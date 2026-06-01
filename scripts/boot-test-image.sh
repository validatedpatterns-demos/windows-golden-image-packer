# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Boot-test a golden qcow2 without modifying it (overlay qcow2; backing stays read-only).
#
# Default: libvirt on qemu:///system with virtio-scsi disk, virtio NIC, and a guest-agent
# channel (domifaddr --source agent). Use BOOT_TEST_METHOD=packer to replay the OVMF
# sysprep Packer QEMU layout (ide.0 + e1000 user netdev, WinRM port forward).
#
# Usage:
#   boot-test-image.sh [options] [IMAGE.qcow2]
#
# Environment (defaults shown):
#   BOOT_TEST_METHOD=libvirt|packer    # default: libvirt (virtio-scsi + guest-agent on system libvirt)
#   BOOT_TEST_CONNECT=qemu:///system   # libvirt URI (default; use qemu:///session to skip ACLs)
#   BOOT_TEST_FIRMWARE=uefi
#   BOOT_TEST_MEMORY=8192
#   BOOT_TEST_VCPUS=4
#   BOOT_TEST_WAIT=180
#   BOOT_TEST_GUEST_WAIT=600
#   BOOT_TEST_CHECK_GUEST=1        # packer: WinRM host port; libvirt: guest-agent IP
#   BOOT_TEST_GRAPHICS=vnc
#   BOOT_TEST_SHOW_CONSOLE=1
#   BOOT_TEST_TPM=0                 # default: off (matches provision_sysprep_vtpm=false)
#   BOOT_TEST_DISK_BUS=virtio         # libvirt uefi: virtio-blk (OpenShift disk.bus: virtio)
#   BOOT_TEST_KEEP_VM=0
#   BOOT_TEST_KEEP_DISK=0
#   BOOT_TEST_WORK_DIR=$HOME/VirtualMachines
#   VAR_FILE=build.pkrvars.hcl
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"
# shellcheck source=scripts/packer-ovmf-sysprep-qemu.sh
source "$ROOT/scripts/packer-ovmf-sysprep-qemu.sh"

CONNECT="${BOOT_TEST_CONNECT:-$(libvirt_default_connect)}"
METHOD="${BOOT_TEST_METHOD:-}"

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
DISK_BUS=""

read_hcl() {
  local key="$1"
  [[ -f "$VAR_FILE" ]] || return 0
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$VAR_FILE" | head -1 \
    | sed -E 's/^[^=]+=[[:space:]]*"([^"]+)".*/\1/; s/^[^=]+=[[:space:]]*([^"[:space:]]+).*/\1/'
}

# Sysprep pass runs without vTPM by default; injecting TPM on first deploy boot often BSODs.
boot_test_tpm_default() {
  local v
  v="$("$ROOT/scripts/read-pkrvar.sh" provision_sysprep_vtpm "$VAR_FILE" false)"
  if [[ "$v" == "true" ]]; then
    echo 1
  else
    echo 0
  fi
}

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Options:"
  echo "  --image PATH       qcow2 to test (default: newest golden under output/)"
  echo "  --name NAME        libvirt domain name (default: boot-test-<image-basename>)"
  echo "  --firmware bios|uefi"
  echo "  --method libvirt|packer   default: libvirt (qemu:///system, virtio-scsi, guest-agent)"
  echo "  --memory MB        --vcpus N"
  echo "  --wait SECONDS     --guest-wait SECONDS"
  echo "  --no-guest-check   skip QEMU guest-agent IP check"
  echo "  --graphics vnc|none"
  echo "  --no-console       do not open virt-viewer"
  echo "  --disk-bus virtio|scsi|sata   root disk (default: virtio = virtio-blk / OpenShift bus: virtio)"
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
    --method) METHOD="$2"; shift 2 ;;
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
  efi_rc=0
  golden_image_has_efi_partition "$IMAGE" || efi_rc=$?
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

if [[ -z "$METHOD" ]]; then
  METHOD=libvirt
fi

case "$METHOD" in
  packer|libvirt) ;;
  *)
    echo "Invalid --method: $METHOD (use packer or libvirt)" >&2
    exit 1
    ;;
esac

if [[ "$METHOD" == "packer" && "$FIRMWARE" != "uefi" ]]; then
  echo "ERROR: BOOT_TEST_METHOD=packer requires --firmware uefi" >&2
  exit 1
fi

if [[ -z "$VM_NAME" ]]; then
  base="$(basename "$IMAGE" .qcow2)"
  VM_NAME="boot-test-${base}"
fi

WORK_DIR=""
TEST_DISK=""
QEMU_PID=""

cleanup() {
  local rc=$?
  if [[ "$METHOD" == "libvirt" && -n "$IMAGE" && -f "$IMAGE" ]]; then
    libvirt_reclaim_backing_for_build_user "$IMAGE" 2>/dev/null || true
  fi
  if [[ "$METHOD" == "packer" && -n "$WORK_DIR" ]]; then
    if [[ "$KEEP_VM" != 1 ]]; then
      packer_ovmf_stop_qemu "$WORK_DIR" 2>/dev/null || true
    fi
  elif [[ "$KEEP_VM" != 1 && -n "$VM_NAME" ]]; then
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

libvirt_uses_system_qemu() {
  [[ "$CONNECT" == qemu://* && "$CONNECT" != *session* ]]
}

prepare_backing_for_overlay() {
  libvirt_reclaim_backing_for_build_user "$IMAGE" || exit 1
}

ORIG_SIZE="$(stat -c%s "$IMAGE")"
ORIG_MTIME="$(stat -c%Y "$IMAGE")"

mkdir -p "$WORK_BASE"
WORK_DIR="$(mktemp -d "$WORK_BASE/boot-test.XXXXXX")"
TEST_DISK="$WORK_DIR/disk.qcow2"

echo "Golden image (read-only backing): $IMAGE"
echo "Test overlay:                  $TEST_DISK"
echo "Method:                        $METHOD"
echo "Firmware:                      $FIRMWARE"
if [[ "$METHOD" == "libvirt" ]]; then
  echo "libvirt:                       $CONNECT"
  echo "Domain:                        $VM_NAME"
  echo "Disk bus:                      $DISK_BUS"
fi

if [[ "$METHOD" == "packer" ]]; then
  require_cmd qemu-system-x86_64 qemu-img stat python3
  packer_ovmf_load_config "$VAR_FILE" "$ROOT" || exit 1
  PACKER_OVMF_MEMORY="$MEMORY"
  PACKER_OVMF_VCPUS="$VPUS"

  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] libvirt_ensure_build_user_read_file + qemu-img create -b ..."
    echo "[dry-run] packer_ovmf_prepare_workdir + qemu (OVMF sysprep pass: ide.0, qcow2 pflash, no vTPM)"
    packer_ovmf_print_qemu_cmd "$WORK_DIR" "disk.qcow2" "$VM_NAME" 44 4228
    exit 0
  fi

  prepare_backing_for_overlay
  packer_ovmf_prepare_workdir "$WORK_DIR" "$IMAGE" "disk.qcow2"
  VNC_DISPLAY="$(packer_ovmf_pick_vnc_display)"
  WINRM_PORT="$(packer_ovmf_pick_free_port)"

  echo "Starting VM (Packer OVMF sysprep layout: ide.0, ${PACKER_OVMF_NET_DEV}, OVMF qcow2 pflash, no vTPM)..." >&2
  packer_ovmf_start_qemu "$WORK_DIR" "disk.qcow2" "$VM_NAME" "$VNC_DISPLAY" "$WINRM_PORT"

  running=0
  for _ in $(seq 1 30); do
    if packer_ovmf_qemu_running "$WORK_DIR"; then
      running=1
      break
    fi
    sleep 1
  done

  if [[ "$running" != 1 ]]; then
    echo "FAIL: QEMU exited immediately (see $WORK_DIR/qemu.log)" >&2
    tail -20 "$WORK_DIR/qemu.log" 2>/dev/null || true
    exit 1
  fi

  echo "VM is running (qemu pid $(packer_ovmf_qemu_pid "$WORK_DIR"))." >&2
  if [[ "$GRAPHICS" == vnc ]]; then
    echo "VNC: vncviewer 127.0.0.1:$((5900 + VNC_DISPLAY))  (display :${VNC_DISPLAY})" >&2
    if [[ "$SHOW_CONSOLE" == 1 ]] && command -v vncviewer >/dev/null; then
      vncviewer "127.0.0.1:$((5900 + VNC_DISPLAY))" >/dev/null 2>&1 &
    fi
  fi
  echo "WinRM forward: localhost:${WINRM_PORT} -> guest :5985" >&2

  echo "Waiting ${WAIT}s to confirm the guest stays up..." >&2
  sleep "$WAIT"

  if ! packer_ovmf_qemu_running "$WORK_DIR"; then
    echo "FAIL: QEMU is not running after ${WAIT}s" >&2
    tail -20 "$WORK_DIR/qemu.log" 2>/dev/null || true
    exit 1
  fi

  guest_ok=0
  if [[ "$CHECK_GUEST" == 1 ]]; then
    echo "Waiting up to ${GUEST_WAIT}s for WinRM on localhost:${WINRM_PORT}..." >&2
    if packer_ovmf_wait_winrm "$WINRM_PORT" "$GUEST_WAIT"; then
      guest_ok=1
      echo "WinRM port is accepting connections." >&2
    else
      echo "FAIL: WinRM not reachable within ${GUEST_WAIT}s (QEMU still running: $(packer_ovmf_qemu_running "$WORK_DIR" && echo yes || echo no))" >&2
      echo "Hint: prep disks should expose WinRM; sysprepped goldens may need BOOT_TEST_CHECK_GUEST=0 during OOBE." >&2
      exit 1
    fi
  else
    guest_ok=1
  fi

  NEW_SIZE="$(stat -c%s "$IMAGE")"
  NEW_MTIME="$(stat -c%Y "$IMAGE")"
  if [[ "$NEW_SIZE" != "$ORIG_SIZE" || "$NEW_MTIME" != "$ORIG_MTIME" ]]; then
    echo "FAIL: golden image file changed on disk (size or mtime)" >&2
    exit 1
  fi

  echo "PASS: boot test succeeded for $IMAGE"
  echo "  QEMU stayed running for ${WAIT}s (Packer OVMF sysprep layout)"
  if [[ "$CHECK_GUEST" == 1 ]]; then
    echo "  WinRM reachable on localhost:${WINRM_PORT}"
  fi
  echo "  Golden image file unchanged (overlay writes did not touch the backing file)"
  exit 0
fi

require_cmd virsh virt-install qemu-img stat

if ! virsh --connect "$CONNECT" uri &>/dev/null; then
  echo "Cannot connect to libvirt: $CONNECT" >&2
  exit 1
fi

if [[ "$CONNECT" == qemu:///system ]] && ! virsh --connect "$CONNECT" net-info default &>/dev/null; then
  echo "libvirt network 'default' not found on $CONNECT (needed for virtio NIC)" >&2
  exit 1
fi

if [[ "$DRY_RUN" == 1 ]]; then
  echo "[dry-run] libvirt_ensure_build_user_read_file + qemu-img create -f qcow2 -F qcow2 -b \"$IMAGE\" \"$TEST_DISK\""
  echo "[dry-run] virt-install --import ... ($DISK_BUS disk, $FIRMWARE)"
  exit 0
fi

prepare_backing_for_overlay
qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" "$TEST_DISK" >/dev/null

if libvirt_uses_system_qemu; then
  libvirt_prepare_system_boot_test_disks "$TEST_DISK" "$IMAGE" || exit 1
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
  if [[ "${BOOT_TEST_TPM:-$(boot_test_tpm_default)}" == 1 ]]; then
    mapfile -t TPM_ARGS < <(libvirt_tpm_args "$VAR_FILE" "$ROOT" 1)
  fi
fi

libvirt_disk_args "$TEST_DISK" "$DISK_BUS" "" 1
libvirt_guest_agent_channel_args

echo "Starting VM (import, ${DISK_BUS} root disk, firmware=${FIRMWARE}, guest-agent channel)..." >&2
echo "libvirt: $CONNECT (system session — use virt-viewer for console)" >&2
if [[ "$FIRMWARE" == "uefi" && "$DISK_BUS" == "virtio" ]]; then
  echo "Disk: virtio-blk (OpenShift disk.bus: virtio; needs boot-start viostor in golden image)" >&2
elif [[ "$FIRMWARE" == "uefi" && "$DISK_BUS" == "scsi" ]]; then
  echo "Disk: virtio-scsi (disk.bus: scsi; needs boot-start vioscsi in golden image)" >&2
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
  "${LIBVIRT_GUEST_AGENT_CHANNEL_ARGS[@]}" \
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
  echo "Hint: sysprep OOBE reboots are normal; try BOOT_TEST_WAIT=300 BOOT_TEST_GUEST_WAIT=900" >&2
  echo "Hint: INACCESSIBLE_BOOT_DEVICE on virtio -> rebuild golden with enable-virtio-blk-boot-load.ps1." >&2
  echo "      Ensure BOOT_TEST_TPM=0 (default). Fallback: BOOT_TEST_DISK_BUS=sata." >&2
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
