# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Boot-test a golden qcow2 without modifying it (overlay disk + libvirt, virtio like CNV).
#
# Usage:
#   boot-test-image.sh [options] [IMAGE.qcow2]
#
# Environment (defaults shown):
#   BOOT_TEST_CONNECT=qemu:///system
#   BOOT_TEST_FIRMWARE=bios          # bios matches default Packer (efi_boot=false); use uefi for UEFI disks
#   BOOT_TEST_MEMORY=8192
#   BOOT_TEST_VCPUS=4
#   BOOT_TEST_WAIT=120             # seconds VM must stay running before guest checks
#   BOOT_TEST_GUEST_WAIT=600       # max seconds to wait for QEMU guest-agent IP
#   BOOT_TEST_CHECK_GUEST=1        # 0 = only verify VM stays up; 1 = also require guest-agent address
#   BOOT_TEST_GRAPHICS=vnc         # vnc or none
#   BOOT_TEST_KEEP_VM=0
#   BOOT_TEST_KEEP_DISK=0
#   VAR_FILE=build.pkrvars.hcl     # used for memory/vcpus when unset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"

CONNECT="${BOOT_TEST_CONNECT:-qemu:///system}"
FIRMWARE="${BOOT_TEST_FIRMWARE:-bios}"
WAIT="${BOOT_TEST_WAIT:-120}"
GUEST_WAIT="${BOOT_TEST_GUEST_WAIT:-600}"
CHECK_GUEST="${BOOT_TEST_CHECK_GUEST:-1}"
GRAPHICS="${BOOT_TEST_GRAPHICS:-vnc}"
KEEP_VM="${BOOT_TEST_KEEP_VM:-0}"
KEEP_DISK="${BOOT_TEST_KEEP_DISK:-0}"
DRY_RUN="${BOOT_TEST_DRY_RUN:-0}"

IMAGE=""
VM_NAME=""

read_hcl() {
  local key="$1"
  [[ -f "$VAR_FILE" ]] || return 0
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$VAR_FILE" | head -1 \
    | sed -E 's/^[^=]+=[[:space:]]*"([^"]+)".*/\1/; s/^[^=]+=[[:space:]]*([^"[:space:]]+).*/\1/'
}

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Options:"
  echo "  --image PATH       qcow2 to test (default: newest golden under output/)"
  echo "  --name NAME        libvirt domain name (default: boot-test-<image-basename>)"
  echo "  --firmware bios|uefi"
  echo "  --memory MB        --vcpus N"
  echo "  --wait SECONDS     --guest-wait SECONDS"
  echo "  --no-guest-check   skip QEMU guest-agent IP check"
  echo "  --graphics vnc|none"
  echo "  --keep-vm --keep-disk"
  echo "  --dry-run"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --name) VM_NAME="$2"; shift 2 ;;
    --firmware) FIRMWARE="$2"; shift 2 ;;
    --memory) export BOOT_TEST_MEMORY="$2"; shift 2 ;;
    --vcpus) export BOOT_TEST_VCPUS="$2"; shift 2 ;;
    --wait) WAIT="$2"; shift 2 ;;
    --guest-wait) GUEST_WAIT="$2"; shift 2 ;;
    --no-guest-check) CHECK_GUEST=0; shift ;;
    --graphics) GRAPHICS="$2"; shift 2 ;;
    --keep-vm) KEEP_VM=1; shift ;;
    --keep-disk) KEEP_DISK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *)
      if [[ -z "$IMAGE" ]]; then
        IMAGE="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$IMAGE" ]]; then
  IMAGE="$("$ROOT/scripts/find-golden-qcow2.sh")"
fi

if [[ ! -f "$IMAGE" ]]; then
  echo "Image not found: $IMAGE" >&2
  exit 1
fi

case "$FIRMWARE" in
  bios|uefi) ;;
  *)
    echo "Invalid --firmware: $FIRMWARE (use bios or uefi)" >&2
    exit 1
    ;;
esac

case "$GRAPHICS" in
  vnc|none) ;;
  *)
    echo "Invalid --graphics: $GRAPHICS (use vnc or none)" >&2
    exit 1
    ;;
esac

IMAGE="$(readlink -f "$IMAGE")"
if [[ "$IMAGE" == *-install.qcow2 ]]; then
  echo "Refusing to boot-test an install-only image: $IMAGE" >&2
  echo "Use the finalized golden image (windows-server-*-standard.qcow2)." >&2
  exit 1
fi

MEMORY="${BOOT_TEST_MEMORY:-$(read_hcl vm_memory)}"
VPUS="${BOOT_TEST_VCPUS:-$(read_hcl vm_cpus)}"
MEMORY="${MEMORY:-8192}"
VPUS="${VPUS:-4}"

if [[ -z "$VM_NAME" ]]; then
  base="$(basename "$IMAGE" .qcow2)"
  VM_NAME="boot-test-${base}"
fi

WORK_DIR=""
TEST_DISK=""

cleanup() {
  local rc=$?
  if [[ "$KEEP_VM" != 1 && -n "$VM_NAME" ]]; then
    virsh --connect "$CONNECT" destroy "$VM_NAME" 2>/dev/null || true
    virsh --connect "$CONNECT" undefine "$VM_NAME" --remove-all-storage 2>/dev/null \
      || virsh --connect "$CONNECT" undefine "$VM_NAME" 2>/dev/null || true
  fi
  if [[ "$KEEP_DISK" != 1 && -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  return "$rc"
}
trap cleanup EXIT

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null || {
      echo "Required command not found: $c" >&2
      exit 1
    }
  done
}

require_cmd virsh virt-install qemu-img stat

if ! virsh --connect "$CONNECT" uri &>/dev/null; then
  echo "Cannot connect to libvirt: $CONNECT" >&2
  exit 1
fi

if [[ "$CONNECT" == qemu:///system ]] && ! virsh --connect "$CONNECT" net-info default &>/dev/null; then
  echo "libvirt network 'default' not found on $CONNECT (needed for virtio NIC)" >&2
  exit 1
fi

ORIG_SIZE="$(stat -c%s "$IMAGE")"
ORIG_MTIME="$(stat -c%Y "$IMAGE")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/boot-test.XXXXXX")"
TEST_DISK="$WORK_DIR/disk.qcow2"

echo "Golden image (read-only backing): $IMAGE"
echo "Test overlay:                  $TEST_DISK"
echo "libvirt:                       $CONNECT"
echo "Domain:                        $VM_NAME"
echo "Firmware:                      $FIRMWARE  |  disk/net: virtio"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "[dry-run] qemu-img create -f qcow2 -F qcow2 -b \"$IMAGE\" \"$TEST_DISK\""
  echo "[dry-run] virt-install --import ... (virtio disk, virtio net, $FIRMWARE)"
  exit 0
fi

qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" "$TEST_DISK" >/dev/null

if virsh --connect "$CONNECT" dominfo "$VM_NAME" &>/dev/null; then
  echo "Removing existing domain $VM_NAME" >&2
  virsh --connect "$CONNECT" destroy "$VM_NAME" 2>/dev/null || true
  virsh --connect "$CONNECT" undefine "$VM_NAME" --remove-all-storage 2>/dev/null \
    || virsh --connect "$CONNECT" undefine "$VM_NAME" 2>/dev/null || true
fi

GRAPHICS_ARGS=(--graphics vnc,listen=127.0.0.1)
[[ "$GRAPHICS" == none ]] && GRAPHICS_ARGS=(--graphics none)

MACHINE="pc"
BOOT_ARGS=(--boot hd)
if [[ "$FIRMWARE" == "uefi" ]]; then
  MACHINE="q35"
  BOOT_ARGS=(--boot uefi)
fi

echo "Starting VM (import, virtio root disk)..." >&2
virt-install --connect "$CONNECT" \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --vcpus "$VPUS" \
  --machine "$MACHINE" \
  --arch x86_64 \
  --osinfo win2k22 \
  --import \
  "${BOOT_ARGS[@]}" \
  --disk "path=${TEST_DISK},bus=virtio,format=qcow2,cache=writeback" \
  --network "network=default,model=virtio" \
  "${GRAPHICS_ARGS[@]}" \
  --noautoconsole

running=0
for _ in $(seq 1 60); do
  state="$(virsh --connect "$CONNECT" domstate "$VM_NAME" 2>/dev/null || true)"
  if [[ "$state" == "running" ]]; then
    running=1
    break
  fi
  sleep 1
done

if [[ "$running" != 1 ]]; then
  echo "FAIL: VM did not reach running state" >&2
  exit 1
fi

echo "VM is running." >&2
if [[ "$GRAPHICS" == vnc ]]; then
  vnc="$(virsh --connect "$CONNECT" vncdisplay "$VM_NAME" 2>/dev/null || true)"
  if [[ -n "$vnc" && "$vnc" != "none" ]]; then
    if [[ "$vnc" == 127.0.0.1:* ]]; then
      port="${vnc##*:}"
      echo "VNC: virt-viewer --connect $CONNECT $VM_NAME  |  vncviewer 127.0.0.1:$((5900 + port))" >&2
    else
      echo "VNC: virt-viewer --connect $CONNECT $VM_NAME  (display $vnc)" >&2
    fi
  fi
fi

echo "Waiting ${WAIT}s to confirm the guest stays up..." >&2
sleep "$WAIT"

state="$(virsh --connect "$CONNECT" domstate "$VM_NAME" 2>/dev/null || true)"
if [[ "$state" != "running" ]]; then
  echo "FAIL: VM is not running after ${WAIT}s (state=${state:-unknown})" >&2
  exit 1
fi

guest_ok=0
if [[ "$CHECK_GUEST" == 1 ]]; then
  echo "Waiting up to ${GUEST_WAIT}s for QEMU guest-agent network address..." >&2
  deadline=$((SECONDS + GUEST_WAIT))
  while ((SECONDS < deadline)); do
    if [[ "$state" != "running" ]]; then
      break
    fi
    mapfile -t addrs < <(virsh --connect "$CONNECT" domifaddr "$VM_NAME" --source agent 2>/dev/null \
      | awk '/ipv4/ {print $4}' | cut -d/ -f1 || true)
    if ((${#addrs[@]} > 0)); then
      guest_ok=1
      echo "Guest agent reported address(es): ${addrs[*]}" >&2
      break
    fi
    sleep 10
    state="$(virsh --connect "$CONNECT" domstate "$VM_NAME" 2>/dev/null || true)"
  done
  if [[ "$guest_ok" != 1 ]]; then
    echo "FAIL: no guest-agent IPv4 within ${GUEST_WAIT}s (VM state: ${state:-unknown})" >&2
    echo "Hint: first boot after sysprep can take several minutes; increase BOOT_TEST_GUEST_WAIT." >&2
    exit 1
  fi
else
  guest_ok=1
fi

NEW_SIZE="$(stat -c%s "$IMAGE")"
NEW_MTIME="$(stat -c%Y "$IMAGE")"
if [[ "$NEW_SIZE" != "$ORIG_SIZE" || "$NEW_MTIME" != "$ORIG_MTIME" ]]; then
  echo "FAIL: golden image file changed on disk (size or mtime)" >&2
  echo "  before: size=$ORIG_SIZE mtime=$ORIG_MTIME" >&2
  echo "  after:  size=$NEW_SIZE mtime=$NEW_MTIME" >&2
  exit 1
fi

echo "PASS: boot test succeeded for $IMAGE"
echo "  VM stayed running for ${WAIT}s"
if [[ "$CHECK_GUEST" == 1 ]]; then
  echo "  QEMU guest agent reported an IP"
fi
echo "  Golden image file unchanged (overlay writes did not touch the backing file)"
