# Assessment: NatePillow/LandSandBoat as the world-bot foundation

23 Oct 2026 · brief: [CLAUDE_MASTER_TECHNICAL_DESIGN.md](../CLAUDE_MASTER_TECHNICAL_DESIGN.md) · read-only. Nothing on the
server or the baseline was changed.

**Owner direction (23 Oct):**
* Nate's design and code supply the autonomous world bots that populate the server.
* The economy comes later, from AutoAH plus Titan's Mercantile and Fieldcraft guilds.
* None of the cancelled FFXI-Forever work is reused.

Where the brief asks to map Nate's code to "our existing bot driver/ledger", there is nothing to map: the baseline is
the clean Phoenix install.

## 1. What was inspected
| | Repository | Pinned commit | Notes |
|---|---|---|---|
| Nate | `NatePillow/LandSandBoat`, branch `singleplayer` (default) | `1982bfd348` (2026-08-07) | Fork of `LandSandBoat/server`, GPL-3.0. Upstream base `baeabac590` (2026-06-16) plus 3 squashed commits: **1 344 files, +108 764 / −2 387 lines**. Last push 2026-10-04. |
| Ours | `phoenixffxi/Phoenix` | `b48e2d4e` (2026-10-18) + 2 Phoenix temp patches | Phoenix's history **contains** Nate's base: it is that base plus **3 699** later commits. |

Local copy for inspection: `E:\FFXI-Forever\research\nate-lsb` (shallow clone, outside the server and the repo).

### Where Nate's changes are
| Area | Files | Lines | What |
|---|---|---|---|
| `modules/singleplayer/bots/` | 31 | ≈ 22 000 | The bot AI, in Lua: roles, magic, abilities, skillchains, formation, pulling, rest, items, lotting, threat, gear swaps, progression cascade |
| `modules/singleplayer/lib/` | 2 | 25 400 | `item_list.lua` (data), `json.lua` |
| `modules/singleplayer/lua/`, `sql/` | 55 | — | Trust overrides; SQL for trust spells, drop rates, recipes |
| `src/map/singleplayer/` | 30 | 6 945 | C++: headless sessions, character creation, Lua bindings and hooks, op/packet registries, **auction bot**, 3 **HTTP servers** (config, auction, char) |
| `src/map/packets/` | 118 | 7 099 | Custom packets for the addon suite |
| Other core (`ai`, `lua`, `entities`, `utils`, `party.cpp`, session container, packet system, spawn handler, navmesh) | ≈ 50 | ≈ 1 600 | Engine extensions and hooks |
| `singleplayer/client/` | 830 | 24 777 | Ashita **v3** addons (autobots, autoequip, automog, autolot, autodps, autowarp) |
| `singleplayer/config/` | 31 | 10 803 | Alliance, food, AshitaCast and other configs |
| `settings/default/` | 4 | — | Single-player tuning (below) |

## 2. How Nate's headless characters work (from source)
* **Real characters.** Each is a full `CCharEntity` from the database (`charutils::LoadChar`), with inventory, gear,
  spells, recasts and status effects, living in the zone like a player. A real client logging in as that character
  evicts the headless one (`destroyHeadlessByCharId`).
* **They are companions with an owner.** `MapSessionContainer::createHeadlessSession(charId, parentChar, …)`
  (`src/map/map_session_container.h`, `src/map/singleplayer/bot_sessions.cpp`) requires a live **parent player**:
  * the bot is inserted into the parent's zone;
  * the parent's session watchdog keeps it alive;
  * it changes zone only when the parent does (`moveHeadlessToPrimaryZone`);
  * it is despawned with the parent (`destroyHeadlessForParent`).
* **One alliance per server.** The AI state is a singleton, `xi.singleplayer.bots.alliance`
  (`modules/singleplayer/bots/docs/ARCHITECTURE.md`), with `mainCharId`/`mainEntity` (24 references), one tank as
  everyone's assist target, a camp anchor and formations. The spawn configuration is one JSON alliance per player
  (`singleplayer/config/alliance/*.json`), started from the autobots addon.
* **Decision loop.** Each tick, `bots.runCombatTick` dispatches on the bot's role. Roles are Tank, Melee, Healer, Rdm,
  Nuker, Brd, Smn and skill-up; each role module is a priority cascade over shared helpers (`ai_ability`, `ai_magic`,
  `ai_threat`, `ai_util`). Engine state is read rather than mirrored. Strong points: skillchains and magic bursts
  (with ms-precision timing), provoke, stun and sleep pools, puller selection by distance, `/check` category and name,
  item use, resting, lotting, and gear sets from AshitaCast XML evaluated **server-side**.
* **Not present:** any decision about *where* to go (no zone travel or routing), camp or level-area choice, goals or
  schedules, or acting without the parent. Progression is meant to be shared: the "progression cascade" copies quest,
  mission and teleport progress from the main character to the bots. That is the opposite of the brief's "no copied
  progression".
* **Scale.** Designed for one player's alliance: up to 18 characters plus trusts in one map process. Their own TODO
  says cross-process zones are unsupported. **No demonstrated scale beyond one alliance; no performance data.**
* **Tests.** No automated tests were found for the bot AI; their testing is play-and-report (DIARY.md).

## 3. Reuse-versus-build matrix (for an autonomous world population)
Classes:
1. reusable with minimal changes;
2. reusable after adaptation;
3. significant porting;
4. must be built (not in Nate's code);
5. not worth adopting for this goal.

| Capability | Class | Source | Notes / risk |
|---|---|---|---|
| Headless character entity (load, persist, live in zone, evicted by a real login) | 2 | `bot_sessions.cpp`, `map_session_container.*`, `lifecycle_hooks.cpp`, `post_tick.cpp` | Needs a **parentless** mode: a session that owns itself (zone, position, watchdog) instead of borrowing the parent's. The central change; touches core session code |
| Character creation and provisioning without a client | 1 | `char_create.cpp`, `provisionNewCharacter` | Creates finished starting characters server-side. Exactly what a population needs |
| Combat roles (tank/melee/heal/rdm/nuke/brd/smn), magic, abilities, threat | 2 | `bots/role_*.lua`, `ai_magic.lua`, `ai_ability.lua`, `ai_threat.lua` | Written against the alliance singleton; state must move to **per-party** objects so many groups can run at once |
| Skillchains / magic bursts, pull logic, formations, resting | 2 | `ai_formation.lua`, `ai_puller.lua`, `ai_rest.lua`, `ai_pool.lua` | Same singleton refactor; the puller already filters by `/check`, distance and name |
| Server-side gear swaps (AshitaCast XML) | 1 | `ai_equip_swap.lua`, `config/AshitaCast` | Per character, no client needed |
| Item use, lotting, inventory consolidation | 1–2 | `ai_item.lua`, `ai_lot.lua`, `sortInventory` binding | Lotting assumes the owner's alliance rules |
| Engine extensions (WS properties, ms status times, Lua bindings) | 1 | `luautils.cpp`, `lua_statuseffect.cpp`, `lua_bindings.cpp` | Small, self-contained |
| Travel between zones, camp/area choice by level, goals, schedules, independent progression | **4** | — | **Not in Nate's code.** The "world" layer: a director that forms parties, picks camps, routes them and keeps each bot's own progress |
| Many concurrent parties; scale toward 500–1 000 characters | **4** | — | Needs the per-party refactor plus tick budgeting; unproven at any scale above one alliance |
| Progression cascade (copy quests/missions/teleports) | **5** | `bots_progression_cascade*` | Contradicts the brief; leave disabled |
| Ashita v3 addon suite and custom packets for it | 5 (for world bots) | `singleplayer/client/`, `src/map/packets/` | Owner UI for companion parties; world bots need none. Our client is Ashita **v4**. Optional later as an admin UI |
| Auction bot (auto-buy, 15-min restock) | 5 for now | `auction_bot.cpp`, `auction_http.cpp` | Overlaps the planned AutoAH; decide in the economy phase |
| Single-player gameplay tuning | 5 | `settings/default/*.lua`, `sql/drop_rate_updates.sql` | E.g. `ALL_MAPS=1`, `DISABLE_PARTY_EXP_PENALTY=true`, `HEALING_TP_CHANGE=0`, chest/coffer timers 5–10 s, NM lottery off, Dynamis 1 h, raised drop rates. Not era-faithful; must stay off |
| HTTP config/auction/char servers | 5 unless locked down | `config_http_server.cpp`, `char_http.cpp`, `auction_http.cpp` | **Security:** default bind `0.0.0.0:51220`, **unauthenticated**, can enumerate characters and read inventories. Port 51220 also **collides with Phoenix's xi_profile**. If any part is kept: bind 127.0.0.1, move the port |

## 4. Dependencies and core patches
* **Build:** the same LSB toolchain (CMake, MSVC, MariaDB); `ext/CMakeLists.txt` adds a vendored HTTP library
  (`httplib`). No external services.
* **Core files touched by Nate: 199 under `src/`.** **56** of them were also changed by Phoenix/upstream since Nate's
  base, so they are merge-conflict candidates. Among them: `map_session_container.*`, `packet_system.*`,
  `map_engine.cpp`, `map_networking.cpp`, `0x00a_login.cpp`, `0x015_pos.cpp`, the AI states (ability, magic,
  weaponskill, range), `luautils.*`, `pathfind.*`, `navmesh.h`, `party.cpp`.
* **Data:** module SQL (trust and spell updates, recipes, drop rates). The headless state needs no new tables: it uses
  the normal character tables. Configuration lives in JSON files on disk.
* **Client:** Ashita v3 addons (only for the companion UI).
* **License:** GPL-3.0, the same as LandSandBoat and Phoenix, so it is compatible. New files carry
  "Copyright (c) 2026 Single Player Dev Teams" headers, which must be kept. Redistribution must stay GPL-3.0 with
  source.

## 5. Options compared
| | A. Build our own bots | B. Port Nate's mod onto the Phoenix pin, then add a world layer | C. Switch the server to Nate's fork, then add a world layer |
|---|---|---|---|
| Matches owner direction | No (rejected) | Yes | Yes |
| Server base | Phoenix `b48e2d4e` | Phoenix `b48e2d4e` | LSB June 2026 + Nate's mod |
| First step | — | Merge Nate's 3 commits onto Phoenix; resolve ≈ 56 core conflicts; then rebuild and test | Build Nate's fork as-is |
| Era fidelity | — | Phoenix era modules stay; Nate's single-player tuning left off | Nate's 75-cap tuning, but single-player changes must be undone; Zilart/CoP "underway", ToAU "likely" |
| Upstream currency | — | Current (Oct 2026) | **3 699 upstream/Phoenix commits behind**; rebasing later costs the same merge as B |
| Regression risk | — | Medium: conflicts sit in session and packet core | Medium: Phoenix-specific fixes and modules lost |
| Effort to first working companion bot | — | **M** (merge + build) | **S** (build) |
| Effort to world population | — | **L**: parentless sessions, per-party state, director (travel, camps, goals) | **L**: same work |
| Long term | — | One base, kept current | Two bases to reconcile, or Phoenix abandoned |

**The "world layer" work is the same under B and C.** Nate's code gives working characters and very good in-combat
behavior, but no ownerless mode, no multi-group state, and no world decisions. So the real choice is between B and C,
and it comes down to whether to keep Phoenix as the server.

## 6. Recommendation
**B: port Nate's mod onto the Phoenix pin, but prove it first in two small, reversible steps.**
* Phoenix is the server you chose and is current. Nate's base is already in its history, so the merge is bounded
  (56 conflict candidates, not a rewrite).
* The single-player tuning, progression cascade, addon packets and HTTP servers can be left out or disabled, which
  shrinks the port.

**The world layer cannot be avoided.** About 22 000 lines of combat AI come for free, but the part that makes them
*world* bots (ownerless, many groups, travel, goals, independent progression) is not in Nate's code. It must be built
on top of his framework, ideally as a module that changes as little of his code as possible.

## 7. Proof of concept (smallest and reversible)
**PoC-1: Nate's fork as-is, isolated** (no change to the Phoenix install).
* Build the `singleplayer` branch in `E:\FFXI-Forever\research\nate-lsb` against its own database `xidb_nate`.
* Set the HTTP server to 127.0.0.1 on a free port.
* Run it only while the Phoenix server is stopped (same game ports).
* Create a player character plus one party of headless characters; spawn them with the config, without the v3
  addons. If that is impossible without the addons, that is a finding.
* Observe: zoning in, a fight in camp, skillchain, healing, rest, death.
* **Answers:** does it build and run on this host, and how good is the combat AI in practice?
* **Undo:** delete the folder and `xidb_nate`.

**PoC-2: one parentless bot** (the decisive question; on a branch in the research copy only).
* Smallest change to `createHeadlessSession`: a headless character that owns its own zone, position and watchdog,
  with no parent.
* Run the existing solo role AI (a single melee bot with a puller config) for 30 minutes in a starter area.
* **Answers:** can Nate's AI run with no player at all, and how much of the alliance singleton does that touch?
* That count sizes the world layer for option B.

**Only after both PoCs:** decide B vs C, then plan the merge onto Phoenix and the world layer.

## 8. Open questions for the owner
1. **Phoenix or Nate's base (B vs C)?** Recommended B, decided after PoC-1.
2. **World-bot scale target** for the first milestone: e.g. one ownerless party, then 5 parties, then towards 500.
3. **Nate's companion mode:** keep it for your own character (you could lead a headless party too), or strip it?
4. **AutoAH vs Nate's auction bot:** decide in the economy phase, after the world bots work.
