@echo off
title FFXI-Forever - Launch Client
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-Client.ps1" %*
if errorlevel 1 pause
