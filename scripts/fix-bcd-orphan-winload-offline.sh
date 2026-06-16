#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Repair generalized UEFI BCD on a golden qcow2:
# - set winload loader device/osdevice to Windows partition GUID (type 0x06 qualified partition)
# - remove orphan winload.efi objects not in bootmgr displayorder
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"

IMAGE="${1:-}"
if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "Usage: $0 /path/to/windows-server-*.qcow2" >&2
  exit 1
fi
if ! command -v guestfish >/dev/null 2>&1; then
  echo "guestfish not found (install libguestfs-tools)" >&2
  exit 1
fi
if ! command -v hivexsh >/dev/null 2>&1 || ! command -v hivexget >/dev/null 2>&1; then
  echo "hivexsh/hivexget not found (install hivex)" >&2
  exit 1
fi

IMAGE="$(readlink -f "$IMAGE")"

BCD_BOOTMGR='{9dea862c-5cdd-4e70-acc1-f32b344d4795}'
BCD_BOOTMGR_DEVICE_KEY="\\Objects\\${BCD_BOOTMGR}\\Elements\\11000001"
BCD_GUEST_PATH='/EFI/Microsoft/Boot/BCD'
BCD_ELEM_DEVICE='11000001'
BCD_ELEM_OSDEVICE='21000001'
BCD_ELEM_WRONG_OSDEVICE='11000002'
BCD_ELEM_APPLICATION='12000002'
BCD_PARTITION_DEVICE_TYPE='06000000'

bcd_get_element() {
  local hive="$1"
  local key="$2"
  local value_name
  for value_name in Element "" 0; do
    if out="$(hivexget "$hive" "$key" "$value_name" 2>/dev/null)"; then
      printf '%s' "$out"
      return 0
    fi
  done
  return 1
}

bcd_element_present() {
  bcd_get_element "$1" "$2" >/dev/null 2>&1
}

bcd_element_hex_type3() {
  local hive="$1"
  local key="$2"
  hivexget "$hive" "$key" Element | xxd -p | tr -d '\n' | sed 's/../&,/g;s/,$//'
}

bcd_element_raw_hex() {
  local hive="$1"
  local key="$2"
  hivexget "$hive" "$key" Element | xxd -p | tr -d '\n'
}

guid_to_bcd_hex() {
  local guid="$1"
  guid="${guid//\{/}"
  guid="${guid//\}/}"
  guid="${guid//-/}"
  guid="${guid,,}"

  local d1="${guid:0:8}"
  local d2="${guid:8:4}"
  local d3="${guid:12:4}"
  local d4="${guid:16:4}"
  local d5="${guid:20:12}"

  rev_pairs() {
    local s="$1" out="" i
    for ((i = ${#s} - 2; i >= 0; i -= 2)); do
      out+="${s:i:2}"
    done
    printf '%s' "$out"
  }

  local part_hex
  part_hex="$(rev_pairs "$d1")$(rev_pairs "$d2")$(rev_pairs "$d3")${d4}${d5}"
  sed 's/../&,/g;s/,$//' <<<"$part_hex"
}

get_windows_partition_guid() {
  local image="$1"
  local part guid gpt_type

  mapfile -t parts < <(libguestfs_direct guestfish --ro -a "$image" run : list-partitions 2>/dev/null || true)
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^/dev/sda[0-9]+$ ]] || continue
    gpt_type="$(libguestfs_direct guestfish --ro -a "$image" run : part-get-gpt-type "$part" 2>/dev/null || true)"
    if [[ "${gpt_type,,}" == 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7' ]]; then
      guid="$(libguestfs_direct guestfish --ro -a "$image" run : part-get-gpt-guid "$part" 2>/dev/null || true)"
      if [[ -n "$guid" ]]; then
        printf '%s' "$guid"
        return 0
      fi
    fi
  done

  guid="$(libguestfs_direct guestfish --ro -a "$image" run : part-get-gpt-guid /dev/sda 3 2>/dev/null || true)"
  if [[ -n "$guid" ]]; then
    printf '%s' "$guid"
    return 0
  fi

  return 1
}

build_windows_partition_device_hex() {
  local hive="$1"
  local windows_guid="$2"
  local template part_hex raw prefix suffix

  raw="$(bcd_element_raw_hex "$hive" "$BCD_BOOTMGR_DEVICE_KEY")"
  if [[ ${#raw} -lt 128 ]]; then
    echo "ERROR: bootmgr device element too short to use as BCD partition template" >&2
    return 1
  fi

  part_hex="$(guid_to_bcd_hex "$windows_guid")"
  part_hex="${part_hex//,/}"
  if [[ ${#part_hex} -ne 32 ]]; then
    echo "ERROR: invalid partition GUID hex for $windows_guid" >&2
    return 1
  fi

  prefix="${raw:0:64}"
  suffix="${raw:96}"
  template="${prefix}${part_hex}${suffix}"
  if [[ "${template:32:8}" != "$BCD_PARTITION_DEVICE_TYPE" ]]; then
    echo "ERROR: bootmgr device template is not GPT partition type 0x06" >&2
    return 1
  fi
  sed 's/../&,/g;s/,$//' <<<"$template"
}

loader_device_needs_repair() {
  local hive="$1"
  local guid="$2"
  local elem key raw devtype part_hex

  for elem in "$BCD_ELEM_DEVICE" "$BCD_ELEM_OSDEVICE"; do
    key="\\Objects\\${guid}\\Elements\\${elem}"
    if ! raw="$(bcd_element_raw_hex "$hive" "$key" 2>/dev/null)"; then
      return 0
    fi
    if [[ ${#raw} -lt 96 ]]; then
      return 0
    fi
    devtype="${raw:32:8}"
    part_hex="${raw:64:32}"
    if [[ "$devtype" != "$BCD_PARTITION_DEVICE_TYPE" ]]; then
      return 0
    fi
    if [[ "$part_hex" == '00000000000000000000000000000000' ]]; then
      return 0
    fi
  done
  return 1
}

append_delete_wrong_osdevice_element() {
  local script="$1"
  local hive="$2"
  local guid="$3"
  local key="\\Objects\\${guid}\\Elements\\${BCD_ELEM_WRONG_OSDEVICE}"

  if ! bcd_element_present "$hive" "$key"; then
    return 1
  fi
  {
    echo "cd ${key}"
    echo "del"
  } >>"$script"
  echo "Offline BCD cleanup: remove non-osdevice element ${BCD_ELEM_WRONG_OSDEVICE} on loader ${guid}" >&2
  return 0
}

append_set_partition_device_element() {
  local script="$1"
  local hive="$2"
  local guid="$3"
  local elem="$4"
  local hexbytes="$5"
  local key="\\Objects\\${guid}\\Elements\\${elem}"

  if bcd_element_present "$hive" "$key"; then
    {
      echo "cd ${key}"
      echo "del"
    } >>"$script"
  fi
  {
    echo "cd \\Objects\\${guid}\\Elements"
    echo "add ${elem}"
    echo "cd ${elem}"
    echo "setval 1"
    echo "Element"
    echo "hex:3:${hexbytes}"
  } >>"$script"
}

append_repair_loader_partition_devices() {
  local script="$1"
  local hive="$2"
  local guid="$3"
  local windows_guid="$4"

  local hexbytes
  hexbytes="$(build_windows_partition_device_hex "$hive" "$windows_guid")"

  append_set_partition_device_element "$script" "$hive" "$guid" "$BCD_ELEM_DEVICE" "$hexbytes"
  append_set_partition_device_element "$script" "$hive" "$guid" "$BCD_ELEM_OSDEVICE" "$hexbytes"
  echo "Offline BCD repair: set loader ${guid} device/osdevice to partition ${windows_guid}" >&2
}

guid_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

download_bcd_hive() {
  local image="$1"
  local dest="$2"
  local esp

  if libguestfs_direct guestfish --ro -a "$image" -i download "$BCD_GUEST_PATH" "$dest" 2>/dev/null; then
    printf '%s' 'inspect-os'
    return 0
  fi

  for esp in /dev/sda1 /dev/sda3; do
    if libguestfs_direct guestfish --ro -a "$image" run : mount "$esp" / : download "$BCD_GUEST_PATH" "$dest" 2>/dev/null; then
      printf '%s' "$esp"
      return 0
    fi
  done

  return 1
}

upload_bcd_hive() {
  local image="$1"
  local esp_mount="$2"
  local local_bcd="$3"

  if lsof "$image" 2>/dev/null | rg -q .; then
    echo "ERROR: $image is open by another process; stop boot-test/Packer VMs before offline BCD repair" >&2
    lsof "$image" 2>/dev/null >&2 || true
    return 1
  fi

  if [[ "$esp_mount" == 'inspect-os' ]]; then
    libguestfs_direct guestfish --rw -a "$image" -i upload "$local_bcd" "$BCD_GUEST_PATH"
    return
  fi

  libguestfs_direct guestfish --rw -a "$image" run \
    : mount "$esp_mount" / \
    : upload "$local_bcd" "$BCD_GUEST_PATH"
}

tmp_bcd="$(build_mktemp bcd.XXXXXX)"
tmp_script="$(build_mktemp hivexsh.XXXXXX)"
trap 'rm -f "$tmp_bcd" "$tmp_script"' EXIT

esp_mount="$(download_bcd_hive "$IMAGE" "$tmp_bcd")" || {
  echo "ERROR: could not read ESP BCD from $IMAGE" >&2
  exit 1
}

windows_guid="$(get_windows_partition_guid "$IMAGE")" || {
  echo "ERROR: could not determine Windows partition GPT GUID from $IMAGE" >&2
  exit 1
}

displayorder_raw="$(bcd_get_element "$tmp_bcd" "\\Objects\\${BCD_BOOTMGR}\\Elements\\23000003" || true)"
mapfile -t keep_guids < <(printf '%s' "$displayorder_raw" | rg -o '\{[0-9a-fA-F-]{36}\}' || true)

mapfile -t bcd_objects < <(printf 'cd Objects\nls\nquit\n' | hivexsh "$tmp_bcd" 2>/dev/null | rg '^\{' || true)

modified=0
: >"$tmp_script"

for guid in "${keep_guids[@]}"; do
  app_path="$(bcd_get_element "$tmp_bcd" "\\Objects\\${guid}\\Elements\\${BCD_ELEM_APPLICATION}" || true)"
  if ! printf '%s' "$app_path" | rg -qi 'winload\.efi'; then
    continue
  fi
  if loader_device_needs_repair "$tmp_bcd" "$guid"; then
    append_repair_loader_partition_devices "$tmp_script" "$tmp_bcd" "$guid" "$windows_guid"
    modified=1
  fi
  if append_delete_wrong_osdevice_element "$tmp_script" "$tmp_bcd" "$guid"; then
    modified=1
  fi
done

for guid in "${bcd_objects[@]}"; do
  app_path="$(bcd_get_element "$tmp_bcd" "\\Objects\\${guid}\\Elements\\${BCD_ELEM_APPLICATION}" || true)"
  if ! printf '%s' "$app_path" | rg -qi 'winload\.efi'; then
    continue
  fi
  if guid_in_list "$guid" "${keep_guids[@]}"; then
    continue
  fi
  {
    echo "cd \\Objects\\${guid}"
    echo "del"
  } >>"$tmp_script"
  modified=1
  echo "Offline BCD cleanup: removing orphan winload object ${guid}" >&2
done

if [[ "$modified" -eq 0 ]]; then
  exit 0
fi

echo "commit" >>"$tmp_script"
hivexsh -w -f "$tmp_script" "$tmp_bcd"
upload_bcd_hive "$IMAGE" "$esp_mount" "$tmp_bcd"
echo "Offline BCD generalized boot repair complete for $IMAGE" >&2
