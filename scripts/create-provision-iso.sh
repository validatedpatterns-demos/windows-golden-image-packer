# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Build PROVISION.iso (autounattend.xml + WinRM locators [+ optional VirtIO drivers]).
# Set PROVISION_ISO_SLIM=1 for virtio-blk install: drivers live on a separate VIRTIO-WIN CD.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"
AUTOUNATTEND="${1:-}"
OUT="${OUT:-$ROOT/output/provision.iso}"

if [[ -z "$AUTOUNATTEND" || ! -f "$AUTOUNATTEND" ]]; then
  echo "Usage: $0 /path/to/autounattend.xml" >&2
  echo "Render with: ./scripts/render-autounattend.sh > output/.build-tmp/autounattend.xml" >&2
  exit 1
fi

if [[ "${PROVISION_ISO_SLIM:-0}" != "1" ]]; then
  if [[ ! -f "$ROOT/drivers/viostor/2k22/amd64/viostor.sys" ]]; then
    echo "VirtIO drivers not staged. Run: make stage-virtio" >&2
    exit 1
  fi
fi

if ! command -v xorriso >/dev/null 2>&1; then
  echo "xorriso is required (dnf install xorriso)" >&2
  exit 1
fi

WORKDIR="$(build_mktemp_dir provision-iso.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

cp "$AUTOUNATTEND" "$WORKDIR/autounattend.xml"
cp "$AUTOUNATTEND" "$WORKDIR/unattend.xml"
if [[ "${PROVISION_ISO_SLIM:-0}" != "1" ]]; then
  cp -a "$ROOT/drivers/." "$WORKDIR/"
fi
"$ROOT/scripts/stage-unattend-media-files.sh" "$WORKDIR"

mkdir -p "$(dirname "$OUT")"
xorriso -as mkisofs \
  -rock -joliet -joliet-long \
  -volid PROVISION \
  -o "$OUT" \
  "$WORKDIR"

echo "PROVISION ISO: $OUT"
