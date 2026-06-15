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
# Defined in libvirt-vm-disk.sh (libvirt_destroy_domain).

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
