@echo off
setlocal
cd /d "%~dp0"
title SSH Connection Help
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Tunnel.ps1" -ShowSshHelp
echo.
pause
endlocal
