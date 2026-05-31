#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Show VNC port and work directory for a running Packer QEMU provision VM.
set -euo pipefail

mapfile -t lines < <(pgrep -af 'qemu-system-x86_64.*packer-win' 2>/dev/null || true)

if ((${#lines[@]} == 0)); then
  echo "No Packer provision QEMU process found (pgrep qemu-system-x86_64.*packer-win)." >&2
  exit 1
fi

for line in "${lines[@]}"; do
  name="$(sed -n 's/.*-name \([^ ]*\).*/\1/p' <<<"$line")"
  vnc_disp="$(sed -n 's/.*-vnc 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' <<<"$line")"
  disk="$(sed -n 's/.*-drive file=\([^,]*packer-win[^,]*\),.*/\1/p' <<<"$line" | head -1)"
  winrm_port="$(sed -n 's/.*hostfwd=tcp::\([0-9][0-9]*\)-:5985.*/\1/p' <<<"$line")"

  echo "VM:      ${name:-unknown}"
  if [[ -n "$disk" ]]; then
    echo "Work:    $(dirname "$disk")/"
    echo "Disk:    $disk"
  fi
  if [[ -n "$vnc_disp" ]]; then
    echo "VNC:     vncviewer 127.0.0.1:$((5900 + vnc_disp))  (display :${vnc_disp})"
  else
    echo "VNC:     not found on command line (try: pgrep -af qemu-system)" >&2
  fi
  if [[ -n "$winrm_port" ]]; then
    echo "WinRM:   localhost:${winrm_port} (forwarded to guest :5985)"
  fi
  if grep -q -- '-display gtk' <<<"$line"; then
    echo "Note:    QEMU also has a local GTK window; if VNC is blank, check the desktop for a VM window."
  fi
  if grep -q 'ide-hd,drive=disk0,bus=ide.0,bootindex=1' <<<"$line"; then
    echo "Boot:    IDE (ide.0) with bootindex=1 (matches libvirt import)"
  elif grep -q 'ich9-ahci' <<<"$line" && grep -q 'bootindex=1' <<<"$line"; then
    echo "WARN:    ich9-ahci OVMF boot may loop; expect ide-hd on ide.0 in current templates." >&2
  fi
  if grep -q 'scsi-hd,bus=scsi0.0,drive=drive0' <<<"$line" && ! grep -q 'bootindex=1' <<<"$line"; then
    echo "WARN:    scsi-hd has no bootindex=1 — OVMF may PXE-loop (blank VNC)." >&2
  fi
  if grep -q 'if=none.*id=drive0' <<<"$line" && ! grep -q 'virtio-scsi-pci\|scsi-hd' <<<"$line"; then
    echo "ERROR:   Disk drive0 is not attached (missing virtio-scsi-pci/scsi-hd)." >&2
    echo "         Remove partial qemuargs -device overrides from from_install_gpt; rebuild." >&2
  fi
  if grep -q 'if=pflash.*format=raw' <<<"$line"; then
    echo "WARN:    OVMF pflash uses format=raw; Fedora OVMF files are qcow2 — expect boot loop." >&2
  fi
  if grep -q 'if=ide,' <<<"$line" && grep -q 'type=q35' <<<"$line"; then
    :
  fi
  echo ""
done
