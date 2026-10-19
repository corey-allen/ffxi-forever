@echo off
title FFXI-Forever - Start Server
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Server.ps1" %*
pause
