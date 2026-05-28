<?xml version="1.0" encoding="utf-8"?>
<!--
  Copyright 2026 Red Hat, Inc.
  SPDX-License-Identifier: Apache-2.0

  Passed to sysprep.exe only (specialize + generalize). Do not include oobeSystem here —
  that pass must run from a fresh Panther\unattend.xml on first boot after generalize.
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend"
  xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="generalize">
    <component name="Microsoft-Windows-Security-SPP" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipRearm>1</SkipRearm>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Stage OOBE-only unattend for first deploy boot</Description>
          <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Copy-Item -LiteralPath 'C:\ProgramData\GoldenImage\sysprep-oobe.xml' -Destination 'C:\Windows\Panther\unattend.xml' -Force"</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
      <Reseal>
        <Mode>OOBE</Mode>
      </Reseal>
    </component>
  </settings>
</unattend>
