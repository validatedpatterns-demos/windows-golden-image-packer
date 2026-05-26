# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Enable WinRM for Packer (specialize pass or first logon).
$ErrorActionPreference = 'Stop'

# Allow full local Administrator token over WinRM (required for DISM/capability installs).
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord -Force

Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

winrm quickconfig -q -force
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="2048"}'

netsh advfirewall firewall set rule group="Windows Remote Management" new enable=yes | Out-Null
netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=TCP action=allow | Out-Null

Write-Host 'WinRM enabled for Packer on port 5985'
