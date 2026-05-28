# Windows Golden Image Packer

Build **Windows Server 2022** and **2025** golden images as **qcow2** disks for **OpenShift Virtualization** (KubeVirt). Images default to **Standard Edition**, include **VirtIO** drivers and the **QEMU guest agent**, run **OpenSSH Server**, set the **Administrator** password, and optionally bake in **SSH public keys**.

## Features

| Requirement | Implementation |
|-------------|----------------|
| Windows Server 2022 / 2025 | `make build` runs both sequentially; each version uses staging dir `.packer-<version>` then promotes to `output/` |
| Standard Edition (default) | `windows_edition` defaults to `Standard`; Datacenter supported |
| VirtIO drivers | Installed in phase 2 (WinRM); WinPE uses IDE disk by default |
| QEMU guest agent | `02-install-qemu-guest-agent.ps1` from virtio-win ISO |
| OpenSSH | `03-configure-openssh.ps1` (Windows capability) |
| Administrator password | autounattend + `04-set-administrator-password.ps1` |
| SSH key injection | `ssh_public_keys` / `ssh_public_keys_file` + `05-inject-ssh-keys.ps1` |
| Disk shrink + optimize | `06-shrink-disk.ps1` (pre-sysprep); post-build `optimize-qcow2.sh` (auto unless `IMAGE_OPTIMIZE=0`) |
| qcow2 for OpenShift Virt | QEMU builder, VirtIO disk/net, sysprep; **UEFI install** via [docs/uefi-install.md](docs/uefi-install.md) |

## Prerequisites

On a Linux build host with KVM:

- [Packer](https://www.packer.io/) >= 1.9
- QEMU/KVM, `qemu-system-x86_64`, OVMF (`edk2-ovmf` or `ovmf` package)
- Windows Server **installation ISOs** (2022 and/or 2025) — licensed media from Microsoft
- [virtio-win](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) ISO

```bash
# Fedora/RHEL example
sudo dnf install -y packer qemu-kvm edk2-ovmf swtpm

# Download virtio-win (optional helper)
make download-virtio
```

## Quick start

1. Copy the example variables and edit paths/secrets:

   Edit `example.pkrvars.hcl`, or copy it for secrets and overrides:

   ```bash
   cp example.pkrvars.hcl build.pkrvars.hcl
   # Edit build.pkrvars.hcl: ISO paths per version (2022/2025), admin_password, ssh_public_keys
   ```

2. Initialize Packer plugins and build:

   ```bash
   make init
   make validate      # uses packer/ci.pkrvars.hcl by default
   make build         # Windows Server 2022, then 2025 (sequential)
   ```

   Set **both** `windows_iso_path_2022` and `windows_iso_path_2025` in `build.pkrvars.hcl` before `make build`.
   One version only: `make build-2022`, `make build-2025`, or `make build BUILD_VERSIONS=2022`.

   `make validate` works without editing var files. Build targets use `build.pkrvars.hcl` (`VAR_FILE`).

3. Output images (under `output/` or `packer/output/` depending on `output_directory`):

   ```text
   windows-server-2022-standard.qcow2
   windows-server-2025-standard.qcow2
   ```

4. **Optional:** push to Quay — [docs/quay-publish.md](docs/quay-publish.md):

   ```bash
   cp example.quay.env quay.env   # set QUAY_IMAGE_2022 and QUAY_IMAGE_2025
   podman login quay.io
   make push-quay                 # pushes every golden qcow2 found
   make build-push                # build both, then push all found
   make image-size                # DataVolume minimum + file size for built images
   ```

See [docs/openshift-virtualization.md](docs/openshift-virtualization.md) for importing the disk and VM settings.

5. **Optional:** boot-test the image before upload (VirtIO disk, overlay copy — does not modify the golden qcow2) — [docs/boot-test.md](docs/boot-test.md):

   ```bash
   make boot-test-2025
   ```

Install uses an **IDE** disk during Setup so WinPE can partition without VirtIO drivers; see [docs/install-phases.md](docs/install-phases.md) for the two-phase flow and optional split builds (`make build-install` / `make build-provision-only`).

## Image size and DataVolume sizing

Two sizes matter:

| Metric | Meaning | How to read it |
|--------|---------|----------------|
| **Virtual size** | Guest disk capacity; **minimum DataVolume/PVC** | `make image-size` or `qemu-img info image.qcow2` |
| **File size** | Bytes stored in the qcow2 (upload/registry) | Same report; reduced by `06-shrink-disk.ps1` + `optimize-qcow2.sh` |

After a build:

```bash
make image-size
# or one file:
make image-size GOLDEN_QCOW2=output/windows-server-2022-standard.qcow2
```

Example output:

```text
DataVolume minimum:  60Gi  (storage.requests.storage: 60Gi)
```

That value is derived from the qcow2 **virtual size** (from `disk_size` at build time, default 60G). It does not shrink when the file is optimized. Set `disk_size` before `make build` if you need a smaller virtual disk.

Re-run host-side optimization without rebuilding:

```bash
make optimize-image                  # all golden images
make optimize-image GOLDEN_QCOW2=output/windows-server-2022-standard.qcow2
```

Skip automatic optimization during build (faster, larger artifact):

```bash
IMAGE_OPTIMIZE=0 make build
```

**Note:** `06-shrink-disk.ps1` runs `cipher /w` to zero free space and can add **15–60+ minutes** to the build before sysprep.

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_VERSIONS` (Makefile) | `2022 2025` | Which releases `make build` runs, in order |
| `windows_version` (Packer) | `2022` | **One** release per `packer build` (ISO, virtio tree, output name). Set by `make build-version` / `-var`; not a list in `build.pkrvars.hcl` |
| `windows_edition` | `Standard` | `Standard` or `Datacenter` |
| `windows_iso_path_2022` | `""` | 2022 install ISO (required for 2022 builds) |
| `windows_iso_path_2025` | `""` | 2025 install ISO (required for 2025 builds) |
| `virtio_win_iso_path` | (required) | virtio-win ISO |
| `admin_password` | (required) | Administrator password (sensitive) |
| `product_key_2022` | `""` | Optional key when `windows_version = "2022"` |
| `product_key_2025` | `""` | Optional key when `windows_version = "2025"` |
| `ssh_public_keys` | `[]` | List of OpenSSH public keys |
| `ssh_public_keys_file` | `""` | File with one key per line |
| `output_directory` | `../output` | qcow2 output directory |
| `disk_size` | `60G` | Root disk virtual size; set DataVolume/PVC to at least this (e.g. `60Gi`) |
| `install_disk_interface` | `ide` | Disk bus during Setup (`ide` recommended) |
| `install_net_device` | `e1000` | NIC during install/WinRM (`e1000` until VirtIO net is installed) |
| `efi_boot` | `false` | Packer install firmware; keep `false` on QEMU 10 |
| `ovmf_code_path` | Fedora OVMF path | OVMF paths when `efi_boot = true` |

Build Datacenter 2025:

```bash
cd packer && packer build -var-file=../build.pkrvars.hcl \
  -var windows_version=2025 -var windows_edition=Datacenter
```

## Build flow

```mermaid
flowchart LR
  A[Windows ISO] --> B[Phase 1: IDE disk + autounattend]
  B --> C[Phase 2: WinRM VirtIO + tools]
  C --> D[provisioners]
  D --> E[VirtIO + QEMU-GA + OpenSSH]
  E --> F[Password + SSH keys]
  F --> S[06 shrink disk + zero free space]
  S --> G[sysprep generalize]
  G --> H[qcow2 artifact]
  H --> O[optimize qcow2 on host]
```

1. **Unattended install** from ISO with VirtIO storage/network drivers during WinPE.
2. **WinRM** connects for provisioning scripts.
3. **Disk shrink** clears temporaries and zeros free space so the qcow2 can sparsify.
4. **Sysprep** generalizes the disk for cloning; image shuts down.
5. Post-processors rename the qcow2, then **optimize** it (`qemu-img convert -c`) unless `IMAGE_OPTIMIZE=0`.
6. Run **`make image-size`** for the exact DataVolume storage request.

## Repository layout

```text
packer/          Packer HCL (QEMU source + build)
http/            autounattend.xml.tpl
scripts/         PowerShell provisioning + sysprep
docs/            OpenShift Virtualization notes
example.pkrvars.hcl
```

## Security notes

- Do not commit `build.pkrvars.hcl` (gitignored); it contains passwords.
- Rotate the Administrator password after deploying VMs in production.
- Prefer SSH keys over password-only access where policy allows.
- Verify Windows ISO image index names if install fails at edition selection (`dism /Get-WimInfo` on the ISO).

## Troubleshooting

- **`make build` left only the last Windows version in `output/`**: Packer removes `output_directory` at the start of each build. Current Makefile uses per-version staging (`.packer-2022`, `.packer-2025`) and `scripts/promote-golden-output.sh` so both qcow2 files remain in `output/` for `make push-quay`.

- **`push-quay`: No golden qcow2 under output/**: the disk may be under `packer/output/` when `output_directory = "./output"` in `build.pkrvars.hcl`. `make push-quay` searches both `output/` and `packer/output/`. Prefer `output_directory = "../output"` in `build.pkrvars.hcl` (see `example.pkrvars.hcl`).

- **Post-processor: No qcow2 found in ./output**: the QEMU builder writes `output_directory/<vm_name>` **without** a `.qcow2` suffix (e.g. `packer-win2022-standard`). The post-processor now finds that file and renames it to `windows-server-*-*.qcow2`. If a long build already finished, recover with: `mv packer/output/packer-win2022-standard output/windows-server-2022-standard.qcow2` (adjust names/paths). Use `output_directory = "../output"` in `build.pkrvars.hcl` (see `example.pkrvars.hcl`).

- **Interrupted or failed build**: Packer default `-on-error=cleanup` deletes its `output_directory` on Ctrl+C. This project uses **`PACKER_ON_ERROR=abort`** (Makefile default) and writes Packer artifacts under **`output/.packer-*/work/`** so the **install qcow2** in the staging root is kept. Retry provision with `SKIP_INSTALL=1 make build-version VERSION=2022` or `make build-provision-only BASE_IMAGE=output/.packer-2022/packer-win2022-standard-install.qcow2`. Use **`make clean`** when you want to wipe all artifacts.

- **`stage-virtio` permission denied**: virtio-win ISO directories are often mode `555`. The script no longer `rm -rf`s them; it skips if drivers are already present, or `mv`s the old tree to `extras/virtio-win-staged.orphan.*` on refresh. If `mv` fails: `sudo chown -R $(whoami): extras/virtio-win-staged && chmod -R u+rwX extras/virtio-win-staged`.

- **Windows VM will not boot on OpenShift with `bus: virtio`**: common causes are (1) **viostor/vioscsi** not boot-start — rebuild with current `01-install-virtio-drivers.ps1` or see [docs/openshift-boot-troubleshooting.md](docs/openshift-boot-troubleshooting.md); (2) **UEFI VM** + **SeaBIOS-built** image — use UEFI install ([docs/uefi-install.md](docs/uefi-install.md)) or interim `firmware.bootloader.bios` / `bus: sata` for recovery.

- **Will not boot / OVMF PXE / still shows UEFI boot menu**: Packer turns on UEFI whenever `efi_firmware_code` / `efi_firmware_vars` are set, even if `efi_boot = false`. Use `efi_boot = false` and **do not** set OVMF paths in `build.pkrvars.hcl` (or only set them when `efi_boot = true`). Run `make clean`, then `make build`. For **UEFI** golden images use [docs/uefi-install.md](docs/uefi-install.md).

- **OVMF `Boot002` / `Boot0003`**: firmware is active — remove `ovmf_*` from your var file or set `efi_boot = true` intentionally and use the virt-install UEFI script instead of Packer.

- **No bootable device**: do not pass `qemuargs` with `-drive` — it replaces Packer's disk and Windows ISO drives.

- **Stuck on "Booting from Floppy"** or **Press any key**: `boot_command` sends Space/Enter; set `headless = false` and watch the VNC URL Packer prints.
- **Two VMs at once** (`packer-win2022-standard` and `packer-win2022-standard-install`): `packer build .` without `-only` runs every build in `packer/`. Use `make build` or `packer build -only=windows-golden-image .`. Do not use `packer build build.pkr.hcl` alone (that skips `variables.pkr.hcl`).

- **Unsupported attribute / No builds to run**: pass the directory `.` (not a single `.pkr.hcl` file). Use the full build id from `packer validate .`, e.g. `-only=windows-golden-image.qemu.windows`.

- **Invalid autounattend for pass [specialize]**: WinRM runs via `Microsoft-Windows-Deployment` / `RunSynchronous` / `Path` (not `CommandLine` under `Shell-Setup`). Invalid settings like `EnableFirewall` under `Microsoft-Windows-Setup` were removed. Run `make clean` so the floppy is regenerated.

- **BdsDxe: No bootable option / DVD Time out**: OVMF cannot start the Microsoft ISO UEFI loader on many Fedora/QEMU 10 hosts. Use default **`install_firmware = "seabios"`** (see `example.pkrvars.hcl`); install uses SeaBIOS, Packer runs **`mbr2gpt`**. See [docs/uefi-install.md](docs/uefi-install.md).
- **Windows cannot be installed to this disk … GPT partition style**: you booted **UEFI** while using the **MBR** answer file, or the opposite. Default **`install_firmware = "seabios"`** uses `autounattend-bios.xml.tpl`. Do not pick a UEFI DVD entry during a SeaBIOS install.
- **Installer runs but asks for language/edition/disk (unattend ignored)**: for UEFI builds, confirm `wimlib-imagex` injected autounattend (`Install ISO with autounattend in boot.wim` in the log). For SeaBIOS (`efi_boot = false`), the floppy carries `autounattend.xml`. Run `make stage-virtio`. Check `%WINDIR%\Panther\setuperr.log` in the VM if a step fails.

- **Install cannot see disk**: VirtIO SCSI needs `vioscsi` + `viostor` on the PROVISION CD; re-run `make stage-virtio` and confirm `drivers/vioscsi/2k22/amd64/vioscsi.sys` exists.

- **Stops on "Select location to install" but shows the expected install disk size**: Setup sees the QEMU disk; unattended partitioning did not finish. On SeaBIOS (`efi_boot = false`) the answer file must use the MBR layout (System Reserved + Windows). Run `make clean` and rebuild so the floppy is regenerated. Short-term: click the unallocated/drive entry and **Next** to continue. If it still prompts every build, check `X:\Windows\Panther\setuperr.log` on the VM (Shift+F10 during setup).
- **`DiskConfiguration` / `ImageInstall` errors**: use defaults `install_disk_interface = "ide"` and `install_net_device = "e1000"` (see [docs/install-phases.md](docs/install-phases.md)). Run `make clean` before rebuilding. Optional split: `make build-install` then `make build-provision-only BASE_IMAGE=...`.
- **VirtIO driver media not found**: run `STAGE_FORCE=1 make stage-virtio` (slim tree ~27MB, not ~500MB). Provisioners read `C:\Windows\Temp\drivers\` (WinRM upload) and fall back to the PROVISION CD (`viostor\2k22\amd64` at CD root or under `drivers\`). On failure the script lists top-level entries on each path it checked.

- **Hung on Uploading drivers/**: cancel (`Ctrl+C`), `make clean`, `STAGE_FORCE=1 make stage-virtio`, then `make build`. An unstaged `drivers/` tree is ~500MB; slim staging is required.

- **`Add-WindowsCapability` / OpenSSH / DISM exit 5**: WinRM cannot install capabilities (access denied). OpenSSH is installed as **SYSTEM** during specialize (`A:\install-openssh-server.ps1`) and, if needed, via a **scheduled task** in `03-configure-openssh.ps1` (not DISM over WinRM). Run `make clean` so the floppy and autounattend are regenerated. The guest needs **network** during install/provision so Windows Update can supply the OpenSSH capability. On failure, check `C:\Windows\Temp\openssh-install.log` in the VM.

- **`sshd_config not found`**: `Get-WindowsCapability` can show **Installed** before `C:\ProgramData\ssh\sshd_config` exists. Scripts now run `install-sshd.ps1`, copy `sshd_config_default`, or start `sshd` once to create the file. Run `make clean` and rebuild so the updated floppy/scripts are used.

- **OpenSSH step appears stuck for several minutes**: Packer often prints little until a PowerShell script finishes. On `03-configure-openssh.ps1`, **`Get-WindowsCapability` can take 1-3 minutes**; the **SYSTEM install task** often takes **5-15 minutes** with sparse output. That is usually normal. If OpenSSH was already installed in specialize, script 03 finishes in under a minute.

- **WinRM timeout** (Server Manager desktop, no disk activity): install finished; WinRM was not enabled. On the VM run `enable-winrm.ps1` from the PROVISION CD or open PowerShell as Administrator and run `winrm quickconfig -q -force` plus firewall rules (see `http/enable-winrm.ps1`). Rebuilds include **first-logon** WinRM setup as a fallback. Check Packer is forwarding port 5985: `pgrep -af hostfwd.*5985`.

- **WinRM timeout (general)**: ensure the build host can reach the VM on port 5985; try `headless = false` to watch setup.
- **Wrong edition**: confirm `/IMAGE/NAME` in the ISO matches `locals.edition_image_names` in `packer/locals.pkr.hcl`.
- **Product key**: set `product_key_2022` or `product_key_2025` in `build.pkrvars.hcl` (see `example.pkrvars.hcl`). The build picks the key for the active `windows_version` (`make build-2025` passes `-var windows_version=2025`). There is no generic `product_key` variable. Omit both to install without a key (evaluation/grace, or activate later via KMS). `scripts/render-autounattend.sh` validates XML with `xmllint` before virt-install. Verify: `VERSION=2022 bash scripts/render-autounattend.sh | xmllint --noout -`.
- **2025 key rejected during setup**: the key must match the edition (`windows_edition` Standard vs Datacenter) and your licensing channel (MAK from VLSC vs KMS GVLK). For KMS clients use the Microsoft GVLK for the edition (for example Server 2025 Standard: `TVRH6-WHNXV-R9WG3-9XRFY-MY832`) and activate against your KMS host after deploy. A 2022 MAK/GVLK will not work on 2025 media. Split install (`make build-install`) requires `VERSION=2025` or it defaults to 2022 and uses `product_key_2022`.
- **OVMF not found**: set `ovmf_code_path` / `ovmf_vars_path` for your distribution.

## License

Packer templates (`packer/`), shell scripts (`scripts/`), and unattended-install assets (`http/`) are licensed under the [Apache License, Version 2.0](LICENSE).

Third-party components are **not** covered by that license, including:

- Microsoft Windows Server installation media and deployed Windows instances (your own licenses)
- [virtio-win](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) drivers staged from the virtio-win ISO
- Tools installed inside the guest image (QEMU guest agent, OpenSSH, and similar) under their respective licenses
