# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Free disk space and zero unused clusters before sysprep so the qcow2 can sparsify on the build host.
# Do not wipe all of C:\Windows\Temp — Packer uploads scripts there (sysprep.ps1, packer-ps-env-vars-*.ps1).
$ErrorActionPreference = 'Stop'

function Test-PreserveTempItem {
    param([System.IO.FileSystemInfo]$Item)

    $name = $Item.Name
    if ($name -eq 'sysprep.ps1') { return $true }
    if ($name -like 'sysprep-*.xml' -or $name -eq 'oobe-info-defaults.xml') { return $true }
    if ($name -eq 'drivers' -or $name -eq 'virtio-drivers') { return $true }
    if ($name -like 'packer-*') { return $true }
    if ($Item -is [System.IO.FileInfo] -and $name -like '*.ps1') { return $true }
    if ($name -eq 'configure-oobe-locale.log') { return $true }
    return $false
}

function Clear-TempPreservingPackerArtifacts {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-PreserveTempItem -Item $_) {
            Write-Host "Preserving: $($_.FullName)"
            return
        }
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OptionalStep {
    param(
        [string]$Label,
        [scriptblock]$Action
    )
    Write-Host "=== Disk shrink: $Label ==="
    try {
        & $Action
    }
    catch {
        Write-Warning "$Label skipped: $($_.Exception.Message)"
    }
}

Invoke-OptionalStep 'clearing temporary files (preserving Packer scripts)' {
    Clear-TempPreservingPackerArtifacts -Path 'C:\Windows\Temp'
    if ($env:TEMP -and ($env:TEMP -ne 'C:\Windows\Temp')) {
        Clear-TempPreservingPackerArtifacts -Path $env:TEMP
    }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

Invoke-OptionalStep 'clearing Windows Update download cache' {
    $service = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Stop-Service -Name 'wuauserv' -Force
    }
    $downloadRoot = 'C:\Windows\SoftwareDistribution\Download'
    if (Test-Path $downloadRoot) {
        Get-ChildItem -Path $downloadRoot -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($service) {
        Set-Service -Name 'wuauserv' -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    }
}

Invoke-OptionalStep 'component store cleanup (DISM)' {
    $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
    if (-not (Test-Path $dism)) {
        throw "Dism.exe not found at $dism"
    }
    $proc = Start-Process -FilePath $dism -ArgumentList @(
        '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/Quiet'
    ) -PassThru -Wait -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "Dism.exe exited with code $($proc.ExitCode)"
    }
}

Invoke-OptionalStep 'disabling hibernation' {
    & powercfg.exe /hibernate off
    $hiber = Join-Path $env:SystemDrive 'hiberfil.sys'
    if (Test-Path $hiber) {
        Remove-Item -Path $hiber -Force
    }
}

Write-Host '=== Disk shrink: zeroing free space on C: (cipher /w — may take 15-60+ minutes) ==='
$cipherDir = 'C:\Windows\Temp\golden-image-cipher-wipe'
New-Item -ItemType Directory -Path $cipherDir -Force | Out-Null
try {
    $proc = Start-Process -FilePath 'cipher.exe' -ArgumentList @("/w:$cipherDir") -PassThru -Wait -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "cipher.exe exited with code $($proc.ExitCode)"
    }
}
finally {
    Remove-Item -Path $cipherDir -Force -Recurse -ErrorAction SilentlyContinue
}

Write-Host '=== Disk shrink complete ==='
