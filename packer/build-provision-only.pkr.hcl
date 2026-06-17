# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Pass 2: boot virtio-blk UEFI install disk, provision over WinRM, sysprep, golden qcow2.
#
# Usage:
#   make build VERSION=2022
#   make build-provision-only VERSION=2022 BASE_IMAGE=output/.packer-2022/packer-win2022-standard-install.qcow2

source "qemu" "from_install_gpt" {
  vm_name          = "${local.vm_name}-provision"
  output_directory = var.output_directory
  accelerator      = var.qemu_accelerator
  cpus             = var.vm_cpus
  memory           = var.vm_memory
  disk_image       = true
  iso_url          = var.base_image_path
  iso_checksum     = "none"
  skip_resize_disk = true
  # Placeholder; gpt_ovmf_qemuargs attaches the disk as virtio-blk for OpenShift parity.
  disk_interface   = "ide"
  net_device       = var.install_net_device
  machine_type     = "q35"
  cpu_model        = "host"
  vga              = "std"

  efi_boot          = true
  efi_firmware_code = var.ovmf_code_path
  efi_firmware_vars = var.ovmf_vars_path
  vtpm              = var.provision_sysprep_vtpm

  boot_wait    = "90s"
  boot_command = []
  headless     = true
  display      = "none"

  qemuargs = local.gpt_ovmf_qemuargs

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = false
  winrm_port     = 5985

  shutdown_command = ""
  shutdown_timeout = "120m"
}

build {
  name    = "windows-golden-provision"
  sources = ["source.qemu.from_install_gpt"]

  # One small script upload, then copy scripts+drivers from PROVISION CD (SATA, like pass 1).
  provisioner "file" {
    source      = "${path.root}/../scripts/stage-provision-from-cd.ps1"
    destination = "C:/Windows/Temp/stage-provision-from-cd.ps1"
  }

  provisioner "powershell" {
    pause_before = "30s"
    inline       = ["& 'C:/Windows/Temp/stage-provision-from-cd.ps1'"]
  }

  provisioner "file" {
    content     = local.sysprep_generalize_unattend
    destination = "C:/Windows/Temp/sysprep-generalize.xml"
  }

  provisioner "file" {
    content     = local.sysprep_oobe_unattend
    destination = "C:/Windows/Temp/sysprep-oobe.xml"
  }

  provisioner "powershell" {
    environment_vars = local.provision_env_vars
    # Scripts already on guest from CD; inline avoids winrmcp re-upload per script.
    inline = ["& 'C:/Windows/Temp/run-provision-pass.ps1'"]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    environment_vars = concat(local.provision_env_vars, [
      "SYSPREP_PROVISIONER_RUN=1",
      "SYSPREP_WORKER_DELAY_SECONDS=45",
    ])
    # Script already on guest from CD staging; inline avoids a second winrmcp upload.
    # Worker is scheduled ~45s later so Packer can tear down WinRM before generalize.
    skip_clean = true
    inline     = ["& 'C:/Windows/Temp/sysprep.ps1'"]
  }

  provisioner "shell-local" {
    inline = [
      "bash \"${path.root}/../scripts/wait-packer-qemu-exit.sh\" \"${local.vm_name}-provision\" 7200",
    ]
    environment_vars = [
      "PACKER_QEMU_FORCE_AFTER=1800",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "bash \"${path.root}/../scripts/finalize-packer-output.sh\" \"${abspath(var.output_directory)}\" \"${local.vm_name}-provision\" \"${local.output_image_name}\"",
      "bash \"${path.root}/../scripts/fix-virtio-startoverride-offline.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"",
      "bash \"${path.root}/../scripts/fix-bcd-orphan-winload-offline.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"",
      "VERSION=${var.windows_version} VAR_FILE=${abspath("../build.pkrvars.hcl")} bash \"${path.root}/../scripts/repair-oobe-unattend-offline.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"",
      "bash \"${path.root}/../scripts/inspect-golden-unattend.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"",
      "bash \"${path.root}/../scripts/verify-sysprep-succeeded-offline.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"",
      "INSPECT_VIRTIO_STRICT=1 bash \"${path.root}/../scripts/inspect-golden-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"",
      "if [ \"$${IMAGE_OPTIMIZE:-1}\" = \"1\" ]; then bash \"${path.root}/../scripts/optimize-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"; fi",
    ]
  }
}
