<#
.SYNOPSIS
    Dumps the game database (xidb) to E:\FFXI-Forever\backups\db-<timestamp>.sql.gz-free plain SQL.

.DESCRIPTION
    Reads host, port, database and credentials from the server's gitignored settings\network.lua, so
    no credential is stored or printed here. Uses mysqldump from the MariaDB service's install folder.
    Run before every live world-bots test (engineering rule in docs/plans/WORLDBOTS_PLAN.md).
#>
[CmdletBinding()]
param([string]$Label = '')

$ErrorActionPreference = 'Stop'
$Settings = 'E:\FFXI-Forever\server\settings\network.lua'
$OutDir   = 'E:\FFXI-Forever\backups'

function Get-Setting([string]$name) {
    $m = Select-String -Path $Settings -Pattern ("^\s*$name\s*=\s*'?([^',]*)'?") | Select-Object -First 1
    if (-not $m) { throw "$name not found in $Settings" }
    return $m.Matches[0].Groups[1].Value
}

$svc  = (Get-CimInstance Win32_Service -Filter "Name='MariaDB'").PathName
$bin  = Split-Path ($svc -replace '^"([^"]+)".*$', '$1') -Parent
$dump = Join-Path $bin 'mysqldump.exe'
if (-not (Test-Path $dump)) { throw "mysqldump not found next to the MariaDB service ($bin)" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$name  = if ($Label) { "db-$stamp-$Label.sql" } else { "db-$stamp.sql" }
$out   = Join-Path $OutDir $name
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# The password goes through the environment (MYSQL_PWD), never the command line.
$env:MYSQL_PWD = Get-Setting 'SQL_PASSWORD'
try {
    $dumpArgs = @(
        "--host=$(Get-Setting 'SQL_HOST')", "--port=$(Get-Setting 'SQL_PORT')", "--user=$(Get-Setting 'SQL_LOGIN')",
        '--single-transaction', '--routines', '--default-character-set=utf8mb4', "--result-file=$out", (Get-Setting 'SQL_DATABASE')
    )
    & $dump @dumpArgs
    if ($LASTEXITCODE -ne 0) { throw "mysqldump failed (exit $LASTEXITCODE)" }
} finally {
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
}
$size = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host "backup: $out ($size MB)"
