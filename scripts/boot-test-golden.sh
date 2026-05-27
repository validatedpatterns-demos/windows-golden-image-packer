# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Run boot-test-image.sh on one or more golden qcow2 images.
#
# Usage:
#   boot-test-golden.sh [--all | --version 2022|2025] [boot-test-image.sh options...]
#
# Examples:
#   boot-test-golden.sh
#   boot-test-golden.sh --all
#   boot-test-golden.sh --version 2025 --no-guest-check
#   boot-test-golden.sh --image output/windows-server-2025-standard.qcow2
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOT_TEST="$ROOT/scripts/boot-test-image.sh"

MODE="newest"
VERSION=""
FORWARD=()

usage() {
  echo "Usage: $0 [--all | --version 2022|2025] [boot-test-image.sh options...]"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --all) MODE="all"; shift ;;
    --version)
      VERSION="$2"
      MODE="filter"
      shift 2
      ;;
    --image)
      exec "$BOOT_TEST" "$@"
      ;;
    *)
      FORWARD+=("$1")
      shift
      ;;
  esac
done

case "$MODE" in
  newest)
    exec "$BOOT_TEST" "${FORWARD[@]}"
    ;;
  all|filter)
    mapfile -t images < <("$ROOT/scripts/find-golden-qcow2.sh" --all)
    if ((${#images[@]} == 0)); then
      echo "No golden images found" >&2
      exit 1
    fi
    failed=0
    tested=0
    for img in "${images[@]}"; do
      [[ "$img" == *-install.qcow2 ]] && continue
      if [[ "$MODE" == filter ]]; then
        case "$VERSION" in
          2022|2025) ;;
          *)
            echo "Invalid --version: $VERSION (use 2022 or 2025)" >&2
            exit 1
            ;;
        esac
        if [[ "$img" != *"windows-server-${VERSION}-"* ]]; then
          continue
        fi
      fi
      echo "========================================" >&2
      echo "Boot test: $img" >&2
      echo "========================================" >&2
      tested=$((tested + 1))
      if ! "$BOOT_TEST" --image "$img" "${FORWARD[@]}"; then
        failed=$((failed + 1))
      fi
    done
    if ((tested == 0)); then
      echo "No images matched the filter (version=${VERSION:-n/a})" >&2
      exit 1
    fi
    if ((failed > 0)); then
      echo "$failed boot test(s) failed" >&2
      exit 1
    fi
    echo "All $tested boot test(s) passed" >&2
    ;;
esac
