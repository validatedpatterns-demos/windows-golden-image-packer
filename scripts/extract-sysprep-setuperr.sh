#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Extract sysprep failure logs from a qcow2 (requires guestfish).
set -euo pipefail

IMAGE="${1:-}"
OUT="${2:-}"

GUEST_PATHS=(
  "/ProgramData/GoldenImage/sysprep-diagnostics.log"
  "/Windows/Panther/sysprep-diagnostics.log"
  "/Windows/System32/Sysprep/Panther/setuperr.log"
  "/Windows/Panther/setuperr.log"
  "/Windows/Temp/sysprep-stderr.log"
  "/Windows/Temp/sysprep-stdout.log"
  "/ProgramData/GoldenImage/prepare-for-sysprep.log"
)

if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "Usage: $0 /path/to/packer-win*.qcow2 [output-file]" >&2
  exit 1
fi

if ! command -v guestfish >/dev/null 2>&1; then
  echo "Install libguestfs-tools (guestfish)" >&2
  exit 1
fi

IMAGE="$(readlink -f "$IMAGE")"

extract_path() {
  local guest_path="$1"
  guestfish -a "$IMAGE" -i cat "$guest_path" 2>/dev/null
}

found=0
for guest_path in "${GUEST_PATHS[@]}"; do
  if extract_path "$guest_path" >/dev/null; then
    found=1
    if [[ -n "$OUT" ]]; then
      {
        echo "=== ${guest_path} ==="
        extract_path "$guest_path"
        echo ""
      } >>"$OUT"
    else
      echo "=== ${guest_path} ==="
      extract_path "$guest_path"
      echo ""
    fi
  fi
done

if [[ "$found" -eq 0 ]]; then
  echo "No sysprep logs found in $IMAGE" >&2
  echo "Tried:" >&2
  printf '  %s\n' "${GUEST_PATHS[@]}" >&2
  echo "Hint: failed builds keep the disk at output/.packer-*/work/packer-win*" >&2
  exit 1
fi

if [[ -n "$OUT" ]]; then
  echo "Wrote $OUT" >&2
fi
