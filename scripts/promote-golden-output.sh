# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Move finalized golden qcow2 from a per-version Packer staging dir to output/.
# Packer removes output_directory on each build; staging avoids deleting other versions.
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
shopt -u nullglob

if ((${#matches[@]} == 0)); then
  echo "No windows-server-${VERSION}-*.qcow2 under $STAGING_DIR" >&2
  ls -la "$STAGING_DIR" >&2 || true
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
done

rm -rf "$STAGING_DIR"
