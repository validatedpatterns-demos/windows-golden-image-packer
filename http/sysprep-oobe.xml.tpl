<?xml version="1.0" encoding="utf-8"?>
<!--
  Copyright 2026 Red Hat, Inc.
  SPDX-License-Identifier: Apache-2.0

  Copied to C:\Windows\Panther\unattend.xml for first boot after sysprep /oobe.
  Not passed to sysprep.exe (avoids oobeSystem being marked processed at generalize time).
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend"
  xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Skip OOBE product key page (generalize clears pre-sysprep SetupDisplayedProductKey)</Description>
          <Path>reg.exe add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OOBE /v SetupDisplayedProductKey /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
%{if product_key != ""~}
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Re-apply product key after sysprep generalize</Description>
          <Path>cmd.exe /c cscript //nologo %SystemRoot%\System32\slmgr.vbs /ipk ${product_key}</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Extend C: when the VM disk is larger than the golden image</Description>
          <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\GoldenImage\extend-system-partition.ps1</Path>
        </RunSynchronousCommand>
%{else~}
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Extend C: when the VM disk is larger than the golden image</Description>
          <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\GoldenImage\extend-system-partition.ps1</Path>
        </RunSynchronousCommand>
%{endif~}
      </RunSynchronous>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UILanguageFallback>en-US</UILanguageFallback>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>${admin_password}</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
