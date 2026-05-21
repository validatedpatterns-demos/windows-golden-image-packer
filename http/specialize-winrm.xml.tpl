    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Enable WinRM for Packer</Description>
          <Path>A:\enable-winrm-locator.cmd</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Install OpenSSH Server (SYSTEM)</Description>
          <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File A:\install-openssh-server.ps1</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
