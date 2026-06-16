# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Tekton-style post-install: virtio-win MSI + QEMU guest agent from virtio CD.
# Runs during specialize (unattended install); PROVISION CD supplies this script.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-FileOnCdRom {
    param(
        [string]$Leaf,
        [switch]$Recurse
    )
    foreach ($letter in @('D', 'E', 'F', 'G', 'H', 'I', 'J', 'K')) {
        $root = "${letter}:\"
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        if ($Recurse) {
            $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter $Leaf -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }
        else {
            $hit = Get-ChildItem -LiteralPath $root -Filter $Leaf -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }
        if ($hit) {
            return $hit.FullName
        }
    }
    return $null
}

function Install-MsiQuiet {
    param([string]$Path)
    if (-not $Path) {
        return
    }
    Write-Host "Installing MSI: $Path"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @(
        '/i', $Path, '/qn', '/passive', '/norestart'
    ) -Wait -PassThru
    if ($proc.ExitCode -notin 0, 3010) {
        throw "msiexec failed for $Path (exit $($proc.ExitCode))"
    }
}

$virtioMsi = Find-FileOnCdRom -Leaf 'virtio-win-gt-x64.msi'
$gaMsi = Find-FileOnCdRom -Leaf 'qemu-ga-x86_64.msi' -Recurse

if (-not $virtioMsi) {
    Write-Warning 'virtio-win-gt-x64.msi not found on any CD-ROM; skipping virtio-win guest tools install'
}
else {
    Install-MsiQuiet -Path $virtioMsi
}

if (-not $gaMsi) {
    Write-Warning 'qemu-ga-x86_64.msi not found on any CD-ROM; skipping guest agent install'
}
else {
    Install-MsiQuiet -Path $gaMsi
}

# Prevent sysprep from re-reading the install unattend on the PROVISION CD.
foreach ($letter in @('D', 'E', 'F', 'G', 'H')) {
    $unattend = "${letter}:\unattend.xml"
    if (Test-Path -LiteralPath $unattend) {
        Rename-Item -LiteralPath $unattend -NewName 'unattend.install.xml' -Force
        Write-Host "Renamed install unattend on ${letter}:"
        break
    }
}

Write-Host 'post-install.ps1 complete'
