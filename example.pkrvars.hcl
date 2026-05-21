# Copy to build.pkrvars.hcl and set paths/passwords before building.
# cp example.pkrvars.hcl build.pkrvars.hcl

windows_version = "2022"
windows_edition = "Standard"

windows_iso_path    = "/path/to/windows-server.iso"
virtio_win_iso_path = "/path/to/virtio-win.iso"

admin_password = "ChangeMe-Use-A-Strong-Password!"

# Optional: bake SSH keys into the golden image
ssh_public_keys = [
  # "ssh-ed25519 AAAA... user@host",
]

# ssh_public_keys_file = "/path/to/authorized_keys"

output_directory = "./output"
vm_cpus          = 4
vm_memory        = 8192
disk_size        = "80G"
headless         = true

# Fedora/RHEL OVMF paths (adjust for Debian/Ubuntu: ovmf package)
ovmf_code_path = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
ovmf_vars_path  = "/usr/share/edk2/ovmf/OVMF_VARS.fd"
