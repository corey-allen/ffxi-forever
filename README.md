# ffxi-forever

A private, locally hosted FFXI world built on the [Phoenix XI](https://github.com/phoenixffxi/Phoenix)
fork of LandSandBoat, with a planned auditable Mercantile Guild economy and persistent autonomous
adventurers. The governing spec is [docs/MASTER_TECHNICAL_DESIGN.md](docs/MASTER_TECHNICAL_DESIGN.md).

**Status:** FIRST TASK (playable local baseline) complete — awaiting review before Phase 1.

This repo holds the project's own work, not the Phoenix server source. The server is reproduced
from upstream Phoenix commit `b48e2d4e` plus the patches in `patches/`.

| Path | Contents |
|---|---|
| `docs/LOCAL_SERVER_INSTALL.md` | How the server, DB, build and client were set up |
| `docs/LOCAL_SERVER_OPERATIONS.md` | Start/stop, logs, backup, updates, firewall, troubleshooting |
| `docs/LOCAL_SERVER_BASELINE.md` | Exact versions, files changed, acceptance-test results |
| `docs/architecture/decisions/` | ADRs |
| `launcher/` | `Play.cmd`, `Start-Server.cmd`, `Stop-Server.cmd`, `Launch-Client.cmd` (+ `.ps1`) |
| `tools/` | `setup_db_account.py` (DB account), `Build-Server.ps1` |
| `config/ashita/` | Ashita v4 boot config used for local play |
| `patches/phoenix-b48e2d4e/` | Phoenix's own core patches, required to build that commit |

Paths in the scripts and docs are specific to the original Windows host
(`E:\FFXI-Forever\server`, `E:\PhoenixXI`); edit `launcher/ffxi-forever.config.ps1` to relocate.
No credentials are stored in this repository.

Licensed GPL-3.0 (see `LICENSE`), consistent with LandSandBoat/Phoenix.
