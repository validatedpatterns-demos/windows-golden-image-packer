# Tekton-aligned golden image build

Two-phase pipeline modeled on [KubeVirt `windows-efi-installer`](https://github.com/kubevirt/kubevirt-tekton-tasks/tree/main/release/pipelines/windows-efi-installer). Windows is installed, provisioned, and sysprepped on **virtio-blk + UEFI** — the same shape as OpenShift `disk.bus: virtio`.

## Phases

| Phase | Tool | Firmware / disk | Output |
|-------|------|-----------------|--------|
| 1 | `virt-install` | OVMF + virtio-blk root | `output/.packer-*/packer-win*-install.qcow2` |
| 2 | Packer `windows-golden-provision` | OVMF + virtio-blk | `output/windows-server-*-standard.qcow2` |

## Phase 1 layout (virt-install)

Microsoft eval ISOs ship a **prompt** UEFI bootloader; OVMF on Fedora/QEMU 10 often ends at **No bootable option or device was found** without the Tekton **noprompt** swap. Phase 1 runs `scripts/modify-windows-iso-for-uefi.sh` (cached as `output/.packer-*/windows-uefi-install.iso`) before virt-install.

| Device | Bus | Content |
|--------|-----|---------|
| Root disk | virtio | Empty qcow2 |
| CD 1 | SATA | Windows ISO (`boot_order=2`), noprompt EFI + autounattend in boot.wim |
| Root disk | virtio | `boot_order=1` (empty first boot; Windows Boot Manager after copy) |
| CD 2 | SATA | PROVISION ISO (autounattend + WinRM + `post-install.ps1`) |
| CD 3 | SATA | VIRTIO-WIN ISO (WinPE drivers + `virtio-win-gt-x64.msi`) |

WinPE loads **viostor** from the virtio CD (`DriverPaths` in `autounattend.xml.tpl`). During **specialize**, `post-install.ps1` installs **virtio-win-gt-x64.msi** and **qemu-ga-x86_64.msi**, then enables WinRM.

## Phase 2 (Packer)

Single pass on the install disk: verify UEFI/VirtIO, guest agent, SSH, shrink, sysprep, inspect gates.

No `mbr2gpt`, no SeaBIOS prep pass, no IDE→virtio BCD bridge.

## Defaults (`build.pkrvars.hcl`)

```hcl
efi_boot               = true
install_firmware       = "uefi"
install_disk_interface = "virtio"
install_net_device     = "e1000"
```

## Build

```bash
make stage-virtio   # includes virtio-win-gt-x64.msi
# Requires: p7zip, genisoimage (modify-windows-iso-for-uefi.sh), xmllint (validate-unattend)
make validate       # CI runs the same checks (libxml2-utils on Ubuntu)
make build BUILD_VERSIONS=2022
./scripts/inspect-golden-qcow2.sh output/windows-server-2022-standard.qcow2
./scripts/inspect-golden-unattend.sh output/windows-server-2022-standard.qcow2
make boot-test-2022
```

## Product keys and OOBE

- Install / specialize: `product_key_2022` or `product_key_2025` in `build.pkrvars.hcl` → `sysprep-generalize.xml.tpl` (specialize pass).
- First deploy boot: `sysprep-oobe.xml.tpl` sets `SetupDisplayedProductKey=1` and runs `slmgr.vbs /ipk` (generalize clears licensing state).
- Host validation: `make validate-unattend`, `./scripts/inspect-golden-unattend.sh`.

## Retry provision only

```bash
make build-provision-only VERSION=2022 \
  BASE_IMAGE=output/.packer-2022/packer-win2022-standard-install.qcow2
```

## Removed from critical path

- `windows-golden-provision-mbr` (SeaBIOS + mbr2gpt)
- `windows-golden-provision-gpt-sysprep` (split sysprep)
- `08-convert-mbr-to-uefi.ps1` during main build
- `01-install-virtio-drivers.ps1` phantom-device path (MSI at install)
- `stage-provision-prep-disk.sh` checkpoint between MBR and sysprep

Legacy scripts remain in `scripts/` for reference until a follow-up cleanup PR.
