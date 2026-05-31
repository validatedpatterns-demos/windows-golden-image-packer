# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Register a one-shot SYSTEM startup task that runs enable-winrm-locator.cmd from the PROVISION CD.
# The OVMF sysprep pass is the first UEFI boot after SeaBIOS mbr2gpt prep; WinRM should already
# be configured, but this task re-enables it early in boot if the service did not start.
$ErrorActionPreference = 'Stop'

$taskName = 'GoldenImageEnableWinRM'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$locatorCmd = 'for %G in (D E F G H A B C) do @if exist %G:\enable-winrm-locator.cmd (call %G:\enable-winrm-locator.cmd & exit /b 0)'
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$locatorCmd`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Registered startup task: $taskName (runs enable-winrm-locator.cmd from PROVISION CD)"
