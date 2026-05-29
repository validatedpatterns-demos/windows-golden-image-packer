# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

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
  description = "UEFI/OVMF golden images for OpenShift Virtualization. true: virt-install install + mbr2gpt during provision + OVMF sysprep (recommended). false: single-pass SeaBIOS Packer build (dev hosts only)."
  default     = true
}

variable "install_firmware" {
  type        = string
  description = "Firmware for virt-install Windows Setup only: seabios (default; boots Microsoft UDF DVD) or uefi (direct OVMF DVD boot; often times out on Fedora QEMU 10). Final golden image is still UEFI when efi_boot=true."
  default     = "seabios"

  validation {
    condition     = contains(["seabios", "uefi"], var.install_firmware)
    error_message = "The install_firmware variable must be seabios or uefi."
  }
}

variable "install_auto_shutdown" {
  type        = bool
  description = "Shut down the guest after unattended install (virt-install pass 1). Required so virt-install --wait completes; not used for single-pass Packer install (WinRM must stay up)."
  default     = false
}

variable "vtpm" {
  type        = bool
  description = "Emulated TPM 2.0 (swtpm) on UEFI/q35 VMs during build and install. Matches OpenShift Virtualization vTPM expectations for Windows Server 2022+."
  default     = true
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
  description = "Optional product key for Windows Server 2022 installs (MAK, KMS, or GVLK). Leave empty to skip. Not marked sensitive so scripts/render-autounattend.sh can emit valid XML (values may appear in Packer logs)."
  default     = ""
}

variable "product_key_2025" {
  type        = string
  description = "Optional product key for Windows Server 2025 installs (MAK, KMS, or GVLK). Leave empty to skip. Not marked sensitive so scripts/render-autounattend.sh can emit valid XML (values may appear in Packer logs)."
  default     = ""
}

variable "admin_password" {
  type        = string
  description = "Password for the built-in Administrator account. Not marked sensitive so scripts/render-autounattend.sh can emit valid XML (may appear in Packer logs)."
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
  description = "Root disk virtual size (QEMU suffix, e.g. 40G). Minimum DataVolume/PVC on import; C: is extended on first deploy boot if the PVC is larger."
  default     = "40G"
}

variable "install_disk_interface" {
  type        = string
  description = "Disk bus during Windows Setup (virt-install / Packer install). Use sata for virt-install UEFI path or ide for Packer SeaBIOS install. Not used for the Packer provision pass (see provision_disk_interface)."
  default     = "ide"

  validation {
    condition     = contains(["ide", "sata", "virtio", "virtio-scsi"], var.install_disk_interface)
    error_message = "The install_disk_interface variable must be ide, sata, virtio, or virtio-scsi."
  }
}

variable "provision_disk_interface" {
  type        = string
  description = "Disk bus for the Packer QEMU provision pass (build-provision-only). Must be ide: the Packer QEMU plugin uses -drive if=sata which QEMU q35 rejects. virtio-scsi is installed during provision for OpenShift runtime."
  default     = "ide"

  validation {
    condition     = contains(["ide", "virtio-scsi"], var.provision_disk_interface)
    error_message = "The provision_disk_interface variable must be ide or virtio-scsi."
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
  type        = bool
  description = "Packer QEMU display. false shows the install console (VNC); true is headless CI."
  default     = false
}

variable "qemu_accelerator" {
  type        = string
  description = "QEMU accelerator: kvm or tcg."
  default     = "kvm"
}

variable "ovmf_code_path" {
  type        = string
  description = "Path to OVMF UEFI firmware CODE file (required for OpenShift Virtualization / KubeVirt)."
  default     = "/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2"
}

variable "ovmf_vars_path" {
  type        = string
  description = "Path to OVMF UEFI firmware VARS template."
  default     = "/usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2"
}

variable "winrm_username" {
  type    = string
  default = "Administrator"
}

variable "winrm_timeout" {
  type    = string
  default = "90m"
}
