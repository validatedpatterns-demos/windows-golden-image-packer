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
    echo "Recommended boot-test: make boot-test (libvirt qemu:///session, virtio-blk + guest-agent)"
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
bcd_rc=0
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
    for override_key in 0 1 2; do
      override_val="$(hivexget "$hive" "\\${cs}\\Services\\${svc}\\StartOverride" "$override_key" 2>/dev/null || true)"
      [[ -n "$override_val" ]] || continue
      echo "  ${cs} ${svc} StartOverride\\${override_key}=${override_val} (expect absent or 0)"
      if [[ "$override_val" != 0 ]]; then
        echo "  FAIL: ${cs} ${svc} StartOverride blocks boot-load at runtime (0x7B on virtio-blk even when Start=0)" >&2
        virtio_rc=1
      fi
    done
  done

  cdd_blk="$(hivexget "$hive" "\\${cs}\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1001" Service 2>/dev/null || true)"
  cdd_blk_sub="$(hivexget "$hive" "\\${cs}\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1001&subsys_00021af4&rev_00" Service 2>/dev/null || true)"
  cdd_blk_mod="$(hivexget "$hive" "\\${cs}\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1042&subsys_11001af4&rev_01" Service 2>/dev/null || true)"
  if [[ -n "$cdd_blk" || -n "$cdd_blk_sub" || -n "$cdd_blk_mod" ]]; then
    found=1
    blk_svc="${cdd_blk:-${cdd_blk_sub:-$cdd_blk_mod}}"
    echo "  ${cs} CriticalDeviceDatabase viostor CDD -> ${blk_svc} (expect viostor)"
    if [[ "$blk_svc" != viostor ]]; then
      echo "  FAIL: ${cs} viostor CriticalDeviceDatabase Service=${blk_svc}" >&2
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
    default_ok=0
    for i in $(seq 1 9); do
      cs="$(printf 'ControlSet%03d' "$i")"
      if inspect_hive_control_set "$tmp_hive" "$cs"; then
        any_cs=1
        [[ "$cs" == "$default_cs" ]] && default_ok=1
      fi
    done
    if [[ "$any_cs" -eq 0 ]]; then
      echo "  FAIL: no VirtIO boot driver keys in any ControlSet00N hive" >&2
      virtio_rc=1
    elif [[ "$default_ok" -ne 1 ]]; then
      echo "  FAIL: Select Default=${default_cs} has no viostor boot-start keys (INACCESSIBLE_BOOT_DEVICE on disk.bus=virtio)" >&2
      virtio_rc=1
    elif [[ "$virtio_rc" -eq 0 ]]; then
      echo "  OK: viostor boot-start in Select Default and all control sets with VirtIO keys"
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

if [[ -r "$IMAGE" ]] && command -v guestfish >/dev/null 2>&1 && command -v strings >/dev/null 2>&1 && command -v hivexsh >/dev/null 2>&1; then
  tmp_bcd="$(mktemp)"
  bcd_get_element() {
    local hive="$1"
    local key="$2"
    for value_name in Element "" 0; do
      if out="$(hivexget "$hive" "$key" "$value_name" 2>/dev/null)"; then
        printf '%s' "$out"
        return 0
      fi
    done
    return 1
  }

  bcd_ok=0
  if libguestfs_direct guestfish --ro -a "$IMAGE" -i download /EFI/Microsoft/Boot/BCD "$tmp_bcd" 2>/dev/null; then
    bcd_ok=1
  else
    for esp in /dev/sda3 /dev/sda1; do
      if libguestfs_direct guestfish --ro -a "$IMAGE" run : mount "$esp" / : download /EFI/Microsoft/Boot/BCD "$tmp_bcd" 2>/dev/null; then
        bcd_ok=1
        break
      fi
    done
  fi
  if [[ "$bcd_ok" -eq 1 ]]; then
    echo ""
    echo "UEFI BCD boot menu sanity:"
    windows_server_count="$(strings -el "$tmp_bcd" 2>/dev/null | rg -x "Windows Server" -c || true)"
    windows_server_count="${windows_server_count:-0}"
    echo "  Windows Server menu entry strings: ${windows_server_count} (expect 1)"
    if [[ "$windows_server_count" -gt 1 ]]; then
      echo "  FAIL: duplicate Windows boot loaders in BCD (boot menu shows two 'Windows Server' entries; winload.efi 0xc000000f risk)" >&2
      bcd_rc=1
    fi

    displayorder_raw="$(bcd_get_element "$tmp_bcd" "\\Objects\\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\Elements\\23000003" || true)"
    mapfile -t display_guids < <(printf '%s' "$displayorder_raw" | rg -o '\{[0-9a-fA-F-]{36}\}' || true)
    display_guids_count="${#display_guids[@]}"
    echo "  bootmgr displayorder GUIDs: ${display_guids_count} (expect 1)"

    display_winload_count=0
    for guid in "${display_guids[@]}"; do
      app_path="$(bcd_get_element "$tmp_bcd" "\\Objects\\${guid}\\Elements\\12000002" || true)"
      if printf '%s' "$app_path" | rg -qi 'winload\.efi'; then
        display_winload_count=$((display_winload_count + 1))
      fi
    done
    echo "  displayorder winload.efi entries: ${display_winload_count} (expect 1)"
    if [[ "$display_guids_count" -ne 1 || "$display_winload_count" -ne 1 ]]; then
      echo "  FAIL: bootmgr displayorder is not a single Windows loader entry (duplicate/invalid boot menu)" >&2
      bcd_rc=1
    fi

    mapfile -t bcd_objects < <(printf 'cd Objects\nls\nquit\n' | hivexsh "$tmp_bcd" 2>/dev/null | rg '^\{' || true)
    bcd_winload_loader_count=0
    for guid in "${bcd_objects[@]}"; do
      app_path="$(bcd_get_element "$tmp_bcd" "\\Objects\\${guid}\\Elements\\12000002" || true)"
      if printf '%s' "$app_path" | rg -qi 'winload\.efi'; then
        bcd_winload_loader_count=$((bcd_winload_loader_count + 1))
      fi
    done
    echo "  BCD osloader objects (winload.efi): ${bcd_winload_loader_count} (expect 1)"
    if [[ "$bcd_winload_loader_count" -ne 1 ]]; then
      echo "  FAIL: BCD store has ${bcd_winload_loader_count} winload osloader objects (orphan loaders -> 0xc000000f/0xc0000001)" >&2
      bcd_rc=1
    fi
  fi
  rm -f "$tmp_bcd"
fi

if [[ "${INSPECT_VIRTIO_STRICT:-1}" != 0 && "$virtio_rc" -ne 0 ]]; then
  exit 1
fi
if [[ "${INSPECT_BCD_STRICT:-1}" != 0 && "$bcd_rc" -ne 0 ]]; then
  exit 1
fi
