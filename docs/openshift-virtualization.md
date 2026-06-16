# Using the golden image in OpenShift Virtualization

The build produces a **sysprepped** **qcow2** image with VirtIO disk/network drivers for **OpenShift `disk.bus: virtio`** (virtio-blk / **viostor**). **vioscsi** is also boot-bound for clusters that use **`disk.bus: scsi`**.

**Firmware:** Default **`efi_boot = true`** builds **UEFI + GPT** images ([uefi-install.md](uefi-install.md)). OpenShift `VirtualMachine` specs must use **UEFI** firmware (`firmware.bootloader.efi`), not SeaBIOS. Boot-testing with `make boot-test` uses UEFI when `efi_boot` is true. SeaBIOS-only disks (`efi_boot = false`) will not boot in a UEFI VM.

**TPM:** Default **`vtpm = true`** (with UEFI) exposes an emulated **TPM 2.0** during build and boot-test (`swtpm` on the host). On OpenShift Virtualization, add a **vTPM** to the VM. For production (BitLocker, persistent secrets), set **`persistent: true`** and configure **`vmStateStorageClass`** on the HyperConverged CR; see [OKD vTPM](https://docs.okd.io/latest/virt/managing_vms/virt-using-vtpm-devices.html).

**VM fails to boot with VirtIO disk?** See [openshift-boot-troubleshooting.md](openshift-boot-troubleshooting.md) (VirtIO boot drivers, UEFI vs BIOS, SATA workaround).

## Disk and DataVolume size

The qcow2 **virtual size** is set at build time by `disk_size` in `build.pkrvars.hcl` (default **40G**). CDI and `virtctl image-upload` require the target PVC/DataVolume to be **at least** that large.

| Build setting | DataVolume / upload (minimum) |
|---------------|-------------------------------|
| `disk_size = "40G"` | `storage: 40Gi`, `--size=40Gi` |
| `disk_size = "60G"` | `storage: 60Gi`, `--size=60Gi` |

Autounattend creates a small System Reserved partition and **extends** the Windows volume to fill the build-time virtual disk. Lower `disk_size` and **rebuild** to reduce the import minimum. Shrinking an existing image in place is not supported by this repo.

### Larger disks on OpenShift (PVC &gt; golden image)

You can import a **40G** golden image into a **larger** PVC (for example `storage: 100Gi`). On **first deploy boot** (sysprep OOBE), `extend-system-partition.ps1` runs from `sysprep-oobe.xml` and extends **C:** into any unallocated space.

Requirements:

1. DataVolume/PVC `storage` **≥** image virtual size (40Gi for the default build).
2. Storage class allows the PVC size you request (`allowVolumeExpansion: true` if you resize later).
3. After a **live PVC resize**, reboot the VM or rescan storage; run `extend-system-partition.ps1` again if C: did not grow (not automated on resize today).

Logs: `C:\ProgramData\GoldenImage\extend-system-partition.log` after first boot.

If you need the guest virtual disk to match build size exactly at import (no extension step), set `disk_size` to your target PVC size before `make build`.

### Exact DataVolume size after build

The **virtual size** in the qcow2 is the hard minimum for CDI and `virtctl image-upload`. It matches `disk_size` from the build (unless the image was resized manually). The **file size on disk** is separate and is what shrink/optimize reduces.

```bash
make image-size
# or
qemu-img info output/windows-server-2022-standard.qcow2
./scripts/qcow2-size-report.sh --json output/windows-server-2022-standard.qcow2
```

Use the reported `DataVolume minimum` (e.g. `40Gi`) for `spec.pvc.resources.requests.storage` and `virtctl image-upload --size=`. You may request a **larger** PVC; first deploy boot extends C: automatically.

Host-side re-encoding without rebuilding:

```bash
make optimize-image
```

Build runs optimization automatically after rename unless `IMAGE_OPTIMIZE=0`.

## Import qcow2

Upload the image to a PVC or use CDI to clone from HTTP/registry, for example:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: windows-server-2022-standard
  namespace: my-namespace
spec:
  source:
    upload: {}
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 40Gi
```

Use `virtctl image-upload` or your cluster's documented import path to load `windows-server-2022-standard.qcow2`.

`virtctl` streams from `--image-path`; it does not offer a separate staging directory. Keep the qcow2 on a filesystem with enough free space (for example `./output/` in this repo), not under `/tmp`:

```bash
virtctl image-upload dv windows-server-2025-standard \
  --size=40Gi \
  --image-path=/home/you/gitwork/windows-golden-image-packer/output/windows-server-2025-standard.qcow2
```

To publish the same disk to **Quay** as a container image (optional), see [quay-publish.md](quay-publish.md).

## VirtualMachine hints

- **Firmware**: UEFI (use the virt-install UEFI base disk, or confirm your Packer-built image boots with UEFI in a test VM)
- **TPM**: vTPM device (recommended; matches golden-image build defaults)
- **Disk bus**: **VirtIO** (`bus: virtio`) — matches default build and `make boot-test`. **`bus: scsi`** also works when **vioscsi** is boot-start (installed by default).
- **Network**: masquerade/bridge with **VirtIO** model
- **QEMU guest agent**: enabled on the VM spec so node operations work
- **First boot**: sysprep OOBE runs once (locale, product key re-apply when configured, disk extend, Administrator password from `http/sysprep-oobe.xml.tpl`); the VM should reach **Administrator sign-in** without a product-key prompt when `product_key_*` is set in `build.pkrvars.hcl`.

```yaml
spec:
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
              model: virtio
          tpm:
            persistent: true
        features:
          acpi: {}
          smm:
            enabled: true
        firmware:
          bootloader:
            efi:
              secureBoot: false
      volumes:
        - name: rootdisk
          dataVolume:
            name: windows-server-2022-standard
```

## SSH access

- User: `Administrator`
- Password: value from `admin_password` at build time (change after import in production)
- Keys: any keys passed via `ssh_public_keys` / `ssh_public_keys_file` at build time are in `administrators_authorized_keys`

For per-VM keys at runtime, use a post-deploy mechanism (Ansible, custom script, or guest agent tooling) in addition to the baked-in keys.

## Windows Server 2025

Build with `windows_version = "2025"` and use a licensed Windows Server 2025 ISO. Image index names in the ISO must match `Windows Server 2025 SERVERSTANDARD` (verify with `oscdimg` / DISM on the ISO if your SKU string differs).
