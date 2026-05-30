#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Move the MBR provision work disk out of work/ before the OVMF sysprep pass.
# Packer -force deletes output_directory (work/) at the start of each build.
# Usage: stage-provision-prep-disk.sh STAGING_DIR VERSION [edition_lc]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="${1:?staging directory required}"
VERSION="${2:?VERSION required}"
EDITION_LC="${3:-$(echo "${WINDOWS_EDITION:-Standard}" | tr '[:upper:]' '[:lower:]')}"

if [[ "$STAGING" != /* ]]; then
  STAGING="$ROOT/$STAGING"
fi

work_disk="$("$ROOT/scripts/resolve-work-disk.sh" "$STAGING/work" "$VERSION" "$EDITION_LC")"
dest="$STAGING/packer-win${VERSION}-${EDITION_LC}-provision-prep.qcow2"

if [[ -f "$dest" ]]; then
  rm -f "$dest"
fi

echo "Staging prep disk for OVMF sysprep: $dest" >&2
mv -f "$work_disk" "$dest"
readlink -f "$dest"
