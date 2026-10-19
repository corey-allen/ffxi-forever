<#
.SYNOPSIS
    Launches the FFXI client through Ashita v4 with the local-ffxi-forever.ini boot config.

.DESCRIPTION
    Refuses to launch unless the local server is up (all launcher-managed processes alive and the
    login ports answering), unless -Force is given. No credentials are passed on the command line:
    the bootloader console asks for Login (1) or Create New Account (2).
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ffxi-forever.config.ps1')

$ini = Join-Path $FFXI.AshitaDir "config\boot\$($FFXI.BootConfig)"
if (-not (Test-Path -LiteralPath $FFXI.AshitaCli)) { Write-Bad "Ashita not found: $($FFXI.AshitaCli)"; exit 1 }
if (-not (Test-Path -LiteralPath $ini))           { Write-Bad "Boot config not found: $ini"; exit 1 }

if (-not $Force) {
    $live = @(Get-FFXIServerProcesses | ForEach-Object Name)
    $missing = @($FFXI.Processes | ForEach-Object Name | Where-Object { $live -notcontains $_ })
    if ($missing.Count -gt 0) { Write-Bad "Server not running (missing: $($missing -join ', ')). Run Start-Server.ps1 or Play.cmd first."; exit 1 }
    foreach ($port in 54231, 54001, 54230) {
        if (-not (Test-TcpPort $FFXI.ZoneIp $port)) { Write-Bad "Login service on $($FFXI.ZoneIp):$port is not answering."; exit 1 }
    }
}

Write-Step "Launching Ashita with $($FFXI.BootConfig)"
Start-Process -FilePath $FFXI.AshitaCli -ArgumentList $FFXI.BootConfig -WorkingDirectory $FFXI.AshitaDir
Write-Ok "Client launched. In the bootloader window choose 1 (Login) or 2 (Create New Account)."
exit 0
