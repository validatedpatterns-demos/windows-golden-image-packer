# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Generalize the image for cloning in OpenShift Virtualization (KubeVirt).
param(
    [switch]$ProvisionerRun
)

$ErrorActionPreference = 'Stop'

if (-not $ProvisionerRun -and $env:SYSPREP_PROVISIONER_RUN -eq '1') {
    $ProvisionerRun = $true
}

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

function Restore-OobeUnattend {
    param(
        [string]$Reason
    )

    $oobeSource = Resolve-OobeUnattendPath

    foreach ($dir in @($panther, $sysprepPanther)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Get-ChildItem -Path $dir -Filter 'unattend*.xml' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Copy-Item -Path $oobeSource -Destination (Join-Path $panther 'unattend.xml') -Force
    Copy-Item -Path $oobeSource -Destination 'C:\unattend.xml' -Force
    if (Test-Path $sysprepPanther) {
        Copy-Item -Path $oobeSource -Destination (Join-Path $sysprepPanther 'unattend.xml') -Force
    }

    $oobeXml = Get-Content -Path (Join-Path $panther 'unattend.xml') -Raw
    if ($oobeXml -notmatch 'Microsoft-Windows-International-Core') {
        throw "Panther unattend after restore ($Reason) is missing Microsoft-Windows-International-Core"
    }
    if ($oobeXml -match 'pass="generalize"') {
        throw "Panther unattend after restore ($Reason) is still sysprep-generalize.xml"
    }
    Write-Host "Restored OOBE-only unattend ($Reason)"
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

function Wait-SysprepWithProgress {
    param(
        [string]$SysprepPath,
        [string[]]$SysprepArgs,
        [int]$TimeoutMinutes = 45
    )

    Remove-Item -Path $sysprepStdout, $sysprepStderr -Force -ErrorAction SilentlyContinue

    $shutdownGuard = Start-SysprepShutdownGuard
    try {
        $proc = Start-Process -FilePath $SysprepPath -ArgumentList $SysprepArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $sysprepStdout -RedirectStandardError $sysprepStderr

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $started = Get-Date
        $lastSetupActSize = 0L
        $lastLogAt = [datetime]::MinValue
        $procExitAt = $null

        while ((Get-Date) -lt $deadline) {
            Cancel-PendingGuestShutdown

            if (Test-SysprepGeneralizeSucceeded) {
                Start-Sleep -Seconds 2
                break
            }

            if ($proc.HasExited -and -not $procExitAt) {
                $procExitAt = Get-Date
                $elapsed = (($procExitAt - $started).TotalSeconds)
                Write-Host "sysprep.exe parent process exited after ${elapsed}s (exit $($proc.ExitCode)); waiting for Sysprep_succeeded.tag until timeout..."
            }

            foreach ($dir in @($sysprepPanther, $panther)) {
                $setupAct = Join-Path $dir 'setupact.log'
                if (-not (Test-Path $setupAct)) { continue }
                $size = (Get-Item -LiteralPath $setupAct).Length
                if ($size -gt $lastSetupActSize) {
                    $lastSetupActSize = $size
                    if (((Get-Date) - $lastLogAt).TotalSeconds -ge 15) {
                        $lastLogAt = Get-Date
                        Write-Host "=== tail $setupAct ==="
                        Get-LogTail -Path $setupAct -Lines 8 | ForEach-Object { Write-Host $_ }
                    }
                }
            }

            Start-Sleep -Seconds 2
        }

        if (-not (Test-SysprepGeneralizeSucceeded)) {
            if ((Get-Date) -gt $deadline) {
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
                Save-SysprepDiagnostics "sysprep timeout after ${TimeoutMinutes}m"
                Write-SysprepDiagnosticLogs
                throw "sysprep.exe did not finish within ${TimeoutMinutes} minutes. Check VNC (./scripts/show-packer-console.sh) and $diagLog"
            }
        }

        Cancel-PendingGuestShutdown
        $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { $null }
        if (Test-SysprepGeneralizeSucceeded) {
            return 0
        }
        return Resolve-SysprepProcessExit -ExitCode $exitCode
    }
    finally {
        try {
            Stop-SysprepShutdownGuard -GuardProcess $shutdownGuard
        }
        catch {
            Write-Warning "shutdown guard cleanup: $($_.Exception.Message)"
        }
    }
}

function Invoke-GuestShutdown {
    Write-Host 'Forcing guest shutdown for Packer (sysprep runs without /shutdown so OOBE unattend can be restored first).'
    & "$env:SystemRoot\System32\shutdown.exe" /s /t 0 /f
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "shutdown.exe exit $LASTEXITCODE; trying Stop-Computer -Force"
        Stop-Computer -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 5
    Write-Host 'Shutdown requested; Packer will wait for the VM to power off.'
}

function Remove-PhantomVirtioBootDevices {
    # Phantom VirtIO block/SCSI devices from enable-virtio-*-boot-load.ps1 can block generalize.
    $enum = & pnputil.exe /enum-devices /class SCSIAdapter 2>&1
    foreach ($line in $enum) {
        if ($line -notmatch 'Instance ID:\s+(ROOT\\.*)') { continue }
        $instanceId = $Matches[1].Trim()
        if ($instanceId -match 'VIOSTORBOOT|VIOSCSIBOOT|VIOSTOR|VIOSCSI') {
            Write-Host "Removing phantom VirtIO adapter before sysprep: $instanceId"
            & pnputil.exe /remove-device $instanceId 2>&1 | Out-Host
        }
    }
}

function Test-SysprepNotAlreadyGeneralized {
    $key = 'HKLM:\SYSTEM\Setup\Status\SysprepStatus'
    if (-not (Test-Path $key)) { return }
    $state = (Get-ItemProperty -Path $key -Name 'GeneralizationState' -ErrorAction SilentlyContinue).GeneralizationState
    if ($null -ne $state -and [int]$state -ge 7) {
        throw "Sysprep already completed on this disk (GeneralizationState=$state). Use a fresh provision-prep qcow2 from MBR pass, not a sysprepped or work/ disk."
    }
}

function Cancel-PendingGuestShutdown {
    # shutdown /a exits 1116 when nothing is pending; under $ErrorActionPreference Stop that
    # stderr must not terminate sysprep.ps1 while polling during /generalize.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & "$env:SystemRoot\System32\shutdown.exe" /a *>$null
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Start-SysprepShutdownGuard {
    # Use a hidden child process, not Start-Job. Packer WinRM can deserialize job objects so
    # Stop-Job/Remove-Job -Force fail with "parameter name 'Force'" and abort before post-sysprep steps.
    $guardScript = Join-Path $env:TEMP 'sysprep-shutdown-guard.ps1'
    @'
$ErrorActionPreference = 'SilentlyContinue'
while ($true) {
    & "$env:SystemRoot\System32\shutdown.exe" /a *>$null
    Start-Sleep -Milliseconds 400
}
'@ | Set-Content -LiteralPath $guardScript -Encoding UTF8
    return Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $guardScript) `
        -PassThru -WindowStyle Hidden
}

function Stop-SysprepShutdownGuard {
    param($GuardProcess)
    if (-not $GuardProcess) { return }
    try {
        Stop-Process -Id $GuardProcess.Id -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Could not stop sysprep shutdown guard: $($_.Exception.Message)"
    }
}

function Stage-VirtioDriversForSysprep {
    $dest = Join-Path $goldenData 'virtio-drivers'
    foreach ($src in @('C:\Windows\Temp\drivers', 'C:\Windows\Temp\virtio-drivers')) {
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force
        Write-Host "Staged VirtIO drivers for post-sysprep restore at $dest"
        return
    }
    Write-Warning 'VirtIO driver tree not found in Temp; restore-virtio-boot-after-sysprep.ps1 needs staged drivers under ProgramData\GoldenImage.'
}

function Test-SysprepGeneralizeSucceeded {
    if (Test-Path -LiteralPath 'C:\Windows\System32\Sysprep\Sysprep_succeeded.tag') {
        return $true
    }
    foreach ($dir in @($sysprepPanther, $panther)) {
        $setupAct = Join-Path $dir 'setupact.log'
        if (-not (Test-Path -LiteralPath $setupAct)) { continue }
        $tail = (Get-Content -Path $setupAct -Tail 30 -ErrorAction SilentlyContinue) -join "`n"
        if ($tail -match 'Sysprep_succeeded\.tag') {
            return $true
        }
    }
    return $false
}

function Wait-ForSysprepSucceededTag {
    param([int]$TimeoutSeconds = 90)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Cancel-PendingGuestShutdown
        if (Test-SysprepGeneralizeSucceeded) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Resolve-SysprepProcessExit {
    param([object]$ExitCode)

    Cancel-PendingGuestShutdown
    Start-Sleep -Milliseconds 500
    Cancel-PendingGuestShutdown

    if ($null -eq $ExitCode) {
        return 1
    }
    if ([int]$ExitCode -eq 0) {
        return 0
    }
    if ([int]$ExitCode -ne 0 -and (Wait-ForSysprepSucceededTag)) {
        Write-Warning "sysprep.exe returned $ExitCode but Sysprep_succeeded.tag is present (OVMF BCD EFI export noise); treating generalize as successful."
        return 0
    }
    return [int]$ExitCode
}

function Test-SysprepGeneralizeSucceededDespiteExit {
    param([object]$ExitCode)

    if ($null -eq $ExitCode -or [int]$ExitCode -eq 0) {
        return $false
    }
    # Sysprep writes Sysprep_succeeded.tag only after generalize completes. Non-zero exit with
    # that tag is the usual OVMF/QEMU BCD EFI export noise (setuperr), not a failed generalize.
    return Test-SysprepGeneralizeSucceeded
}

function Get-WindowsBootPartitionSpec {
    if (Test-Path 'C:\Windows') {
        return 'C:'
    }
    $vol = Get-Partition -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows") } |
        Select-Object -First 1
    if ($vol -and $vol.DriveLetter) {
        return "$($vol.DriveLetter):"
    }
    throw 'Could not determine Windows boot partition letter for post-sysprep BCD repair'
}

function Repair-GeneralizedBcdStore {
    $part = Get-WindowsBootPartitionSpec
    Write-Host "Repairing generalized BCD store for first deploy boot (partition=$part)"
    foreach ($id in @('{default}', '{current}')) {
        & bcdedit.exe /set $id device "partition=$part" 2>&1 | Out-Host
        & bcdedit.exe /set $id osdevice "partition=$part" 2>&1 | Out-Host
    }
    & bcdedit.exe /set '{bootmgr}' device "partition=$part" 2>&1 | Out-Host
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

    Test-SysprepNotAlreadyGeneralized

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

    Restore-OobeUnattend -Reason 'before sysprep generalize'

    if (-not (Test-Path $oobeUnattendPersistent)) {
        throw "Missing $oobeUnattendPersistent (configure-oobe-locale.ps1 must run before sysprep)"
    }

    foreach ($name in @('wuauserv', 'UsoSvc', 'bits', 'dosvc', 'edgeupdate', 'edgeupdatem')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-PhantomVirtioBootDevices

    . (Join-Path $PSScriptRoot 'remove-sysprep-blocking-appx.ps1')
    if (Get-Command Test-EdgeSysprepReady -ErrorAction SilentlyContinue) {
        $ready, $readyMsg = Test-EdgeSysprepReady
        if ($ready) {
            Write-Host "Edge sysprep-ready: $readyMsg (skipping full Edge reprovision)"
            Stop-EdgeForSysprep
        }
        else {
            Write-Host "Edge not sysprep-ready ($readyMsg); running full Edge prep..."
            Remove-SysprepBlockingAppx
        }
    }
    else {
        Write-Host 'Ensuring Edge is provisioned for all users and stopping browser processes...'
        Remove-SysprepBlockingAppx
    }

    Stage-VirtioDriversForSysprep

    $unattend = $generalizeUnattend
    # /quit: do not reboot or shut down after generalize — post-sysprep virtio restore and OOBE
    # unattend must run while WinRM is still up. Without /quit, sysprep calls InitiateSystemShutdownEx
    # on success and Packer sees exit 16001 before restore-virtio-boot-after-sysprep.ps1 runs.
    $timeoutMin = 45
    if ($env:SYSPREP_TIMEOUT_MINUTES -match '^\d+$') {
        $timeoutMin = [int]$env:SYSPREP_TIMEOUT_MINUTES
    }
    # /quiet suppresses confirmation dialogs that can block sysprep headless under QEMU.
    $sysprepArgs = @('/generalize', '/oobe', '/mode:vm', '/quiet', '/quit', "/unattend:$unattend")
    Write-Host ('Running sysprep ' + ($sysprepArgs -join ' ') + " (timeout ${timeoutMin}m, setupact.log tailed every 15s while running)")

    $sysprepExit = Wait-SysprepWithProgress -SysprepPath $sysprep -SysprepArgs $sysprepArgs -TimeoutMinutes $timeoutMin
    $codeLabel = if ($null -eq $sysprepExit) { 'unknown' } else { "$sysprepExit" }

    if ($null -eq $sysprepExit -or $sysprepExit -ne 0) {
        if (Test-SysprepGeneralizeSucceededDespiteExit -ExitCode $sysprepExit) {
            Write-Warning "sysprep.exe exit ${codeLabel} with Sysprep_succeeded.tag (OVMF cannot export BCD to EFI NVRAM; BCD store generalize succeeded). Continuing post-sysprep steps."
            $global:LASTEXITCODE = 0
        }
        else {
            Write-Host "sysprep.exe exited with code $codeLabel"
            Save-SysprepDiagnostics "sysprep exit $codeLabel"
            Write-SysprepDiagnosticLogs
            Write-Host "Common causes of exit ${codeLabel}: Appx/Edge (see setuperr.log), sysprep already run on this disk, or invalid generalize unattend."
            Write-Host "Extract logs: make extract-sysprep-log IMAGE=<qcow2 from work/>"
            exit 1
        }
    }

    Repair-GeneralizedBcdStore

    # sysprep.exe leaves sysprep-generalize.xml in Panther; first deploy boot needs sysprep-oobe.xml.
    Restore-OobeUnattend -Reason 'after sysprep generalize'

    $restoreVirtio = Join-Path $PSScriptRoot 'restore-virtio-boot-after-sysprep.ps1'
    if (-not (Test-Path -LiteralPath $restoreVirtio)) {
        throw "Missing $restoreVirtio"
    }
    & $restoreVirtio

    $global:LASTEXITCODE = 0
    # Generalize can break WinRM before Packer's shutdown_command runs; power off locally and let
    # Packer wait for the QEMU process to exit instead of another WinRM round-trip.
    Invoke-GuestShutdown
    exit 0
}
catch {
    Save-SysprepDiagnostics $_.Exception.Message
    Write-SysprepDiagnosticLogs
    Write-Host "sysprep.ps1 failed: $($_.Exception.Message)"
    exit 1
}
