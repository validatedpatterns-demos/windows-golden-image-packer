# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Package a qcow2 as a KubeVirt container disk and push to one or more Quay image references.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"

usage() {
  cat <<'EOF'
Usage: push-qcow2-to-quay.sh <qcow2-path> [quay.io/org/repo:tag ...]

If no image references are given, reads quay.env in the repo root (see example.quay.env).

Environment (optional overrides):
  QUAY_IMAGE_2022     Image ref for Windows Server 2022 builds
  QUAY_IMAGE_2025     Image ref for Windows Server 2025 builds
  QUAY_IMAGE_REFS     Space-separated list of refs (pushes the same disk to each)
  CONTAINER_TOOL      podman or docker (default: podman, then docker)
  BUILD_TMPDIR        Temp dir for small files (default: output/.build-tmp)
  QUAY_PUSH_WORK_DIR  Unused (kept for compatibility); build context is the qcow2 directory

Prerequisites: podman|docker login quay.io (or your registry host)

Disk space: the qcow2 is not copied into the build temp dir. Podman may still use
/var/lib/containers during layer commit (often needs ~1x image size free somewhere).
EOF
}

log() { printf '%s\n' "$*"; }

die() { log "ERROR: $*" >&2; exit 1; }

pick_container_tool() {
  if [[ -n "${CONTAINER_TOOL:-}" ]]; then
    command -v "$CONTAINER_TOOL" >/dev/null 2>&1 || die "CONTAINER_TOOL not found: $CONTAINER_TOOL"
    echo "$CONTAINER_TOOL"
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    echo podman
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    echo docker
    return
  fi
  die 'Install podman or docker, or set CONTAINER_TOOL'
}

detect_version_from_qcow2() {
  local base="$1"
  if [[ "$base" =~ windows-server-2025 ]]; then
    echo 2025
  elif [[ "$base" =~ windows-server-2022 ]]; then
    echo 2022
  else
    echo ""
  fi
}

load_quay_env() {
  local env_file="${QUAY_ENV_FILE:-$ROOT/quay.env}"
  [[ -f "$env_file" ]] || return 0
  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a
}

resolve_image_refs() {
  local qcow2_path="$1"
  shift
  local -a refs=("$@")
  local base version

  if ((${#refs[@]} > 0)); then
    printf '%s\n' "${refs[@]}"
    return
  fi

  load_quay_env

  if [[ -n "${QUAY_IMAGE_REFS:-}" ]]; then
    # shellcheck disable=SC2206
    refs=(${QUAY_IMAGE_REFS})
    printf '%s\n' "${refs[@]}"
    return
  fi

  base="$(basename "$qcow2_path")"
  version="$(detect_version_from_qcow2 "$base")"
  case "$version" in
    2022)
      [[ -n "${QUAY_IMAGE_2022:-}" ]] && echo "$QUAY_IMAGE_2022" && return
      ;;
    2025)
      [[ -n "${QUAY_IMAGE_2025:-}" ]] && echo "$QUAY_IMAGE_2025" && return
      ;;
  esac

  die "No Quay image ref for $base. Pass refs on the command line or set QUAY_IMAGE_${version:-*} in quay.env (see example.quay.env)."
}

verify_registry_login() {
  local tool="$1"
  local registry="$2"
  local user
  user="$("$tool" login "$registry" --get-login 2>/dev/null || true)"
  if [[ -z "$user" ]]; then
    die "Not logged in to $registry. Run: $tool login $registry"
  fi
  log "Registry login OK for $registry (user: $user)"
}

registry_from_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^([^/]+\.[^/]+)/ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo quay.io
  fi
}

build_container_disk() {
  local tool="$1"
  local qcow2_path="$2"
  local image_tag="$3"
  local abs_qcow2 qcow2_dir qcow2_name containerfile
  abs_qcow2="$(cd "$(dirname "$qcow2_path")" && pwd)/$(basename "$qcow2_path")"
  qcow2_dir="$(dirname "$abs_qcow2")"
  qcow2_name="$(basename "$abs_qcow2")"

  # Build from the qcow2 directory so we do not copy the full image into build temp.
  containerfile="$(build_mktemp containerfile.XXXXXX)"
  trap 'rm -f "$containerfile"' RETURN
  cat >"$containerfile" <<EOF
# KubeVirt / OpenShift Virtualization container disk (qemu uid 107).
FROM scratch
LABEL org.opencontainers.image.title="Windows golden image (container disk)"
COPY --chown=107:107 ${qcow2_name} /disk/disk.qcow2
EOF

  log "Building container disk image ($("$tool" --version | head -1))..."
  log "Build context: $qcow2_dir (qcow2 not staged in build temp dir)"
  "$tool" build --format docker -f "$containerfile" -t "$image_tag" "$qcow2_dir"
}

push_ref() {
  local tool="$1"
  local qcow2_path="$2"
  local image_ref="$3"
  local registry tmp_tag

  registry="$(registry_from_ref "$image_ref")"
  verify_registry_login "$tool" "$registry"

  tmp_tag="packer-golden-disk:build-$$"
  build_container_disk "$tool" "$qcow2_path" "$tmp_tag"

  log "Tagging and pushing $image_ref"
  "$tool" tag "$tmp_tag" "$image_ref"
  "$tool" push "$image_ref"
  "$tool" rmi -f "$tmp_tag" 2>/dev/null || true

  log "Pushed: $image_ref (also tagged locally)"
}

main() {
  local qcow2_path tool
  local -a image_refs=()

  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0
  [[ $# -ge 1 ]] || { usage >&2; exit 1; }

  qcow2_path="$1"
  shift
  [[ -f "$qcow2_path" ]] || die "qcow2 not found: $qcow2_path"

  mapfile -t image_refs < <(resolve_image_refs "$qcow2_path" "$@")
  ((${#image_refs[@]} > 0)) || die "No image references to push."

  tool="$(pick_container_tool)"
  log "Using $tool; qcow2: $qcow2_path ($(du -h "$qcow2_path" | cut -f1))"
  log "Targets: ${image_refs[*]}"

  for ref in "${image_refs[@]}"; do
    push_ref "$tool" "$qcow2_path" "$ref"
  done

  log "All pushes completed."
}

main "$@"
