# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Generalize the image for cloning in OpenShift Virtualization (KubeVirt).
param(
    [switch]$ProvisionerRun,
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'

if (-not $ProvisionerRun -and $env:SYSPREP_PROVISIONER_RUN -eq '1') {
    $ProvisionerRun = $true
}

$goldenData = 'C:\ProgramData\GoldenImage'
$shutdownGuardPidFile = Join-Path $goldenData 'sysprep-shutdown-guard.pid'
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

function Set-PostSysprepProductKeyOobe {
    # Registry + UnattendPasses only. Do not run slmgr here — generalize invalidates WinRM and
    # Packer's powershell provisioner fails with 401 on script cleanup. Product key is applied in
    # sysprep-generalize.xml (specialize pass) and again on first deploy boot (sysprep-oobe.xml).
    foreach ($path in @(
            'HKLM:\SYSTEM\Setup\Status\SysprepStatus',
            'HKLM:\SYSTEM\Setup\Status\UnattendPasses'
        )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Cleared $path (oobeSystem must run from Panther unattend on first deploy boot)"
        }
    }

    $oobeReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OOBE'
    if (-not (Test-Path -LiteralPath $oobeReg)) {
        New-Item -Path $oobeReg -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $oobeReg -Name 'SetupDisplayedProductKey' -Value 1 -Type DWord -Force
    Write-Host 'Set SetupDisplayedProductKey=1 (skip OOBE product key page after generalize)'
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

function Stop-OrphanSysprepShutdownGuards {
    # If Stop-SysprepShutdownGuard failed, the guard loops shutdown /a and blocks Invoke-GuestShutdown.
    if (Test-Path -LiteralPath $shutdownGuardPidFile) {
        $guardPid = Get-Content -LiteralPath $shutdownGuardPidFile -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^\d+$' } |
            Select-Object -First 1
        if ($guardPid) {
            Write-Host "Stopping sysprep shutdown guard from pid file (pid $guardPid)"
            Stop-Process -Id ([int]$guardPid) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $shutdownGuardPidFile -Force -ErrorAction SilentlyContinue
    }

    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*sysprep-shutdown-guard.ps1*' } |
        ForEach-Object {
            Write-Host "Stopping orphan sysprep shutdown guard (pid $($_.ProcessId))"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Invoke-GuestShutdown {
    $shutdownExe = "$env:SystemRoot\System32\shutdown.exe"
    Write-Host 'Forcing guest shutdown for Packer (sysprep runs without /shutdown so OOBE unattend can be restored first).'

    Stop-OrphanSysprepShutdownGuards
    Cancel-PendingGuestShutdown
    Start-Sleep -Seconds 1

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Stop-OrphanSysprepShutdownGuards
        Cancel-PendingGuestShutdown
        Start-Sleep -Milliseconds 400

        Write-Host "Guest shutdown attempt $attempt/3..."
        & $shutdownExe /s /t 0 /f
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "shutdown.exe exit $LASTEXITCODE on attempt $attempt"
        }

        Start-Sleep -Seconds 5
        Stop-OrphanSysprepShutdownGuards
    }

    Stop-OrphanSysprepShutdownGuards
    Cancel-PendingGuestShutdown
    Write-Host 'Using Stop-Computer -Force (login screen can ignore shutdown.exe while WinRM is still up).'
    Stop-Computer -Force
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
    New-Item -ItemType Directory -Path $goldenData -Force | Out-Null
    $guard = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $guardScript) `
        -PassThru -WindowStyle Hidden
    Set-Content -LiteralPath $shutdownGuardPidFile -Value $guard.Id -Encoding ASCII
    return $guard
}

function Stop-SysprepShutdownGuard {
    param($GuardProcess)
    if ($GuardProcess) {
        try {
            Stop-Process -Id $GuardProcess.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning "Could not stop sysprep shutdown guard: $($_.Exception.Message)"
        }
    }
    Stop-OrphanSysprepShutdownGuards
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

function Get-EspBcdDeviceSpec {
    $esp = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object {
            $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $_.Type -eq 'System'
        } |
        Select-Object -First 1
    if (-not $esp) {
        throw 'EFI system partition not found for BCD bootmgr repair'
    }
    if ($esp.Guid) {
        return "partition={$($esp.Guid)}"
    }
    if ($esp.DriveLetter) {
        return "partition=$($esp.DriveLetter):"
    }
    throw 'ESP has no GPT GUID or drive letter for BCD repair'
}

function Get-WindowsPartitionBcdDeviceSpec {
    $windows = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object {
            $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -or
            ($_.Type -eq 'Basic' -and $_.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}')
        } |
        Sort-Object -Property Size -Descending |
        Select-Object -First 1
    if (-not $windows) {
        throw 'Windows data partition not found for BCD loader repair'
    }
    if ($windows.Guid) {
        return "partition={$($windows.Guid)}"
    }
    if ($windows.DriveLetter) {
        return "partition=$($windows.DriveLetter):"
    }
    throw 'Windows partition has no GPT GUID or drive letter for BCD repair'
}

function Get-BcdObjectIds {
    param(
        [string[]]$BcdeditArgs
    )

    $out = & bcdedit.exe @BcdeditArgs 2>&1 | Out-String
    return [regex]::Matches($out, '\{[0-9a-f-]{36}\}') |
        ForEach-Object { $_.Value } |
        Select-Object -Unique
}

function Invoke-BcdeditSilently {
    param(
        [string[]]$BcdeditArgs
    )

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & bcdedit.exe @BcdeditArgs 2>&1 | Out-Host
    }
    finally {
        $ErrorActionPreference = $prev
    }
    $global:LASTEXITCODE = 0
}

function Get-BcdWinloadObjectIds {
    $out = & bcdedit.exe /enum all 2>&1 | Out-String
    $ids = @()
    $currentId = $null
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match 'identifier\s+(\{[0-9a-f-]{36}\})') {
            $currentId = $Matches[1]
            continue
        }
        if ($currentId -and $line -match 'path\s+.*winload\.efi') {
            $ids += $currentId
            $currentId = $null
        }
    }
    return @($ids | Select-Object -Unique)
}

function Remove-AllBcdWinloadObjects {
    param(
        [string[]]$KeepIds = @()
    )

    foreach ($id in @(Get-BcdWinloadObjectIds)) {
        if ($KeepIds -contains $id) {
            continue
        }
        Write-Host "Removing BCD winload object $id"
        Invoke-BcdeditSilently -BcdeditArgs @('/delete', $id, '/f')
    }
}

function Remove-AllBcdOsLoaders {
    Remove-AllBcdWinloadObjects
}

function Resolve-BcdDefaultLoaderId {
    $out = & bcdedit.exe /enum '{default}' /v 2>&1 | Out-String
    if ($out -match 'identifier\s+(\{[0-9a-f-]{36}\})') {
        return $Matches[1]
    }
    return '{default}'
}

function Remove-DuplicateBcdOsLoaders {
    $keepId = Resolve-BcdDefaultLoaderId
    Remove-AllBcdWinloadObjects -KeepIds @($keepId)
}

function Clear-BcdDiskLocateElements {
    param(
        [string[]]$ObjectIds
    )

    foreach ($id in $ObjectIds) {
        foreach ($elem in @('21000026')) {
            Invoke-BcdeditSilently -BcdeditArgs @('/deletevalue', $id, $elem)
        }
    }
}

function Reset-BcdBootMenu {
    # Replace displayorder with a single {default} entry (do not /addfirst — that leaves orphans).
    Invoke-BcdeditSilently -BcdeditArgs @('/displayorder', '{default}')
}

function Test-BcdSingleOsLoader {
    $loaderIds = @(Get-BcdWinloadObjectIds)
    if ($loaderIds.Count -ne 1) {
        throw "BCD repair left $($loaderIds.Count) winload objects (expected 1): $($loaderIds -join ', ')"
    }
    Write-Host "BCD winload object count OK: $($loaderIds[0])"
}

function Test-BcdLoaderBootDevices {
    param([string]$LoaderId)

    $out = & bcdedit.exe /enum $LoaderId /v 2>&1 | Out-String
    if ($out -notmatch '(?m)^device\s+.*\bpartition=') {
        throw "BCD loader $LoaderId is missing device partition= (0xc000000f risk)"
    }
    if ($out -notmatch '(?m)^osdevice\s+.*\bpartition=') {
        throw "BCD loader $LoaderId is missing osdevice partition= (0xc000000f risk)"
    }
    Write-Host "BCD loader boot devices OK: $LoaderId (device + osdevice partition=)"
}

function Repair-GeneralizedBcdStore {
    # OVMF sysprep boots virtio-blk (OpenShift parity). Rebuild BCD once after generalize:
    # fresh bcdboot on ESP, point bootmgr at ESP, loader at Windows partition GUID (not device boot).
    $espSpec = Get-EspBcdDeviceSpec
    $windowsSpec = Get-WindowsPartitionBcdDeviceSpec

    Remove-AllBcdWinloadObjects

    $uefiRepair = Join-Path $PSScriptRoot '07-repair-uefi-boot.ps1'
    if (-not (Test-Path -LiteralPath $uefiRepair)) {
        throw "Missing $uefiRepair"
    }
    & $uefiRepair -CleanBcdStore

    Remove-DuplicateBcdOsLoaders

    $loaderId = Resolve-BcdDefaultLoaderId
    Write-Host "Repairing generalized BCD for virtio-blk deploy (loader=$loaderId, bootmgr=$espSpec, device/osdevice=$windowsSpec)"
    & bcdedit.exe /set '{bootmgr}' device $espSpec 2>&1 | Out-Host
    foreach ($id in @($loaderId, '{default}', '{current}')) {
        & bcdedit.exe /set $id device $windowsSpec 2>&1 | Out-Host
        & bcdedit.exe /set $id osdevice $windowsSpec 2>&1 | Out-Host
    }
    Clear-BcdDiskLocateElements -ObjectIds @($loaderId, '{default}', '{current}')
    Invoke-BcdeditSilently -BcdeditArgs @('/displayorder', $loaderId)
    Remove-DuplicateBcdOsLoaders
    Test-BcdSingleOsLoader
    Test-BcdLoaderBootDevices -LoaderId $loaderId
    $global:LASTEXITCODE = 0
}

function Get-SysprepWorkerDelaySeconds {
    if ($env:SYSPREP_WORKER_DELAY_SECONDS -match '^\d+$') {
        return [int]$env:SYSPREP_WORKER_DELAY_SECONDS
    }
    return 30
}

function Start-SysprepWorkerProcess {
    # Do not Start-Process the worker immediately — sysprep /generalize breaks WinRM while Packer
    # is still tearing down the inline provisioner script (401 on winrmcp cleanup). Schedule the
    # worker so Packer can exit WinRM before generalize runs.
    New-Item -ItemType Directory -Path $goldenData -Force | Out-Null
    $workerLog = Join-Path $goldenData 'sysprep-worker.log'
    $taskName = 'GoldenImageSysprepWorker'
    $delaySec = Get-SysprepWorkerDelaySeconds
    $runAt = (Get-Date).AddSeconds($delaySec)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        schtasks.exe /Delete /TN $taskName /F | Out-Null
    }
    finally {
        $ErrorActionPreference = $prev
    }

    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker"
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -Once -At $runAt
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

    Write-Host "Scheduled sysprep worker as SYSTEM in ${delaySec}s (task: $taskName; log: $workerLog)"
    Write-Host "Run at: $($runAt.ToString('o')) (Packer must finish WinRM teardown before generalize)"
}

function Invoke-SysprepGeneralizeAndFinalize {
    if ($Worker) {
        $taskName = 'GoldenImageSysprepWorker'
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        finally {
            $ErrorActionPreference = $prev
        }
    }

    $sysprep = 'C:\Windows\System32\Sysprep\sysprep.exe'
    if (-not (Test-Path $sysprep)) {
        throw "Sysprep not found at $sysprep"
    }

    $installVirtio = Join-Path $PSScriptRoot '01-install-virtio-drivers.ps1'
    if (-not (Test-Path -LiteralPath $installVirtio)) {
        throw "Missing $installVirtio"
    }

    $unattend = $generalizeUnattend
    # /quit: do not reboot or shut down after generalize — post-sysprep virtio restore and OOBE
    # unattend must run on the guest before shutdown. Without /quit, sysprep shuts down before
    # restore-virtio-boot-after-sysprep.ps1 runs.
    $timeoutMin = 45
    if ($env:SYSPREP_TIMEOUT_MINUTES -match '^\d+$') {
        $timeoutMin = [int]$env:SYSPREP_TIMEOUT_MINUTES
    }
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

    Restore-OobeUnattend -Reason 'after sysprep generalize'

    $restoreVirtio = Join-Path $PSScriptRoot 'restore-virtio-boot-after-sysprep.ps1'
    if (-not (Test-Path -LiteralPath $restoreVirtio)) {
        throw "Missing $restoreVirtio"
    }
    & $restoreVirtio

    if (-not (Get-Command Sync-VirtioBootRegistryToAllControlSets -ErrorAction SilentlyContinue)) {
        . $installVirtio -SkipMain
    }
    Sync-VirtioBootRegistryToAllControlSets
    Remove-VirtioBootStartOverrideAllControlSets

    $verifyVirtio = Join-Path $PSScriptRoot 'verify-virtio-boot-drivers.ps1'
    if (-not (Test-Path -LiteralPath $verifyVirtio)) {
        throw "Missing $verifyVirtio"
    }
    & $verifyVirtio -AllControlSets
    Remove-VirtioBootStartOverrideAllControlSets
    Repair-GeneralizedBcdStore
    Set-PostSysprepProductKeyOobe

    $global:LASTEXITCODE = 0
    Stop-OrphanSysprepShutdownGuards
    Invoke-GuestShutdown
    exit 0
}

try {
    if ($Worker) {
        New-Item -ItemType Directory -Path $goldenData -Force | Out-Null
        $workerLog = Join-Path $goldenData 'sysprep-worker.log'
        if (Test-Path -LiteralPath $workerLog) {
            Remove-Item -LiteralPath $workerLog -Force -ErrorAction SilentlyContinue
        }
        Start-Transcript -Path $workerLog -Force | Out-Null
        Write-Host "Sysprep worker started at $(Get-Date -Format o)"
    }

    if (-not $Worker) {
        $clearScript = Join-Path $PSScriptRoot 'clear-autologon.ps1'
        if (Test-Path $clearScript) {
            & $clearScript
        }
        else {
            Write-Warning "clear-autologon.ps1 not found beside sysprep.ps1; image may autologon on first OpenShift boot"
        }

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

        $installVirtio = Join-Path $PSScriptRoot '01-install-virtio-drivers.ps1'
        if (-not (Test-Path -LiteralPath $installVirtio)) {
            throw "Missing $installVirtio"
        }
        . $installVirtio -SkipMain
        Remove-VirtioBootStartOverrideAllControlSets
    }

    if ($ProvisionerRun -and -not $Worker) {
        Start-SysprepWorkerProcess
        $global:LASTEXITCODE = 0
        exit 0
    }

    Invoke-SysprepGeneralizeAndFinalize
}
catch {
    Save-SysprepDiagnostics $_.Exception.Message
    Write-SysprepDiagnosticLogs
    Write-Host "sysprep.ps1 failed: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($Worker) {
        Stop-Transcript | Out-Null
    }
}
