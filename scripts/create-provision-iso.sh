# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Build PROVISION.iso (autounattend.xml + staged VirtIO drivers) for manual installs.
# UEFI virt-install uses create-provision-drivers-iso.sh + inject-autounattend-into-windows-iso.sh instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUTOUNATTEND="${1:-}"
OUT="${OUT:-$ROOT/output/provision.iso}"

if [[ -z "$AUTOUNATTEND" || ! -f "$AUTOUNATTEND" ]]; then
  echo "Usage: $0 /path/to/autounattend.xml" >&2
  echo "Render with: ./scripts/render-autounattend.sh > /tmp/autounattend.xml" >&2
  exit 1
fi

if [[ ! -f "$ROOT/drivers/viostor/2k22/amd64/viostor.sys" ]]; then
  echo "VirtIO drivers not staged. Run: make stage-virtio" >&2
  exit 1
fi

if ! command -v xorriso >/dev/null 2>&1; then
  echo "xorriso is required (dnf install xorriso)" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cp "$AUTOUNATTEND" "$WORKDIR/autounattend.xml"
cp "$AUTOUNATTEND" "$WORKDIR/unattend.xml"
cp -a "$ROOT/drivers/." "$WORKDIR/"
"$ROOT/scripts/stage-unattend-media-files.sh" "$WORKDIR"

mkdir -p "$(dirname "$OUT")"
xorriso -as mkisofs \
  -rock -joliet -joliet-long \
  -volid PROVISION \
  -o "$OUT" \
  "$WORKDIR"

echo "PROVISION ISO: $OUT"
