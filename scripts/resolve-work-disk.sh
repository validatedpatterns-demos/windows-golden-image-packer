#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Resolve the Packer provision work disk under a staging work/ directory.
# Usage: resolve-work-disk.sh WORK_DIR VERSION [edition_lc]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${1:?work directory required}"
VERSION="${2:?VERSION required}"
EDITION_LC="${3:-$(echo "${WINDOWS_EDITION:-Standard}" | tr '[:upper:]' '[:lower:]')}"

if [[ "$WORK_DIR" != /* ]]; then
  WORK_DIR="$ROOT/$WORK_DIR"
fi

shopt -s nullglob
for candidate in \
  "$WORK_DIR/packer-win${VERSION}-${EDITION_LC}-provision" \
  "$WORK_DIR/packer-win${VERSION}-${EDITION_LC}-provision.qcow2" \
  "$WORK_DIR/packer-win${VERSION}-${EDITION_LC}" \
  "$WORK_DIR/packer-win${VERSION}-${EDITION_LC}.qcow2"; do
  if [[ -f "$candidate" ]]; then
    readlink -f "$candidate"
    shopt -u nullglob
    exit 0
  fi
done
shopt -u nullglob

echo "ERROR: Provision work disk not found under $WORK_DIR" >&2
echo "  Expected: packer-win${VERSION}-${EDITION_LC}-provision[.qcow2]" >&2
exit 1
