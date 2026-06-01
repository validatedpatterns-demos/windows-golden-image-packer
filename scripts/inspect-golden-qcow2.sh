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
inspect_hive_control_set() {
  local hive="$1"
  local cs="$2"
  local svc start cdd_blk cdd_scsi found=0

  for svc in viostor vioscsi; do
    start="$(hivexget "$hive" "\\${cs}\\Services\\${svc}" Start 2>/dev/null || true)"
    [[ -n "$start" ]] || continue
    found=1
    echo "  ${cs} ${svc} Start=${start} (expect 0)"
    if [[ "$start" != 0 ]]; then
      echo "  FAIL: ${cs} ${svc} is not boot-start (sysprep left a stale control set without VirtIO drivers)" >&2
      virtio_rc=1
    fi
  done

  cdd_blk="$(hivexget "$hive" "\\${cs}\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1001" Service 2>/dev/null || true)"
  if [[ -n "$cdd_blk" ]]; then
    found=1
    echo "  ${cs} CriticalDeviceDatabase pci#ven_1af4&dev_1001 -> ${cdd_blk} (expect viostor)"
    if [[ "$cdd_blk" != viostor ]]; then
      echo "  FAIL: ${cs} missing viostor CriticalDeviceDatabase entry (INACCESSIBLE_BOOT_DEVICE on disk.bus=virtio)" >&2
      virtio_rc=1
    fi
  fi

  cdd_scsi="$(hivexget "$hive" "\\${cs}\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1004" Service 2>/dev/null || true)"
  if [[ -n "$cdd_scsi" ]]; then
    echo "  ${cs} CriticalDeviceDatabase pci#ven_1af4&dev_1004 -> ${cdd_scsi} (expect vioscsi)"
    if [[ "$cdd_scsi" != vioscsi ]]; then
      echo "  FAIL: ${cs} missing vioscsi CriticalDeviceDatabase entry (INACCESSIBLE_BOOT_DEVICE on disk.bus=scsi)" >&2
      virtio_rc=1
    fi
  fi

  [[ "$found" -eq 1 ]]
}

if [[ -r "$IMAGE" ]] && command -v guestfish >/dev/null 2>&1 && command -v hivexget >/dev/null 2>&1; then
  tmp_hive="$(mktemp)"
  if libguestfs_direct guestfish --ro -a "$IMAGE" -i download /Windows/System32/config/SYSTEM "$tmp_hive" 2>/dev/null; then
    echo ""
    echo "VirtIO boot-start (offline registry):"
    default_cs_num="$(hivexget "$tmp_hive" "\\Select" Default 2>/dev/null || echo 1)"
    default_cs_num="${default_cs_num//$'\r'/}"
    default_cs="$(printf 'ControlSet%03d' "$default_cs_num")"
    echo "  Select Default=${default_cs_num} (${default_cs})"

    any_cs=0
    for i in $(seq 1 9); do
      cs="$(printf 'ControlSet%03d' "$i")"
      if inspect_hive_control_set "$tmp_hive" "$cs"; then
        any_cs=1
      fi
    done
    if [[ "$any_cs" -eq 0 ]]; then
      echo "  FAIL: no VirtIO boot driver keys in any ControlSet00N hive" >&2
      virtio_rc=1
    fi

    for driver in viostor.sys vioscsi.sys; do
      if ! libguestfs_direct guestfish --ro -a "$IMAGE" -i is-file "/Windows/System32/drivers/$driver" >/dev/null 2>&1; then
        echo "  FAIL: missing /Windows/System32/drivers/$driver" >&2
        virtio_rc=1
      else
        echo "  driver binary present: $driver"
      fi
    done
  fi
  rm -f "$tmp_hive"
elif [[ ! -r "$IMAGE" ]]; then
  echo ""
  echo "VirtIO registry check skipped (image not readable — chown golden qcow2 to your user first)." >&2
fi

if [[ "${INSPECT_VIRTIO_STRICT:-1}" != 0 && "$virtio_rc" -ne 0 ]]; then
  exit 1
fi
