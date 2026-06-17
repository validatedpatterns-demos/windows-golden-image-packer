#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Preflight a qcow2 before pass 2 (build-provision-only / recover-provision).
# Fails fast when the image was sysprepped or WinRM was never configured.
#
# Usage: verify-provision-base-image.sh /path/to/install-or-salvage.qcow2
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"

IMAGE="${1:-}"
if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "Usage: $0 /path/to/image.qcow2" >&2
  exit 1
fi

IMAGE="$(readlink -f "$IMAGE")"

if [[ "$IMAGE" == *"/work/"* ]]; then
  echo "ERROR: Do not use a disk under work/ as BASE_IMAGE (packer -force deletes work/)." >&2
  echo "Run: EXECUTE=1 make recover-provision VERSION=..." >&2
  exit 1
fi

if ! command -v guestfish >/dev/null 2>&1; then
  echo "WARN: guestfish not installed; skipping offline base-image checks" >&2
  exit 0
fi

if pgrep -af "qemu-system-x86_64.*${IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: QEMU is using $IMAGE — stop the VM before provisioning." >&2
  exit 2
fi

TAG_PATH='/Windows/System32/Sysprep/Sysprep_succeeded.tag'
if libguestfs_direct guestfish --ro -a "$IMAGE" -i is-file "$TAG_PATH" 2>/dev/null | grep -qx true; then
  echo "ERROR: $IMAGE is already sysprepped (Sysprep_succeeded.tag present)." >&2
  echo "Use a fresh install disk from pass 1, not a golden or post-sysprep image." >&2
  exit 1
fi

tmp_hive="$(mktemp)"
trap 'rm -f "$tmp_hive"' EXIT
if ! libguestfs_direct guestfish --ro -a "$IMAGE" -i download /Windows/System32/config/SYSTEM "$tmp_hive" 2>/dev/null; then
  echo "WARN: Could not read SYSTEM hive from $IMAGE; skipping WinRM check" >&2
  exit 0
fi

if ! command -v hivexget >/dev/null 2>&1; then
  echo "WARN: hivexget not installed; skipping WinRM service check" >&2
  exit 0
fi

winrm_start="$(hivexget "$tmp_hive" '\ControlSet001\Services\WinRM' Start 2>/dev/null || true)"
if [[ "$winrm_start" != "2" ]]; then
  echo "ERROR: WinRM service is not set to Automatic (Start=$winrm_start) on $IMAGE." >&2
  echo "Re-run pass 1 install or use an install disk that completed specialize WinRM setup." >&2
  exit 1
fi

if libguestfs_direct guestfish --ro -a "$IMAGE" -i is-file /Windows/Temp/sysprep.ps1 2>/dev/null | grep -qx true; then
  echo "WARN: $IMAGE already has C:\\Windows\\Temp\\sysprep.ps1 (partial provision?)." >&2
  echo "      Prefer recover-provision salvage copy or a fresh install disk." >&2
fi

echo "OK: $IMAGE is suitable for pass 2 provision (not sysprepped, WinRM Automatic)."
