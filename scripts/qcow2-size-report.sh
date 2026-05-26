#!/usr/bin/env bash
# Report qcow2 virtual size (DataVolume minimum) and on-disk file size.
# Usage: qcow2-size-report.sh [path.qcow2 ...]
#        qcow2-size-report.sh --all
#        qcow2-size-report.sh --json [path.qcow2 ...]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON=0
ALL=0
declare -a paths=()

usage() {
  cat <<EOF
Usage: qcow2-size-report.sh [--json] [--all] [path.qcow2 ...]

Reports:
  - virtual size  -> minimum OpenShift DataVolume / PVC storage request
  - file size     -> bytes stored in the qcow2 file (upload/registry footprint)

With no paths, reports the newest golden image under output/ or packer/output/.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --json)
      JSON=1
      shift
      ;;
    --all)
      ALL=1
      shift
      ;;
    --)
      shift
      paths+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done

if [[ "$ALL" == "1" ]]; then
  mapfile -t paths < <("$ROOT/scripts/find-golden-qcow2.sh" --all)
fi

if ((${#paths[@]} == 0)); then
  paths=("$( "$ROOT/scripts/find-golden-qcow2.sh")")
fi

require_qemu_img() {
  command -v qemu-img >/dev/null 2>&1 || {
    echo "qemu-img not found (install qemu-img)" >&2
    exit 1
  }
}

bytes_to_gib_ceil() {
  local bytes="$1"
  echo $(( (bytes + 1073741824 - 1) / 1073741824 ))
}

human_bytes() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes"
  else
    echo "${bytes} bytes"
  fi
}

read_qcow2_info() {
  local image="$1"
  qemu-img info --output=json "$image"
}

report_one_json() {
  local image="$1"
  local info virtual_bytes file_bytes dv_gib
  info="$(read_qcow2_info "$image")"
  virtual_bytes="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])' <<<"$info")"
  file_bytes="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["actual-size"])' <<<"$info")"
  dv_gib="$(bytes_to_gib_ceil "$virtual_bytes")"
  python3 - <<PY
import json
print(json.dumps({
    "path": "$image",
    "virtual_size_bytes": int("$virtual_bytes"),
    "file_size_bytes": int("$file_bytes"),
    "datavolume_storage_gi": int("$dv_gib"),
    "datavolume_storage": f"{int('$dv_gib')}Gi",
}))
PY
}

report_one_human() {
  local image="$1"
  local info virtual_bytes file_bytes dv_gib format_name
  info="$(read_qcow2_info "$image")"
  virtual_bytes="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])' <<<"$info")"
  file_bytes="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["actual-size"])' <<<"$info")"
  format_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("format","unknown"))' <<<"$info")"
  dv_gib="$(bytes_to_gib_ceil "$virtual_bytes")"

  cat <<EOF
Image: $image
  Format:              $format_name
  Virtual size:        $(human_bytes "$virtual_bytes") ($virtual_bytes bytes)
  File size on disk:   $(human_bytes "$file_bytes") ($file_bytes bytes)
  DataVolume minimum:  ${dv_gib}Gi  (storage.requests.storage: ${dv_gib}Gi)
  virtctl upload size: --size=${dv_gib}Gi
EOF
}

require_qemu_img

first=1
for image in "${paths[@]}"; do
  [[ -f "$image" ]] || {
    echo "Not a file: $image" >&2
    exit 1
  }
  if [[ "$JSON" == "1" ]]; then
    if [[ "$first" == "1" && ${#paths[@]} -gt 1 ]]; then
      echo '['
    fi
    if [[ "$first" == "0" ]]; then
      if ((${#paths[@]} > 1)); then
        echo ','
      else
        echo
      fi
    fi
    if ((${#paths[@]} == 1)); then
      report_one_json "$image"
    else
      report_one_json "$image" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))'
    fi
    first=0
  else
    [[ "$first" == "1" ]] || echo
    report_one_human "$image"
    first=0
  fi
done

if [[ "$JSON" == "1" && ${#paths[@]} -gt 1 ]]; then
  echo ']'
fi
