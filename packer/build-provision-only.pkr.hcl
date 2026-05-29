# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Optional pass 2: boot an existing qcow2 and run provisioners + sysprep only.
#
# Two builds (pick with -only):
#   windows-golden-provision-mbr  — SeaBIOS/pc for virt-install MBR install disks
#   windows-golden-provision-gpt  — OVMF/q35 for GPT salvage / post-mbr2gpt recovery
#
# Usage:
#   make build-provision-only VERSION=2022 BASE_IMAGE=output/.packer-2022/packer-win2022-standard-install.qcow2
#   EXECUTE=1 make recover-provision VERSION=2022

source "qemu" "from_install_mbr" {
  vm_name          = "${local.vm_name}-provision"
  output_directory = var.output_directory
  accelerator      = var.qemu_accelerator
  cpus             = var.vm_cpus
  memory           = var.vm_memory
  headless         = var.headless
  disk_image       = true
  iso_url          = var.base_image_path
  iso_checksum     = "none"
  skip_resize_disk = true
  disk_interface   = var.provision_disk_interface
  net_device       = var.install_net_device
  machine_type     = "pc"
  cpu_model        = "host"

  efi_boot = false

  cd_label = "PROVISION"
  cd_files = local.provision_cd_files

  qemuargs = [
    ["-device", "qemu-xhci"],
  ]

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = false
  winrm_port     = 5985

  shutdown_command = "powershell -ExecutionPolicy Bypass -File C:/Windows/Temp/sysprep.ps1"
  shutdown_timeout = "45m"
}

source "qemu" "from_install_gpt" {
  vm_name          = "${local.vm_name}-provision"
  output_directory = var.output_directory
  accelerator      = var.qemu_accelerator
  cpus             = var.vm_cpus
  memory           = var.vm_memory
  headless         = var.headless
  disk_image       = true
  iso_url          = var.base_image_path
  iso_checksum     = "none"
  skip_resize_disk = true
  disk_interface   = var.provision_disk_interface
  net_device       = var.install_net_device
  machine_type     = "q35"
  cpu_model        = "host"

  efi_boot          = true
  efi_firmware_code = var.ovmf_code_path
  efi_firmware_vars = var.ovmf_vars_path
  vtpm              = var.vtpm

  cd_label = "PROVISION"
  cd_files = local.provision_cd_files

  qemuargs = [
    ["-boot", "order=c"],
    ["-device", "qemu-xhci"],
  ]

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
  name    = "windows-golden-provision-mbr"
  sources = ["source.qemu.from_install_mbr"]

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

  # VirtIO while SeaBIOS can still boot the MBR disk, then one reboot.
  provisioner "powershell" {
    environment_vars = local.provision_env_vars
    scripts          = ["${path.root}/../scripts/01-install-virtio-drivers.ps1"]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # mbr2gpt + UEFI boot files. No reboot here — SeaBIOS cannot boot GPT/UEFI-only afterward.
  provisioner "powershell" {
    environment_vars = local.provision_env_vars
    scripts = [
      "${path.root}/../scripts/08-convert-mbr-to-uefi.ps1",
      "${path.root}/../scripts/07-repair-uefi-boot.ps1",
    ]
  }

  provisioner "powershell" {
    environment_vars = local.provision_env_vars
    scripts = [
      "${path.root}/../scripts/02-install-qemu-guest-agent.ps1",
      "${path.root}/../scripts/03-configure-openssh.ps1",
      "${path.root}/../scripts/04-set-administrator-password.ps1",
      "${path.root}/../scripts/05-inject-ssh-keys.ps1",
      "${path.root}/../scripts/configure-oobe-locale.ps1",
      "${path.root}/../scripts/06-shrink-disk.ps1",
      "${path.root}/../scripts/09-prepare-for-sysprep.ps1",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "bash \"${path.root}/../scripts/finalize-packer-output.sh\" \"${abspath(var.output_directory)}\" \"${local.vm_name}-provision\" \"${local.output_image_name}\"",
      "if [ \"$${IMAGE_OPTIMIZE:-1}\" = \"1\" ]; then bash \"${path.root}/../scripts/optimize-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"; fi",
    ]
  }
}

build {
  name    = "windows-golden-provision-gpt"
  sources = ["source.qemu.from_install_gpt"]

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
    environment_vars = local.provision_env_vars
    scripts = [
      "${path.root}/../scripts/08-convert-mbr-to-uefi.ps1",
      "${path.root}/../scripts/07-repair-uefi-boot.ps1",
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    environment_vars = local.provision_env_vars
    scripts = [
      "${path.root}/../scripts/verify-uefi-boot.ps1",
      "${path.root}/../scripts/01-install-virtio-drivers.ps1",
      "${path.root}/../scripts/02-install-qemu-guest-agent.ps1",
      "${path.root}/../scripts/03-configure-openssh.ps1",
      "${path.root}/../scripts/04-set-administrator-password.ps1",
      "${path.root}/../scripts/05-inject-ssh-keys.ps1",
      "${path.root}/../scripts/configure-oobe-locale.ps1",
      "${path.root}/../scripts/06-shrink-disk.ps1",
      "${path.root}/../scripts/09-prepare-for-sysprep.ps1",
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  post-processor "shell-local" {
    inline = [
      "bash \"${path.root}/../scripts/finalize-packer-output.sh\" \"${abspath(var.output_directory)}\" \"${local.vm_name}-provision\" \"${local.output_image_name}\"",
      "if [ \"$${IMAGE_OPTIMIZE:-1}\" = \"1\" ]; then bash \"${path.root}/../scripts/optimize-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"; fi",
    ]
  }
}
