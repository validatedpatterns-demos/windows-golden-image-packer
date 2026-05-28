# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Refresh UEFI boot files on the ESP and confirm VirtIO storage drivers are boot-start.
# Run after virtio driver install and before sysprep so virtio + UEFI boots on KubeVirt/libvirt.
$ErrorActionPreference = 'Stop'

function Get-EfiPartition {
    $esp = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
        Select-Object -First 1
    if (-not $esp) {
        throw 'EFI system partition not found (expected UEFI/GPT layout).'
    }
    return $esp
}

function Get-EfiMountPath {
    param($Partition)

    $vol = Get-Volume -Partition $Partition -ErrorAction SilentlyContinue
    if ($vol -and $vol.DriveLetter) {
        return "$($vol.DriveLetter):\"
    }

    $access = (Mount-Partition -Partition $Partition -PassThru -ErrorAction Stop).AccessPaths |
        Where-Object { $_ -match '^[A-Z]:\\$' } |
        Select-Object -First 1
    if (-not $access) {
        throw 'Could not mount EFI system partition to a drive letter.'
    }
    return $access
}

try {
  $esp = Get-EfiPartition
}
catch {
  Write-Host 'No EFI system partition (SeaBIOS/MBR image); skipping UEFI boot repair.'
  exit 0
}

$efiRoot = Get-EfiMountPath -Partition $esp
$windowsRoot = $env:SystemRoot

Write-Host "Repairing UEFI boot store: bcdboot $windowsRoot /s $efiRoot /f UEFI"
& bcdboot.exe $windowsRoot /s $efiRoot /f UEFI | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "bcdboot failed with exit code $LASTEXITCODE"
}

foreach ($svc in @('viostor', 'vioscsi')) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    if (-not (Test-Path $key)) {
        Write-Warning "Boot driver service missing: $svc (run 01-install-virtio-drivers.ps1)"
        continue
    }
    $start = (Get-ItemProperty -Path $key -Name 'Start' -ErrorAction SilentlyContinue).Start
    if ($start -ne 0) {
        throw "Driver $svc is not boot-start (Start=$start, expected 0)."
    }
    Write-Host "Boot-start driver OK: $svc"
}

Write-Host 'UEFI boot repair complete.'
