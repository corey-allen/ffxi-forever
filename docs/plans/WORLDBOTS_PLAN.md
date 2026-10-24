# Plan: autonomous world bots on our Phoenix server (awaiting owner approval)

23 Oct 2026. Replaces the companion-import plan. Sources:
* owner goals and answers (23 Oct);
* the [assessment of Nate's fork](../assessment/NATE_LSB_ASSESSMENT.md);
* Nate's code at `NatePillow/LandSandBoat@1982bfd348` (GPL-3.0);
* target: Phoenix `b48e2d4e` plus its two temp patches.

## Goal
A population of **fully autonomous headless world bots** that live on this server alongside real players. Each bot
is a real account and character in the database, so it persists and grows over time. Each bot:
* logs in and out by itself;
* levels its job;
* farms for gil;
* gathers and crafts with real game actions (HELM points, fishing, synthesis);
* acts on its own goals, so the world feels populated and alive.

Nate's code is the foundation, so we don't design these from scratch:
* headless characters;
* combat AI: job roles, magic, abilities, weaponskills, skillchains, threat, gear swaps, items, resting, lotting.

## Owner decisions already made
| Topic | Decision |
|---|---|
| Crafting and gathering | Real in-game actions, the same as a player. The AutoAH/Titan guild economy is a separate, later layer |
| Population during development | **18 bots**: WAR, MNK, THF, WHM, BLM and RDM in each starting nation (San d'Oria, Bastok, Windurst) |
| Long-term population | 500–1 000 concurrent, added gradually after the project is complete |
| Grouping | Bots only with each other. Grouping with real players comes after completion |
| Soloing and parties (24 Oct 2026) | Like real players, bots solo until level 12, then group in parties and hunt at exp camps in zones where exp camps exist |
| Trusts | Not implemented (not 2006/2007). Nate's trust code is not imported |
| Names | Lore-accurate for Vana'diel and Ivalice, following each race's naming style |
| Era | 75 cap, circa 2006/2007 (the Phoenix era settings already in place) |

## Two layers
**Layer 1: imported from Nate (hand-ported to Phoenix).** How a bot exists in the world and fights.
* The bot Lua: roles, magic, abilities, weaponskills, skillchains, threat, formation, movement, pulling, resting, items,
  lotting, server-side gear swaps.
* The engine pieces it needs:
  * headless sessions;
  * 42 Lua API methods;
  * bot fields on the character;
  * party/alliance helpers;
  * AI-state flags;
  * navmesh raycasts;
  * the per-tick hook;
  * server-side character creation.

It is a hand port: upstream has since renamed Phoenix's core files and changed them heavily (≈ 21 000 lines in the Lua
entity API alone).

**Not imported:**
* the Ashita v3 addon channel (118 custom packets, HTTP servers);
* single-player gameplay tweaks;
* trust overrides;
* the progression cascade;
* his auction bot.

**Layer 2: built new: the world brain.** Nate's code has none of this. His bots need a logged-in owner and only act
when told to.
* **Ownerless bots.** A headless session that owns its own zone, position and lifetime. This is the core change to his
  session model.
* **Per-party AI state.** His AI keeps one alliance per server; it becomes one state per bot party, so all three
  nations' parties (and later hundreds) run at once.
* **Population registry** in the database: identity, job, nation, personality, schedule, goals and decision log.
  Characters are created through the server's own character creation.
* **Schedules.** Logging in and out like players, visible in `/sea`.
* **Goals and planning.** What to do next (level, farm, gather, craft, shop, rest), with reasons and fallbacks.
* **Travel.** Zone-to-zone routing over zone lines and navmesh, recovery when stuck, home point after death.
* **Party formation** between bots (each nation's six can form a full party), camp choice by level, pulling.
* **Gil, gathering and crafting.** Selling drops to vendors, buying gear and supplies within a budget, HELM gathering
  with the right tools, fishing, synthesis with real recipes and skill-ups.

## Milestones (each one built, tested, reported and pushed)
| # | Milestone | Done when |
|---|---|---|
| **M1** | **Engine port** (layer 1 core): headless sessions, Lua API, tick hook and character creation on Phoenix; Nate's bot Lua loads | Builds with `/WX`; full regression shows no new failures; a headless character can be created and spawned server-side (test-only) and its role AI runs one fight |
| **M2** | **Ownerless bot and the population**: self-owned sessions; registry tables; lore-name generator; the 18 bots created through character creation; login/logout schedules | 18 bots exist in the database; they log in and out on their schedules with no player online; they appear in `/sea`; a restart resumes them |
| **M3** | **Solo life**: one bot leaves town, travels to a level-appropriate area, fights with Nate's role AI, rests, recovers from death, returns, and keeps a goal across restarts | Each of the 18 levels from 1 to 5 on its own, recorded fight by fight; no stuck loops |
| **M4** | **Parties**: per-party AI state; bots form nation parties; pulling, formation, healing, skillchains | Three 6-bot parties hunt at once, each fight recorded; healer heals, nuker bursts, at least one closed skillchain |
| **M5** | **Progression and gil**: leveling plan by level and area to 75; gear upgrades bought within budget; drops sold; gil goals | Measured progress over multi-day soaks (levels, gil, gear), with every gil change explained by the server's own audit logs |
| **M6** | **Gathering and crafting**: HELM gathering with the right tools, fishing, synthesis and skill-ups, chosen when worth it against the bot's goals | Bots gather and craft through real game actions; items and skills reconcile with logs |
| **M7** | **Scale-up** (after completion): 18 → 50 → 100 → … → 500–1 000, measuring CPU, memory and tick time at each step | Load report per step |

Grouping with real players and the economy layer (AutoAH, Titan's guilds) follow M7.

## Engineering rules
* **Server authority.** The server decides every game outcome. Bots act only through the same code paths a player's
  actions use; nothing is granted.
* **Era fidelity.** 75 cap, 2006/2007 rules, no trusts; this is checked by observation as well as by settings.
* **Reproducible.**
  * Our Lua and C++ live in a Phoenix module in this repository.
  * Unavoidable core changes live in a version-controlled patch set (`patches/phoenix-b48e2d4e/worldbots-core.patch`),
    applied by an install script.
  * Every hunk is marked and traced to Nate's original change or to our design.
* **Licensing.** GPL-3.0 on both sides. Nate's file headers are kept, and a `NOTICE.md` credits his repository and
  commit.
* **Every milestone:**
  * `/WX` build;
  * full `xi_test` regression with no new failures;
  * unit tests for pure decision logic;
  * a live run on the Phoenix server after a database backup;
  * a decision and telemetry trail for every bot action;
  * a report, then push.
* **Security.** Nothing listens beyond the local machine; no HTTP control servers.

## Names (lore-accurate)
Generated per race from each race's in-lore naming style:
* **Hume:** Western-European given names, as with San d'Orian and Bastokan Humes.
* **Elvaan:** French-styled.
* **Tarutaru:** reduplicated syllables, e.g. "Kupipi"-style.
* **Mithra:** syllable-hyphen style, e.g. "Mishi-Ahhim".
* **Galka:** single names with Galkan roots.
* **Ivalice-inspired names** mixed in where they fit the race.

The server's rules apply: 3–15 letters, letters only, no names already used by an NPC or monster. Canonical NPC names
are never reused, so a bot can't be mistaken for an NPC. Each nation's six bots get a plausible race mix for that
nation.

## Open question for the owner
**Naming source list.** I will write a curated name list per race (lore-style, original), with the generator falling
back to syllable rules. If you have favorite names or a source you want used, send it; otherwise I'll write the list.

## First step after approval
M1, the engine port, starting with the headless session core and the tick hook. It is reported before M2 begins.
