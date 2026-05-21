# UEFI installs (OpenShift Virtualization)

Packer's QEMU builder on **Fedora with QEMU 10** attaches install media with legacy `-drive media=cdrom`. OVMF often will not boot the Microsoft ISO's **hidden EFI** El Torito image, and may try the empty VirtIO disk or the small **PROVISION** CD first, then fall back to PXE (`Boot002` / `Boot0003` errors).

The default Packer build therefore uses **SeaBIOS** (`efi_boot = false`) so setup boots from the **legacy** catalog on the Windows DVD. That completes unattended install and provisioning reliably on the build host.

**OpenShift Virtualization** and KubeVirt typically run guests with **UEFI**. A disk installed under SeaBIOS (MBR, BIOS bootloader) may not start in a UEFI VM without conversion. For production golden images, install under UEFI with **libvirt** (SATA CD-ROM, same as `virt-install`).

## Recommended: virt-install UEFI build

Prerequisites: `virt-install`, `xorriso`, staged VirtIO drivers (`make stage-virtio`), and `build.pkrvars.hcl` paths.

```bash
# From repo root
make stage-virtio
./scripts/build-uefi-virt-install.sh
```

The script:

1. Renders `http/autounattend.xml.tpl` (GPT + EFI system partition) via Packer console.
2. Builds a **PROVISION** ISO with VirtIO WinPE drivers.
3. Starts a transient VM: **UEFI**, **q35**, **SATA** disk + two **SATA** CD-ROMs (Windows ISO + PROVISION), matching what libvirt generates for Windows.

After Windows setup finishes and the VM shuts down, run the same PowerShell provisioners manually or import the disk and complete tooling in a follow-up step (this script focuses on **getting a UEFI-installed base disk**).

## Packer build (SeaBIOS, fast iteration)

```bash
make clean
# efi_boot defaults to false; do not set efi_boot = true on QEMU 10 unless you accept boot failures
make build
```

Use this path to validate autounattend, WinRM scripts, and sysprep. Migrate to the virt-install UEFI disk for OpenShift if the BIOS-installed qcow2 does not boot in your cluster.

## If you must use Packer with UEFI

Setting `efi_boot = true` in `build.pkrvars.hcl` selects `http/autounattend.xml.tpl` (GPT). On QEMU 10 you may still see **No bootable device** or OVMF PXE. There is no reliable fix inside Packer alone today; use the virt-install script or a libvirt-based pipeline instead.

**Note:** Listing `ovmf_code_path` / `ovmf_vars_path` in a var file is fine, but `packer/build.pkr.hcl` only passes them to QEMU when `efi_boot = true`. Previously they were always passed, which forced UEFI and broke SeaBIOS booting of the Windows ISO.
