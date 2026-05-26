# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Install OpenSSH.Server capability (must run as SYSTEM; used by specialize and scheduled task).
$ErrorActionPreference = 'Stop'

$commonScript = @(
    (Join-Path $PSScriptRoot 'OpenSSH-Server-Common.ps1')
    'C:\Windows\Temp\OpenSSH-Server-Common.ps1'
    'A:\OpenSSH-Server-Common.ps1'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $commonScript) {
    Write-Error 'OpenSSH-Server-Common.ps1 not found (expected on floppy A:\ or C:\Windows\Temp\).'
    exit 1
}

. $commonScript

$logPath = 'C:\Windows\Temp\openssh-install.log'
function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    $line | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host $line
}

Write-Log "Starting OpenSSH install (user: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name))"

$capability = Get-OpenSshCapability
if (-not $capability) {
    Write-Log 'ERROR: OpenSSH.Server capability not found on this image.'
    exit 1
}

if ($capability.State -eq 'Installed' -and (Test-OpenSshServerReady)) {
    Write-Log "Already installed with sshd_config present: $($capability.Name)"
    exit 0
}

if ($capability.State -eq 'Installed') {
    Write-Log "Capability shows Installed but sshd_config missing; repairing layout."
} else {
    Write-Log "Installing $($capability.Name) (was $($capability.State)); needs network for Windows Update."
    try {
        $result = Add-WindowsCapability -Online -Name $capability.Name
        Write-Log "Add-WindowsCapability returned RestartNeeded=$($result.RestartNeeded)"
    } catch {
        Write-Log "ERROR: Add-WindowsCapability failed: $_"
        exit 1
    }

    $capability = Get-OpenSshCapability
    if ($capability.State -ne 'Installed') {
        Write-Log "ERROR: Capability state after install: $($capability.State)"
        exit 1
    }
}

try {
    Initialize-OpenSshServerLayout -Log { param($m) Write-Log $m }
} catch {
    Write-Log "ERROR: $_"
    exit 1
}

if (-not (Test-OpenSshServerReady)) {
    Write-Log 'ERROR: OpenSSH install finished but sshd_config is still missing.'
    exit 1
}

Write-Log 'OpenSSH Server is installed and layout is ready.'
exit 0
