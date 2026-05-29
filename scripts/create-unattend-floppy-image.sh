#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# 2.88 MB FAT12 floppy image with autounattend.xml at the root (drive A: in WinPE).
# Windows Setup discovers autounattend on removable floppy before the language page.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <autounattend.xml> <output.img>" >&2
  exit 1
fi

AUTOUNATTEND="$1"
OUT_IMG="$2"

for cmd in mformat mcopy; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required (dnf install mtools)" >&2
    exit 1
  fi
done

if [[ ! -f "$AUTOUNATTEND" ]]; then
  echo "autounattend.xml not found: $AUTOUNATTEND" >&2
  exit 1
fi

AUTOUNATTEND="$(readlink -f "$AUTOUNATTEND")"
OUT_IMG="$(readlink -f "$OUT_IMG")"

newest_src="$AUTOUNATTEND"
for f in \
  "$ROOT/http/enable-winrm.ps1" \
  "$ROOT/http/enable-winrm.cmd" \
  "$ROOT/http/enable-winrm-locator.cmd" \
  "$ROOT/scripts/clear-autologon.ps1" \
  "$ROOT/scripts/stage-unattend-media-files.sh"; do
  [[ -f "$f" && "$f" -nt "$newest_src" ]] && newest_src="$f"
done

if [[ -f "$OUT_IMG" && "$OUT_IMG" -nt "$newest_src" ]]; then
  echo "Using cached unattend floppy image: $OUT_IMG" >&2
  exit 0
fi

mkdir -p "$(dirname "$OUT_IMG")"
rm -f "$OUT_IMG"
truncate -s 2880K "$OUT_IMG"
mformat -i "$OUT_IMG" -f 2880 -v UNATTEND ::
mcopy -oi "$OUT_IMG" "$AUTOUNATTEND" ::autounattend.xml
mcopy -oi "$OUT_IMG" "$AUTOUNATTEND" ::unattend.xml

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
"$ROOT/scripts/stage-unattend-media-files.sh" "$STAGE"
for f in "$STAGE"/*; do
  [[ -f "$f" ]] || continue
  mcopy -oi "$OUT_IMG" "$f" "::$(basename "$f")"
done

echo "Unattend floppy image: $OUT_IMG" >&2
