#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Re-render sysprep-oobe.xml from build.pkrvars.hcl and write it to all OOBE unattend paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"

IMAGE="${1:-}"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
VERSION="${VERSION:-2022}"

if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "Usage: VAR_FILE=build.pkrvars.hcl VERSION=2022 $0 /path/to/windows-server-*.qcow2" >&2
  exit 1
fi
if ! command -v guestfish >/dev/null 2>&1; then
  echo "guestfish not found (install libguestfs-tools)" >&2
  exit 1
fi
if [[ ! -f "$VAR_FILE" ]]; then
  echo "Var file not found: $VAR_FILE" >&2
  exit 1
fi

IMAGE="$(readlink -f "$IMAGE")"

if lsof "$IMAGE" 2>/dev/null | rg -q .; then
  echo "ERROR: $IMAGE is open (stop boot-test/Packer VMs first)" >&2
  lsof "$IMAGE" 2>/dev/null >&2 || true
  exit 1
fi

OOBE_UNATTEND_PATHS=(
  /unattend.xml
  /Windows/Panther/unattend.xml
  /ProgramData/GoldenImage/sysprep-oobe.xml
  /Windows/Temp/sysprep-oobe.xml
)

render_oobe_unattend() {
  local var_file="$1"
  local version="$2"
  # shellcheck source=scripts/resolve-packer.sh
  source "$ROOT/scripts/resolve-packer.sh"
  local packer_bin
  packer_bin="$(resolve_packer)"
  (
    cd "$ROOT/packer"
    "$packer_bin" console -var-file="../$(basename "$var_file")" -var "windows_version=${version}" . <<'EOF' | sed -n '/^<?xml/,/^<\/unattend>/p'
local.sysprep_oobe_unattend
EOF
  )
}

tmp="$(build_mktemp sysprep-oobe.XXXXXX)"
software_hive="$(build_mktemp software.XXXXXX)"
oobe_reg="$(build_mktemp oobe-skip-product-key.XXXXXX.reg)"
trap 'rm -f "$tmp" "$software_hive" "$oobe_reg"' EXIT

render_oobe_unattend "$VAR_FILE" "$VERSION" >"$tmp"

if ! head -1 "$tmp" | rg -q '^<\?xml'; then
  echo "ERROR: failed to render sysprep-oobe.xml from $VAR_FILE" >&2
  exit 1
fi

if rg -q '<WillShowUI>' "$tmp"; then
  echo "ERROR: rendered sysprep-oobe.xml still contains WillShowUI" >&2
  exit 1
fi

root_part="$(libguestfs_direct guestfish --ro -a "$IMAGE" run : inspect-os 2>/dev/null || true)"
if [[ -z "$root_part" ]]; then
  echo "ERROR: could not find Windows root partition in $IMAGE" >&2
  exit 1
fi

for guest_path in "${OOBE_UNATTEND_PATHS[@]}"; do
  libguestfs_direct guestfish --rw -a "$IMAGE" run \
    : ntfsfix "$root_part" \
    : mount "$root_part" / \
    : upload "$tmp" "$guest_path"
  echo "Wrote rendered sysprep-oobe.xml -> $guest_path" >&2
done

set_oobe_skip_product_key_offline() {
  local image="$1"
  local local_hive="$2"
  local reg_file="$3"

  if ! command -v hivexregedit >/dev/null 2>&1; then
    echo "WARNING: hivexregedit not found; skipping offline SetupDisplayedProductKey registry patch" >&2
    return 0
  fi

  if ! libguestfs_direct guestfish --ro -a "$image" -i download /Windows/System32/config/SOFTWARE "$local_hive" 2>/dev/null; then
    echo "WARNING: could not read SOFTWARE hive; skipping SetupDisplayedProductKey patch" >&2
    return 0
  fi

  cat >"$reg_file" <<'EOF'
Windows Registry Editor Version 5.00

[Microsoft\Windows\CurrentVersion\Setup\OOBE]
"SetupDisplayedProductKey"=dword:00000001
EOF

  if ! hivexregedit --merge "$local_hive" "$reg_file" 2>/dev/null; then
    echo "WARNING: hivexregedit failed to set SetupDisplayedProductKey" >&2
    return 0
  fi

  libguestfs_direct guestfish --rw -a "$image" run \
    : ntfsfix "$root_part" \
    : mount "$root_part" / \
    : upload "$local_hive" /Windows/System32/config/SOFTWARE
  echo "Set SOFTWARE\\...\\Setup\\OOBE\\SetupDisplayedProductKey=1 offline" >&2
}

set_oobe_skip_product_key_offline "$IMAGE" "$software_hive" "$oobe_reg"

echo "Offline OOBE unattend refresh complete for $IMAGE" >&2
