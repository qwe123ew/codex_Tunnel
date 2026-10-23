@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Tunnel.ps1" -CheckOnly
echo.
pause
endlocal
