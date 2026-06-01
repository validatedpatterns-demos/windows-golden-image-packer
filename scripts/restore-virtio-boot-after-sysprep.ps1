# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# sysprep /generalize removes VirtIO boot-start services (viostor/vioscsi) because the sysprep
# VM boots from SATA, not virtio-blk. Re-bind before power-off so OpenShift disk.bus=virtio works.
$ErrorActionPreference = 'Stop'

$installScript = Join-Path $PSScriptRoot '01-install-virtio-drivers.ps1'
if (-not (Test-Path -LiteralPath $installScript)) {
    throw "Missing $installScript"
}

. $installScript -SkipMain

$virtioOsDir = Get-TargetVirtioOsDir
$mediaRoot = Find-VirtioMediaRoot -OsDir $virtioOsDir
$virtioOsDir = Get-VirtioOsDir -MediaRoot $mediaRoot -OsDir $virtioOsDir

Write-Host "Re-binding VirtIO boot drivers after sysprep (media: $mediaRoot, OS dir: $virtioOsDir)"
Install-VirtioBootBinding -MediaRoot $mediaRoot -VirtioOsDir $virtioOsDir

$verify = Join-Path $PSScriptRoot 'verify-virtio-boot-drivers.ps1'
if (-not (Test-Path -LiteralPath $verify)) {
    throw "Missing $verify"
}
& $verify

Sync-VirtioBootRegistryToAllControlSets

Write-Host 'restore-virtio-boot-after-sysprep.ps1 complete'
