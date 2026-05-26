<!--
  Copyright 2026 Red Hat, Inc.
  SPDX-License-Identifier: Apache-2.0
-->

        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Enable WinRM for Packer (first logon fallback)</Description>
          <CommandLine>cmd.exe /c A:\enable-winrm-locator.cmd</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Install OpenSSH Server (first logon fallback)</Description>
          <CommandLine>cmd.exe /c A:\install-openssh-locator.cmd</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Disable autologon after first boot</Description>
          <CommandLine>reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f</CommandLine>
        </SynchronousCommand>
