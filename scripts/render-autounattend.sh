# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Render autounattend.xml from Packer HCL (uses same templates/vars as packer build).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKER_DIR="$ROOT/packer"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
# Match the Windows release under test (same as make build-version VERSION=...).
VERSION="${VERSION:-2022}"
UEFI="${UEFI:-1}"

if [[ ! -f "$VAR_FILE" ]]; then
  echo "Var file not found: $VAR_FILE (copy example.pkrvars.hcl to build.pkrvars.hcl)" >&2
  exit 1
fi

cd "$PACKER_DIR"
packer init -upgrade . >/dev/null

EFI_FLAG="-var=efi_boot=true"
if [[ "$UEFI" != "1" ]]; then
  EFI_FLAG="-var=efi_boot=false"
fi

# shellcheck disable=SC2016
packer console -var-file="../$(basename "$VAR_FILE")" -var "windows_version=${VERSION}" $EFI_FLAG . <<'EOF' | sed -n '/^<?xml/,/^<\/unattend>/p'
local.autounattend
EOF
