# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Find built golden qcow2 images under output/ or packer/output/.
# Usage: find-golden-qcow2.sh          # print one image (newest), exit 1 if none
#        find-golden-qcow2.sh --all    # print all windows-server-*.qcow2 (one per line)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALL="${1:-}"

search_dirs=(
  "$ROOT/output"
  "$ROOT/packer/output"
)

collect_finalized() {
  local -a found=()
  local dir f
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    shopt -s nullglob
    for f in "$dir"/windows-server-*.qcow2; do
      [[ -f "$f" ]] && found+=("$f")
    done
    shopt -u nullglob
  done
  if ((${#found[@]} > 0)); then
    printf '%s\n' "${found[@]}"
    return 0
  fi
  return 1
}

collect_packer_vm_names() {
  local -a found=()
  local dir f
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    shopt -s nullglob
    for f in "$dir"/packer-win*; do
      [[ -f "$f" ]] && found+=("$f")
    done
    shopt -u nullglob
  done
  if ((${#found[@]} > 0)); then
    printf '%s\n' "${found[@]}"
    return 0
  fi
  return 1
}

mapfile -t images < <(collect_finalized || collect_packer_vm_names || true)

if ((${#images[@]} == 0)); then
  echo "No golden qcow2 found under output/ or packer/output/ (run make build first)" >&2
  echo "Checked: ${search_dirs[*]}" >&2
  exit 1
fi

if [[ "$ALL" == "--all" ]]; then
  printf '%s\n' "${images[@]}"
  exit 0
fi

# Default: newest file by mtime (single build / push-quay with GOLDEN_QCOW2 unset)
newest="${images[0]}"
for f in "${images[@]}"; do
  if [[ "$f" -nt "$newest" ]]; then
    newest="$f"
  fi
done
echo "$newest"
