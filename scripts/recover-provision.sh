#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Diagnose a failed or interrupted Packer build and retry provision without reinstalling Windows.
#
# Usage:
#   ./scripts/recover-provision.sh                         # list disks + recommended commands
#   ./scripts/recover-provision.sh --execute               # run the best recovery for VERSION
#   ./scripts/recover-provision.sh --execute --from PATH   # provision from a specific qcow2 copy
#   VERSION=2022 ./scripts/recover-provision.sh
#
# Environment:
#   VERSION           Windows Server version (2022 or 2025). Default: newest .packer-* staging dir.
#   WINDOWS_EDITION   Standard (default) or Datacenter
#   VAR_FILE          Packer var file (default: build.pkrvars.hcl)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
WINDOWS_EDITION="${WINDOWS_EDITION:-$("$ROOT/scripts/read-pkrvar.sh" windows_edition "$VAR_FILE" Standard)}"
EDITION_LC="$(echo "$WINDOWS_EDITION" | tr '[:upper:]' '[:lower:]')"
EXECUTE=0
FROM_IMAGE=""

# shellcheck source=scripts/libvirt-vm-disk.sh
source "$ROOT/scripts/libvirt-vm-disk.sh"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --execute) EXECUTE=1; shift ;;
    --from)
      FROM_IMAGE="${2:?--from requires a qcow2 path}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage 1
      ;;
  esac
done

disk_gpt_hint() {
  local image="$1"
  if ! command -v virt-filesystems >/dev/null 2>&1; then
    echo unknown
    return
  fi
  if golden_image_has_efi_partition "$image"; then
    echo GPT
  else
    echo MBR
  fi
}

file_size_human() {
  local f="$1"
  if [[ -f "$f" ]]; then
    du -h "$f" | awk '{print $1}'
  else
    echo "-"
  fi
}

resolve_install_disk() {
  "$ROOT/scripts/resolve-install-disk.sh" "$1" "$2" "$EDITION_LC" 2>/dev/null || true
}

resolve_work_disks() {
  local staging="$1" version="$2"
  local work="$staging/work"
  local -a found=()
  local f base

  [[ -d "$work" ]] || return 0

  shopt -s nullglob
  for f in \
    "$work/packer-win${version}-${EDITION_LC}-provision" \
    "$work/packer-win${version}-${EDITION_LC}-provision.qcow2" \
    "$work/packer-win${version}-${EDITION_LC}" \
    "$work/packer-win${version}-${EDITION_LC}.qcow2"; do
    [[ -f "$f" ]] && found+=("$f")
  done
  shopt -u nullglob

  ((${#found[@]} > 0)) && printf '%s\n' "${found[@]}"
}

newest_staging_version() {
  local d ver newest=""
  local newest_mtime=0 mtime
  for d in "$ROOT"/output/.packer-*; do
    [[ -d "$d" ]] || continue
    ver="${d##*/.packer-}"
    mtime="$(stat -c %Y "$d" 2>/dev/null || echo 0)"
    if (( mtime >= newest_mtime )); then
      newest_mtime=$mtime
      newest="$ver"
    fi
  done
  echo "$newest"
}

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(newest_staging_version)"
fi
if [[ -z "$VERSION" ]]; then
  echo "ERROR: No output/.packer-* staging directory found. Run make build first." >&2
  exit 1
fi

STAGING="$ROOT/output/.packer-${VERSION}"
if [[ ! -d "$STAGING" ]]; then
  echo "ERROR: Staging directory not found: $STAGING" >&2
  echo "Set VERSION=2022 or VERSION=2025." >&2
  exit 1
fi

INSTALL_DISK="$(resolve_install_disk "$STAGING" "$VERSION" || true)"
mapfile -t WORK_DISKS < <(resolve_work_disks "$STAGING" "$VERSION" || true)

EFI_BOOT="$("$ROOT/scripts/read-pkrvar.sh" efi_boot "$VAR_FILE" true)"

echo "=== Recover provision (Windows Server ${VERSION} ${WINDOWS_EDITION}) ==="
echo "Staging:   $STAGING"
echo "efi_boot:  $EFI_BOOT (virt-install pass; provision picks SeaBIOS vs OVMF from disk layout)"
echo ""

if [[ -n "$INSTALL_DISK" ]]; then
  echo "Install disk (virt-install pass 1, usually MBR until provision runs mbr2gpt):"
  echo "  $INSTALL_DISK  ($(file_size_human "$INSTALL_DISK"), layout: $(disk_gpt_hint "$INSTALL_DISK"))"
else
  echo "Install disk: not found (expected packer-win${VERSION}-${EDITION_LC}-install[.qcow2])"
  echo "  -> single-pass SeaBIOS build, or install was removed"
fi
echo ""

if ((${#WORK_DISKS[@]} > 0)); then
  echo "In-progress Packer work disks (PACKER_ON_ERROR=abort keeps these on failure):"
  for f in "${WORK_DISKS[@]}"; do
    echo "  $f  ($(file_size_human "$f"), layout: $(disk_gpt_hint "$f"))"
  done
  echo ""
  echo "  WARNING: Packer -force deletes $STAGING/work/. Never point BASE_IMAGE at a file inside work/."
else
  echo "Work disks: none under $STAGING/work/"
  echo ""
fi

# Pick recommended source disk (prefer GPT work disk = resume after mbr2gpt).
RECOMMENDED=""
RECOMMENDED_REASON=""
REDO_FROM_INSTALL=0

if [[ -n "$FROM_IMAGE" ]]; then
  FROM_IMAGE="$(readlink -f "$FROM_IMAGE")"
  [[ -f "$FROM_IMAGE" ]] || { echo "ERROR: --from image not found: $FROM_IMAGE" >&2; exit 1; }
  RECOMMENDED="$FROM_IMAGE"
  RECOMMENDED_REASON="user --from"
elif ((${#WORK_DISKS[@]} > 0)); then
  # Prefer newest GPT work disk (partial provision, including post-mbr2gpt).
  for f in "${WORK_DISKS[@]}"; do
    if [[ "$(disk_gpt_hint "$f")" == GPT ]]; then
      RECOMMENDED="$f"
      RECOMMENDED_REASON="resume partial provision (disk already GPT / mbr2gpt done)"
      break
    fi
  done
  if [[ -z "$RECOMMENDED" ]]; then
    RECOMMENDED="${WORK_DISKS[0]}"
    RECOMMENDED_REASON="resume partial provision (work disk still MBR)"
  fi
elif [[ -n "$INSTALL_DISK" ]]; then
  REDO_FROM_INSTALL=1
  RECOMMENDED="$INSTALL_DISK"
  RECOMMENDED_REASON="redo full provision from untouched install image"
fi

echo "=== Recommended recovery ==="
echo ""

if [[ -z "$RECOMMENDED" ]]; then
  echo "No qcow2 found to recover. Checked install + work paths under $STAGING." >&2
  echo "Run: make build-version VERSION=${VERSION}" >&2
  exit 1
fi

if [[ "$REDO_FROM_INSTALL" -eq 1 ]]; then
  echo "Situation: install finished; provision never started or work/ was removed."
  echo "Action:    redo provision from install disk (re-runs mbr2gpt + virtio + sysprep)."
  echo ""
  echo "  SKIP_INSTALL=1 make build-version VERSION=${VERSION}"
  echo ""
  echo "Equivalent manual pass (same as make build when efi_boot=true):"
  echo "  make build-provision-only \\"
  echo "    VERSION=${VERSION} \\"
  echo "    BASE_IMAGE=${INSTALL_DISK}"
  if [[ "$EXECUTE" -eq 1 ]]; then
    echo ""
    echo "Executing: SKIP_INSTALL=1 make build-version VERSION=${VERSION}"
    exec make -C "$ROOT" build-version VERSION="$VERSION" SKIP_INSTALL=1
  fi
  exit 0
fi

LAYOUT="$(disk_gpt_hint "$RECOMMENDED")"
if [[ "$LAYOUT" == GPT ]]; then
  FIRMWARE_MSG="OVMF/q35 (auto-detected GPT disk)"
else
  FIRMWARE_MSG="SeaBIOS/pc (MBR install or pre-mbr2gpt work disk)"
fi

RECOVERY_DIR="$STAGING/recovery"
SAFE_COPY="$RECOVERY_DIR/salvage-${VERSION}-${EDITION_LC}.qcow2"

echo "Situation: $RECOMMENDED_REASON"
echo "Source:    $RECOMMENDED ($LAYOUT)"
echo "Action:    copy out of work/, then run provision-only ($FIRMWARE_MSG)."
echo ""
echo "  EXECUTE=1 make recover-provision VERSION=${VERSION}"
echo ""
echo "Manual steps:"
echo "  mkdir -p $RECOVERY_DIR"
echo "  cp -a '$RECOMMENDED' '$SAFE_COPY'"
echo "  make build-provision-only VERSION=${VERSION} BASE_IMAGE='$SAFE_COPY'"
echo ""

if [[ "$EXECUTE" -ne 1 ]]; then
  exit 0
fi

if [[ "$LAYOUT" == GPT ]]; then
  if [[ -f "$SAFE_COPY" ]]; then
    schedule_profile=provision-gpt
  else
    schedule_profile=recover-gpt
  fi
else
  if [[ -f "$SAFE_COPY" ]]; then
    schedule_profile=provision-mbr
  else
    schedule_profile=recover-mbr
  fi
fi
BUILD_SCHEDULE_LOG="$STAGING/build-schedule.log" "$ROOT/scripts/print-build-schedule.sh" "$schedule_profile"
echo ""

mkdir -p "$RECOVERY_DIR"
if [[ -f "$SAFE_COPY" ]]; then
  echo "Reusing existing recovery copy: $SAFE_COPY" >&2
  echo "Delete it first to re-copy from work/." >&2
else
  echo "Copying work disk -> $SAFE_COPY (this may take a few minutes)..." >&2
  cp -a "$RECOMMENDED" "$SAFE_COPY"
fi

exec make -C "$ROOT" build-provision-only VERSION="$VERSION" BASE_IMAGE="$SAFE_COPY"
