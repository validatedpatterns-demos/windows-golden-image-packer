source "qemu" "windows" {
  vm_name          = local.vm_name
  output_directory = var.output_directory
  accelerator      = var.qemu_accelerator
  cpus             = var.vm_cpus
  memory           = var.vm_memory
  headless         = var.headless
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  machine_type     = "q35"
  cpu_model        = "host"
  efi_boot              = true
  efi_firmware_code     = var.ovmf_code_path
  efi_firmware_vars     = var.ovmf_vars_path

  iso_url      = var.windows_iso_path
  iso_checksum = "none"

  floppy_content = {
    "autounattend.xml" = local.autounattend
  }

  # Second CD-ROM: virtio-win driver and QEMU guest agent media
  qemuargs = [
    ["-drive", "file=${var.virtio_win_iso_path},media=cdrom,index=3,if=none,readonly=on"],
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
    ]
  }

  post-processor "shell-local" {
    inline = [
      "OUTPUT_DIR='${var.output_directory}'",
      "VM_NAME='${local.vm_name}'",
      "TARGET='${local.output_image_name}'",
      "FOUND=$(find \"$OUTPUT_DIR\" -maxdepth 1 -name \"*.qcow2\" -type f | head -1)",
      "if [ -z \"$FOUND\" ]; then echo \"No qcow2 found in $OUTPUT_DIR\" >&2; exit 1; fi",
      "mv -f \"$FOUND\" \"$OUTPUT_DIR/$TARGET\"",
      "echo \"Golden image: $OUTPUT_DIR/$TARGET\"",
    ]
  }
}
