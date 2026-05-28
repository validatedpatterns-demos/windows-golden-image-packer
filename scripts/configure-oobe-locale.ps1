# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Bake en-US locale, install language pack (from Windows ISO or Windows Update), publish OOBE unattend.
param(
    [switch]$SkipLanguagePack
)

$ErrorActionPreference = 'Stop'
$culture = 'en-US'
$logPath = 'C:\Windows\Temp\configure-oobe-locale.log'
$pantherLog = 'C:\Windows\Panther\configure-oobe-locale.log'
$goldenData = 'C:\ProgramData\GoldenImage'
Start-Transcript -Path $logPath -Force | Out-Null

function Clear-UnattendProcessedState {
    foreach ($path in @(
            'HKLM:\SYSTEM\Setup\Status\SysprepStatus',
            'HKLM:\SYSTEM\Setup\Status\UnattendPasses'
        )) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Cleared $path"
        }
    }
}

function Publish-OobeUnattend {
    $src = 'C:\Windows\Temp\sysprep-oobe.xml'
    if (-not (Test-Path $src)) {
        throw "Missing $src (Packer must upload sysprep-oobe.xml before this script runs)"
    }

    [void][xml](Get-Content -Path $src -Raw)

    New-Item -ItemType Directory -Path $goldenData -Force | Out-Null
    Copy-Item -Path $src -Destination (Join-Path $goldenData 'sysprep-oobe.xml') -Force
    Write-Host "Staged OOBE unattend in $goldenData (survives disk shrink)"

    $pantherDir = 'C:\Windows\Panther'
    New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
    Get-ChildItem -Path $pantherDir -Filter 'unattend*.xml' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $dest = Join-Path $pantherDir 'unattend.xml'
    Copy-Item -Path $src -Destination $dest -Force
    Copy-Item -Path $src -Destination 'C:\unattend.xml' -Force
    Write-Host "Published OOBE unattend: $dest"

    $xml = Get-Content -Path $dest -Raw
    if ($xml -notmatch 'Microsoft-Windows-International-Core') {
        throw "Published unattend is missing Microsoft-Windows-International-Core"
    }
    if ($xml -match 'pass="oobeSystem" wasPassProcessed="true"') {
        throw 'Published unattend still marked oobeSystem wasPassProcessed=true (install autounattend?)'
    }
}

function Publish-OobeInfoDefaults {
    $src = 'C:\Windows\Temp\oobe-info-defaults.xml'
    if (-not (Test-Path $src)) {
        Write-Warning "oobe-info-defaults.xml not staged at $src"
        return
    }

    $infoDir = 'C:\Windows\System32\Oobe\Info'
    New-Item -ItemType Directory -Path $infoDir -Force | Out-Null
    Copy-Item -Path $src -Destination (Join-Path $infoDir 'oobe.xml') -Force
    $langDir = Join-Path $infoDir 'Default\1033'
    New-Item -ItemType Directory -Path $langDir -Force | Out-Null
    Copy-Item -Path $src -Destination (Join-Path $langDir 'oobe.xml') -Force
    Write-Host 'Published Oobe\Info\oobe.xml defaults (en-US / US)'
}

function Get-WindowsIsoDriveLetter {
    $isoPath = $env:WINDOWS_ISO_PATH
    if (-not $isoPath -or -not (Test-Path $isoPath)) {
        return $null
    }

    $existing = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        Select-Object -First 1
    if ($existing) {
        return $existing.DriveLetter
    }

    $mounted = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $letter = ($mounted | Get-Volume | Where-Object { $_.DriveLetter }).DriveLetter
    return $letter
}

function Install-EnUsLanguagePack {
    $dism = "$env:Windir\System32\dism.exe"
    $capName = 'Language.LanguagePack~~~en-US~0.0.1.0'

    $letter = Get-WindowsIsoDriveLetter
    if ($letter) {
        $sources = @(
            "${letter}:\sources\langpacks",
            "${letter}:\sources",
            "${letter}:\x64\langpacks"
        )
        foreach ($src in $sources) {
            if (-not (Test-Path $src)) { continue }
            Write-Host "DISM Add-Capability from ISO source: $src"
            & $dism /Online /Add-Capability /CapabilityName:$capName /LimitAccess /Source:$src 2>&1 | Out-Host
            if ($LASTEXITCODE -eq 0) {
                return
            }
        }
        Write-Warning "DISM from ISO sources failed (exit $LASTEXITCODE); trying online capability store"
    }

    if (Get-Command Install-Language -ErrorAction SilentlyContinue) {
        Write-Host "Install-Language $culture -CopyToSettings"
        Install-Language -Language $culture -CopyToSettings
        if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
        }
        return
    }

    $caps = Get-WindowsCapability -Online -ErrorAction Stop |
        Where-Object { $_.Name -match 'Language\.LanguagePack.*en-us' -and $_.State -ne 'Installed' }
    foreach ($cap in $caps) {
        Write-Host "Add-WindowsCapability: $($cap.Name)"
        Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
    }
    # Set-AllIntl does not accept /QuietNoRestart on Server 2022 (DISM error 87).
    & $dism /Online /Set-AllIntl:$culture 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "DISM Set-AllIntl exited $LASTEXITCODE (Set-Win* locale was already applied above)"
    }
}

function Ensure-RegistryKey {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and $parent -ne $Path -and -not (Test-Path -LiteralPath $parent)) {
        Ensure-RegistryKey -Path $parent
    }
    New-Item -Path $Path -Force | Out-Null
}

function Set-HideOobeLanguagePageRegistry {
    # Align with setup.exe LanguagePack_WriteOfflineHives (see setupact.log during install).
    # Do not New-Item HKLM:\SYSTEM\Setup — it already exists; -Force tries to replace the hive branch.
    $setup = 'HKLM:\SYSTEM\Setup'
    if (Test-Path -LiteralPath $setup) {
        Set-ItemProperty -LiteralPath $setup -Name 'SystemSetupInProgress' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $setup -Name 'SetupType' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    } else {
        Write-Warning "Registry path $setup missing; skipping SetupType keys"
    }

    $mui = 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\Settings'
    Ensure-RegistryKey -Path $mui
    Set-ItemProperty -Path $mui -Name 'UILanguage' -Value 'en-US' -Type String -Force
    Set-ItemProperty -Path $mui -Name 'PreferredUILanguages' -Value @('en-US') -Type MultiString -Force -ErrorAction SilentlyContinue
}

function Set-EnUsIntlRegistry {
    $nlsLang = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language'
    Ensure-RegistryKey -Path $nlsLang
    Set-ItemProperty -Path $nlsLang -Name 'InstallLanguage' -Value '0409' -Type String
    Set-ItemProperty -Path $nlsLang -Name 'Default' -Value '0409' -Type String

    $nlsLocale = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Locale'
    Ensure-RegistryKey -Path $nlsLocale
    Set-ItemProperty -Path $nlsLocale -Name 'Default' -Value '00000409' -Type String

    $oobeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OOBE'
    Ensure-RegistryKey -Path $oobeKey
    Set-ItemProperty -Path $oobeKey -Name 'SetupDisplayedProductKey' -Value 1 -Type DWord -ErrorAction SilentlyContinue
}

function Set-PreSysprepAccountPolicy {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & net.exe user Administrator /logonpasswordchg:no 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "net user Administrator /logonpasswordchg:no exited $LASTEXITCODE"
        }

        $admin = Get-CimInstance -ClassName Win32_UserAccount -Filter "Name='Administrator' and LocalAccount=True" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($admin) {
            Set-CimInstance -InputObject $admin -Property @{ PasswordExpires = $false } -ErrorAction SilentlyContinue | Out-Null
        } else {
            & wmic.exe useraccount where "name='Administrator'" set PasswordExpires=FALSE 2>&1 | Out-Host
        }

        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '0' -Type String -Force
        foreach ($valueName in @('DefaultPassword', 'DefaultUserName')) {
            Remove-ItemProperty -LiteralPath $winlogon -Name $valueName -ErrorAction SilentlyContinue
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

try {
    Set-WinUILanguageOverride -Language $culture
    Set-WinUserLanguageList $culture -Force
    Set-WinSystemLocale $culture
    Set-Culture $culture
    Set-WinHomeLocation -GeoId 244 | Out-Null
}
catch {
    Write-Warning "Set-Win* locale cmdlets failed: $_"
}

if (-not $SkipLanguagePack) {
    Install-EnUsLanguagePack
}

Set-EnUsIntlRegistry
Set-HideOobeLanguagePageRegistry
Clear-UnattendProcessedState
Set-PreSysprepAccountPolicy
Publish-OobeInfoDefaults
Publish-OobeUnattend

Write-Host 'configure-oobe-locale.ps1 complete'
Stop-Transcript | Out-Null

# Survives 06-shrink-disk.ps1 (Temp logs are removed) and is readable from the golden qcow2 on the host.
New-Item -ItemType Directory -Path (Split-Path $pantherLog) -Force | Out-Null
Copy-Item -Path $logPath -Destination $pantherLog -Force
Write-Host "Copied log to $pantherLog"
