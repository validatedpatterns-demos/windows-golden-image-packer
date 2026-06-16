# Boot-testing golden images

Boot tests validate that a built **qcow2** starts without modifying the golden file you upload or publish.

**Default (UEFI and SeaBIOS):** `boot-test-image.sh` uses **libvirt `qemu:///session`**, **virtio-blk** root disk (`disk.bus: virtio` — same as OpenShift), **virtio** NIC, and a **QEMU guest-agent channel**. Before starting the VM it runs **`inspect-golden-qcow2.sh`** offline; boot-test **fails** if **viostor** is not boot-start in the golden image. There is **no** scsi/sata fallback — a blue screen or boot failure means the golden build is not OpenShift-ready.

**Alternate:** `BOOT_TEST_METHOD=packer` replays the **OVMF sysprep Packer** layout (q35, ide-hd on `ide.0`, e1000 user netdev, WinRM port forward, no guest agent). Use that when debugging Packer sysprep boot loops, not for production virtio validation.

Golden images are **sysprepped** (`/generalize /oobe /mode:vm`). The first start after capture (including boot-test) runs **OOBE** using `C:\unattend.xml` / `Panther\unattend.xml` from `http/sysprep-oobe.xml.tpl` (**oobeSystem** only — not the file passed to `sysprep.exe`). First boot runs **SetupDisplayedProductKey** (skip product-key page), **slmgr /ipk** when a key is configured, **disk extension** (`extend-system-partition.ps1`) when the virtual disk is larger than the golden image, then remaining OOBE. First boot can take **10–20+ minutes**; do not power off during OOBE.

If you see **"The computer restarted unexpectedly"** or **"Sysprep hasn't finished"**, the golden disk was likely captured or boot-tested before sysprep completed and shut down cleanly. Rebuild with current `sysprep.ps1` (no sysprep `/shutdown`; explicit `shutdown /s /t 0 /f` after OOBE unattend restore).

If you see **language to install** during **virt-install**, ensure `mtools` is installed and the log shows `Unattend floppy:`. Run `VERSION=2022 bash scripts/render-autounattend.sh | xmllint --noout -`. If you see **BdsDxe: No bootable option**, delete any `output/.packer-*/windows-uefi-install.iso` (repacked ISO breaks UEFI) and rebuild with the unchanged Microsoft ISO.

If you still see the **language / region** OOBE screen on **first boot of the golden qcow2** (after sysprep):

1. Run **`make clean && make build-…`** (boot-test alone does not change the qcow2).
2. Confirm Packer log shows **`configure-oobe-locale.ps1 complete`** and **`Published OOBE unattend`**. After `make build`, promote runs **`inspect-golden-unattend.sh`** — the build fails if OOBE unattend is wrong.
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

### Blue screen / "Your device ran into a problem and needs to restart"

First boot after sysprep is fragile. Common causes:

| Cause | Fix |
|-------|-----|
| **vTPM added at boot-test** but sysprep ran without TPM | Default is now **`BOOT_TEST_TPM=0`** (matches `provision_sysprep_vtpm=false`). Do not set `BOOT_TEST_TPM=1` until after OOBE. |
| **virtio-blk disk** without boot-bound **viostor** | Preflight fails or **INACCESSIBLE_BOOT_DEVICE** BSOD — **rebuild** golden (`restore-virtio-boot-after-sysprep.ps1`, `Sync-VirtioBootRegistryToAllControlSets`) |
| **OOBE unattend parse error** | `./scripts/inspect-golden-unattend.sh output/windows-server-*.qcow2` — rebuild with fixed `sysprep-oobe.xml.tpl`. Do not put `<ProductKey>` in oobeSystem Shell-Setup. |
| **OOBE product key prompt** | Confirm `SetupDisplayedProductKey` RunSynchronous in Panther `unattend.xml`. Offline fix: `./scripts/repair-oobe-unattend-offline.sh output/windows-server-*.qcow2`. Host check: `make validate-unattend`. |
| OOBE still running / reboot loop | Increase `BOOT_TEST_WAIT=300` `BOOT_TEST_GUEST_WAIT=900`; do not power off during OOBE. |

Quick recovery without rebuild:

```bash
make boot-test-image IMAGE=output/windows-server-2022-standard.qcow2
```

### Failed to boot (OVMF / VM stops)

| Symptom | What to try |
|--------|-------------|
| OVMF **no bootable device** with **virtio-blk** | Run `./scripts/inspect-golden-qcow2.sh`; rebuild if VirtIO boot-start registry fails |
| OVMF **INACCESSIBLE_BOOT_DEVICE** / BSOD on virtio | Same — golden missing viostor in all control sets; rebuild with current sysprep restore scripts |
| VM stops during first boot | Sysprep OOBE can reboot; use `BOOT_TEST_WAIT=300 BOOT_TEST_GUEST_WAIT=900`. |
| Guest-agent check fails | OOBE delays agent startup; increase `BOOT_TEST_GUEST_WAIT` or use `BOOT_TEST_CHECK_GUEST=0` temporarily. |
| **winload.efi** / blue screen after locale changes | Rebuild with current split sysprep answer files. Run `make clean && make build-…`. |
| SeaBIOS image in UEFI VM | Rebuild with `efi_boot=true` or `BOOT_TEST_FIRMWARE=bios`. |
| Compare with Packer sysprep QEMU layout | `BOOT_TEST_METHOD=packer make boot-test-image IMAGE=...` |

## How it works

1. **`qemu-img create -b`** builds a copy-on-write overlay under `~/VirtualMachines/boot-test.*` (backing qcow2 stays read-only).
2. **Default (`BOOT_TEST_METHOD=libvirt`):** `virt-install --import` on **`qemu:///session`**: q35 + OVMF, **virtio-blk** root disk (fixed; OpenShift `disk.bus: virtio`), **virtio** NIC, **guest-agent channel**, **no vTPM** by default. Offline **viostor** preflight via `inspect-golden-qcow2.sh`.
3. **Alternate (`BOOT_TEST_METHOD=packer`):** raw `qemu-system-x86_64` with the OVMF sysprep Packer device list (`scripts/packer-ovmf-sysprep-qemu.sh`): ide-hd on `ide.0`, e1000 user netdev, WinRM host port forward.
4. The test checks that the VM **stays running**, optionally **guest-agent IP** (libvirt) or **WinRM** (packer), and that the **golden file size/mtime** did not change.
5. The libvirt domain / QEMU process and overlay are removed on exit (unless you keep them for debugging).

**Libvirt method** requires libvirt and a reachable network on the chosen URI. Session libvirt often has no `default` network defined; boot-test reuses the system **`virbr0`** NAT bridge when it is already up, otherwise **user-mode** SLIRP networking.

**Disk bus:** UEFI boot-test **always** uses **virtio-blk**. Preflight must pass `./scripts/inspect-golden-qcow2.sh` before the VM starts.

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
| `BOOT_TEST_METHOD` / `--method` | `libvirt` | Session libvirt + **virtio-blk** + guest-agent; `packer` replays OVMF sysprep QEMU |
| `BOOT_TEST_FIRMWARE` / `--firmware` | matches `efi_boot` in `build.pkrvars.hcl` (`uefi` by default) | Must match how the qcow2 was installed (`uefi` for OpenShift images) |
| `BOOT_TEST_DISK_BUS` / `--disk-bus` | `virtio` (fixed for UEFI) | OpenShift `disk.bus: virtio`; not overridable on UEFI boot-test |
| `BOOT_TEST_WAIT` / `--wait` | `180` | Seconds the VM must stay up before guest checks |
| `BOOT_TEST_GUEST_WAIT` / `--guest-wait` | `600` | Max seconds to wait for guest-agent IP (libvirt) or WinRM (packer) |
| `BOOT_TEST_CHECK_GUEST` | `1` | Set `0` or `--no-guest-check` to only verify the VM process stays running |
| `BOOT_TEST_GRAPHICS` / `--graphics` | `vnc` | `none` for headless automation |
| `BOOT_TEST_SHOW_CONSOLE` / `--no-console` | `1` | Launch **virt-viewer** (libvirt) or **vncviewer** (packer) |
| `BOOT_TEST_CONNECT` | `qemu:///session` | libvirt URI (`qemu:///system` needs ACLs for disks under `$HOME`) |
| `BOOT_TEST_NETWORK` | *(auto)* | `network=default`, `bridge=virbr0`, or `user` (+ `model=virtio`) |
| `BOOT_TEST_TPM` | `0` (from `provision_sysprep_vtpm`) | Set `1` only to test vTPM after OOBE works |
| `BOOT_TEST_KEEP_VM` / `--keep-vm` | `0` | Leave the domain defined after the test |
| `BOOT_TEST_WORK_DIR` | `~/VirtualMachines` | Parent directory for overlay qcow2 (`boot-test.*` subdirs) |
| `BOOT_TEST_KEEP_DISK` / `--keep-disk` | `0` | Keep the overlay under `BOOT_TEST_WORK_DIR/boot-test.*` |
| `BOOT_TEST_DRY_RUN` / `--dry-run` | `0` | Print actions without starting a VM |

Example — faster smoke test (no guest-agent wait):

```bash
BOOT_TEST_CHECK_GUEST=0 BOOT_TEST_WAIT=60 make boot-test-2025
```

Example — replay Packer sysprep QEMU layout:

```bash
BOOT_TEST_METHOD=packer make boot-test-image IMAGE=output/windows-server-2022-standard.qcow2
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

## Permission denied on backing qcow2

```
qemu-img: ... Could not open '.../windows-server-*.qcow2': Permission denied
Could not open backing image.
```

A prior **`qemu:///system`** boot-test (or libvirt **dynamic_ownership**) can leave the golden file owned by **`qemu:qemu`** mode **`640`**. Your user runs **`qemu-img create -b`** and must **read** the backing file first.

**One-time fix** (reclaim the golden for your user):

```bash
sudo chown "$(whoami):$(whoami)" output/windows-server-2022-standard.qcow2
chmod u+rw output/windows-server-2022-standard.qcow2
```

Then re-run boot-test. The script reclaims ownership automatically when **passwordless sudo** is available, and tries again in **cleanup** after the test.

Session libvirt (default) avoids this for new tests. For **`qemu:///system`**, install **`acl`** (`dnf install acl`).
