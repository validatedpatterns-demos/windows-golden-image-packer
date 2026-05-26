# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Locate Packer QEMU output and rename to the golden-image filename.
# QEMU writes output_directory/vm_name with no .qcow2 extension unless vm_name includes it.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <output_directory> <vm_name> <target_filename>" >&2
  exit 1
fi

OUTPUT_DIR="$1"
VM_NAME="$2"
TARGET="$3"

if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "Output directory not found: $OUTPUT_DIR" >&2
  exit 1
fi

FOUND=""
for candidate in "$OUTPUT_DIR/$VM_NAME" "$OUTPUT_DIR/${VM_NAME}.qcow2"; do
  if [[ -f "$candidate" ]]; then
    FOUND="$candidate"
    break
  fi
done

if [[ -z "$FOUND" ]]; then
  FOUND=$(find "$OUTPUT_DIR" -maxdepth 2 -type f \( -name '*.qcow2' -o -name "$VM_NAME" \) 2>/dev/null | head -1)
fi

if [[ -z "$FOUND" ]]; then
  echo "No QEMU disk image found in $OUTPUT_DIR (expected file named $VM_NAME or *.qcow2)" >&2
  echo "Directory listing:" >&2
  ls -la "$OUTPUT_DIR" >&2
  exit 1
fi

TARGET_PATH="$OUTPUT_DIR/$TARGET"
if [[ "$FOUND" != "$TARGET_PATH" ]]; then
  mv -f "$FOUND" "$TARGET_PATH"
fi

echo "Golden image: $TARGET_PATH"
