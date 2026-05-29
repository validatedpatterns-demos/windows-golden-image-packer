# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Optional pass 2: boot an existing qcow2 (after a failed or partial build) and run provisioners + sysprep only.
# Usage:
#   make build-install          # stops before sysprep; writes output/*-install.qcow2
#   make build-provision-only BASE_IMAGE=output/windows-server-2022-standard-install.qcow2

source "qemu" "from_install" {
  vm_name          = "${local.vm_name}-provision"
  output_directory = var.output_directory
  accelerator      = var.qemu_accelerator
  cpus             = var.vm_cpus
  memory           = var.vm_memory
  headless         = var.headless
  disk_image       = true
  iso_url          = var.base_image_path # qcow2 from make build-install
  iso_checksum     = "none"
  disk_interface   = var.install_disk_interface
  net_device       = var.install_net_device
  machine_type     = local.install_machine_type
  cpu_model        = "host"

  efi_boot          = var.efi_boot
  efi_firmware_code = var.efi_boot ? var.ovmf_code_path : ""
  efi_firmware_vars = var.efi_boot ? var.ovmf_vars_path : ""
  vtpm              = local.use_vtpm

  cd_label   = "PROVISION"
  cd_files   = local.provision_cd_files

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = false
  winrm_port     = 5985

  shutdown_command = "powershell -ExecutionPolicy Bypass -File C:/Windows/Temp/sysprep.ps1"
  shutdown_timeout = "45m"
}

build {
  name    = "windows-golden-provision-only"
  sources = ["source.qemu.from_install"]

  provisioner "file" {
    destination = "C:/Windows/Temp/"
    source      = "${path.root}/../scripts/"
  }

  provisioner "file" {
    content     = local.sysprep_generalize_unattend
    destination = "C:/Windows/Temp/sysprep-generalize.xml"
  }

  provisioner "file" {
    content     = local.sysprep_oobe_unattend
    destination = "C:/Windows/Temp/sysprep-oobe.xml"
  }

  provisioner "file" {
    source      = "${path.root}/../http/oobe-info-defaults.xml"
    destination = "C:/Windows/Temp/oobe-info-defaults.xml"
  }

  provisioner "file" {
    destination = "C:/Windows/Temp/"
    source      = "${path.root}/../drivers"
  }

  provisioner "powershell" {
    environment_vars = [
      "WINRM_PASSWORD=${var.admin_password}",
      "SSH_PUBLIC_KEYS=${jsonencode(local.ssh_keys_combined)}",
      "WINDOWS_ISO_PATH=${local.windows_iso_path}",
    ]
    scripts = [
      "${path.root}/../scripts/08-convert-mbr-to-uefi.ps1",
      "${path.root}/../scripts/01-install-virtio-drivers.ps1",
      "${path.root}/../scripts/02-install-qemu-guest-agent.ps1",
      "${path.root}/../scripts/03-configure-openssh.ps1",
      "${path.root}/../scripts/04-set-administrator-password.ps1",
      "${path.root}/../scripts/05-inject-ssh-keys.ps1",
      "${path.root}/../scripts/configure-oobe-locale.ps1",
      "${path.root}/../scripts/07-repair-uefi-boot.ps1",
      "${path.root}/../scripts/06-shrink-disk.ps1",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "bash \"${path.root}/../scripts/finalize-packer-output.sh\" \"${abspath(var.output_directory)}\" \"${local.vm_name}-provision\" \"${local.output_image_name}\"",
      "if [ \"$${IMAGE_OPTIMIZE:-1}\" = \"1\" ]; then bash \"${path.root}/../scripts/optimize-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"; fi",
    ]
  }
}
