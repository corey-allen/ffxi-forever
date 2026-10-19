# Local Server Operations — FFXI-Forever (Phoenix XI)

Everything below works from any directory or shortcut; scripts use absolute paths.
Paths are configured in one place: `launcher\ffxi-forever.config.ps1`.

## Everyday use

| Want to… | Do this |
|---|---|
| Play (start server if needed, then client) | Desktop shortcut **FFXI-Forever**, or `launcher\Play.cmd` |
| Start server only | `launcher\Start-Server.cmd` (add `-SkipDbUpdate` to skip the dbtool check) |
| Launch client only (server must be up) | `launcher\Launch-Client.cmd` |
| Stop server | `launcher\Stop-Server.cmd` — **log out in-game first** |
| Rebuild after source changes | stop server, then `tools\Build-Server.ps1` |

In the bootloader console: `1` = Login, `2` = Create New Account.

## What Start-Server does
1. Checks the five executables and `settings\network.lua` exist.
2. Refuses to double-start: if its recorded processes are alive it says so and exits; if
   `xi_*` processes from this folder are running that it did not start, or a needed port is
   taken, it stops with the owning PID.
3. Ensures service `MariaDB` is running (UAC prompt if it must start it) and port 3306 answers.
4. Runs `tools\dbtool.py update` (says "Database is up to date." when nothing changed; never
   prompts — stdin is closed so a prompt fails instead of hanging).
5. Starts, in order, each in a minimized console window, waiting until each is listening **and**
   has logged its own "…-server is ready to work" line (xi_map opens its port ~20 s before it is
   actually ready):

| Process | Ready when listening on | Log |
|---|---|---|
| xi_connect | tcp 54230, 54231, 54001 | `log\connect-server.log` |
| xi_search  | tcp 54002 | `log\search-server.log` |
| xi_profile | tcp 51220, 51240 | `log\profile-server.log` |
| xi_world   | tcp 127.0.0.1:54003 (ZMQ) | `log\world-server.log` |
| xi_map     | udp 54230 | `log\map-server-54230.log` |

If a process exits during startup it prints the last 20 log lines and stops the others.
Typical start: 7–25 s. PIDs + start times go to `E:\FFXI-Forever\run\server-pids.json`.

## What Stop-Server does
Stops only processes listed in the PID file **and** matching exe path and start time (never by
name), in reverse order (map first). Each gets a console Ctrl+C, which the server treats as a
graceful shutdown (`src/common/application.cpp`); only if it is still alive after 20 s
(`-GraceSeconds`) is it terminated. Verified: all five exit on Ctrl+C in ~12 s total.

## Logs
* Server: `E:\FFXI-Forever\server\log\*.log` (appended each run). Crash dumps, if any, in `dmp\`.
* Client/Ashita: `E:\PhoenixXI\logs\`.
* Builds: `E:\FFXI-Forever\buildlogs\`.

Expected, harmless log lines on every start:
* map: `init.txt entry does not exist: ./modules/phoenix_ac/{cpp,lua,sql}` (private submodule).
* map: `Failed to look up key: logging.PACKET_CAPTURE_DIR` (packetcap module default).
* map: `[AH PAGES] AH_LIST_LIMIT is already set to 7 … This module isn't required.`
* map at logout: `Invalid GP_CLI_COMMAND_POS packet … Character is shutting down`.

## Backup and restore
Back up before migrations, Phoenix updates, or anything experimental.

```powershell
cd E:\FFXI-Forever\server
py -3 tools\dbtool.py backup          # full dump into sql\backups\
py -3 tools\dbtool.py backup lite     # player (protected) tables only
```
Also copy `settings\*.lua`, `tools\config.yaml` and `E:\FFXI-Forever\patches\` alongside the dump
and note the commit (`git -C E:\FFXI-Forever\server log -1`). Keep code version, DB dump and
config together; never restore only some tables from a different DB state.

Restore: stop the server, then use dbtool's interactive menu (`py -3 tools\dbtool.py`; it reads
backups from `sql\backups\`). **Not yet exercised on this host** — neither backup nor restore has
been tested; do a restore into a disposable database before trusting it.

## Updating Phoenix (deliberately, not routinely)
1. Stop server; back up DB + settings.
2. Revert the temp patches (`git apply -R` of the saved LF patch files, fishing first, then yaml).
3. `git pull` / checkout the chosen commit; `git submodule update --init`.
4. Re-apply that revision's `modules/temp_patch/*.patch` (LF method in the install doc).
5. Rebuild; `py -3 tools\dbtool.py update`; start; re-run the acceptance tests; update the baseline doc.

## Firewall
The server binds all IPv4 interfaces (hard-coded). On first start Windows created inbound
**Allow** rules (Public profile, any remote address) for `xi_connect`, `xi_search`, `xi_profile`
and `xi_map`. Local play does not need them (loopback is not filtered). To keep the server
local-only, in an **administrator** PowerShell:

```powershell
Get-NetFirewallApplicationFilter | Where-Object Program -like '*\ffxi-forever\server\*' | Get-NetFirewallRule | Set-NetFirewallRule -Action Block
Set-NetFirewallRule -DisplayName 'MariaDB 10.11 (x64)' -Action Block
```
Do not disable Windows Firewall and do not port-forward.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `dbtool update failed` / `Make sure git is installed` | git not on PATH in that environment; the launcher reloads PATH from the registry, check Git is installed. |
| `Incorrect mysql_login or mysql_password` | `settings\network.lua` out of sync — re-run `tools\setup_db_account.py`. |
| MariaDB not accepting connections | `Get-Service MariaDB`; check `E:\MariaDB 10.11\data\*.err`. |
| A process "exited during startup" | read the printed log tail; common: DB credentials, port in use, missing DLL (rebuild). |
| "did not open its ports within Ns" | process still running — look at its console window; run Stop-Server to clean up. |
| Client: `incorrect client version` in connect log | client version below `CLIENT_VER` in `settings\login.lua` (`VER_LOCK = 2`); launch via the FFXI-Forever shortcut / `local-ffxi-forever.ini`. |
| Client: `stream truncated` / `Failed to handshake` + `incorrect client version: got Unknown` | One of each per login is **normal on this setup** (seen on every successful login). Only a problem if login never succeeds → check bootloader is `phoenix-loader.exe`/xiloader, not `pol.exe`. |
| Build: `fishingutils … is not a member` | temp patches not applied (install doc §4). |
| Build: `patch does not apply` | CRLF patch file — apply from `git show HEAD:...` as documented. |
