# Configure OpenSSH Server (install via SYSTEM task if needed; WinRM/DISM alone get access denied).
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Get-OpenSshCapability {
    Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' }
}

function Install-OpenSshServerAsSystem {
    param(
        [string]$ScriptPath = 'C:\Windows\Temp\install-openssh-server.ps1',
        [int]$TimeoutMinutes = 25
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Install script not found at $ScriptPath (file provisioner should upload scripts/)."
    }

    $taskName = 'PackerInstallOpenSSH'
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $cap = Get-OpenSshCapability
        if ($cap -and $cap.State -eq 'Installed') {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            return
        }
        if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {
            break
        }
    }

    $info = Get-ScheduledTaskInfo -TaskName $taskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $cap = Get-OpenSshCapability
    if ($cap -and $cap.State -eq 'Installed') {
        return
    }

    $logHint = ''
    if (Test-Path 'C:\Windows\Temp\openssh-install.log') {
        $logHint = " Last lines of C:\Windows\Temp\openssh-install.log:`n$(
            (Get-Content 'C:\Windows\Temp\openssh-install.log' -Tail 15) -join "`n"
        )"
    }

    throw @(
        "OpenSSH install task did not complete (task result $($info.LastTaskResult), capability state $($cap.State))."
        'Ensure the VM has network for Windows Update during build.'
        $logHint
    ) -join ' '
}

Write-Step 'Checking OpenSSH.Server capability (Get-WindowsCapability can take 1-3 minutes)...'

$capability = Get-OpenSshCapability
if (-not $capability) {
    throw 'OpenSSH.Server capability not found on this image.'
}

Write-Step "OpenSSH.Server state: $($capability.State) ($($capability.Name))"

if ($capability.State -ne 'Installed') {
    Write-Step 'Installing OpenSSH as SYSTEM (WinRM/DISM exit 5 = access denied; scheduled task, often 5-15 minutes)...'
    Install-OpenSshServerAsSystem
    $capability = Get-OpenSshCapability
    Write-Step "OpenSSH.Server state after install: $($capability.State)"
}

if ($capability.State -ne 'Installed') {
    throw 'OpenSSH.Server is still not installed after SYSTEM install task.'
}

Write-Step 'Updating sshd_config...'

$sshdConfig = 'C:\ProgramData\ssh\sshd_config'
if (-not (Test-Path $sshdConfig)) {
    throw "sshd_config not found at $sshdConfig."
}

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

$fwRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $fwRule) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

Write-Step 'OpenSSH Server is installed, configured, and running.'
