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
| `output/.packer-2022/packer-win2022-standard-install.qcow2` | **Install** (virt-install pass 1). Usually **MBR** until provision runs. Untouched if provision failed early. |
| `output/.packer-2022/work/packer-win2022-standard-provision` | **Provision** VM disk (`efi_boot=true` path). May be **GPT** if `mbr2gpt` already ran. |
| `output/.packer-2022/work/packer-win2022-standard` | **Single-pass** SeaBIOS build (`windows-golden-image`). May be **GPT** if provision failed after `mbr2gpt`. |
| `output/.packer-2022/recovery/salvage-*.qcow2` | Safe copy made by `recover-provision` before retry. |

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

Skips virt-install (~45 min) and re-runs the full Packer provision pass (mbr2gpt, virtio, sysprep).

### Provision failed after `mbr2gpt` (SeaBIOS prompt / stuck reboot)

Work disk is **GPT**; Packer rebooted with **SeaBIOS** instead of OVMF.

Requirements:

1. `efi_boot = true` in `build.pkrvars.hcl`
2. Recover from the **work** disk (or a copy), not the install disk

```bash
EXECUTE=1 make recover-provision VERSION=2022
```

This copies `work/packer-win*` to `recovery/salvage-*.qcow2` and runs `build-provision-only` with OVMF.

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
| `BASE_IMAGE=...-install.qcow2` after `mbr2gpt` failed on work disk | Install image is still **MBR**; you lose progress and re-run `mbr2gpt` |
| `efi_boot=false` with a GPT work disk | SeaBIOS cannot boot post-`mbr2gpt` disks |
| `packer build .` without `-only` | Starts multiple builds / two VMs |

## Build paths (for context)

| `make` target | Packer build id | Firmware during provision |
|---------------|-----------------|---------------------------|
| `make build` (`efi_boot=true`) | `windows-golden-provision-only` | OVMF |
| `make build` (`efi_boot=false`) | `windows-golden-image` | SeaBIOS (no `mbr2gpt` in current templates) |

Production OpenShift images: **`efi_boot = true`** ([uefi-install.md](uefi-install.md)).

| `unsupported bus type 'sata'` on provision | Packer QEMU uses `-drive if=sata`, which q35 rejects. Fixed: provision pass uses `provision_disk_interface=ide` (default). Update and retry. |

## When to give up and reinstall

- Install qcow2 is missing and work disk is corrupt or absent: `make build-version VERSION=2022`
- You changed provision scripts significantly and want a clean run: `make clean` then full `make build`
