# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Create stub ISO/qcow2 paths and a minimal drivers/ tree for `packer validate` / CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKER_DIR="$ROOT/packer"
DRIVERS="$ROOT/drivers"

mkdir -p \
  "$DRIVERS/viostor/2k22/amd64" \
  "$DRIVERS/viostor/2k25/amd64" \
  "$DRIVERS/vioscsi/2k22/amd64" \
  "$DRIVERS/vioscsi/2k25/amd64" \
  "$DRIVERS/NetKVM/2k22/amd64" \
  "$DRIVERS/NetKVM/2k25/amd64" \
  "$DRIVERS/guest-agent"

# Placeholder files (validate checks paths exist; real builds use `make stage-virtio`).
for pair in \
  viostor:viostor \
  vioscsi:vioscsi \
  NetKVM:netkvm; do
  component="${pair%%:*}"
  base="${pair##*:}"
  for osdir in 2k22 2k25; do
    dir="$DRIVERS/$component/$osdir/amd64"
    touch "$dir/$base.inf" "$dir/$base.sys"
  done
done

touch "$DRIVERS/guest-agent/qemu-ga-x86_64.msi"
touch "$PACKER_DIR/ci-stub.iso" "$PACKER_DIR/ci-stub.qcow2"

echo "CI validate stubs ready under $DRIVERS and $PACKER_DIR/ci-stub.*"
