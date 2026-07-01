# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Configure OpenSSH Server (install via SYSTEM task if needed; then sshd_config + service).
$ErrorActionPreference = 'Stop'

# File provisioner flattens scripts/ into C:\Windows\Temp\ (no subfolder).
$commonPath = 'C:\Windows\Temp\OpenSSH-Server-Common.ps1'
if (-not (Test-Path $commonPath)) {
    $commonPath = Join-Path $PSScriptRoot 'OpenSSH-Server-Common.ps1'
}
. $commonPath

function Write-Step {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Install-OpenSshServerAsSystem {
    param(
        [string]$ScriptPath = 'C:\Windows\Temp\install-openssh-server.ps1',
        [int]$TimeoutMinutes = 25
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Install script not found at $ScriptPath."
    }

    $taskName = 'PackerInstallOpenSSH'
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        if (Test-OpenSshServerReady) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            return
        }
        if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {
            break
        }
    }

    $info = Get-ScheduledTaskInfo -TaskName $taskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    if (Test-OpenSshServerReady) {
        return
    }

    $logHint = ''
    if (Test-Path 'C:\Windows\Temp\openssh-install.log') {
        $logHint = " Log tail:`n$((Get-Content 'C:\Windows\Temp\openssh-install.log' -Tail 15) -join "`n")"
    }

    throw @(
        "OpenSSH install task failed (LastTaskResult $($info.LastTaskResult), capability $((Get-OpenSshCapability).State))."
        'VM needs network for Windows Update. Check C:\Windows\Temp\openssh-install.log.'
        $logHint
    ) -join ' '
}

Write-Step 'Checking OpenSSH.Server capability (Get-WindowsCapability can take 1-3 minutes)...'

$capability = Get-OpenSshCapability
if (-not $capability) {
    throw 'OpenSSH.Server capability not found on this image.'
}

Write-Step "OpenSSH.Server state: $($capability.State) ($($capability.Name))"

if (-not (Test-OpenSshServerReady)) {
    if ($capability.State -ne 'Installed') {
        Write-Step 'Installing OpenSSH as SYSTEM (scheduled task; often 5-15 minutes)...'
        Install-OpenSshServerAsSystem
    } else {
        Write-Step 'Capability is Installed but sshd_config missing; repairing layout as SYSTEM...'
        Install-OpenSshServerAsSystem
    }
    $capability = Get-OpenSshCapability
    Write-Step "After install: capability=$($capability.State), ready=$(Test-OpenSshServerReady)"
}

if (-not (Test-OpenSshServerReady)) {
    Write-Step 'Attempting layout initialization from WinRM session...'
    Initialize-OpenSshServerLayout -Log { param($m) Write-Step $m }
}

$sshdConfig = 'C:\ProgramData\ssh\sshd_config'
if (-not (Test-Path $sshdConfig)) {
    throw "sshd_config still missing at $sshdConfig. See C:\Windows\Temp\openssh-install.log and C:\Windows\Logs\DISM\dism.log."
}

Write-Step 'Updating sshd_config...'

$config = Get-Content $sshdConfig
$replacements = @{
    '#PasswordAuthentication yes' = 'PasswordAuthentication yes'
    '#PubkeyAuthentication yes'   = 'PubkeyAuthentication yes'
    '#PermitRootLogin prohibit-password' = 'PermitRootLogin no'
}

foreach ($key in $replacements.Keys) {
    if ($config -contains $key) {
        $config = $config -replace [regex]::Escape($key), $replacements[$key]
    }
}

if ($config -notmatch '(?m)^PubkeyAuthentication') {
    $config += 'PubkeyAuthentication yes'
}
if ($config -notmatch '(?m)^PasswordAuthentication') {
    $config += 'PasswordAuthentication yes'
}

Set-Content -Path $sshdConfig -Value $config -Encoding ascii

Write-Step 'Starting sshd service and firewall rule...'

Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

Ensure-OpenSshFirewallRule

Write-Step 'OpenSSH Server is installed, configured, and running.'
