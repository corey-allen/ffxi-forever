<#
.SYNOPSIS
    Builds the Phoenix server (RelWithDebInfo via tools\build.py) and logs to E:\FFXI-Forever\buildlogs\.

.PARAMETER Preset
    CMake build preset from CMakePresets.json (default, debug, release, tracy). Default: default.

.NOTES
    Stop the server first: the build copies new executables into the server directory.
    Phoenix's modules/temp_patch patches must already be applied (see docs/LOCAL_SERVER_INSTALL.md).
#>
[CmdletBinding()]
param([string]$Preset = 'default')

$ServerDir = 'E:\FFXI-Forever\server'
$Python    = 'C:\Users\Corey\AppData\Local\Programs\Python\Python314\python.exe'
$LogDir    = 'E:\FFXI-Forever\buildlogs'

# Pick up tools installed after this shell started.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$log = Join-Path $LogDir ("build-{0}-{1}.log" -f $Preset, (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-Host "Building preset '$Preset'; log: $log"

Push-Location $ServerDir
try {
    & $Python 'tools\build.py' '--preset' $Preset 2>&1 | Tee-Object -FilePath $log | Select-String -Pattern '^\[\d+/\d+\]|error|FAILED|warning C' | ForEach-Object { $_.Line }
    $code = $LASTEXITCODE
} finally { Pop-Location }

if ($code -eq 0) { Write-Host "BUILD SUCCEEDED" -ForegroundColor Green } else { Write-Host "BUILD FAILED (exit $code) - see $log" -ForegroundColor Red }
exit $code
