# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Copy scripts/ and drivers/ from the PROVISION CD to C:\Windows\Temp (pass 2).
# Avoids Packer winrmcp bulk upload, which can fail with "Couldn't create shell" on early boot.
$ErrorActionPreference = 'Stop'

function Get-CdRomDriveRoots {
    $roots = @()
    foreach ($cd in Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction SilentlyContinue) {
        if (-not $cd.Drive) { continue }
        $drive = $cd.Drive.TrimEnd('\')
        if (-not $drive.EndsWith(':')) { $drive += ':' }
        $roots += ($drive + '\')
    }
    return $roots | Select-Object -Unique
}

function Find-ProvisionCdRoot {
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        foreach ($root in Get-CdRomDriveRoots) {
            $marker = Join-Path $root 'scripts\sysprep.ps1'
            if (Test-Path -LiteralPath $marker) {
                return $root
            }
        }
        $roots = (Get-CdRomDriveRoots) -join ', '
        if ($roots) {
            Write-Host "Waiting for PROVISION CD (seen: $roots)..."
        }
        else {
            Write-Host 'Waiting for PROVISION CD (no CD-ROM drive letters yet)...'
        }
        Start-Sleep -Seconds 3
    }
    throw 'PROVISION CD not found (expected scripts\sysprep.ps1 on a CD-ROM drive)'
}

function Wait-WinRmReady {
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        try {
            $svc = Get-Service -Name WinRM -ErrorAction Stop
            if ($svc.Status -eq 'Running') {
                $null = winrm id 2>$null
                if ($LASTEXITCODE -eq 0) {
                    return
                }
            }
        }
        catch {
            # WinRM still starting
        }
        Start-Sleep -Seconds 5
    }
    Write-Warning 'WinRM did not report ready; continuing with CD staging'
}

Wait-WinRmReady
Start-Sleep -Seconds 15

$cdRoot = Find-ProvisionCdRoot
$dest = 'C:\Windows\Temp'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$scriptsSrc = Join-Path $cdRoot 'scripts'
if (-not (Test-Path -LiteralPath $scriptsSrc)) {
    throw "Missing scripts on PROVISION CD: $scriptsSrc"
}
Get-ChildItem -Path $scriptsSrc -Force | Copy-Item -Destination $dest -Recurse -Force

$driversSrc = Join-Path $cdRoot 'drivers'
$driversDest = Join-Path $dest 'drivers'
if (-not (Test-Path -LiteralPath $driversSrc)) {
    throw "Missing drivers on PROVISION CD: $driversSrc"
}
if (Test-Path -LiteralPath $driversDest) {
    Remove-Item -Path $driversDest -Recurse -Force
}
Copy-Item -Path $driversSrc -Destination $driversDest -Recurse -Force

Write-Host "Staged provision media from $cdRoot to $dest"
