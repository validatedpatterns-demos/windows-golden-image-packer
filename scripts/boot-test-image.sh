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
#   BOOT_TEST_FIRMWARE=uefi          # default: matches efi_boot in build.pkrvars.hcl (uefi for OpenShift)
#   BOOT_TEST_MEMORY=8192
#   BOOT_TEST_VCPUS=4
#   BOOT_TEST_WAIT=120             # seconds VM must stay running before guest checks
#   BOOT_TEST_GUEST_WAIT=600       # max seconds to wait for QEMU guest-agent IP
#   BOOT_TEST_CHECK_GUEST=1        # 0 = only verify VM stays up; 1 = also require guest-agent address
#   BOOT_TEST_GRAPHICS=vnc         # vnc or none
#   BOOT_TEST_SHOW_CONSOLE=1       # 0 = do not launch virt-viewer
#   BOOT_TEST_DISK_BUS=scsi        # UEFI default: virtio-scsi (OVMF does not boot virtio-blk)
#   BOOT_TEST_KEEP_VM=0
#   BOOT_TEST_KEEP_DISK=0
#   BOOT_TEST_WORK_DIR=$HOME/VirtualMachines   # overlay qcow2 directory (needs free space)
#   VAR_FILE=build.pkrvars.hcl     # used for memory/vcpus when unset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"

CONNECT="${BOOT_TEST_CONNECT:-qemu:///system}"

default_firmware() {
  local efi
  efi="$("$ROOT/scripts/read-pkrvar.sh" efi_boot "$VAR_FILE" true)"
  if [[ "$efi" == "true" ]]; then
    echo uefi
  else
    echo bios
  fi
}

FIRMWARE="${BOOT_TEST_FIRMWARE:-$(default_firmware)}"
WAIT="${BOOT_TEST_WAIT:-180}"
GUEST_WAIT="${BOOT_TEST_GUEST_WAIT:-600}"
CHECK_GUEST="${BOOT_TEST_CHECK_GUEST:-1}"
GRAPHICS="${BOOT_TEST_GRAPHICS:-vnc}"
SHOW_CONSOLE="${BOOT_TEST_SHOW_CONSOLE:-1}"
KEEP_VM="${BOOT_TEST_KEEP_VM:-0}"
KEEP_DISK="${BOOT_TEST_KEEP_DISK:-0}"
DRY_RUN="${BOOT_TEST_DRY_RUN:-0}"
WORK_BASE="${BOOT_TEST_WORK_DIR:-$HOME/VirtualMachines}"

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
  echo "  --no-console       do not open virt-viewer"
  echo "  --disk-bus virtio|sata   root disk bus (default: virtio)"
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
    --disk-bus) DISK_BUS="$2"; shift 2 ;;
    --no-console) SHOW_CONSOLE=0; shift ;;
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

if [[ -z "$DISK_BUS" ]]; then
  if [[ "$FIRMWARE" == "uefi" ]]; then
    DISK_BUS="${BOOT_TEST_DISK_BUS:-$(default_uefi_disk_bus)}"
  else
    DISK_BUS="${BOOT_TEST_DISK_BUS:-virtio}"
  fi
fi

case "$DISK_BUS" in
  scsi|sata|virtio) ;;
  *)
    echo "Invalid disk bus: $DISK_BUS (use scsi, sata, or virtio)" >&2
    exit 1
    ;;
esac

if [[ "$FIRMWARE" == "uefi" ]]; then
  golden_image_has_efi_partition "$IMAGE"
  efi_rc=$?
  if [[ "$efi_rc" -eq 1 ]]; then
    echo "ERROR: $IMAGE has no EFI system partition but boot-test uses UEFI." >&2
    echo "Rebuild with efi_boot=true, or use --firmware bios for SeaBIOS images." >&2
    "$ROOT/scripts/inspect-golden-qcow2.sh" "$IMAGE" >&2 || true
    exit 1
  elif [[ "$efi_rc" -eq 2 ]]; then
    echo "WARN: could not inspect partitions (install libguestfs-tools for preflight checks)" >&2
  fi
fi

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
    virsh --connect "$CONNECT" undefine "$VM_NAME" 2>/dev/null || true
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

libvirt_qemu_user() {
  local u
  if [[ -r /etc/libvirt/qemu.conf ]]; then
    u="$(awk -F= '/^[[:space:]]*user[[:space:]]*=/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      gsub(/"/, "", $2)
      if ($2 !~ /^\+/) { print $2; exit }
    }' /etc/libvirt/qemu.conf)"
  fi
  if [[ -z "${u:-}" ]] || ! getent passwd "$u" &>/dev/null; then
    u="qemu"
  fi
  echo "$u"
}

libvirt_uses_system_qemu() {
  [[ "$CONNECT" == qemu://* && "$CONNECT" != *session* ]]
}

grant_qemu_traverse_parents() {
  local qemu_user="$1" target="$2" dir
  target="$(readlink -f "$target")"
  if [[ -f "$target" ]]; then
    dir="$(dirname "$target")"
  else
    dir="$target"
  fi
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if ! setfacl -m "u:${qemu_user}:x" "$dir"; then
      echo "Failed to grant $qemu_user traverse on $dir (install acl?)" >&2
      return 1
    fi
    dir="$(dirname "$dir")"
  done
}

grant_qemu_system_storage_access() {
  local qemu_user disk backing disk_dir
  command -v setfacl >/dev/null || {
    echo "setfacl is required for $CONNECT when disks are under your home directory." >&2
    echo "Install the acl package, or set BOOT_TEST_CONNECT=qemu:///session to run VMs as your user." >&2
    exit 1
  }
  qemu_user="$(libvirt_qemu_user)"
  disk="$(readlink -f "$1")"
  backing="$(readlink -f "$2")"
  grant_qemu_traverse_parents "$qemu_user" "$disk" || exit 1
  grant_qemu_traverse_parents "$qemu_user" "$backing" || exit 1
  disk_dir="$(dirname "$disk")"
  setfacl -m "u:${qemu_user}:rx" "$disk_dir" || exit 1
  setfacl -m "u:${qemu_user}:rw" "$disk" || exit 1
  setfacl -m "u:${qemu_user}:r" "$backing" || exit 1
  echo "Granted $qemu_user ACL access to overlay and backing file." >&2
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

mkdir -p "$WORK_BASE"
WORK_DIR="$(mktemp -d "$WORK_BASE/boot-test.XXXXXX")"
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

if libvirt_uses_system_qemu; then
  grant_qemu_system_storage_access "$TEST_DISK" "$IMAGE"
fi

if virsh --connect "$CONNECT" dominfo "$VM_NAME" &>/dev/null; then
  echo "Removing existing domain $VM_NAME" >&2
  virsh --connect "$CONNECT" destroy "$VM_NAME" 2>/dev/null || true
  virsh --connect "$CONNECT" undefine "$VM_NAME" 2>/dev/null || true
fi

GRAPHICS_ARGS=(--graphics vnc,listen=127.0.0.1)
[[ "$GRAPHICS" == none ]] && GRAPHICS_ARGS=(--graphics none)

MACHINE="pc"
BOOT_ARGS=(--boot hd)
TPM_ARGS=()
if [[ "$FIRMWARE" == "uefi" ]]; then
  MACHINE="q35"
  BOOT_ARGS=()
  libvirt_uefi_import_boot_args "$VAR_FILE" "$ROOT" || exit 1
  if [[ "${BOOT_TEST_TPM:-1}" == 1 ]]; then
    if pkrvar_vtpm_enabled "$VAR_FILE" "$ROOT"; then
      mapfile -t TPM_ARGS < <(libvirt_tpm_args "$VAR_FILE" "$ROOT" 1)
    fi
  fi
fi

libvirt_disk_args "$TEST_DISK" "$DISK_BUS" "" 1

echo "Starting VM (import, ${DISK_BUS} root disk, firmware=${FIRMWARE})..." >&2
if [[ "$FIRMWARE" == "uefi" && "$DISK_BUS" == "virtio" ]]; then
  echo "WARN: virtio-blk often fails under OVMF (no bootable device). Prefer BOOT_TEST_DISK_BUS=scsi." >&2
fi

virt-install --connect "$CONNECT" \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --vcpus "$VPUS" \
  --machine "$MACHINE" \
  --arch x86_64 \
  --osinfo win2k22 \
  --import \
  "${BOOT_ARGS[@]}" \
  "${LIBVIRT_UEFI_VIRT_INSTALL_ARGS[@]}" \
  "${TPM_ARGS[@]}" \
  "${DISK_CONTROLLER_ARGS[@]}" \
  "${DISK_DEVICE_ARG[@]}" \
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
  if [[ "$FIRMWARE" == "uefi" ]]; then
    echo "Hint: OVMF 'no bootable device' -> use BOOT_TEST_DISK_BUS=sata (default) not virtio; rebuild with current sysprep unattend." >&2
  fi
  exit 1
fi

echo "VM is running." >&2
if [[ "$GRAPHICS" == vnc && "$SHOW_CONSOLE" == 1 ]]; then
  "$ROOT/scripts/open-vm-console.sh" --background "$CONNECT" "$VM_NAME" || true
elif [[ "$GRAPHICS" == vnc ]]; then
  echo "Console: virt-viewer --connect $CONNECT $VM_NAME  (or set BOOT_TEST_SHOW_CONSOLE=1)" >&2
fi

echo "Waiting ${WAIT}s to confirm the guest stays up..." >&2
sleep "$WAIT"

state="$(virsh --connect "$CONNECT" domstate "$VM_NAME" 2>/dev/null || true)"
if [[ "$state" != "running" ]]; then
  echo "FAIL: VM is not running after ${WAIT}s (state=${state:-unknown})" >&2
  echo "Hint: first boot after sysprep may reboot during OOBE; try BOOT_TEST_WAIT=300 BOOT_TEST_GUEST_WAIT=900" >&2
  virsh --connect "$CONNECT" domstate "$VM_NAME" 2>/dev/null || true
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
