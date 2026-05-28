#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Embed autounattend.xml in sources/boot.wim and repack the Windows install ISO.
# NOT used by build-uefi-virt-install.sh: xorriso -boot_image replay breaks the hidden UEFI
# El Torito image (OVMF: "BdsDxe: No bootable option or device was found"). Use the
# unmodified Microsoft ISO plus scripts/create-unattend-floppy-image.sh instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "Usage: $0 <windows.iso> <autounattend.xml> <output.iso>" >&2
  exit 1
}

WINDOWS_ISO="${1:-}"
AUTOUNATTEND="${2:-}"
OUT_ISO="${3:-}"

[[ -n "$WINDOWS_ISO" && -n "$AUTOUNATTEND" && -n "$OUT_ISO" ]] || usage
[[ -f "$WINDOWS_ISO" ]] || { echo "Windows ISO not found: $WINDOWS_ISO" >&2; exit 1; }
[[ -f "$AUTOUNATTEND" ]] || { echo "autounattend.xml not found: $AUTOUNATTEND" >&2; exit 1; }

for cmd in 7z wimlib-imagex xorriso; do
  command -v "$cmd" >/dev/null || {
    echo "$cmd is required (dnf install p7zip-plugins wimlib-utils xorriso)" >&2
    exit 1
  }
done

WINDOWS_ISO="$(readlink -f "$WINDOWS_ISO")"
AUTOUNATTEND="$(readlink -f "$AUTOUNATTEND")"
OUT_ISO="$(readlink -f "$OUT_ISO")"
mkdir -p "$(dirname "$OUT_ISO")"

iso_id="$(stat -c '%Y:%s' "$WINDOWS_ISO")"
au_id="$(sha256sum "$AUTOUNATTEND" | awk '{print $1}')"
stamp="${iso_id}-${au_id}"

if [[ -f "$OUT_ISO" && -f "${OUT_ISO}.stamp" && "$(cat "${OUT_ISO}.stamp")" == "$stamp" ]]; then
  echo "Using cached install ISO with boot.wim autounattend: $OUT_ISO" >&2
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

BOOTWIM="$WORKDIR/sources/boot.wim"
7z x -o"$WORKDIR" -y "$WINDOWS_ISO" sources/boot.wim >/dev/null
if [[ ! -f "$BOOTWIM" ]]; then
  echo "ERROR: 7z did not extract sources/boot.wim (expected $BOOTWIM)" >&2
  exit 1
fi

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

tmp_out="${OUT_ISO}.partial"
rm -f "$tmp_out"
xorriso -indev "$WINDOWS_ISO" \
  -boot_image any replay \
  -map "$BOOTWIM" /sources/boot.wim \
  -outdev "$tmp_out" \
  -commit >/dev/null

mv -f "$tmp_out" "$OUT_ISO"
printf '%s\n' "$stamp" >"${OUT_ISO}.stamp"
echo "Install ISO with autounattend in boot.wim: $OUT_ISO" >&2
