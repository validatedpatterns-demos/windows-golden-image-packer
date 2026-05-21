@echo off
if exist A:\install-openssh-server.ps1 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File A:\install-openssh-server.ps1
  exit /b %ERRORLEVEL%
)
for %%G in (D E F G H) do if exist %%G:\install-openssh-server.ps1 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File %%G:\install-openssh-server.ps1
  exit /b %ERRORLEVEL%
)
echo install-openssh-server.ps1 not found on A: or CD-ROM D-H. >&2
exit /b 1
