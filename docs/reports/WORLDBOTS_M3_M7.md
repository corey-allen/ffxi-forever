# World bots: M3–M7 report

Dates: 23–24 Oct 2026. The figures are the server's own data: the `worldbots_log` decision trail,
`audit_vendor`, `char_skills` and `accounts_parties`. Population: the 18 development bots. M7 adds up to
1,000 bots for load tests; those 982 extra bots and the M1 test character were deleted afterwards on the
owner's instruction (backup first: `db-20261024-073309-pre-delete-scalebots.sql`).

**Design change (owner, 24 Oct):** bots solo until level 12, then group in parties and hunt at exp camps in
zones where exp camps exist. It is implemented:
* `PARTY_MIN_LEVEL = 12`.
* Solo zones for levels 10–11.
* Parties choose only exp-camp zones and settle at the camp. The camp is the densest spot of monsters at
  the party's level; the party hunts within 60 yalms of it and waits there for respawns.
* Parties whose weakest member is below 12 disband. The M4 test parties (formed from level 5) disbanded
  when the change went in.

## M3: solo life

**Done when (plan):** each of the 18 levels from 1 to 5 on its own, recorded fight by fight, with no stuck
loops.

**Result: 17 of 18 reached level 5 solo; Dadakaru (Windurst BLM) is at level 4.**

| Nation | WAR | MNK | THF | WHM | BLM | RDM |
|---|---|---|---|---|---|---|
| San d'Oria | Quentrel 7 | Dalan 8 | Mjerrah 7 | Isabeau 6 | Mimikaro 5 | Sabine 7 |
| Bastok | Jorvlak 7 | Berenger 7 | Theda 7 | Josseline 6 | Chuchumi 5 | Corentin 7 |
| Windurst | Zalvohr 7 | Hanijhaoi 7 | Purerasha 6 | Bebeloko 5 | **Dadakaru 4** | Falric 6 |

Melee bots reached level 5 in about 1–2 hours of play; mages took 3–6 hours. That gap is the era: a new
mage knows no spells and fights with a staff until it buys scrolls.

Recorded: 4,045 fights, 112 level changes, 135 deaths and home-point returns, and 5 navmesh recoveries,
each in the log with monster, level, duration, EXP, HP, zone and spells or weapon skills used.

Each bot does this on its own:
* chooses a camp by level and nation and walks there over the real zone lines;
* picks unclaimed monsters at its level, away from aggressive monsters too strong for it;
* fights with Nate's role AI;
* rests to 80% HP/MP;
* after a death, waits 60 s for a raise, then returns home with the death menu's home-point request.

Bugs found and fixed while it ran:
* **Healing cut every tick.** Nate's movement and his MP-only "stand up" rule cancelled /heal on every
  tick. The brain now moves world bots itself (Nate's CombatOnly mode), and HP rest is protected.
* **Weapons in the wrong slot.** Starting weapons went to the sub hand.
* **Wrong lookups.** Zone-line distance used 3D instead of horizontal, and the action hook dropped all bot
  actions because the engine's lookup is for monster ids.
* **Stuck bots.** Off-navmesh positions, unreachable exits (now planned around), split navmesh areas
  (ring detours), and empty camps (camp moves).
* **Crowding.** Shared starter zones: mob claims between bots, and caster windows below their own level.

## M4: parties

**Done when (plan):** three 6-bot parties hunt at once, each fight recorded; healer heals, nuker bursts,
at least one closed skillchain.

**Result: met except the skillchain.** It was tested with parties from level 5, before the level-12 rule.
* Three nation parties hunted at the same time: two full 6-bot parties (San d'Oria, Bastok) and Windurst
  with 4–5.
* Engine parties: `accounts_parties`, one shared AI context per party.
* 331 party fights, 302 won.
* Healers cured, for example "4 cures (+48 hp)" in a single fight.
* Mages cast offensive spells (nukes and Dia/Banish) and melee used weapon skills.

**No skillchain closed yet.** Pairs come from what members hold. The level-1 weapon skills these bots have
(Fast Blade, Wasp Sting, Combo, Shining Strike) don't chain with each other. The first chains need a WAR's
Raging Axe (Combo or Wasp Sting into Raging Axe, or Raging Axe into Fast Blade). Axes are the WARs'
preferred weapon and on their shopping lists (Bronze Axe, 328 gil), but none had bought one when the test
ended. A unit test covers the pairing.

## M5: progression and gil

**Done when (plan):** measured progress over multi-day soaks, every gil change explained by the server's
audit logs.

**Result: working; measured over about 8 hours, not multiple days.**
* **Shopping.** Bots learn shops by talking to vendors, and their shop knowledge is saved across restarts.
  * 334 sales for 20,861 gil and 93 purchases for 16,223 gil, every one in `audit_vendor`.
  * Gil from monster drops is logged per fight.
* **Purchases** fit the job and level, within a budget: weapons of the job's type, armour upgrades, the
  nation's craft tool, and spell scrolls.
  * 14 spells learned by using the scroll (Cure, Dia, Banish, Stone, Poisona…).
* **Leveling plan to 75** in `brain/areas.lua`. Every zone in it is reachable on foot from every home city
  (unit test).

## M6: gathering and crafting

**Done when (plan):** bots gather and craft through real game actions; items and skills reconcile with logs.

**Result: working.**
* **Signet:** 37 times from their own nation's gate guards (needed for crystal drops).
* **Gathering:** 146 HELM trades, 117 items. Logging in East Ronfaure and harvesting in West Sarutabaruta
  work. Mining in Zeruhn Mines failed (points out of the navmesh's reach); bots now fall back to Palborough
  and Gusgen Mines.
* **Synthesis** through the 0x096 packet, with the server's own success and skill-up rolls.
  * Woodworking skill 0.0 → 0.7 (Mjerrah) in `char_skills`.
  * Earlier attempts failed because full bags left no slot for the result. The server logged the reason;
    bots now keep at most two stacks of each material and craft only with free slots.

## M7: scale

Steps 18 → 50 → 100 → 250 → 500 → 1,000 bots on this machine (16 cores; the map server runs bots on one
thread):

| Bots online | `xi_map` CPU (one core) | Memory | Bot Lua per tick | Zone tick gap (nominal 400 ms) |
|---|---|---|---|---|
| 18 | 42% | 3.0 GB | 0.54 ms | – |
| 50 | 44% | 3.0 GB | 0.51 ms | – |
| 100 | 50% | 3.0 GB | 0.67 ms | – |
| 250 | 63% | 3.0 GB | 0.65 ms | – |
| 500 | 78% | 3.0 GB | 0.74 ms | 411 ms |
| 1,000 (before fix) | 97% | 3.0 GB | 0.89 ms | **1,018 ms (falling behind)** |
| **1,000 (after fix)** | **63%** | 3.0 GB | **0.17 ms** | **399 ms** |

* **The fix.** Profiling showed 82% of bot CPU was Nate's threat check, which scanned every monster in the
  zone for each alliance every 250 ms. The scan is now shared per zone (`brain/perf.lua`).
* **Idle ticks.** Idle bots run their Lua tick about once a second instead of every zone tick.

Memory doesn't grow with bots: Phoenix loads every zone at start. **1,000 concurrent bots run with
headroom.**

## Not done yet, or open

* **Dadakaru** is still at level 4.
* **No closed skillchain yet**, and the parties at exp camps from level 12 haven't been observed yet: no
  bot is above level 8.
* **No ships or airships:** six leveling zones are left out until bots can take boats.
* **No multi-day soak.**
