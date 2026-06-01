#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Print the Packer executable path. Honors PACKER when set and executable.
# Usage: PACKER_BIN="$(scripts/resolve-packer.sh)"   or   source scripts/resolve-packer.sh
set -euo pipefail

resolve_packer() {
  if [[ -n "${PACKER:-}" && -x "${PACKER}" ]]; then
    printf '%s\n' "$PACKER"
    return 0
  fi

  if command -v packer >/dev/null 2>&1; then
    command -v packer
    return 0
  fi

  local candidate
  for candidate in \
    /home/linuxbrew/.linuxbrew/bin/packer \
    "${HOME}/.linuxbrew/bin/packer" \
    /opt/homebrew/bin/packer \
    /usr/local/bin/packer; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_packer
fi
