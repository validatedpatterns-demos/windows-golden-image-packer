# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Destroy/undefine libvirt domains created by this repo (virt-install UEFI install, boot-test).
# shellcheck disable=SC2034
LIBVIRT_CLEANUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

libvirt_cleanup_connects() {
  local primary="${LIBVIRT_CONNECT:-qemu:///system}"
  printf '%s\n' "$primary"
  if [[ "$primary" != "qemu:///session" ]]; then
    printf '%s\n' qemu:///session
  fi
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
  # Default: undefine only. Project qcow2 overlays are removed by clean-build.sh / boot-test scripts.
  virsh --connect "$connect" undefine "$name" 2>/dev/null || true
  if [[ "$remove_storage" == 1 ]]; then
    echo "WARN: remove_storage=1 is unsafe if install media was attached via --cdrom; use rm on known paths instead." >&2
  fi
}

# Args: [remove_storage: 0|1]
libvirt_cleanup_project_domains() {
  local remove_storage="${1:-0}"
  local connect name

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
        libvirt_destroy_domain "$connect" "$name" "$remove_storage"
      fi
    done
  done < <(libvirt_cleanup_connects)
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
