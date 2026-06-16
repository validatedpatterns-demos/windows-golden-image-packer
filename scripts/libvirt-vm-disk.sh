# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Shared virt-install disk/controller fragments (UEFI + OpenShift alignment).

# shellcheck shell=bash

# libguestfs defaults to the libvirt backend; on some hosts that cannot spawn the appliance
# (SELinux, session qemu). Direct backend avoids libvirt for read-only inspection.
libguestfs_direct() {
  LIBGUESTFS_BACKEND=direct "$@"
}

# Select a matching OVMF CODE+VARS pair (same generation/size). q35 needs 4M firmware on
# current Fedora (OVMF_CODE_4M.*.qcow2); 2M OVMF_CODE.fd often fails to boot on q35.
libvirt_ovmf_paths() {
  local var_file="${1:-}" root="${2:-.}"
  local read_pkr="$root/scripts/read-pkrvar.sh"
  local from_code from_vars pair code vars

  from_code="$("$read_pkr" ovmf_code_path "$var_file" "")"
  from_vars="$("$read_pkr" ovmf_vars_path "$var_file" "")"
  if [[ -n "$from_code" && -n "$from_vars" ]]; then
    [[ "$from_code" != /* ]] && from_code="$root/$from_code"
    [[ "$from_vars" != /* ]] && from_vars="$root/$from_vars"
    if [[ -f "$from_code" && -f "$from_vars" ]]; then
      OVMF_CODE="$from_code"
      OVMF_VARS="$from_vars"
      export OVMF_CODE OVMF_VARS
      return 0
    fi
    echo "WARN: ovmf_code_path/ovmf_vars_path in pkrvars not found; using built-in defaults" >&2
  fi

  for pair in \
    "/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2:/usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2" \
    "/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2:/usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2" \
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd" \
    "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd:/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd" \
    "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"; do
    code="${pair%%:*}"
    vars="${pair##*:}"
    if [[ -f "$code" && -f "$vars" ]]; then
      OVMF_CODE="$code"
      OVMF_VARS="$vars"
      export OVMF_CODE OVMF_VARS
      return 0
    fi
  done

  OVMF_CODE=""
  OVMF_VARS=""
  export OVMF_CODE OVMF_VARS
  return 1
}

# Populated by libvirt_uefi_*_boot_args; use "${LIBVIRT_UEFI_VIRT_INSTALL_ARGS[@]}" (not mapfile — set -e
# does not fail when a process substitution command returns non-zero).
LIBVIRT_UEFI_VIRT_INSTALL_ARGS=()

# SeaBIOS install from DVD (Microsoft UDF ISO UEFI El Torito often times out on OVMF+QEMU 10).
libvirt_seabios_install_boot_args() {
  LIBVIRT_UEFI_VIRT_INSTALL_ARGS=(
    --boot "menu=on,cdrom"
  )
}

# Fresh Windows install from ISO: UEFI (OVMF), boot menu, CD-ROM first.
libvirt_uefi_install_boot_args() {
  local var_file="${1:-}" root="${2:-.}"
  LIBVIRT_UEFI_VIRT_INSTALL_ARGS=()
  libvirt_ovmf_paths "$var_file" "$root"
  if [[ ! -f "$OVMF_CODE" || ! -f "$OVMF_VARS" ]]; then
    echo "ERROR: OVMF firmware not found. Install edk2-ovmf (dnf install edk2-ovmf)." >&2
    return 1
  fi
  echo "Using OVMF: CODE=$OVMF_CODE VARS=$OVMF_VARS" >&2
  # hd before cdrom: after the first reboot Windows Setup must boot the ESP on the
  # virtio disk, not the install DVD (boot_order=1 on CD causes an install loop).
  LIBVIRT_UEFI_VIRT_INSTALL_ARGS=(
    --boot "uefi,loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,nvram.template=${OVMF_VARS},menu=on,hd,cdrom"
    --features "acpi=on,smm=on"
  )
}

# Boot an existing qcow2 (--import).
libvirt_uefi_import_boot_args() {
  local var_file="${1:-}" root="${2:-.}"
  LIBVIRT_UEFI_VIRT_INSTALL_ARGS=()
  libvirt_ovmf_paths "$var_file" "$root"
  if [[ ! -f "$OVMF_CODE" || ! -f "$OVMF_VARS" ]]; then
    echo "ERROR: OVMF firmware not found (CODE=$OVMF_CODE VARS=$OVMF_VARS)" >&2
    return 1
  fi
  LIBVIRT_UEFI_VIRT_INSTALL_ARGS=(
    --boot "uefi,loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,nvram.template=${OVMF_VARS},menu=on"
    --features "acpi=on,smm=on"
  )
}

# Backward-compatible alias
libvirt_uefi_boot_args() {
  libvirt_uefi_import_boot_args "$@"
}

# Sets DISK_CONTROLLER_ARGS and DISK_DEVICE_ARG arrays.
# Args: disk_path disk_bus [size_gb] [boot_order]
#   size_gb set, boot_order unset -> new/install disk, CD-ROM boots first
#   size_gb empty, boot_order 1   -> import existing golden disk
libvirt_disk_args() {
  local disk_path="$1"
  local disk_bus="${2:-scsi}"
  local size_gb="${3:-}"
  local boot_order="${4:-}"
  local size_opt="" boot_order_opt=""
  DISK_CONTROLLER_ARGS=()
  DISK_DEVICE_ARG=()

  if [[ -n "$size_gb" ]]; then
    size_opt=",size=${size_gb}"
  fi
  if [[ "$boot_order" == "1" ]]; then
    boot_order_opt=",boot_order=1"
  fi

  case "$disk_bus" in
    scsi)
      DISK_CONTROLLER_ARGS=(--controller type=scsi,model=virtio-scsi)
      DISK_DEVICE_ARG=(--disk "path=${disk_path},bus=scsi,format=qcow2,cache=writeback${size_opt}${boot_order_opt}")
      ;;
    sata)
      DISK_DEVICE_ARG=(--disk "path=${disk_path},bus=sata,format=qcow2,cache=writeback${size_opt}${boot_order_opt}")
      ;;
    virtio)
      DISK_DEVICE_ARG=(--disk "path=${disk_path},bus=virtio,format=qcow2,cache=writeback${size_opt}${boot_order_opt}")
      ;;
    *)
      echo "Unsupported disk bus: $disk_bus (use scsi, sata, or virtio)" >&2
      return 1
      ;;
  esac
}

golden_image_has_efi_partition() {
  local image="$1"
  if ! command -v virt-filesystems >/dev/null 2>&1; then
    return 2
  fi

  # Linux images expose ESP mount points; Windows ESP is usually not mounted in the guest view.
  if libguestfs_direct virt-filesystems -a "$image" --all 2>/dev/null | grep -qE '/boot/efi|/efi'; then
    return 0
  fi

  # Windows post-mbr2gpt: inspect GPT partition types for the EFI system partition GUID.
  if ! command -v guestfish >/dev/null 2>&1; then
    return 2
  fi

  local -a parts=()
  local part disk num type upper gf_out gf_rc=0
  local esp_guid='C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
  gf_out="$(libguestfs_direct guestfish --ro -a "$image" run : list-partitions 2>&1)" || gf_rc=$?
  if [[ "$gf_rc" -ne 0 ]] || [[ "$gf_out" == *libguestfs:*error* ]]; then
    return 2
  fi
  mapfile -t parts <<< "$gf_out"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    num="${part##*[!0-9]}"
    disk="${part%"$num"}"
    [[ -z "$num" || -z "$disk" ]] && continue
    type="$(libguestfs_direct guestfish --ro -a "$image" run : part-get-gpt-type "$disk" "$num" 2>/dev/null || true)"
    upper="$(echo "$type" | tr '[:lower:]' '[:upper:]')"
    if [[ "$upper" == "$esp_guid" ]]; then
      return 0
    fi
  done

  return 1
}

# OpenShift / KubeVirt: boot-test validates disk.bus=virtio (virtio-blk / viostor boot-start).
default_uefi_disk_bus() {
  echo virtio
}

# Virtio serial channel for virsh domifaddr --source agent (guest must run qemu-ga).
libvirt_guest_agent_channel_args() {
  LIBVIRT_GUEST_AGENT_CHANNEL_ARGS=(
    --channel "unix,target_type=virtio,name=org.qemu.guest_agent.0"
  )
}

# Returns 0 if vtpm is enabled in var file (default true).
pkrvar_vtpm_enabled() {
  local var_file="${1:-}" root="${2:-.}"
  local v
  v="$("$root/scripts/read-pkrvar.sh" vtpm "$var_file" true)"
  [[ "$v" == "true" ]]
}

# Prints --tpm ... for virt-install (libvirt starts swtpm). Args: var_file root [0|1]
libvirt_tpm_args() {
  local var_file="${1:-}" root="${2:-.}"
  local enabled="${3:-}"

  if [[ -z "$enabled" ]]; then
    if pkrvar_vtpm_enabled "$var_file" "$root"; then
      enabled=1
    else
      enabled=0
    fi
  fi

  [[ "$enabled" == 1 || "$enabled" == true ]] || return 0

  if ! command -v swtpm >/dev/null 2>&1; then
    echo "ERROR: swtpm is required for TPM (install: dnf install swtpm)" >&2
    return 1
  fi

  # tpm-crb + TPM 2.0 matches q35/UEFI and OpenShift persistent vTPM.
  printf '%s\n' "--tpm" "backend.type=emulator,backend.version=2.0,model=tpm-crb"
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

libvirt_uses_system_connect() {
  local connect="${1:-${LIBVIRT_CONNECT:-qemu:///system}}"
  [[ "$connect" == qemu://* && "$connect" != *session* ]]
}

# Prefer session libvirt so qcow2 under $HOME stays owned by the build user (no sudo chown).
libvirt_default_connect() {
  if [[ -n "${LIBVIRT_CONNECT:-}" ]]; then
    echo "$LIBVIRT_CONNECT"
    return 0
  fi
  if virsh --connect qemu:///session uri >/dev/null 2>&1; then
    echo qemu:///session
    return 0
  fi
  echo qemu:///system
}

# Boot-test defaults to session libvirt (golden qcow2 under $HOME stays owned by the build user).
# Override with BOOT_TEST_CONNECT=qemu:///system for system libvirt (ACLs required under $HOME).
libvirt_boot_test_default_connect() {
  echo "${BOOT_TEST_CONNECT:-qemu:///session}"
}

# Pick a --network spec for boot-test. Session libvirt often has no "default" network; reuse
# the system hypervisor NAT bridge (virbr0) when it is already up, else SLIRP user networking.
# Override with BOOT_TEST_NETWORK=network=default or bridge=virbr0,user,...
libvirt_boot_test_network_spec() {
  local connect="$1"
  local spec="${BOOT_TEST_NETWORK:-}"

  if [[ -n "$spec" ]]; then
    if [[ "$spec" == *,model=* ]]; then
      echo "$spec"
    else
      echo "${spec},model=virtio"
    fi
    return 0
  fi

  if virsh --connect "$connect" net-info default &>/dev/null; then
    local state=""
    state="$(virsh --connect "$connect" net-info default 2>/dev/null | awk -F': *' '/^Active:/ {print $2}')"
    if [[ "$state" != "yes" ]]; then
      virsh --connect "$connect" net-start default &>/dev/null || true
      state="$(virsh --connect "$connect" net-info default 2>/dev/null | awk -F': *' '/^Active:/ {print $2}')"
    fi
    if [[ "$state" == "yes" ]]; then
      echo "network=default,model=virtio"
      return 0
    fi
  fi

  if [[ "$connect" == *session* ]] && ip link show virbr0 &>/dev/null; then
    echo "Boot-test network: bridge=virbr0 (system libvirt NAT; session has no active default network)" >&2
    echo "bridge=virbr0,model=virtio"
    return 0
  fi

  echo "Boot-test network: user-mode NAT (no libvirt default network on $connect)" >&2
  echo "user,model=virtio"
}

# Args: connect name [remove_storage: 0|1]
libvirt_destroy_domain() {
  local connect="$1" name="$2" remove_storage="${3:-0}"

  if ! command -v virsh >/dev/null 2>&1; then
    return 0
  fi
  if ! virsh --connect "$connect" dominfo "$name" &>/dev/null; then
    return 0
  fi

  echo "Removing libvirt domain $name ($connect)" >&2
  virsh --connect "$connect" destroy "$name" 2>/dev/null || true
  # UEFI/OVMF domains keep NVRAM; plain undefine fails with "cannot undefine domain with nvram".
  if ! virsh --connect "$connect" undefine "$name" --nvram 2>/dev/null; then
    virsh --connect "$connect" undefine "$name" --managed-save --nvram 2>/dev/null || \
      virsh --connect "$connect" undefine "$name" 2>/dev/null || true
  fi
  if virsh --connect "$connect" dominfo "$name" &>/dev/null; then
    echo "ERROR: failed to undefine libvirt domain $name on $connect (name still in use)." >&2
    virsh --connect "$connect" dominfo "$name" >&2 || true
    return 1
  fi

  rm -f "${HOME}/.config/libvirt/qemu/nvram/${name}_VARS.qcow2" 2>/dev/null || true
  if [[ "$remove_storage" == 1 ]]; then
    echo "WARN: remove_storage=1 is unsafe if install media was attached via --cdrom." >&2
  fi
}

libvirt_check_build_prereqs() {
  local connect="${1:-$(libvirt_default_connect)}"
  local user
  user="$(id -un)"

  if [[ ! -r /dev/kvm ]]; then
    echo "ERROR: /dev/kvm is not readable for $user." >&2
    echo "  One-time: sudo usermod -aG kvm $user  (then log out and back in)" >&2
    return 1
  fi

  if libvirt_uses_system_connect "$connect"; then
    if ! command -v setfacl >/dev/null 2>&1; then
      echo "ERROR: $connect with disks under \$HOME needs POSIX ACLs (dnf install acl)." >&2
      echo "  Or set LIBVIRT_CONNECT=qemu:///session to run install VMs as your user." >&2
      return 1
    fi
  fi

  return 0
}

libvirt_grant_qemu_traverse_parents() {
  local qemu_user="$1" target="$2" dir
  target="$(readlink -f "$target")"
  if [[ -f "$target" ]]; then
    dir="$(dirname "$target")"
  else
    dir="$target"
  fi
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if ! setfacl -m "u:${qemu_user}:x" "$dir" 2>/dev/null; then
      echo "Failed to grant $qemu_user traverse on $dir (install acl package?)" >&2
      return 1
    fi
    dir="$(dirname "$dir")"
  done
}

# Ensure the build user can read a golden backing qcow2 (libvirt dynamic_ownership may leave qemu:640).
libvirt_reclaim_backing_for_build_user() {
  local backing="$1"
  local build_user owner
  build_user="${USER:-$(id -un)}"
  backing="$(readlink -f "$backing")"

  if [[ -r "$backing" ]]; then
    return 0
  fi

  owner="$(stat -c '%U' "$backing" 2>/dev/null || echo unknown)"
  echo "Golden backing not readable (${owner} $(stat -c '%G %a' "$backing" 2>/dev/null || echo unknown))." >&2

  if [[ "$owner" == "$build_user" ]]; then
    chmod u+rw "$backing" 2>/dev/null || true
    [[ -r "$backing" ]] && return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n chown "$build_user:$build_user" "$backing" 2>/dev/null; then
    chmod u+rw "$backing" 2>/dev/null || true
    echo "Reclaimed $backing for $build_user (passwordless sudo)." >&2
    [[ -r "$backing" ]] && return 0
  fi

  echo "ERROR: cannot read backing file: $backing" >&2
  echo "  A prior qemu:///system boot-test likely left it owned by $(libvirt_qemu_user)." >&2
  echo "  Run: sudo chown $build_user:$build_user '$backing' && chmod u+rw '$backing'" >&2
  echo "  Or: BOOT_TEST_CONNECT=qemu:///system make boot-test-image ... (needs ACLs under \$HOME)" >&2
  return 1
}

libvirt_ensure_build_user_read_file() {
  libvirt_reclaim_backing_for_build_user "$1"
}

# boot-test overlay + backing under \$HOME with qemu:///system: build user runs qemu-img create;
# qemu user opens both files at runtime.
libvirt_prepare_system_boot_test_disks() {
  local overlay="$1"
  local backing="$2"
  local build_user qemu_user overlay_dir
  build_user="${USER:-$(id -un)}"
  qemu_user="$(libvirt_qemu_user)"
  overlay="$(readlink -f "$overlay")"
  backing="$(readlink -f "$backing")"
  overlay_dir="$(dirname "$overlay")"

  if ! command -v setfacl >/dev/null 2>&1; then
    echo "ERROR: setfacl is required for qemu:///system boot-test under \$HOME (dnf install acl)." >&2
    echo "  Or set BOOT_TEST_CONNECT=qemu:///system (needs ACLs under \$HOME)." >&2
    return 1
  fi

  libvirt_reclaim_backing_for_build_user "$backing" || return 1

  libvirt_grant_qemu_traverse_parents "$qemu_user" "$overlay" || return 1
  libvirt_grant_qemu_traverse_parents "$qemu_user" "$backing" || return 1

  setfacl -m "u:${qemu_user}:rx" "$overlay_dir" || return 1
  setfacl -m "u:${build_user}:rwx" "$overlay_dir" || return 1
  setfacl -m "u:${qemu_user}:rw" "$overlay" || return 1
  setfacl -m "u:${build_user}:rw" "$overlay" || return 1
  setfacl -m "u:${qemu_user}:r" "$backing" || return 1
  echo "Prepared ACLs for $build_user and $qemu_user on boot-test overlay and backing." >&2
}

# Before qemu:///system virt-install: keep build-user rw after libvirt dynamic_ownership (nobody:nobody).
libvirt_prepare_install_disk_for_system() {
  local disk="$1"
  local build_user qemu_user disk_dir
  build_user="${USER:-$(id -un)}"
  qemu_user="$(libvirt_qemu_user)"
  disk="$(readlink -f "$disk")"
  disk_dir="$(dirname "$disk")"

  command -v setfacl >/dev/null 2>&1 || {
    echo "ERROR: setfacl required for $LIBVIRT_CONNECT install disks under \$HOME." >&2
    return 1
  }

  libvirt_grant_qemu_traverse_parents "$qemu_user" "$disk" || return 1
  setfacl -m "u:${qemu_user}:rx" "$disk_dir" || return 1
  setfacl -m "u:${qemu_user}:rw" "$disk" || return 1
  setfacl -m "u:${build_user}:rw" "$disk" || return 1
  echo "Prepared ACLs on install disk for $build_user and $qemu_user (no sudo needed after install)." >&2
}

# qemu:///system + dynamic_ownership often leaves qcow2 in $HOME as nobody:nobody mode 0600.
# Packer (running as the build user) must read the install disk for pass 2.
libvirt_fixup_disk_for_build_user() {
  local disk="$1"
  [[ -f "$disk" ]] || return 0
  if [[ -r "$disk" && -w "$disk" ]]; then
    return 0
  fi

  local build_user="${USER:-$(id -un)}"
  local before
  before="$(stat -c '%U:%G %a' "$disk" 2>/dev/null || echo unknown)"
  echo "ERROR: install disk not readable for Packer (was $before): $disk" >&2
  echo "  Default is LIBVIRT_CONNECT=qemu:///session when available (disks stay yours)." >&2
  echo "  For qemu:///system, rebuild after: dnf install acl  (ACLs are set before virt-install)." >&2
  echo "  One-time fix for this file: chown $build_user:$build_user '$disk' && chmod u+rw '$disk'" >&2
  echo "    (requires root if the file is owned by nobody/qemu)" >&2
  return 1
}
