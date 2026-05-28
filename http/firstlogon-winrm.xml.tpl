<!--
  Copyright 2026 Red Hat, Inc.
  SPDX-License-Identifier: Apache-2.0
-->

        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Enable WinRM for Packer (first logon fallback)</Description>
          <CommandLine>cmd.exe /c "for %G in (D E F G H A B C) do @if exist %G:\enable-winrm-locator.cmd (call %G:\enable-winrm-locator.cmd &amp; exit /b 0)"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Install OpenSSH Server (first logon fallback)</Description>
          <CommandLine>cmd.exe /c "for %G in (D E F G H A B C) do @if exist %G:\install-openssh-locator.cmd (call %G:\install-openssh-locator.cmd &amp; exit /b 0)"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Disable autologon after Packer install (Winlogon)</Description>
          <CommandLine>cmd.exe /c "for %G in (D E F G H A B C) do @if exist %G:\clear-autologon.ps1 (powershell.exe -NoProfile -ExecutionPolicy Bypass -File %G:\clear-autologon.ps1 &amp; exit /b 0)"</CommandLine>
        </SynchronousCommand>
