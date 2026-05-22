#!/usr/bin/env bash
# Print the path to the built golden qcow2 (repo output/ or packer/output/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

search_dirs=(
  "$ROOT/output"
  "$ROOT/packer/output"
)

for dir in "${search_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  # Prefer finalized golden image name
  shopt -s nullglob
  for f in "$dir"/windows-server-*.qcow2; do
    if [[ -f "$f" ]]; then
      echo "$f"
      exit 0
    fi
  done
  shopt -u nullglob
done

# Fallback: Packer vm_name without .qcow2 extension (post-processor did not run)
for dir in "${search_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  shopt -s nullglob
  for f in "$dir"/packer-win*; do
    if [[ -f "$f" ]]; then
      echo "$f"
      exit 0
    fi
  done
  shopt -u nullglob
done

echo "No golden qcow2 found under output/ or packer/output/ (run make build first)" >&2
echo "Checked: ${search_dirs[*]}" >&2
exit 1
