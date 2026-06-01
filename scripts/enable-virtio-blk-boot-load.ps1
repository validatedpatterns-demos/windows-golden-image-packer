# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Bind viostor for boot on virtio-blk disks (OpenShift/KubeVirt disk.bus: virtio).
# Manual Services\Start=0 is not enough on Server 2019+; Windows must associate the
# driver with VirtIO PCI hardware via Critical Device Database + a phantom device.
# Approach adapted from https://github.com/croit/load-virtio-scsi-on-boot

param(
    [Parameter(Mandatory = $true)]
    [string]$InfPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InfPath)) {
    throw "viostor INF not found: $InfPath"
}

$scsiClassGuid = '{4d36e97b-e325-11ce-bfc1-08002be10318}'
$hardwareId = 'PCI\VEN_1AF4&DEV_1001&SUBSYS_00021AF4&REV_00'
$deviceId = 'VIOSTORBOOT'

function Get-ViostorOemInf {
    $packages = 'HKLM:\SYSTEM\DriverDatabase\DriverPackages'
    if (-not (Test-Path $packages)) {
        return $null
    }
    foreach ($entry in Get-ChildItem -Path $packages -ErrorAction SilentlyContinue) {
        if ($entry.Name -notmatch 'viostor\.inf') { continue }
        $oem = (Get-ItemProperty -Path $entry.PSPath -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
        if ($oem) {
            return Join-Path $env:Windir "INF\$oem"
        }
    }
    return $null
}

function Set-ViostorCriticalDeviceDatabase {
    $paths = @(
        'pci#ven_1af4&dev_1001',
        'pci#ven_1af4&dev_1001&subsys_00021af4&rev_00',
        'pci#ven_1af4&dev_1042&subsys_11001af4&rev_01'
    )
    foreach ($rel in $paths) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\$rel"
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name 'Service' -Value 'viostor' -Type String -Force
        Set-ItemProperty -Path $key -Name 'ClassGUID' -Value $scsiClassGuid -Type String -Force
        Write-Host "CriticalDeviceDatabase: $rel -> viostor"
    }
}

$source = @'
using System;
using System.Runtime.InteropServices;

public class VirtioBlkBootDeviceInstaller
{
    private const uint DIF_REGISTERDEVICE = 0x00000019;
    private const uint DIF_SELECTBESTCOMPATDRV = 0x00000017;
    private const uint DIF_INSTALLDEVICE = 0x00000002;
    private const uint DICD_GENERATE_ID = 0x00000001;
    private const uint SPDIT_COMPATDRIVER = 0x00000001;

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool SetupDiCreateDeviceInfo(
        IntPtr DeviceInfoSet, string DeviceName, ref Guid ClassGuid, string DeviceDescription,
        IntPtr hwndParent, uint CreationFlags, ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiSetDeviceRegistryProperty(
        IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData,
        uint Property, byte[] PropertyBuffer, uint PropertyBufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiRegisterDeviceInfo(
        IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData,
        uint Flags, IntPtr CompareProc, IntPtr CompareContext, IntPtr DupDeviceInfo);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiCallClassInstaller(
        uint InstallFunction, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiBuildDriverInfoList(
        IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint DriverType);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiInstallDevice(
        IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData);

    public static void CreatePhantomDevice(string deviceName, string classGuidStr, string hardwareId)
    {
        Guid classGuid = new Guid(classGuidStr);
        IntPtr devInfoSet = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (devInfoSet == IntPtr.Zero || devInfoSet.ToInt64() == -1) {
            throw new Exception("SetupDiCreateDeviceInfoList failed: " + Marshal.GetLastWin32Error());
        }
        try {
            SP_DEVINFO_DATA devInfoData = new SP_DEVINFO_DATA();
            devInfoData.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            devInfoData.ClassGuid = classGuid;
            if (!SetupDiCreateDeviceInfo(devInfoSet, deviceName, ref classGuid,
                "VirtIO Block Driver", IntPtr.Zero, DICD_GENERATE_ID, ref devInfoData)) {
                throw new Exception("SetupDiCreateDeviceInfo failed: " + Marshal.GetLastWin32Error());
            }
            byte[] hwid = System.Text.Encoding.ASCII.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(devInfoSet, ref devInfoData, 1, hwid, (uint)hwid.Length)) {
                throw new Exception("SetupDiSetDeviceRegistryProperty failed: " + Marshal.GetLastWin32Error());
            }
            if (!SetupDiRegisterDeviceInfo(devInfoSet, ref devInfoData, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero)) {
                throw new Exception("SetupDiRegisterDeviceInfo failed: " + Marshal.GetLastWin32Error());
            }
            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, devInfoSet, ref devInfoData)) {
                throw new Exception("DIF_REGISTERDEVICE failed: " + Marshal.GetLastWin32Error());
            }
            if (SetupDiBuildDriverInfoList(devInfoSet, ref devInfoData, SPDIT_COMPATDRIVER)) {
                SetupDiCallClassInstaller(DIF_SELECTBESTCOMPATDRV, devInfoSet, ref devInfoData);
                SetupDiInstallDevice(devInfoSet, ref devInfoData);
                SetupDiCallClassInstaller(DIF_INSTALLDEVICE, devInfoSet, ref devInfoData);
            }
        } finally {
            SetupDiDestroyDeviceInfoList(devInfoSet);
        }
    }
}
'@

Write-Host "Installing viostor package: $InfPath"
& pnputil.exe /add-driver $InfPath /install | Out-Host

$oemInf = Get-ViostorOemInf
if (-not $oemInf -or -not (Test-Path -LiteralPath $oemInf)) {
    throw 'viostor not in DriverDatabase after pnputil; cannot bind boot driver'
}
Write-Host "Driver store INF: $oemInf"

Add-Type -TypeDefinition $source -ErrorAction Stop
[VirtioBlkBootDeviceInstaller]::CreatePhantomDevice($deviceId, $scsiClassGuid, $hardwareId)
Write-Host 'Registered phantom VirtIO block device for boot driver binding'

Set-ViostorCriticalDeviceDatabase

$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\viostor'
if (-not (Test-Path $svcKey)) {
    throw 'Services\viostor missing after phantom device install'
}
Set-ItemProperty -Path $svcKey -Name 'Start' -Value 0 -Type DWord -Force
Write-Host 'viostor Start=0 (boot-start)'

$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
if ($build -ge 19041) {
    $enum = & pnputil.exe /enum-devices /class SCSIAdapter 2>&1
    foreach ($line in $enum) {
        if ($line -match 'Instance ID:\s+(ROOT\\.*)') {
            $instanceId = $Matches[1].Trim()
            if ($instanceId -match 'VIOSTORBOOT|VIOSTOR') {
                Write-Host "Removing phantom device: $instanceId"
                & pnputil.exe /remove-device $instanceId 2>&1 | Out-Host
            }
        }
    }
} else {
    Write-Warning 'pnputil /remove-device unavailable; phantom VirtIO block device may remain in Device Manager'
}

Write-Host 'enable-virtio-blk-boot-load.ps1 complete'
