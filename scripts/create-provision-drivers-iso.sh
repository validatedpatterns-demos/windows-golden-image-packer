#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# VirtIO drivers only (no autounattend.xml). Used with boot.wim-injected install ISO so
# legacy BIOS Setup does not read a GPT answer file from a second CD-ROM.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/output/provision-drivers.iso}"

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

cp -a "$ROOT/drivers/." "$WORKDIR/"

mkdir -p "$(dirname "$OUT")"
xorriso -as mkisofs \
  -rock -joliet -joliet-long \
  -volid PROVISION \
  -o "$OUT" \
  "$WORKDIR"

echo "PROVISION drivers ISO (no unattend): $OUT"
