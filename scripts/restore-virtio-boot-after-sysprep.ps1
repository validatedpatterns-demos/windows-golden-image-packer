# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# sysprep /generalize can clone a control set without VirtIO boot keys. Re-bind and sync
# every ControlSet00N before power-off so OpenShift disk.bus=virtio (virtio-blk) works.
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
& $verify -AllControlSets

Write-Host 'restore-virtio-boot-after-sysprep.ps1 complete'
