# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# Convert a SeaBIOS/MBR install disk to GPT + UEFI boot files (mbr2gpt).
# Run at the start of the Packer provision pass before 07-repair-uefi-boot.ps1.
$ErrorActionPreference = 'Stop'

$bootDisk = Get-Disk | Where-Object { $_.IsBoot -eq $true } | Select-Object -First 1
if (-not $bootDisk) {
    throw 'No boot disk found for mbr2gpt'
}

if ($bootDisk.PartitionStyle -eq 'GPT') {
    Write-Host "Boot disk $($bootDisk.Number) is already GPT; skipping mbr2gpt"
    exit 0
}

if ($bootDisk.PartitionStyle -ne 'MBR') {
    throw "Unsupported boot disk partition style: $($bootDisk.PartitionStyle)"
}

$mbr2gpt = Join-Path $env:SystemRoot 'System32\mbr2gpt.exe'
if (-not (Test-Path -LiteralPath $mbr2gpt)) {
    throw "mbr2gpt.exe not found at $mbr2gpt"
}

Write-Host "Validating MBR disk $($bootDisk.Number) for conversion..."
& $mbr2gpt /validate /disk:$($bootDisk.Number) /allowFullOS | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "mbr2gpt /validate failed with exit code $LASTEXITCODE"
}

Write-Host "Converting boot disk $($bootDisk.Number) to GPT (mbr2gpt /convert)..."
& $mbr2gpt /convert /disk:$($bootDisk.Number) /allowFullOS | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "mbr2gpt /convert failed with exit code $LASTEXITCODE"
}

$bootDisk = Get-Disk -Number $bootDisk.Number
if ($bootDisk.PartitionStyle -ne 'GPT') {
    throw 'mbr2gpt finished but boot disk is not GPT'
}

Write-Host 'mbr2gpt complete; Packer will boot this image with OVMF on the provision pass'
