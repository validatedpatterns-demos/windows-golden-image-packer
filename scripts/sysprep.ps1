# Generalize the image for cloning in OpenShift Virtualization (KubeVirt).
$ErrorActionPreference = 'Stop'

$sysprep = 'C:\Windows\System32\Sysprep\sysprep.exe'
if (-not (Test-Path $sysprep)) {
    throw "Sysprep not found at $sysprep"
}

Write-Host 'Running sysprep /generalize /oobe /shutdown'
& $sysprep /generalize /oobe /quiet /shutdown
