#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Print cumulative local-time ETAs for golden-image build steps.
#
# Usage:
#   ./scripts/print-build-schedule.sh PROFILE
#   ./scripts/print-build-schedule.sh provision-gpt
#
# Profiles:
#   full-uefi        Phase 1 virt-install + Phase 2 SeaBIOS provision + promote
#   skip-install     Phase 2 SeaBIOS provision + promote (SKIP_INSTALL=1)
#   provision-mbr         Phase 2 SeaBIOS prep + chained OVMF sysprep
#   provision-gpt-sysprep OVMF sysprep only (after MBR prep)
#   provision-gpt    Phase 2 OVMF provision only (GPT / recovery disk)
#   recover-gpt      Copy work disk to recovery/ + provision-gpt
#   recover-mbr      Copy work disk to recovery/ + provision-mbr
#   install-only     Packer install pass only (make build-install)
#
# Environment:
#   BUILD_SCHEDULE_LOG  Optional file to append the same report (e.g. staging/build-schedule.log)
set -euo pipefail

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 PROFILE" >&2
  echo "Profiles: full-uefi skip-install provision-mbr provision-gpt provision-gpt-sysprep recover-gpt recover-mbr install-only" >&2
  exit 1
fi

start_epoch="$(date +%s)"
start_label="$(date '+%Y-%m-%d %H:%M %Z')"

format_epoch() {
  date -d "@$1" '+%H:%M' 2>/dev/null || date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1"
}

steps_for_profile() {
  case "$1" in
    full-uefi)
      cat <<'EOF'
Phase 1: Windows install (virt-install, UEFI + virtio-blk)|30|45|60
Phase 2: Waiting for WinRM|5|20|90
Upload scripts + drivers to guest|2|5|15
Verify UEFI + VirtIO boot drivers|2|5|10
QEMU-GA, OpenSSH, password, keys, locale|8|15|35
Disk shrink (06-shrink-disk, incl. cipher /w)|15|35|60
Sysprep + guest shutdown (OVMF/virtio-blk)|10|18|45
Finalize qcow2 + optimize|2|5|10
Golden image promoted to output/|0|1|2
EOF
      ;;
    skip-install)
      cat <<'EOF'
Phase 2: Waiting for WinRM|5|20|90
Upload scripts + drivers to guest|2|5|15
Verify UEFI + VirtIO boot drivers|2|5|10
QEMU-GA, OpenSSH, password, keys, locale|8|15|35
Disk shrink (06-shrink-disk, incl. cipher /w)|15|35|60
Sysprep + guest shutdown (OVMF/virtio-blk)|10|18|45
Finalize qcow2 + optimize|2|5|10
Golden image promoted to output/|0|1|2
EOF
      ;;
    provision-mbr)
      cat <<'EOF'
Waiting for WinRM|5|20|90
Upload scripts + VirtIO drivers to guest|2|5|15
VirtIO drivers + guest reboot|5|10|20
mbr2gpt + UEFI boot repair|3|8|15
QEMU-GA, OpenSSH, password, keys, locale|8|15|35
Disk shrink (06-shrink-disk, incl. cipher /w)|15|35|60
Guest shutdown (prep complete, no sysprep on SeaBIOS)|2|5|10
Phase 3: OVMF boot + UEFI BCD repair|3|8|15
Sysprep + guest shutdown (OVMF)|10|18|45
Finalize qcow2 + optimize|2|5|10
EOF
      ;;
    provision-gpt-sysprep)
      cat <<'EOF'
Waiting for WinRM (OVMF boot)|5|15|45
Upload sysprep scripts + unattend XML|1|3|8
UEFI BCD repair (07-repair-uefi-boot)|1|4|10
Sysprep + guest shutdown|10|18|45
Finalize qcow2 + optimize|2|5|10
EOF
      ;;
    provision-gpt)
      cat <<'EOF'
Waiting for WinRM (OVMF/virtio-blk boot)|5|15|45
Upload scripts + drivers to guest|2|5|15
Verify UEFI + VirtIO boot drivers|2|5|10
QEMU-GA, OpenSSH, password, keys, locale|8|15|35
Disk shrink (06-shrink-disk, incl. cipher /w)|15|35|60
Sysprep + guest shutdown|10|18|45
Finalize qcow2 + optimize|2|5|10
EOF
      ;;
    recover-gpt)
      cat <<'EOF'
Copy work disk to recovery/ (cp -a)|3|8|15
Waiting for WinRM (OVMF boot)|5|15|45
Upload sysprep scripts + unattend XML|1|3|8
UEFI BCD repair (07-repair-uefi-boot)|1|4|10
Sysprep + guest shutdown|10|18|45
Finalize qcow2 + optimize|2|5|10
EOF
      ;;
    recover-mbr)
      cat <<'EOF'
Copy work disk to recovery/ (cp -a)|3|8|15
Waiting for WinRM|5|20|90
Upload scripts + VirtIO drivers to guest|2|5|15
VirtIO drivers + guest reboot|5|10|20
mbr2gpt + UEFI boot repair|3|8|15
QEMU-GA, OpenSSH, password, keys, locale|8|15|35
Disk shrink (06-shrink-disk, incl. cipher /w)|15|35|60
Guest shutdown (prep complete, no sysprep on SeaBIOS)|2|5|10
Phase 3: OVMF boot + UEFI BCD repair|3|8|15
Sysprep + guest shutdown (OVMF)|10|18|45
Finalize qcow2 + optimize|2|5|10
EOF
      ;;
    install-only)
      cat <<'EOF'
Packer: Windows install (ISO + autounattend)|30|45|60
Install disk finalized|1|3|5
EOF
      ;;
    *)
      echo "Unknown profile: $1" >&2
      return 1
      ;;
  esac
}

if ! steps_for_profile "$PROFILE" >/dev/null; then
  exit 1
fi

cum_min=0
cum_typ=0
cum_max=0

lines=()
lines+=("Build schedule ($PROFILE)")
lines+=("Started: $start_label")
lines+=("")
lines+=("  Step                                      typical end   latest end")
lines+=("  ----------------------------------------  ------------  ------------")

while IFS='|' read -r label min_m typ_m max_m; do
  [[ -z "$label" ]] && continue
  cum_min=$((cum_min + min_m))
  cum_typ=$((cum_typ + typ_m))
  cum_max=$((cum_max + max_m))

  end_typ_epoch=$((start_epoch + cum_typ * 60))
  end_max_epoch=$((start_epoch + cum_max * 60))
  end_typ="$(format_epoch "$end_typ_epoch")"
  end_max="$(format_epoch "$end_max_epoch")"

  printf -v row '  %-42s  %12s  %12s' "$label" "$end_typ" "$end_max"
  lines+=("$row")
done < <(steps_for_profile "$PROFILE")

end_typ_epoch=$((start_epoch + cum_typ * 60))
end_max_epoch=$((start_epoch + cum_max * 60))
lines+=("")
lines+=("  Total typical duration: ${cum_typ} min (~$(format_epoch "$end_typ_epoch") today)")
lines+=("  Total latest estimate: ${cum_max} min (~$(format_epoch "$end_max_epoch") today)")
lines+=("")
lines+=("  Estimates only. WinRM wait, cipher /w, and Windows Update dominate variance.")

for line in "${lines[@]}"; do
  echo "$line"
done

if [[ -n "${BUILD_SCHEDULE_LOG:-}" ]]; then
  mkdir -p "$(dirname "$BUILD_SCHEDULE_LOG")"
  {
    echo "=== $start_label ==="
    for line in "${lines[@]}"; do
      echo "$line"
    done
    echo ""
  } >>"$BUILD_SCHEDULE_LOG"
fi
