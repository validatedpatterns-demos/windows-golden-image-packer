# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Generalize the image for cloning in OpenShift Virtualization (KubeVirt).
$ErrorActionPreference = 'Stop'

$goldenData = 'C:\ProgramData\GoldenImage'
$generalizeUnattend = 'C:\Windows\Temp\sysprep-generalize.xml'
$oobeUnattend = 'C:\Windows\Temp\sysprep-oobe.xml'
$oobeUnattendPersistent = Join-Path $goldenData 'sysprep-oobe.xml'
$panther = 'C:\Windows\Panther'
$sysprepPanther = 'C:\Windows\System32\Sysprep\Panther'
$diagLog = Join-Path $goldenData 'sysprep-diagnostics.log'
$sysprepStdout = 'C:\Windows\Temp\sysprep-stdout.log'
$sysprepStderr = 'C:\Windows\Temp\sysprep-stderr.log'

function Resolve-OobeUnattendPath {
    if (Test-Path $oobeUnattend) {
        return $oobeUnattend
    }
    if (Test-Path $oobeUnattendPersistent) {
        return $oobeUnattendPersistent
    }
    throw "Missing OOBE unattend (expected $oobeUnattend or $oobeUnattendPersistent). Disk shrink may have removed Temp copies before sysprep; rebuild with current scripts."
}

function Get-LogTail {
    param([string]$Path, [int]$Lines = 80)
    if (-not (Test-Path $Path)) {
        return @("(not found: $Path)")
    }
    return Get-Content -Path $Path -Tail $Lines -ErrorAction SilentlyContinue
}

function Save-SysprepDiagnostics {
    param([string]$Reason)

    New-Item -ItemType Directory -Path $goldenData -Force | Out-Null
    $lines = @(
        "=== sysprep diagnostics ===",
        "Time: $(Get-Date -Format o)",
        "Reason: $Reason",
        ''
    )

    foreach ($dir in @($sysprepPanther, $panther)) {
        foreach ($name in @('setuperr.log', 'setupact.log')) {
            $path = Join-Path $dir $name
            $lines += "=== $path ==="
            $lines += Get-LogTail -Path $path
            $lines += ''
        }
    }

    foreach ($path in @($sysprepStdout, $sysprepStderr)) {
        $lines += "=== $path ==="
        $lines += Get-LogTail -Path $path
        $lines += ''
    }

    $lines | Set-Content -Path $diagLog -Encoding UTF8
    Copy-Item -Path $diagLog -Destination (Join-Path $panther 'sysprep-diagnostics.log') -Force -ErrorAction SilentlyContinue
    Write-Host "Wrote diagnostics to $diagLog"
}

function Write-SysprepDiagnosticLogs {
    foreach ($dir in @($sysprepPanther, $panther)) {
        if (-not (Test-Path $dir)) { continue }
        foreach ($name in @('setuperr.log', 'setupact.log')) {
            $path = Join-Path $dir $name
            if (-not (Test-Path $path)) { continue }
            Write-Host "=== $path ==="
            Get-LogTail -Path $path | ForEach-Object { Write-Host $_ }
        }
    }
    foreach ($path in @($sysprepStdout, $sysprepStderr, $diagLog)) {
        if (-not (Test-Path $path)) { continue }
        Write-Host "=== $path ==="
        Get-LogTail -Path $path | ForEach-Object { Write-Host $_ }
    }
}

function Test-EspPresent {
    $esp = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
        Select-Object -First 1
    if (-not $esp) {
        throw 'EFI system partition not found before sysprep; run 08-convert-mbr-to-uefi.ps1 and 07-repair-uefi-boot.ps1 first.'
    }
}

function Repair-UefiBootIfNeeded {
    $esp = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
        Select-Object -First 1
    if (-not $esp) {
        throw 'EFI system partition not found before sysprep; run 08-convert-mbr-to-uefi.ps1 and 07-repair-uefi-boot.ps1 first.'
    }

    $letter = (Get-Volume -Partition $esp -ErrorAction SilentlyContinue).DriveLetter
    if (-not $letter) {
        Write-Warning 'ESP has no drive letter; skipping pre-sysprep bcdboot (07-repair-uefi-boot.ps1 should have run after mbr2gpt).'
        return
    }

    $efiRoot = "$letter`:\"
    Write-Host "Refreshing UEFI boot store before sysprep: bcdboot $env:SystemRoot /s $efiRoot /f UEFI"
    & bcdboot.exe $env:SystemRoot /s $efiRoot /f UEFI | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "bcdboot before sysprep failed with exit code $LASTEXITCODE"
    }
}

try {
    $clearScript = Join-Path $PSScriptRoot 'clear-autologon.ps1'
    if (Test-Path $clearScript) {
        & $clearScript
    }
    else {
        Write-Warning "clear-autologon.ps1 not found beside sysprep.ps1; image may autologon on first OpenShift boot"
    }

    # SeaBIOS provision pass runs sysprep before OVMF reboot; verify ESP only (not firmware type).
    Test-EspPresent

    $sysprep = 'C:\Windows\System32\Sysprep\sysprep.exe'
    if (-not (Test-Path $sysprep)) {
        throw "Sysprep not found at $sysprep"
    }

    foreach ($dir in @($panther, $sysprepPanther)) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -Path $dir -Filter 'unattend*.xml' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        foreach ($name in @('setupact.log', 'setuperr.log')) {
            $path = Join-Path $dir $name
            if (Test-Path $path) {
                Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $sysprepStatus = 'HKLM:\SYSTEM\Setup\Status\SysprepStatus'
    if (Test-Path $sysprepStatus) {
        Remove-Item -Path $sysprepStatus -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $generalizeUnattend)) {
        throw "Missing $generalizeUnattend (specialize/generalize only - no oobeSystem)"
    }
    $oobeSource = Resolve-OobeUnattendPath

    [void][xml](Get-Content -Path $generalizeUnattend -Raw)
    [void][xml](Get-Content -Path $oobeSource -Raw)

    New-Item -ItemType Directory -Path $panther -Force | Out-Null
    Copy-Item -Path $oobeSource -Destination (Join-Path $panther 'unattend.xml') -Force
    Copy-Item -Path $oobeSource -Destination 'C:\unattend.xml' -Force
    $oobeXml = Get-Content -Path (Join-Path $panther 'unattend.xml') -Raw
    if ($oobeXml -notmatch 'Microsoft-Windows-International-Core') {
        throw 'Panther unattend missing International-Core before sysprep - not sysprep-oobe.xml'
    }
    if ($oobeXml -match '<AutoLogon>[\s\S]*?<Enabled>true</Enabled>') {
        throw 'Panther unattend still has install AutoLogon - replace with sysprep-oobe.xml before sysprep'
    }
    Write-Host "Staged OOBE-only unattend in Panther for first deploy boot"

    if (-not (Test-Path $oobeUnattendPersistent)) {
        throw "Missing $oobeUnattendPersistent (configure-oobe-locale.ps1 must run before sysprep)"
    }

    foreach ($name in @('wuauserv', 'UsoSvc', 'bits', 'dosvc')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        }
    }

    Repair-UefiBootIfNeeded

    . (Join-Path $PSScriptRoot 'remove-sysprep-blocking-appx.ps1')
    Write-Host 'Running last-chance AppX cleanup before sysprep...'
    Remove-SysprepBlockingAppx

    $unattend = $generalizeUnattend
    $sysprepArgs = @('/generalize', '/oobe', '/mode:vm', '/shutdown', "/unattend:$unattend")
    Write-Host ('Running sysprep ' + ($sysprepArgs -join ' '))

    Remove-Item -Path $sysprepStdout, $sysprepStderr -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $sysprep -ArgumentList $sysprepArgs -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $sysprepStdout -RedirectStandardError $sysprepStderr
    $sysprepExit = $proc.ExitCode
    $codeLabel = if ($null -eq $sysprepExit) { 'unknown' } else { "$sysprepExit" }

    if ($null -eq $sysprepExit -or $sysprepExit -ne 0) {
        Write-Host "sysprep.exe exited with code $codeLabel"
        Save-SysprepDiagnostics "sysprep exit $codeLabel"
        Write-SysprepDiagnosticLogs
        throw "sysprep.exe failed (exit $codeLabel). Diagnostics saved to $diagLog; extract with: make extract-sysprep-log IMAGE=<qcow2>"
    }

    Write-Host 'sysprep.exe completed with /shutdown; waiting for guest power-off (do not schedule a second shutdown)'
}
catch {
    if (-not (Test-Path $diagLog)) {
        Save-SysprepDiagnostics $_.Exception.Message
        Write-SysprepDiagnosticLogs
    }
    throw
}
