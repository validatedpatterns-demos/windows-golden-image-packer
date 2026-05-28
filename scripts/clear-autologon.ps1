# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Disable automatic Administrator logon (Winlogon). Used before sysprep and on post-sysprep first boot.
$ErrorActionPreference = 'Stop'

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0' -Type String -Force
Set-ItemProperty -Path $winlogon -Name ForceAutoLogon -Value '0' -Type String -Force -ErrorAction SilentlyContinue

foreach ($name in @(
        'DefaultPassword',
        'DefaultUserName',
        'DefaultDomainName',
        'AltDefaultUserName',
        'AltDefaultDomainName',
        'AutoLogonSID',
        'AutoLogonCount'
    )) {
    Remove-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue
}

Write-Host 'Autologon disabled (Winlogon keys cleared).'
