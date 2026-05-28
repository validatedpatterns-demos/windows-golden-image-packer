# UEFI installs (OpenShift Virtualization)

Packer's QEMU builder on **Fedora with QEMU 10** attaches install media with legacy `-drive media=cdrom`. OVMF often will not boot the Microsoft ISO's **hidden EFI** El Torito image, and may try the empty VirtIO disk or the small **PROVISION** CD first, then fall back to PXE (`Boot002` / `Boot0003` errors).

With **`efi_boot = true`** (default in `example.pkrvars.hcl`), `make build` runs a **virt-install UEFI** install, then Packer provision + sysprep — disks match OpenShift Virtualization (UEFI + GPT).

Set **`efi_boot = false`** only for a one-shot **SeaBIOS** Packer build on hosts where the Windows ISO does not boot under OVMF in Packer (see below). Those disks must not be used in UEFI `VirtualMachine` specs.

## How `make build` works when `efi_boot = true`

Prerequisites: `virt-install`, `xorriso`, **`edk2-ovmf`** (4M OVMF for q35), **`swtpm`** (default **`vtpm = true`**), staged VirtIO drivers (`make stage-virtio`), and `build.pkrvars.hcl` paths.

The install script logs `Using OVMF: CODE=...` — on Fedora this should be **`OVMF_CODE_4M.qcow2`**, not `OVMF_CODE.fd` (2M often fails to boot on `machine q35`).

**Important:** `make clean` and the UEFI install script only **undefine** libvirt domains; they do **not** use `virsh undefine --remove-all-storage`, because that can delete host files attached as `--cdrom` (your Windows ISO under `~/iso/`). Install disks under `output/.packer-*` are removed by `make clean` via `rm`, not libvirt.

```bash
make stage-virtio
make build-2025    # or make build for both versions
```

Per version, `make build-version-uefi`:

1. Renders `http/autounattend-bios.xml.tpl` (MBR) or `autounattend.xml.tpl` (GPT) depending on `install_firmware`.
2. Builds a **virtual floppy** and **PROVISION** CD. The **Microsoft install ISO is not modified**.
3. Runs **virt-install** with **`install_firmware = "seabios"`** (default): **SeaBIOS** + `machine pc` boots the UDF DVD reliably. **Packer provision** then runs **`08-convert-mbr-to-uefi.ps1`** (`mbr2gpt`) and boots with **OVMF** on **q35** for virtio + sysprep.
4. Optional **`install_firmware = "uefi"`** tries direct OVMF DVD install (`q35` + TPM when `vtpm = true`). On Fedora **QEMU 10** this often fails with **BdsDxe: failed to start … DVD … Time out** — use the default SeaBIOS install path instead.

Prerequisites: **mtools**, **xorriso**, **edk2-ovmf**, **swtpm** (`dnf install mtools xorriso edk2-ovmf swtpm`).

### SeaBIOS / CDBOOT instead of OVMF

If the console shows the **SeaBIOS** banner or **CDBOOT: Couldn't find BOOTMGR**, the VM is not running UEFI firmware (or you booted the ISO's **legacy** El Torito entry).

1. On the host: `virsh dumpxml win-uefi-install-2022 | grep -E 'pflash|firmware'` — you want `firmware="efi"` and `type='pflash'`. If missing, install `edk2-ovmf`, destroy the domain, and rebuild.
2. Build log must include `Using OVMF: CODE=...OVMF_CODE_4M.qcow2` (not 2M `OVMF_CODE.fd` alone on q35).
3. In OVMF, pick **UEFI: … DVD**, not a plain legacy DVD entry.

### BdsDxe: No bootable option or device was found

OVMF is running but cannot start the Windows DVD UEFI boot image (common on **Fedora QEMU 10** with Microsoft UDF ISOs: `failed to start … DVD … Time out`).

**Fix (default):** use SeaBIOS for install and convert during provision:

```hcl
install_firmware = "seabios"   # default in variables.pkr.hcl
efi_boot         = true
```

Rebuild with `make clean && make build-2022`. Install runs under SeaBIOS; Packer runs `mbr2gpt` then boots with OVMF.

If you set `install_firmware = "uefi"`, also check: unmodified Microsoft ISO (no `windows-uefi-install.iso`), pick **UEFI: … DVD** in OVMF, and `boot_order=1` on the Windows CD.

### "The selected disk is of the GPT partition style"

That message means **Windows Setup is running in legacy BIOS mode** while the answer file (or disk) uses **GPT**, which is correct for UEFI. The install autounattend already defines a UEFI/GPT layout (EFI system partition + MSR + Windows).

1. Confirm the VM uses **OVMF/UEFI** (build log: `OVMF vars:` and `GPT layout:`).
2. In the **OVMF boot menu**, pick the entry named like **UEFI: … DVD/CD** or **Windows … (UEFI)**, not a plain **DVD Drive** / legacy option.
3. Run `make clean` and rebuild so the install qcow2 is recreated (`qemu-img create`, not a leftover MBR disk from an old SeaBIOS attempt).
4. Do not use `efi_boot = false` / `autounattend-bios.xml.tpl` for OpenShift images.

If you see the opposite text — **MBR partition table … only be installed on GPT disks** — the VM is UEFI but the target disk is still MBR; wipe the install qcow2 and rebuild with the current `autounattend.xml.tpl`.
3. Runs Packer **provision-only** with `efi_boot=true` (VirtIO, sysprep, same scripts as the SeaBIOS path).

Manual single-version install only:

```bash
make stage-virtio
VERSION=2025 ./scripts/build-uefi-virt-install.sh
make build-provision-only VERSION=2025 BASE_IMAGE=output/.packer-2025/packer-win2025-standard-install.qcow2
```

## SeaBIOS build (`efi_boot = false`, dev only)

```bash
# build.pkrvars.hcl: efi_boot = false
make clean
make build
```

Use only to validate autounattend on hosts where Packer cannot boot the ISO under OVMF. **Do not** deploy those qcow2 files to UEFI OpenShift VMs.

## If you must use Packer with UEFI

Setting `efi_boot = true` in `build.pkrvars.hcl` selects `http/autounattend.xml.tpl` (GPT). On QEMU 10 you may still see **No bootable device** or OVMF PXE. There is no reliable fix inside Packer alone today; use the virt-install script or a libvirt-based pipeline instead.

**Note:** Listing `ovmf_code_path` / `ovmf_vars_path` in a var file is fine, but `packer/build.pkr.hcl` only passes them to QEMU when `efi_boot = true`. Previously they were always passed, which forced UEFI and broke SeaBIOS booting of the Windows ISO.
