#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# OVMF sysprep-only Packer pass (after MBR prep). BASE_IMAGE must not live under work/.
# Usage: run-packer-provision-sysprep.sh BASE_IMAGE STAGING_DIR [VERSION]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_IMAGE="${1:?BASE_IMAGE required}"
STAGING="${2:?staging directory required}"
VERSION="${3:-}"

if [[ "$BASE_IMAGE" != /* ]]; then
  BASE_IMAGE="$ROOT/$BASE_IMAGE"
fi
if [[ "$STAGING" != /* ]]; then
  STAGING="$ROOT/$STAGING"
fi

case "$BASE_IMAGE" in
  */work/*)
    echo "ERROR: BASE_IMAGE must not be under work/ — packer -force deletes that directory." >&2
    exit 1
    ;;
esac
[[ -f "$BASE_IMAGE" ]] || { echo "ERROR: BASE_IMAGE not found: $BASE_IMAGE" >&2; exit 1; }

if [[ -z "$VERSION" ]]; then
  VERSION="$(echo "$BASE_IMAGE" | sed -n 's|.*/\.packer-\([0-9][0-9][0-9][0-9]\)/.*|\1|p')"
fi
[[ -n "$VERSION" ]] || { echo "ERROR: could not infer VERSION from BASE_IMAGE" >&2; exit 1; }

PACKER_DIR="$ROOT/packer"
VAR_FILE="${VAR_FILE:-build.pkrvars.hcl}"
if [[ "$VAR_FILE" != /* ]]; then
  VAR_FILE="$ROOT/$VAR_FILE"
fi
[[ -f "$VAR_FILE" ]] || {
  echo "Var file not found: $VAR_FILE (copy example.pkrvars.hcl to build.pkrvars.hcl)" >&2
  exit 1
}
VAR_FILE_FLAG="-var-file=$VAR_FILE"
PACKER_ON_ERROR="${PACKER_ON_ERROR:-abort}"
WINDOWS_EDITION="${WINDOWS_EDITION:-Standard}"
WORK_DIR="$STAGING/work"
mkdir -p "$WORK_DIR"

BUILD_SCHEDULE_LOG="${BUILD_SCHEDULE_LOG:-$STAGING/build-schedule.log}"
BUILD_SCHEDULE_LOG="$BUILD_SCHEDULE_LOG" "$ROOT/scripts/print-build-schedule.sh" provision-gpt-sysprep
echo ""
echo "=== OVMF sysprep (GPT disk, BCD generalize requires UEFI firmware) ==="
echo "  Prep disk: $BASE_IMAGE"
echo "  Packer work directory: $WORK_DIR"
echo "  While the VM runs: ./scripts/show-packer-console.sh  (VNC port + work path)"
echo "  Sysprep normally finishes in 10-25 minutes; setupact.log tails every 60s after 'Running sysprep'."
echo "  If sysprep exceeds 45 minutes it fails with diagnostics (SYSPREP_TIMEOUT_MINUTES to override)."
echo ""

cd "$PACKER_DIR"
packer build -force -on-error="$PACKER_ON_ERROR" "$VAR_FILE_FLAG" \
  -var "windows_version=$VERSION" \
  -var "windows_edition=$WINDOWS_EDITION" \
  -var "base_image_path=$BASE_IMAGE" \
  -var "output_directory=$WORK_DIR" \
  -only=windows-golden-provision-gpt-sysprep.qemu.from_install_gpt \
  .
