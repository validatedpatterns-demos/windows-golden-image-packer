# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Report partition layout and boot hints for a golden qcow2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"

IMAGE="${1:-}"
if [[ -z "$IMAGE" ]]; then
  echo "Usage: $0 path/to/windows-server-*.qcow2" >&2
  exit 1
fi
if [[ ! -f "$IMAGE" ]]; then
  echo "Not found: $IMAGE" >&2
  exit 1
fi
IMAGE="$(readlink -f "$IMAGE")"

echo "Image: $IMAGE"
qemu-img info "$IMAGE"
echo ""

if command -v virt-filesystems >/dev/null 2>&1; then
  echo "Partitions:"
  libguestfs_direct virt-filesystems -a "$IMAGE" --all || true
  echo ""
  efi_rc=0
  golden_image_has_efi_partition "$IMAGE" || efi_rc=$?
  if [[ "$efi_rc" -eq 0 ]]; then
    echo "Firmware hint: UEFI (EFI system partition present)"
    echo "Recommended boot-test: make boot-test (UEFI uses Packer OVMF sysprep QEMU layout by default)"
    echo "Legacy libvirt test: BOOT_TEST_METHOD=libvirt make boot-test-image IMAGE=..."
  elif [[ "$efi_rc" -eq 2 ]]; then
    echo "Firmware hint: unknown (could not inspect partitions with libguestfs)"
    echo "Recommended boot-test: try UEFI + sata; install libguestfs-tools if missing"
  else
    echo "Firmware hint: SeaBIOS/MBR (no ESP listed)"
    echo "Recommended boot-test: BOOT_TEST_FIRMWARE=bios"
    echo "Do not use UEFI firmware with this image."
  fi
else
  echo "Install libguestfs-tools (virt-filesystems) for partition inspection." >&2
fi
