# Install OpenSSH.Server capability (must run as SYSTEM; used by specialize and scheduled task).
$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\openssh-install.log'
function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    $line | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host $line
}

Write-Log "Starting OpenSSH install (user: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name))"

$capability = Get-WindowsCapability -Online |
    Where-Object { $_.Name -like 'OpenSSH.Server*' }

if (-not $capability) {
    Write-Log 'ERROR: OpenSSH.Server capability not found on this image.'
    exit 1
}

if ($capability.State -eq 'Installed') {
    Write-Log "Already installed: $($capability.Name)"
    exit 0
}

Write-Log "Installing $($capability.Name) (was $($capability.State)); this may take several minutes and needs network access to Windows Update."

try {
    $result = Add-WindowsCapability -Online -Name $capability.Name
    Write-Log "Add-WindowsCapability returned: $($result.RestartNeeded)"
} catch {
    Write-Log "ERROR: Add-WindowsCapability failed: $_"
    exit 1
}

$capability = Get-WindowsCapability -Online |
    Where-Object { $_.Name -like 'OpenSSH.Server*' }

if ($capability.State -ne 'Installed') {
    Write-Log "ERROR: Capability state after install: $($capability.State)"
    exit 1
}

Write-Log 'OpenSSH.Server capability installed successfully.'
exit 0
