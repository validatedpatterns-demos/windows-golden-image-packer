#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Stop stale Packer QEMU VMs that reuse the same -name (blocks new builds and wait loops).
# Usage: stop-stale-packer-qemu.sh VM_NAME
set -euo pipefail

VM_NAME="${1:?VM_NAME required}"

pids="$(pgrep -f "qemu-system-x86_64.*${VM_NAME}" 2>/dev/null || true)"
if [[ -z "$pids" ]]; then
  exit 0
fi

echo "Stopping stale Packer QEMU for $VM_NAME..." >&2
while read -r pid; do
  [[ -n "$pid" ]] || continue
  echo "  SIGTERM pid $pid" >&2
  kill -TERM "$pid" 2>/dev/null || true
done <<< "$pids"

for _ in $(seq 1 15); do
  pids="$(pgrep -f "qemu-system-x86_64.*${VM_NAME}" 2>/dev/null || true)"
  [[ -z "$pids" ]] && exit 0
  sleep 1
done

while read -r pid; do
  [[ -n "$pid" ]] || continue
  echo "  SIGKILL pid $pid" >&2
  kill -KILL "$pid" 2>/dev/null || true
done <<< "$pids"
