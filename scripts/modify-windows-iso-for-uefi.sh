#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Tekton modify-windows-iso-file: swap prompt EFI bootloaders for noprompt variants so
# OVMF can boot Microsoft Server ISOs unattended on Fedora/QEMU 10.
# Optionally embed autounattend.xml in sources/boot.wim (reliable WinPE discovery).
#
# Usage: modify-windows-iso-for-uefi.sh <windows.iso> <output.iso> [autounattend.xml]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"

usage() {
  echo "Usage: $0 <windows.iso> <output.iso> [autounattend.xml]" >&2
  exit 1
}

WINDOWS_ISO="${1:-}"
OUT_ISO="${2:-}"
AUTOUNATTEND="${3:-}"

[[ -n "$WINDOWS_ISO" && -n "$OUT_ISO" ]] || usage
[[ -f "$WINDOWS_ISO" ]] || { echo "Windows ISO not found: $WINDOWS_ISO" >&2; exit 1; }
if [[ -n "$AUTOUNATTEND" && ! -f "$AUTOUNATTEND" ]]; then
  echo "autounattend.xml not found: $AUTOUNATTEND" >&2
  exit 1
fi

for cmd in 7z genisoimage isoinfo; do
  command -v "$cmd" >/dev/null || {
    echo "$cmd is required (dnf install p7zip p7zip-plugins genisoimage)" >&2
    exit 1
  }
done
if [[ -n "$AUTOUNATTEND" ]]; then
  command -v wimlib-imagex >/dev/null || {
    echo "wimlib-imagex is required to embed autounattend (dnf install wimlib-utils)" >&2
    exit 1
  }
fi

WINDOWS_ISO="$(readlink -f "$WINDOWS_ISO")"
OUT_ISO="$(readlink -f "$OUT_ISO")"
mkdir -p "$(dirname "$OUT_ISO")"

iso_id="$(stat -c '%Y:%s' "$WINDOWS_ISO")"
au_stamp="none"
if [[ -n "$AUTOUNATTEND" ]]; then
  au_stamp="$(sha256sum "$AUTOUNATTEND" | awk '{print $1}')"
fi
stamp="${iso_id}-noprompt-uefi-v2-${au_stamp}"

if [[ -f "$OUT_ISO" && -f "${OUT_ISO}.stamp" && "$(cat "${OUT_ISO}.stamp")" == "$stamp" ]]; then
  echo "Using cached UEFI noprompt install ISO: $OUT_ISO" >&2
  exit 0
fi

WORKDIR="$(build_mktemp_dir modify-windows-iso.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

CONTENTS="$WORKDIR/contents"
mkdir -p "$CONTENTS"

echo "Extracting Windows ISO (this may take a few minutes)..." >&2
7z x -y "-o${CONTENTS}" "$WINDOWS_ISO" >/dev/null

EFI_BOOT="${CONTENTS}/efi/microsoft/boot"
for f in efisys_noprompt.bin cdboot_noprompt.efi efisys.bin cdboot.efi; do
  if [[ ! -f "${EFI_BOOT}/${f}" ]]; then
    echo "ERROR: expected efi/microsoft/boot/${f} in Windows ISO (is this a Microsoft Server eval ISO?)" >&2
    exit 1
  fi
done
if [[ ! -f "${CONTENTS}/boot/etfsboot.com" ]]; then
  echo "ERROR: expected boot/etfsboot.com in Windows ISO" >&2
  exit 1
fi

echo "Replacing prompt EFI bootloaders with noprompt variants..." >&2
cp -f "${EFI_BOOT}/efisys_noprompt.bin" "${EFI_BOOT}/efisys.bin"
cp -f "${EFI_BOOT}/cdboot_noprompt.efi" "${EFI_BOOT}/cdboot.efi"

BOOTWIM="${CONTENTS}/sources/boot.wim"
if [[ -n "$AUTOUNATTEND" ]]; then
  if [[ ! -f "$BOOTWIM" ]]; then
    echo "ERROR: sources/boot.wim missing from Windows ISO" >&2
    exit 1
  fi
  echo "Embedding autounattend.xml in sources/boot.wim..." >&2
  image_count="$(wimlib-imagex info "$BOOTWIM" | awk -F': *' '/^Image Count:/ {print $2}')"
  if [[ -z "$image_count" || "$image_count" -lt 1 ]]; then
    echo "ERROR: Could not read boot.wim image count from $BOOTWIM" >&2
    exit 1
  fi
  for idx in $(seq 1 "$image_count"); do
    wimlib-imagex update "$BOOTWIM" "$idx" \
      --command="add ${AUTOUNATTEND} /autounattend.xml"
    wimlib-imagex update "$BOOTWIM" "$idx" \
      --command="add ${AUTOUNATTEND} /unattend.xml"
  done
fi

volume_label="$(isoinfo -d -i "$WINDOWS_ISO" | awk -F: '/Volume id:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
[[ -n "$volume_label" ]] || volume_label="WINDOWS"

tmp_out="${OUT_ISO}.partial"
rm -f "$tmp_out"

echo "Repacking bootable ISO (dual El Torito BIOS + UEFI)..." >&2
(
  cd "$CONTENTS"
  genisoimage \
    -allow-limited-size \
    -iso-level 4 \
    -udf \
    -joliet \
    -joliet-long \
    -relaxed-filenames \
    -V "$volume_label" \
    -b boot/etfsboot.com \
    -no-emul-boot \
    -boot-load-size 8 \
    -hide boot.catalog \
    -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys.bin \
    -no-emul-boot \
    -o "$tmp_out" \
    .
)

mv -f "$tmp_out" "$OUT_ISO"
printf '%s\n' "$stamp" >"${OUT_ISO}.stamp"
echo "UEFI noprompt install ISO: $OUT_ISO" >&2
