# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Generalize the image for cloning in OpenShift Virtualization (KubeVirt).
$ErrorActionPreference = 'Stop'

$clearScript = Join-Path $PSScriptRoot 'clear-autologon.ps1'
if (Test-Path $clearScript) {
    & $clearScript
}
else {
    Write-Warning "clear-autologon.ps1 not found beside sysprep.ps1; image may autologon on first OpenShift boot"
}

$sysprep = 'C:\Windows\System32\Sysprep\sysprep.exe'
if (-not (Test-Path $sysprep)) {
    throw "Sysprep not found at $sysprep"
}

$goldenData = 'C:\ProgramData\GoldenImage'
$generalizeUnattend = 'C:\Windows\Temp\sysprep-generalize.xml'
$oobeUnattend = 'C:\Windows\Temp\sysprep-oobe.xml'
$oobeUnattendPersistent = Join-Path $goldenData 'sysprep-oobe.xml'
$panther = 'C:\Windows\Panther'
$sysprepPanther = 'C:\Windows\System32\Sysprep\Panther'

function Resolve-OobeUnattendPath {
    if (Test-Path $oobeUnattend) {
        return $oobeUnattend
    }
    if (Test-Path $oobeUnattendPersistent) {
        return $oobeUnattendPersistent
    }
    throw "Missing OOBE unattend (expected $oobeUnattend or $oobeUnattendPersistent). Disk shrink may have removed Temp copies before sysprep; rebuild with current scripts."
}

foreach ($dir in @($panther, $sysprepPanther)) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem -Path $dir -Filter 'unattend*.xml' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($name in @('setupact.log', 'setuperr.log')) {
        $path = Join-Path $dir $name
        if (Test-Path $path) {
            Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        }
    }
}

$sysprepStatus = 'HKLM:\SYSTEM\Setup\Status\SysprepStatus'
if (Test-Path $sysprepStatus) {
    Remove-Item -Path $sysprepStatus -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $generalizeUnattend)) {
    throw "Missing $generalizeUnattend (specialize/generalize only — no oobeSystem)"
}
$oobeSource = Resolve-OobeUnattendPath

[void][xml](Get-Content -Path $generalizeUnattend -Raw)
[void][xml](Get-Content -Path $oobeSource -Raw)

New-Item -ItemType Directory -Path $panther -Force | Out-Null
Copy-Item -Path $oobeSource -Destination (Join-Path $panther 'unattend.xml') -Force
Copy-Item -Path $oobeSource -Destination 'C:\unattend.xml' -Force
$oobeXml = Get-Content -Path (Join-Path $panther 'unattend.xml') -Raw
if ($oobeXml -notmatch 'Microsoft-Windows-International-Core') {
    throw 'Panther unattend missing International-Core before sysprep — not sysprep-oobe.xml'
}
if ($oobeXml -match '<AutoLogon>[\s\S]*?<Enabled>true</Enabled>') {
    throw 'Panther unattend still has install AutoLogon — replace with sysprep-oobe.xml before sysprep'
}
Write-Host "Staged OOBE-only unattend in Panther for first deploy boot"

# Sysprep must not use the oobeSystem file; generalize pass copies sysprep-oobe.xml back to Panther.
$unattend = $generalizeUnattend

$sysprepArgs = @('/generalize', '/oobe', '/mode:vm', '/quiet', '/shutdown', "/unattend:$unattend")
Write-Host ('Running sysprep ' + ($sysprepArgs -join ' '))
& $sysprep @sysprepArgs
