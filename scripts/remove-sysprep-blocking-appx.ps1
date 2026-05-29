# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Remove per-user and provisioned AppX packages that block sysprep generalize (Edge, etc.).
# Dot-source from 09-prepare-for-sysprep.ps1 and sysprep.ps1.

function Test-SysprepBlockingAppxName {
    param([string]$Name)
    $patterns = @(
        'Microsoft.MicrosoftEdge.Stable',
        'Microsoft.MicrosoftEdge',
        'Microsoft.MicrosoftEdgeDevToolsClient',
        'Microsoft.Windows.CloudExperienceHost'
    )
    foreach ($pattern in $patterns) {
        if ($Name -like "*$pattern*") {
            return $true
        }
    }
    return $false
}

function Remove-SysprepBlockingAppx {
    foreach ($pkg in Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) {
        if (-not (Test-SysprepBlockingAppxName -Name $pkg.Name)) {
            continue
        }
        Write-Host "Removing user AppX (AllUsers): $($pkg.PackageFullName)"
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($pkg in Get-AppxPackage -ErrorAction SilentlyContinue) {
        if (-not (Test-SysprepBlockingAppxName -Name $pkg.Name)) {
            continue
        }
        Write-Host "Removing user AppX (current user): $($pkg.PackageFullName)"
        Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($pkg in Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) {
        if (-not (Test-SysprepBlockingAppxName -Name $pkg.DisplayName)) {
            continue
        }
        Write-Host "Removing provisioned AppX: $($pkg.DisplayName)"
        Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue | Out-Null
    }

    $remaining = @(
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Get-AppxPackage -ErrorAction SilentlyContinue
    ) | Where-Object { $_ -and (Test-SysprepBlockingAppxName -Name $_.Name) } |
        Select-Object -ExpandProperty PackageFullName -Unique

    if ($remaining) {
        throw "Sysprep-blocking AppX still present after cleanup: $($remaining -join ', ')"
    }

    Write-Host 'Sysprep-blocking AppX cleanup complete (no Edge/CloudExperience packages remain)'
}
