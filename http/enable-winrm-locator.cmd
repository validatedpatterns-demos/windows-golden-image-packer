@echo off
if exist A:\enable-winrm.ps1 powershell.exe -ExecutionPolicy Bypass -File A:\enable-winrm.ps1 && exit /b 0
if exist A:\enable-winrm.cmd call A:\enable-winrm.cmd && exit /b 0
for %%G in (D E F G H) do if exist %%G:\enable-winrm.ps1 (
  powershell.exe -ExecutionPolicy Bypass -File %%G:\enable-winrm.ps1
  exit /b 0
)
for %%G in (D E F G H) do if exist %%G:\enable-winrm.cmd (
  call %%G:\enable-winrm.cmd
  exit /b 0
)
exit /b 1
