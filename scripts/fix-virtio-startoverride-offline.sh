#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Remove Services\viostor|vioscsi\StartOverride from the offline SYSTEM hive.
# Windows re-adds StartOverride=3 when the sysprep VM last booted SATA/IDE (not virtio-blk),
# often after in-guest verify and immediately before shutdown.
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
if ! command -v hivexsh >/dev/null 2>&1 || ! command -v hivexget >/dev/null 2>&1; then
  echo "hivexsh/hivexget not found (install hivex)" >&2
  exit 1
fi

IMAGE="$(readlink -f "$IMAGE")"

startoverride_key_present() {
  local hive="$1"
  local cs="$2"
  local svc="$3"
  local key

  for key in 0 1 2; do
    if hivexget "$hive" "\\${cs}\\Services\\${svc}\\StartOverride" "$key" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

build_hivexsh_script() {
  local hive="$1"
  local script="$2"
  local modified=0
  local i cs svc

  : >"$script"
  for i in $(seq 1 9); do
    cs="$(printf 'ControlSet%03d' "$i")"
    for svc in viostor vioscsi; do
      if startoverride_key_present "$hive" "$cs" "$svc"; then
        {
          echo "cd \\${cs}\\Services\\${svc}\\StartOverride"
          echo "del"
        } >>"$script"
        modified=1
        echo "Offline StartOverride cleanup: \\${cs}\\Services\\${svc}\\StartOverride" >&2
      fi
    done
  done

  if [[ "$modified" -eq 1 ]]; then
    echo "commit" >>"$script"
    return 0
  fi
  return 1
}

guestfish_upload_system_hive() {
  local image="$1"
  local local_hive="$2"
  local root_part=""

  root_part="$(libguestfs_direct guestfish --ro -a "$image" run : inspect-os 2>/dev/null || true)"
  if [[ -z "$root_part" ]]; then
    echo "ERROR: could not find Windows root partition in $image" >&2
    return 1
  fi

  libguestfs_direct guestfish --rw -a "$image" run \
    : ntfsfix "$root_part" \
    : mount "$root_part" / \
    : upload "$local_hive" /Windows/System32/config/SYSTEM
}

tmp_hive="$(mktemp)"
tmp_script="$(mktemp)"
trap 'rm -f "$tmp_hive" "$tmp_script"' EXIT

if ! libguestfs_direct guestfish --ro -a "$IMAGE" -i download /Windows/System32/config/SYSTEM "$tmp_hive" 2>/dev/null; then
  echo "ERROR: could not read SYSTEM hive from $IMAGE (StartOverride offline cleanup required)" >&2
  exit 1
fi

if ! build_hivexsh_script "$tmp_hive" "$tmp_script"; then
  exit 0
fi

hivexsh -w -f "$tmp_script" "$tmp_hive"
guestfish_upload_system_hive "$IMAGE" "$tmp_hive"
echo "Offline StartOverride cleanup complete for $IMAGE" >&2
