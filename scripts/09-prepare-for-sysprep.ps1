# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Last-minute guest cleanup before sysprep. Follow with windows-restart in Packer to clear pending reboot.
$ErrorActionPreference = 'Stop'

$goldenData = 'C:\ProgramData\GoldenImage'
New-Item -ItemType Directory -Path $goldenData -Force | Out-Null
$logPath = Join-Path $goldenData 'prepare-for-sysprep.log'
Start-Transcript -Path $logPath -Force | Out-Null

. (Join-Path $PSScriptRoot 'remove-sysprep-blocking-appx.ps1')

function Test-PendingReboot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }
    return $false
}

function Stop-UpdateServices {
    foreach ($name in @('wuauserv', 'UsoSvc', 'bits', 'dosvc')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Host "Stopping service $name"
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        }
    }
}

Stop-UpdateServices
Remove-SysprepBlockingAppx

if (Test-PendingReboot) {
    Write-Host 'Pending reboot detected (expected after drivers/mbr2gpt/DISM); Packer windows-restart will reboot next'
}
else {
    Write-Host 'No pending reboot markers detected'
}

Write-Host 'prepare-for-sysprep.ps1 complete'
Stop-Transcript | Out-Null
