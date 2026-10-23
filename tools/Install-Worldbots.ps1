<#
.SYNOPSIS
    Installs the FFXI-Forever world-bots module into the Phoenix checkout (idempotent).

.DESCRIPTION
    1. Junction  E:\FFXI-Forever\server\modules\worldbots  ->  <repo>\modules\worldbots
       (and a git exclude entry so the Phoenix checkout stays clean).
    2. modules\init.txt: adds worldbots/cpp, worldbots/bots and worldbots/lua (last, so they load after Phoenix's modules).
    3. Core patch: applies patches\phoenix-b48e2d4e\worldbots-core.patch with git apply (skipped if already applied).
    Rebuild (tools\Build-Server.ps1) and restart afterwards.

.PARAMETER Uninstall
    Reverses all three steps.
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$Repo     = Split-Path $PSScriptRoot -Parent
$Server   = 'E:\FFXI-Forever\server'
$Link     = Join-Path $Server 'modules\worldbots'
$Target   = Join-Path $Repo 'modules\worldbots'
$InitTxt  = Join-Path $Server 'modules\init.txt'
$Exclude  = Join-Path $Server '.git\info\exclude'
$Patch    = Join-Path $Repo 'patches\phoenix-b48e2d4e\worldbots-core.patch'
$InitBlock = @('', '# FFXI-Forever world bots (github.com/corey-allen/ffxi-forever) - keep last', 'worldbots/cpp', 'worldbots/bots', 'worldbots/lua')

$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

function Get-NL([string]$path) { if ([IO.File]::ReadAllText($path) -match "`r`n") { "`r`n" } else { "`n" } }
function Get-Lines([string]$path) { [IO.File]::ReadAllText($path) -split "`r?`n" }
function Set-Lines([string]$path, $lines, [string]$nl) { [IO.File]::WriteAllText($path, (($lines -join $nl).TrimEnd("`r", "`n") + $nl)) }
function Test-PatchApplied { & git -C $Server apply --reverse --check $Patch 2>$null; return $LASTEXITCODE -eq 0 }

if ($Uninstall) {
    if (Test-Path -LiteralPath $Link) { (Get-Item -LiteralPath $Link).Delete(); Write-Host "removed junction $Link" }
    Set-Lines $InitTxt (Get-Lines $InitTxt | Where-Object { $_ -notmatch '^worldbots/' -and $_ -notmatch 'FFXI-Forever world bots' }) (Get-NL $InitTxt)
    Write-Host 'removed worldbots lines from modules\init.txt'
    if (Test-PatchApplied) { & git -C $Server apply --reverse $Patch; if ($LASTEXITCODE -ne 0) { throw 'reverting the core patch failed' }; Write-Host 'reverted the core patch' }
    Set-Lines $Exclude (Get-Lines $Exclude | Where-Object { $_ -ne '/modules/worldbots' }) (Get-NL $Exclude)
    Write-Host 'Done. Rebuild and restart.'
    return
}

# 1. Junction
if (Test-Path -LiteralPath $Link) {
    $item = Get-Item -LiteralPath $Link
    if ($item.LinkType -ne 'Junction' -or ($item.Target | Select-Object -First 1) -ne $Target) { throw "$Link exists but is not a junction to $Target" }
    Write-Host "junction ok: $Link"
} else {
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    Write-Host "created junction: $Link -> $Target"
}
if ((Get-Lines $Exclude) -notcontains '/modules/worldbots') { Add-Content -LiteralPath $Exclude -Value '/modules/worldbots'; Write-Host 'added git exclude for the junction' }

# 2. init.txt
if ((Get-Lines $InitTxt) -contains 'worldbots/cpp') { Write-Host 'init.txt ok' }
else { Set-Lines $InitTxt (@(Get-Lines $InitTxt) + $InitBlock) (Get-NL $InitTxt); Write-Host 'appended worldbots to modules\init.txt' }

# 3. Core patch
if (Test-PatchApplied) { Write-Host 'core patch already applied' }
else {
    & git -C $Server apply --check $Patch
    if ($LASTEXITCODE -ne 0) { throw "core patch does not apply cleanly: $Patch" }
    & git -C $Server apply $Patch
    if ($LASTEXITCODE -ne 0) { throw 'applying the core patch failed' }
    Write-Host 'applied the core patch'
}
Write-Host 'Done. Rebuild (tools\Build-Server.ps1) and restart the server.'
