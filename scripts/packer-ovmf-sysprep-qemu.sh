# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Shared QEMU launch for the OVMF sysprep Packer pass (from_install_gpt).
# Used by boot-test-image.sh (BOOT_TEST_METHOD=packer) to match Packer's runtime.
#
# Source this file, then call:
#   packer_ovmf_load_config VAR_FILE ROOT
#   packer_ovmf_prepare_workdir WORK_DIR BACKING_QCOW2 [disk_basename]
#   packer_ovmf_start_qemu WORK_DIR disk_basename VM_NAME VNC_DISPLAY WINRM_HOST_PORT
# shellcheck shell=bash

packer_ovmf_load_config() {
  local var_file="${1:?var file}"
  local root="${2:?root}"
  local read_pkr="$root/scripts/read-pkrvar.sh"

  PACKER_OVMF_ACCEL="$("$read_pkr" qemu_accelerator "$var_file" kvm)"
  PACKER_OVMF_NET_DEV="$("$read_pkr" install_net_device "$var_file" e1000)"
  PACKER_OVMF_MEMORY="$("$read_pkr" vm_memory "$var_file" 8192)"
  PACKER_OVMF_VCPUS="$("$read_pkr" vm_cpus "$var_file" 4)"

  libvirt_ovmf_paths "$var_file" "$root" || {
    echo "ERROR: OVMF firmware not found (install edk2-ovmf or set ovmf_*_path in pkrvars)" >&2
    return 1
  }
  PACKER_OVMF_CODE="$OVMF_CODE"
  PACKER_OVMF_VARS_TEMPLATE="$OVMF_VARS"
}

packer_ovmf_prepare_workdir() {
  local work_dir="${1:?work dir}"
  local backing="${2:?backing qcow2}"
  local disk_name="${3:-disk.qcow2}"

  mkdir -p "$work_dir"
  cp -f "$PACKER_OVMF_VARS_TEMPLATE" "$work_dir/efivars.fd"
  qemu-img create -f qcow2 -F qcow2 -b "$backing" "$work_dir/$disk_name" >/dev/null
}

packer_ovmf_common_qemu_args() {
  local work_dir="$1"
  local disk_name="$2"
  local vm_name="$3"
  local vnc_display="$4"
  local winrm_host_port="$5"

  printf '%s\n' \
    -vnc "127.0.0.1:${vnc_display}" \
    -drive "file=${PACKER_OVMF_CODE},if=pflash,unit=0,format=qcow2,readonly=on" \
    -drive "file=${work_dir}/efivars.fd,if=pflash,unit=1,format=qcow2" \
    -machine "type=q35,accel=${PACKER_OVMF_ACCEL},smm=on" \
    -boot menu=on,strict=on \
    -drive "if=none,file=${work_dir}/${disk_name},id=disk0,cache=writeback,discard=ignore,format=qcow2" \
    -device "ide-hd,drive=disk0,bus=ide.0,bootindex=1,write-cache=on" \
    -device "${PACKER_OVMF_NET_DEV},netdev=user.0,bootindex=5" \
    -m "${PACKER_OVMF_MEMORY}M" \
    -smp "$PACKER_OVMF_VCPUS" \
    -cpu host \
    -vga std \
    -display none \
    -name "$vm_name" \
    -netdev "user,id=user.0,hostfwd=tcp::${winrm_host_port}-:5985"
}

# Print the qemu-system-x86_64 command (one line) for logging/dry-run.
packer_ovmf_print_qemu_cmd() {
  local work_dir="$1"
  local disk_name="$2"
  local vm_name="$3"
  local vnc_display="$4"
  local winrm_host_port="$5"
  local -a args
  mapfile -t args < <(packer_ovmf_common_qemu_args "$work_dir" "$disk_name" "$vm_name" "$vnc_display" "$winrm_host_port")
  printf '%q ' qemu-system-x86_64 "${args[@]}"
  echo
}

packer_ovmf_start_qemu() {
  local work_dir="$1"
  local disk_name="$2"
  local vm_name="$3"
  local vnc_display="$4"
  local winrm_host_port="$5"
  local pid_file="$work_dir/qemu.pid"
  local log_file="$work_dir/qemu.log"
  local -a args
  mapfile -t args < <(packer_ovmf_common_qemu_args "$work_dir" "$disk_name" "$vm_name" "$vnc_display" "$winrm_host_port")

  qemu-system-x86_64 "${args[@]}" >>"$log_file" 2>&1 &

  echo $! >"$pid_file"
  echo "$winrm_host_port" >"$work_dir/winrm.hostport"
  echo "$vnc_display" >"$work_dir/vnc.display"
}

packer_ovmf_qemu_pid() {
  local work_dir="$1"
  local pid_file="$work_dir/qemu.pid"
  [[ -f "$pid_file" ]] || return 1
  cat "$pid_file"
}

packer_ovmf_qemu_running() {
  local work_dir="$1"
  local pid
  pid="$(packer_ovmf_qemu_pid "$work_dir" 2>/dev/null)" || return 1
  kill -0 "$pid" 2>/dev/null
}

packer_ovmf_stop_qemu() {
  local work_dir="$1"
  local pid
  pid="$(packer_ovmf_qemu_pid "$work_dir" 2>/dev/null)" || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$work_dir/qemu.pid"
}

# Wait for forwarded WinRM TCP port (same signal Packer uses before provisioners).
packer_ovmf_wait_winrm() {
  local host_port="$1"
  local timeout_sec="${2:-600}"
  local deadline=$((SECONDS + timeout_sec))

  while ((SECONDS < deadline)); do
    if (echo >/dev/tcp/127.0.0.1/"$host_port") 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 1
}

packer_ovmf_pick_free_port() {
  local port
  port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  echo "$port"
}

packer_ovmf_pick_vnc_display() {
  local disp=10
  while ((disp < 100)); do
    if ! ss -ltn 2>/dev/null | grep -q ":$((5900 + disp)) "; then
      echo "$disp"
      return 0
    fi
    ((disp++))
  done
  echo "ERROR: no free VNC display in range :10-:99" >&2
  return 1
}
