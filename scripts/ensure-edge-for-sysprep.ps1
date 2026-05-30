# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Install/provision Chromium Edge for all users so sysprep generalize succeeds.
# Per-user Edge without machine provisioning causes 0x80073cf2. Do not launch Edge
# after provisioning — a user session update breaks sysprep on provisioned packages.

function Test-EdgeAppxName {
    param([string]$Name)
    return (
        $Name -like 'Microsoft.MicrosoftEdge.Stable*' -or
        $Name -like 'Microsoft.MicrosoftEdgeDevToolsClient*' -or
        $Name -eq 'Microsoft.MicrosoftEdge' -or
        $Name -like 'Microsoft.MicrosoftEdge_*'
    )
}

function Test-EdgeStableAppxName {
    param([string]$Name)
    return $Name -like 'Microsoft.MicrosoftEdge.Stable*'
}

function Remove-AppxPackageQuiet {
    param(
        [string]$PackageFullName,
        [switch]$AllUsers
    )
    try {
        if ($AllUsers) {
            Remove-AppxPackage -Package $PackageFullName -AllUsers -ErrorAction Stop | Out-Null
        }
        else {
            Remove-AppxPackage -Package $PackageFullName -ErrorAction Stop | Out-Null
        }
        return $true
    }
    catch {
        Write-Warning "Remove-AppxPackage skipped for ${PackageFullName}: $($_.Exception.Message)"
        return $false
    }
}

function Stop-EdgeForSysprep {
    foreach ($name in @('msedge', 'msedgewebview2', 'MicrosoftEdgeUpdate', 'MicrosoftEdgeSH')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    foreach ($svcName in @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Host "Stopping service $svcName"
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-EdgeStablePackageFolder {
    $roots = @(
        (Join-Path $env:ProgramFiles 'WindowsApps')
    )
    if (${env:ProgramFiles(x86)}) {
        $roots += (Join-Path ${env:ProgramFiles(x86)} 'WindowsApps')
    }

    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $folder = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Microsoft.MicrosoftEdge.Stable_*' } |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($folder) {
            return $folder
        }
    }
    return $null
}

function Remove-EdgeUserRegistrations {
    foreach ($pkg in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { Test-EdgeAppxName -Name $_.Name })) {
        Write-Host "Removing Edge user registration (AllUsers): $($pkg.PackageFullName)"
        Remove-AppxPackageQuiet -PackageFullName $pkg.PackageFullName -AllUsers | Out-Null
    }
    foreach ($pkg in @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { Test-EdgeAppxName -Name $_.Name })) {
        Write-Host "Removing Edge user registration (current user): $($pkg.PackageFullName)"
        Remove-AppxPackageQuiet -PackageFullName $pkg.PackageFullName | Out-Null
    }
}

function Remove-EdgeProvisioning {
    foreach ($pkg in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { Test-EdgeAppxName -Name $_.DisplayName })) {
        Write-Host "Removing Edge provisioning: $($pkg.DisplayName)"
        Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue | Out-Null
    }
}

function Install-EdgeStableIfMissing {
    $existing = Get-EdgeStablePackageFolder
    if ($existing) {
        return $existing
    }

    $setup = Join-Path $env:TEMP 'MicrosoftEdgeEnterpriseSetup.exe'
    $url = 'https://go.microsoft.com/fwlink/?linkid=2093438'
    Write-Host "Downloading Edge installer: $url"
    Invoke-WebRequest -Uri $url -OutFile $setup -UseBasicParsing

    Write-Host 'Installing Edge silently (system-level)...'
    $installArgs = @('/silent', '/install', '--system-level')
    $proc = Start-Process -FilePath $setup -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    if ($null -ne $exitCode -and $exitCode -notin 0, 3010) {
        throw "Edge installer exited with code $exitCode"
    }

    Start-Sleep -Seconds 10
    $folder = Get-EdgeStablePackageFolder
    if (-not $folder) {
        throw 'Edge installer finished but Microsoft.MicrosoftEdge.Stable was not found under Program Files\WindowsApps'
    }
    Write-Host "Edge package folder: $($folder.FullName)"
    return $folder
}

function Add-EdgeStableProvisioning {
    param([System.IO.DirectoryInfo]$Folder)

    if (-not (Test-Path -LiteralPath (Join-Path $Folder.FullName 'AppxManifest.xml'))) {
        throw "Edge folder missing AppxManifest.xml: $($Folder.FullName)"
    }

    Write-Host "Provisioning Edge for all users: $($Folder.Name)"
    Add-AppxProvisionedPackage -Online -FolderPath $Folder.FullName -SkipLicense -ErrorAction Stop | Out-Null
}

function Test-EdgeSysprepReady {
    $provisioned = @(
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { Test-EdgeStableAppxName -Name $_.DisplayName }
    )
    if (-not $provisioned) {
        return $false, 'Microsoft.MicrosoftEdge.Stable is not provisioned for all users'
    }

    $userStable = @(
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { Test-EdgeStableAppxName -Name $_.Name }
    )
    if ($userStable) {
        $names = ($userStable | Select-Object -ExpandProperty PackageFullName) -join ', '
        return $false, "Edge Stable has per-user registration (blocks sysprep): $names"
    }

    $legacyUser = @(
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object {
                Test-EdgeAppxName -Name $_.Name -and -not (Test-EdgeStableAppxName -Name $_.Name)
            }
    )
    if ($legacyUser) {
        $names = ($legacyUser | Select-Object -ExpandProperty PackageFullName) -join ', '
        return $false, "Legacy Edge packages still registered per-user: $names"
    }

    return $true, "Edge Stable provisioned ($($provisioned[0].DisplayName)); no per-user Edge registrations"
}

function Ensure-EdgeAppxForSysprep {
    Stop-EdgeForSysprep

    $ready, $readyMsg = Test-EdgeSysprepReady
    if ($ready) {
        Write-Host $readyMsg
        Stop-EdgeForSysprep
        return
    }

    Write-Host "Edge sysprep state needs repair: $readyMsg"

    Remove-EdgeUserRegistrations
    Remove-EdgeProvisioning
    Remove-EdgeUserRegistrations

    $folder = Install-EdgeStableIfMissing
    Add-EdgeStableProvisioning -Folder $folder

    # Installer or provisioning can register Edge for the current admin profile.
    Remove-EdgeUserRegistrations

    $ready, $readyMsg = Test-EdgeSysprepReady
    if (-not $ready) {
        throw "Edge not sysprep-ready after provisioning: $readyMsg"
    }

    Write-Host $readyMsg
    Stop-EdgeForSysprep
}

function Remove-CloudExperienceHostProvisioning {
    foreach ($pkg in Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) {
        if ($pkg.DisplayName -notlike 'Microsoft.Windows.CloudExperienceHost*') {
            continue
        }
        Write-Host "Removing provisioned AppX: $($pkg.DisplayName)"
        Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue | Out-Null
    }
}
