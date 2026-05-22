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

  # Phase 1 (WinPE): IDE needs no VirtIO storage drivers on the PROVISION CD.
  include_winpe_virtio_drivers = contains(["virtio", "virtio-scsi"], var.install_disk_interface)

  install_machine_type = var.efi_boot ? "q35" : "pc"

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

  specialize_winrm_xml   = file("${path.root}/../http/specialize-winrm.xml.tpl")
  firstlogon_commands_xml = file("${path.root}/../http/firstlogon-winrm.xml.tpl")

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

  product_key_xml = local.windows_product_key != "" ? templatefile("${path.root}/../http/product-key.xml.tpl", {
    product_key = replace(
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
    )
  }) : ""

  autounattend_template_vars = {
    windows_image_name           = local.windows_image_name
    admin_password               = local.admin_password_xml
    computer_name                = "WIN-PACKER"
    virtio_driver_paths_xml      = local.virtio_driver_paths_xml
    product_key_xml              = local.product_key_xml
    include_winpe_virtio_drivers = local.include_winpe_virtio_drivers
    specialize_winrm_xml          = local.specialize_winrm_xml
    firstlogon_commands_xml       = local.firstlogon_commands_xml
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
    "install-openssh-server.ps1"   = file("${path.root}/../scripts/install-openssh-server.ps1")
    "OpenSSH-Server-Common.ps1"    = file("${path.root}/../scripts/OpenSSH-Server-Common.ps1")
    "install-openssh-locator.cmd" = file("${path.root}/../http/install-openssh-locator.cmd")
  }

  autounattend_floppy = var.efi_boot ? {} : local.winrm_floppy_files

  autounattend_cd = var.efi_boot ? local.winrm_floppy_files : {}

  # PROVISION CD: driver *contents* at CD root (viostor\2k22\amd64). WinRM also uploads drivers/ (~27MB).
  provision_cd_files = [
    "${path.root}/../drivers/*",
  ]
}
