# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Sysprep AppX prep: provision Edge for all users; trim CloudExperienceHost provisioning.
# Dot-source from 09-prepare-for-sysprep.ps1 and sysprep.ps1.

. (Join-Path $PSScriptRoot 'ensure-edge-for-sysprep.ps1')

function Remove-SysprepBlockingAppx {
    Remove-CloudExperienceHostProvisioning
    Ensure-EdgeAppxForSysprep
}
