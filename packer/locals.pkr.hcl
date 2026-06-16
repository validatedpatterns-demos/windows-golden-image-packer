# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

locals {
  edition_image_names = {
    "2022-Standard"    = "Windows Server 2022 SERVERSTANDARD"
    "2022-Datacenter"  = "Windows Server 2022 SERVERDATACENTER"
    "2025-Standard"    = "Windows Server 2025 SERVERSTANDARD"
    "2025-Datacenter"  = "Windows Server 2025 SERVERDATACENTER"
  }

  windows_image_name = lookup(
    local.edition_image_names,
    "${var.windows_version}-${var.windows_edition}",
    "Windows Server ${var.windows_version} SERVER${upper(var.windows_edition)}"
  )

  virtio_os_dir = var.windows_version == "2025" ? "2k25" : "2k22"

  windows_iso_path = var.windows_version == "2025" ? var.windows_iso_path_2025 : var.windows_iso_path_2022

  # WinPE VirtIO driver paths only when installing to a virtio/virtio-scsi disk (not UEFI+SATA).
  include_winpe_virtio_drivers = contains(["virtio", "virtio-scsi"], var.install_disk_interface)

  install_machine_type = var.efi_boot ? "q35" : "pc"

  # TPM 2.0 requires UEFI/q35; Packer plugin starts swtpm when vtpm is true.
  use_vtpm = var.efi_boot && var.vtpm

  output_image_name = "windows-server-${var.windows_version}-${lower(var.windows_edition)}.qcow2"

  vm_name = var.vm_name != "" ? var.vm_name : "packer-win${var.windows_version}-${lower(var.windows_edition)}"

  ssh_keys_combined = compact(concat(
    var.ssh_public_keys,
    var.ssh_public_keys_file != "" ? split("\n", trimspace(replace(file(var.ssh_public_keys_file), "\r", ""))) : []
  ))

  virtio_driver_paths_xml = templatefile("${path.root}/../http/virtio-driver-paths.xml.tpl", {
    virtio_os_dir = local.virtio_os_dir
  })

  enable_winrm_cmd     = file("${path.root}/../http/enable-winrm.cmd")
  enable_winrm_ps1     = file("${path.root}/../http/enable-winrm.ps1")
  enable_winrm_locator = file("${path.root}/../http/enable-winrm-locator.cmd")

  specialize_winrm_xml = local.include_winpe_virtio_drivers ? "" : file("${path.root}/../http/specialize-winrm.xml.tpl")

  specialize_post_install_xml = local.include_winpe_virtio_drivers ? file("${path.root}/../http/specialize-post-install.xml.tpl") : ""

  firstlogon_commands_xml = join("\n", compact([
    file("${path.root}/../http/firstlogon-winrm.xml.tpl"),
    var.install_auto_shutdown ? file("${path.root}/../http/firstlogon-install-shutdown.xml.tpl") : "",
  ]))

  # IDE install: stage VirtIO block/SCSI/NIC drivers during specialize (PROVISION CD paths).
  specialize_virtio_xml = local.include_winpe_virtio_drivers ? "" : templatefile(
    "${path.root}/../http/specialize-virtio-drivers.xml.tpl",
    { virtio_os_dir = local.virtio_os_dir }
  )

  # Packer has no xmlencode(); escape characters that break autounattend.xml.
  admin_password_xml = replace(
    replace(
      replace(
        replace(replace(var.admin_password, "&", "&amp;"), "<", "&lt;"),
        ">",
        "&gt;"
      ),
      "\"",
      "&quot;"
    ),
    "'",
    "&apos;"
  )

  windows_product_key = var.windows_version == "2025" ? var.product_key_2025 : var.product_key_2022

  windows_product_key_xml = local.windows_product_key != "" ? replace(
    replace(
      replace(
        replace(replace(local.windows_product_key, "&", "&amp;"), "<", "&lt;"),
        ">",
        "&gt;"
      ),
      "\"",
      "&quot;"
    ),
    "'",
    "&apos;"
  ) : ""

  product_key_xml = local.windows_product_key_xml != "" ? templatefile("${path.root}/../http/product-key.xml.tpl", {
    product_key = local.windows_product_key_xml
  }) : ""

  product_key_oobe_xml = local.windows_product_key_xml != "" ? templatefile("${path.root}/../http/product-key-oobe.xml.tpl", {
    product_key = local.windows_product_key_xml
  }) : ""

  # Split sysprep answer files: generalize-only for sysprep.exe, oobe-only for Panther on first deploy boot.
  sysprep_generalize_unattend = templatefile("${path.root}/../http/sysprep-generalize.xml.tpl", {})
  sysprep_oobe_unattend = templatefile("${path.root}/../http/sysprep-oobe.xml.tpl", {
    admin_password      = local.admin_password_xml
    product_key_oobe_xml = local.product_key_oobe_xml
  })

  autounattend_template_vars = {
    windows_image_name           = local.windows_image_name
    admin_password               = local.admin_password_xml
    computer_name                = "WIN-PACKER"
    virtio_driver_paths_xml      = local.virtio_driver_paths_xml
    product_key_xml              = local.product_key_xml
    product_key                  = local.windows_product_key_xml
    include_winpe_virtio_drivers = local.include_winpe_virtio_drivers
    specialize_winrm_xml          = local.specialize_winrm_xml
    specialize_post_install_xml   = local.specialize_post_install_xml
    firstlogon_commands_xml       = local.firstlogon_commands_xml
    specialize_virtio_xml         = local.specialize_virtio_xml
  }

  autounattend = templatefile(
    var.efi_boot ? "${path.root}/../http/autounattend.xml.tpl" : "${path.root}/../http/autounattend-bios.xml.tpl",
    local.autounattend_template_vars
  )

  # SeaBIOS: autounattend + enable-winrm.cmd on floppy. UEFI: both on PROVISION CD.
  winrm_floppy_files = {
    "autounattend.xml"            = local.autounattend
    "enable-winrm.ps1"            = local.enable_winrm_ps1
    "enable-winrm.cmd"            = local.enable_winrm_cmd
    "enable-winrm-locator.cmd"    = local.enable_winrm_locator
    "clear-autologon.ps1"         = file("${path.root}/../scripts/clear-autologon.ps1")
  }

  autounattend_floppy = var.efi_boot ? {} : local.winrm_floppy_files

  autounattend_cd = var.efi_boot ? local.winrm_floppy_files : {}

  # PROVISION CD (pass 2+): WinRM locators for OVMF first boot + VirtIO driver tree at CD root.
  provision_winrm_cd_content = {
    "enable-winrm.ps1"         = local.enable_winrm_ps1
    "enable-winrm.cmd"         = local.enable_winrm_cmd
    "enable-winrm-locator.cmd" = local.enable_winrm_locator
  }

  # PROVISION CD: driver *contents* at CD root (viostor\2k22\amd64). WinRM also uploads drivers/ (~27MB).
  provision_cd_files = [
    "${path.root}/../drivers/*",
  ]

  # OVMF/q35 sysprep pass: boot from virtio-blk to match OpenShift disk.bus=virtio.
  # OVMF pflash must stay qcow2 (not raw), otherwise UEFI can loop at high CPU.
  gpt_ovmf_machine = "type=q35,accel=${var.qemu_accelerator},smm=on"

  gpt_ovmf_qemuargs = concat(
    [
      ["-machine", local.gpt_ovmf_machine],
      ["-boot", "menu=on,strict=on"],
      ["-display", "none"],
      ["-drive", "if=none,file={{ .OutputDir }}/{{ .Name }},id=disk0,cache=writeback,discard=ignore,format=qcow2"],
      ["-drive", "file=${var.ovmf_code_path},if=pflash,unit=0,format=qcow2,readonly=on"],
      ["-drive", "file={{ .OutputDir }}/efivars.fd,if=pflash,unit=1,format=qcow2"],
      ["-device", "virtio-blk-pci,drive=disk0,bootindex=1,write-cache=on"],
      ["-device", "${var.install_net_device},netdev=user.0,bootindex=5"],
    ],
    var.provision_sysprep_vtpm ? [["-device", "tpm-tis,tpmdev=tpm0"]] : []
  )

  provision_env_vars = [
    "WINRM_PASSWORD=${var.admin_password}",
    "SSH_PUBLIC_KEYS=${jsonencode(local.ssh_keys_combined)}",
    "WINDOWS_ISO_PATH=${local.windows_iso_path}",
    "WINDOWS_VERSION=${var.windows_version}",
  ]
}
