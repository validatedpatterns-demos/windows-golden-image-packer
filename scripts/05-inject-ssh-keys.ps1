# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Authorize SSH public keys for the Administrator account (administrators_authorized_keys).
$ErrorActionPreference = 'Stop'

$keys = @()
if ($env:SSH_PUBLIC_KEYS) {
    $parsed = $env:SSH_PUBLIC_KEYS | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        $keys = @($parsed)
    } elseif ($parsed) {
        $keys = @([string]$parsed)
    }
}

$keys = $keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }

if (-not $keys) {
    Write-Host 'No SSH public keys supplied; skipping key injection.'
    exit 0
}

$programData = $env:ProgramData
if (-not $programData) { $programData = 'C:\ProgramData' }

$sshDir = Join-Path $programData 'ssh'
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

$authKeys = Join-Path $sshDir 'administrators_authorized_keys'
$keys | Set-Content -Path $authKeys -Encoding ascii

# Required ACL: SYSTEM and Administrators only (inheritance disabled).
$acl = Get-Acl $authKeys
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

$systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')

$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $systemSid, 'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $adminSid, 'FullControl', 'Allow')))

Set-Acl -Path $authKeys -AclObject $acl

Write-Host "Injected $($keys.Count) SSH public key(s) into $authKeys"
