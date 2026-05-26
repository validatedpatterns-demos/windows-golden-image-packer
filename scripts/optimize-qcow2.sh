# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Re-encode a golden qcow2 with sparse allocation and optional cluster compression.
# Usage: optimize-qcow2.sh [--all] [path.qcow2 ...]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP_BACKUP="${QCOW2_OPTIMIZE_KEEP_BACKUP:-0}"
COMPRESSION="${QCOW2_COMPRESSION:-zstd}"
ALL=0
declare -a paths=()

usage() {
  cat <<EOF
Usage: optimize-qcow2.sh [--all] [path.qcow2 ...]

Re-encodes qcow2 images so unused clusters are dropped and clusters are compressed.
Virtual disk size is unchanged; DataVolume requirements stay the same.

Environment:
  QCOW2_COMPRESSION           zstd (default) or zlib
  QCOW2_OPTIMIZE_KEEP_BACKUP  1 keeps path.qcow2.orig after success (default 0)

With no paths, optimizes the newest golden image under output/ or packer/output/.
EOF
}

log() {
  echo "optimize-qcow2: $*" >&2
}

die() {
  echo "optimize-qcow2: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --all)
      ALL=1
      shift
      ;;
    --)
      shift
      paths+=("$@")
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done

if [[ "$ALL" == "1" ]]; then
  mapfile -t paths < <("$ROOT/scripts/find-golden-qcow2.sh" --all)
fi

if ((${#paths[@]} == 0)); then
  paths=("$( "$ROOT/scripts/find-golden-qcow2.sh")")
fi

command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"

convert_opts() {
  local -a opts=(-p -O qcow2)
  case "$COMPRESSION" in
    zstd | zlib)
      opts+=(-c -o "compression_type=$COMPRESSION")
      ;;
    none | off)
      ;;
    *)
      die "Unsupported QCOW2_COMPRESSION=$COMPRESSION (use zstd, zlib, or none)"
      ;;
  esac
  printf '%s\n' "${opts[@]}"
}

optimize_one() {
  local image="$1"
  local abs src_dir base tmp backup before after
  [[ -f "$image" ]] || die "Not a file: $image"

  abs="$(cd "$(dirname "$image")" && pwd)/$(basename "$image")"
  src_dir="$(dirname "$abs")"
  base="$(basename "$abs")"
  tmp="$(mktemp "$src_dir/.${base}.optimize.XXXXXX")"
  backup="${abs}.orig"

  trap 'rm -f "$tmp"' RETURN

  before="$(qemu-img info --output=json "$abs" | python3 -c 'import json,sys; print(json.load(sys.stdin)["actual-size"])')"
  log "Optimizing $abs ($(numfmt --to=iec-i --suffix=B "$before" 2>/dev/null || echo "${before} bytes"))"

  mapfile -t convert_args < <(convert_opts)
  if ! qemu-img convert "${convert_args[@]}" "$abs" "$tmp" 2>/dev/null; then
    if [[ "$COMPRESSION" == "zstd" ]]; then
      log "zstd compression unavailable; retrying with zlib"
      COMPRESSION=zlib
      mapfile -t convert_args < <(convert_opts)
      qemu-img convert "${convert_args[@]}" "$abs" "$tmp"
    else
      die "qemu-img convert failed for $abs"
    fi
  fi

  qemu-img check "$tmp" >/dev/null

  after="$(qemu-img info --output=json "$tmp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["actual-size"])')"
  mv -f "$abs" "$backup"
  mv -f "$tmp" "$abs"
  trap - RETURN

  if [[ "$KEEP_BACKUP" == "1" ]]; then
    log "Backup kept at $backup"
  else
    rm -f "$backup"
  fi

  log "Done: $abs ($(numfmt --to=iec-i --suffix=B "$after" 2>/dev/null || echo "${after} bytes"))"
  "$ROOT/scripts/qcow2-size-report.sh" "$abs"
}

for image in "${paths[@]}"; do
  optimize_one "$image"
done
