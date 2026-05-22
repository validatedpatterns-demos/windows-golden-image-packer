# Publishing the golden image to Quay

Optional step after a successful Packer build: package the qcow2 as a **KubeVirt container disk** OCI image and push to Quay (or any registry that uses the same layout).

## Prerequisites

- `podman` or `docker`
- Registry credentials: `podman login quay.io` (or your registry host)
- A completed golden image, e.g. `output/windows-server-2022-standard.qcow2` or `packer/output/windows-server-2022-standard.qcow2` (depends on `output_directory` in `build.pkrvars.hcl`)

## Configure repositories

```bash
cp example.quay.env quay.env
# Edit quay.env — set QUAY_IMAGE_2022 / QUAY_IMAGE_2025 (and optionally QUAY_IMAGE_REFS)
```

Example:

```bash
QUAY_IMAGE_2022=quay.io/myorg/windows-server-2022-standard:golden
QUAY_IMAGE_2025=quay.io/myorg/windows-server-2025-standard:golden
```

Push the same disk to several tags/repos:

```bash
QUAY_IMAGE_REFS="quay.io/myorg/windows-2022:golden quay.io/myorg/windows-2022:release"
```

## Push after build

```bash
make build
make push-quay
```

Or build and push in one step:

```bash
PUSH_QUAY=1 make build
```

Push a specific qcow2 and override refs on the command line:

```bash
./scripts/push-qcow2-to-quay.sh output/windows-server-2022-standard.qcow2 \
  quay.io/myorg/windows-2022:golden
```

## Image layout

The script builds a `scratch` image with the qcow2 at `/disk/disk.qcow2` (ownership `107:107` for qemu), which is the usual **container disk** layout for OpenShift Virtualization / KubeVirt.

## Using the image in a cluster

Reference the registry image on a `VirtualMachine` (container disk) or import via CDI from registry, per your cluster documentation. Example (adjust API version and namespace):

```yaml
spec:
  template:
    spec:
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/myorg/windows-server-2022-standard:golden
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
```

For DataVolume-based import from qcow2 on disk instead of registry, see [openshift-virtualization.md](openshift-virtualization.md).

## Troubleshooting

- **Not logged in**: run `podman login quay.io` (or the host from your image ref).
- **No image ref**: set `QUAY_IMAGE_2022` / `QUAY_IMAGE_2025` in `quay.env` or pass refs as script arguments.
- **Large push**: the full qcow2 is in one layer; upload time depends on disk size and network.
