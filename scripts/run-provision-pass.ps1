# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Run pass-2 provision scripts from C:\Windows\Temp (staged from PROVISION CD).
# Packer must invoke this with inline "& 'C:/Windows/Temp/run-provision-pass.ps1'" so scripts
# are not re-uploaded over WinRM (winrmcp bulk upload fails early on both 2022 and 2025).
$ErrorActionPreference = 'Stop'

$base = 'C:\Windows\Temp'
$steps = @(
    'verify-uefi-boot.ps1',
    'ensure-virtio-boot-binding.ps1',
    'verify-virtio-boot-drivers.ps1',
    '02-install-qemu-guest-agent.ps1',
    '03-configure-openssh.ps1',
    '04-set-administrator-password.ps1',
    '05-inject-ssh-keys.ps1',
    'configure-oobe-locale.ps1',
    '10-ensure-edge-for-sysprep.ps1',
    '06-shrink-disk.ps1',
    '09-prepare-for-sysprep.ps1'
)

foreach ($name in $steps) {
    $path = Join-Path $base $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing provision script on guest: $path (CD staging failed?)"
    }
    Write-Host ""
    Write-Host "=== $name ==="
    & $path
}

Write-Host ""
Write-Host "Provision pass scripts completed."
