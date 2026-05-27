# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Generalize the image for cloning in OpenShift Virtualization (KubeVirt).
$ErrorActionPreference = 'Stop'

$sysprep = 'C:\Windows\System32\Sysprep\sysprep.exe'
if (-not (Test-Path $sysprep)) {
    throw "Sysprep not found at $sysprep"
}

$unattend = 'C:\Windows\Panther\unattend.xml'
$unattendAlt = 'C:\Windows\Temp\sysprep-unattend.xml'
if (-not (Test-Path $unattend) -and (Test-Path $unattendAlt)) {
    New-Item -ItemType Directory -Path (Split-Path $unattend) -Force | Out-Null
    Copy-Item -Path $unattendAlt -Destination $unattend -Force
}

$sysprepArgs = @('/generalize', '/oobe', '/quiet', '/shutdown')
if (Test-Path $unattend) {
    Write-Host "Running sysprep with unattend: $unattend"
    $sysprepArgs += "/unattend:$unattend"
}
else {
    Write-Warning 'No sysprep unattend at C:\Windows\Panther\unattend.xml — OOBE may prompt for a product key on first boot'
}

Write-Host ('Running sysprep ' + ($sysprepArgs -join ' '))
& $sysprep @sysprepArgs
