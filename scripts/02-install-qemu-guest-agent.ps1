# Install QEMU Guest Agent (required for OpenShift Virtualization / KubeVirt guest management).
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

function Find-GuestAgentMsi {
    $msiNames = @('qemu-ga-x86_64.msi', 'qemu-ga-x64.msi')
    $roots = @(
        'C:\Windows\Temp\drivers\guest-agent',
        'C:\Windows\Temp\virtio-drivers\guest-agent'
    )

    foreach ($drive in (Get-CdRomDriveLetters)) {
        $roots += (Join-Path $drive 'guest-agent')
        $roots += (Join-Path $drive 'drivers\guest-agent')
        $roots += (Join-Path $drive 'virtio-win-staged\guest-agent')
        $roots += $drive
    }

    foreach ($root in ($roots | Select-Object -Unique)) {
        foreach ($name in $msiNames) {
            $path = Join-Path $root $name
            if (Test-Path $path) { return $path }
        }
    }

    throw @(
        'QEMU Guest Agent MSI not found (WinRM staging or PROVISION CD).'
        "CD-ROM(s): $((Get-CdRomDriveLetters) -join ', ')."
        'Run: STAGE_FORCE=1 make stage-virtio && make build.'
    ) -join ' '
}

$msi = Find-GuestAgentMsi

Write-Host "Installing QEMU Guest Agent from $msi"
Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -NoNewWindow

$service = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
if ($service) {
    Set-Service -Name 'QEMU-GA' -StartupType Automatic
    if ($service.Status -ne 'Running') {
        Start-Service -Name 'QEMU-GA'
    }
}

Write-Host 'QEMU Guest Agent installed and set to start automatically.'
