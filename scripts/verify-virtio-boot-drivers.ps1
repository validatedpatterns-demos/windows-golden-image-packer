# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# OVMF sysprep pass: prep disk already has VirtIO from the MBR provision pass.
# Re-running 01-install-virtio-drivers.ps1 (phantom devices, pnputil) without a reboot
# often leaves pending driver state and sysprep generalize can hang for hours.
$ErrorActionPreference = 'Stop'

function Test-BootDriver {
    param(
        [string]$ServiceName,
        [string]$SysFileName
    )

    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path $key)) {
        throw "Missing boot driver service: $ServiceName (re-run MBR provision pass with 01-install-virtio-drivers.ps1)"
    }
    $start = (Get-ItemProperty -Path $key -Name 'Start' -ErrorAction SilentlyContinue).Start
    if ($start -ne 0) {
        throw "Driver $ServiceName is not boot-start (Start=$start, expected 0)"
    }

    $sys = Join-Path $env:SystemRoot "System32\drivers\$SysFileName"
    if (-not (Test-Path -LiteralPath $sys)) {
        throw "Missing $sys"
    }
    Write-Host "Boot driver OK: $ServiceName (Start=0, $SysFileName present)"
}

function Test-CriticalDeviceDatabase {
    param(
        [string]$RelativePath,
        [string]$ExpectedService
    )

    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\$RelativePath"
    if (-not (Test-Path $key)) {
        throw "Missing CriticalDeviceDatabase entry: $RelativePath (re-run MBR provision with enable-virtio-*-boot-load.ps1)"
    }
    $svc = (Get-ItemProperty -Path $key -Name 'Service' -ErrorAction SilentlyContinue).Service
    if ($svc -ne $ExpectedService) {
        throw "CriticalDeviceDatabase $RelativePath Service=$svc (expected $ExpectedService)"
    }
    Write-Host "CriticalDeviceDatabase OK: $RelativePath -> $ExpectedService"
}

Test-BootDriver -ServiceName 'viostor' -SysFileName 'viostor.sys'
Test-BootDriver -ServiceName 'vioscsi' -SysFileName 'vioscsi.sys'
Test-CriticalDeviceDatabase -RelativePath 'pci#ven_1af4&dev_1001' -ExpectedService 'viostor'
Test-CriticalDeviceDatabase -RelativePath 'pci#ven_1af4&dev_1004' -ExpectedService 'vioscsi'

Write-Host 'verify-virtio-boot-drivers.ps1 complete'
