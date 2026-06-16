# OpenShift Virtualization: Windows golden image boot issues

## Symptoms

- VM with `disk.bus: virtio` does not boot (blank screen, automatic repair loop, or **INACCESSIBLE_BOOT_DEVICE** / stop `0x7B`)
- Same image boots in **`make boot-test`** but fails in OpenShift (firmware, TPM, or PVC sizing)
- OOBE loops or product-key prompts on first deploy boot (unattend issue — see [boot-test.md](boot-test.md))

Disk shrinking and qcow2 optimization do **not** change the guest boot path; they only affect file size on disk.

## Current build (`efi_boot = true`, default)

| Phase | Disk / firmware |
|-------|-----------------|
| virt-install | OVMF + **virtio-blk** root |
| Packer provision + sysprep | OVMF + **virtio-blk** (OpenShift parity) |
| boot-test | Session libvirt, **virtio-blk**, guest-agent channel |

Inspect before upload:

```bash
./scripts/inspect-golden-qcow2.sh output/windows-server-2025-standard.qcow2
./scripts/inspect-golden-unattend.sh output/windows-server-2025-standard.qcow2
make boot-test-2025
```

**Rebuild** after changing virtio/sysprep scripts; old qcow2 files will not self-heal.

## Common causes

### 1. VirtIO storage not boot-start (most common with `bus: virtio`)

OpenShift **`disk.bus: virtio`** needs **viostor** registered as **boot-start** in every control set that sysprep may clone. **vioscsi** is also boot-bound for clusters that use **`disk.bus: scsi`**.

**Current builds** install drivers during Setup (virtio-win MSI + WinPE paths) and re-bind after sysprep in `restore-virtio-boot-after-sysprep.ps1`. Promote runs **`inspect-golden-qcow2.sh`** with **`INSPECT_VIRTIO_STRICT=1`**.

Retry provision without reinstalling Windows:

```bash
make build-provision-only VERSION=2022 \
  BASE_IMAGE=output/.packer-2022/packer-win2022-standard-install.qcow2
```

Or recover from a partial work disk: [recover-build.md](recover-build.md).

### 2. Firmware mismatch (SeaBIOS image vs UEFI VM)

Legacy **`efi_boot = false`** images are **SeaBIOS + MBR**. OpenShift `VirtualMachine` specs must use **UEFI** for production:

```yaml
firmware:
  bootloader:
    efi:
      secureBoot: false
```

A SeaBIOS-built image **will not boot** under OEFI even with correct VirtIO drivers. Rebuild with **`efi_boot = true`** ([uefi-install.md](uefi-install.md)).

### 3. Wrong disk bus in the VM spec

| Golden image | OpenShift `disk.bus` | Driver |
|--------------|----------------------|--------|
| Current default (virt-install + sysprep) | **`virtio`** | **viostor** |
| Same image (alternate) | **`scsi`** | **vioscsi** (also installed) |

Boot-test validates **`virtio`** only. Prefer **`bus: virtio`** to match the build and boot-test gate.

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

After a **rebuild** with current provisioners:

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
                bus: virtio
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

On a VM that boots (e.g. with `bus: sata` temporarily):

```powershell
Get-Service viostor, vioscsi -ErrorAction SilentlyContinue
Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\viostor -Name Start
Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi -Name Start
```

`Start` should be **0** (boot) for the storage driver matching your disk bus before switching to VirtIO in the VM spec.

## Related docs

- [openshift-virtualization.md](openshift-virtualization.md) — import and DataVolume sizing
- [install-phases.md](install-phases.md) — virt-install + provision flow
- [uefi-install.md](uefi-install.md) — UEFI install details
- [boot-test.md](boot-test.md) — pre-upload boot validation
