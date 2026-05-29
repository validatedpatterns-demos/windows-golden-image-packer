#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Copy diagnostic logs from a golden qcow2 to the current directory (requires guestfish).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-}"
OUT_DIR="${2:-./golden-logs}"

if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "Usage: $0 /path/to/windows-server-*.qcow2 [output-dir]" >&2
  exit 1
fi

if ! command -v guestfish >/dev/null 2>&1; then
  echo "Install libguestfs-tools (guestfish)" >&2
  exit 1
fi

IMAGE="$(readlink -f "$IMAGE")"
mkdir -p "$OUT_DIR"

copy_if_exists() {
  local guest_path="$1" out_name="$2"
  if guestfish -a "$IMAGE" -i cat "$guest_path" >"$OUT_DIR/$out_name" 2>/dev/null; then
    echo "Wrote $OUT_DIR/$out_name"
  else
    echo "Missing in image: $guest_path" >&2
  fi
}

echo "Extracting from $IMAGE" >&2
copy_if_exists /Windows/Panther/configure-oobe-locale.log configure-oobe-locale.log
copy_if_exists /Windows/Panther/unattend.xml panther-unattend.xml
copy_if_exists /Windows/Panther/setuperr.log panther-setuperr.log
copy_if_exists /Windows/Panther/setupact.log panther-setupact.log
copy_if_exists /Windows/System32/Sysprep/Panther/setuperr.log sysprep-setuperr.log
copy_if_exists /Windows/System32/Sysprep/Panther/setupact.log sysprep-setupact.log
copy_if_exists /ProgramData/GoldenImage/sysprep-oobe.xml golden-sysprep-oobe.xml
copy_if_exists /Windows/Temp/configure-oobe-locale.log temp-configure-oobe-locale.log

if [[ -f "$OUT_DIR/panther-unattend.xml" ]] && grep -q 'pass="windowsPE"' "$OUT_DIR/panther-unattend.xml" 2>/dev/null; then
  if ! "$ROOT/scripts/inspect-golden-unattend.sh" "$IMAGE" 2>/dev/null; then
    echo "" >&2
    echo ">>> Panther unattend.xml is NOT the sysprep OOBE file (locale prompt expected)." >&2
    echo ">>> Re-run make build-2022 and ensure Packer provision completes configure-oobe-locale.ps1." >&2
  fi
fi

echo "Done. See $OUT_DIR/" >&2
