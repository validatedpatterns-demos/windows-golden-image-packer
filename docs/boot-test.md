# Boot-testing golden images

Boot tests validate that a built **qcow2** starts under libvirt with **VirtIO** disk and network — similar to a typical OpenShift Virtualization VM — without modifying the golden file you upload or publish.

Golden images are **sysprepped** (`/generalize /oobe /mode:vm`). The first start after capture (including boot-test) runs **OOBE** using `C:\Windows\Panther\unattend.xml` from `http/sysprep-oobe.xml.tpl` (**oobeSystem** only — not the file passed to `sysprep.exe`). First boot runs **disk extension** (`extend-system-partition.ps1`) when the virtual disk is larger than the golden image, then OOBE. First boot can take **10–20+ minutes**; do not power off during OOBE.

If you see **"The computer restarted unexpectedly"**, rebuild after fixing the sysprep answer files; clicking OK in a loop will not recover the VM.

If you see **language to install** during **virt-install**, ensure `mtools` is installed and the log shows `Unattend floppy:`. Run `VERSION=2022 bash scripts/render-autounattend.sh | xmllint --noout -`. If you see **BdsDxe: No bootable option**, delete any `output/.packer-*/windows-uefi-install.iso` (repacked ISO breaks UEFI) and rebuild with the unchanged Microsoft ISO.

If you still see the **language / region** OOBE screen on **first boot of the golden qcow2** (after sysprep):

1. Run **`make clean && make build-…`** (boot-test alone does not change the qcow2).
2. Confirm Packer log shows **`configure-oobe-locale.ps1 complete`** and **`Published OOBE unattend`**. After `make build`, promote runs **`inspect-golden-unattend.sh`** — the build fails if Panther still has the install `autounattend.xml`.
3. Inspect the built image: `./scripts/inspect-golden-unattend.sh output/windows-server-2022-standard.qcow2`
4. Render answer files on the host: `VERSION=2022 bash scripts/render-sysprep-unattend.sh`
5. Extract logs from the golden qcow2 on the host (needs `libguestfs-tools`):

   ```bash
   ./scripts/extract-golden-logs.sh output/windows-server-2022-standard.qcow2
   less golden-logs/configure-oobe-locale.log
   less golden-logs/panther-unattend.xml
   ```

   Inside the VM during build the log is also at `C:\Windows\Panther\configure-oobe-locale.log` (survives disk shrink). After first boot OOBE, check `C:\Windows\Panther\setuperr.log` and `setupact.log` (Shift+F10 → `notepad C:\Windows\Panther\setuperr.log`).

`configure-oobe-locale.ps1` installs the **en-US** language pack from `WINDOWS_ISO_PATH` (your install ISO) when possible.

### Failed to boot (OVMF / VM stops)

| Symptom | What to try |
|--------|-------------|
| OVMF **no bootable device** | `BOOT_TEST_DISK_BUS=sata` (default for UEFI). Do not use `virtio` unless you know OVMF boots virtio-blk on your host. |
| VM stops during first boot | Sysprep OOBE can reboot; use `BOOT_TEST_WAIT=300 BOOT_TEST_GUEST_WAIT=900`. |
| **winload.efi** / blue screen after locale changes | Rebuild with current split sysprep answer files. Run `make clean && make build-…`. |
| SeaBIOS image in UEFI VM | Rebuild with `efi_boot=true` or `BOOT_TEST_FIRMWARE=bios`. |

## How it works

1. **`qemu-img create -b`** builds a copy-on-write overlay on top of the golden qcow2 under `~/VirtualMachines/boot-test.*` by default (overlays can be large — not `/tmp`). All writes go to the overlay; the backing image stays read-only.
2. **`virt-install --import`** starts a transient libvirt domain (`boot-test-windows-server-…`) with:
   - `bus=virtio` root disk
   - `model=virtio` NIC on the `default` network
   - **UEFI** (`machine q35`, explicit OVMF loader) when `efi_boot = true` (default)
   - **TPM 2.0** (`swtpm`, `tpm-crb`) when `vtpm = true` (default with UEFI). Set `BOOT_TEST_TPM=0` to skip.
   - Root disk **`bus=sata`** by default for UEFI (same as install; OVMF reads the ESP). Use `--disk-bus scsi` to test virtio-scsi (OpenShift runtime bus)
3. The test checks that the VM **stays running**, optionally that the **QEMU guest agent** reports an IPv4 address, and that the **golden file size/mtime** did not change.
4. The domain and overlay are removed on exit (unless you keep them for debugging).

Requires **KVM**, **libvirt** (`qemu:///system`), **`swtpm`** (for default TPM), the **`default`** network (`virsh net-list --all`), and the **`acl`** package when overlays live under your home directory (the script grants the libvirt **qemu** user traverse/read ACLs on the overlay and golden backing file).

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

**virt-viewer** opens automatically when the VM starts (`BOOT_TEST_SHOW_CONSOLE=1`, default). To suppress it:

```bash
BOOT_TEST_SHOW_CONSOLE=0 make boot-test-2025
# or
make boot-test-2025 -- --no-console
```

## Options and environment

Pass flags through `boot-test-golden.sh` to `boot-test-image.sh`:

| Flag / variable | Default | Meaning |
|-----------------|---------|---------|
| `BOOT_TEST_FIRMWARE` / `--firmware` | matches `efi_boot` in `build.pkrvars.hcl` (`uefi` by default) | Must match how the qcow2 was installed (`uefi` for OpenShift images) |
| `BOOT_TEST_DISK_BUS` / `--disk-bus` | `sata` for UEFI | Matches install bus. Use `scsi` to test OpenShift virtio-scsi |
| `BOOT_TEST_WAIT` / `--wait` | `120` | Seconds the VM must stay up before guest checks |
| `BOOT_TEST_GUEST_WAIT` / `--guest-wait` | `600` | Max seconds to wait for guest-agent IP |
| `BOOT_TEST_CHECK_GUEST` | `1` | Set `0` or `--no-guest-check` to only verify the VM process stays running |
| `BOOT_TEST_GRAPHICS` / `--graphics` | `vnc` | `none` for headless automation |
| `BOOT_TEST_SHOW_CONSOLE` / `--no-console` | `1` | Launch **virt-viewer** when the VM is running |
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
