# Install VirtIO storage, network, balloon, and SCSI drivers from the virtio-win ISO.
$ErrorActionPreference = 'Stop'

function Find-VirtioIsoDrive {
    $candidates = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } |
        ForEach-Object { "$($_.DriveLetter):" }

    foreach ($drive in $candidates) {
        if (Test-Path "$drive\virtio-win-gt-x64.exe") { return $drive }
        if (Test-Path "$drive\viostor") { return $drive }
    }
    throw 'virtio-win ISO not found on any CD-ROM drive letter.'
}

function Get-DriverSearchPaths {
    param([string]$DriveRoot)
    $subdirs = @('2k22', '2k25', 'w11', 'w10')
    $components = @('viostor', 'NetKVM', 'Balloon', 'vioscsi', 'qxldod')
    $paths = @()
    foreach ($component in $components) {
        foreach ($subdir in $subdirs) {
            $path = Join-Path $DriveRoot "$component\$subdir\amd64"
            if (Test-Path $path) { $paths += $path }
        }
    }
    return $paths | Select-Object -Unique
}

$isoDrive = Find-VirtioIsoDrive
$driverPaths = Get-DriverSearchPaths -DriveRoot $isoDrive

if (-not $driverPaths) {
    throw "No VirtIO driver directories found under $isoDrive"
}

Write-Host "Installing VirtIO drivers from paths:"
$driverPaths | ForEach-Object { Write-Host "  $_" }

foreach ($path in $driverPaths) {
    pnputil.exe /add-driver (Join-Path $path '*.inf') /install | Out-Host
}

Write-Host 'VirtIO driver installation complete.'
