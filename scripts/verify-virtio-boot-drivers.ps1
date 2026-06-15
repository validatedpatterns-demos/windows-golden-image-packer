# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Verify viostor/vioscsi are boot-start for OpenShift disk.bus=virtio (virtio-blk).
# Use -AllControlSets after restore-virtio-boot-after-sysprep.ps1 — sysprep /generalize can
# leave stale ControlSet00N hives without VirtIO keys (INACCESSIBLE_BOOT_DEVICE on first boot).
param(
    [switch]$AllControlSets
)

$ErrorActionPreference = 'Stop'

$ViostorCddPaths = @(
    'pci#ven_1af4&dev_1001',
    'pci#ven_1af4&dev_1001&subsys_00021af4&rev_00',
    'pci#ven_1af4&dev_1042&subsys_11001af4&rev_01'
)

function Test-BootDriver {
    param(
        [string]$RegistryRoot,
        [string]$ServiceName,
        [string]$SysFileName,
        [switch]$RequireDriverFile
    )

    $key = "$RegistryRoot\Services\$ServiceName"
    if (-not (Test-Path $key)) {
        throw "Missing boot driver service: $ServiceName under $RegistryRoot (re-run MBR provision with 01-install-virtio-drivers.ps1)"
    }
    $start = (Get-ItemProperty -Path $key -Name 'Start' -ErrorAction SilentlyContinue).Start
    if ($start -ne 0) {
        throw "Driver $ServiceName under $RegistryRoot is not boot-start (Start=$start, expected 0)"
    }

    if ($RequireDriverFile) {
        $sys = Join-Path $env:SystemRoot "System32\drivers\$SysFileName"
        if (-not (Test-Path -LiteralPath $sys)) {
            throw "Missing $sys"
        }
    }
    Write-Host "Boot driver OK: $ServiceName under $RegistryRoot (Start=0)"
}

function Test-ViostorCriticalDeviceDatabase {
    param(
        [string]$RegistryRoot
    )

    foreach ($rel in $ViostorCddPaths) {
        $key = "$RegistryRoot\Control\CriticalDeviceDatabase\$rel"
        if (-not (Test-Path $key)) {
            continue
        }
        $svc = (Get-ItemProperty -Path $key -Name 'Service' -ErrorAction SilentlyContinue).Service
        if ($svc -eq 'viostor') {
            Write-Host "CriticalDeviceDatabase OK: $rel -> viostor under $RegistryRoot"
            return
        }
    }
    throw "Missing viostor CriticalDeviceDatabase entry under $RegistryRoot (expected one of: $($ViostorCddPaths -join ', '))"
}

function Test-VirtioBootRegistryRoot {
    param(
        [string]$Label,
        [string]$RegistryRoot,
        [switch]$RequireDriverFiles
    )

    Test-BootDriver -RegistryRoot $RegistryRoot -ServiceName 'viostor' -SysFileName 'viostor.sys' -RequireDriverFile:$RequireDriverFiles
    Test-BootDriver -RegistryRoot $RegistryRoot -ServiceName 'vioscsi' -SysFileName 'vioscsi.sys' -RequireDriverFile:$RequireDriverFiles
    Test-ViostorCriticalDeviceDatabase -RegistryRoot $RegistryRoot
    Write-Host "VirtIO boot registry OK: $Label"
}

if ($AllControlSets) {
    $roots = @(
        @{ Label = 'CurrentControlSet'; Root = 'HKLM:\SYSTEM\CurrentControlSet' }
    )
    Get-ChildItem -Path 'HKLM:\SYSTEM' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^ControlSet\d+$' } |
        ForEach-Object {
            $roots += @{ Label = $_.PSChildName; Root = $_.PSPath }
        }

    $seen = @{}
    foreach ($entry in $roots) {
        if ($seen.ContainsKey($entry.Label)) { continue }
        $seen[$entry.Label] = $true
        Test-VirtioBootRegistryRoot -Label $entry.Label -RegistryRoot $entry.Root -RequireDriverFiles:($entry.Label -eq 'CurrentControlSet')
    }
}
else {
    Test-VirtioBootRegistryRoot -Label 'CurrentControlSet' -RegistryRoot 'HKLM:\SYSTEM\CurrentControlSet' -RequireDriverFiles
}

Write-Host 'verify-virtio-boot-drivers.ps1 complete'
