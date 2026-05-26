# Copy to build.pkrvars.hcl and set paths/passwords before building.
# cp example.pkrvars.hcl build.pkrvars.hcl

# Version selection: make build uses BUILD_VERSIONS (default 2022 2025), not windows_version here.
# windows_version is a per-run Packer variable (set by Makefile -var or manual packer -var).
windows_edition = "Standard"

# --- Windows Server 2022 ---
windows_iso_path_2022 = "/path/to/windows-server-2022.iso"
# product_key_2022      = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"

# --- Windows Server 2025 ---
windows_iso_path_2025 = "/path/to/windows-server-2025.iso"
# product_key_2025      = "YYYYY-YYYYY-YYYYY-YYYYY-YYYYY"

virtio_win_iso_path = "/path/to/virtio-win.iso"

# Phase 1 install bus (ide = reliable unattend; virtio installed in phase 2 via WinRM)
install_disk_interface = "ide"
install_net_device     = "e1000"

admin_password = "ChangeMe-Use-A-Strong-Password!"

# Optional: bake SSH keys into the golden image
ssh_public_keys = [
  # "ssh-ed25519 AAAA... user@host",
]

# ssh_public_keys_file = "/path/to/authorized_keys"

# Relative to packer/ (where make build runs). Resolves to repo output/.
output_directory = "../output"
vm_cpus          = 4
vm_memory        = 8192
# Virtual disk size; match or exceed this in DataVolume/PVC (e.g. 60G -> storage: 60Gi).
disk_size        = "60G"
headless         = true

# Leave false on Fedora/QEMU 10 — SeaBIOS boots the Windows ISO reliably. See docs/uefi-install.md.
efi_boot = false

# Only used when efi_boot = true (Packer enables UEFI if these are wired in unconditionally).
# ovmf_code_path = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
# ovmf_vars_path  = "/usr/share/edk2/ovmf/OVMF_VARS.fd"
