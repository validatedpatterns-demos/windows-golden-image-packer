# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Open the graphical console for a libvirt domain (virt-viewer or remote-viewer).
# Usage: open-vm-console.sh [--background] <connect-uri> <domain-name>
set -euo pipefail

BACKGROUND=0
if [[ "${1:-}" == "--background" ]]; then
  BACKGROUND=1
  shift
fi

CONNECT="${1:-qemu:///system}"
DOMAIN="${2:?domain name required}"

run_viewer() {
  if command -v virt-viewer >/dev/null 2>&1; then
    virt-viewer --connect "$CONNECT" "$DOMAIN"
    return 0
  fi
  if command -v remote-viewer >/dev/null 2>&1; then
    remote-viewer --connect "$CONNECT" "$DOMAIN"
    return 0
  fi
  echo "virt-viewer not found (install virt-viewer or virt-manager)" >&2
  return 1
}

if [[ "$BACKGROUND" == 1 ]]; then
  run_viewer >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "Console: virt-viewer --connect $CONNECT $DOMAIN" >&2
else
  run_viewer
fi
