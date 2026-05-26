# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Unattended UEFI Windows install via virt-install (SATA CD-ROMs). For OpenShift-ready base disks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"

read_hcl() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$VAR_FILE" | head -1 | sed -E 's/^[^=]+=[[:space:]]*"([^"]+)".*/\1/; s/^[^=]+=[[:space:]]*([^"[:space:]]+).*/\1/'
}

WINDOWS_VERSION="$(read_hcl windows_version)"
VM_MEMORY="$(read_hcl vm_memory)"
VM_CPUS="$(read_hcl vm_cpus)"
DISK_SIZE="$(read_hcl disk_size)"
OUTPUT_DIR="$(read_hcl output_directory)"
HEADLESS="$(read_hcl headless)"

WINDOWS_VERSION="${WINDOWS_VERSION:-2022}"
if [[ "$WINDOWS_VERSION" == "2025" ]]; then
  WINDOWS_ISO="$(read_hcl windows_iso_path_2025)"
  ISO_VAR="windows_iso_path_2025"
else
  WINDOWS_ISO="$(read_hcl windows_iso_path_2022)"
  ISO_VAR="windows_iso_path_2022"
fi

: "${WINDOWS_ISO:?Set ${ISO_VAR} in $VAR_FILE for windows_version=${WINDOWS_VERSION}}"
: "${VM_MEMORY:=8192}"
: "${VM_CPUS:=4}"
: "${DISK_SIZE:=60G}"
: "${OUTPUT_DIR:=$ROOT/output}"

DISK_PATH="$OUTPUT_DIR/uefi-install-base.qcow2"
AUTOUNATTEND_XML="$(mktemp)"
PROVISION_ISO="$OUTPUT_DIR/provision.iso"
VM_NAME="win-uefi-install"

mkdir -p "$OUTPUT_DIR"
UEFI=1 VAR_FILE="$VAR_FILE" "$ROOT/scripts/render-autounattend.sh" >"$AUTOUNATTEND_XML"
"$ROOT/scripts/create-provision-iso.sh" "$AUTOUNATTEND_XML"
rm -f "$AUTOUNATTEND_XML"

if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "Removing existing domain $VM_NAME" >&2
  virsh destroy "$VM_NAME" 2>/dev/null || true
  virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || virsh undefine "$VM_NAME" 2>/dev/null || true
fi

rm -f "$DISK_PATH"

GRAPHICS=(--graphics vnc,listen=127.0.0.1)
if [[ "$HEADLESS" == "true" ]]; then
  GRAPHICS=(--graphics none)
fi

echo "Starting UEFI install VM (watch virt-viewer or VNC if headless=false in var file)" >&2
virt-install \
  --name "$VM_NAME" \
  --memory "$VM_MEMORY" \
  --vcpus "$VM_CPUS" \
  --machine q35 \
  --arch x86_64 \
  --osinfo win2k22 \
  --boot uefi,menu=on \
  --disk path="$DISK_PATH",size="${DISK_SIZE%G}",bus=sata,format=qcow2,cache=writeback \
  --cdrom "$WINDOWS_ISO" \
  --disk path="$PROVISION_ISO",device=cdrom,bus=sata \
  "${GRAPHICS[@]}" \
  --noautoconsole \
  --wait -1

echo "Install finished. Disk: $DISK_PATH"
echo "Next: boot the VM once, confirm WinRM/OpenSSH, or attach this disk to your provisioning workflow."
