# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Unattended Windows install via virt-install: UEFI + virtio-blk root (Tekton windows-efi-installer).
# WinPE loads viostor from virtio-win CD; specialize runs virtio-win-gt MSI + QEMU GA.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"
# shellcheck source=scripts/libvirt-cleanup.sh
source "$ROOT/scripts/libvirt-cleanup.sh"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"

read_hcl() {
  "$ROOT/scripts/read-pkrvar.sh" "$1" "$VAR_FILE" "${2:-}"
}

VERSION="${VERSION:-$(read_hcl windows_version 2022)}"
WINDOWS_EDITION="${WINDOWS_EDITION:-$(read_hcl windows_edition Standard)}"
EDITION_LC="$(echo "$WINDOWS_EDITION" | tr '[:upper:]' '[:lower:]')"
PACKER_STAGING="${PACKER_STAGING:-.packer-${VERSION}}"
OUTPUT_PARENT="${OUTPUT_PARENT:-output}"
INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-$(read_hcl install_firmware uefi)}"
INSTALL_DISK_BUS="${INSTALL_DISK_BUS:-$(read_hcl install_disk_interface virtio)}"

VM_MEMORY="$(read_hcl vm_memory 8192)"
VM_CPUS="$(read_hcl vm_cpus 4)"
DISK_SIZE="$(read_hcl disk_size 40G)"
HEADLESS="$(read_hcl headless false)"

if [[ "$VERSION" == "2025" ]]; then
  WINDOWS_ISO="$(read_hcl windows_iso_path_2025)"
  ISO_VAR="windows_iso_path_2025"
else
  WINDOWS_ISO="$(read_hcl windows_iso_path_2022)"
  ISO_VAR="windows_iso_path_2022"
fi

: "${WINDOWS_ISO:?Set ${ISO_VAR} in $VAR_FILE for VERSION=${VERSION}}"

if [[ "$WINDOWS_ISO" != /* ]]; then
  WINDOWS_ISO="$ROOT/$WINDOWS_ISO"
fi
if [[ ! -f "$WINDOWS_ISO" ]]; then
  iso_dir="$(dirname "$WINDOWS_ISO")"
  echo "ERROR: Windows ISO not found: $WINDOWS_ISO" >&2
  echo "Update ${ISO_VAR} in $VAR_FILE to your install media." >&2
  if [[ -d "$iso_dir" ]]; then
    echo "Available *.iso in $iso_dir:" >&2
    # shellcheck disable=SC2012
    ls -1 "$iso_dir"/*.iso 2>/dev/null | sed 's/^/  /' >&2 || echo "  (none)" >&2
  fi
  exit 1
fi
WINDOWS_ISO="$(readlink -f "$WINDOWS_ISO")"

virtio_os_dir=2k22
if [[ "$VERSION" == "2025" ]]; then
  virtio_os_dir=2k25
fi
if [[ ! -f "$ROOT/drivers/viostor/$virtio_os_dir/amd64/viostor.sys" ]]; then
  echo "VirtIO drivers not staged for $virtio_os_dir. Run: STAGE_FORCE=1 make stage-virtio" >&2
  exit 1
fi
if [[ ! -f "$ROOT/drivers/virtio-win-gt-x64.msi" ]]; then
  echo "virtio-win-gt-x64.msi not staged. Run: STAGE_FORCE=1 make stage-virtio" >&2
  exit 1
fi

STAGING_DIR="$ROOT/$OUTPUT_PARENT/$PACKER_STAGING"
mkdir -p "$STAGING_DIR"

DISK_PATH="$STAGING_DIR/packer-win${VERSION}-${EDITION_LC}-install.qcow2"
AUTOUNATTEND_XML="$(build_mktemp autounattend.XXXXXX)"
PROVISION_ISO="$STAGING_DIR/provision.iso"
VIRTIO_ISO="$STAGING_DIR/virtio-drivers.iso"
WINDOWS_INSTALL_ISO="$WINDOWS_ISO"
WINDOWS_UEFI_ISO="$STAGING_DIR/windows-uefi-install.iso"
UNATTEND_FLOPPY="$STAGING_DIR/unattend-floppy.img"
VM_NAME="win-uefi-install-${VERSION}"
LIBVIRT_CONNECT="${LIBVIRT_CONNECT:-$(libvirt_default_connect)}"

libvirt_check_build_prereqs "$LIBVIRT_CONNECT"

log() {
  echo "$*"
}

trap 'rm -f "$AUTOUNATTEND_XML"' EXIT

case "$INSTALL_FIRMWARE" in
  uefi)
    UEFI_FLAG=1
    INSTALL_MACHINE=q35
    ;;
  seabios)
    UEFI_FLAG=0
    INSTALL_MACHINE=pc
    ;;
  *)
    echo "ERROR: install_firmware must be seabios or uefi (got: $INSTALL_FIRMWARE)" >&2
    exit 1
    ;;
esac

case "$INSTALL_DISK_BUS" in
  virtio | virtio-scsi | sata | ide) ;;
  *)
    echo "ERROR: install_disk_interface must be virtio, virtio-scsi, sata, or ide (got: $INSTALL_DISK_BUS)" >&2
    exit 1
    ;;
esac

UEFI="$UEFI_FLAG" VERSION="$VERSION" VAR_FILE="$VAR_FILE" INSTALL_AUTO_SHUTDOWN=1 "$ROOT/scripts/render-autounattend.sh" >"$AUTOUNATTEND_XML"

if [[ "$INSTALL_FIRMWARE" == "uefi" ]]; then
  "$ROOT/scripts/modify-windows-iso-for-uefi.sh" "$WINDOWS_ISO" "$WINDOWS_UEFI_ISO" "$AUTOUNATTEND_XML"
  WINDOWS_INSTALL_ISO="$WINDOWS_UEFI_ISO"
fi

PROVISION_ISO_SLIM=1 OUT="$PROVISION_ISO" "$ROOT/scripts/create-provision-iso.sh" "$AUTOUNATTEND_XML"
OUT="$VIRTIO_ISO" "$ROOT/scripts/create-provision-drivers-iso.sh"

rm -f "$STAGING_DIR/provision-drivers.iso" \
  "$STAGING_DIR/windows-install-with-autounattend.iso" \
  "$STAGING_DIR/unattend-usb.img" "$UNATTEND_FLOPPY"

libvirt_destroy_domain "$LIBVIRT_CONNECT" "$VM_NAME" 0
if virsh --connect "$LIBVIRT_CONNECT" dominfo "$VM_NAME" &>/dev/null; then
  echo "ERROR: libvirt domain $VM_NAME still exists; run: make clean" >&2
  exit 1
fi
if libvirt_uses_system_connect "$LIBVIRT_CONNECT"; then
  rm -f "/var/lib/libvirt/qemu/nvram/${VM_NAME}_VARS.qcow2" 2>/dev/null || true
fi

rm -f "$DISK_PATH"
if libvirt_uses_system_connect "$LIBVIRT_CONNECT"; then
  qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
  libvirt_prepare_install_disk_for_system "$DISK_PATH"
  libvirt_disk_args "$DISK_PATH" "$INSTALL_DISK_BUS" "" "1"
else
  libvirt_disk_args "$DISK_PATH" "$INSTALL_DISK_BUS" "${DISK_SIZE%G}" "1"
fi

GRAPHICS=(--graphics vnc,listen=127.0.0.1)
if [[ "$HEADLESS" == "true" ]]; then
  GRAPHICS=(--graphics none)
fi

if [[ "$INSTALL_FIRMWARE" == "uefi" ]]; then
  libvirt_uefi_install_boot_args "$VAR_FILE" "$ROOT" || exit 1
else
  libvirt_seabios_install_boot_args
fi

TPM_ARGS=()
if [[ "$INSTALL_FIRMWARE" == "uefi" ]] && pkrvar_vtpm_enabled "$VAR_FILE" "$ROOT"; then
  mapfile -t TPM_ARGS < <(libvirt_tpm_args "$VAR_FILE" "$ROOT" 1)
fi

VIRT_INSTALL_DISKS=(
  --disk "path=${WINDOWS_INSTALL_ISO},device=cdrom,bus=sata,boot_order=2"
  --disk "path=${PROVISION_ISO},device=cdrom,bus=sata"
  --disk "path=${VIRTIO_ISO},device=cdrom,bus=sata"
)

if [[ "$INSTALL_FIRMWARE" == "seabios" ]]; then
  "$ROOT/scripts/create-unattend-floppy-image.sh" "$AUTOUNATTEND_XML" "$UNATTEND_FLOPPY"
  VIRT_INSTALL_DISKS+=(--disk "path=${UNATTEND_FLOPPY},device=floppy,readonly=on")
fi

log ""
log "=== Phase 1/2: Windows install (virt-install, UEFI + virtio-blk) ==="
log "Unattended Setup runs in the libvirt VM; this phase usually takes 30-60 minutes."
log ""
log "Starting Windows Server ${VERSION} install VM (${WINDOWS_EDITION})"
log "  libvirt:          $LIBVIRT_CONNECT"
log "  Install firmware: $INSTALL_FIRMWARE"
log "  Root disk bus:    $INSTALL_DISK_BUS"
log "  Machine:          $INSTALL_MACHINE"
log "  Windows ISO:      $WINDOWS_ISO"
if [[ "$INSTALL_FIRMWARE" == "uefi" ]]; then
  log "  UEFI install ISO: $WINDOWS_INSTALL_ISO (noprompt EFI bootloaders)"
fi
log "  Install disk:     $DISK_PATH (boot_order=1 — reboots continue on disk, not DVD)"
log "  PROVISION ISO:    $PROVISION_ISO (autounattend + WinRM)"
log "  VirtIO ISO:       $VIRTIO_ISO (WinPE drivers + virtio-win-gt MSI)"
if [[ "$INSTALL_FIRMWARE" == "uefi" ]]; then
  log "  Console: OVMF should auto-boot the Windows DVD (noprompt ISO); use boot menu if needed"
else
  log "  Console: SeaBIOS + Windows Setup"
fi
log ""
virt-install \
  --connect "$LIBVIRT_CONNECT" \
  --name "$VM_NAME" \
  --memory "$VM_MEMORY" \
  --vcpus "$VM_CPUS" \
  --machine "$INSTALL_MACHINE" \
  --arch x86_64 \
  --osinfo win2k22 \
  "${LIBVIRT_UEFI_VIRT_INSTALL_ARGS[@]}" \
  "${TPM_ARGS[@]}" \
  "${VIRT_INSTALL_DISKS[@]}" \
  "${DISK_CONTROLLER_ARGS[@]}" \
  "${DISK_DEVICE_ARG[@]}" \
  "${GRAPHICS[@]}" \
  --noautoconsole \
  --wait -1 &
INSTALL_PID=$!

for _ in $(seq 1 60); do
  if virsh --connect "$LIBVIRT_CONNECT" dominfo "$VM_NAME" &>/dev/null; then
    if [[ "$INSTALL_FIRMWARE" == "uefi" ]]; then
      if ! virsh --connect "$LIBVIRT_CONNECT" dumpxml "$VM_NAME" | grep -q 'type=.pflash'; then
        echo "ERROR: $VM_NAME has no OVMF loader (libvirt defaulted to SeaBIOS)." >&2
        echo "  Install edk2-ovmf, destroy the domain, and rebuild." >&2
        exit 1
      fi
    fi
    if [[ "$HEADLESS" != "true" ]]; then
      "$ROOT/scripts/open-vm-console.sh" --background "$LIBVIRT_CONNECT" "$VM_NAME" || true
    fi
    break
  fi
  sleep 1
done

log "virt-install started (domain: $VM_NAME). Waiting for Windows Setup to finish and power off..."
install_start=$(date +%s)
last_progress=0
while kill -0 "$INSTALL_PID" 2>/dev/null; do
  now=$(date +%s)
  elapsed=$((now - install_start))
  if (( elapsed - last_progress >= 300 )); then
    state="$(virsh --connect "$LIBVIRT_CONNECT" domstate "$VM_NAME" 2>/dev/null || echo unknown)"
    mins=$((elapsed / 60))
    log ""
    log "  [${mins}m] Install still in progress (VM state: ${state}). Typical total: 30-60 minutes."
    log "  Watch the VM: virt-viewer --connect $LIBVIRT_CONNECT $VM_NAME"
    log ""
    last_progress=$elapsed
  fi
  sleep 30
done
wait "$INSTALL_PID"

libvirt_destroy_domain "$LIBVIRT_CONNECT" "$VM_NAME" 0

libvirt_fixup_disk_for_build_user "$DISK_PATH"

log ""
log "=== Phase 1/2 complete ==="
log "Install finished: $DISK_PATH"
log "Next: Phase 2 Packer provision + sysprep on OVMF/virtio-blk — typically 45-90 minutes."
log ""
