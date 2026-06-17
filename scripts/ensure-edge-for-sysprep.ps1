# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Install/provision Chromium Edge for all users so sysprep generalize succeeds.
# Per-user Edge without machine provisioning causes 0x80073cf2. Do not launch Edge
# after provisioning — a user session update breaks sysprep on provisioned packages.

function Get-TargetWindowsServerVersion {
    switch ($env:WINDOWS_VERSION) {
        '2025' { return '2025' }
        '2022' { return '2022' }
    }

    $caption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    if ($caption -match '2025') {
        return '2025'
    }
    if ($caption -match '2022') {
        return '2022'
    }

    return '2022'
}

function Test-EdgeAppxName {
    param([string]$Name)
    return (
        $Name -like 'Microsoft.MicrosoftEdge.Stable*' -or
        $Name -like 'Microsoft.MicrosoftEdgeDevToolsClient*' -or
        $Name -eq 'Microsoft.MicrosoftEdge' -or
        $Name -like 'Microsoft.MicrosoftEdge_*'
    )
}

function Test-EdgeSysprepBlockingLegacyAppxName {
    param([string]$Name)
    if (Test-EdgeStableAppxName -Name $Name) {
        return $false
    }
    # Server 2025 Win32 Edge often leaves DevToolsClient registered per-user after
    # Remove-AppxPackage -AllUsers; it is not a legacy browser and does not block sysprep.
    # Keep 2022 on the original strict path (DevToolsClient must be removed).
    if ($Name -like 'Microsoft.MicrosoftEdgeDevToolsClient*') {
        return (Get-TargetWindowsServerVersion) -ne '2025'
    }
    return (
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

function Get-EdgeStableProvisionedPackages {
    @(
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-EdgeStableAppxName -Name $_.DisplayName) -or
                (Test-EdgeStableAppxName -Name $_.PackageName)
            }
    )
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
    foreach ($pkg in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Microsoft.MicrosoftEdgeDevToolsClient*' })) {
        Write-Host "Removing Edge DevTools provisioning: $($pkg.DisplayName)"
        Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue | Out-Null
    }
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

function Get-EdgeEnterpriseMsiUrl {
    $api = 'https://edgeupdates.microsoft.com/api/products?channel=Stable&platform=Windows&arch=x64'
    Write-Host "Resolving latest Edge enterprise MSI from $api"
    $payload = Invoke-RestMethod -Uri $api -UseBasicParsing -ErrorAction Stop

    $release = @(
        foreach ($product in @($payload)) {
            foreach ($entry in @($product.Releases)) {
                if ($entry.Platform -eq 'Windows' -and $entry.Architecture -eq 'x64') {
                    $entry
                }
            }
        }
    ) | Select-Object -First 1

    if (-not $release) {
        throw 'Edge update API returned no Windows x64 release'
    }

    $msi = @($release.Artifacts | Where-Object { $_.ArtifactName -eq 'msi' } | Select-Object -First 1)
    if (-not $msi -or -not $msi.Location) {
        throw 'Edge update API returned no enterprise MSI artifact for Windows x64'
    }

    Write-Host "Edge enterprise MSI: version $($release.ProductVersion)"
    return [string]$msi.Location
}

function Find-StagedEdgeEnterpriseMsi {
    $name = 'MicrosoftEdgeEnterpriseX64.msi'
    $roots = @(
        'C:\Windows\Temp',
        'C:\Windows\Temp\drivers',
        'C:\Windows\Temp\virtio-drivers'
    )

    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } |
        ForEach-Object {
            $drive = "$($_.DriveLetter):"
            $roots += $drive
            $roots += (Join-Path $drive 'drivers')
        }

    foreach ($root in ($roots | Select-Object -Unique)) {
        $path = Join-Path $root $name
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}

function Resolve-EdgeEnterpriseMsiPath {
    $msiPath = Join-Path $env:TEMP 'MicrosoftEdgeEnterpriseX64.msi'
    if (Test-Path -LiteralPath $msiPath) {
        return $msiPath
    }

    $staged = Find-StagedEdgeEnterpriseMsi
    if ($staged) {
        Write-Host "Using staged Edge enterprise MSI: $staged"
        Copy-Item -LiteralPath $staged -Destination $msiPath -Force
        return $msiPath
    }

    $url = Get-EdgeEnterpriseMsiUrl
    Write-Host "Downloading Edge enterprise MSI: $url"
    Invoke-WebRequest -Uri $url -OutFile $msiPath -UseBasicParsing
    return $msiPath
}

function Expand-EdgeEnterpriseMsi {
    param(
        [string]$MsiPath,
        [string]$Dest
    )

    if (Test-Path -LiteralPath $Dest) {
        Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null

    Write-Host "Extracting Edge enterprise MSI: $MsiPath -> $Dest"
    $args = @('/a', $MsiPath, '/qn', "TARGETDIR=$Dest")
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $args -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    if ($null -ne $exitCode -and $exitCode -notin 0, 3010, 1641) {
        throw "Edge MSI administrative install exited with code $exitCode"
    }
}

function Find-EdgeEnterpriseSetupExe {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 40MB })

    if (-not $candidates) {
        return $null
    }

    $preferred = @(
        $candidates | Where-Object { $_.Name -match 'MicrosoftEdge|EdgeInstaller|setup' } | Sort-Object Length -Descending
        $candidates | Sort-Object Length -Descending
    ) | Select-Object -First 1

    return $preferred.FullName
}

function Find-EdgeAppxBundleInTree {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    $patterns = @('*.appxbundle', '*.msixbundle', '*.appx', '*.msix')
    $candidates = @()
    foreach ($pattern in $patterns) {
        $candidates += @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue)
    }
    if (-not $candidates) {
        return $null
    }

    $preferred = @(
        $candidates | Where-Object { $_.Name -match 'x64|amd64' } | Sort-Object FullName -Descending
        $candidates | Where-Object { $_.Name -match 'neutral' } | Sort-Object FullName -Descending
        $candidates | Sort-Object FullName -Descending
    ) | Select-Object -First 1

    return $preferred.FullName
}

function Get-EdgeAppxBundleSearchRoots {
    param([string[]]$ExtraRoots = @())

    $roots = @(
        (Join-Path $env:TEMP 'edge-msi-admin')
        (Join-Path $env:ProgramFiles 'Microsoft\EdgeUpdate\Download')
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate\Download')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\EdgeUpdate\Download')
    )
    $roots += $ExtraRoots
    return @($roots | Where-Object { $_ } | Select-Object -Unique)
}

function Install-EdgeEnterpriseMsiDirect {
    param([string]$MsiPath)

    $logPath = Join-Path $env:TEMP 'edge-enterprise-install.log'
    Write-Host 'Installing Edge enterprise MSI directly (fallback)...'
    $msiArgs = @(
        '/i', $MsiPath,
        '/qn', '/norestart',
        'ALLUSERS=1',
        'DONOTLAUNCHEDGE=true',
        'DONOTCREATEDESKTOPSHORTCUT=true',
        'DONOTCREATETASKBARSHORTCUT=true',
        '/L*v', $logPath
    )
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    if ($null -ne $exitCode -and $exitCode -notin 0, 3010, 1641) {
        throw "Edge MSI install exited with code $exitCode (see $logPath)"
    }
}

function Install-EdgeEnterpriseFromMsi {
    param([string]$MsiPath)

    $extractRoot = Join-Path $env:TEMP 'edge-msi-admin'
    Expand-EdgeEnterpriseMsi -MsiPath $MsiPath -Dest $extractRoot

    $setup = Find-EdgeEnterpriseSetupExe -Root $extractRoot
    if ($setup) {
        Write-Host "Installing Edge from extracted enterprise setup: $setup"
        $setupArgs = @(
            '/silent',
            '/install',
            '/installsource=enterprisemsi',
            '/system-level'
        )
        $proc = Start-Process -FilePath $setup -ArgumentList $setupArgs -Wait -PassThru -NoNewWindow
        $exitCode = $proc.ExitCode
        if ($null -ne $exitCode -and $exitCode -notin 0, 3010, 1641) {
            throw "Edge enterprise setup exited with code $exitCode"
        }
        return
    }

    Write-Warning 'Edge setup.exe not found in MSI extract; falling back to msiexec /i'
    Install-EdgeEnterpriseMsiDirect -MsiPath $MsiPath
}

function Wait-EdgeStableProvisioned {
    param([int]$TimeoutSeconds = 180)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Get-EdgeStableProvisionedPackages) {
            return $true
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Add-EdgeStableProvisioningFromBundle {
    param([string]$BundlePath)

    if (-not (Test-Path -LiteralPath $BundlePath)) {
        throw "Edge AppX bundle not found: $BundlePath"
    }

    Write-Host "Provisioning Edge for all users from bundle: $BundlePath"
    try {
        Add-AppxProvisionedPackage -Online -PackagePath $BundlePath -SkipLicense -ErrorAction Stop | Out-Null
        return
    }
    catch {
        Write-Warning "Add-AppxProvisionedPackage failed: $($_.Exception.Message)"
    }

    $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    Write-Host "Trying DISM Add-ProvisionedAppxPackage for $BundlePath"
    $dismArgs = @(
        '/Online',
        '/Add-ProvisionedAppxPackage',
        "/PackagePath:$BundlePath",
        '/SkipLicense',
        '/Region:all'
    )
    $proc = Start-Process -FilePath $dism -ArgumentList $dismArgs -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "DISM Add-ProvisionedAppxPackage exited with code $exitCode for $BundlePath"
    }
}

function Test-EdgeWin32Installed {
    foreach ($path in @(
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        )) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return $null
}

function Remove-EdgePerUserRegistrationsIfPresent {
    $userPkgs = @(
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { Test-EdgeAppxName -Name $_.Name }
    )
    if (-not $userPkgs) {
        return
    }
    Remove-EdgeUserRegistrations
}

function Add-EdgeStableProvisioningIfNeeded {
    param([string]$MsiPath)

    if (Get-EdgeStableProvisionedPackages) {
        Write-Host 'Edge Stable already provisioned'
        return $true
    }

    $searchRoots = Get-EdgeAppxBundleSearchRoots
    foreach ($root in $searchRoots) {
        $bundle = Find-EdgeAppxBundleInTree -Root $root
        if ($bundle) {
            Add-EdgeStableProvisioningFromBundle -BundlePath $bundle
            if (Get-EdgeStableProvisionedPackages) {
                return $true
            }
        }
    }

    if (Invoke-EdgeUpdateSystemInstall) {
        Write-Host 'EdgeUpdate system install provisioned Stable'
        return $true
    }

    Write-Warning @(
        'Edge AppX provisioning was not available on this image (common on Windows Server).'
        'Will rely on Win32 Edge install if present.'
        "MSI path: $MsiPath"
    ) -join ' '
    return $false
}

function Get-EdgeSysprepDiagnostics {
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { Test-EdgeAppxName -Name $_.DisplayName })
    $user = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { Test-EdgeAppxName -Name $_.Name })
    $win32 = Test-EdgeWin32Installed

    $lines = @('Provisioned Edge packages:')
    if ($prov) {
        $lines += @($prov | ForEach-Object { "  $($_.DisplayName)" })
    }
    else {
        $lines += '  (none)'
    }

    $lines += 'Per-user Edge packages:'
    if ($user) {
        $lines += @($user | ForEach-Object { "  $($_.PackageFullName)" })
    }
    else {
        $lines += '  (none)'
    }

    $lines += 'Win32 Edge binary:'
    if ($win32) {
        $lines += "  $win32"
    }
    else {
        $lines += '  (none)'
    }

    return ($lines -join [Environment]::NewLine)
}

function Invoke-EdgeUpdateSystemInstall {
    $updateExe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe'
    if (-not (Test-Path -LiteralPath $updateExe)) {
        return $false
    }

    Write-Host "Triggering EdgeUpdate system install: $updateExe"
    $updateArgs = '/silent /install appguid={56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}&appname=Microsoft%20Edge&needsadmin=True'
    $proc = Start-Process -FilePath $updateExe -ArgumentList $updateArgs -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    if ($null -ne $exitCode -and $exitCode -notin 0, 3010, 1641) {
        Write-Warning "EdgeUpdate install exited with code $exitCode"
    }

    Start-Sleep -Seconds 15
    return [bool](Get-EdgeStableProvisionedPackages)
}

function Test-EdgeSysprepReady {
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
            Where-Object { Test-EdgeSysprepBlockingLegacyAppxName -Name $_.Name }
    )
    if ($legacyUser) {
        $names = ($legacyUser | Select-Object -ExpandProperty PackageFullName) -join ', '
        return $false, "Legacy Edge packages still registered per-user: $names"
    }

    $devToolsOnly = @(
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Microsoft.MicrosoftEdgeDevToolsClient*' }
    )
    if ($devToolsOnly -and (Get-TargetWindowsServerVersion) -eq '2025' -and (Test-EdgeWin32Installed)) {
        $names = ($devToolsOnly | Select-Object -ExpandProperty PackageFullName) -join ', '
        Write-Warning "Edge DevToolsClient still registered per-user (non-blocking on Server 2025 with Win32 Edge): $names"
    }

    $provisioned = Get-EdgeStableProvisionedPackages
    if ($provisioned) {
        return $true, "Edge Stable provisioned ($($provisioned[0].DisplayName)); no per-user Edge registrations"
    }

    $win32 = Test-EdgeWin32Installed
    if ($win32) {
        return $true, "Edge Win32 installed ($win32); no AppX registrations (sysprep-safe on Server)"
    }

    return $false, 'Edge not installed (no Win32 msedge.exe and no provisioned AppX)'
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

    Remove-EdgePerUserRegistrationsIfPresent

    $ready, $readyMsg = Test-EdgeSysprepReady
    if ($ready) {
        Write-Host $readyMsg
        Stop-EdgeForSysprep
        return
    }

    $provisioned = Get-EdgeStableProvisionedPackages
    $win32 = Test-EdgeWin32Installed
    if (-not $provisioned -and -not $win32) {
        $msiPath = Resolve-EdgeEnterpriseMsiPath
        Install-EdgeEnterpriseFromMsi -MsiPath $msiPath

        if (-not (Wait-EdgeStableProvisioned)) {
            Write-Host 'Edge AppX auto-provision not detected; trying optional AppX bundle provisioning'
            Add-EdgeStableProvisioningIfNeeded -MsiPath $msiPath | Out-Null
        }
        else {
            Write-Host 'Edge setup provisioned Stable AppX for all users'
        }
    }
    elseif (-not $provisioned -and $win32) {
        Write-Host "Keeping existing Win32 Edge install: $win32"
    }

    # Only strip per-user AppX drift. Do not deprovision a working AppX catalog.
    Remove-EdgePerUserRegistrationsIfPresent

    $ready, $readyMsg = Test-EdgeSysprepReady
    if (-not $ready) {
        $diag = Get-EdgeSysprepDiagnostics
        throw "Edge not sysprep-ready after provisioning: $readyMsg`n$diag"
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
