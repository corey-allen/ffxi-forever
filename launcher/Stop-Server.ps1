<#
.SYNOPSIS
    Stops only the FFXI-Forever server processes started by Start-Server.ps1.

.DESCRIPTION
    Processes are identified from the PID file and re-verified by exe path and start time, so
    nothing else (another server instance, a recycled PID) is touched. Stops in reverse start
    order (xi_map first). Each process first gets a console Ctrl+C, which the server handles
    as a graceful shutdown (src/common/application.cpp); it is force-terminated only if it has
    not exited after -GraceSeconds. Log out in-game before stopping to be safe.
#>
[CmdletBinding()]
param([int]$GraceSeconds = 20, [switch]$Quiet)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ffxi-forever.config.ps1')

# Sends CTRL_C to a console process. Runs in a separate hidden PowerShell because attaching to
# another console requires detaching from our own.
function Send-CtrlC([int]$targetPid) {
    $code = @"
Add-Type -Namespace W -Name K -MemberDefinition '
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint p);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);'
[W.K]::FreeConsole() | Out-Null
if (-not [W.K]::AttachConsole($targetPid)) { exit 2 }
[W.K]::SetConsoleCtrlHandler([System.IntPtr]::Zero, `$true) | Out-Null
if (-not [W.K]::GenerateConsoleCtrlEvent(0, 0)) { exit 3 }
Start-Sleep -Milliseconds 200
[W.K]::FreeConsole() | Out-Null
exit 0
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $h = Start-Process powershell.exe -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $enc -WindowStyle Hidden -PassThru -Wait
    return $h.ExitCode -eq 0
}

$live = @(Get-FFXIServerProcesses)
if ($live.Count -eq 0) {
    if (-not $Quiet) { Write-Ok "No FFXI-Forever server processes are running (per $($FFXI.PidFile))." }
    if (Test-Path -LiteralPath $FFXI.PidFile) { Remove-Item -LiteralPath $FFXI.PidFile }
    exit 0
}

$order = @($FFXI.Processes | ForEach-Object { $_.Name }); [array]::Reverse($order)
$failed = @()
foreach ($name in $order) {
    foreach ($entry in @($live | Where-Object Name -eq $name)) {
        $p = $entry.Process
        Write-Step "Stopping $name (PID $($entry.Pid))"
        $sent = Send-CtrlC $entry.Pid
        if (-not $sent) { Write-Host "    could not deliver Ctrl+C; will force-terminate after the grace period" }
        if (-not $p.WaitForExit($GraceSeconds * 1000)) {
            Write-Bad "    $name did not exit within ${GraceSeconds}s; terminating"
            try { $p.Kill(); $p.WaitForExit(10000) | Out-Null } catch { $failed += $name }
        }
        if ($p.HasExited) { Write-Ok "    $name stopped" } else { $failed += $name }
    }
}

if ($failed.Count -gt 0) { Write-Bad "Could not stop: $($failed -join ', ')"; exit 1 }
Remove-Item -LiteralPath $FFXI.PidFile -ErrorAction SilentlyContinue
Write-Ok "Server stopped."
exit 0
