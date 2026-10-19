<#
.SYNOPSIS
    One-click: start (or reuse) the local server, then launch the client.
#>
[CmdletBinding()]
param([switch]$SkipDbUpdate)

& (Join-Path $PSScriptRoot 'Start-Server.ps1') -SkipDbUpdate:$SkipDbUpdate
if ($LASTEXITCODE -ne 0) { Write-Host "Server did not start; client not launched." -ForegroundColor Red; exit 1 }
& (Join-Path $PSScriptRoot 'Launch-Client.ps1')
exit $LASTEXITCODE
