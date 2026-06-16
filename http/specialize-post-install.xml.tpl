<!--
  Copyright 2026 Red Hat, Inc.
  SPDX-License-Identifier: Apache-2.0
  virtio-blk install: MSI guest tools + WinRM for Packer (Tekton windows-efi-installer pattern).
-->

    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Install virtio-win guest tools and QEMU GA from virtio CD</Description>
          <Path>cmd.exe /c "for %G in (D E F G H I J K) do @if exist %G:\post-install.ps1 (powershell.exe -NoProfile -ExecutionPolicy Bypass -File %G:\post-install.ps1 &amp; exit /b 0)"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Enable WinRM for Packer</Description>
          <Path>cmd.exe /c "for %G in (D E F G H A B C) do @if exist %G:\enable-winrm-locator.cmd (call %G:\enable-winrm-locator.cmd &amp; exit /b 0)"</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
