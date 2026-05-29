# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Fail fast if the provision pass booted with SeaBIOS after mbr2gpt (GPT disks need OVMF).
$ErrorActionPreference = 'Stop'

function Get-FirmwareType {
    if (Get-Command Get-ComputerInfo -ErrorAction SilentlyContinue) {
        $info = Get-ComputerInfo -Property BiosFirmwareType -ErrorAction SilentlyContinue
        if ($info -and $info.BiosFirmwareType) {
            return [string]$info.BiosFirmwareType
        }
    }

    $envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Pnp\PnpSetup'
    if (Test-Path $envKey) {
        $val = (Get-ItemProperty -Path $envKey -Name 'FirmwareBootDevice' -ErrorAction SilentlyContinue).FirmwareBootDevice
        if ($val) {
            return [string]$val
        }
    }

    return 'Unknown'
}

$fw = Get-FirmwareType
Write-Host "Detected firmware type: $fw"

if ($fw -match 'BIOS|Legacy|Bios') {
    throw @(
        'Provision VM booted with SeaBIOS/legacy firmware on a GPT/UEFI disk.'
        'Packer must run the provision pass with efi_boot=true (OVMF on q35).'
        'Check build.pkrvars.hcl and confirm the Packer log shows OVMF_CODE_4M.qcow2, not a SeaBIOS banner.'
    ) -join ' '
}

$esp = Get-Partition -ErrorAction SilentlyContinue |
    Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
    Select-Object -First 1
if (-not $esp) {
    throw 'EFI system partition not found; run 08-convert-mbr-to-uefi.ps1 and 07-repair-uefi-boot.ps1 first.'
}

Write-Host 'UEFI boot environment verified (firmware + ESP present).'
