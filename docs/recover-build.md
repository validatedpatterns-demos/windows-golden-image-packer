# Recovering a failed build

A full build can take ~90 minutes. Packer is configured to **keep disks on failure** (`PACKER_ON_ERROR=abort` in the Makefile) so you can retry provision without reinstalling Windows.

## Quick start

```bash
# 1. See what disks exist and which command to run (safe, read-only)
make recover-provision VERSION=2022

# 2. Run the recommended recovery
EXECUTE=1 make recover-provision VERSION=2022
```

`recover-provision` copies any in-progress work disk **out of `work/`** before starting Packer. Never point `BASE_IMAGE` at a file inside `work/` — `packer -force` deletes that directory.

## Where disks live

| Path | Meaning |
|------|---------|
| `output/.packer-2022/packer-win2022-standard-install.qcow2` | **Install** (virt-install pass 1). Untouched if provision failed early. |
| `output/.packer-2022/work/packer-win2022-standard-provision` | **Provision** VM disk (partial phase 2). |
| `output/.packer-2022/recovery/salvage-*.qcow2` | Safe copy made by `recover-provision` before retry. |
| `output/windows-server-2022-standard.qcow2` | **Golden** image after successful promote. |

Find candidates:

```bash
./scripts/find-golden-qcow2.sh
./scripts/inspect-golden-qcow2.sh output/.packer-2022/work/packer-win2022-standard-provision
```

## Which recovery to use

### Install finished, provision never ran (or `work/` was deleted)

Install disk exists; work disk missing or empty.

```bash
SKIP_INSTALL=1 make build-version VERSION=2022
```

Skips virt-install (~45 min) and re-runs the full Packer provision pass.

### Provision failed mid-way (VirtIO, sysprep, shrink, etc.)

Recover from the **work** disk (or a copy), not a stale path under `work/`:

```bash
EXECUTE=1 make recover-provision VERSION=2022
```

This copies `work/packer-win*` to `recovery/salvage-*.qcow2` and runs `build-provision-only`.

### Manual provision retry (when you already have a safe copy)

```bash
cp output/.packer-2022/work/packer-win2022-standard-provision \
   output/.packer-2022/recovery/salvage.qcow2

make build-provision-only \
  VERSION=2022 \
  BASE_IMAGE=output/.packer-2022/recovery/salvage.qcow2
```

## Common mistakes

| Mistake | Why it fails |
|---------|----------------|
| `BASE_IMAGE=.../work/packer-win...` | Packer `-force` wipes `work/` including your source disk |
| `BASE_IMAGE=...-install.qcow2` when work disk has provision progress | Install image has no WinRM provision / sysprep progress |
| `packer build .` without `-only` | Starts multiple builds / two VMs |

## Build paths (for context)

| `make` target | Packer build id | Notes |
|---------------|-----------------|-------|
| `make build` (`efi_boot=true`, default) | `windows-golden-provision` (`from_install_gpt`) | virt-install pass 1, then single OVMF + virtio-blk provision + sysprep |
| `make build-install` | `windows-install-only` | Phase 1 only |
| `make build-provision-only` | `windows-golden-provision` | Phase 2 from `BASE_IMAGE` |
| `make build` (`efi_boot=false`, legacy) | `windows-golden-image` | Single-pass SeaBIOS Packer install |

Production OpenShift images: **`efi_boot = true`** ([uefi-install.md](uefi-install.md), [tekton-aligned-build.md](tekton-aligned-build.md)).

| Sysprep **>45 minutes** with no log progress | Check VNC: `./scripts/show-packer-console.sh`. Extract logs: `make extract-sysprep-log IMAGE=...` |
| `Guest has not initialized the display` / blank VNC, **100% CPU** | Confirm OVMF pflash uses **`format=qcow2`** on firmware drives. Kill VM and retry. |
| `Disk ... is already in use by other guests ['win-uefi-install-2022']` | Stale **virt-install** domain. Run **`make clean`** (`virsh undefine --nvram`). |
| `permission denied` opening `packer-win*-install.qcow2` | Old disk owned by `nobody:nobody` from `qemu:///system`. New builds default to **`qemu:///session`**. One-time: `chown $USER:$USER ...` then `SKIP_INSTALL=1 make build-version VERSION=2022`. |

## When to give up and reinstall

- Install qcow2 is missing and work disk is corrupt or absent: `make build-version VERSION=2022`
- You changed provision scripts significantly and want a clean run: `make clean` then full `make build`
