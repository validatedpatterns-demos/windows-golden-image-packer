#!/usr/bin/env bash
# Add Apache-2.0 SPDX headers to packer/, scripts/, and http/ sources (idempotent).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MARKER='SPDX-License-Identifier: Apache-2.0'

add_hash_header() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -q "$MARKER" "$file" && return 0
  local tmp
  tmp="$(mktemp)"
  {
    echo '# Copyright 2026 Red Hat, Inc.'
    echo '# SPDX-License-Identifier: Apache-2.0'
    echo
    cat "$file"
  } >"$tmp"
  mv "$tmp" "$file"
}

add_xml_header() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -q "$MARKER" "$file" && return 0
  local tmp
  tmp="$(mktemp)"
  if head -1 "$file" | grep -q '^<?xml'; then
    head -1 "$file" >"$tmp"
    {
      echo '<!--'
      echo '  Copyright 2026 Red Hat, Inc.'
      echo '  SPDX-License-Identifier: Apache-2.0'
      echo '-->'
      echo
      tail -n +2 "$file"
    } >>"$tmp"
  else
    {
      echo '<!--'
      echo '  Copyright 2026 Red Hat, Inc.'
      echo '  SPDX-License-Identifier: Apache-2.0'
      echo '-->'
      echo
      cat "$file"
    } >"$tmp"
  fi
  mv "$tmp" "$file"
}

add_cmd_header() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -q "$MARKER" "$file" && return 0
  local tmp
  tmp="$(mktemp)"
  {
    echo '@REM Copyright 2026 Red Hat, Inc.'
    echo '@REM SPDX-License-Identifier: Apache-2.0'
    echo
    cat "$file"
  } >"$tmp"
  mv "$tmp" "$file"
}

shopt -s nullglob
for f in "$ROOT"/packer/*.hcl "$ROOT"/example.pkrvars.hcl; do
  add_hash_header "$f"
done
for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/*.ps1; do
  add_hash_header "$f"
done
for f in "$ROOT"/http/*.tpl; do
  add_xml_header "$f"
done
for f in "$ROOT"/http/*.ps1; do
  add_hash_header "$f"
done
for f in "$ROOT"/http/*.cmd; do
  add_cmd_header "$f"
done
shopt -u nullglob

echo "License headers applied (or already present)."
