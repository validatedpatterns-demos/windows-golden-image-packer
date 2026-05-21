# Using the golden image in OpenShift Virtualization

The build produces a **sysprepped**, **UEFI (OVMF)** **qcow2** image with VirtIO disk/network and the QEMU guest agent installed. Import it as a DataVolume or containerized disk, then create a `VirtualMachine` that uses UEFI and VirtIO.

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
        storage: 80Gi
```

Use `virtctl image-upload` or your cluster's documented import path to load `windows-server-2022-standard.qcow2`.

## VirtualMachine hints

- **Firmware**: UEFI (matches OVMF build)
- **Disk bus**: VirtIO
- **Network**: masquerade/bridge with **VirtIO** model
- **QEMU guest agent**: enabled on the VM spec so node operations work
- **First boot**: sysprep OOBE runs once; set hostname and license per your process

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
