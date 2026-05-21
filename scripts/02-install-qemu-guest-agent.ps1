# Install QEMU Guest Agent (required for OpenShift Virtualization / KubeVirt guest management).
$ErrorActionPreference = 'Stop'

function Find-VirtioIsoDrive {
    $candidates = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } |
        ForEach-Object { "$($_.DriveLetter):" }

    foreach ($drive in $candidates) {
        if (Test-Path "$drive\guest-agent") { return $drive }
        if (Test-Path "$drive\virtio-win-gt-x64.exe") { return $drive }
    }
    throw 'virtio-win ISO not found on any CD-ROM drive letter.'
}

$isoDrive = Find-VirtioIsoDrive
$msiCandidates = @(
    (Join-Path $isoDrive 'guest-agent\qemu-ga-x86_64.msi'),
    (Join-Path $isoDrive 'guest-agent\qemu-ga-x64.msi')
)

$msi = $msiCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $msi) {
    throw "QEMU Guest Agent MSI not found under $isoDrive\guest-agent"
}

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
