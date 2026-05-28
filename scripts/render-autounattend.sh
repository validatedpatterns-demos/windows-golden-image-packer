#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Render autounattend.xml from Packer HCL (same templates/vars as packer build).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKER_DIR="$ROOT/packer"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
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

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

# shellcheck disable=SC2016
packer console -var-file="../$(basename "$VAR_FILE")" -var "windows_version=${VERSION}" $EFI_FLAG . <<'EOF' | sed -n '/^<?xml/,/^<\/unattend>/p' >"$rendered"
local.autounattend
EOF

if grep -q '<sensitive>' "$rendered"; then
  echo "ERROR: render-autounattend produced invalid XML (<sensitive> placeholders)." >&2
  echo "Packer console redacts sensitive variables; product_key_* and admin_password must not be sensitive in packer/variables.pkr.hcl." >&2
  exit 1
fi

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$rendered" >&2
fi

cat "$rendered"
