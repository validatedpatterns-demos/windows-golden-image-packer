# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Extract VirtIO drivers from virtio-win.iso into drivers/ (WinPE + provision CD).
# Always stage both 2k22 and 2k25: one shared drivers/ tree supports sequential 2022 + 2025 builds.
# Each Packer run installs only the matching OS dir (see packer/locals.pkr.hcl virtio_os_dir).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"
ISO="${1:-$ROOT/downloads/virtio-win.iso}"
DRIVERS="${DRIVERS:-$ROOT/drivers}"
READY_MARKER="${READY_MARKER:-$ROOT/extras/.virtio-win-staged.ready}"
# virtio-win ships many OS trees; staging all of them is ~500MB+ and breaks WinRM file upload.
STAGE_OS_DIRS="${STAGE_OS_DIRS:-2k22 2k25}"

if [[ ! -f "$ISO" ]]; then
  echo "virtio-win ISO not found: $ISO" >&2
  echo "Run: make download-virtio" >&2
  exit 1
fi

drivers_ready() {
  [[ -f "$DRIVERS/viostor/2k22/amd64/viostor.sys" ]] && \
    [[ -f "$DRIVERS/NetKVM/2k22/amd64/netkvm.sys" ]] && \
    [[ -f "$DRIVERS/guest-agent/qemu-ga-x86_64.msi" ]] && \
    [[ -f "$DRIVERS/virtio-win-gt-x64.msi" ]]
}

if [[ "${STAGE_FORCE:-0}" != "1" ]] && drivers_ready; then
  touch "$READY_MARKER"
  echo "VirtIO drivers already staged under $DRIVERS (set STAGE_FORCE=1 to refresh)"
  exit 0
fi

EXTRACT_TMP="$(build_mktemp_dir virtio-extract.XXXXXX)"
trap 'rm -rf "$EXTRACT_TMP"' EXIT

echo "Extracting virtio-win (7z resolves hardlinks)..."
if command -v 7z >/dev/null 2>&1; then
  7z x -y "-o${EXTRACT_TMP}" "$ISO" \
    viostor NetKVM vioscsi Balloon guest-agent virtio-win-gt-x64.msi >/dev/null
else
  echo "7z is required to extract virtio-win.iso on this host (install p7zip)." >&2
  exit 1
fi

if [[ ! -f "$EXTRACT_TMP/viostor/2k22/amd64/viostor.sys" ]]; then
  echo "Extract missing viostor/2k22/amd64/viostor.sys" >&2
  exit 1
fi

if [[ -d "$DRIVERS" ]]; then
  chmod -R u+rwX "$DRIVERS" 2>/dev/null || true
  if ! rm -rf "$DRIVERS" 2>/dev/null; then
    orphan="${DRIVERS}.orphan.$(date +%s)"
    mv "$DRIVERS" "$orphan" || {
      echo "Cannot replace $DRIVERS; remove it manually and re-run." >&2
      exit 1
    }
    echo "Moved old drivers tree to $orphan"
  fi
fi

mkdir -p "$DRIVERS"
for component in viostor NetKVM vioscsi Balloon; do
  for osdir in $STAGE_OS_DIRS; do
    src="${EXTRACT_TMP}/${component}/${osdir}/amd64"
    if [[ -d "$src" ]]; then
      mkdir -p "${DRIVERS}/${component}/${osdir}"
      cp -a "$src" "${DRIVERS}/${component}/${osdir}/"
    fi
  done
done

if [[ -d "$EXTRACT_TMP/guest-agent" ]]; then
  cp -a "$EXTRACT_TMP/guest-agent" "$DRIVERS/"
fi

if [[ -f "$EXTRACT_TMP/virtio-win-gt-x64.msi" ]]; then
  cp -a "$EXTRACT_TMP/virtio-win-gt-x64.msi" "$DRIVERS/"
fi

find "$DRIVERS" -name '*.pdb' -delete 2>/dev/null || true

chmod -R a+rX "$DRIVERS"
touch "$READY_MARKER"
echo "Staged VirtIO drivers (slim): $DRIVERS"
du -sh "$DRIVERS" 2>/dev/null || true
