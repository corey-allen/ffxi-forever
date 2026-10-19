# FFXI-Forever local launcher configuration (dot-sourced by the other scripts).
# Edit paths here if anything moves. Contains no secrets: the DB password lives only
# in the server's gitignored settings\network.lua.

$FFXI = @{
    ServerDir     = 'E:\FFXI-Forever\server'
    RunDir        = 'E:\FFXI-Forever\run'            # PID file + launcher logs
    Python        = 'C:\Users\Corey\AppData\Local\Programs\Python\Python314\python.exe'
    MariaDBSvc    = 'MariaDB'
    MariaDBPort   = 3306
    AshitaDir     = 'E:\PhoenixXI'
    AshitaCli     = 'E:\PhoenixXI\Ashita-cli.exe'
    BootConfig    = 'local-ffxi-forever.ini'          # in E:\PhoenixXI\config\boot\
    ZoneIp        = '127.0.0.1'

    # Start order matches tools/dbtool.py "Launch Server". Ready = process alive and
    # listening on every port listed (ports come from settings\network.lua defaults).
    Processes     = @(
        @{ Name = 'xi_connect'; Args = @('--log', 'log/connect-server.log'); Tcp = @(54230, 54231, 54001); Udp = @();      TimeoutSec = 60  }
        @{ Name = 'xi_search';  Args = @('--log', 'log/search-server.log');  Tcp = @(54002);               Udp = @();      TimeoutSec = 60  }
        @{ Name = 'xi_profile'; Args = @('--log', 'log/profile-server.log'); Tcp = @(51220, 51240);        Udp = @();      TimeoutSec = 60  }
        @{ Name = 'xi_world';   Args = @('--log', 'log/world-server.log');   Tcp = @(54003);               Udp = @();      TimeoutSec = 60  }
        @{ Name = 'xi_map';     Args = @('--log', 'log/map-server-54230.log', '--ip', '127.0.0.1', '--port', '54230'); Tcp = @(); Udp = @(54230); TimeoutSec = 300 }
    )
}

$FFXI.PidFile = Join-Path $FFXI.RunDir 'server-pids.json'

# dbtool needs git on PATH; reload it from the registry so a shell opened before tools were
# installed (or an odd shortcut environment) still works.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

function Write-Step([string]$msg)  { Write-Host "[FFXI-Forever] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)    { Write-Host "[FFXI-Forever] $msg" -ForegroundColor Green }
function Write-Bad([string]$msg)   { Write-Host "[FFXI-Forever] $msg" -ForegroundColor Red }

# Returns live server processes recorded in the PID file, verified by PID + exe path + start
# time so a recycled PID belonging to some other program is never treated as ours.
function Get-FFXIServerProcesses {
    if (-not (Test-Path -LiteralPath $FFXI.PidFile)) { return @() }
    try { $entries = Get-Content -LiteralPath $FFXI.PidFile -Raw | ConvertFrom-Json } catch { return @() }
    $live = @()
    foreach ($e in @($entries)) {
        $p = Get-Process -Id $e.Pid -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $path = $null; try { $path = $p.Path } catch {}
        $expected = Join-Path $FFXI.ServerDir ("{0}.exe" -f $e.Name)
        if ($path -and ($path -ieq $expected) -and ($p.StartTime.ToString('o') -eq $e.StartTime)) {
            $live += [pscustomobject]@{ Name = $e.Name; Pid = $e.Pid; Process = $p }
        }
    }
    return $live
}

function Test-TcpPort([string]$hostName, [int]$port, [int]$timeoutMs = 1500) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($hostName, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
        $c.EndConnect($iar); return $true
    } catch { return $false } finally { $c.Close() }
}
