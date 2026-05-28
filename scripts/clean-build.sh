# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Tear down a failed or interrupted Packer QEMU build (processes + artifacts).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/libvirt-cleanup.sh
source "$ROOT/scripts/libvirt-cleanup.sh"

FORCE="${FORCE:-0}"
KILL_WAIT="${KILL_WAIT:-3}"

log() { printf '%s\n' "$*"; }

# QEMU command lines for this project use -name packer-win{version}-{edition}
collect_packer_qemu_pids() {
  local pids=()
  local line pid

  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ qemu-system ]] && [[ "$line" =~ packer-win ]]; then
      pid="${line%% *}"
      [[ "$pid" =~ ^[0-9]+$ ]] && pids+=("$pid")
    fi
  done < <(pgrep -af 'qemu-system' 2>/dev/null || true)

  if ((${#pids[@]} > 0)); then
    printf '%s\n' "${pids[@]}" | sort -u
  fi
}

stop_qemu() {
  local pids
  pids="$(collect_packer_qemu_pids || true)"
  if [[ -z "$pids" ]]; then
    log "No Packer QEMU processes found."
    return 0
  fi

  log "Stopping Packer QEMU process(es):"
  pgrep -af 'qemu-system' 2>/dev/null | grep 'packer-win' || true

  while read -r pid; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      log "  SIGTERM pid $pid"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done <<< "$pids"

  sleep "$KILL_WAIT"

  pids="$(collect_packer_qemu_pids || true)"
  if [[ -n "$pids" ]]; then
    log "Processes still running; sending SIGKILL."
    while read -r pid; do
      [[ -z "$pid" ]] && continue
      if kill -0 "$pid" 2>/dev/null; then
        log "  SIGKILL pid $pid"
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done <<< "$pids"
    sleep 1
  fi

  if pids="$(collect_packer_qemu_pids || true)" && [[ -n "$pids" ]]; then
    log "Warning: some QEMU processes may still be running." >&2
    return 1
  fi

  log "Packer QEMU processes stopped."
}

remove_artifacts() {
  log "Removing build artifacts..."
  for orphan in extras/virtio-win-staged.orphan.*; do
    [[ -e "$orphan" ]] || continue
    chmod -R u+rwX "$orphan" 2>/dev/null || true
    rm -rf "$orphan" 2>/dev/null || mv "$orphan" "${orphan}.left" 2>/dev/null || true
  done
  rm -f extras/.virtio-win-staged.ready 2>/dev/null || true

  rm -rf \
    output \
    packer/output \
    packer/packer_cache \
    packer_cache \
    packer/ci-output \
    packer/ci-stub.iso \
    packer-manifest.json \
    packer/packer-manifest.json

  # Packer QEMU output dirs named after vm_name (e.g. output_directory/vm_name/)
  local dir
  for dir in output/packer-win* packer/output/packer-win* ../output/packer-win*; do
    if [[ -d "$dir" ]]; then
      rm -rf "$dir"
      log "  removed $dir"
    fi
  done

  find output packer/output -maxdepth 2 -type f \( -name '*.qcow2' -o -name 'packer-win*' -o -name 'windows-server-*' \) -delete 2>/dev/null || true
  log "Artifact cleanup done."
}

clean_libvirt() {
  log "Removing libvirt domains from this project (virt-install / boot-test)..."
  libvirt_cleanup_project_domains 0
  libvirt_cleanup_boot_test_workdirs
  log "Libvirt cleanup done."
}

main() {
  if [[ "${1:-}" == "--artifacts-only" ]]; then
    remove_artifacts
    exit 0
  fi

  clean_libvirt
  stop_qemu || [[ "$FORCE" == "1" ]] || exit 1
  remove_artifacts
}

main "$@"
