# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Shared OpenSSH Server install/layout helpers (dot-sourced by install + configure scripts).

function Get-OpenSshCapability {
    Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' }
}

function Get-OpenSshBinDirs {
    @(
        "$env:ProgramFiles\OpenSSH",
        "$env:SystemRoot\System32\OpenSSH"
    ) | Where-Object { Test-Path $_ }
}

function Test-OpenSshServerReady {
    Test-Path 'C:\ProgramData\ssh\sshd_config'
}

function Initialize-OpenSshServerLayout {
    param([scriptblock]$Log = { param($m) Write-Host $m })

    $sshData = 'C:\ProgramData\ssh'
    $config = Join-Path $sshData 'sshd_config'

    if (Test-Path $config) {
        & $Log "sshd_config already present at $config"
        return
    }

    if (-not (Test-Path $sshData)) {
        New-Item -ItemType Directory -Path $sshData -Force | Out-Null
        & $Log "Created $sshData"
    }

    foreach ($dir in (Get-OpenSshBinDirs)) {
        $installScript = Join-Path $dir 'install-sshd.ps1'
        if (Test-Path $installScript) {
            & $Log "Running $installScript"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
            if (Test-Path $config) {
                return
            }
        }

        $defaultConfig = Join-Path $dir 'sshd_config_default'
        if (Test-Path $defaultConfig) {
            & $Log "Copying $defaultConfig to $config"
            Copy-Item -Path $defaultConfig -Destination $config -Force
            return
        }
    }

    $sshd = Get-Command sshd.exe -ErrorAction SilentlyContinue
    if ($sshd) {
        & $Log 'Starting sshd once so Windows generates sshd_config (per Microsoft docs)'
        try {
            Start-Service sshd -ErrorAction Stop
            Start-Sleep -Seconds 5
        } catch {
            & $Log "Start-Service sshd: $_"
        }
        if (Test-Path $config) {
            return
        }
        Stop-Service sshd -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $config)) {
        throw "Could not create sshd_config at $config (OpenSSH binaries or install-sshd.ps1 missing)."
    }
}
