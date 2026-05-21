# Install VirtIO storage, network, balloon, and SCSI drivers from WinRM-staged or PROVISION CD media.
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

function Get-DriverSearchPaths {
    param([string]$DriveRoot)

    if (-not (Test-Path $DriveRoot)) {
        return @()
    }

    $paths = @()
    $components = @('viostor', 'NetKVM', 'Balloon', 'vioscsi', 'qxldod')
    $subdirs = @('2k22', '2k25', 'w11', 'w10')

    foreach ($component in $components) {
        foreach ($subdir in $subdirs) {
            $path = Join-Path $DriveRoot "$component\$subdir\amd64"
            if (Test-Path $path) { $paths += $path }
        }
    }

    foreach ($subdir in $subdirs) {
        $path = Join-Path $DriveRoot "$subdir\amd64"
        if (Test-Path $path) { $paths += $path }
    }

    if (-not $paths) {
        Get-ChildItem -Path $DriveRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'amd64' } |
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
    foreach ($root in (Get-ProvisionSearchRoots)) {
        if ((Get-DriverSearchPaths -DriveRoot $root).Count -gt 0) {
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

$mediaRoot = Find-VirtioMediaRoot
$driverPaths = Get-DriverSearchPaths -DriveRoot $mediaRoot

Write-Host "VirtIO media: $mediaRoot"
Write-Host 'Installing VirtIO drivers from paths:'
$driverPaths | ForEach-Object { Write-Host "  $_" }

foreach ($path in $driverPaths) {
    pnputil.exe /add-driver (Join-Path $path '*.inf') /install | Out-Host
}

Write-Host 'VirtIO driver installation complete.'
