# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# virtio-win MSI (Phase 1) installs drivers and sets Start=0 but not CriticalDeviceDatabase.
# Server 2025 may leave service keys without viostor.sys in System32\drivers — stage from
# WinRM-uploaded drivers/ when missing, then register CDD and sync control sets.
$ErrorActionPreference = 'Stop'

$installScript = Join-Path $PSScriptRoot '01-install-virtio-drivers.ps1'
if (-not (Test-Path -LiteralPath $installScript)) {
    throw "Missing $installScript"
}
. $installScript -SkipMain

$virtioOsDir = Get-TargetVirtioOsDir
$mediaRoot = Find-VirtioMediaRoot -OsDir $virtioOsDir
$virtioOsDir = Get-VirtioOsDir -MediaRoot $mediaRoot -OsDir $virtioOsDir

$viostorSys = Join-Path $env:SystemRoot 'System32\drivers\viostor.sys'
$vioscsiSys = Join-Path $env:SystemRoot 'System32\drivers\vioscsi.sys'
if (-not (Test-Path -LiteralPath $viostorSys) -or -not (Test-Path -LiteralPath $vioscsiSys)) {
    Write-Host "Boot driver binaries missing; staging from $mediaRoot (OS dir: $virtioOsDir)"
    $viostorInf = Join-Path $mediaRoot "viostor\$virtioOsDir\amd64\viostor.inf"
    $vioscsiInf = Join-Path $mediaRoot "vioscsi\$virtioOsDir\amd64\vioscsi.inf"
    Ensure-BootDriverStaged -ServiceName 'viostor' -SysFileName 'viostor.sys' -InfPath $viostorInf
    Ensure-BootDriverStaged -ServiceName 'vioscsi' -SysFileName 'vioscsi.sys' -InfPath $vioscsiInf
}

foreach ($svc in @('viostor', 'vioscsi')) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    if (-not (Test-Path -LiteralPath $key)) {
        throw "Missing $svc service (expected virtio-win MSI from Phase 1 install)"
    }
    $start = (Get-ItemProperty -Path $key -Name 'Start' -ErrorAction SilentlyContinue).Start
    if ($start -ne 0) {
        throw "Driver $svc is not boot-start (Start=$start, expected 0)"
    }
}

Set-VirtioCriticalDeviceDatabase -ServiceName 'viostor' -RelativePaths @(
    'pci#ven_1af4&dev_1001',
    'pci#ven_1af4&dev_1001&subsys_00021af4&rev_00',
    'pci#ven_1af4&dev_1042&subsys_11001af4&rev_01'
)
Set-VirtioCriticalDeviceDatabase -ServiceName 'vioscsi' -RelativePaths @(
    'pci#ven_1af4&dev_1004',
    'pci#ven_1af4&dev_1004&subsys_00081af4&rev_00',
    'pci#ven_1af4&dev_1048&subsys_11001af4&rev_01'
)

Confirm-BootDrivers -ServiceNames @('viostor', 'vioscsi')
Sync-VirtioBootRegistryToAllControlSets
Remove-VirtioBootStartOverrideAllControlSets
Set-VirtioBootControlSetSelect

Write-Host 'ensure-virtio-boot-binding.ps1 complete'
$global:LASTEXITCODE = 0
exit 0
