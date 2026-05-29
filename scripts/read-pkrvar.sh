# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# Read a simple top-level value from a Packer .pkrvars.hcl / .hcl file.
# Usage: read-pkrvar.sh <key> [var_file] [default]
set -euo pipefail

KEY="${1:?key required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${2:-$ROOT/build.pkrvars.hcl}"
DEFAULT="${3:-}"

if [[ ! -f "$FILE" ]]; then
  echo "$DEFAULT"
  exit 0
fi

VAL=""
if grep -qE "^[[:space:]]*${KEY}[[:space:]]*=" "$FILE" 2>/dev/null; then
  VAL="$(grep -E "^[[:space:]]*${KEY}[[:space:]]*=" "$FILE" | tail -1 \
    | sed -E 's/#.*$//; s/^[[:space:]]*[^=]+=[[:space:]]*"([^"]*)".*/\1/; s/^[[:space:]]*[^=]+=[[:space:]]*([^[:space:]]+).*/\1/; s/[[:space:]]+$//')"
fi

if [[ -z "$VAL" ]]; then
  echo "$DEFAULT"
else
  echo "$VAL"
fi
