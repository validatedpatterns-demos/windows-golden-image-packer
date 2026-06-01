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
    echo "Recommended boot-test: make boot-test (libvirt qemu:///system, virtio-blk + guest-agent)"
    echo "Packer OVMF replay:    BOOT_TEST_METHOD=packer make boot-test-image IMAGE=..."
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

virtio_rc=0
if [[ -r "$IMAGE" ]] && command -v guestfish >/dev/null 2>&1 && command -v hivexget >/dev/null 2>&1; then
  tmp_hive="$(mktemp)"
  if libguestfs_direct guestfish --ro -a "$IMAGE" -i download /Windows/System32/config/SYSTEM "$tmp_hive" 2>/dev/null; then
    echo ""
    echo "VirtIO boot-start (offline registry):"
    for svc in viostor vioscsi; do
      start="$(hivexget "$tmp_hive" "\\ControlSet001\\Services\\$svc" Start 2>/dev/null || echo missing)"
      echo "  $svc Start=$start (expect 0 for virtio boot)"
      if [[ "$start" != 0 ]]; then
        echo "  FAIL: $svc is not boot-start (sysprep stripped drivers; rebuild with restore-virtio-boot-after-sysprep.ps1)" >&2
        virtio_rc=1
      fi
    done
    cdd_blk="$(hivexget "$tmp_hive" '\\ControlSet001\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1001' Service 2>/dev/null || echo missing)"
    echo "  CriticalDeviceDatabase pci#ven_1af4&dev_1001 -> $cdd_blk (expect viostor for bus=virtio)"
    if [[ "$cdd_blk" != viostor ]]; then
      echo "  FAIL: missing viostor CriticalDeviceDatabase entry (INACCESSIBLE_BOOT_DEVICE on disk.bus=virtio)" >&2
      virtio_rc=1
    fi
  fi
  rm -f "$tmp_hive"
elif [[ ! -r "$IMAGE" ]]; then
  echo ""
  echo "VirtIO registry check skipped (image not readable — chown golden qcow2 to your user first)." >&2
fi

if [[ "${INSPECT_VIRTIO_STRICT:-1}" != 0 && "$virtio_rc" -ne 0 ]]; then
  exit 1
fi
