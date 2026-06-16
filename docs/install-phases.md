# Install phases

Windows Setup runs several **unattend passes** in order (`windowsPE` → `specialize` → `oobeSystem`) during install. That is normal and is still a single install VM. Packer **phase 2** (WinRM provisioners) only starts after virt-install completes and the install disk is handed to Packer.

## Default: `make build` (virt-install + provision)

Production OpenShift images use **UEFI + virtio-blk** end to end ([tekton-aligned-build.md](tekton-aligned-build.md)).

| Step | What happens |
|------|----------------|
| **Phase 1 (virt-install)** | OVMF + **virtio-blk** root disk, **e1000** NIC. Windows ISO uses noprompt EFI bootloaders; autounattend is embedded in `boot.wim`. WinPE loads **viostor** from the virtio-win ISO; **post-install.ps1** installs **virtio-win-gt-x64.msi** and enables WinRM during **specialize**. |
| **Phase 2 (Packer)** | WinRM on the install disk (OVMF + virtio-blk): verify VirtIO boot drivers, QEMU guest agent, OpenSSH, locale/OOBE prep, disk shrink, **sysprep**, offline inspect gates, optimize. |

Defaults in `packer/variables.pkr.hcl` and `example.pkrvars.hcl`:

```hcl
efi_boot               = true
install_firmware       = "uefi"
install_disk_interface = "virtio"
install_net_device     = "e1000"
```

The finished **qcow2** boots on OpenShift with **`disk.bus: virtio`** after sysprep restores **viostor** boot-start keys. Boot-test enforces the same layout (`make boot-test`).

## Optional: two explicit Packer runs

Use this if install succeeds but provisioning fails (or you want to retry phase 2 without reinstalling Windows).

**Recovery after a long failed build:** see **[recover-build.md](recover-build.md)** (`make recover-provision`).

**Important:** use `-only` so only one build runs, but still pass the directory `.` so variables and locals load:

```bash
cd packer
packer build -force -var-file=../build.pkrvars.hcl -only=windows-golden-provision.qemu.from_install_gpt .
```

Do **not** use `packer build build.pkr.hcl` (single file — variables missing) or bare `packer build .` (every build — multiple VMs).

### Pass 1 – install only

```bash
make clean
make stage-virtio
make build-install
```

Output: `output/.packer-<version>/packer-win<version>-<edition>-install.qcow2`

### Pass 2 – provision + sysprep

```bash
make build-provision-only VERSION=2022 \
  BASE_IMAGE=output/.packer-2022/packer-win2022-standard-install.qcow2
```

Output: `output/windows-server-<version>-<edition>.qcow2`

If provision failed mid-way, use `make recover-provision` — see [recover-build.md](recover-build.md).

## Legacy: SeaBIOS / IDE single-pass Packer install

Only for dev hosts where virt-install is unavailable. Set in `build.pkrvars.hcl`:

```hcl
efi_boot               = false
install_disk_interface = "ide"
```

Do **not** deploy those qcow2 files to UEFI OpenShift VMs. See [uefi-install.md](uefi-install.md).

## Advanced: other install disk buses

```hcl
install_disk_interface = "virtio-scsi"  # or "sata", "ide"
install_net_device     = "virtio-net"   # requires WinPE VirtIO net drivers
```

The autounattend answer file must include matching VirtIO driver paths on the PROVISION / virtio-win media.
