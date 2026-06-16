#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Fix OOBE unattend ProductKey blocks for sysprep first boot:
# - flat <ProductKey>KEY</ProductKey> -> nested <Key>
# - remove invalid <WillShowUI> from oobeSystem Shell-Setup
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

IMAGE="$(readlink -f "$IMAGE")"

OOBE_UNATTEND_PATHS=(
  /unattend.xml
  /Windows/Panther/unattend.xml
  /ProgramData/GoldenImage/sysprep-oobe.xml
  /Windows/Temp/sysprep-oobe.xml
)

rewrite_oobe_product_key() {
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()
original = text

# Remove WillShowUI (invalid in oobeSystem Shell-Setup; causes "outside acceptable values").
text = re.sub(r"[ \t]*<WillShowUI>[^<]*</WillShowUI>\n?", "", text)

flat = re.compile(
    r"(?P<indent>[ \t]*)<ProductKey>(?P<key>[^<\s]+)</ProductKey>"
)
if flat.search(text):
    text = flat.sub(
        r"\g<indent><ProductKey>\n"
        r"\g<indent>  <Key>\g<key></Key>\n"
        r"\g<indent></ProductKey>",
        text,
        count=1,
    )

if text == original:
    sys.exit(1)

open(path, "w", encoding="utf-8").write(text)
print("rewrote")
PY
}

guestfish_upload() {
  local local_path="$1"
  local guest_path="$2"
  local root_part

  root_part="$(libguestfs_direct guestfish --ro -a "$IMAGE" run : inspect-os 2>/dev/null || true)"
  if [[ -z "$root_part" ]]; then
    echo "ERROR: could not find Windows root partition in $IMAGE" >&2
    return 1
  fi

  libguestfs_direct guestfish --rw -a "$IMAGE" run \
    : ntfsfix "$root_part" \
    : mount "$root_part" / \
    : upload "$local_path" "$guest_path"
}

modified=0
for guest_path in "${OOBE_UNATTEND_PATHS[@]}"; do
  tmp="$(build_mktemp oobe-unattend.XXXXXX)"
  if ! libguestfs_direct guestfish --ro -a "$IMAGE" -i download "$guest_path" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    continue
  fi
  if rewrite_oobe_product_key "$tmp"; then
    echo "Offline OOBE unattend repair: $guest_path" >&2
    guestfish_upload "$tmp" "$guest_path"
    modified=1
  fi
  rm -f "$tmp"
done

if [[ "$modified" -eq 0 ]]; then
  exit 0
fi

echo "Offline OOBE ProductKey/unattend repair complete for $IMAGE" >&2
