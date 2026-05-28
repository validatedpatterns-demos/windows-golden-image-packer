# OpenShift Virtualization: Windows golden image boot issues

## Symptoms

- VM with `disk.bus: virtio` does not boot (blank screen, automatic repair loop, or **INACCESSIBLE_BOOT_DEVICE** / stop `0x7B`)
- Same image may boot on the Packer build host (IDE disk) but not in OpenShift Container Native Virtualization (CNV)

Disk shrinking and qcow2 optimization do **not** change the guest boot path; they only affect file size on disk.

## "No bootable device" (OVMF / UEFI)

On most **Fedora/libvirt OVMF** builds, firmware **does not boot virtio-blk** (`disk.bus: virtio`). You get **no bootable device** even with a healthy image.

| Mistake | Result |
|---------|--------|
| SeaBIOS (MBR) image in a **UEFI** VM | OVMF: no bootable device |
| **`bus: virtio`** (virtio-blk) under OVMF | OVMF never sees a bootable ESP |
| UEFI image tested with **`BOOT_TEST_DISK_BUS=virtio`** | Same as above — use **`scsi`** |

**Current `efi_boot = true` builds**:

1. Install Windows on **SATA** (virt-install + WinPE).
2. Provision on **SATA**, install **vioscsi/viostor** boot-start drivers, run **`07-repair-uefi-boot.ps1`**.
3. Boot-test and OpenShift use **`disk.bus: scsi`** (virtio-scsi), not virtio-blk.

Inspect an image:

```bash
./scripts/inspect-golden-qcow2.sh output/windows-server-2025-standard.qcow2
make boot-test-2025   # uses UEFI + scsi by default
```

**Rebuild** after changing this; old qcow2 files will not self-heal.

## Two common causes

### 1. VirtIO storage not loaded at boot (most common with `bus: virtio`)

The default build installs Windows on an **IDE** disk, then installs VirtIO drivers in WinRM. OpenShift VMs typically use a **VirtIO block** disk (`bus: virtio`), which needs the **viostor** driver (and **vioscsi** if you use SCSI) registered as **boot-start** before sysprep.

**Fixed in current builds** by:

- `specialize` unattend (`specialize-virtio-drivers.xml.tpl`) staging drivers from the PROVISION CD
- `01-install-virtio-drivers.ps1` copying `viostor.sys` / `vioscsi.sys` into `System32\drivers` and creating **boot-start** `Services` keys (required because the build VM has no VirtIO disk, so `pnputil` alone does not register those services)

**Rebuild** after pulling these changes: `make clean && make build`.

### 2. Firmware mismatch (SeaBIOS image vs UEFI VM)

The default Packer build uses **SeaBIOS** + **MBR** (`efi_boot = false`). Many CNV `VirtualMachine` examples use **UEFI**:

```yaml
firmware:
  bootloader:
    efi:
      secureBoot: false
```

A BIOS-installed Windows image often **will not boot** under UEFI even with correct VirtIO drivers.

**Options:**

| Approach | When to use |
|----------|-------------|
| **UEFI golden image** | Production on CNV — run [uefi-install.md](uefi-install.md) (`scripts/build-uefi-virt-install.sh`) or install with UEFI when Packer supports it on your QEMU version |
| **BIOS VM firmware** (interim) | Test or short-term use of an existing SeaBIOS-built qcow2 |

Example VM fragment for a **SeaBIOS-built** image (check your cluster’s KubeVirt API version):

```yaml
spec:
  template:
    spec:
      domain:
        firmware:
          bootloader:
            bios: {}
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: scsi
```

Prefer **UEFI install** for new images rather than running production Windows VMs with BIOS firmware.

## Workarounds for an **existing** image (no rebuild yet)

### A. Boot with SATA instead of VirtIO

Windows has inbox drivers for SATA/AHCI. This confirms the OS partition is fine and isolates VirtIO driver issues:

```yaml
devices:
  disks:
    - name: rootdisk
      disk:
        bus: sata
```

Performance is lower than VirtIO; use only for recovery or migration.

### B. Recover VirtIO drivers in WinRE

1. Stop the VM.
2. Attach the cluster **virtio-win** container disk (CNV: *Mount Windows drivers disk* on the VM).
3. Boot Windows install/recovery ISO (or the VM OS if it reaches WinRE).
4. Command prompt — load storage driver (adjust drive letter and OS folder):

   ```cmd
   drvload E:\viostor\2k22\amd64\viostor.inf
   ```

5. Reboot and set `bus: virtio` again.

See Red Hat / vendor recovery guides for attaching the virtio container disk on CNV.

## Recommended production VM settings

After a **rebuild** with current provisioners (or a **UEFI** base disk):

```yaml
spec:
  template:
    spec:
      domain:
        firmware:
          bootloader:
            efi:
              secureBoot: false
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: scsi
          interfaces:
            - name: default
              masquerade: {}
              model: virtio
        features:
          acpi: {}
          smm:
            enabled: true
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            claimName: windows-server-2022-standard
```

Enable the **QEMU guest agent** on the VM spec if your platform documents it (drivers are installed by `02-install-qemu-guest-agent.ps1`).

## Verify drivers inside a running test VM

On a VM that boots (e.g. with `bus: sata`):

```powershell
Get-Service viostor, vioscsi -ErrorAction SilentlyContinue
Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\viostor -Name Start
Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi -Name Start
```

`Start` should be **0** (boot) for both storage drivers before switching the disk to VirtIO in the VM spec.

## Related docs

- [openshift-virtualization.md](openshift-virtualization.md) — import and DataVolume sizing
- [install-phases.md](install-phases.md) — IDE install + VirtIO provisioners
- [uefi-install.md](uefi-install.md) — UEFI base disk for CNV
