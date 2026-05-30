# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Destroy/undefine libvirt domains created by this repo (virt-install UEFI install, boot-test).
# shellcheck disable=SC2034
LIBVIRT_CLEANUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/libvirt-vm-disk.sh
source "$LIBVIRT_CLEANUP_ROOT/scripts/libvirt-vm-disk.sh"

libvirt_cleanup_connects() {
  local primary="${LIBVIRT_CONNECT:-$(libvirt_default_connect)}"
  local -a connects=()
  local c

  for c in "$primary" qemu:///session qemu:///system; do
    [[ -z "$c" ]] && continue
    case " ${connects[*]} " in
      *" $c "*) continue ;;
    esac
    connects+=("$c")
  done

  printf '%s\n' "${connects[@]}"
}

# Returns 0 if the domain name belongs to this project.
libvirt_domain_is_project() {
  case "$1" in
    win-uefi-install-* | boot-test-*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Args: connect name [remove_storage: 0|1]
# Never pass remove_storage=1 when the domain uses --cdrom with a host ISO path; libvirt can delete that file.
libvirt_destroy_domain() {
  local connect="$1" name="$2" remove_storage="${3:-0}"

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
    echo "ERROR: failed to undefine libvirt domain $name on $connect (disk may stay locked)." >&2
    virsh --connect "$connect" dominfo "$name" >&2 || true
    return 1
  fi

  # Orphan session NVRAM from OVMF installs (undefine --nvram usually removes it).
  rm -f "${HOME}/.config/libvirt/qemu/nvram/${name}_VARS.qcow2" 2>/dev/null || true
  if [[ "$remove_storage" == 1 ]]; then
    echo "WARN: remove_storage=1 is unsafe if install media was attached via --cdrom; use rm on known paths instead." >&2
  fi
}

# Args: [remove_storage: 0|1]
libvirt_cleanup_project_domains() {
  local remove_storage="${1:-0}"
  local connect name failed=0

  if ! command -v virsh >/dev/null 2>&1; then
    echo "virsh not found; skipping libvirt cleanup" >&2
    return 0
  fi

  while IFS= read -r connect; do
    [[ -z "$connect" ]] && continue
    if ! virsh --connect "$connect" uri &>/dev/null; then
      echo "Skipping libvirt connect $connect (not available)" >&2
      continue
    fi
    mapfile -t names < <(virsh --connect "$connect" list --all --name 2>/dev/null || true)
    for name in "${names[@]}"; do
      [[ -z "$name" ]] && continue
      if libvirt_domain_is_project "$name"; then
        libvirt_destroy_domain "$connect" "$name" "$remove_storage" || failed=1
      fi
    done
  done < <(libvirt_cleanup_connects)
  return "${failed:-0}"
}

# Remove boot-test overlay workdirs (default ~/VirtualMachines/boot-test.*).
libvirt_cleanup_boot_test_workdirs() {
  local work_parent="${BOOT_TEST_WORK_DIR:-$HOME/VirtualMachines}"
  local dir

  [[ -d "$work_parent" ]] || return 0
  shopt -s nullglob
  for dir in "$work_parent"/boot-test.*; do
    [[ -d "$dir" ]] || continue
    echo "Removing boot-test workdir $dir" >&2
    rm -rf "$dir"
  done
  shopt -u nullglob
}
