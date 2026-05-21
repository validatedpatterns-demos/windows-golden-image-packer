# Windows Golden Image Packer

Build **Windows Server 2022** and **2025** golden images as **qcow2** disks for **OpenShift Virtualization** (KubeVirt). Images default to **Standard Edition**, include **VirtIO** drivers and the **QEMU guest agent**, run **OpenSSH Server**, set the **Administrator** password, and optionally bake in **SSH public keys**.

## Features

| Requirement | Implementation |
|-------------|----------------|
| Windows Server 2022 / 2025 | `windows_version` variable (`2022` or `2025`) |
| Standard Edition (default) | `windows_edition` defaults to `Standard`; Datacenter supported |
| VirtIO drivers | Installed in phase 2 (WinRM); WinPE uses IDE disk by default |
| QEMU guest agent | `02-install-qemu-guest-agent.ps1` from virtio-win ISO |
| OpenSSH | `03-configure-openssh.ps1` (Windows capability) |
| Administrator password | autounattend + `04-set-administrator-password.ps1` |
| SSH key injection | `ssh_public_keys` / `ssh_public_keys_file` + `05-inject-ssh-keys.ps1` |
| qcow2 for OpenShift Virt | QEMU builder, VirtIO disk/net, sysprep; **UEFI install** via [docs/uefi-install.md](docs/uefi-install.md) |

## Prerequisites

On a Linux build host with KVM:

- [Packer](https://www.packer.io/) >= 1.9
- QEMU/KVM, `qemu-system-x86_64`, OVMF (`edk2-ovmf` or `ovmf` package)
- Windows Server **installation ISOs** (2022 and/or 2025) — licensed media from Microsoft
- [virtio-win](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) ISO

```bash
# Fedora/RHEL example
sudo dnf install -y packer qemu-kvm edk2-ovmf

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
   make build-2022    # or: make build-2025
   ```

   `make validate` works without editing var files. Build targets default to `build.pkrvars.hcl`
   (`VAR_FILE`); set real ISO paths there before `make build` or `make build-2022`.

   Manual build from `packer/` (flags go **after** `build`):

   ```bash
   cd packer && packer init .
   packer build -force -var-file=../build.pkrvars.hcl -only=windows-golden-image.qemu.windows .
   ```

3. Output image:

   ```text
   output/windows-server-2022-standard.qcow2
   ```

See [docs/openshift-virtualization.md](docs/openshift-virtualization.md) for importing the disk and VM settings.

Install uses an **IDE** disk during Setup so WinPE can partition without VirtIO drivers; see [docs/install-phases.md](docs/install-phases.md) for the two-phase flow and optional split builds (`make build-install` / `make build-provision-only`).

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `windows_version` | `2022` | `2022` or `2025` |
| `windows_edition` | `Standard` | `Standard` or `Datacenter` |
| `windows_iso_path_2022` | `""` | 2022 install ISO (required when `windows_version = "2022"`) |
| `windows_iso_path_2025` | `""` | 2025 install ISO (required when `windows_version = "2025"`) |
| `virtio_win_iso_path` | (required) | virtio-win ISO |
| `admin_password` | (required) | Administrator password (sensitive) |
| `product_key_2022` | `""` | Optional key when `windows_version = "2022"` |
| `product_key_2025` | `""` | Optional key when `windows_version = "2025"` |
| `ssh_public_keys` | `[]` | List of OpenSSH public keys |
| `ssh_public_keys_file` | `""` | File with one key per line |
| `output_directory` | `../output` | qcow2 output directory |
| `disk_size` | `80G` | Root disk size |
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
  F --> G[sysprep generalize]
  G --> H[qcow2 artifact]
```

1. **Unattended install** from ISO with VirtIO storage/network drivers during WinPE.
2. **WinRM** connects for provisioning scripts.
3. **Sysprep** generalizes the disk for cloning; image shuts down.
4. Post-processor renames the qcow2 to `windows-server-{version}-{edition}.qcow2`.

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

- **Interrupted or failed build**: `make clean` sends SIGTERM/SIGKILL to `qemu-system` processes whose command line includes `packer-win`, then deletes `output/`, Packer cache dirs, and partial qcow2 files. Use `make clean-force` if cleanup should continue even when a VM process could not be killed.

- **`stage-virtio` permission denied**: virtio-win ISO directories are often mode `555`. The script no longer `rm -rf`s them; it skips if drivers are already present, or `mv`s the old tree to `extras/virtio-win-staged.orphan.*` on refresh. If `mv` fails: `sudo chown -R $(whoami): extras/virtio-win-staged && chmod -R u+rwX extras/virtio-win-staged`.

- **Will not boot / OVMF PXE / still shows UEFI boot menu**: Packer turns on UEFI whenever `efi_firmware_code` / `efi_firmware_vars` are set, even if `efi_boot = false`. Use `efi_boot = false` and **do not** set OVMF paths in `build.pkrvars.hcl` (or only set them when `efi_boot = true`). Run `make clean`, then `make build`. For **UEFI** golden images use [docs/uefi-install.md](docs/uefi-install.md).

- **OVMF `Boot002` / `Boot0003`**: firmware is active — remove `ovmf_*` from your var file or set `efi_boot = true` intentionally and use the virt-install UEFI script instead of Packer.

- **No bootable device**: do not pass `qemuargs` with `-drive` — it replaces Packer's disk and Windows ISO drives.

- **Stuck on "Booting from Floppy"** or **Press any key**: `boot_command` sends Space/Enter; set `headless = false` and watch the VNC URL Packer prints.
- **Two VMs at once** (`packer-win2022-standard` and `packer-win2022-standard-install`): `packer build .` without `-only` runs every build in `packer/`. Use `make build` or `packer build -only=windows-golden-image .`. Do not use `packer build build.pkr.hcl` alone (that skips `variables.pkr.hcl`).

- **Unsupported attribute / No builds to run**: pass the directory `.` (not a single `.pkr.hcl` file). Use the full build id from `packer validate .`, e.g. `-only=windows-golden-image.qemu.windows`.

- **Invalid autounattend for pass [specialize]**: WinRM runs via `Microsoft-Windows-Deployment` / `RunSynchronous` / `Path` (not `CommandLine` under `Shell-Setup`). Invalid settings like `EnableFirewall` under `Microsoft-Windows-Setup` were removed. Run `make clean` so the floppy is regenerated.

- **Installer runs but asks for language/edition/disk (unattend ignored)**: ensure `efi_boot = false` (floppy carries `autounattend.xml`) and `make stage-virtio` completed. Check `%WINDIR%\Panther\setuperr.log` in the VM if a step fails.

- **Install cannot see disk**: VirtIO SCSI needs `vioscsi` + `viostor` on the PROVISION CD; re-run `make stage-virtio` and confirm `drivers/vioscsi/2k22/amd64/vioscsi.sys` exists.

- **`DiskConfiguration` / `ImageInstall` errors**: use defaults `install_disk_interface = "ide"` and `install_net_device = "e1000"` (see [docs/install-phases.md](docs/install-phases.md)). Run `make clean` before rebuilding. Optional split: `make build-install` then `make build-provision-only BASE_IMAGE=...`.
- **VirtIO driver media not found**: run `STAGE_FORCE=1 make stage-virtio` (slim tree ~27MB, not ~500MB). Provisioners read `C:\Windows\Temp\drivers\` (WinRM upload) and fall back to the PROVISION CD (`viostor\2k22\amd64` at CD root or under `drivers\`). On failure the script lists top-level entries on each path it checked.

- **Hung on Uploading drivers/**: cancel (`Ctrl+C`), `make clean`, `STAGE_FORCE=1 make stage-virtio`, then `make build`. An unstaged `drivers/` tree is ~500MB; slim staging is required.

- **`Add-WindowsCapability` / OpenSSH / DISM exit 5**: WinRM cannot install capabilities (access denied). OpenSSH is installed as **SYSTEM** during specialize (`A:\install-openssh-server.ps1`) and, if needed, via a **scheduled task** in `03-configure-openssh.ps1` (not DISM over WinRM). Run `make clean` so the floppy and autounattend are regenerated. The guest needs **network** during install/provision so Windows Update can supply the OpenSSH capability. On failure, check `C:\Windows\Temp\openssh-install.log` in the VM.

- **OpenSSH step appears stuck for several minutes**: Packer often prints little until a PowerShell script finishes. On `03-configure-openssh.ps1`, **`Get-WindowsCapability` can take 1-3 minutes**; the **SYSTEM install task** often takes **5-15 minutes** with sparse output. That is usually normal. If OpenSSH was already installed in specialize, script 03 finishes in under a minute.

- **WinRM timeout** (Server Manager desktop, no disk activity): install finished; WinRM was not enabled. On the VM run `enable-winrm.ps1` from the PROVISION CD or open PowerShell as Administrator and run `winrm quickconfig -q -force` plus firewall rules (see `http/enable-winrm.ps1`). Rebuilds include **first-logon** WinRM setup as a fallback. Check Packer is forwarding port 5985: `pgrep -af hostfwd.*5985`.

- **WinRM timeout (general)**: ensure the build host can reach the VM on port 5985; try `headless = false` to watch setup.
- **Wrong edition**: confirm `/IMAGE/NAME` in the ISO matches `locals.edition_image_names` in `packer/locals.pkr.hcl`.
- **Product key**: set `product_key_2022` or `product_key_2025` in `build.pkrvars.hcl` (see `example.pkrvars.hcl`). The build picks the key for the active `windows_version`. Omit both to install without a key (evaluation/grace, or activate later via KMS).
- **OVMF not found**: set `ovmf_code_path` / `ovmf_vars_path` for your distribution.

## License

Provide your own Windows Server licenses for installation media and deployed VMs.
