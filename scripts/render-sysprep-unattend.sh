#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Render sysprep answer files (same as Packer uploads to C:\Windows\Temp\).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
VERSION="${VERSION:-2022}"
# shellcheck source=scripts/resolve-packer.sh
source "$ROOT/scripts/resolve-packer.sh"
PACKER_BIN="$(resolve_packer)"

cd "$ROOT/packer"
render() {
  local local_name="$1"
  "$PACKER_BIN" console -var-file="../$(basename "$VAR_FILE")" -var "windows_version=${VERSION}" . <<EOF | sed -n '/^<?xml/,/^<\/unattend>/p'
${local_name}
EOF
}

echo "=== sysprep-oobe.xml (Panther\\unattend.xml on first boot) ==="
render local.sysprep_oobe_unattend
echo
echo "=== sysprep-generalize.xml (sysprep.exe /unattend) ==="
render local.sysprep_generalize_unattend
