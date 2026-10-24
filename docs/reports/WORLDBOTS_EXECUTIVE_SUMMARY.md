# World bots: executive summary (24 Oct 2026)

## What exists now
18 autonomous world bots live on the local Phoenix server: WAR, MNK, THF, WHM, BLM and RDM in each of San
d'Oria, Bastok and Windurst.

* **Real characters.** Each one was made through server-side character creation, with a lore-style name.
  It has its own personality and play schedule, and its state is kept in the database (`worldbots`), so
  bots resume after restarts.
* **Real sessions.** They log in and out like players (visible in `/sea`), but nobody can log into their
  accounts.

**Owner change of 24 Oct, applied:** bots solo until level 12, then group with bots of their nation and
hunt at exp camps in exp-camp zones.

## How a bot lives
* **Plays on schedule.** It logs in by its schedule, gets the starting gear the game gives a new
  character, and takes Signet from its nation's gate guard.
* **Travels by itself.** It picks a camp for its level, walks there on the navmesh and crosses zone lines
  like a client.
* **Fights with Nate's combat AI**, unchanged: roles, spells, weapon skills, threat, lotting.
* **Between fights** it rests, and after a death it returns to its home point.
* **Shops for itself.** It sells its loot to NPC vendors and buys job-appropriate weapons, armour, spell
  scrolls (then learns them) and its craft's tool.
* **Gathers and crafts** its nation's craft (logging, mining, harvesting; woodworking, smithing,
  clothcraft) through real HELM trades and synthesis.
* **Logs every decision** to `worldbots_log`; the server's own logs (`audit_vendor`, `char_skills`)
  confirm trades and skills.

**Nothing is granted.** Every action goes through the same server code a player's client triggers (login,
zone-line, talk, shop, trade, synthesis and death-menu packets, and the AI states).

## Results so far (about 8 hours of play)

| Milestone | Status |
|---|---|
| M1 engine port | Done. Regression identical to the baseline: 169 pre-existing failures of this Phoenix commit, none new. |
| M2 population | Done: 18 bots, schedules, `/sea`, resume after restart. |
| M3 solo life (each bot to level 5 on its own) | 17 of 18 done (now levels 5–8); one BLM at level 4. 4,045 fights recorded. |
| M4 parties | Three parties hunted at once (two of 6), with heals, spells and weapon skills, 331 party fights. **No skillchain yet:** it needs a WAR with an axe. Tested from level 5; parties now start at 12 as you decided. |
| M5 gil and progression | Working: 20,861 gil earned and 16,223 spent at NPCs (all audited), gear upgrades, 14 spells learned. Measured over hours, not days. |
| M6 gathering and crafting | Working: 117 gathered items, synthesis with skill-ups (woodworking 0.0 → 0.7). Bastok mining moved to other mines after Zeruhn's points proved unreachable. |
| M7 scale | **1,000 bots run on this machine** at 63% of one core and 3 GB, with zones on their normal 400 ms tick, after a profiling fix that made bot ticks 5× cheaper. |

## What's not done, or limited
* **Not observed yet:** a skillchain, and parties at exp camps (that needs bots at level 12; the highest is
  8 now).
* **No ships or airships yet.** Bots walk only, so zones reached by boat are left out of the leveling plan.
* **No multi-day soak yet.**
* **Gil from drops** is logged by the bots; the server audits only vendor sales and purchases.

## Decisions for you
* **Scale-test data:** the 982 scale-test bots and the M1 test character are disabled, not deleted. Keep
  or delete?
* **When to grow the population:** the code is ready for 500–1,000. Raise the population with
  `brain.grow(target)` and keep them enabled (I can make this a setting).

## Where things are
* Code: `modules/worldbots/` (C++ in `cpp/`, Nate's AI in `bots/`, the brain in `brain/`).
* Core patch: `patches/phoenix-b48e2d4e/`; install with `tools/Install-Worldbots.ps1`.
* Database backups: `tools/Backup-Database.ps1`.
* Reports: `docs/reports/`. Settings: `modules/worldbots/brain/config.lua`.
