# Enable and configure OpenSSH Server for Administrator access.
$ErrorActionPreference = 'Stop'

$capability = Get-WindowsCapability -Online |
    Where-Object { $_.Name -like 'OpenSSH.Server*' -and $_.State -ne 'Installed' }

if ($capability) {
    Write-Host "Installing $($capability.Name)"
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}

$sshdConfig = 'C:\ProgramData\ssh\sshd_config'
if (-not (Test-Path $sshdConfig)) {
    throw "sshd_config not found at $sshdConfig"
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

Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

$fwRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $fwRule) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

Write-Host 'OpenSSH Server is installed, configured, and running.'
