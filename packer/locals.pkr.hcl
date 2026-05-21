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

  output_image_name = "windows-server-${var.windows_version}-${lower(var.windows_edition)}.qcow2"

  vm_name = var.vm_name != "" ? var.vm_name : "packer-win${var.windows_version}-${lower(var.windows_edition)}"

  ssh_keys_combined = compact(concat(
    var.ssh_public_keys,
    var.ssh_public_keys_file != "" ? split("\n", trimspace(replace(file(var.ssh_public_keys_file), "\r", ""))) : []
  ))

  autounattend = templatefile("${path.root}/../http/autounattend.xml.tpl", {
    windows_image_name = local.windows_image_name
    admin_password     = var.admin_password
    computer_name      = "WIN-PACKER"
  })
}
