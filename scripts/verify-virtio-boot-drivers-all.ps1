# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Wrapper for Packer provisioners that cannot pass -AllControlSets to a script path.
$ErrorActionPreference = 'Stop'
$verify = Join-Path $PSScriptRoot 'verify-virtio-boot-drivers.ps1'
if (-not (Test-Path -LiteralPath $verify)) {
    throw "Missing $verify"
}
& $verify -AllControlSets
