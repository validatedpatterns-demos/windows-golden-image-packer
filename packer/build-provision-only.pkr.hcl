# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Optional pass 2: boot an existing qcow2 and run provisioners + sysprep only.
#
# Two builds (pick with -only):
#   windows-golden-provision-mbr         — SeaBIOS/pc: VirtIO, mbr2gpt, prep (no sysprep)
#   windows-golden-provision-gpt-sysprep — OVMF/q35: sysprep after MBR prep (required for BCD)
#   windows-golden-provision-gpt         — OVMF/q35: full provision + sysprep on GPT salvage
#
# OVMF sources omit the PROVISION CD at boot (see from_install_gpt); a data CD causes OVMF
# to hang on a blank screen. Drivers/scripts upload over WinRM after connect.
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

  cd_label   = "PROVISION"
  cd_content = local.provision_winrm_cd_content
  cd_files   = local.provision_cd_files

  boot_wait = "30s"

  qemuargs = [
    # Append only (--device). A single -device entry overrides Packer's NIC/disk devices.
    ["--device", "qemu-xhci"],
  ]

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = false
  winrm_port     = 5985

  shutdown_command = "shutdown /s /t 0 /f"
  shutdown_timeout = "30m"
}

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
  # Sysprep pass: no vTPM (OpenShift adds it at deploy). See provision_sysprep_vtpm.
  vtpm              = var.provision_sysprep_vtpm

  # Do not attach a PROVISION CD on OVMF boot: fresh OVMF NVRAM boots CD-ROM before the
  # disk (Packer's -boot order= is BIOS-only). A non-bootable drivers ISO then hangs
  # with a blank VNC screen until WinRM times out. Scripts/drivers are uploaded via
  # file provisioners after WinRM connects; WinRM itself persists on the prep disk.
  boot_wait    = "45s"
  boot_command = []
  # Headless prints a vnc:// URL in the log; headless=false adds GTK and often leaves VNC black.
  headless  = true
  display   = "none"

  qemuargs = local.gpt_ovmf_qemuargs

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = false
  winrm_port     = 5985

  # sysprep.ps1 shuts down the guest locally; generalize breaks WinRM (401 on shutdown_command).
  # wait-packer-qemu-exit.sh (shell-local provisioner) waits for QEMU to exit; empty command
  # skips a second WinRM round-trip and avoids force-killing a running guest (dirty NTFS).
  shutdown_command = ""
  shutdown_timeout = "120m"
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
      "${path.root}/../scripts/10-ensure-edge-for-sysprep.ps1",
      "${path.root}/../scripts/06-shrink-disk.ps1",
      "${path.root}/../scripts/09-prepare-for-sysprep.ps1",
      "${path.root}/../scripts/schedule-winrm-at-boot.ps1",
      "${path.root}/../scripts/verify-virtio-boot-drivers-all.ps1",
    ]
  }
}

build {
  name    = "windows-golden-provision-gpt-sysprep"
  sources = ["source.qemu.from_install_gpt"]

  # Sysprep BCD generalize requires OVMF on a GPT disk (SeaBIOS + GPT fails with c0000452).
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
    scripts          = [
      "${path.root}/../scripts/verify-virtio-boot-drivers.ps1",
      "${path.root}/../scripts/11-prepare-bcd-virtio-boot.ps1",
      "${path.root}/../scripts/10-ensure-edge-for-sysprep.ps1",
      "${path.root}/../scripts/configure-oobe-locale.ps1",
      "${path.root}/../scripts/09-prepare-for-sysprep.ps1",
    ]
  }

  # Clear pending reboot from locale/DISM before sysprep (01-install-virtio is not re-run here).
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    environment_vars = concat(local.provision_env_vars, ["SYSPREP_PROVISIONER_RUN=1"])
    scripts          = ["${path.root}/../scripts/sysprep.ps1"]
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
      "INSPECT_VIRTIO_STRICT=1 bash \"${path.root}/../scripts/inspect-golden-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"",
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
      "${path.root}/../scripts/10-ensure-edge-for-sysprep.ps1",
      "${path.root}/../scripts/06-shrink-disk.ps1",
      "${path.root}/../scripts/09-prepare-for-sysprep.ps1",
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    environment_vars = concat(local.provision_env_vars, ["SYSPREP_PROVISIONER_RUN=1"])
    scripts          = ["${path.root}/../scripts/sysprep.ps1"]
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
      "INSPECT_VIRTIO_STRICT=1 bash \"${path.root}/../scripts/inspect-golden-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"",
      "if [ \"$${IMAGE_OPTIMIZE:-1}\" = \"1\" ]; then bash \"${path.root}/../scripts/optimize-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"; fi",
    ]
  }
}
