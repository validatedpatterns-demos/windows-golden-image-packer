# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Provision Edge for all users early in the provision pass (before shrink/sysprep).
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'remove-sysprep-blocking-appx.ps1')
Remove-SysprepBlockingAppx

Write-Host '10-ensure-edge-for-sysprep.ps1 complete'
