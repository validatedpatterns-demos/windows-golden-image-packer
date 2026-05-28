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
DISK_SIZE="$(read_hcl disk_size 60G)"
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
LIBVIRT_CONNECT="${LIBVIRT_CONNECT:-qemu:///system}"

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

UEFI="$UEFI_FLAG" VERSION="$VERSION" VAR_FILE="$VAR_FILE" "$ROOT/scripts/render-autounattend.sh" >"$AUTOUNATTEND_XML"
OUT="$PROVISION_ISO" "$ROOT/scripts/create-provision-iso.sh" "$AUTOUNATTEND_XML"
"$ROOT/scripts/create-unattend-floppy-image.sh" "$AUTOUNATTEND_XML" "$UNATTEND_FLOPPY"

rm -f "$STAGING_DIR/provision-drivers.iso" "$STAGING_DIR/windows-uefi-install.iso" \
  "$STAGING_DIR/windows-uefi-install.iso.stamp" "$STAGING_DIR/windows-install-with-autounattend.iso" \
  "$STAGING_DIR/unattend-usb.img"

libvirt_destroy_domain "$LIBVIRT_CONNECT" "$VM_NAME" 0
rm -f "/var/lib/libvirt/qemu/nvram/${VM_NAME}_VARS.qcow2" 2>/dev/null || true

rm -f "$DISK_PATH"

GRAPHICS=(--graphics vnc,listen=127.0.0.1)
if [[ "$HEADLESS" == "true" ]]; then
  GRAPHICS=(--graphics none)
fi

libvirt_disk_args "$DISK_PATH" sata "${DISK_SIZE%G}"

if [[ "$INSTALL_FIRMWARE" == "uefi" ]]; then
  libvirt_uefi_install_boot_args "$VAR_FILE" "$ROOT" || exit 1
else
  libvirt_seabios_install_boot_args
fi

TPM_ARGS=()
if [[ "$INSTALL_FIRMWARE" == "uefi" ]] && pkrvar_vtpm_enabled "$VAR_FILE" "$ROOT"; then
  mapfile -t TPM_ARGS < <(libvirt_tpm_args "$VAR_FILE" "$ROOT" 1)
fi

echo "Starting Windows Server ${VERSION} install VM (${WINDOWS_EDITION})" >&2
echo "  Install firmware: $INSTALL_FIRMWARE (final golden image is still UEFI after provision + mbr2gpt)" >&2
echo "  Machine:          $INSTALL_MACHINE" >&2
echo "  Windows ISO:      $WINDOWS_ISO (unmodified Microsoft media)" >&2
echo "  Disk (install):   $DISK_PATH (SATA)" >&2
echo "  PROVISION ISO:    $PROVISION_ISO" >&2
echo "  Unattend floppy:  $UNATTEND_FLOPPY" >&2
if [[ "$INSTALL_FIRMWARE" == "seabios" ]]; then
  echo "  OVMF BdsDxe timeout on DVD? Expected — install uses SeaBIOS; Packer converts disk to UEFI." >&2
else
  echo "  In OVMF menu pick UEFI: … DVD for the Windows ISO." >&2
fi

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

wait "$INSTALL_PID"

libvirt_destroy_domain "$LIBVIRT_CONNECT" "$VM_NAME" 0

echo "Install finished: $DISK_PATH"
echo "Next: Packer provision (mbr2gpt + virtio + sysprep) boots with OVMF"
