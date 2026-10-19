<#
.SYNOPSIS
    Starts the local FFXI-Forever (Phoenix XI) server: MariaDB check, dbtool update, then
    xi_connect, xi_search, xi_profile, xi_world, xi_map, each verified ready before the next.

.PARAMETER SkipDbUpdate
    Do not run "tools\dbtool.py update" before starting.

.NOTES
    Safe to run from any directory or a shortcut. Refuses to start a second instance.
    Each server process gets its own minimized console window; its log is in <server>\log\.
#>
[CmdletBinding()]
param([switch]$SkipDbUpdate)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ffxi-forever.config.ps1')

function Fail([string]$msg) { Write-Bad $msg; exit 1 }

# --- 1. Preconditions -------------------------------------------------------------------
Write-Step "Checking installation at $($FFXI.ServerDir)"
if (-not (Test-Path -LiteralPath $FFXI.ServerDir)) { Fail "Server directory not found: $($FFXI.ServerDir)" }
foreach ($p in $FFXI.Processes) {
    $exe = Join-Path $FFXI.ServerDir "$($p.Name).exe"
    if (-not (Test-Path -LiteralPath $exe)) { Fail "Missing $exe - build the server first (py -3 tools\build.py)." }
}
if (-not (Test-Path -LiteralPath (Join-Path $FFXI.ServerDir 'settings\network.lua'))) { Fail "Missing settings\network.lua (copy settings\default\*.lua into settings\)." }
New-Item -ItemType Directory -Force -Path $FFXI.RunDir, (Join-Path $FFXI.ServerDir 'log') | Out-Null

# --- 2. Already running? ----------------------------------------------------------------
$running = @(Get-FFXIServerProcesses)
if ($running.Count -gt 0) {
    Write-Ok ("Server already running: " + (($running | ForEach-Object { "$($_.Name)[$($_.Pid)]" }) -join ', '))
    Write-Host "Use Stop-Server.ps1 first if you want a restart."
    exit 0
}
$strays = Get-Process -Name ($FFXI.Processes | ForEach-Object { $_.Name }) -ErrorAction SilentlyContinue |
    Where-Object { try { $_.Path -like "$($FFXI.ServerDir)\*" } catch { $false } }
if ($strays) {
    Fail ("Server processes are running that this launcher did not start: " +
          (($strays | ForEach-Object { "$($_.ProcessName)[$($_.Id)]" }) -join ', ') +
          ". Close those windows (or end them in Task Manager), then retry.")
}
foreach ($p in $FFXI.Processes) {
    foreach ($port in $p.Tcp) {
        $o = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($o) { Fail "TCP port $port (needed by $($p.Name)) is already in use by PID $($o.OwningProcess) ($((Get-Process -Id $o.OwningProcess -ErrorAction SilentlyContinue).ProcessName))." }
    }
    foreach ($port in $p.Udp) {
        $o = Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($o) { Fail "UDP port $port (needed by $($p.Name)) is already in use by PID $($o.OwningProcess)." }
    }
}

# --- 3. MariaDB ------------------------------------------------------------------------
Write-Step "Checking MariaDB service '$($FFXI.MariaDBSvc)'"
$svc = Get-Service -Name $FFXI.MariaDBSvc -ErrorAction SilentlyContinue
if (-not $svc) { Fail "MariaDB service '$($FFXI.MariaDBSvc)' is not installed." }
if ($svc.Status -ne 'Running') {
    Write-Step "MariaDB is $($svc.Status); starting it (a UAC prompt may appear)"
    try { Start-Service -Name $FFXI.MariaDBSvc }
    catch { Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', "Start-Service '$($FFXI.MariaDBSvc)'" }
}
$deadline = (Get-Date).AddSeconds(30)
while (-not (Test-TcpPort '127.0.0.1' $FFXI.MariaDBPort)) {
    if ((Get-Date) -gt $deadline) { Fail "MariaDB is not accepting connections on 127.0.0.1:$($FFXI.MariaDBPort)." }
    Start-Sleep -Milliseconds 500
}
Write-Ok "MariaDB is accepting connections on 127.0.0.1:$($FFXI.MariaDBPort)"

# --- 4. Database update (repository tool) -----------------------------------------------
if (-not $SkipDbUpdate) {
    Write-Step "Running tools\dbtool.py update"
    Push-Location $FFXI.ServerDir
    try {
        # stdin is closed so dbtool fails instead of hanging if it ever wants to prompt.
        $out = $null | & $FFXI.Python 'tools\dbtool.py' 'update' 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    $out | ForEach-Object { Write-Host "    $_" }
    if ($code -ne 0 -or ($out -match 'Incorrect mysql_login|does not exist|Error:|Traceback')) {
        Fail "dbtool update failed (exit $code). Server not started."
    }
}

# --- 5. Start processes in order --------------------------------------------------------
$started = @()
function Save-Pids { $started | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $FFXI.PidFile -Encoding utf8 }

foreach ($p in $FFXI.Processes) {
    $exe = Join-Path $FFXI.ServerDir "$($p.Name).exe"
    Write-Step "Starting $($p.Name) $($p.Args -join ' ')"
    # Logs are appended across runs: only a "ready to work" line written after this point counts.
    $log = Join-Path $FFXI.ServerDir ($p.Args[1] -replace '/', '\')
    $logLinesBefore = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log).Count } else { 0 }
    $proc = Start-Process -FilePath $exe -ArgumentList $p.Args -WorkingDirectory $FFXI.ServerDir -WindowStyle Minimized -PassThru
    $started += [pscustomobject]@{ Name = $p.Name; Pid = $proc.Id; StartTime = $proc.StartTime.ToString('o') }
    Save-Pids

    $deadline = (Get-Date).AddSeconds($p.TimeoutSec)
    while ($true) {
        if ($proc.HasExited) {
            Write-Bad "$($p.Name) exited during startup with code $($proc.ExitCode). Last log lines ($log):"
            if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 20 | ForEach-Object { Write-Host "    $_" } }
            Write-Bad "Stopping the processes already started..."
            & (Join-Path $PSScriptRoot 'Stop-Server.ps1') -Quiet
            exit 1
        }
        $tcpOk = @($p.Tcp | Where-Object { -not (Get-NetTCPConnection -State Listen -LocalPort $_ -OwningProcess $proc.Id -ErrorAction SilentlyContinue) }).Count -eq 0
        $udpOk = @($p.Udp | Where-Object { -not (Get-NetUDPEndpoint -LocalPort $_ -OwningProcess $proc.Id -ErrorAction SilentlyContinue) }).Count -eq 0
        # Ports open early (xi_map binds UDP ~20 s before it has loaded zones); also require the
        # server's own "<name>-server is ready to work" line (common/application.cpp markLoaded).
        $logOk = (Test-Path -LiteralPath $log) -and
                 (@(Get-Content -LiteralPath $log | Select-Object -Skip $logLinesBefore | Select-String -SimpleMatch 'is ready to work').Count -gt 0)
        if ($tcpOk -and $udpOk -and $logOk) { break }
        if ((Get-Date) -gt $deadline) {
            Write-Bad "$($p.Name) did not become ready (ports $((@($p.Tcp | ForEach-Object { "tcp/$_" }) + @($p.Udp | ForEach-Object { "udp/$_" })) -join ', ') open: $($tcpOk -and $udpOk); 'ready to work' logged: $logOk) within $($p.TimeoutSec)s."
            Write-Bad "It is still running (PID $($proc.Id)); check its console window and $($FFXI.ServerDir)\log\. Run Stop-Server.ps1 to clean up."
            exit 1
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Ok "$($p.Name) ready (PID $($proc.Id))"
}

Write-Ok "All server processes are up. Logs: $($FFXI.ServerDir)\log\"
exit 0
