# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Shared virt-install disk/controller fragments (UEFI + OpenShift alignment).

# shellcheck shell=bash

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
  LIBVIRT_UEFI_VIRT_INSTALL_ARGS=(
    --boot "uefi,loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,nvram.template=${OVMF_VARS},menu=on,cdrom"
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
  virt-filesystems -a "$image" --all 2>/dev/null | grep -qE '/boot/efi|/efi'
}

# Match install bus (SATA) so OVMF can read the ESP without a driver switch.
default_uefi_disk_bus() {
  echo sata
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
