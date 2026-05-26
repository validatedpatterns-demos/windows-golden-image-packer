# Phase 1: unattended Windows Setup (IDE disk + e1000 — no VirtIO required in WinPE).
# Phase 2: WinRM provisioners install VirtIO, QEMU-GA, OpenSSH, then sysprep.

source "qemu" "windows" {
  vm_name          = local.vm_name
  output_directory = var.output_directory
  accelerator      = var.qemu_accelerator
  cpus             = var.vm_cpus
  memory           = var.vm_memory
  headless         = var.headless
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_interface   = var.install_disk_interface
  disk_cache       = "writeback"
  net_device       = var.install_net_device
  machine_type     = local.install_machine_type
  cpu_model        = "host"

  efi_boot          = var.efi_boot
  efi_firmware_code = var.efi_boot ? var.ovmf_code_path : ""
  efi_firmware_vars = var.efi_boot ? var.ovmf_vars_path : ""

  iso_url      = local.windows_iso_path
  iso_checksum = "none"

  floppy_content = local.autounattend_floppy
  cd_label       = "PROVISION"
  cd_content     = local.autounattend_cd
  cd_files       = local.provision_cd_files

  boot_wait = "15s"
  boot_command = [
    "<spacebar>",
    "<wait3>",
    "<spacebar>",
    "<wait3>",
    "<enter>",
  ]

  qemuargs = [
    ["-boot", "order=cdn"],
    ["-device", "qemu-xhci"],
  ]

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = false
  winrm_port     = 5985

  shutdown_command = "powershell -ExecutionPolicy Bypass -File C:/Windows/Temp/sysprep.ps1"
  shutdown_timeout = "30m"
}

build {
  name    = "windows-golden-image"
  sources = ["source.qemu.windows"]

  provisioner "file" {
    destination = "C:/Windows/Temp/"
    source      = "${path.root}/../scripts/"
  }

  provisioner "file" {
    destination = "C:/Windows/Temp/"
    source      = "${path.root}/../drivers"
  }

  provisioner "powershell" {
    environment_vars = [
      "WINRM_PASSWORD=${var.admin_password}",
      "SSH_PUBLIC_KEYS=${jsonencode(local.ssh_keys_combined)}",
    ]
    scripts = [
      "${path.root}/../scripts/01-install-virtio-drivers.ps1",
      "${path.root}/../scripts/02-install-qemu-guest-agent.ps1",
      "${path.root}/../scripts/03-configure-openssh.ps1",
      "${path.root}/../scripts/04-set-administrator-password.ps1",
      "${path.root}/../scripts/05-inject-ssh-keys.ps1",
      "${path.root}/../scripts/06-shrink-disk.ps1",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "bash \"${path.root}/../scripts/finalize-packer-output.sh\" \"${abspath(var.output_directory)}\" \"${local.vm_name}\" \"${local.output_image_name}\"",
      "if [ \"$${IMAGE_OPTIMIZE:-1}\" = \"1\" ]; then bash \"${path.root}/../scripts/optimize-qcow2.sh\" \"${abspath(var.output_directory)}/${local.output_image_name}\"; fi",
    ]
  }
}
