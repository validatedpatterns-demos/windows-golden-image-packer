#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Check Sysprep_succeeded.tag on a qcow2 without booting the guest.
# Use this after sysprep generalize — new WinRM sessions fail with NTLM/401 even when
# admin_password is correct (see wait-packer-qemu-exit.sh).
#
# Do not run against a qcow2 that QEMU still has open; copy the work disk or stop the VM first.
#
# Usage: verify-sysprep-succeeded-offline.sh /path/to/image.qcow2
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"

TAG_PATH='/Windows/System32/Sysprep/Sysprep_succeeded.tag'

IMAGE="${1:-}"
if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "Usage: $0 /path/to/image.qcow2" >&2
  exit 1
fi

if ! command -v guestfish >/dev/null 2>&1; then
  echo "guestfish not found (install libguestfs-tools)" >&2
  exit 1
fi

IMAGE="$(readlink -f "$IMAGE")"

if pgrep -af "qemu-system-x86_64.*${IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: QEMU is using $IMAGE — stop the VM or verify via VNC instead." >&2
  echo "  VNC: scripts/show-packer-console.sh" >&2
  exit 2
fi

if libguestfs_direct guestfish --ro -a "$IMAGE" -i is-file "$TAG_PATH" >/dev/null 2>&1; then
  echo "OK: Sysprep_succeeded.tag present in $IMAGE"
  exit 0
fi

echo "FAIL: Sysprep_succeeded.tag not found at $TAG_PATH in $IMAGE" >&2
exit 1
