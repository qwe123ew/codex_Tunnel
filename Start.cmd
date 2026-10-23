@echo off
setlocal
cd /d "%~dp0"
title Portable Codex Proxy Tunnel
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Tunnel.ps1"
echo.
pause
endlocal
