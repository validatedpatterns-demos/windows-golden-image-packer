#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Wait for Packer's qemu-system-x86_64 process to exit after sysprep.ps1 shuts down the guest.
# Generalize breaks WinRM (401) so Packer cannot run shutdown_command; sysprep powers off locally
# and this script waits for QEMU to exit before Packer's empty shutdown step runs.
#
# Usage: wait-packer-qemu-exit.sh VM_NAME [TIMEOUT_SECONDS]
#
# Environment:
#   PACKER_QEMU_FORCE_AFTER  Seconds before SIGTERM on stuck QEMU (default: 1800 = 30m)
#   PACKER_QEMU_LOG_INTERVAL Log heartbeat while waiting (default: 60s)
set -euo pipefail

VM_NAME="${1:?VM_NAME required (Packer -name, e.g. packer-win2022-standard-provision)}"
TIMEOUT="${2:-7200}"
FORCE_AFTER="${PACKER_QEMU_FORCE_AFTER:-1800}"
LOG_INTERVAL="${PACKER_QEMU_LOG_INTERVAL:-60}"

packer_qemu_pids() {
  pgrep -f "qemu-system-x86_64.*${VM_NAME}" 2>/dev/null || true
}

packer_qemu_running() {
  [[ -n "$(packer_qemu_pids)" ]]
}

format_elapsed() {
  local s="$1"
  printf '%dm %ds' $((s / 60)) $((s % 60))
}

packer_winrm_port() {
  local line
  line="$(pgrep -af "qemu-system-x86_64.*${VM_NAME}" 2>/dev/null | head -1 || true)"
  sed -n 's/.*hostfwd=tcp::\([0-9][0-9]*\)-:5985.*/\1/p' <<<"$line"
}

winrm_port_open() {
  local port="$1"
  [[ -n "$port" ]] || return 1
  (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null
}

force_stop_qemu() {
  local pid elapsed="$1"
  echo "WARN: QEMU still running after $(format_elapsed "$elapsed") — sending SIGTERM (guest shutdown may be stuck)." >&2
  echo "  Check VNC: ./scripts/show-packer-console.sh" >&2
  echo "  Orphan sysprep shutdown-guard.ps1 on the guest can block shutdown /a in a loop." >&2
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    echo "  SIGTERM pid $pid" >&2
    kill -TERM "$pid" 2>/dev/null || true
  done < <(packer_qemu_pids)
  sleep 15
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "  SIGKILL pid $pid" >&2
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done < <(packer_qemu_pids)
}

if ! packer_qemu_running; then
  echo "QEMU for $VM_NAME is not running (already exited)." >&2
  exit 0
fi

echo "Waiting up to ${TIMEOUT}s for guest shutdown and QEMU exit ($VM_NAME)..." >&2
echo "  Progress every ${LOG_INTERVAL}s; SIGTERM after $(format_elapsed "$FORCE_AFTER") if still running." >&2
pgrep -af "qemu-system-x86_64.*${VM_NAME}" 2>/dev/null | head -3 >&2 || true

started=$SECONDS
deadline=$((SECONDS + TIMEOUT))
last_log=$SECONDS
forced=0

while ((SECONDS < deadline)); do
  if ! packer_qemu_running; then
    echo "QEMU for $VM_NAME has exited after $(format_elapsed $((SECONDS - started)))." >&2
    exit 0
  fi

  elapsed=$((SECONDS - started))
  if ((forced == 0 && elapsed >= FORCE_AFTER)); then
    force_stop_qemu "$elapsed"
    forced=1
    last_log=$SECONDS
  fi

  if ((SECONDS - last_log >= LOG_INTERVAL)); then
    echo "  Still waiting ($(format_elapsed elapsed))..." >&2
    pgrep -af "qemu-system-x86_64.*${VM_NAME}" 2>/dev/null | head -1 >&2 || true
    winrm_port="$(packer_winrm_port || true)"
    if winrm_port_open "$winrm_port"; then
      echo "  Guest still running (WinRM 127.0.0.1:${winrm_port} open). Login screen = shutdown failed." >&2
      echo "  VNC: ./scripts/show-packer-console.sh — sign in as Administrator, then in PowerShell:" >&2
      echo "    Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | ? { \$_.CommandLine -like '*sysprep-shutdown-guard*' } | % { Stop-Process -Id \$_.ProcessId -Force }" >&2
      echo "    shutdown /s /t 0 /f" >&2
      echo "  First verify sysprep succeeded: Test-Path C:\\Windows\\System32\\Sysprep\\Sysprep_succeeded.tag" >&2
    fi
    last_log=$SECONDS
  fi

  sleep 2
done

echo "ERROR: timed out after ${TIMEOUT}s waiting for QEMU ($VM_NAME) to exit" >&2
pgrep -af "qemu-system-x86_64.*${VM_NAME}" 2>/dev/null || true
exit 1
