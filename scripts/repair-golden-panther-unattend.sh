#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# sysprep.exe leaves sysprep-generalize.xml in Panther when sysprep.ps1 ran as shutdown_command
# and the guest powered off before post-sysprep restore. C:\unattend.xml is often still OOBE.
# Copy C:\unattend.xml -> Panther\unattend.xml offline so promote-time inspect passes.
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

IMAGE="$(readlink -f "$IMAGE")"

read_guest_file() {
  libguestfs_direct guestfish --ro -a "$IMAGE" -i cat "$1" 2>/dev/null || true
}

c_unattend="$(read_guest_file /unattend.xml)"
panther_unattend="$(read_guest_file /Windows/Panther/unattend.xml)"

needs_repair=0
if printf '%s\n' "$c_unattend" | grep -q 'pass="oobeSystem"'; then
  if [[ -z "$panther_unattend" ]]; then
    needs_repair=1
  elif printf '%s\n' "$panther_unattend" | grep -q 'pass="generalize"'; then
    needs_repair=1
  elif ! printf '%s\n' "$panther_unattend" | grep -q 'pass="oobeSystem"'; then
    needs_repair=1
  fi
fi

if [[ $needs_repair -eq 0 ]]; then
  exit 0
fi

guestfish_upload_rw() {
  local image="$1"
  local local_path="$2"
  local guest_path="$3"
  local root_part=""

  root_part="$(libguestfs_direct guestfish --ro -a "$image" run : inspect-os 2>/dev/null || true)"
  if [[ -z "$root_part" ]]; then
    echo "ERROR: could not find Windows root partition in $image" >&2
    return 1
  fi

  # Force-killed QEMU leaves NTFS dirty; libguestfs mounts it read-only until ntfsfix runs.
  libguestfs_direct guestfish --rw -a "$image" run \
    : ntfsfix "$root_part" \
    : mount "$root_part" / \
    : upload "$local_path" "$guest_path"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s' "$c_unattend" >"$tmp"

echo "Repairing Panther\\unattend.xml from C:\\unattend.xml in $IMAGE" >&2
guestfish_upload_rw "$IMAGE" "$tmp" /Windows/Panther/unattend.xml
