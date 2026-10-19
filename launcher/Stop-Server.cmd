@echo off
title FFXI-Forever - Stop Server
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-Server.ps1" %*
pause
