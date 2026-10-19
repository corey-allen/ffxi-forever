# ADR-0000: Local server installation baseline

* Status: Accepted (owner approved each decision in session, 18 Oct 2026)
* Scope: FIRST TASK (playable local baseline). Gameplay/extension strategy is ADR-0001.

## Context
The master design asks for a local Phoenix XI server with VS 2022, the server at `E:\PhoenixXI`,
and no source changes beyond what a valid baseline requires. Inspection showed conflicts.

## Decisions

1. **Server location `E:\FFXI-Forever\server`.** `E:\PhoenixXI` is the existing Phoenix client
   install (Ashita + FFXI). The design's alternative `E:\FFXI Forever` contains a space, which the
   LSB build-troubleshooting guide advises against.
2. **Baseline = `phoenixffxi/Phoenix` branch `beta` @ `b48e2d4e`** (remote default). Updates are
   deliberate (operations doc), never automatic.
3. **Visual Studio 2026 Build Tools instead of VS 2022.** The in-repo Quick-Start Guide for this
   revision requires VS 2026; the code is C++23. Build Tools (not the IDE) are sufficient.
4. **MariaDB 10.11.19 from the official MSI**, not winget (winget has no 10.11 package).
   Bound to 127.0.0.1. Dedicated `xiforever` account limited to `xidb.*` instead of the guide's
   root login.
5. **Apply Phoenix's `modules/temp_patch/*.patch` to the core, uncommitted.** Phoenix's own
   modules do not compile without `phoenix-fishing.patch`, and `lsb-yaml.patch` is required by its
   YAML data modules. These are the fork's intended baseline, not an outside change; they alter
   fishing behaviour and packet blocking while fishing as Phoenix does. Applied from git objects
   (LF) because Git for Windows' `autocrlf` breaks the working-tree copies. Snapshot saved.
6. **Five server processes, not four.** This revision adds `xi_profile` (TCP 51220/51240).
7. **Shipped default settings for gameplay.** No era/rate changes in this phase.
8. **Launcher manages processes by recorded PID + exe path + start time**, graceful Ctrl+C stop.

## Consequences
* Updating Phoenix requires reverting and re-applying temp patches (documented).
* Network exposure is controlled by Windows Firewall, not bind addresses (listeners are hard-coded
  to all interfaces); owner action needed to block the auto-created Allow rules.
* Whether the default settings match the "classic level-75 / 2006-era" target is unresolved and
  must be decided before gameplay-affecting work.
