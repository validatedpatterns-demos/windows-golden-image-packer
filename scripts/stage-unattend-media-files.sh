#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Copy autounattend support files (WinRM locators) into a staging directory.
# Used by create-provision-iso.sh and create-unattend-floppy-image.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?destination directory required}"

mkdir -p "$DEST"

for f in enable-winrm.ps1 enable-winrm.cmd enable-winrm-locator.cmd; do
  cp "$ROOT/http/$f" "$DEST/"
done

for f in clear-autologon.ps1 post-install.ps1; do
  cp "$ROOT/scripts/$f" "$DEST/"
done
