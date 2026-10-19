# Local Server Baseline — FFXI-Forever (Phoenix XI)

Recorded 18 October 2026. This is the reproducible starting point for all later phases.

## Source

| Item | Value |
|---|---|
| Repository | https://github.com/phoenixffxi/Phoenix.git (fork of LandSandBoat) |
| Branch | `beta` (remote default) |
| Commit | `b48e2d4ecb8a3b0fd5f4094cf86b76807e04840f` — "Merge pull request #314 from phoenixffxi/King-Arthro-Persistence" (2026-10-18 13:32 -0400) |
| Submodules | `navmeshes` e8ca9f0, `ximeshes` 906d725; `modules/phoenix_ac` not initialised (private, `update = none`) |
| Local source changes | Phoenix's own `modules/temp_patch/lsb-yaml.patch` + `phoenix-fishing.patch` applied, uncommitted (20 files, +774/−258). Diff: `E:\FFXI-Forever\patches\temp_patch-applied-on-b48e2d4e.diff` |
| Local config (gitignored) | `settings\*.lua` copied from `settings\default`; `network.lua`: `SQL_LOGIN`, `SQL_PASSWORD`, `LOGIN_*_IP`; `tools\config.yaml`: `mysql_bin` |
| DB version (dbtool) | `db_ver: b48e2d` |

## Toolchain

| Component | Version | Path |
|---|---|---|
| Windows | 11 Home 10.0.26300 x64 | |
| Git for Windows | 2.55.0.windows.5 | on PATH |
| Python | 3.14.7 (+ `tools/requirements.txt`, e.g. mariadb 1.1.14) | `%LOCALAPPDATA%\Programs\Python\Python314\python.exe` |
| CMake (used for build) | 4.4.4 (Kitware) | `C:\Program Files\CMake\bin\cmake.exe` |
| Ninja | 1.13.2 (VS-bundled) | `…\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\` |
| Visual Studio | Build Tools 2026 18.11.0, VCTools workload | `C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools` |
| MSVC | toolset 14.51.36231, cl 19.51.36260 | |
| Windows SDK | 10.0.26100.0 | |
| MariaDB | 10.11.19 (service `MariaDB`, auto start, bound to 127.0.0.1:3306) | `E:\MariaDB 10.11` |
| Ashita | v4 4.3.2.1 (pre-existing) | `E:\PhoenixXI` |
| Bootloader | `phoenix-loader.exe` (= `xiloader.exe`, SHA-256 E1282885…B732C) | `E:\PhoenixXI\bootloader` |

## Build

`tools\Build-Server.ps1` → `py -3 tools\build.py` → `cmake --preset default` + `cmake --build --preset default`
(Ninja Multi-Config, RelWithDebInfo, `/WX`). Result: **succeeded**, 0 errors.
First attempt (before patches) failed at step 984/986 in `fishing_history.cpp` / `fishing_meters.cpp`.

## Runtime

| Process | Listens on | Notes |
|---|---|---|
| xi_connect | tcp 0.0.0.0:54001, 54230, 54231 | generates self-signed `login.cert/.key` |
| xi_search | tcp 0.0.0.0:54002 | |
| xi_profile | tcp 0.0.0.0:51220, 51240 | Phoenix/LSB profile + IRC; generates `profile.cert/.key` (not in the upstream 4-process guide) |
| xi_world | tcp 127.0.0.1:54003 | ZMQ message broker |
| xi_map | udp 0.0.0.0:54230 | one process, all zones (`zone_settings` = 127.0.0.1:54230) |

Database `xidb`: 125 tables, utf8mb4/utf8mb4_general_ci, account `xiforever` (rights on `xidb.*` only).

Gameplay settings are the shipped defaults of this revision (e.g. `main.lua` has every
expansion flag `= 1`, `SERVER_NAME = 'Nameless'`); era behaviour comes from Phoenix's modules in
`modules/init.txt`. **No gameplay settings were changed.** Whether these defaults equal the desired
"classic / 2006-era" baseline is an open decision for the next phase.

## Files created or modified

Created (project, `E:\Claude\Projects\FFXI-Forever`): `launcher\ffxi-forever.config.ps1`,
`Start-Server.ps1/.cmd`, `Stop-Server.ps1/.cmd`, `Launch-Client.ps1/.cmd`, `Play.ps1/.cmd`;
`tools\setup_db_account.py`, `tools\Build-Server.ps1`; `docs\LOCAL_SERVER_*.md`;
`docs\architecture\decisions\ADR-0000-local-server-baseline.md`.

Created elsewhere: `E:\FFXI-Forever\` (checkout, buildlogs, run, patches);
`E:\PhoenixXI\config\boot\local-ffxi-forever.ini`; Desktop `FFXI-Forever.lnk`;
server-generated `login.*` / `profile.*` certs in the checkout root.

Modified: checkout working tree (temp patches, above); gitignored `settings\network.lua`,
`tools\config.yaml`; `E:\MariaDB 10.11\data\my.ini` (+`bind-address=127.0.0.1`, backup kept).
Not modified: `local-phoenix.ini`, `phoenix-launch.ini`, Ashita examples, `modules/init.txt`,
any gameplay setting, `E:\TitanXI`.

## Acceptance tests

| Test | Result | Evidence |
|---|---|---|
| Remote/branch/commit recorded | PASS | above |
| Submodules present | PASS (public ones) | `git submodule status`; `phoenix_ac` private by design |
| Git, Python, CMake, VS C++ usable | PASS | versions above; successful build |
| MariaDB starts, Phoenix connects | PASS | service Running/Automatic; dbtool + all five processes connect |
| DB initialised with matching schema/data | PASS | `dbtool update full` OK, no migrations pending, `db_ver b48e2d` |
| All binaries compile | PASS | build log, 0 errors |
| Runtime DLLs available | PASS | processes start from repo root with bundled DLLs |
| Every process starts, none exits | PASS | launcher readiness checks; processes alive |
| Logs show DB connectivity / init | PASS | only the expected lines listed in the operations doc |
| Correct local addresses/ports | PASS | zone 127.0.0.1:54230, search 127.0.0.1:54002 in connect log |
| Shutdown stops intended processes | PASS | Ctrl+C, all exited within grace, none killed, none left |
| Restart without DB repair | PASS | restart in 7 s; "Database is up to date." |
| Duplicate start prevented | PASS | second start reports running PIDs, starts nothing |
| Launcher from other dir / .cmd | PASS | started from `C:\`, `%USERPROFILE%` (via .cmd), `D:\` |
| Ashita starts with custom ini, correct client | PASS | user report; logged-in session via 127.0.0.1 |
| Account creation | PASS | `accounts` id 1000 created 20:24:02 |
| Character creation | PASS | connect log 20:25:22 "char <Bajablast> was successfully created" |
| Enter world, move, basic actions | PASS | map log zone-in 230 (S. San d'Oria) 20:25:30; 478 s playtime; user report |
| Disconnect without blocking errors | PASS | clean logout 20:33:29, no open sessions |
| Full server stop + restart via Desktop shortcut | PASS | new PIDs 20:37:27–30 recorded by launcher (Play.cmd) |
| Reconnect after server restart | PASS | connect 20:37:49 charid 1 → 127.0.0.1:54230; map 20:37:53 "Player <Bajablast> logging in to zone <230>" |
| Desktop shortcut launches server + client | PASS | as above |

**Login-sequence quirk (consistent, non-blocking):** every login so far (20:23–20:25 and
20:37) logs one TLS `stream truncated` / `Failed to handshake!` and one
`incorrect client version: got Unknown…` in `connect-server.log`, followed seconds later by a
successful login. Cause not determined (likely the bootloader's connection sequence); no player impact seen.

**Launcher readiness fix (after the restart test):** xi_map binds UDP 54230 ~20 s before it logs
"map-server is ready to work", so the launcher could launch the client early (the 20:37 login
only succeeded after the map was ready by timing). `Start-Server.ps1` now also waits for each
process's own "is ready to work" log line. Parse- and logic-checked against the real log;
**not yet exercised in a live start.**

## Known gaps / open issues
* Next start should confirm the stricter readiness check live (expect xi_map to take ~20 s).
* Server ports bind all interfaces and Windows created Allow rules on the Public profile; owner
  to set them to Block (operations doc). The `LOGIN_*_IP` edit does not affect binding.
* Backup/restore not yet exercised.
* Owner to rotate the MariaDB root password set during install
  (`ALTER USER 'root'@'localhost' IDENTIFIED BY '…'`). The server does not use root.
* Era/classic gameplay baseline not yet reviewed against the design goals.
