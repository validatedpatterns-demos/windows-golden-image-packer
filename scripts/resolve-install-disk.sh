#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Resolve the virt-install pass-1 disk under a staging directory.
# Usage: resolve-install-disk.sh STAGING_DIR VERSION [edition_lc]
# Prints absolute path on success; exits 1 with a clear message if missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="${1:?staging directory required}"
VERSION="${2:?VERSION required}"
EDITION_LC="${3:-$(echo "${WINDOWS_EDITION:-Standard}" | tr '[:upper:]' '[:lower:]')}"

if [[ "$STAGING" != /* ]]; then
  STAGING="$ROOT/$STAGING"
fi

base="$STAGING/packer-win${VERSION}-${EDITION_LC}-install"
if [[ -f "${base}.qcow2" ]]; then
  readlink -f "${base}.qcow2"
elif [[ -f "$base" ]]; then
  readlink -f "$base"
else
  echo "ERROR: Install disk not found under $STAGING" >&2
  echo "  Expected: ${base}.qcow2 (from virt-install pass 1)" >&2
  echo "  Also tried: $base" >&2
  echo "Re-run without SKIP_INSTALL=1 to install Windows (~45 min), or set BASE_IMAGE= to an existing qcow2." >&2
  exit 1
fi
