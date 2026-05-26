variable "windows_version" {
  type        = string
  description = "Windows Server version for this Packer run (one image per invocation: 2022 or 2025). make build sets this via -var for each pass; manual packer build must pass -var windows_version=... or rely on the default."
  default     = "2022"

  validation {
    condition     = contains(["2022", "2025"], var.windows_version)
    error_message = "The windows_version variable must be 2022 or 2025."
  }
}

variable "windows_edition" {
  type        = string
  description = "Windows Server edition: Standard (default) or Datacenter."
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Datacenter"], var.windows_edition)
    error_message = "The windows_edition variable must be Standard or Datacenter."
  }
}

variable "efi_boot" {
  type        = bool
  description = "Use UEFI/OVMF for install. On Fedora with QEMU 10, leave false. Packer enables UEFI if efi_firmware_* paths are set in build.pkr.hcl even when this is false."
  default     = false
}

variable "windows_iso_path_2022" {
  type        = string
  description = "Path to the Windows Server 2022 installation ISO (used when windows_version = 2022)."
  default     = ""
}

variable "windows_iso_path_2025" {
  type        = string
  description = "Path to the Windows Server 2025 installation ISO (used when windows_version = 2025)."
  default     = ""
}

variable "virtio_win_iso_path" {
  type        = string
  description = "Path to the virtio-win ISO (Fedora Project virtio-win)."
}

variable "product_key_2022" {
  type        = string
  description = "Optional product key for Windows Server 2022 installs (MAK, KMS, or GVLK). Leave empty to skip."
  default     = ""
  sensitive   = true
}

variable "product_key_2025" {
  type        = string
  description = "Optional product key for Windows Server 2025 installs (MAK, KMS, or GVLK). Leave empty to skip."
  default     = ""
  sensitive   = true
}

variable "admin_password" {
  type        = string
  description = "Password for the built-in Administrator account."
  sensitive   = true
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "OpenSSH public keys to authorize for Administrator (one key per element)."
  default     = []
}

variable "ssh_public_keys_file" {
  type        = string
  description = "Optional file with one SSH public key per line (merged with ssh_public_keys)."
  default     = ""
}

variable "output_directory" {
  type        = string
  description = "Directory for the output qcow2 image."
  default     = "../output"
}

variable "vm_name" {
  type        = string
  description = "QEMU VM name used during the build."
  default     = ""
}

variable "vm_cpus" {
  type    = number
  default = 4
}

variable "vm_memory" {
  type    = number
  default = 8192
}

variable "disk_size" {
  type        = string
  description = "Root disk virtual size (QEMU suffix, e.g. 60G). Must be <= your OpenShift DataVolume/PVC size; autounattend extends C: to fill this disk."
  default     = "60G"
}

variable "install_disk_interface" {
  type        = string
  description = "Disk bus during Windows Setup (phase 1). Use ide so WinPE can partition without VirtIO drivers; virtio is installed in phase 2 (WinRM)."
  default     = "ide"

  validation {
    condition     = contains(["ide", "sata", "virtio", "virtio-scsi"], var.install_disk_interface)
    error_message = "The install_disk_interface variable must be ide, sata, virtio, or virtio-scsi."
  }
}

variable "base_image_path" {
  type        = string
  description = "Pass 2 only (build-provision-only): qcow2 from make build-install."
  default     = ""
}

variable "install_net_device" {
  type        = string
  description = "NIC model during install and provisioning. e1000 works without VirtIO network drivers in WinPE."
  default     = "e1000"

  validation {
    condition     = contains(["e1000", "rtl8139", "virtio-net", "virtio"], var.install_net_device)
    error_message = "The install_net_device variable must be e1000, rtl8139, virtio-net, or virtio."
  }
}

variable "headless" {
  type    = bool
  default = true
}

variable "qemu_accelerator" {
  type        = string
  description = "QEMU accelerator: kvm or tcg."
  default     = "kvm"
}

variable "ovmf_code_path" {
  type        = string
  description = "Path to OVMF UEFI firmware CODE file (required for OpenShift Virtualization / KubeVirt)."
  default     = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
}

variable "ovmf_vars_path" {
  type        = string
  description = "Path to OVMF UEFI firmware VARS template."
  default     = "/usr/share/edk2/ovmf/OVMF_VARS.fd"
}

variable "winrm_username" {
  type    = string
  default = "Administrator"
}

variable "winrm_timeout" {
  type    = string
  default = "90m"
}
