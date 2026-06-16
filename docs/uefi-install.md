# UEFI installs (OpenShift Virtualization)

With **`efi_boot = true`** (default in `packer/variables.pkr.hcl` and `example.pkrvars.hcl`), `make build` runs a **virt-install UEFI** install on **virtio-blk**, then Packer provision + sysprep — matching OpenShift **`disk.bus: virtio`**.

Set **`efi_boot = false`** only for a legacy **SeaBIOS** single-pass Packer build on dev hosts. Those disks must not be used in UEFI `VirtualMachine` specs.

See also [tekton-aligned-build.md](tekton-aligned-build.md) for the full two-phase layout.

## How `make build` works when `efi_boot = true`

Prerequisites: `virt-install`, `xorriso`, **`edk2-ovmf`** (4M OVMF for q35), **`swtpm`** (default **`vtpm = true`**), staged VirtIO drivers (`make stage-virtio`), **`p7zip`** + **`genisoimage`** (noprompt ISO repack), and `build.pkrvars.hcl` paths.

The install script logs `Using OVMF: CODE=...` — on Fedora this should be **`OVMF_CODE_4M.qcow2`**, not `OVMF_CODE.fd` (2M often fails to boot on `machine q35`).

**Important:** `make clean` and the UEFI install script **undefine** libvirt domains with **`virsh undefine --nvram`** when OVMF NVRAM is present. They do **not** use `virsh undefine --remove-all-storage` (that can delete host ISO paths attached as `--cdrom`).

```bash
make stage-virtio
make build-2025    # or make build for both versions
```

Per version, `make build-version-uefi`:

1. Renders `http/autounattend.xml.tpl` (GPT / UEFI layout when `install_firmware = "uefi"`).
2. Builds a **virtual floppy** and **PROVISION** CD. Repacks a **noprompt** Windows ISO (`windows-uefi-install.iso` in the staging dir) via `scripts/modify-windows-iso-for-uefi.sh`.
3. Runs **virt-install** with **`install_firmware = "uefi"`** (default): OVMF + **virtio-blk** root, Windows DVD `boot_order=2`, empty root disk `boot_order=1`.
4. Runs Packer **`windows-golden-provision`** on the install disk (OVMF + virtio-blk, sysprep, inspect gates).

Optional **`install_firmware = "seabios"`** installs on SeaBIOS then converts via mbr2gpt during provision (legacy path; not used on the default Tekton-aligned build).

Prerequisites package list:

```bash
dnf install mtools xorriso edk2-ovmf swtpm p7zip genisoimage
```

### BdsDxe: No bootable option or device was found

OVMF is running but cannot start the Windows DVD UEFI boot image (common on **Fedora QEMU 10** with unmodified Microsoft UDF ISOs).

**Fix (default):** `install_firmware = "uefi"` runs `scripts/modify-windows-iso-for-uefi.sh`, which swaps `efisys.bin` / `cdboot.efi` for the noprompt variants and repacks a bootable ISO.

If install still fails:

1. Build log should show `UEFI install ISO: .../windows-uefi-install.iso (noprompt EFI bootloaders)`.
2. Confirm OVMF 4M firmware: `Using OVMF: CODE=...OVMF_CODE_4M.qcow2`.
3. In the OVMF boot menu, pick the entry for the **largest** Windows DVD (not PROVISION or VIRTIO-WIN).
4. Run `make clean` and rebuild so stale NVRAM / install qcow2 are removed.

**Install loop (Setup restarts from DVD every reboot):** caused by `boot_order=1` on the Windows ISO. The virtio root disk must be `boot_order=1` and the install DVD `boot_order=2`. Delete cached `windows-uefi-install.iso` after upgrading templates so autounattend is re-embedded in `boot.wim`.

### "The selected disk is of the GPT partition style"

That message means **Windows Setup is running in legacy BIOS mode** while the answer file uses **GPT** (correct for UEFI).

1. Confirm the VM uses **OVMF/UEFI** (build log: `OVMF vars:` and `GPT layout:`).
2. In the **OVMF boot menu**, pick **UEFI: … DVD/CD**, not a plain legacy DVD entry.
3. Run `make clean` and rebuild so the install qcow2 is recreated.
4. Do not use `efi_boot = false` / `autounattend-bios.xml.tpl` for OpenShift images.

If you see **MBR partition table … only be installed on GPT disks** — the VM is UEFI but the target disk is still MBR; wipe the install qcow2 and rebuild.

Manual single-version install only:

```bash
make stage-virtio
VERSION=2025 ./scripts/build-uefi-virt-install.sh
make build-provision-only VERSION=2025 \
  BASE_IMAGE=output/.packer-2025/packer-win2025-standard-install.qcow2
```

If provision fails, see [recover-build.md](recover-build.md).

## SeaBIOS build (`efi_boot = false`, dev only)

```bash
# build.pkrvars.hcl: efi_boot = false
make clean
make build
```

Use only to validate autounattend on hosts where virt-install is unavailable. **Do not** deploy those qcow2 files to UEFI OpenShift VMs.

## If you must use Packer with UEFI for install

Single-pass Packer install with `efi_boot = true` selects `http/autounattend.xml.tpl` (GPT). On QEMU 10 you may still see **No bootable device** or OVMF PXE when Packer attaches the ISO. The supported path is **virt-install** (above), not Packer-only install.

**Note:** Listing `ovmf_code_path` / `ovmf_vars_path` in a var file is fine; Packer passes them to QEMU only when `efi_boot = true`.
