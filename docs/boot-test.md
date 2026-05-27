# Boot-testing golden images

Boot tests validate that a built **qcow2** starts under libvirt with **VirtIO** disk and network — similar to a typical OpenShift Virtualization VM — without modifying the golden file you upload or publish.

Golden images are **sysprepped** (`/generalize /oobe`). The first start after capture (including boot-test) runs **OOBE** again using `C:\Windows\Panther\unattend.xml` from `http/sysprep-unattend.xml.tpl` (locale **en-US**, Administrator password, no manual language/password prompts). Rebuild the image after changing that file.

## How it works

1. **`qemu-img create -b`** builds a copy-on-write overlay on top of the golden qcow2 under `~/VirtualMachines/boot-test.*` by default (overlays can be large — not `/tmp`). All writes go to the overlay; the backing image stays read-only.
2. **`virt-install --import`** starts a transient libvirt domain (`boot-test-windows-server-…`) with:
   - `bus=virtio` root disk
   - `model=virtio` NIC on the `default` network
   - **SeaBIOS** (`machine pc`) by default — matches the default Packer build (`efi_boot = false`)
3. The test checks that the VM **stays running**, optionally that the **QEMU guest agent** reports an IPv4 address, and that the **golden file size/mtime** did not change.
4. The domain and overlay are removed on exit (unless you keep them for debugging).

Requires **KVM**, **libvirt** (`qemu:///system`), the **`default`** network (`virsh net-list --all`), and the **`acl`** package when overlays live under your home directory (the script grants the libvirt **qemu** user traverse/read ACLs on the overlay and golden backing file).

If you prefer not to use ACLs, run with `BOOT_TEST_CONNECT=qemu:///session` so the VM runs as your user (session libvirt, not the system hypervisor).

## Quick usage

```bash
# Newest golden image under output/ or packer/output/
make boot-test

# One Windows version
make boot-test-2025

# Every golden qcow2 found
make boot-test-all

# Explicit path
make boot-test-image IMAGE=packer/output/windows-server-2025-standard.qcow2
```

Watch the console during the test (VNC is enabled by default):

```bash
virt-viewer --connect qemu:///system boot-test-windows-server-2025-standard
```

## Options and environment

Pass flags through `boot-test-golden.sh` to `boot-test-image.sh`:

| Flag / variable | Default | Meaning |
|-----------------|---------|---------|
| `BOOT_TEST_FIRMWARE` / `--firmware` | `bios` | Use `uefi` for UEFI-installed disks ([uefi-install.md](uefi-install.md)) |
| `BOOT_TEST_WAIT` / `--wait` | `120` | Seconds the VM must stay up before guest checks |
| `BOOT_TEST_GUEST_WAIT` / `--guest-wait` | `600` | Max seconds to wait for guest-agent IP |
| `BOOT_TEST_CHECK_GUEST` | `1` | Set `0` or `--no-guest-check` to only verify the VM process stays running |
| `BOOT_TEST_GRAPHICS` / `--graphics` | `vnc` | `none` for headless automation |
| `BOOT_TEST_CONNECT` | `qemu:///system` | libvirt URI |
| `BOOT_TEST_KEEP_VM` / `--keep-vm` | `0` | Leave the domain defined after the test |
| `BOOT_TEST_WORK_DIR` | `~/VirtualMachines` | Parent directory for overlay qcow2 (`boot-test.*` subdirs) |
| `BOOT_TEST_KEEP_DISK` / `--keep-disk` | `0` | Keep the overlay under `BOOT_TEST_WORK_DIR/boot-test.*` |
| `BOOT_TEST_DRY_RUN` / `--dry-run` | `0` | Print actions without starting a VM |

Example — faster smoke test (no guest-agent wait):

```bash
BOOT_TEST_CHECK_GUEST=0 BOOT_TEST_WAIT=60 make boot-test-2025
```

Example — UEFI disk from `scripts/build-uefi-virt-install.sh`:

```bash
./scripts/boot-test-image.sh --firmware uefi --image output/uefi-install-base.qcow2
```

## After `make build`

```bash
make build-2025
make boot-test-2025
```

Exit code `0` prints `PASS:`; non-zero indicates boot failure, guest-agent timeout, or accidental modification of the backing qcow2.

## Permission denied (uid 107)

With `qemu:///system`, QEMU runs as the **qemu** user (often uid 107). It must traverse every directory from `/` to the overlay and backing qcow2. `boot-test-image.sh` sets **POSIX ACLs** (`setfacl`) on those paths automatically. If that fails, install `acl` or use session libvirt:

```bash
BOOT_TEST_CONNECT=qemu:///session make boot-test-2025
```
