# World bots: M1 (engine port) and M2 (population) report

Date: 23 Oct 2026. Server: Phoenix `b48e2d4e` with `patches/phoenix-b48e2d4e/worldbots-core.patch`.

## M1: engine port

| Done-when (plan) | Result |
|---|---|
| Builds with `/WX` | Yes. Every build in this report was a `/WX` build with no warnings. |
| Full regression shows no new failures | Yes. `xi_test`: 1,662 tests, 1,493 passed, 169 failed. The baseline run, with the world-bots lines removed from `init.txt`, gives the same 169. One test differs on each side (Uragnite roam vs. a Chocobo Circuit race), both timing-dependent. The 169 are pre-existing failures of this Phoenix commit. |
| A headless character can be created and spawned server-side, and its role AI runs one fight | Yes. A test character was created through the new server-side creation and spawned ownerless in West Ronfaure. With Nate's Tank role it chased a Wild Rabbit, killed it and earned 50 EXP. |

What M1 added on top of the earlier port:
* **Server-side character creation** (`cpp/worldbots_create.cpp`). It mirrors Phoenix's `saveCharacter` and account insert, and applies the same name rules: letters only, 3–15 characters, unique, and not an NPC or monster name (checked against SQL and zone files).
  * The account's password field holds a marker that is not a bcrypt hash, so no password logs into it.
  * Bot ids stay below the `xi_test` range (20,000,000 and up), which tests wipe.
* **Entering the world through the login handler.** `arrive()` runs Phoenix's own 0x00A handler, so a bot's first login runs `xi.player.charCreate` (starting gear, gil, title). Starting from the intro cutscene's exit spot, it also gets the Adventurer's Coupon.

## M2: ownerless bots and the population

| Done-when (plan) | Result |
|---|---|
| 18 bots exist in the database | Yes. WAR, MNK, THF, WHM, BLM and RDM in each nation, created through character creation, with lore-style names (see below). |
| They log in and out on their schedules with no player online | Yes. After a restart, all 19 registered bots matched their schedules (0 mismatches). A forced close of one bot's schedule made it log out within 5 s, after it finished its fight. Reopening logged it back in at its saved spot. |
| They appear in `/sea` | Yes. The search server's own query returns each online bot with its live zone, job and level. |
| A restart resumes them | Yes. Registry, schedule and goal state are in the `worldbots` table, and bots log back in where they were saved. |

The population (`worldbots` table; decision trail in `worldbots_log`):

| Nation | WAR | MNK | THF | WHM | BLM | RDM |
|---|---|---|---|---|---|---|
| San d'Oria | Quentrel (Elvaan) | Dalan (Hume) | Mjerrah (Mithra) | Isabeau (Elvaan) | Mimikaro (Taru) | Sabine (Hume) |
| Bastok | Jorvlak (Galka) | Berenger (Hume) | Theda (Hume) | Josseline (Elvaan) | Chuchumi (Taru) | Corentin (Elvaan) |
| Windurst | Zalvohr (Galka) | Hanijhaoi (Mithra) | Purerasha (Mithra) | Bebeloko (Taru) | Dadakaru (Taru) | Falric (Hume) |

Valfroy, the M1 test character, is in the registry but disabled.

Names come from `brain/names.lua`: original names in each race's naming style, with Ivalice-style names mixed in. The server refuses any name an NPC or monster uses (live check: "Excenmille" was refused).

Schedules come from six personalities (dedicated, casual, nightowl, earlybird, weekender, steady), in server-local time. Set `SCHEDULE_MODE = 'always'` in `brain/config.lua` to keep every bot online for soak tests.

## How a bot acts, and what goes through the server's own code

| Action | Path |
|---|---|
| Log in | 0x00A login handler |
| Zone change | Walk to the zone line on the navmesh, then the 0x05E zone-line packet. The engine's `SendToZone` and `removeCharFromZone` run, then the character is reloaded from the DB and logged in with 0x00A, as for a reconnecting client. |
| Fight | Nate's role AI with Phoenix's AI states |
| Home point | The death menu's 0x01A home-point request |
| Talk, shops, trades, synthesis (M5/M6) | The client packets' own `validate()` then `process()` |

## Bugs found and fixed during M1/M2

* **Registry insert failed.** The DB layer refuses any query containing `{}`, so the empty JSON state is now bound as a parameter. The 18 characters created before the fix were adopted into the registry (`WorldbotOrphans`) rather than duplicated.
* **Zone loop.** After the first zone change, bots re-zoned to zone 0 in a loop. The engine expects a fresh character load after a zone change. Bots are now reloaded with `LoadChar` (as `map_networking.cpp` does), and spawn falls back to the home point for an invalid saved zone.
* **Ship-only zones.** Bots don't use ships or airships yet, so six ship- or Tavnazia-only zones were replaced with walkable ones. A unit test checks that every leveling zone 1–75 is reachable from every home city.
* **Smaller fixes:**
  * Solo bots no longer chase the same mob: there are now mob claims between bots.
  * Kill EXP is credited to the right fight: records settle 3 s after the kill.
  * The arrival poller runs at most every 100 ms.
  * Actions that involve no bot no longer reach the bot Lua, which matters at scale.
  * World bots' PAI listeners run in their own party's context.

## Tests

* `brain/tests.lua`: 11 unit tests (schedules, level windows, routes from every home city, names, contexts). Run them in the server by putting `return require('modules/worldbots/brain/tests').run()` in `modules/worldbots/dev/run.lua`. All pass.
* A database backup before each live run (`tools/Backup-Database.ps1`).
