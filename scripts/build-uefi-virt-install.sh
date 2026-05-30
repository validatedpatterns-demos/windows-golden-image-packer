# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Unattended Windows install via virt-install, then Packer provision converts MBR→GPT for UEFI.
# Microsoft UDF install ISOs often fail OVMF DVD boot (BdsDxe timeout) on Fedora QEMU 10; SeaBIOS
# install + mbr2gpt during provision is the reliable path. Set install_firmware=uefi to try direct UEFI install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"
# shellcheck source=scripts/libvirt-cleanup.sh
source "$ROOT/scripts/libvirt-cleanup.sh"

read_hcl() {
  "$ROOT/scripts/read-pkrvar.sh" "$1" "$VAR_FILE" "${2:-}"
}

VERSION="${VERSION:-$(read_hcl windows_version 2022)}"
WINDOWS_EDITION="${WINDOWS_EDITION:-$(read_hcl windows_edition Standard)}"
EDITION_LC="$(echo "$WINDOWS_EDITION" | tr '[:upper:]' '[:lower:]')"
PACKER_STAGING="${PACKER_STAGING:-.packer-${VERSION}}"
OUTPUT_PARENT="${OUTPUT_PARENT:-output}"
INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-$(read_hcl install_firmware seabios)}"

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

STAGING_DIR="$ROOT/$OUTPUT_PARENT/$PACKER_STAGING"
mkdir -p "$STAGING_DIR"

DISK_PATH="$STAGING_DIR/packer-win${VERSION}-${EDITION_LC}-install.qcow2"
AUTOUNATTEND_XML="$(mktemp)"
PROVISION_ISO="$STAGING_DIR/provision.iso"
UNATTEND_FLOPPY="$STAGING_DIR/unattend-floppy.img"
VM_NAME="win-uefi-install-${VERSION}"
LIBVIRT_CONNECT="${LIBVIRT_CONNECT:-$(libvirt_default_connect)}"

libvirt_check_build_prereqs "$LIBVIRT_CONNECT"

log() {
  # stdout so phase banners stay visible when make captures stderr from virt-install
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

UEFI="$UEFI_FLAG" VERSION="$VERSION" VAR_FILE="$VAR_FILE" INSTALL_AUTO_SHUTDOWN=1 "$ROOT/scripts/render-autounattend.sh" >"$AUTOUNATTEND_XML"
OUT="$PROVISION_ISO" "$ROOT/scripts/create-provision-iso.sh" "$AUTOUNATTEND_XML"
"$ROOT/scripts/create-unattend-floppy-image.sh" "$AUTOUNATTEND_XML" "$UNATTEND_FLOPPY"

rm -f "$STAGING_DIR/provision-drivers.iso" "$STAGING_DIR/windows-uefi-install.iso" \
  "$STAGING_DIR/windows-uefi-install.iso.stamp" "$STAGING_DIR/windows-install-with-autounattend.iso" \
  "$STAGING_DIR/unattend-usb.img"

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
  libvirt_disk_args "$DISK_PATH" sata ""
else
  libvirt_disk_args "$DISK_PATH" sata "${DISK_SIZE%G}"
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

log ""
log "=== Phase 1/2: Windows install (virt-install) ==="
log "Unattended Setup runs in the libvirt VM; this phase usually takes 30-60 minutes."
log "The golden image is still UEFI/GPT after Phase 2 (Packer mbr2gpt + virtio + sysprep)."
log ""
log "Starting Windows Server ${VERSION} install VM (${WINDOWS_EDITION})"
log "  libvirt:          $LIBVIRT_CONNECT"
log "  Install firmware: $INSTALL_FIRMWARE (SeaBIOS is normal; Packer converts to UEFI later)"
log "  Machine:          $INSTALL_MACHINE"
log "  Windows ISO:      $WINDOWS_ISO"
log "  Install disk:     $DISK_PATH (SATA via libvirt)"
log "  PROVISION ISO:    $PROVISION_ISO"
log "  Unattend floppy:  $UNATTEND_FLOPPY"
if [[ "$INSTALL_FIRMWARE" == "seabios" ]]; then
  log "  Console: SeaBIOS + Windows Setup (no OVMF menu expected in this phase)"
else
  log "  Console: pick UEFI: … DVD in the OVMF boot menu if prompted"
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
  "${DISK_CONTROLLER_ARGS[@]}" \
  "${DISK_DEVICE_ARG[@]}" \
  --disk "path=${WINDOWS_ISO},device=cdrom,bus=sata,boot_order=1" \
  --disk "path=${PROVISION_ISO},device=cdrom,bus=sata" \
  --disk "path=${UNATTEND_FLOPPY},device=floppy,readonly=on" \
  "${GRAPHICS[@]}" \
  --noautoconsole \
  --wait -1 &
INSTALL_PID=$!

for _ in $(seq 1 60); do
  if virsh --connect "$LIBVIRT_CONNECT" dominfo "$VM_NAME" &>/dev/null; then
    if [[ "$INSTALL_FIRMWARE" == "uefi" ]]; then
      if ! virsh --connect "$LIBVIRT_CONNECT" dumpxml "$VM_NAME" | grep -q 'type=.pflash'; then
        echo "ERROR: $VM_NAME has no OVMF loader (libvirt defaulted to SeaBIOS)." >&2
        echo "  Install edk2-ovmf, destroy the domain, set install_firmware=seabios, and rebuild." >&2
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
log "  When unattended install succeeds, the guest shuts down automatically (Server Manager = install done; run: shutdown /s /t 0)"
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
    log "  After this phase: Packer provision (mbr2gpt, VirtIO drivers, sysprep)."
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
log "Next: Phase 2 Packer provision (OVMF, mbr2gpt, virtio, sysprep) — typically 45-90 minutes."
log ""
