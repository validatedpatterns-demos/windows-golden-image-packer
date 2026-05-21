#!/usr/bin/env bash
# Download virtio-win ISO for QEMU/KubeVirt Windows builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${DEST_DIR:-$ROOT/downloads}"
mkdir -p "$DEST_DIR"

download_virtio() {
  local base_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads"
  local iso_url="${base_url}/stable-virtio/virtio-win.iso"
  local dest="${DEST_DIR}/virtio-win.iso"

  if [[ -f "$dest" ]]; then
    echo "virtio-win ISO already present: $dest"
    return 0
  fi

  echo "Downloading virtio-win ISO to $dest"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$dest" "$iso_url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$iso_url"
  else
    echo "curl or wget required" >&2
    exit 1
  fi

  echo "Downloaded: $dest"
  echo "Set virtio_win_iso_path = \"$dest\" in build.pkrvars.hcl (used for staging drivers/ only)"

  if [[ -x "$ROOT/scripts/stage-virtio-drivers.sh" ]]; then
    "$ROOT/scripts/stage-virtio-drivers.sh" "$dest"
  fi
}

case "${1:-virtio}" in
  virtio) download_virtio ;;
  *)
    echo "Usage: $0 virtio" >&2
    exit 1
    ;;
esac
