#!/usr/bin/env bash
# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Render Packer unattend answer files and validate XML plus Microsoft pass rules.
# Fails fast before a long sysprep run when templates put settings in invalid passes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/build-temp.sh
source "$ROOT/scripts/build-temp.sh"
PACKER_DIR="$ROOT/packer"
VAR_FILE="${VAR_FILE:-$ROOT/build.pkrvars.hcl}"
VALIDATE_VAR_FILE="${VALIDATE_VAR_FILE:-$ROOT/packer/ci.pkrvars.hcl}"
VERSIONS="${VALIDATE_VERSIONS:-2022 2025}"

usage() {
  cat <<'EOF'
Usage: validate-unattend.sh

Environment:
  VAR_FILE            Packer var file for rendering (default: build.pkrvars.hcl)
  VALIDATE_VAR_FILE   Fallback var file when VAR_FILE is missing (default: packer/ci.pkrvars.hcl)
  VALIDATE_VERSIONS   Space-separated Windows versions to check (default: "2022 2025")
  PACKER              Override packer binary (default: resolve-packer.sh)

Requires: packer (after packer init), xmllint, python3
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for cmd in xmllint python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "validate-unattend: missing required command: $cmd" >&2
    exit 1
  fi
done

# shellcheck source=scripts/resolve-packer.sh
source "$ROOT/scripts/resolve-packer.sh"
PACKER_BIN="$(resolve_packer)" || {
  echo "validate-unattend: packer not found (run: make init or set PACKER=/path/to/packer)" >&2
  exit 1
}

render_var_file="$VAR_FILE"
if [[ ! -f "$render_var_file" && -f "$ROOT/$render_var_file" ]]; then
  render_var_file="$ROOT/$render_var_file"
fi
if [[ ! -f "$render_var_file" && -f "$PACKER_DIR/$render_var_file" ]]; then
  render_var_file="$PACKER_DIR/$render_var_file"
fi
if [[ ! -f "$render_var_file" ]]; then
  render_var_file="$VALIDATE_VAR_FILE"
fi
if [[ ! -f "$render_var_file" && -f "$ROOT/$render_var_file" ]]; then
  render_var_file="$ROOT/$render_var_file"
fi
if [[ ! -f "$render_var_file" && -f "$PACKER_DIR/$render_var_file" ]]; then
  render_var_file="$PACKER_DIR/$render_var_file"
fi
if [[ ! -f "$render_var_file" ]]; then
  echo "validate-unattend: no var file found (tried VAR_FILE and VALIDATE_VAR_FILE)" >&2
  exit 1
fi
render_var_file="$(readlink -f "$render_var_file")"

render_packer_local() {
  local local_expr="$1"
  local version="$2"
  local efi_boot="${3:-}"

  local -a extra_vars=(-var "windows_version=${version}")
  if [[ -n "$efi_boot" ]]; then
    extra_vars+=(-var "efi_boot=${efi_boot}")
  fi

  cd "$PACKER_DIR"
  "$PACKER_BIN" console -var-file="$render_var_file" "${extra_vars[@]}" . <<EOF | sed -n '/^<?xml/,/^<\/unattend>/p'
${local_expr}
EOF
}

tmpdir="$(build_mktemp_dir validate-unattend.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

render_to_file() {
  local label="$1"
  local local_expr="$2"
  local version="$3"
  local efi_boot="${4:-}"
  local dest="$tmpdir/${label}.xml"

  if ! render_packer_local "$local_expr" "$version" "$efi_boot" >"$dest"; then
    echo "FAIL: could not render $label (packer console)" >&2
    return 1
  fi

  if [[ ! -s "$dest" ]]; then
    echo "FAIL: rendered $label is empty" >&2
    return 1
  fi

  if ! xmllint --noout "$dest" 2>"$tmpdir/${label}.xmllint"; then
    echo "FAIL: $label is not well-formed XML:" >&2
    cat "$tmpdir/${label}.xmllint" >&2
    return 1
  fi

  printf '%s\n' "$dest"
}

validate_profile() {
  local profile="$1"
  local xml_path="$2"
  python3 - "$profile" "$xml_path" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

profile = sys.argv[1]
path = sys.argv[2]
UNATTEND_NS = "urn:schemas-microsoft-com:unattend"
NS = {"u": UNATTEND_NS}

tree = ET.parse(path)
root = tree.getroot()

def local_tag(elem):
    tag = elem.tag
    return tag.split("}", 1)[1] if tag.startswith("{") else tag

def passes_present():
    return {s.get("pass") for s in root.findall(f".//{{{UNATTEND_NS}}}settings") if s.get("pass")}

def settings_for(pass_name):
    return root.findall(f'.//{{{UNATTEND_NS}}}settings[@pass="{pass_name}"]')

def has_element(settings_elem, name):
    for elem in settings_elem.iter():
        if local_tag(elem) == name:
            return True
    return False

def raw_text():
    with open(path, encoding="utf-8") as fh:
        return fh.read()

errors = []
passes = passes_present()
raw = raw_text()

def fail(msg):
    errors.append(msg)

if profile == "sysprep-generalize":
    if "generalize" not in passes:
        fail("missing settings pass=\"generalize\"")
    if "oobeSystem" in passes:
        fail("must not contain pass=\"oobeSystem\" (use sysprep-oobe.xml for first deploy boot)")
    if "windowsPE" in passes:
        fail("must not contain pass=\"windowsPE\" (install autounattend only)")

    for settings in settings_for("generalize"):
        for forbidden in ("RunSynchronous", "Reseal", "RunAsynchronous"):
            if has_element(settings, forbidden):
                fail(
                    f"pass=\"generalize\" contains <{forbidden}> "
                    f"(valid in specialize/auditUser for RunSynchronous; "
                    f"auditSystem/auditUser/oobeSystem for Reseal)"
                )

    if not any(has_element(s, "SkipRearm") for s in settings_for("generalize")):
        fail("pass=\"generalize\" should include Microsoft-Windows-Security-SPP / SkipRearm")

elif profile == "sysprep-oobe":
    if "oobeSystem" not in passes:
        fail("missing settings pass=\"oobeSystem\"")
    if "generalize" in passes:
        fail("must not contain pass=\"generalize\"")
    if "windowsPE" in passes:
        fail("must not contain pass=\"windowsPE\"")

    if "Microsoft-Windows-International-Core" not in raw:
        fail("missing Microsoft-Windows-International-Core (locale OOBE will prompt)")

    for needle in (
        "<NetworkLocation>",
        'wasPassProcessed="',
        "WIN-PACKER",
    ):
        if needle in raw:
            fail(f"contains forbidden value {needle!r}")

    shell_setup = re.search(
        r"<component[^>]*Microsoft-Windows-Shell-Setup.*?</component>",
        raw,
        re.DOTALL,
    )
    if shell_setup and "<!--" in shell_setup.group(0):
        fail("contains XML comments inside Microsoft-Windows-Shell-Setup")

    if "<WillShowUI>" in raw:
        fail("contains WillShowUI (valid in windowsPE UserData only, not oobeSystem Shell-Setup)")

    if "pass=\"oobeSystem\"" in raw and re.search(
        r'<component[^>]*Microsoft-Windows-Shell-Setup[\s\S]*?<ProductKey',
        raw,
    ):
        fail(
            "Shell-Setup ProductKey is valid in specialize pass only "
            "(use RunSynchronous slmgr.vbs /ipk in oobeSystem instead)"
        )

    if "<Enabled>true</Enabled>" in raw:
        fail("AutoLogon Enabled=true (install autounattend, not sysprep OOBE)")

    if "SetupDisplayedProductKey" not in raw:
        fail(
            "missing RunSynchronous reg SetupDisplayedProductKey "
            "(generalize clears pre-sysprep value; OOBE shows product key page without it)"
        )

    for settings in settings_for("generalize"):
        for forbidden in ("RunSynchronous", "Reseal"):
            if has_element(settings, forbidden):
                fail(f"pass=\"generalize\" contains <{forbidden}>")

elif profile == "autounattend":
    if "windowsPE" not in passes:
        fail("missing settings pass=\"windowsPE\"")
    if "generalize" in passes:
        fail("must not contain pass=\"generalize\" (sysprep-generalize.xml only)")

    for settings in settings_for("generalize"):
        for forbidden in ("RunSynchronous", "Reseal"):
            if has_element(settings, forbidden):
                fail(f"pass=\"generalize\" contains <{forbidden}>")

else:
    fail(f"unknown profile {profile!r}")

if errors:
    print(f"FAIL: {path} ({profile})", file=sys.stderr)
    for err in errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {path} ({profile})")
PY
}

check_one() {
  local label="$1"
  local profile="$2"
  local local_expr="$3"
  local version="$4"
  local efi_boot="${5:-}"

  local rendered
  if ! rendered="$(render_to_file "$label" "$local_expr" "$version" "$efi_boot")"; then
    return 1
  fi
  validate_profile "$profile" "$rendered"
}

rc=0
echo "validate-unattend: rendering with $(basename "$render_var_file")" >&2

for version in $VERSIONS; do
  echo "=== Windows Server $version ===" >&2
  check_one "sysprep-generalize-${version}" "sysprep-generalize" \
    "local.sysprep_generalize_unattend" "$version" || rc=1
  check_one "sysprep-oobe-${version}" "sysprep-oobe" \
    "local.sysprep_oobe_unattend" "$version" || rc=1
  check_one "autounattend-uefi-${version}" "autounattend" \
    "local.autounattend" "$version" "true" || rc=1
  check_one "autounattend-bios-${version}" "autounattend" \
    "local.autounattend" "$version" "false" || rc=1
done

if [[ $rc -ne 0 ]]; then
  echo "validate-unattend: FAILED (fix http/*.xml.tpl before running sysprep)" >&2
  exit 1
fi

echo "validate-unattend: all checks passed" >&2
exit 0
