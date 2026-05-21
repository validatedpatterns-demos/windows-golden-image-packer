variable "windows_version" {
  type        = string
  description = "Windows Server version to build: 2022 or 2025."
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

variable "windows_iso_path" {
  type        = string
  description = "Path to the Windows Server installation ISO."
}

variable "virtio_win_iso_path" {
  type        = string
  description = "Path to the virtio-win ISO (Fedora Project virtio-win)."
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
  description = "Root disk size, e.g. 80G."
  default     = "80G"
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
