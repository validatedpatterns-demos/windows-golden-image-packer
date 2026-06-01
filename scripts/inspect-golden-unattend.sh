#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Read OOBE unattend from a golden qcow2 (offline) and confirm sysprep first-boot settings.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"

IMAGE="${1:-}"
if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "Usage: $0 /path/to/windows-server-*.qcow2" >&2
  exit 1
fi

if ! command -v guestfish >/dev/null 2>&1; then
  echo "guestfish not found (install libguestfs-tools)" >&2
  exit 1
fi

read_guest_file() {
  local guest_path="$1"
  libguestfs_direct guestfish --ro -a "$IMAGE" -i cat "$guest_path" 2>/dev/null || true
}

validate_oobe_unattend() {
  local label="$1"
  local unattend="$2"

  if [[ -z "$unattend" ]]; then
    echo "FAIL: $label is empty or missing" >&2
    return 1
  fi

  if printf '%s\n' "$unattend" | grep -q 'pass="windowsPE"'; then
    echo "FAIL: $label is the install answer file (contains windowsPE pass)." >&2
    return 1
  fi

  if printf '%s\n' "$unattend" | grep -q 'pass="generalize"'; then
    echo "FAIL: $label is sysprep-generalize.xml (missing oobeSystem for first deploy boot)." >&2
    return 1
  fi

  if ! printf '%s\n' "$unattend" | grep -q 'pass="oobeSystem"'; then
    echo "FAIL: $label has no oobeSystem pass." >&2
    return 1
  fi

  if printf '%s\n' "$unattend" | grep -q 'pass="oobeSystem" wasPassProcessed="true"'; then
    echo "FAIL: $label oobeSystem was already processed (install autounattend?)." >&2
    return 1
  fi

  if ! printf '%s\n' "$unattend" | grep -q 'Microsoft-Windows-International-Core'; then
    echo "FAIL: $label has no Microsoft-Windows-International-Core (locale OOBE will prompt)." >&2
    return 1
  fi

  if printf '%s\n' "$unattend" | grep -q 'WIN-PACKER'; then
    echo "FAIL: $label is still install autounattend.xml (ComputerName WIN-PACKER)." >&2
    return 1
  fi

  if printf '%s\n' "$unattend" | grep -q '<Enabled>true</Enabled>'; then
    echo "FAIL: $label has AutoLogon enabled (install file, not sysprep-oobe.xml)." >&2
    return 1
  fi

  if printf '%s\n' "$unattend" | grep -q '<NetworkLocation>'; then
    echo "FAIL: $label contains deprecated NetworkLocation (OOBE parse error on Server)." >&2
    return 1
  fi

  if printf '%s\n' "$unattend" | grep -q '<WillShowUI>'; then
    echo "FAIL: $label contains WillShowUI (valid only in windowsPE UserData, not oobeSystem)." >&2
    return 1
  fi

  echo "OK: $label looks like sysprep OOBE configuration" >&2
}

IMAGE="$(readlink -f "$IMAGE")"
echo "Inspecting $IMAGE" >&2

c_unattend="$(read_guest_file /unattend.xml)"
panther_unattend="$(read_guest_file /Windows/Panther/unattend.xml)"

rc=0
validate_oobe_unattend "C:\\unattend.xml" "$c_unattend" || rc=1
validate_oobe_unattend "Panther\\unattend.xml" "$panther_unattend" || rc=1

if [[ $rc -ne 0 ]]; then
  echo "      Rebuild with current sysprep-oobe.xml.tpl and sysprep.ps1." >&2
  exit 1
fi

exit 0
