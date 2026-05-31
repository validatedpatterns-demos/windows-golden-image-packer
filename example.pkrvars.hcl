# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

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

# virt-install install disk (libvirt SATA/AHCI). Packer provision uses provision_disk_interface (ide).
install_disk_interface = "sata"
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
# Virtual disk size at build (minimum DataVolume on import). Use a larger PVC in OpenShift;
# first deploy boot extends C: automatically (extend-system-partition.ps1).
disk_size        = "40G"
headless         = false

# true (default): UEFI install via virt-install, then Packer provision + sysprep (OpenShift/CNV).
# false: one-shot SeaBIOS Packer build — do not deploy those disks to UEFI VMs.
efi_boot = true

# virt-install Setup firmware: seabios (default) boots Microsoft UDF DVD; uefi often BdsDxe timeouts on QEMU 10.
# install_firmware = "seabios"

# Emulated TPM 2.0 (swtpm) on UEFI builds; disable only for hosts without swtpm.
vtpm = true

# OVMF sysprep pass (from_install_gpt): default false — matches boot-test and avoids first-OVMF boot loops.
# provision_sysprep_vtpm = false

# OVMF paths (optional; virt-install auto-picks a matching pair). On Fedora 44+ use 4M firmware
# for q35 — do not point at 2M OVMF_CODE.fd alone or the VM may not boot:
# ovmf_code_path = "/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2"
# ovmf_vars_path  = "/usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2"
