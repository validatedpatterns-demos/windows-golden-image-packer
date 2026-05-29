# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

# First deploy boot (oobeSystem): extend C: into unallocated space when the VM disk/PVC
# is larger than the golden image virtual size (e.g. 40G image on a 100Gi DataVolume).
$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\extend-system-partition.log'
$goldenLog = 'C:\ProgramData\GoldenImage\extend-system-partition.log'

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path $goldenLog) -Force | Out-Null
    Write-Log 'extend-system-partition.ps1 starting'

    Import-Module Storage -ErrorAction Stop

    Update-HostStorageCache | Out-Null

    $partition = Get-Partition -DriveLetter C -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber
    Write-Log "Boot disk $($disk.Number): $($disk.FriendlyName) size=$($disk.Size) partitionStyle=$($disk.PartitionStyle)"

    $supported = Get-PartitionSupportedSize -DriveLetter C
    $current = $partition.Size
    $max = $supported.SizeMax
    $delta = $max - $current

    if ($delta -lt 4MB) {
        Write-Log "C: already uses available space (size=$current max=$max); nothing to extend"
        exit 0
    }

    Write-Log "Extending C: by $delta bytes (from $current to $max)"
    Resize-Partition -DriveLetter C -Size $max
    $after = (Get-Partition -DriveLetter C).Size
    Write-Log "Extend complete; C: size is now $after"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    if (Test-Path -LiteralPath $logPath) {
        Copy-Item -LiteralPath $logPath -Destination $goldenLog -Force -ErrorAction SilentlyContinue
    }
}
