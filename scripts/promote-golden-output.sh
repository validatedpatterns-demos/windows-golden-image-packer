#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Move finalized golden qcow2 from a per-version Packer staging dir to output/.
# Install qcow2 and helper ISOs live in the staging root; Packer writes to staging/work/.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <windows_version> [staging_dir_name]" >&2
  echo "Example: $0 2022 .packer-2022" >&2
  exit 1
fi

VERSION="$1"
STAGING="${2:-.packer-${VERSION}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/output"
STAGING_DIR="$ROOT/output/$STAGING"

mkdir -p "$DEST"

if [[ ! -d "$STAGING_DIR" ]]; then
  echo "Staging directory not found: $STAGING_DIR" >&2
  exit 1
fi

shopt -s nullglob
matches=("$STAGING_DIR"/windows-server-"${VERSION}"-*.qcow2)
if ((${#matches[@]} == 0)); then
  matches=("$STAGING_DIR"/work/windows-server-"${VERSION}"-*.qcow2)
fi
shopt -u nullglob

if ((${#matches[@]} == 0)); then
  echo "No windows-server-${VERSION}-*.qcow2 under $STAGING_DIR (or $STAGING_DIR/work)" >&2
  ls -la "$STAGING_DIR" "$STAGING_DIR/work" 2>/dev/null || ls -la "$STAGING_DIR" >&2 || true
  exit 1
fi

for src in "${matches[@]}"; do
  base="$(basename "$src")"
  dest="$DEST/$base"
  if [[ -f "$dest" ]]; then
    rm -f "$dest"
  fi
  mv -f "$src" "$dest"
  echo "Golden image: $dest"
  if [[ -x "$ROOT/scripts/inspect-golden-unattend.sh" ]]; then
    "$ROOT/scripts/inspect-golden-unattend.sh" "$dest"
  fi
done

# Drop Packer work dir only; install qcow2 and ISOs remain until make clean.
rm -rf "$STAGING_DIR/work"
