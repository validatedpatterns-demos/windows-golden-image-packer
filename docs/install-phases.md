# Install phases (IDE setup, then VirtIO)

Windows Setup in WinPE often fails when the target disk is **VirtIO** or **VirtIO-SCSI** and drivers are not loaded yet (`DiskConfiguration` / `ImageInstall` errors). This project splits work into two logical phases.

## Default: one `make build` (one VM — not two Packer runs at once)

Windows Setup itself runs several **unattend passes** in order (`windowsPE` → `specialize` → `oobeSystem`). That is normal and is still a single install. Packer **phase 2** (WinRM provisioners) only starts after those passes finish and the VM reboots.

| Step | What happens |
|------|----------------|
| **Setup (unattend)** | SeaBIOS (`pc`), **IDE** disk, **e1000** NIC. Floppy has `autounattend.xml` + `enable-winrm.cmd`. Installs Windows and enables WinRM in the **specialize** pass. |
| **Packer provisioners** | WinRM: VirtIO drivers, QEMU guest agent, OpenSSH, password/keys, **sysprep**. |

Defaults in `packer/variables.pkr.hcl`:

```hcl
install_disk_interface = "ide"
install_net_device     = "e1000"
```

The finished **qcow2** can boot on OpenShift with **`disk.bus: virtio`** after phase 2 registers **viostor/vioscsi** as boot-start drivers (and the VM firmware matches the image — UEFI for production; see [docs/openshift-boot-troubleshooting.md](docs/openshift-boot-troubleshooting.md)).

## Optional: two Packer runs

Use this if install succeeds but provisioning fails (or you want to retry phase 2 without reinstalling Windows).

**Recovery after a long failed build:** see **[recover-build.md](recover-build.md)** (`make recover-provision`).

**Important:** use `-only` so only one build runs, but still pass the directory `.` so variables and locals load:

```bash
cd packer
packer build -force -var-file=../build.pkrvars.hcl -only=windows-golden-image.qemu.windows .
```

Do **not** use `packer build build.pkr.hcl` (single file — variables missing) or bare `packer build .` (every build — two VMs).

### Pass 1 – install only

```bash
make clean
make stage-virtio
make build-install
```

Output: `output/windows-server-<version>-<edition>-install.qcow2`

### Pass 2 – provision + sysprep

```bash
make build-provision-only VERSION=2022 \
  BASE_IMAGE=output/.packer-2022/packer-win2022-standard-install.qcow2
```

Output: `output/windows-server-<version>-<edition>.qcow2`

If provision failed mid-way (especially after `mbr2gpt`), use `make recover-provision` instead — see [recover-build.md](recover-build.md).

## Advanced: VirtIO disk during Setup

Only if you accept WinPE driver complexity:

```hcl
install_disk_interface = "virtio-scsi"  # or "virtio"
install_net_device     = "virtio-net"
```

The autounattend answer file will include VirtIO driver paths on the PROVISION CD again.
