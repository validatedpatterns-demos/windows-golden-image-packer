# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Install VirtIO storage, network, balloon, and SCSI drivers from WinRM-staged or PROVISION CD media.
# Marks block/SCSI drivers boot-start so the image can boot with disk.bus virtio on OpenShift/KubeVirt.
$ErrorActionPreference = 'Stop'

function Get-CdRomDriveLetters {
    $letters = @()
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } |
        ForEach-Object { $letters += "$($_.DriveLetter):" }
    Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 5 -and $_.DeviceID } |
        ForEach-Object { $letters += $_.DeviceID }
    return $letters | Select-Object -Unique
}

function Get-TargetVirtioOsDir {
    switch ($env:WINDOWS_VERSION) {
        '2025' { return '2k25' }
        '2022' { return '2k22' }
    }

    $caption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    if ($caption -match '2025') {
        return '2k25'
    }

    return '2k22'
}

function Get-DriverSearchPaths {
    param(
        [string]$DriveRoot,
        [string]$OsDir
    )

    if (-not (Test-Path $DriveRoot)) {
        return @()
    }

    $paths = @()
    $components = @('viostor', 'NetKVM', 'Balloon', 'vioscsi', 'qxldod')

    foreach ($component in $components) {
        $path = Join-Path $DriveRoot "$component\$OsDir\amd64"
        if (Test-Path $path) { $paths += $path }
    }

    $flat = Join-Path $DriveRoot "$OsDir\amd64"
    if (Test-Path $flat) { $paths += $flat }

    if (-not $paths) {
        Get-ChildItem -Path $DriveRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\$([regex]::Escape($OsDir))\\amd64$" } |
            ForEach-Object {
                if (Get-ChildItem -Path $_.FullName -Filter '*.inf' -ErrorAction SilentlyContinue) {
                    $_.FullName
                }
            } |
            ForEach-Object { $paths += $_ }
    }

    return $paths | Select-Object -Unique
}

function Get-ProvisionSearchRoots {
    $roots = @(
        'C:\Windows\Temp\drivers',
        'C:\Windows\Temp\virtio-drivers'
    )

    foreach ($drive in (Get-CdRomDriveLetters)) {
        $roots += $drive
        $roots += (Join-Path $drive 'drivers')
        $roots += (Join-Path $drive 'virtio-win-staged')
    }

    return $roots | Select-Object -Unique
}

function Find-VirtioMediaRoot {
    param([string]$OsDir)

    foreach ($root in (Get-ProvisionSearchRoots)) {
        if ((Get-DriverSearchPaths -DriveRoot $root -OsDir $OsDir).Count -gt 0) {
            return $root
        }
    }

    $cdLetters = (Get-CdRomDriveLetters) -join ', '
    $diag = @("VirtIO driver media not found (WinRM staging or PROVISION CD).")
    if ($cdLetters) { $diag += "CD-ROM(s): $cdLetters." }
    $diag += 'Run: STAGE_FORCE=1 make stage-virtio && make build.'

    foreach ($root in (Get-ProvisionSearchRoots)) {
        if (-not (Test-Path $root)) { continue }
        $diag += "Contents of ${root}:"
        Get-ChildItem -Path $root -ErrorAction SilentlyContinue |
            Select-Object -First 20 |
            ForEach-Object { $diag += "  $($_.Name)" }
    }

    throw ($diag -join "`n")
}

function Get-VirtioOsDir {
    param(
        [string]$MediaRoot,
        [string]$OsDir
    )

    if (Test-Path (Join-Path $MediaRoot "viostor\$OsDir\amd64\viostor.inf")) {
        return $OsDir
    }

    throw "Could not find viostor.inf under $MediaRoot\viostor\$OsDir\amd64 (stage both 2k22 and 2k25 with make stage-virtio)."
}

function Install-DriverPackage {
    param([string]$InfPath)

    if (-not (Test-Path $InfPath)) {
        Write-Warning "Driver INF not found: $InfPath"
        return $false
    }

    Write-Host "Installing driver package: $InfPath"
    pnputil.exe /add-driver $InfPath /install | Out-Host
    return $true
}

# pnputil only creates Services\* keys when matching VirtIO PCI hardware is present.
# The build VM uses IDE, so stage boot drivers explicitly (copy .sys + service registry).
function Ensure-BootDriverStaged {
    param(
        [string]$ServiceName,
        [string]$SysFileName,
        [string]$InfPath
    )

    if (-not (Test-Path $InfPath)) {
        throw "Driver INF not found: $InfPath"
    }

    $driverDir = Split-Path -Parent $InfPath
    $sysSrc = Join-Path $driverDir $SysFileName
    $sysDst = Join-Path $env:SystemRoot "System32\drivers\$SysFileName"

    Install-DriverPackage -InfPath $InfPath | Out-Null

    if (-not (Test-Path $sysSrc)) {
        throw "Driver binary not found: $sysSrc"
    }

    Copy-Item -Path $sysSrc -Destination $sysDst -Force
    Write-Host "Copied $SysFileName -> $sysDst"

    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name 'Type' -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $key -Name 'ErrorControl' -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $key -Name 'ImagePath' -Value "System32\drivers\$SysFileName" -PropertyType ExpandString -Force | Out-Null
        New-ItemProperty -Path $key -Name 'Group' -Value 'SCSI miniport' -PropertyType String -Force | Out-Null
        Write-Host "Created boot driver service key: $ServiceName"
    }

    Set-ItemProperty -Path $key -Name 'Start' -Value 0 -Type DWord -Force
    Write-Host "Boot-start driver: $ServiceName (Start=0)"

    if (-not (Test-Path $sysDst)) {
        throw "Driver binary missing after staging: $sysDst"
    }
}

function Set-VirtioCriticalDeviceDatabase {
    param(
        [string]$ServiceName,
        [string[]]$RelativePaths
    )

    $classGuid = '{4d36e97b-e325-11ce-bfc1-08002be10318}'
    foreach ($rel in $RelativePaths) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\$rel"
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name 'Service' -Value $ServiceName -Type String -Force
        Set-ItemProperty -Path $key -Name 'ClassGUID' -Value $classGuid -Type String -Force
        Write-Host "CriticalDeviceDatabase: $rel -> $ServiceName"
    }
}
function Confirm-BootDrivers {
    param([string[]]$ServiceNames)

    foreach ($name in $ServiceNames) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        if (-not (Test-Path $key)) {
            throw "Boot driver service key missing: $name"
        }
        $start = (Get-ItemProperty -Path $key -Name 'Start' -ErrorAction SilentlyContinue).Start
        if ($start -ne 0) {
            throw "Driver $name is not boot-start (Start=$start, expected 0)."
        }
    }
}

$virtioOsDir = Get-TargetVirtioOsDir
$mediaRoot = Find-VirtioMediaRoot -OsDir $virtioOsDir
$virtioOsDir = Get-VirtioOsDir -MediaRoot $mediaRoot -OsDir $virtioOsDir
$driverPaths = Get-DriverSearchPaths -DriveRoot $mediaRoot -OsDir $virtioOsDir

Write-Host "VirtIO media: $mediaRoot (OS dir: $virtioOsDir)"
Write-Host 'Installing VirtIO drivers from paths:'
$driverPaths | ForEach-Object { Write-Host "  $_" }

foreach ($path in $driverPaths) {
    pnputil.exe /add-driver (Join-Path $path '*.inf') /install | Out-Host
}

# Explicit INF install for storage controllers used by KubeVirt disk.bus virtio / virtio-scsi.
$viostorInf = Join-Path $mediaRoot "viostor\$virtioOsDir\amd64\viostor.inf"
$vioscsiInf = Join-Path $mediaRoot "vioscsi\$virtioOsDir\amd64\vioscsi.inf"
$netkvmInf = Join-Path $mediaRoot "NetKVM\$virtioOsDir\amd64\netkvm.inf"

Ensure-BootDriverStaged -ServiceName 'viostor' -SysFileName 'viostor.sys' -InfPath $viostorInf
Ensure-BootDriverStaged -ServiceName 'vioscsi' -SysFileName 'vioscsi.sys' -InfPath $vioscsiInf
Install-DriverPackage -InfPath $netkvmInf | Out-Null

Set-VirtioCriticalDeviceDatabase -ServiceName 'viostor' -RelativePaths @(
    'pci#ven_1af4&dev_1001',
    'pci#ven_1af4&dev_1001&subsys_00021af4&rev_00',
    'pci#ven_1af4&dev_1042&subsys_11001af4&rev_01'
)

$enableBlkBoot = Join-Path $PSScriptRoot 'enable-virtio-blk-boot-load.ps1'
if (-not (Test-Path -LiteralPath $enableBlkBoot)) {
    throw "Missing $enableBlkBoot"
}
& $enableBlkBoot -InfPath $viostorInf

$enableScsiBoot = Join-Path $PSScriptRoot 'enable-virtio-scsi-boot-load.ps1'
if (-not (Test-Path -LiteralPath $enableScsiBoot)) {
    throw "Missing $enableScsiBoot"
}
& $enableScsiBoot -InfPath $vioscsiInf

Confirm-BootDrivers -ServiceNames @('viostor', 'vioscsi')

Write-Host 'VirtIO driver installation complete (viostor/vioscsi boot-start + virtio blk/scsi boot binding).'
