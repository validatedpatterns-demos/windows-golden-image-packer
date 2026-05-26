# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Ensure the built-in Administrator account is enabled with the Packer-supplied password.
$ErrorActionPreference = 'Stop'

$password = $env:WINRM_PASSWORD
if ([string]::IsNullOrWhiteSpace($password)) {
    throw 'WINRM_PASSWORD is not set; cannot configure Administrator password.'
}

$secure = ConvertTo-SecureString $password -AsPlainText -Force
Set-LocalUser -Name 'Administrator' -Password $secure -PasswordNeverExpires:$true
Enable-LocalUser -Name 'Administrator'

Write-Host 'Administrator account password applied and account enabled.'
