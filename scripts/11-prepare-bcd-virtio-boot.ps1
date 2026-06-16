# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Prep disk BCD was built on IDE during MBR provision. OVMF sysprep boots virtio-blk;
# point boot entries at the boot device before the pre-sysprep restart (no bcdboot here).
$ErrorActionPreference = 'Stop'

Import-Module Storage -ErrorAction SilentlyContinue

function Get-EspBcdDeviceSpec {
    $esp = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object {
            $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $_.Type -eq 'System'
        } |
        Select-Object -First 1
    if (-not $esp) {
        throw 'EFI system partition not found for BCD virtio boot prep'
    }
    if ($esp.Guid) {
        return "partition={$($esp.Guid)}"
    }
    if ($esp.DriveLetter) {
        return "partition=$($esp.DriveLetter):"
    }
    throw 'ESP has no GPT GUID or drive letter for BCD prep'
}

function Invoke-BcdeditSilently {
    param([string[]]$BcdeditArgs)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & bcdedit.exe @BcdeditArgs 2>&1 | Out-Host
    }
    finally {
        $ErrorActionPreference = $prev
    }
    $global:LASTEXITCODE = 0
}

$espSpec = Get-EspBcdDeviceSpec
Write-Host "Preparing BCD for virtio-blk OVMF sysprep boot (bootmgr=$espSpec, default/current=device boot)"
& bcdedit.exe /set '{bootmgr}' device $espSpec 2>&1 | Out-Host
foreach ($id in @('{default}', '{current}')) {
    & bcdedit.exe /set $id device boot 2>&1 | Out-Host
    & bcdedit.exe /set $id osdevice boot 2>&1 | Out-Host
    Invoke-BcdeditSilently -BcdeditArgs @('/deletevalue', $id, '21000026')
}
$global:LASTEXITCODE = 0
Write-Host '11-prepare-bcd-virtio-boot.ps1 complete'
