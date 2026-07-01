# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Refresh UEFI boot files on the ESP and confirm VirtIO storage drivers are boot-start.
# Run after virtio driver install and before sysprep so virtio + UEFI boots on KubeVirt/libvirt.
param(
    [switch]$CleanBcdStore
)

$ErrorActionPreference = 'Stop'

Import-Module Storage -ErrorAction SilentlyContinue

function Get-EfiPartition {
    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        throw 'Get-Partition unavailable (Storage module not loaded).'
    }
    $esp = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
        Select-Object -First 1
    if (-not $esp) {
        throw 'EFI system partition not found (expected UEFI/GPT layout).'
    }
    return $esp
}

function Mount-EspWithDiskPart {
    param(
        [int]$DiskNumber,
        [int]$PartitionNumber
    )

    foreach ($letter in @('S', 'T', 'U', 'V', 'W', 'X')) {
        $script = @"
select disk $DiskNumber
select partition $PartitionNumber
assign letter=$letter
"@
        $null = $script | & diskpart.exe 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path "${letter}:\")) {
            return "${letter}:\"
        }
    }
    throw 'Could not assign a drive letter to the EFI system partition (diskpart).'
}

function Get-EfiMountPath {
    param($Partition)

    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        $vol = Get-Volume -Partition $Partition -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) {
            return "$($vol.DriveLetter):\"
        }
    }

    if (Get-Command Mount-Partition -ErrorAction SilentlyContinue) {
        $mounted = Mount-Partition -Partition $Partition -PassThru -ErrorAction SilentlyContinue
        $access = $mounted.AccessPaths |
            Where-Object { $_ -match '^[A-Z]:\\$' } |
            Select-Object -First 1
        if ($access) {
            return $access
        }
    }

    return Mount-EspWithDiskPart -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
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

Write-Host "Repairing UEFI boot store: bcdboot $windowsRoot /s $efiRoot /f UEFI$(if ($CleanBcdStore) { ' (fresh ESP BCD)' })"
if ($CleanBcdStore) {
    $bcdOnEsp = Join-Path $efiRoot 'EFI\Microsoft\Boot\BCD'
    if (Test-Path -LiteralPath $bcdOnEsp) {
        Write-Host "Removing stale ESP BCD before bcdboot: $bcdOnEsp"
        $removed = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                Remove-Item -LiteralPath $bcdOnEsp -Force -ErrorAction Stop
                $removed = $true
                break
            }
            catch {
                Write-Warning "ESP BCD locked (attempt $attempt/5): $($_.Exception.Message)"
                Start-Sleep -Seconds 2
            }
        }
        if (-not $removed) {
            throw "Could not remove locked ESP BCD at $bcdOnEsp"
        }
    }
}
$bcdbootArgs = @($windowsRoot, '/s', $efiRoot, '/f', 'UEFI')
& bcdboot.exe @bcdbootArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "bcdboot failed with exit code $LASTEXITCODE"
}

foreach ($svc in @('viostor', 'vioscsi')) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    if (-not (Test-Path $key)) {
        throw "Boot driver service missing: $svc (run 01-install-virtio-drivers.ps1 before sysprep)"
    }
    $start = (Get-ItemProperty -Path $key -Name 'Start' -ErrorAction SilentlyContinue).Start
    if ($start -ne 0) {
        throw "Driver $svc is not boot-start (Start=$start, expected 0)."
    }
    Write-Host "Boot-start driver OK: $svc"
}

Write-Host 'UEFI boot repair complete.'
