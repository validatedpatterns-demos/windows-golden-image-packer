# Pass 1 only: unattended Windows install, then shut down (no VirtIO provisioners, no sysprep).
# Use with: make build-install
# Then:     make build-provision-only BASE_IMAGE=output/windows-server-2022-standard-install.qcow2

source "qemu" "install" {
  vm_name          = "${local.vm_name}-install"
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

  shutdown_command = "shutdown /s /t 0 /f"
  shutdown_timeout = "30m"
}

build {
  name    = "windows-install-only"
  sources = ["source.qemu.install"]

  post-processor "shell-local" {
    inline = [
      "OUTPUT_DIR='${var.output_directory}'",
      "TARGET='${replace(local.output_image_name, ".qcow2", "-install.qcow2")}'",
      "FOUND=$(find \"$OUTPUT_DIR\" -maxdepth 1 -name \"*.qcow2\" -type f | head -1)",
      "if [ -z \"$FOUND\" ]; then echo \"No qcow2 found in $OUTPUT_DIR\" >&2; exit 1; fi",
      "mv -f \"$FOUND\" \"$OUTPUT_DIR/$TARGET\"",
      "echo \"Install disk (pass 1): $OUTPUT_DIR/$TARGET\"",
      "echo \"Next: make build-provision-only BASE_IMAGE=$OUTPUT_DIR/$TARGET\"",
    ]
  }
}
