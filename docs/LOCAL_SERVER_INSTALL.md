# Local Server Install — FFXI-Forever (Phoenix XI)

How the local Phoenix XI server on this machine was installed, configured, built and verified.
Exact versions and test results live in [LOCAL_SERVER_BASELINE.md](LOCAL_SERVER_BASELINE.md);
day-to-day use is in [LOCAL_SERVER_OPERATIONS.md](LOCAL_SERVER_OPERATIONS.md).

The authoritative guides for this revision are the copies **inside the checkout**:
`E:\FFXI-Forever\server\docs\wiki\Quick-Start-Guide.md` and `Client-Setup-Windows.md`.
Phoenix has no install docs of its own; the online LSB wiki may be newer than this revision.

## 1. Layout on this host

| What | Path |
|---|---|
| Phoenix server checkout (build output goes to its root) | `E:\FFXI-Forever\server` |
| Build logs | `E:\FFXI-Forever\buildlogs\` |
| Launcher PID file | `E:\FFXI-Forever\run\server-pids.json` |
| Copies of the applied Phoenix core patches | `E:\FFXI-Forever\patches\` |
| MariaDB 10.11 (service `MariaDB`, data + `my.ini`) | `E:\MariaDB 10.11\` |
| Ashita v4 + FFXI client (Phoenix client bundle, pre-existing) | `E:\PhoenixXI\` |
| Custom Ashita boot config | `E:\PhoenixXI\config\boot\local-ffxi-forever.ini` |
| Launchers, helper tools, these docs | `E:\Claude\Projects\FFXI-Forever\` (`launcher\`, `tools\`, `docs\`) |
| Desktop shortcut | `%USERPROFILE%\Desktop\FFXI-Forever.lnk` → `launcher\Play.cmd` |

`E:\PhoenixXI` is the Phoenix **client** install, not a server checkout, which is why the server
lives in its own folder. `E:\TitanXI` (a separate Titan client) was not touched.

## 2. Dependencies

Installed with winget unless noted. Versions follow the in-repo Quick-Start Guide (VS 2026,
MariaDB 10.11.x, Python 3.14.x); see the ADR for why VS 2026 rather than the design doc's VS 2022.

```powershell
winget install --id Git.Git --exact --source winget
winget install --id Python.Python.3.14 --exact --source winget --override "/quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1 Include_pip=1"
winget install --id Kitware.CMake --exact --source winget
winget install --id Microsoft.VisualStudio.BuildTools --exact --source winget --override "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

* **MariaDB 10.11**: winget only offers 10.9 or 11.x+, so the official MSI was used:
  `mariadb-10.11.19-winx64.msi` from `downloads.mariadb.org` (SHA-256
  `83af9d523bf7ba989ea0031d4ebca7e4dc21e49f435122570ddc87f0620b3a5c`, signed by MariaDB USA, Inc.), installed interactively to `E:\MariaDB 10.11`
  as service `MariaDB` (automatic start). Root has no remote access.
* Windows allows one MSI install at a time: the VS install fails with 1618 if the MariaDB
  installer is still open.
* Ninja comes with the VS Build Tools C++ workload; `tools\build.py` enters the VS developer
  environment itself, so no Developer PowerShell is needed.

### MariaDB hardening done here
* `E:\MariaDB 10.11\data\my.ini`: added `bind-address=127.0.0.1` under `[mysqld]`
  (backup: `my.ini.bak-ffxiforever-20261018-194321`). Service restarted via UAC.
* The installer created an inbound **Allow** firewall rule "MariaDB 10.11 (x64)"; with the loopback
  bind it no longer matters. Optional: set it to Block (see Operations → Firewall).
* The UTF8 option did not end up in `my.ini`; harmless, `xidb` is created explicitly as utf8mb4.

## 3. Clone

```powershell
git clone --recursive https://github.com/phoenixffxi/Phoenix.git E:\FFXI-Forever\server
py -3 -m pip install -r E:\FFXI-Forever\server\tools\requirements.txt
```

* Branch `beta` (the default), commit recorded in the baseline doc.
* Submodule `modules/phoenix_ac` points at Phoenix's private staff repo with `update = none`
  and is intentionally skipped for public clones. `modules/init.txt` still lists it, which only
  causes three harmless `init.txt entry does not exist: ./modules/phoenix_ac/...` errors in the
  map log. CMake and dbtool skip missing entries.

## 4. Apply Phoenix's core patches (required)

Phoenix keeps two core patches uncommitted in `modules/temp_patch/` and applies them when building
its live server. Without `phoenix-fishing.patch` the build fails (`fishing_history.cpp` /
`fishing_meters.cpp` need `fishingutils::FishingEvent` / `SetAccountMeterAccess`);
`lsb-yaml.patch` changes the YAML data merging used by the `era/data` and `phoenix/data` modules.
Nothing in the repo documents this step.

Git for Windows' system-wide `core.autocrlf=true` checks the `.patch` files out with CRLF
endings while `.gitattributes` forces the sources to LF, so applying the working-tree files fails.
Apply them from the git objects instead:

```powershell
cd E:\FFXI-Forever\server
cmd /c "git show HEAD:modules/temp_patch/lsb-yaml.patch > %TEMP%\lsb-yaml.patch"
cmd /c "git show HEAD:modules/temp_patch/phoenix-fishing.patch > %TEMP%\phoenix-fishing.patch"
git apply --check $env:TEMP\lsb-yaml.patch; git apply --check $env:TEMP\phoenix-fishing.patch
git apply $env:TEMP\lsb-yaml.patch; git apply $env:TEMP\phoenix-fishing.patch
```

Result: 20 modified files, left **uncommitted**. Snapshot of the exact diff:
`E:\FFXI-Forever\patches\temp_patch-applied-on-b48e2d4e.diff`. Undo with
`git apply -R` of the same two files (reverse order). After pulling a new Phoenix revision,
revert first, pull, then re-apply that revision's patches.

## 5. Configure

```powershell
Copy-Item E:\FFXI-Forever\server\settings\default\*.lua E:\FFXI-Forever\server\settings\
```
(`settings\*.lua` is gitignored; nothing existed there beforehand.)

`settings\network.lua` changes from default:
* `SQL_LOGIN = 'xiforever'`, `SQL_PASSWORD = <generated>` (written by the helper below; never commit).
* `LOGIN_DATA_IP` / `LOGIN_VIEW_IP` / `LOGIN_AUTH_IP` = `'127.0.0.1'` (default `'0.0.0.0'`).
  **These do not control binding in this revision** (listeners are hard-coded to all IPv4
  interfaces); `LOGIN_AUTH_IP` only feeds a ZMQ routing id and the self-signed cert. Harmless, kept.

All other settings (`main.lua`, `map.lua`, `login.lua`, …) are the shipped defaults. Zone routing
comes from the DB (`zone_settings`: every zone `127.0.0.1:54230`), matching a same-machine client.

## 6. Database

1. Dedicated account + database — run once (prompts for the MariaDB root password, hidden):
   ```powershell
   py -3 E:\Claude\Projects\FFXI-Forever\tools\setup_db_account.py
   ```
   Creates `xidb` (utf8mb4 / utf8mb4_general_ci, as dbtool does), account `xiforever`@`localhost`
   and @`127.0.0.1` with `ALL` on `xidb.*` only, a random 43-char password, verifies the login,
   then writes the password into `settings\network.lua`. Re-running rotates the password.
   For non-interactive use set `FFXI_DB_ROOT_PASSWORD` for that process only.
2. Tell dbtool where the MariaDB client is: `tools\config.yaml` → `mysql_bin: E:/MariaDB 10.11/bin/`
   (its interactive prompt does the same; piping the answer from PowerShell did not work).
3. Import schema + data (from `E:\FFXI-Forever\server`, git must be on PATH):
   ```powershell
   py -3 tools\dbtool.py update full
   ```
   Imports `sql\*.sql` plus module SQL from `init.txt`, runs migrations, records `db_ver`.
   Took 23 s; result: 125 tables, `item_basic` 23 537 rows, `synth_recipes` 4 446, empty
   `accounts`/`chars`. `dbtool.py update` (no `full`) is the routine, non-destructive check.

## 7. Build

```powershell
powershell -ExecutionPolicy Bypass -File E:\Claude\Projects\FFXI-Forever\tools\Build-Server.ps1
```
Wraps `py -3 tools\build.py` (CMake preset `default` = Ninja Multi-Config, **RelWithDebInfo**)
and logs to `E:\FFXI-Forever\buildlogs\`. Warnings are errors (`/WX`). First full build ≈ 12 min;
after patching, 98 steps. Outputs are copied to the repo root next to the bundled DLLs:
`xi_connect.exe`, `xi_search.exe`, `xi_profile.exe`, `xi_world.exe`, `xi_map.exe` (+ `xi_test.exe`).
Stop the server before rebuilding.

## 8. Client (Ashita v4)

`E:\PhoenixXI` already contained Ashita v4 (4.3.2.1), the FFXI client and the Phoenix bootloader.
`bootloader\phoenix-loader.exe` is byte-identical to the bundled `xiloader.exe`.

`config\boot\local-ffxi-forever.ini` is a copy of the pre-existing `local-phoenix.ini` with only the
launcher name changed, so display, gamepad, sandbox and pivot (EraDATs) settings are preserved.
Boot section: `file = .\bootloader\phoenix-loader.exe`, `command = --server 127.0.0.1`.
No credentials are stored; the bootloader console asks for Login (1) / Create New Account (2).
Ashita's example configs and `local-phoenix.ini` / `phoenix-launch.ini` were not modified.

## 9. Verify

See the acceptance-test table in [LOCAL_SERVER_BASELINE.md](LOCAL_SERVER_BASELINE.md). Quick check:
`launcher\Start-Server.cmd` must end with "All server processes are up", then the Desktop
shortcut launches the client.
