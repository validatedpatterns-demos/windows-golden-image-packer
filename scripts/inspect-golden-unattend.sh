#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Read C:\Windows\Panther\unattend.xml from a golden qcow2 (offline) to confirm sysprep OOBE locale settings.
set -euo pipefail

IMAGE="${1:-}"
if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "Usage: $0 /path/to/windows-server-*.qcow2" >&2
  exit 1
fi

if ! command -v guestfish >/dev/null 2>&1; then
  echo "guestfish not found (install libguestfs-tools)" >&2
  exit 1
fi

IMAGE="$(readlink -f "$IMAGE")"
echo "Inspecting $IMAGE" >&2

unattend="$(guestfish -a "$IMAGE" -i <<'EOF'
cat /Windows/Panther/unattend.xml
EOF
)" || {
  echo "ERROR: Could not read /Windows/Panther/unattend.xml from image" >&2
  exit 1
}

if printf '%s\n' "$unattend" | grep -q 'pass="windowsPE"'; then
  echo "FAIL: Panther unattend is the install answer file (contains windowsPE pass)." >&2
  echo "      Provision/sysprep did not replace it with sysprep-oobe.xml." >&2
  exit 1
fi

if printf '%s\n' "$unattend" | grep -q 'pass="oobeSystem" wasPassProcessed="true"'; then
  echo "FAIL: Panther unattend oobeSystem was already processed (install autounattend)." >&2
  exit 1
fi

if ! printf '%s\n' "$unattend" | grep -q 'Microsoft-Windows-International-Core'; then
  echo "FAIL: Panther unattend has no Microsoft-Windows-International-Core (locale OOBE will prompt)." >&2
  exit 1
fi

if printf '%s\n' "$unattend" | grep -q 'WIN-PACKER'; then
  echo "FAIL: Panther unattend is still install autounattend.xml (ComputerName WIN-PACKER)." >&2
  exit 1
fi

if printf '%s\n' "$unattend" | grep -q '<Enabled>true</Enabled>'; then
  echo "FAIL: Panther unattend has AutoLogon enabled (install file, not sysprep-oobe.xml)." >&2
  exit 1
fi

echo "OK: Panther unattend.xml looks like sysprep OOBE locale configuration" >&2
