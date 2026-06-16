#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Run the verify-sysprep-succeeded Ansible playbook against a running Packer QEMU VM.
# Only works before sysprep /generalize; after generalize use verify-sysprep-succeeded-offline.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"
PLAYBOOK="${ROOT}/ansible/playbooks/verify-sysprep-succeeded.yml"
REQUIREMENTS="${ROOT}/ansible/requirements.yml"

usage() {
  cat <<'EOF'
Usage: verify-sysprep-via-ansible.sh [options]

Connect to the running Packer provision VM over WinRM and verify
C:\Windows\System32\Sysprep\Sysprep_succeeded.tag exists.

Only valid BEFORE sysprep /generalize (new WinRM logins fail after generalize).
After sysprep, use scripts/verify-sysprep-succeeded-offline.sh on the stopped qcow2.

Environment:
  WINRM_PASSWORD   Guest Administrator password (required)
  WINRM_USER       WinRM user (default: Administrator)
  WINRM_HOST       Target host (default: 127.0.0.1)
  WINRM_PORT       Override forwarded WinRM port (default: auto from qemu)

Options:
  -h, --help       Show this help
EOF
}

WINRM_HOST="${WINRM_HOST:-127.0.0.1}"
WINRM_USER="${WINRM_USER:-Administrator}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${WINRM_PASSWORD:-}" ]]; then
  echo "WINRM_PASSWORD is not set (same value as admin_password in build.pkrvars.hcl)." >&2
  echo "Quote passwords that contain '!': export WINRM_PASSWORD='Redhat123!'" >&2
  exit 1
fi

if [[ -z "${WINRM_PORT:-}" ]]; then
  line="$(pgrep -af 'qemu-system-x86_64.*packer-win' 2>/dev/null | head -1 || true)"
  if [[ -z "$line" ]]; then
    echo "No Packer QEMU VM found. Start provision or set WINRM_PORT manually." >&2
    exit 1
  fi
  WINRM_PORT="$(sed -n 's/.*hostfwd=tcp::\([0-9][0-9]*\)-:5985.*/\1/p' <<<"$line")"
  if [[ -z "$WINRM_PORT" ]]; then
    echo "Could not parse WinRM hostfwd port from qemu command line." >&2
    echo "Run scripts/show-packer-console.sh or set WINRM_PORT." >&2
    exit 1
  fi
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook not found. Install ansible-core and ansible.windows collection." >&2
  exit 1
fi

if [[ -f "$REQUIREMENTS" ]]; then
  ansible-galaxy collection install -r "$REQUIREMENTS" >/dev/null 2>&1 || true
fi

tmpdir="$(build_mktemp_dir ansible-inventory.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"${tmpdir}/inventory.yml" <<EOF
all:
  hosts:
    packer_vm:
      ansible_host: ${WINRM_HOST}
      ansible_port: ${WINRM_PORT}
      ansible_connection: winrm
      ansible_winrm_scheme: http
      ansible_winrm_transport: ntlm
      ansible_winrm_message_encryption: always
      ansible_winrm_server_cert_validation: ignore
      ansible_user: ${WINRM_USER}
      ansible_password: "${WINRM_PASSWORD}"
EOF

echo "WinRM target: ${WINRM_HOST}:${WINRM_PORT} (user: ${WINRM_USER})"
ansible-playbook -i "${tmpdir}/inventory.yml" "$PLAYBOOK"
