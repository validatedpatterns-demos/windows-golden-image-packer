#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Build PROVISION ISO for pass 2 (Packer provision on virtio-blk install disk).
# Scripts and drivers are copied from the CD inside the guest to avoid WinRM bulk upload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"
OUT="${OUT:-$ROOT/output/provision-pass.iso}"
VERSION="${VERSION:-}"

if [[ -n "$VERSION" ]]; then
  virtio_os_dir=2k22
  if [[ "$VERSION" == "2025" ]]; then
    virtio_os_dir=2k25
  fi
  if [[ ! -f "$ROOT/drivers/viostor/$virtio_os_dir/amd64/viostor.sys" ]]; then
    echo "VirtIO drivers not staged for $virtio_os_dir. Run: STAGE_FORCE=1 make stage-virtio" >&2
    exit 1
  fi
elif [[ ! -f "$ROOT/drivers/viostor/2k22/amd64/viostor.sys" ]] || [[ ! -f "$ROOT/drivers/viostor/2k25/amd64/viostor.sys" ]]; then
  echo "VirtIO drivers not staged for 2k22 and 2k25. Run: STAGE_FORCE=1 make stage-virtio" >&2
  exit 1
fi

if ! command -v xorriso >/dev/null 2>&1; then
  echo "xorriso is required (dnf install xorriso)" >&2
  exit 1
fi

WORKDIR="$(build_mktemp_dir provision-pass-iso.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

cp -a "$ROOT/scripts" "$WORKDIR/scripts"
cp -a "$ROOT/drivers" "$WORKDIR/drivers"
cp "$ROOT/scripts/stage-provision-from-cd.ps1" "$WORKDIR/"
cp "$ROOT/scripts/run-provision-pass.ps1" "$WORKDIR/scripts/"
cp "$ROOT/http/oobe-info-defaults.xml" "$WORKDIR/scripts/oobe-info-defaults.xml"
"$ROOT/scripts/stage-unattend-media-files.sh" "$WORKDIR"

mkdir -p "$(dirname "$OUT")"
xorriso -as mkisofs \
  -rock -joliet -joliet-long \
  -volid PROVISION \
  -o "$OUT" \
  "$WORKDIR"

echo "PROVISION pass ISO: $OUT"
