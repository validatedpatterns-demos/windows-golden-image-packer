#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Temp files for build/inspect scripts live under output/.build-tmp (not /tmp).
# Override: BUILD_TMPDIR=/path/on/large/disk
#
# shellcheck shell=bash

build_temp_dir() {
  local root="${BUILD_TEMP_ROOT:-${WINDOWS_GOLDEN_ROOT:-}}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  local base="${BUILD_TMPDIR:-$root/output/.build-tmp}"
  mkdir -p "$base"
  printf '%s' "$base"
}

build_mktemp() {
  mktemp --tmpdir="$(build_temp_dir)" "$@"
}

build_mktemp_dir() {
  mktemp -d --tmpdir="$(build_temp_dir)" "${1:-tmp.XXXXXX}"
}
