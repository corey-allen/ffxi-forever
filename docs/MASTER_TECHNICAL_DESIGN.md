*MASTER TECHNICAL DESIGN DOCUMENT*

FFXI - FORVER: AUTONOMOUS FFXI SERVER

A persistent, locally hosted FFXI world with autonomous adventurers and
a self-sustaining economy

## Implementation north star for Claude Code

Baseline: Phoenix XI fork of LandSandBoat (LSB) • Economy inspiration:
Titan XI Mercantile Guild / Auction House • Runtime target: local
Windows-hosted server • Gameplay target: classic level-75 / 2006-era
behavior unless an explicit, documented exception is approved

*Version 1.0 • 18 October 2026*

# Document control and how to use this specification

This document defines the product mission, system boundaries, behavior
contracts, implementation method, data integrity rules, testing
strategy, operating model, and phased delivery plan. It is a guiding
specification, not proof that any particular code path, schema, API, or
Titan implementation has been inspected. Claude Code must inspect the
checked-out repository before implementing details and must treat the
live repository as the authority for actual names and interfaces.

  -----------------------------------------------------------------------
  Field                               Decision
  ----------------------------------- -----------------------------------
  Product                             A private, locally hosted FFXI
                                      world for one human player
                                      supported by persistent autonomous
                                      adventurers.

  Gameplay authority                  The selected Phoenix XI / LSB
                                      baseline. Do not silently import
                                      modern retail behavior or unrelated
                                      fork balance changes.

  Economy authority                   Existing FFXI item, recipe, vendor,
                                      AH, inventory, delivery, and
                                      crafting rules where available;
                                      Titan-inspired guild automation is
                                      an additive layer.

  Bot authority                       Server-side player-like entities
                                      operating through validated game
                                      actions and the same world rules as
                                      a human, with explicit bot-only
                                      orchestration APIs.

  Primary user                        The local server owner/player; no
                                      public service or multi-tenant
                                      assumptions unless later requested.

  Implementation style                Small, testable vertical slices;
                                      additive modules; reversible
                                      migrations; observable decisions;
                                      no giant rewrite.

  Current status                      Design specification. All paths,
                                      APIs, table names, and current
                                      behavior must be verified by Claude
                                      Code against the repository before
                                      use.
  -----------------------------------------------------------------------

# Executive summary

Build a world that feels inhabited rather than simulated by a handful of
scripts. Persistent AI adventurers should have identities, schedules,
job goals, equipment needs, budgets, skills, social ties, travel plans,
risk tolerance, memory, and imperfect decision-making. They should hunt,
rest, travel, gather, craft, sell, buy, form parties, recover from
setbacks, and resume work after restart. Their growth must emerge from
legal actions and real costs.

The economy must never create an item merely because a bot or human
wants one. Supply must have provenance: monster drops, gathering,
ordinary vendor purchases, player sales, crafting, or explicitly
configured starter stock. The Mercantile Guild can bridge thin markets,
but it must pay for inputs, obey eligibility restrictions, retain
inventory and cost basis, and use demand/supply signals instead of
infinite stock or arbitrary price controls.

The goal is availability, not unlimited free goods. Common progression
gear and consumables should usually be obtainable through a mix of AH
listings, guild stock, crafting orders, and gathering. Rare items,
expensive gear, rare drops, and scarce materials may remain scarce and
costly. A believable economy includes shortages, surpluses, price
movement, failures, and delayed fulfillment.

A local dashboard should make the world legible: bot activity, levels
and jobs, party status, gil creation/sinks, AH sell-through, listing
age, item availability, craft queues, gathering yield, deaths and
retreats, stuck bots, database health, and logs. All economic and AI
decisions must be explainable after the fact.

# 1. Mission, product goals, and non-goals

## 1.1 Mission

Create a persistent Vana'diel sandbox in which the human player
experiences the original FFXI progression loop alongside autonomous
adventurers, with a living player-like economy that remains useful at
low population and continues evolving without direct supervision.

## 1.2 Product goals

-   Preserve Phoenix XI / LSB mechanics, data, era assumptions, quest
    flow, combat resolution, item eligibility, and progression unless a
    deliberate exception is approved.

-   Operate locally on the owner's Windows environment with predictable
    start, stop, backup, update, and recovery procedures.

-   Support an initial cohort of 54 persistent bots as a practical
    baseline, with architecture capable of testing larger cohorts;
    population targets must be measured, not assumed.

-   Implement server-side bots as durable character-like entities that
    use normal legal actions rather than client macros or packet
    spoofing.

-   Provide full job progression, subjob progression where applicable,
    gear selection, inventory management, crafting, gathering, economy
    participation, party formation, and travel.

-   Add Titan-inspired Mercantile Guild behavior: real acquisition,
    ledgered stock, fair cost-based pricing, demand-aware crafting,
    input sourcing, stack consolidation, and market-facing guild
    merchants.

-   Ensure player and bot AH transactions share the same market and
    enforce normal item, gil, listing, and delivery invariants.

-   Provide telemetry and a local admin dashboard with audit history and
    safe operational controls.

-   Make all autonomous decisions reproducible enough to diagnose, test,
    and explain.

## 1.3 Non-goals and explicit boundaries

-   Do not replace Phoenix's combat or world engine with a new
    simulation.

-   Do not import all of another server fork wholesale. Port only
    individually reviewed capabilities and keep changes compatible with
    the chosen baseline.

-   Do not make bots omniscient: they cannot know hidden drops, unseen
    enemies, unlisted prices, undiscovered paths, or future spawns
    unless the same information is available through a defined in-world
    observation.

-   Do not grant free gil, free items, free skill-ups, free crafting
    success, or automatic levels outside explicitly configured
    administrative/test operations.

-   Do not change the era baseline, EXP rate, item stacking, drop rates,
    AH fees, craft rules, rare/ex flags, or mission availability
    silently.

-   Do not make the world dependent on a hosted AI API. The default
    decision engine is deterministic, local, and rule-based; optional
    language models may assist with non-authoritative flavor but never
    resolve game mechanics.

-   Do not optimize every bot for maximum EXP per hour. The target is
    competent, imperfect, persistent player-like behavior.

## 1.4 Success criteria

  ----------------------------------------------------------------------------------------
  Area                    Initial acceptance target                Notes
  ----------------------- ---------------------------------------- -----------------------
  Stability               72-hour soak without unbounded memory    Fix or document
                          growth, duplicate scheduled jobs, or     baseline server
                          unexplained economic creation.           failures separately.

  Bot population          54 persistent bots resume identity,      Measure CPU, memory,
                          location, job, inventory and goals after tick time and DB load.
                          restart.                                 

  Autonomy                Each bot has a valid goal, current plan, No-progress detector
                          and fallback behavior; no repeated       and recovery reason
                          identical no-progress loops.             required.

  Combat                  Bots use valid targets, ability/spell    Combat regression tests
                          recasts, weapon skills, enmity and       take precedence over AI
                          retreat rules from the baseline.         heuristics.

  Economy                 Every guild item has provenance and a    No unexplained
                          traceable cost basis; every gil movement inventory or gil
                          is journaled.                            deltas.

  Market                  AH                                       Exact baseline rules
                          search/list/buy/delivery/cancel/expiry   must be verified first.
                          work with player and guild listings in   
                          the same system.                         

  Availability            Core leveling consumables and gear have  Track demand coverage
                          a configurable target availability       and stockout duration.
                          without guaranteeing rare goods.         

  Gathering/crafting      Inputs are consumed, outputs created     Idempotency is
                          once, skill and recipe rules respected,  mandatory.
                          failures handled.                        

  Observability           Dashboard exposes bot state, economy     Metrics must be based
                          health, stockouts, errors, and recent    on durable events.
                          decisions.                               

  Recovery                Crash/restart safely recovers unfinished Fault-injection tests
                          orders, reservations and bot plans       required.
                          without double-spend.                    
  ----------------------------------------------------------------------------------------

# 2. Baseline selection and repository reconnaissance

The public Phoenix repository identifies itself as a fork of
LandSandBoat and includes the expected server, data, scripts, modules,
SQL and tooling structure. Titan's public Mercantile Guild description
documents a shop-fed stock model, cost tracking, crafting from accounted
inputs, a usual 20% margin, ingredient sourcing, stack handling, and
guild-owned AH listings. These public descriptions are architectural
reference points, not substitutes for inspecting implementation code.
The repository currently checked out locally is authoritative.

Reference links reviewed for this design:

-   Phoenix XI repository: https://github.com/phoenixffxi/Phoenix

-   Titan XI Mercantile Guild: https://www.titan-xi.com/mercantile-guild

-   Titan XI Auction House: https://www.titan-xi.com/auction-house

-   Titan XI overview and server settings:
    https://www.titan-xi.com/about

## 2.1 Mandatory reconnaissance before code changes

1.  Record repository remote URLs, current branch, commit SHA,
    working-tree status, submodules, and any local uncommitted changes.

2.  Read repository guidance files, especially AGENTS.txt, contribution
    docs, AI-agent instructions, build instructions, Lua conventions,
    SQL migration conventions, and test instructions.

3.  Identify server processes and boundaries: login, map/world, search,
    database, scripts, settings, extensions, modules, and any web/API
    process already present.

4.  Inspect the current AH implementation end-to-end: schema, listing
    lifecycle, sale settlement, delivery box, expiration, fees, limits,
    categories, stack rules, and transaction boundaries.

5.  Inspect the exact Titan-related code available to the user, if any.
    If only the public site is available, do not claim the site source
    has been ported or inspected.

6.  Inventory bot implementation already present: entity creation,
    character persistence, AI tick, navigation, combat, party logic,
    gear, AH, gathering, crafting, and diagnostics.

7.  Inspect all custom SQL tables and migrations, Lua modules, C++
    changes, scripts, config files, and local operational tooling before
    proposing new names or replacing files.

8.  Run the baseline build and current tests; save a baseline report.
    Record pre-existing failures so new regressions are distinguishable.

9.  Produce a dependency map and a list of extension points. Prefer
    existing hooks over invasive edits to core game logic.

10. Write a concise reconnaissance report with confirmed facts,
    unknowns, risks, and implementation plan before making architectural
    changes.

## 2.2 Required artifacts from reconnaissance

-   docs/architecture/repository-inventory.md

-   docs/architecture/baseline-behavior.md

-   docs/architecture/extension-map.md

-   docs/architecture/current-bot-capabilities.md

-   docs/architecture/known-defects-and-test-baseline.md

-   docs/architecture/decisions/ADR-0001-baseline-and-extension-strategy.md

## 2.3 Compatibility and upstream strategy

Maintain a clearly identified upstream baseline and isolate custom
functionality in modules, scripts, dedicated tables, and small
well-documented core hooks. If a core change is unavoidable, keep the
diff minimal and include a regression test. Do not overwrite existing
files wholesale when a narrow patch is possible. Keep an upstream-sync
procedure that merges/rebases deliberately, builds, migrates a
disposable database, runs tests, and requires manual promotion.

Before adopting code from another fork, verify license compatibility,
provenance, commit history, and which behaviors are actually needed.
Preserve applicable notices and GPL obligations. Never copy secrets,
credentials, private account data, or unrelated copyrighted assets into
the project.

# 3. High-level architecture

  -----------------------------------------------------------------------
  Layer                   Responsibilities        Design constraint
  ----------------------- ----------------------- -----------------------
  Phoenix / LSB game core World simulation,       Remain the rules
                          combat, NPCs, jobs,     authority.
                          items, recipes,         
                          movement, party, zones, 
                          inventory and standard  
                          transactions.           

  Extension boundary      Stable hooks and APIs   No direct DB writes
                          for bots, economy,      that bypass game
                          dashboard and           invariants.
                          operational controls.   

  Bot runtime             Persistent identities,  Bounded CPU; no
                          goals, planning, action omniscient state.
                          arbitration,            
                          perception, memory,     
                          scheduling and          
                          recovery.               

  Bot capability services Combat, navigation,     All actions validated
                          party, inventory,       by server rules.
                          shopping, gathering,    
                          crafting, social and    
                          progression adapters.   

  Economy services        Ledger, acquisition,    No free goods; atomic
                          inventory lots,         state transitions.
                          pricing, demand,        
                          recipes, crafting jobs, 
                          reservations and market 
                          listing policy.         

  Auction House adapter   Shared listings,        Reuse baseline AH
                          bids/buys, settlement,  semantics.
                          delivery, expiration,   
                          cancellation and fees.  

  Persistence             Character state, goals, Transactions,
                          memory summaries,       constraints,
                          orders, lots, journal,  idempotency.
                          telemetry and           
                          migrations.             

  Control plane           Dashboard, health       Local-only by default;
                          checks, safe admin      authenticated if
                          commands, configuration network-exposed.
                          and reporting.          

  Test and simulation     Unit, integration,      Seeded scenarios and
  harness                 scenario, soak,         reproducible reports.
                          restart, balance and    
                          economic stress tests.  
  -----------------------------------------------------------------------

## 3.1 Recommended logical service boundaries

\`\`\`text BotDirector -\> GoalPlanner -\> PlanExecutor -\>
ActionAdapters -\> Phoenix game APIs

\`\`\`text World Observations -\> Perception/Memory -\> GoalPlanner

\`\`\`text AH Events / Shop Events / Gather Events / Craft Events -\>
Economic Event Journal

\`\`\`text Economic Scheduler -\> Demand Forecast -\> Procurement
Planner -\> Craft Queue -\> Guild Listing Publisher

\`\`\`text Game DB + Economy Tables -\> Transactional repositories -\>
Dashboard read models

These are logical boundaries, not necessarily separate operating-system
processes. Start as modules inside or adjacent to the existing server
process where that is the safest extension point. Introduce a separate
local service only when isolation, deployment or performance justifies
it. Avoid distributed systems complexity for a single-player local
server.

# 4. Core invariants and non-negotiable engineering rules

## 4.1 Game integrity

-   Phoenix game rules determine whether any action succeeds. Bot intent
    is not success.

-   Bot actions must pass the same legality checks as a human action:
    range, line of sight where relevant, target validity, recasts,
    MP/TP, inventory capacity, status, zoning, claim, recipe
    requirements and item eligibility.

-   Do not directly set EXP, level, skill, gil, drops or equipment to
    simulate progress. Administrative fixtures are test-only and must be
    clearly separated.

-   Use actual item IDs, recipe definitions, NPC/vendor data, job
    restrictions, level requirements, stack limits, rare/ex flags and AH
    eligibility from the baseline resources/database.

-   All bot-only APIs must call established game functions or the same
    validation layer used by player actions.

## 4.2 Economy integrity

-   Every item creation has a source event; every transfer has a source
    and destination; every destruction has a reason.

-   Every gil change is classified as transfer, vendor transaction, AH
    settlement, crafting fee, tax/fee, reward, or explicit configured
    system sink/source.

-   Never use a dashboard display cache as the source of truth for money
    or inventory.

-   Use a single transaction for linked changes: consume inputs, debit
    funds, create output, update lot costs, record event, and transition
    job status.

-   Every scheduled operation and order has an idempotency key or
    durable state transition so retries cannot duplicate outputs or
    charges.

-   Reservations are distinct from ownership. Reserved items cannot be
    sold, consumed by another order, or counted as free stock.

-   Guild pricing is based on recorded costs and verified market/shop
    references, not on arbitrary bot desire.

-   Guild supply is allowed to bridge thin markets, not erase scarcity
    for rare or intentionally scarce items.

## 4.3 AI integrity

-   Every bot decision includes a reason code, selected goal, candidate
    alternatives, and key constraints. Avoid logging every tick at INFO;
    use structured sampling.

-   Planning must be bounded: finite candidate sets, time budgets,
    cancellation, and a safe idle fallback.

-   Persist long-lived intent and compact memory, not every transient
    thought or full world snapshot.

-   Use the same seeded random stream per bot for reproducible testing;
    randomness must not break transaction safety.

-   Repeated no-progress loops trigger plan invalidation, backoff,
    alternate plans, and eventually a stuck alert.

-   Bot autonomy must survive process restarts and missed ticks without
    duplicating work.

# 5. Persistent autonomous adventurer model

## 5.1 Identity and profile

Each bot is a persistent character with an immutable bot ID linked to a
normal character record or an adapter-supported equivalent. Store
personality and preferences separately from authoritative character
state.

  -----------------------------------------------------------------------
  Profile field                       Examples / purpose
  ----------------------------------- -----------------------------------
  Identity                            Stable character name, race,
                                      nation, appearance, creation date,
                                      history summary.

  Jobs                                Main job, subjob, unlocked jobs,
                                      job levels, preferred role,
                                      secondary interests.

  Temperament                         Cautious/bold, social/reserved,
                                      thrifty/generous,
                                      exploratory/familiar,
                                      patient/impulsive.

  Goals                               Reach next level, unlock subjob,
                                      obtain weapon, complete craft tier,
                                      earn gil, discover zone, restock
                                      supplies.

  Constraints                         Current gil budget, allowed risk,
                                      preferred play session length,
                                      inventory capacity, required
                                      consumables.

  Competence                          Learned combat patterns, navigation
                                      success/failure, recipe experience,
                                      party reliability.

  Social graph                        Trusted party members, guild
                                      affiliations, preferred roles,
                                      prior party outcomes, avoid/retry
                                      cooldowns.

  Memory summary                      Recent deaths, failed routes,
                                      prices observed, successful hunts,
                                      unresolved goals, meaningful
                                      transactions.

  Schedule                            Active, travel, town, rest, gather,
                                      craft, social, offline/suspended
                                      state with configurable weights.
  -----------------------------------------------------------------------

## 5.2 Goals and utility

Use hierarchical goals. A high-level goal decomposes into concrete
subgoals; subgoals produce executable actions and explicit completion
conditions. A goal should be chosen using utility, feasibility, risk,
cost and personality rather than a single universal priority.

\`\`\`text score(goal) = weighted(need, progress_value, urgency,
preference, social_value)

\`\`\`text - weighted(cost, travel_time, risk, opportunity_cost,
uncertainty)

This equation is conceptual. Implement a normalized score with
documented weights and clamps. Use a stable tie-breaker and a seeded
small random term so equal-value choices do not produce synchronized
behavior.

## 5.3 Example goal hierarchy

\`\`\`text Become a capable level-18 WAR

\`\`\`text -\> earn EXP safely

\`\`\`text -\> select an appropriate camp

\`\`\`text -\> travel to camp

\`\`\`text -\> find legal target within level/risk envelope

\`\`\`text -\> fight using job policy

\`\`\`text -\> heal / recover / restock when thresholds require

\`\`\`text -\> return to town if gear, quest, inventory or supply goal
is blocked

\`\`\`text -\> obtain usable gear

\`\`\`text -\> inspect owned/equipped items

\`\`\`text -\> identify level/job-compatible upgrade

\`\`\`text -\> compare vendor, AH, Guild, crafting and drop options

\`\`\`text -\> ensure budget and reserve funds for food/ammo/repairs

\`\`\`text -\> acquire through legal transaction

## 5.4 Decision loop and tick budget

A 400 ms orchestration cadence is a reasonable initial control interval
for a lightweight state machine, but not every subsystem should perform
expensive planning every tick. Use event-driven wakeups and staggered
periodic tasks.

  -----------------------------------------------------------------------
  Cadence                             Work
  ----------------------------------- -----------------------------------
  \~400 ms controller tick            Advance active state machine,
  (configurable)                      inspect immediate combat danger,
                                      validate action timeout, update
                                      short-lived intent.

  1--3 seconds, staggered             Movement progress, target
                                      acquisition, party tactical
                                      evaluation, combat rotation
                                      eligibility.

  10--30 seconds, staggered           Goal re-evaluation, inventory
                                      thresholds, consumable checks,
                                      social opportunities, camp
                                      suitability.

  1--5 minutes                        Market scan for relevant needs,
                                      craft/gather planning, travel route
                                      refresh, price memory decay.

  Vana'diel day / longer              Schedule variation, personal goals,
                                      job/skill plans, periodic guild
                                      planning and market target
                                      recalculation.

  Startup / recovery                  Reconcile persisted plan with
                                      actual world, inventory, party,
                                      orders and transaction journal.
  -----------------------------------------------------------------------

Never run a full path search, full recipe catalog scan, or broad AH
query for every bot every 400 ms. Cache static data, index item/recipe
mappings, schedule expensive work, and cap concurrent planners.

# 6. Bot state machine and execution contracts

## 6.1 Canonical states

  -------------------------------------------------------------------------------
  State                   Entry condition         Exit / recovery
  ----------------------- ----------------------- -------------------------------
  OFFLINE / SUSPENDED     Disabled, shutdown or   Resume only after startup
                          configured schedule     reconciliation.
                          says inactive.          

  INITIALIZING            Loading character,      Validate identity and reconcile
                          memory and current      actual character state.
                          world state.            

  IDLE / GOAL_SELECT      No executable plan.     Select feasible goal; if none,
                                                  safe town/idle behavior.

  PLANNING                Constructing bounded    Accept plan, retry with
                          plan.                   backoff, or choose fallback.

  TRAVELING               Route to camp, NPC,     Detect progress; re-path around
                          node, shop, AH or       obstruction; abandon after
                          party.                  bounded failures.

  TOWN_SERVICES           Using shops, AH,        Verify result and continue;
                          storage, guild service, never assume transaction
                          quest or equipment      succeeded.
                          services.               

  GATHERING               At legal gathering      Use real action and resource
                          location with           rules; stop on depletion, risk,
                          tool/requirements.      inventory or tool constraint.

  CRAFTING                At valid craft location Reserve and consume inputs
                          or authorized Guild     correctly; track
                          service.                skill/success/failure/output.

  PARTY_FORMING           Seeking or negotiating  Role composition and
                          a party.                consent/timeouts; solo fallback
                                                  if suitable.

  COMBAT                  Engaged in a valid      Resolve combat through server;
                          encounter.              retreat/defend if risk envelope
                                                  exceeded.

  RESTING / RECOVERING    HP/MP/TP/supplies below Resume when thresholds met or
                          policy thresholds or    return-to-town trigger fires.
                          post-combat need.       

  RETREATING              Risk exceeds allowed    Move to safe state, recover,
                          threshold or encounter  record reason, replan.
                          is failing.             

  DEAD / RECOVERY         Character death event.  Apply baseline
                                                  death/EXP/recovery rules; no
                                                  hidden penalty bypass.

  STUCK / QUARANTINED     Repeated no-progress or Cancel unsafe work, release
                          invariant violation.    reservations safely, emit
                                                  alert; require recovery policy.
  -------------------------------------------------------------------------------

## 6.2 Plan contract

Each plan should persist: plan ID, bot ID, goal ID, creation time,
expected world context, ordered steps, step preconditions, timeout,
retry policy, completion predicate, cancellation predicate, and recovery
handler. Before executing a step, revalidate critical assumptions
because other bots, monsters, prices, inventory and party state may have
changed.

## 6.3 Action result model

\`\`\`text ActionResult = { status: SUCCESS \| RETRYABLE_FAILURE \|
PERMANENT_FAILURE \| CANCELLED,

\`\`\`text reason_code, observed_state_version, side_effect_ids,
retry_after, details }

Never infer success from a function call returning without an exception.
Verify authoritative postconditions such as inventory delta, gil delta,
new listing ID, party membership, position, skill change, or order
state.

# 7. Combat AI: authentic, safe, and imperfect

## 7.1 Combat philosophy

Combat should use job-aware policies and the baseline's combat engine.
The bot chooses actions; the server determines accuracy, damage, enmity,
resist, recast, TP, status and EXP outcomes. Use level-appropriate
behavior without giving bots access to future events or hidden target
statistics beyond what a player could reasonably know.

## 7.2 Target selection

-   Filter by zone, reachability, aggression/links, level range
    estimate, claim state, party support, current HP/MP, escape route,
    respawn pressure and competition.

-   Estimate expected time-to-kill, incoming damage, healing capacity,
    status risk, link probability and recovery cost.

-   Prefer even/challenging targets when the party is stable; prefer
    safer targets after death, with low supplies, or when a bot is
    learning.

-   Use conservative defaults until enough observed outcomes exist;
    learning can update estimates but cannot override hard safety
    constraints.

-   Do not pull multiple targets unless the party's role composition,
    cooldowns, terrain and estimated incoming damage support it.

## 7.3 Role behavior

  -----------------------------------------------------------------------
  Role                                Behavior contract
  ----------------------------------- -----------------------------------
  Tank                                Maintain threat using legal job
                                      abilities, protect party members,
                                      watch HP and healer capacity, avoid
                                      pulling additional mobs when party
                                      risk is high.

  Healer                              Prioritize survival, healing
                                      thresholds, status removal, MP
                                      conservation and spell legality;
                                      stop unnecessary casts and rest
                                      when appropriate.

  Support                             Maintain useful buffs/debuffs
                                      within MP/time cost; avoid wasting
                                      duration before travel or when
                                      encounter is nearly over.

  Damage dealer                       Use weaponskills and abilities
                                      based on TP, recasts, expected
                                      value, skillchain opportunities and
                                      target survivability; avoid unsafe
                                      over-pulling.

  Solo-capable                        Choose lower-risk targets, keep
                                      emergency supplies, maintain
                                      retreat options, and accept slower
                                      EXP over repeated deaths.
  -----------------------------------------------------------------------

## 7.4 Rest, pull and retreat

Use stateful thresholds rather than one universal HP percentage. Pulling
thresholds should account for party role composition, healer MP, tank
HP, active status effects, nearby links, estimated enemy level and
retreat path. Resting should consider time-to-full, food duration, MP
recovery, nearby threat and party synchronization.

Measure net progression: EXP earned minus EXP lost to deaths, plus time
spent traveling, resting, recovering and re-equipping. Optimize for
sustainable EXP per wall-clock hour over sessions, not damage per second
in one fight.

## 7.5 Skillchains and magic bursts

Treat skillchain coordination as an optional tactical capability, not a
prerequisite for all fights. Maintain a shared party plan with weapon
skill availability, TP estimates, target vulnerability and caster MP.
Execute only when timing and legal actions permit. If any participant is
not ready, use normal job policy rather than freezing the party.

# 8. Party formation, social behavior and learning

## 8.1 Composition and recruitment

-   Build parties around actual job roles and level compatibility;
    prefer a viable tank/healer/support/damage mix where available, but
    permit imperfect groups.

-   Use party invitation and acceptance semantics consistent with the
    baseline. Bot consent rules should be explicit and observable.

-   Consider travel distance, camp availability, shared goals, session
    duration, player reputation, prior party outcomes and current gear.

-   Do not force all bots into one ideal party. Maintain multiple
    cohorts and solo behavior when party formation costs exceed
    benefits.

-   Set a configurable party search timeout and fallback plan to avoid
    idle deadlock.

## 8.2 Social behavior

Conversation should be sparse, context-sensitive, and safe. Bots may
greet party members, announce a pull, ask for rest, request a role,
share market information, or report a death. Do not spam chat or
impersonate the human. Use templates and event-driven dialogue; any
optional generative text must be filtered, rate-limited, and kept out of
authoritative game decisions.

## 8.3 Learning

Use transparent, bounded learning first: success/failure counts,
estimated kill duration, damage received, route failures, prices
observed, craft outcomes, party success, and item consumption. Update
estimates using rolling averages or Bayesian smoothing. Learning should
improve choices gradually and be resettable for experiments. Avoid an
opaque reinforcement learner until a deterministic baseline and
evaluation harness exist.

# 9. World navigation, gathering and exploration

## 9.1 Navigation

-   Use available LSB navigation/navmesh/pathfinding facilities rather
    than custom straight-line movement whenever possible.

-   Track destination, current route, last successful movement, zone
    transitions, obstruction count and last known safe position.

-   Detect no movement despite intended travel; try a bounded re-path,
    alternate entrance or known waypoint before declaring stuck.

-   Respect zone exits, aggro, level-appropriate routes, travel items,
    movement speeds and actual teleport unlocks.

-   Store learned waypoints only after successful traversal; decay or
    invalidate them when repeated failures occur.

## 9.2 Gathering behavior

Gathering is a player activity with real resource depletion, tool
requirements, action timing, skill checks, inventory constraints and
risk. Bots should choose gathering based on an actual goal: personal
crafting, guild demand, expected sale value, skill progression, route
safety or a job supply requirement. Never spawn materials directly into
inventory.

-   Select node/area using expected value per minute, required tool,
    skill/recipe fit, travel cost, danger and current market need.

-   Track tool durability/charges or consumption according to the
    baseline implementation, and buy tools through legal sources.

-   Stop when inventory is full, a required material target is met,
    danger rises, node yield declines, or expected value becomes poor.

-   Store resource yield and failed attempts to improve future route
    choice; do not assume nodes always contain desired items.

-   Allow gathering-focused bots to sell surplus or deliver materials to
    guild workflows through actual transactions.

## 9.3 Fieldcraft Guild

The Fieldcraft Guild is the gathering/procurement counterpart to the
Mercantile Guild. It should not create a second disconnected market. It
manages work orders and collection priorities:
mining/harvesting/logging/bone or hide acquisition/fishing as supported
by the baseline, tool supply, safe routes, material delivery, and
gathered-stock accounting. It may be a logical department rather than a
separate currency or inventory system.

  -----------------------------------------------------------------------
  Subsystem                           Responsibility
  ----------------------------------- -----------------------------------
  Fieldcraft job board                Publishes prioritized material
                                      requests from bot personal needs
                                      and Mercantile craft demand.

  Gathering planner                   Assigns tasks based on skill, tool,
                                      location, risk, route, inventory
                                      and expected yield.

  Material ledger                     Records source, quantity,
                                      acquisition time, skill/job context
                                      and destination.

  Delivery / transfer                 Moves goods through a real
                                      transaction to personal inventory,
                                      a guild-owned warehouse, or an AH
                                      listing.

  Reward model                        Pays only from a configured guild
                                      budget funded by legitimate
                                      sales/fees or explicit seed
                                      capital; logs every transfer.

  Anti-farming controls               Limits repeated identical routes,
                                      tracks depletion, applies
                                      travel/time cost and avoids
                                      unrealistic synchronized swarms.
  -----------------------------------------------------------------------

# 10. Crafting system

## 10.1 Recipe authority

Use the exact recipe data and skill requirements available in the
Phoenix baseline. Do not recreate the recipe catalog from a web list if
the repository already has authoritative data. Respect crystals,
ingredients, synthesis rules, skill caps, subcrafts, HQ odds, failure
behavior, breaks, output quantities, and any era-specific differences.

## 10.2 Crafting decision process

1.  Identify the bot's actual need or a validated guild demand signal.

2.  Find recipes with valid inputs, skill/job requirements, and an
    eligible output.

3.  Estimate expected value after ingredient cost, AH fee where
    applicable, travel, time, expected HQ value and failure loss.

4.  Check inventory space, crystal availability, budget, recipe
    knowledge, tool requirements and reservations.

5.  Reserve all inputs and budget atomically; if any reservation fails,
    do not begin.

6.  Execute through the real crafting path; record success/failure,
    skill change, ingredients consumed, output provenance and time.

7.  Route output to personal equipment/consumption, guild inventory, or
    the AH according to the original goal.

8.  Reconcile actual results against expected results and release unused
    reservations.

## 10.3 Player and guild crafting distinction

Bots should normally craft using their own skill, recipe knowledge and
materials, including authentic failure and HQ outcomes. A Mercantile
Guild service can be a convenience for the human player, using an
explicitly specified service fee and clear input rules. Do not let the
guild service bypass item eligibility, duplicate outputs, or make player
crafting skills irrelevant.

## 10.4 Craft queue

  -----------------------------------------------------------------------
  Field                               Purpose
  ----------------------------------- -----------------------------------
  order_id / idempotency_key          Uniquely identifies one order and
                                      prevents duplicate execution.

  owner_type / owner_id               Human character, bot, or guild
                                      entity that requested the work.

  recipe_id / recipe_version          Reference to the authoritative
                                      recipe definition.

  requested_quantity /                Track requested work and actual
  fulfilled_quantity                  output, including recipe batch
                                      size.

  input_reservations                  Exact item lot/quantity
                                      reservations and provenance.

  gil_budget / gil_reserved /         Prevent overspending and return
  gil_spent                           unused funds.

  state                               DRAFT, QUOTED, RESERVED,
                                      WAITING_FOR_INPUTS, READY, RUNNING,
                                      FULFILLED, FAILED, CANCELLED,
                                      REFUND_PENDING.

  timestamps / retry_count            Durable recovery and operational
                                      metrics.

  result_event_ids                    Links to actual consumption/output
                                      and ledger events.
  -----------------------------------------------------------------------

## 10.5 Craft failures and recovery

A failed craft is a real outcome, not a retryable database error.
Persist the game's result exactly. A process crash during order
execution is different: on restart, reconcile whether the game action
and output event committed before retrying. If the result is ambiguous,
quarantine the order for reconciliation rather than risking a duplicate
craft.

# 11. Mercantile Guild and autonomous market

## 11.1 Purpose and operating model

The Mercantile Guild is a collection of merchant roles sharing one
inventory, cost ledger and AH interface. It acts as a middleman and
manufacturer: adventurers sell eligible items to ordinary shops; the
guild acquires eligible goods from those transactions, offers them on
the AH, consolidates stock, sources ingredients for needed crafts,
crafts from paid-for inputs, and buys fair player listings when doing so
solves a real need.

Titan's public design describes a shop-fed market, distinct merchant
specialties, costed inputs, a usual 20% margin, demand-aware
replenishment, and item provenance. Treat those as reference behaviors.
Every numeric policy should be configurable and tested against the
user's preferred local economy.

## 11.2 Merchant roles

  -----------------------------------------------------------------------
  Role / archetype                    Inventory or decision focus
  ----------------------------------- -----------------------------------
  General Merchant                    Everyday supplies, common
                                      consumables, crystals when
                                      legitimately acquired,
                                      singles-to-stack consolidation.

  Guild Buyer / Broker                Fair-priced AH purchases for real
                                      production needs; bargain
                                      acquisition only against verified
                                      vendor buyback or other defensible
                                      reference.

  Quartermaster                       Weapons, armor, shields and
                                      progression gear legally acquired
                                      or crafted from costed materials.

  Apothecary                          Medicines, remedies and travel
                                      supplies when ingredients and
                                      demand justify production.

  Provisioner                         Food, drinks and cooking outputs
                                      based on observed consumption and
                                      shelf gaps.

  Arcanist                            Eligible scrolls and magical
                                      supplies within the configured
                                      era/item restrictions.

  Materials Broker                    Ore, ingots, logs, lumber, thread,
                                      cloth, hides, bones and processed
                                      ingredients.

  Field Supplier                      Arrows, bolts, bullets, ninja tools
                                      and other consumable field
                                      supplies.

  Curios Dealer                       Approved furniture, furnishings and
                                      non-progression curios where
                                      eligible.

  Ledgerkeeper                        Cost basis, inventory lots,
                                      transfers, craft lineage,
                                      settlements, audits and
                                      reconciliation.
  -----------------------------------------------------------------------

## 11.3 Supply sources and provenance

  -----------------------------------------------------------------------
  Source                              Rules
  ----------------------------------- -----------------------------------
  Player sells to NPC shop            If the existing shop transaction is
                                      eligible and succeeds, emit an
                                      acquisition event. Guild stock
                                      receives only the actual quantity
                                      sold and only if the configured
                                      acquisition policy allows it.

  Bot sells to NPC shop               Same rule as human; the bot cannot
                                      secretly route inventory to guild
                                      stock without an auditable
                                      transaction.

  Player AH listing                   Guild may purchase only through the
                                      normal AH transaction and at the
                                      actual asking/settlement price plus
                                      normal fees.

  Ordinary shop / craft guild         Permitted only for items actually
                                      sold by that NPC in this baseline
                                      and only at the actual quoted
                                      price; elemental crystals/clusters
                                      should not be shop-sourced if
                                      following Titan's published policy.

  Field gathering                     Material is recorded from the
                                      actual gathering action and can be
                                      transferred to guild ownership only
                                      through a real, journaled transfer.

  Monster drop                        Guild only receives the item if a
                                      character obtains it and
                                      transfers/sells it through an
                                      allowed path. No direct drop-table
                                      injection.

  Guild crafting                      Output is created only by a
                                      successful craft/order using
                                      reserved and consumed real inputs;
                                      store recipe and ingredient
                                      lineage.

  Explicit bootstrap inventory        Optional, finite, clearly labeled
                                      starting stock funded by
                                      configuration; bootstrap must not
                                      recur on restart.
  -----------------------------------------------------------------------

## 11.4 Cost basis and pricing

Track inventory in lots rather than only aggregate counts. A lot
contains item ID, quantity, source type, acquisition event, unit cost,
fees, acquisition timestamp, owner, reservations and lineage. For mixed
lots, use a documented cost method such as weighted average or FIFO;
choose one and keep it consistent. The UI may aggregate lots, but
accounting must retain provenance.

\`\`\`text base_cost = allocated_input_cost + acquisition_costs +
applicable_fees

\`\`\`text normal_offer = max(base_cost \* (1 + target_margin),
verified_floor, policy_floor)

\`\`\`text craft_offer = allocated_input_cost + craft_operating_cost +
target_margin

For a Titan-like default, target_margin may start at 20%, but it must be
configurable by category and item liquidity. This is not a guarantee of
profitability or market clearing. For immediate arbitrage risk, compare
the proposed resale value with a defensible alternative use (such as
verified NPC buyback or a recipe's known output value), include fees and
expected losses, and reject or reprice unprofitable loops.

-   Never treat an unverified price as a verified cost basis.

-   Never let a high player ask become the guild's reference price
    simply because it exists.

-   Use recent completed sales when available; listings alone are
    offers, not proof of market value.

-   Use vendor price as a fallback reference only when the baseline's
    actual shop quote is known.

-   Use price ceilings/floors as safety rails, not as a substitute for
    supply-demand behavior.

-   Record every pricing decision with inputs, rule version, reference
    data and resulting price.

## 11.5 Demand and replenishment

Demand should be inferred from several independent signals: recent
completed sales, human purchases, bot consumption, bot shopping intents,
stockouts, listing age, progression cohorts, crafting recipes and
observed material consumption. Do not count a bot's unfulfilled wish as
a completed sale. Do not let bots generate unlimited demand for items
they never consume.

\`\`\`text effective_demand(item, window) = weighted(actual_sales,
actual_consumption, valid_pending_needs)

\`\`\`text target_stock = min(max_stock, forecast_demand \*
coverage_window + safety_stock)

\`\`\`text replenishment_gap = max(0, target_stock - sellable_stock -
inbound_reserved_stock)

Weights, windows and caps are configuration. For the initial baseline,
use a modest safety stock for frequently used low-level consumables and
common progression gear, lower targets for slow-moving items, and no
guaranteed target for rare or high-value items. Replenishment should
stop when the market is saturated or unit economics are poor.

## 11.6 Ingredient sourcing order

1.  Use unreserved, available guild inventory at its recorded cost.

2.  Consider transfers from another guild department/merchant at a
    ledgered internal transfer price.

3.  Consider fair-priced player AH listings that are genuinely needed
    and within the approved budget.

4.  Use ordinary shops/craft guilds only if they sell the required item
    in this baseline and policy permits it.

5.  If inputs remain unavailable or too expensive, pause the craft
    order, lower its priority, or cancel it according to order policy.
    Do not fabricate missing inputs.

## 11.7 Stock and listing behavior

-   Guild listings are durable until sold or deliberately
    regrouped/repriced/withdrawn; player listings follow the baseline
    expiration and listing limit unless an approved custom rule changes
    it.

-   Stack singles only when the item's stack rules permit it and
    quantity thresholds are met. Preserve unit cost and provenance
    during aggregation.

-   Partial-stack consumption must decrement quantity and cost
    correctly; never lose the cost basis of the remainder.

-   Keep a minimum amount of operational working capital. Do not spend
    the whole guild treasury on speculative stock.

-   Do not repeatedly undercut human listings every tick. Repricing
    requires a meaningful event or cooldown and respects minimum margin
    / loss policy.

-   Guild merchant names should be stable and clearly identified so
    players understand which offers are system-operated.

## 11.8 Human accessibility policy

The objective is reliable access to useful items, not an AH populated
with every item at all times. Define availability tiers:

  -----------------------------------------------------------------------
  Tier                    Examples                Policy
  ----------------------- ----------------------- -----------------------
  A --- essential / high  Common tools, basic     High target coverage;
  velocity                food, common ammo,      short stockout alerts;
                          leveling consumables,   prioritize legitimate
                          basic crystals if       sourcing.
                          allowed.                

  B --- progression       Common weapons, armor,  Moderate target stock;
  staples                 spell scrolls and       craft or source when
                          common crafting inputs. demand and cost
                                                  justify.

  C --- specialist / low  Niche job gear,         Opportunistic stocking;
  velocity                less-used recipes,      longer replenishment
                          uncommon tools.         window; avoid
                                                  overproduction.

  D --- rare / high value Rare drops, expensive   No guaranteed
                          gear, scarce NMs or     availability; only
                          low-supply items.       legitimate acquisition;
                                                  price reflects
                                                  scarcity.

  E --- prohibited /      No-AH, quest-locked or  Never list, craft for
  ineligible              out-of-era items per    AH, or make tradable by
                          configuration.          guild policy.
  -----------------------------------------------------------------------

## 11.9 Auction House integration

Use the existing AH transaction engine wherever possible. The guild
should be a listing owner/entity recognized by that engine, or use a
thin adapter that still passes through the same validations, settlement
and delivery rules. Do not create a parallel web-only market with
independent stock and prices.

-   Use the same item eligibility, listing categories, quantity rules,
    gil debit, fee, settlement, delivery and cancellation behavior as
    normal players.

-   Every guild listing links to an inventory lot or lot allocation;
    sold quantity decrements exactly once.

-   On purchase, settle gil and item ownership atomically or use a
    durable two-phase state machine if the current engine cannot provide
    a single transaction.

-   Handle server crash between buyer debit, listing decrement and
    delivery without duplication or lost items.

-   Keep a reconciliation job that compares listing quantities, guild
    lots, completed sales and delivery records.

-   Human player listing rules should remain unchanged unless an
    explicit product decision is recorded.

# 12. Economic sustainability and gil-flow model

## 12.1 Understand that gil and items are different ledgers

Items can be transferred, consumed, destroyed, crafted or looted. Gil
can be transferred between characters, paid to NPCs, earned from
rewards, created by sale to an NPC, or removed by fees and sinks. AH
sales usually transfer gil between participants minus applicable fees;
they do not inherently create gil. The dashboard must distinguish
transfers from system sources and sinks.

## 12.2 Required gil categories

  -----------------------------------------------------------------------
  Category                            Examples / treatment
  ----------------------------------- -----------------------------------
  Sources                             Baseline monster gil,
                                      quests/rewards, NPC purchase of
                                      items, configured seed capital.
                                      Every source must be explicitly
                                      named.

  Transfers                           Player-to-player, bot-to-bot,
                                      human-to-bot and AH settlement;
                                      neutral at world level before fees.

  Sinks                               NPC purchases, AH fees if
                                      configured, guild service fees,
                                      travel/services, consumables bought
                                      from NPCs, other baseline sinks.

  Guild operating balance             Treasury, reserved operating
                                      capital, acquisition budget, craft
                                      budget, receivables and
                                      payable/refund liabilities.

  Unclassified delta                  Any unexplained difference; should
                                      be zero after reconciliation or
                                      raise a high-priority alert.
  -----------------------------------------------------------------------

## 12.3 Avoid self-sustaining loops that only look healthy

-   Prevent guild-to-bot-to-guild loops that turn seed capital into
    repeated apparent sales.

-   Track system-operated demand separately from human demand. Both are
    useful, but dashboards must not conflate them.

-   Set budgets and demand caps per item/category, per bot, and per time
    window.

-   Do not treat listings created by bots as demand; only completed
    transactions or actual consumption count as realized demand.

-   Track the proportion of sales among bots, between guild entities,
    and to the human player.

-   Flag a market where price and transaction volume rise while the
    number of unique actual consumers does not.

-   Use finite startup capital and report its source; never silently
    replenish guild treasury when it runs low.

## 12.4 Economic health KPIs

  -----------------------------------------------------------------------
  KPI                                 Definition / why it matters
  ----------------------------------- -----------------------------------
  AH sell-through                     Units or listings sold divided by
                                      eligible listings in a defined
                                      cohort/window; clarify denominator.

  Availability coverage               Percentage of sampled item-time
                                      intervals where an item is
                                      available at a policy-valid price.

  Stockout duration                   Time between stock reaching zero
                                      and valid replenishment.

  Listing age                         Median and 90th percentile age of
                                      unsold listings by category.

  Price spread                        Difference between representative
                                      buy and sell offers where
                                      meaningful; avoid false precision
                                      with sparse trades.

  Guild gross margin                  Sales proceeds minus allocated cost
                                      basis and direct fees; report
                                      realized and unrealized separately.

  Inventory turns                     Cost of goods sold divided by
                                      average inventory value over a
                                      window.

  Craft utilization                   Completed useful crafts / planned
                                      crafts; include failures and
                                      abandoned orders.

  Input coverage                      Fraction of planned craft inputs
                                      available from owned stock, fair AH
                                      acquisition, or permitted shops.

  Gil creation and sinks              Separate sources, sinks, transfers
                                      and unclassified deltas.

  Bot market share                    Share of purchases/sales involving
                                      bots or guild; flag high
                                      circularity.

  Demand fulfillment                  Valid bot/human purchase intents
                                      fulfilled within a time target.

  Price stability                     Volatility and change rate by
                                      category, adjusted for low
                                      transaction count.

  Economic provenance coverage        Share of guild inventory and
                                      outputs with complete source and
                                      cost lineage; target 100%.
  -----------------------------------------------------------------------

The previously observed local cohort figures---54 bots online, 605
level-ups, 7.1% AH sell-through, 1,234 gil credited to
Fieldcraft/Gatherers Guild against a 50,000-gil reference budget, and
0.61% solo deaths---should be treated as a historical snapshot to
investigate, not proof of a defect by themselves. Define the measurement
windows and denominators before changing behavior. The most immediate
diagnostic questions are whether demand is real and correctly forecast,
whether prices reflect completed sales, whether guild craft inputs are
feasible, and whether gil flows reconcile.

# 13. Item availability, gear planning and bot shopping

## 13.1 Gear goals

Each bot should maintain a lightweight equipment plan based on level,
job, race restrictions where applicable, slots, weapon skill, defensive
needs, accuracy/attack balance, magic stats, gil and expected time until
the next upgrade. Do not assume the most expensive or highest item-level
choice is best. Compare usable upgrades and avoid repeated shopping for
marginal improvements.

## 13.2 Acquisition decision

1.  Determine the actual need and deadline: missing weapon, armor slot,
    ammo, food, spell, tool, or quest material.

2.  Filter for item legality and compatibility with current job, level,
    slots, inventory and era rules.

3.  Check owned inventory, Mog/storage capabilities available to the
    character, and current equipment.

4.  Compare legitimate acquisition routes: AH, Mercantile Guild, NPC
    vendor, crafting, gathering, quest, drop, or party support.

5.  Estimate full cost including AH fee, travel, crafting failure risk,
    and reserved operating funds.

6.  Purchase only if budget and value policy permit; use a cooldown to
    avoid repeated scans and price chasing.

7.  Verify the actual received item and equip only if legal and better
    under the bot's role policy.

8.  Record why it bought or rejected the item for telemetry and
    learning.

## 13.3 Market coverage without omniscience

Bots can query their permitted AH search interface, remember prices they
actually observed, and ask guild services for quotes. They cannot use
hidden database state as if they saw every listing unless the bot is
explicitly acting as the Guild market planner. Keep bot perception
separate from administrator telemetry. The human dashboard may see full
market data; ordinary bots should see only their authorized view.

## 13.4 Inventory hygiene

-   Keep reserved space for job-critical tools, ammo, food, medicine,
    crystals and quest items.

-   Do not sell equipped, reserved, rare/ex, quest-critical or currently
    required items.

-   Consolidate stacks only through legal stack behavior.

-   Use sell decisions based on expected future need, storage capacity,
    vendor value, market liquidity and personal goal.

-   Protect emergency funds and travel consumables before discretionary
    purchases.

-   Reconcile equipment state after death, level-up, job change, zoning
    and acquisition.

# 14. Data model and persistence

The precise schema must be adapted after repository inspection. Use
migrations compatible with the existing database and naming conventions.
Do not duplicate authoritative character, item, recipe, AH or inventory
data if it already exists.

  -----------------------------------------------------------------------
  Logical entity                      Key fields / constraints
  ----------------------------------- -----------------------------------
  bot_profile                         bot_id, character_id, personality
                                      JSON/version, preferences,
                                      schedule, enabled, created_at.

  bot_goal                            goal_id, bot_id, type, priority,
                                      state, target, deadline, reason,
                                      created/updated timestamps.

  bot_plan                            plan_id, bot_id, goal_id, state,
                                      plan_version, context version,
                                      current step, timeout, retry_count.

  bot_memory_summary                  bot_id, memory_type, summary/value,
                                      confidence, source event IDs,
                                      expires_at, updated_at.

  bot_observation                     optional bounded telemetry; sampled
                                      observations, zone, target, action,
                                      outcome, event timestamp.

  economic_event                      event_id, idempotency_key,
                                      event_type, actor, counterparty,
                                      item/gil deltas, source,
                                      correlation_id, timestamp.

  guild_account                       guild_id, gil_balance,
                                      reserved_gil, policy_version,
                                      treasury status.

  guild_inventory_lot                 lot_id, guild_id, item_id,
                                      quantity, reserved_quantity,
                                      unit_cost, source_type,
                                      source_event_id, lineage_id.

  guild_lot_allocation                order/listing/transfer allocation
                                      from a lot, quantity, cost
                                      allocation and state.

  guild_listing_link                  guild listing ID, AH listing ID,
                                      lot allocation ID, listed quantity,
                                      state, last reconciled timestamp.

  market_observation                  item_id, observed price,
                                      observation type, source, time,
                                      confidence, sample count.

  demand_signal                       item_id, signal type, quantity,
                                      window, actor class, confidence,
                                      source event, expiry.

  craft_order                         order ID, owner, recipe, quantity,
                                      state, idempotency key, budgets,
                                      reservations, result links.

  material_reservation                reservation ID, owner/order, lot or
                                      character inventory reference,
                                      item, quantity, expiry, state.

  gather_work_order                   work ID, item target, quantity,
                                      skill/zone constraints, budget,
                                      priority, assigned bot, state.

  guild_policy                        versioned config key/value, scope,
                                      effective time, audit actor.

  reconciliation_run                  run ID, scope, start/end,
                                      discrepancies, repairs
                                      proposed/applied, result.

  bot_decision_event                  bot, goal, action, reason code,
                                      alternatives summary, outcome,
                                      correlation ID, timestamp.
  -----------------------------------------------------------------------

## 14.1 Persistence requirements

-   Use database transactions and constraints wherever possible. Do not
    rely on application-level check-then-write when concurrent bots may
    reserve the same stock.

-   Use unique constraints for idempotency keys and external game-event
    IDs.

-   Use UTC timestamps for technical events; convert to Vana'diel/local
    time only for presentation and schedules.

-   Version serialized plans and policies so startup can migrate or
    invalidate stale plans safely.

-   Keep telemetry bounded with retention rules, aggregation and
    sampling. Preserve economic ledger events long enough to audit the
    full history.

-   Use foreign keys where consistent with the baseline; document any
    intentionally denormalized read model.

-   Add indexes based on observed queries, especially pending jobs, item
    stock, AH listing links, event time, bot active state and
    reconciliation status.

# 15. Transaction design, concurrency and crash recovery

## 15.1 Transactional patterns

Inventory and gil operations are correctness-critical. Use the existing
database transaction conventions and locking model. If the AH, game
inventory and custom economy tables cannot share a transaction, use an
explicit durable state machine with compensation/reconciliation, not
optimistic assumptions.

## 15.2 Example guild craft transaction

1.  Create order with unique idempotency key; reject duplicate request.

2.  Validate recipe and current policy version.

3.  Reserve available lot quantities and budget using atomic conditional
    updates.

4.  Persist state RESERVED and reservation records.

5.  Execute crafting through the authoritative game path or controlled
    service path.

6.  Persist exact consumed inputs and actual output; allocate input cost
    to output lot(s).

7.  Debit actual fee/cost, return unused reserved gil, release unused
    input reservations, and mark terminal state.

8.  Publish market listing only after output lot is committed and AH
    eligibility passes.

9.  On restart, reconcile every nonterminal order against inventory,
    event journal and crafting result before retry.

## 15.3 Idempotency and event handling

All asynchronous consumers should assume at-least-once delivery. The
same event may be replayed. Deduplicate by stable event ID/idempotency
key, and ensure processing a duplicate does not apply the item or gil
delta again. Use an outbox pattern if events must be emitted after a DB
transaction without losing them.

## 15.4 Reconciliation jobs

-   Bot character inventory versus bot intent/reservation state.

-   Guild lot quantities versus AH active listing quantities and
    completed sales.

-   Guild gil ledger versus account balance and reserved funds.

-   Craft order input/output events versus actual inventory deltas.

-   Player/bot delivery boxes versus AH purchase settlement.

-   Bot party membership and current zone versus persisted plan.

-   Pending scheduled actions and locks versus process restart state.

Reconciliation must default to read-only reporting. Auto-repair is
permitted only for deterministic, provably safe cases and must record
before/after values, reason and event IDs. Ambiguous discrepancies
should be quarantined for inspection, never guessed away.

# 16. Dashboard, reports and operator controls

## 16.1 Local dashboard goals

-   Show a live population map or zone summary with bot state, level,
    job, party, current goal and last progress time.

-   Show aggregate bot activity distribution: combat, rest, travel,
    town, gathering, crafting, party search, recovery and stuck.

-   Show AH health: active listings, sales, sell-through, listing age,
    stockouts, price distribution, guild share and human/bot share.

-   Show Mercantile Guild treasury, costed inventory, reservations,
    craft queues, source breakdown, margins and top shortages.

-   Show Fieldcraft demand queue, assigned gatherers, material yields,
    failed attempts, delivery backlog and tool shortages.

-   Show gil sources/sinks/transfers, guild budgets, unclassified deltas
    and circular bot/guild trade alerts.

-   Show combat progression: level-ups, EXP/hour, death rate, net
    EXP/hour, retreat rate, camp usage and stuck travel.

-   Provide a searchable decision timeline for a bot: goal chosen,
    options rejected, action, outcome and subsequent plan.

## 16.2 Operator controls

  -----------------------------------------------------------------------
  Control                             Safety behavior
  ----------------------------------- -----------------------------------
  Pause/resume all bots               Stops issuing new actions; safely
                                      resolves or checkpoints in-flight
                                      work.

  Pause/resume cohort                 Can pause by level range, job,
                                      zone, role or feature flag.

  Set bot population                  Changes active cohort through
                                      graceful activation/deactivation;
                                      never deletes identity.

  Pause guild trading                 Stops new purchases/listings while
                                      allowing settlement/reconciliation.

  Pause crafting/gathering            Stops new work; finishes or safely
                                      cancels current jobs.

  Rebuild market read models          Recomputes caches from source
                                      tables/events; must not mutate
                                      authoritative balances.

  Run reconciliation                  Read-only by default; separate
                                      explicit safe-repair action.

  Export report                       Produces timestamped
                                      CSV/JSON/HTML/Docx report with
                                      metric definitions and time window.

  Reset test cohort                   Allowed only on a test database or
                                      explicit confirmation with a clear
                                      irreversible-action warning.

  Change policy                       Validate schema/ranges, version
                                      policy, audit old/new values and
                                      require reload semantics.
  -----------------------------------------------------------------------

## 16.3 Security

-   Bind dashboard/API to localhost by default. Do not expose an
    unauthenticated admin API on the LAN or internet.

-   Keep DB credentials, tokens and local secrets out of source control
    and logs.

-   Use role separation between read-only dashboard and mutation/admin
    actions.

-   Validate every command server-side and audit it; never accept
    arbitrary SQL or filesystem paths from the dashboard.

-   Rate-limit action endpoints and protect destructive operations with
    confirmation and backups.

-   Make remote control an opt-in deployment change, not the default.

# 17. Configuration and tuning

All tuning values belong in versioned configuration rather than
scattered constants. Ship conservative defaults and a schema validator.
Every config option must have a description, default, allowed range,
reload behavior and related metric.

  -----------------------------------------------------------------------
  Configuration group                 Examples
  ----------------------------------- -----------------------------------
  bots.population                     initial_count, maximum_active,
                                      cohort composition, activation
                                      staggering.

  bots.tick                           controller_ms, planner intervals,
                                      maximum concurrent expensive plans,
                                      per-tick action budget.

  bots.goal_weights                   progress, safety, social, cost,
                                      exploration, preference and urgency
                                      weights.

  bots.combat                         pull thresholds, risk caps, rest
                                      thresholds, retreat triggers, max
                                      link tolerance.

  bots.travel                         path retry limits, stuck timeout,
                                      replan cooldown, preferred route
                                      memory TTL.

  bots.economy                        market scan intervals, spending
                                      budgets, reserve funds, shopping
                                      cooldowns.

  guild.pricing                       default margin, category margins,
                                      min margin, max markup, price
                                      confidence thresholds.

  guild.stock                         availability tiers, target
                                      coverage, max stock, safety stock,
                                      reorder cooldown.

  guild.procurement                   max price, permitted sources,
                                      budget caps, fair listing rules.

  guild.crafting                      queue concurrency, input reserve
                                      TTL, order timeout,
                                      cancellation/refund policy.

  fieldcraft                          task priorities, travel risk,
                                      material quotas, tool reserve,
                                      route rotation.

  telemetry                           log level, sampling, retention,
                                      metric windows, dashboard refresh
                                      intervals.

  safety                              kill switch, maximum retries,
                                      quarantine policy, database health
                                      thresholds.
  -----------------------------------------------------------------------

Configuration values should be selected by simulation and observed
behavior, not asserted as universal truths. In particular, the 400 ms
tick, 54-bot starting cohort, 20% default guild margin and stock targets
are initial design defaults that require load and economy testing.

# 18. Testing strategy and acceptance gates

## 18.1 Test pyramid

  -----------------------------------------------------------------------
  Test layer                          Examples
  ----------------------------------- -----------------------------------
  Unit                                Goal scoring, pricing, demand
                                      aggregation, cost allocation,
                                      eligibility filters, inventory
                                      reservation, idempotency and retry
                                      logic.

  Database integration                Migrations, constraints, concurrent
                                      reservations, lot split/merge, AH
                                      sale settlement, delivery and
                                      restart reconciliation.

  Game integration                    Bot entity lifecycle, legal
                                      movement, combat action, death/EXP
                                      behavior, crafting, gathering,
                                      party membership and equipment.

  Scenario                            A level-1 bot starts with baseline
                                      funds and progresses through town,
                                      gear, hunting, selling drops,
                                      restocking and leveling.

  Economic simulation                 Low/medium/high demand, no human
                                      buyers, single human buyer,
                                      material shortage, surplus, price
                                      shock, treasury exhaustion.

  Fault injection                     Crash before/after debit, after
                                      item reservation, during craft,
                                      after AH sale but before delivery,
                                      while bots are zoning.

  Soak/load                           54 bots for 72 hours; larger
                                      cohorts in staged runs; monitor
                                      tick latency, DB locks, memory and
                                      queue growth.

  Regression                          Baseline player workflows and era
                                      rules remain unchanged after custom
                                      feature work.
  -----------------------------------------------------------------------

## 18.2 Mandatory economy scenarios

-   Empty AH at startup: common gear and consumables become available
    only through legitimate supply paths; no phantom listings appear.

-   One player sells common materials to shops: only eligible, actually
    sold quantities enter guild stock.

-   Guild crafts an output: input lots decrement, output provenance is
    created, costs roll forward, and listing points to the correct lot.

-   Two bots request the same scarce material: reservation prevents
    overspending or double allocation.

-   Guild buys a player listing: item ownership and gil settle exactly
    once, and cost basis equals the actual paid cost plus relevant fees.

-   AH purchase occurs at the same moment a listing is being cancelled
    or expiring: only one legal terminal state wins.

-   Stack consolidation and partial consumption preserve exact
    quantities and weighted/FIFO cost.

-   Market demand falls: guild stops producing surplus, listing age
    rises visibly, and no hidden disposal occurs.

-   Guild treasury reaches zero: procurement pauses safely and reports
    why; it does not refill itself.

-   Price manipulation attempts: an extravagant listing does not become
    the standard market value.

-   All bots are idle or offline: economic scheduler remains bounded and
    no runaway crafting/procurement loop occurs.

-   Crash/restart at every transaction boundary: no duplicate output,
    missing item, lost gil or stale reservation remains.

## 18.3 Mandatory bot scenarios

-   Bot wakes after restart in town with a stale travel plan and
    correctly reconciles actual position.

-   Bot attempts an unreachable camp repeatedly and eventually chooses a
    fallback rather than looping forever.

-   Bot reaches low HP/MP, evaluates risk, rests or retreats according
    to role and observed conditions.

-   Bot dies and follows baseline death, EXP, recovery and equipment
    behavior.

-   Bot cannot afford an upgrade and preserves funds for essential
    consumables.

-   Bot is in a party missing a role and attempts a viable recruitment
    strategy with a timeout.

-   Bot inventory is full while gathering and stops or returns to town
    without losing acquired items.

-   Bot's AH purchase fails because the listing disappeared; it re-plans
    and does not assume the item was received.

-   Bot encounters a linked add or unexpected danger and uses the
    correct defensive/retreat policy.

-   Bot has no useful goal and remains in a bounded safe idle state.

## 18.4 Quality gates

-   All migrations apply to a fresh disposable database and upgrade from
    the prior supported schema.

-   Baseline build succeeds; no new compiler/Lua errors; relevant tests
    pass.

-   All economic operations are auditable and idempotent.

-   Bot actions use authoritative game mechanics; no unexplained direct
    state edits.

-   New features have logs, metrics, error handling, docs and rollback
    instructions.

-   At least one integration test covers every new transaction boundary.

-   Changes are committed in small, reviewable units with an
    implementation summary and known limitations.

# 19. Implementation roadmap for Claude Code

Deliver in vertical slices. Do not attempt to implement the whole system
in one massive code-generation pass. Each phase ends with a working
build, migration check, tests, operational instructions and a written
report.

  ----------------------------------------------------------------------------
  Phase                   Deliverables            Exit gate
  ----------------------- ----------------------- ----------------------------
  0\. Reconnaissance      Repository inventory,   No implementation until
                          baseline tests,         current state is understood.
                          extension map,          
                          architecture decision   
                          records, identified     
                          source-of-truth tables  
                          and hooks.              

  1\. Foundation          Config schema, feature  Clean startup, safe
                          flags, event IDs,       shutdown, DB backup and
                          structured logging,     baseline tests.
                          migrations, local       
                          health checks,          
                          backup/restore scripts. 

  2\. Bot persistence     Stable profiles, state  Bots persist identity and
                          machine, durable        resume without duplicate
                          goals/plans, restart    actions.
                          reconciliation, 54-bot  
                          cohort seeding.         

  3\. Bot navigation and  Pathing adapter, stuck  Scenario tests show safe
  survival                detection, travel,      progress and no infinite
                          target observation,     loops.
                          rest/retreat, death     
                          recovery.               

  4\. Combat and jobs     Role policies, combat   Net EXP/hour and
                          adapters, job-aware     death/retreat telemetry;
                          actions, gear checks,   baseline mechanics
                          party composition and   preserved.
                          leveling.               

  5\. Economy ledger      Economic event journal, Every test item/gil delta
                          guild accounts, lots,   traces to a source event.
                          provenance,             
                          reservations,           
                          reconciliation.         

  6\. Shared AH           Guild-owned listings    Player and guild
  integration             through baseline AH,    transactions share
                          settlement, delivery,   invariants; fault tests
                          expiration/cancel and   pass.
                          listing reconciliation. 

  7\. Demand/pricing      Market observations,    No price hallucination;
                          completed-sales         low/high demand scenarios
                          history, demand         behave correctly.
                          signals, stock targets, 
                          fair pricing and        
                          budgets.                

  8\. Crafting and        Ingredient sourcing,    Craft inputs/outputs and
  Mercantile Guild        recipe-based craft      costs reconcile exactly.
                          jobs, merchant roles,   
                          output lineage, stack   
                          consolidation.          

  9\. Fieldcraft and      Work orders, tools,     Materials originate from
  gathering               resource acquisition,   real gathering actions and
                          route planning,         are traceable.
                          material delivery and   
                          market demand           
                          integration.            

  10\. Shopping and       Bot gear plans,         Bots acquire useful gear
  progression             shopping decisions,     without infinite budgets or
                          vendor/AH/Guild         repeated shopping loops.
                          comparisons, inventory  
                          hygiene and consumable  
                          planning.               

  11\. Dashboard and      Population/activity,    Metrics agree with source
  reports                 AH, guild, fieldcraft,  events and definitions are
                          combat, gil flows,      documented.
                          alerts and decision     
                          timeline.               

  12\. Hardening          72-hour soak,           No unresolved critical
                          restart/fault           integrity or stability
                          injection, economic     defects.
                          stress tests, backup    
                          recovery, performance   
                          profiling.              

  13\. Tune and release   Use observed telemetry  Repeatable
                          to tune policies,       launch/stop/update/restore
                          document baseline       process.
                          behavior, pin versions  
                          and publish local       
                          runbook.                
  ----------------------------------------------------------------------------

## 19.1 Suggested milestone strategy

Start with one bot and a small test cohort. Validate legal movement,
combat, persistence and transaction invariants before turning on 54
bots. Activate features behind flags. Run the economic scheduler in
dry-run mode first: it should explain what it would buy, craft, list or
withdraw without mutating stock. After its decisions look reasonable,
enable one category at a time. Do not simultaneously tune combat, market
pricing and gathering routes because the resulting telemetry will be
difficult to interpret.

# 20. Claude Code operating contract

## 20.1 Required behavior on every task

1.  Read repository guidance and inspect the exact files involved before
    editing.

2.  Restate the requested behavior as observable acceptance criteria and
    identify affected systems/data.

3.  Search for an existing implementation or extension point before
    creating a new abstraction.

4.  Make the smallest coherent change; do not refactor unrelated code or
    change the era baseline without approval.

5.  Add/update tests before or with the implementation, including
    failure and restart paths for stateful work.

6.  Run relevant formatting, static checks, unit/integration tests,
    build and migration validation available in the repository.

7.  Inspect the diff for accidental changes, generated files, secrets,
    schema drift and unrelated edits.

8.  Update docs/config examples and note any manual DB/server restart
    requirements.

9.  Report exact files created/modified, tests run and results,
    migrations, restart steps, rollback steps, known gaps and next
    recommended task.

10. Never claim tests passed if they were not run; clearly separate
    verified facts from assumptions.

## 20.2 Code and schema rules

-   Follow the repository's actual language/style conventions. Use C++
    only where server core hooks require it; use Lua for appropriate
    gameplay/module extensions; use SQL migrations for persistence; use
    the existing UI stack if one is present.

-   Do not invent API names, DB columns, event hooks, recipe IDs or
    settings. Search definitions and call sites.

-   Do not use raw SQL strings with untrusted input. Parameterize
    queries and follow project DB abstractions.

-   Keep item IDs, recipe IDs and job IDs as baseline references; avoid
    duplicated magic-number catalogs.

-   Keep configuration typed, validated and documented. Invalid config
    should fail safely with a clear message.

-   Use structured reason codes for AI decisions and economic
    rejections.

-   Do not swallow exceptions/errors silently. Retry only retryable
    failures, with bounded backoff and idempotency.

-   Any background loop needs cancellation, timing, concurrency limits
    and shutdown behavior.

-   All migrations need forward-upgrade instructions and an explicit
    backup/rollback strategy. Do not casually promise a destructive down
    migration is safe.

-   Keep local secrets, passwords, tokens and personal data out of logs
    and committed files.

## 20.3 Completion report format

\`\`\`text Implementation summary

\`\`\`text Files changed (created / modified / preserved)

\`\`\`text Behavior delivered and acceptance criteria

\`\`\`text Database migrations and data impact

\`\`\`text Tests/builds run (exact commands and outcomes)

\`\`\`text Operational steps: restart required? which process? config
reload?

\`\`\`text Rollback / backup / recovery

\`\`\`text Known limitations and risks

\`\`\`text Next smallest logical implementation step

## 20.4 Never do these

-   Never rewrite the entire server architecture in one task.

-   Never make up a game rule when the repository or era reference is
    unclear; document the uncertainty and ask for a decision if it
    changes behavior.

-   Never create inventory or gil as a shortcut to make a demo look
    successful.

-   Never bypass the standard AH or inventory transaction paths to save
    time.

-   Never treat bot intentions, planned crafts, or listings as realized
    demand or realized sales.

-   Never use an unbounded loop or per-tick full-world scan.

-   Never automatically delete characters, inventory, listings, orders
    or ledger history during routine startup.

-   Never promote a schema or policy change without backup, migration
    validation and reconciliation.

-   Never tune around a broken metric; verify the measurement before
    changing behavior.

# 21. Recommended repository organization

Adapt this layout to the existing conventions; do not force it if the
repo already has a better established structure. The goal is clear
ownership and isolation, not folder churn.

\`\`\`text docs/

\`\`\`text architecture/ \# ADRs, data flow, baseline behavior, threat
model

\`\`\`text operations/ \# local runbook, backup, restore, upgrades,
troubleshooting

\`\`\`text economy/ \# ledger, pricing, market policies, item provenance

\`\`\`text bots/ \# state machine, goals, combat, navigation, test
scenarios

\`\`\`text testing/ \# soak procedures, baselines, acceptance criteria

\`\`\`text modules/ or existing extension root/

\`\`\`text autonomous_adventurers/

\`\`\`text mercantile_guild/

\`\`\`text fieldcraft_guild/

\`\`\`text economy_ledger/

\`\`\`text admin_dashboard_adapter/

\`\`\`text sql/ or existing migration root/

\`\`\`text custom migrations following repository convention

\`\`\`text tools/

\`\`\`text diagnostics, reports, backup/restore, simulation harness

\`\`\`text config/

\`\`\`text schema and safe example configuration; no secrets

If the repository already has a bot implementation, extend and
modularize it rather than duplicating it. If an external bot project
such as a single-player/AutoBots fork is evaluated, port individual
capabilities after compatibility review instead of merging the whole
fork and its unrelated gameplay changes.

# 22. Operational model for the local server

## 22.1 Startup sequence

1.  Validate configuration and required paths; fail before mutation if
    invalid.

2.  Confirm database availability and run pending migrations only
    through the documented upgrade command.

3.  Load baseline server services and verify health.

4.  Run read-only reconciliation of guild inventory, AH links,
    reservations, bot identities and pending orders.

5.  Load bot profiles and restore persisted goals/plans; invalidate
    stale plans against actual world state.

6.  Start bot scheduler with staggered activation, not all 54 bots
    issuing actions simultaneously.

7.  Start economic planning in dry-run or safe mode; enable mutations
    only after health checks pass.

8.  Start dashboard and expose local health/metrics endpoints.

9.  Write a startup report containing version, commit SHA, migrations,
    bot count, feature flags and reconciliation results.

## 22.2 Shutdown sequence

1.  Stop accepting new admin mutations and new economic orders.

2.  Signal bot controllers to stop issuing actions and checkpoint
    durable state.

3.  Allow short in-flight transaction completion or leave recoverable
    durable state.

4.  Stop economic schedulers and flush the event outbox.

5.  Write final health/metrics snapshot and clean shutdown marker.

6.  Stop server processes in documented order; never kill the database
    before application shutdown unless recovery is required.

## 22.3 Backup and restore

-   Back up the database and configuration before migrations, bot resets
    or economic policy changes.

-   Keep a known-good baseline backup separate from the active database.

-   Document how to restore a backup into a disposable test instance
    before trusting it.

-   Do not restore only the economy tables if they refer to AH listings,
    characters or item IDs from a different database state.

-   Test restore periodically and record duration and validation
    results.

-   Keep code version, migration version, config version and backup
    timestamp together.

## 22.4 Logs and diagnostics

Use structured logs with timestamp, severity, subsystem, bot ID, plan
ID, order ID, item ID, event ID, reason code and correlation ID where
applicable. Separate high-volume decision traces from warnings/errors.
Provide one-command summaries for bot stuck reasons, unresolved orders,
ledger mismatches, AH delivery mismatches, and recent Lua/C++
exceptions.

# 23. Initial policy defaults and tuning principles

These are starting policies, not claims about ideal universal values.
Validate them with controlled scenarios and telemetry.

  -----------------------------------------------------------------------
  Policy                              Initial design stance
  ----------------------------------- -----------------------------------
  Bot cohort                          Start with 1, then 5, then 15, then
                                      54; stagger activation and monitor
                                      CPU, DB load and behavior.

  Controller cadence                  \~400 ms for lightweight state
                                      progression only; heavier planning
                                      is staggered and rate-limited.

  Guild margin                        20% default reference, configurable
                                      by category; compare with actual
                                      costs, fees and market demand.

  Guild startup capital               Finite and explicitly seeded;
                                      publish a ledger entry and initial
                                      inventory report.

  AH pricing                          Completed sales outrank asks;
                                      sparse markets lower confidence and
                                      use conservative cost/vendor
                                      references.

  Stock target                        Demand forecast + modest safety
                                      stock, bounded by max stock and
                                      available working capital.

  Essential goods                     Higher availability target for
                                      common tools/consumables; do not
                                      guarantee rare items.

  Shopping                            Cooldowns, minimum upgrade value,
                                      reserve funds and budget ceilings.

  Retreat                             Risk envelope uses role, HP/MP,
                                      links, party state, observed enemy
                                      threat and retreat route.

  Stuck recovery                      Bounded re-path/replan attempts,
                                      exponential backoff, then safe
                                      idle/quarantine and alert.

  Learning                            Transparent rolling statistics
                                      first; keep hard legality/safety
                                      constraints immutable.

  Market scheduler                    Dry-run first; mutation only after
                                      policy, budget and provenance
                                      checks.

  Logging                             Sample ordinary decisions; always
                                      log transaction failures, state
                                      transitions, policy changes and
                                      invariant violations.
  -----------------------------------------------------------------------

## 23.1 First tuning loop

1.  Run a stable baseline cohort for a defined period and freeze the
    configuration.

2.  Measure activity-state distribution, net EXP/hour, deaths, retreats,
    time-to-level, gear gaps, shopping outcomes and stuck loops.

3.  Measure AH sell-through with a clearly defined cohort and
    denominator, demand fulfillment, listing age and stockout duration.

4.  Measure guild acquisition cost, craft input feasibility, gross
    margin, inventory turns, budget utilization and all gil flows.

5.  Identify one dominant bottleneck at a time. Examples: low
    sell-through from bad prices; failed crafts from missing crystals;
    idle bots from impossible party requirements; low progression from
    excessive rest.

6.  Change one related policy group, run the same duration/scenario,
    compare against baseline and retain or revert.

7.  Record the result in a tuning log with config version, dates, sample
    size and confounding factors.

# 24. Risk register

  -----------------------------------------------------------------------
  Risk                    Impact                  Mitigation
  ----------------------- ----------------------- -----------------------
  Core fork drift         Custom patches become   Small patches, ADRs,
                          hard to merge or break  upstream-sync test plan
                          after upstream changes. and pinned commits.

  AH transaction mismatch Duplicated/lost items   Reuse baseline engine,
                          or gil.                 idempotency,
                                                  transactional
                                                  settlement and fault
                                                  injection.

  Phantom supply          Economy appears healthy Provenance required for
                          but inventory is        every lot/output and
                          fabricated.             100% lineage reporting.

  Bot market circularity  Bots buy/sell among     Actor-class reporting,
                          themselves and fake     circularity metrics,
                          demand or profits.      budgets and
                                                  realized-consumption
                                                  accounting.

  Overproduction          Guild floods the market Demand forecasts, max
                          and drains treasury.    stock, cooldowns,
                                                  margin checks and
                                                  slow-moving inventory
                                                  policy.

  Permanent stockouts     Bots cannot progress    Essential-item coverage
                          because required goods  targets, legitimate
                          are unavailable.        sourcing options,
                                                  priority queues and
                                                  shortage telemetry.

  Price runaway           Sparse AH asks distort  Completed-sale
                          guild price or make     weighting, confidence
                          goods unaffordable.     thresholds, cost/vendor
                                                  anchors and price caps.

  AI synchronized         All bots farm the same  Staggered scheduling,
  behavior                camp or shop at once.   personality variation,
                                                  route rotation and
                                                  per-zone caps.

  Planner CPU explosion   Tick delays and         Bounded planners,
                          database overload.      caching, staggered
                                                  work, profiling and
                                                  concurrency limits.

  Stale bot plans         Bots repeat failed      Persisted plan
                          travel/action after     versions, precondition
                          restart.                checks, timeouts and
                                                  startup reconciliation.

  Schema migration damage Existing                Backup, disposable
                          world/character data    upgrade test, additive
                          lost.                   migrations and restore
                                                  drills.

  Era drift               Custom features alter   Baseline regression
                          Phoenix gameplay        suite, feature flags
                          unintentionally.        and explicit decision
                                                  records.

  Unclear metrics         Tuning decisions        Metric dictionary,
                          optimize a misleading   source event IDs and
                          denominator.            independent
                                                  reconciliation.

  Admin surface exposure  Local tools allow       Localhost default,
                          unauthorized changes if authentication for
                          network-bound.          remote use, audit logs
                                                  and safe endpoints.
  -----------------------------------------------------------------------

# 25. Architecture decisions that must be explicitly recorded

Claude Code should create an Architecture Decision Record (ADR) whenever
a decision affects core behavior, persistence, market rules,
compatibility or operational risk.

-   Which exact Phoenix commit/branch is the baseline and what upstream
    sync policy is used?

-   How are headless bot entities represented in this baseline: native
    server-side character entities, a compatible bot framework, or a
    reviewed adapter?

-   Which Titan-inspired features are already available in code versus
    newly implemented?

-   Does guild stock acquire items through shop sale hooks, explicit
    sell-to-guild transactions, or both? What exact eligibility filters
    apply?

-   Which AH listing ownership model allows guild merchants to share the
    standard market without bypassing rules?

-   Which cost-basis method is selected: FIFO or weighted average?

-   What is the exact policy for item shop sourcing, especially
    crystals/clusters, rare/ex items, quest items and out-of-era items?

-   What are the default bot schedule weights, cohort makeup and role
    composition?

-   What is the economic bootstrap capital and how is its source
    recorded?

-   What are the precise definitions and time windows for sell-through,
    availability, stockout, margin and bot market share?

-   What local dashboard technology and authentication model fit the
    current repository and Windows environment?

-   What data retention, backup cadence, restore procedure and telemetry
    privacy rules apply?

# 26. First master prompt for Claude Code

Use this as the opening instruction in Claude Code after placing this
document in the repository as docs/MASTER_TECHNICAL_DESIGN.md. The
prompt intentionally asks Claude to inspect first and not rush into
implementation.

\`\`\`text You are the principal engineer for the FFXI - Forever project. 
Treat docs/MASTER_TECHNICAL_DESIGN.md as the
governing product and architecture specification.

MISSION Build a locally hosted, persistent FFXI world using the
checked-out Phoenix XI fork of LandSandBoat as the gameplay authority.
Add a fully auditable Titan-inspired Mercantile Guild / Auction House /
crafting / gathering economy and persistent autonomous server-side
adventurers. Preserve the configured classic/2006-era baseline unless a
documented ADR approves an exception.

NON-NEGOTIABLES 1. Inspect the repository, instructions, current commit,
working tree, build, DB schema, migrations, AH implementation, current
bot code, and existing tests before editing. 2. Do not assume public
Titan behavior proves its implementation details are available. Verify
the code actually present in this repository. 3. Do not rewrite the
server or merge an entire unrelated fork. Reuse existing hooks and make
small, reviewable changes. 4. Never create free items, gil, EXP, skills,
crafting outputs, or market demand. All changes must arise from
authoritative game actions or explicitly configured, ledgered seed
capital. 5. Reuse the baseline inventory, AH, crafting, party, combat,
navigation, delivery and character rules wherever possible. Bots choose
actions; the server validates outcomes. 6. Every economic item lot must
have provenance and cost basis. Every gil delta must be classified.
Reservations, purchases, crafts, listings and deliveries must be
idempotent. 7. Keep all custom features behind configuration/feature
flags where practical. No silent era changes, destructive migrations, or
automatic data resets. 8. Implement in vertical slices with tests. Do
not implement all subsystems in one pass. 9. Before any code change,
report the repository facts, unknowns, relevant files, test baseline,
risks, and a proposed small implementation plan. 10. After each slice,
report exact files changed, tests and commands run, migrations, restart
requirements, rollback steps, known gaps, and the next smallest task.

FIRST TASK --- Establish a fully working, locally hosted Final Fantasy 
XI server using the official Phoenix XI GitHub repository, with a 
functional MariaDB database, compiled server binaries, a working Ashita 
client configuration, and a convenient Windows launcher.

This is the prerequisite for all subsequent development. Do not begin 
implementing autonomous adventurers, the Mercantile Guild, gathering, 
crafting, economy simulation, dashboards, or other custom gameplay systems 
during this phase.

Definition of success: I can launch the local server, start the FFXI client 
through Ashita using a dedicated boot configuration, create or use a local 
account, log into the server, create a character, enter the game world, and 
move around in-game. I can stop and restart the server and reconnect successfully.

1. Authoritative Sources and Repository

Use these sources as the starting point:

- Phoenix XI repository: https://github.com/phoenixffxi/Phoenix
- LandSandBoat official quick-start guide: https://github.com/LandSandBoat/lsb-wiki/blob/main/Quick-Start-Guide.md
- LandSandBoat official wiki: https://github.com/LandSandBoat/server/wiki/
- LandSandBoat build troubleshooting: https://github.com/LandSandBoat/server/wiki/Build-Troubleshooting
- Ashita installation documentation: https://docs.ashitaxi.com/installation/
- Ashita v4 repository: https://github.com/AshitaXI/Ashita-v4beta

Before making changes, inspect the current Phoenix repository, its README, Git 
submodules, branches, settings, CMake presets, database tools, launch scripts, 
and any repository-specific setup instructions. Read any AI-agent guidance provided 
by the repository.

Use Phoenix as the actual server codebase. Do not clone the main LandSandBoat 
repository in place of Phoenix, and do not silently substitute a different server fork.

Read the complete relevant LSB installation guide, including its Windows installation 
procedure, database setup, configuration, build, and post-install steps. Adapt the 
instructions to the Phoenix fork only where inspection shows that adaptation is necessary.

When Phoenix and current upstream LSB instructions differ, document the difference and 
follow the version and structure supported by the checked-out Phoenix revision.

2. Host and Installation Assumptions

Target environment: Windows 11, running a local server and client on the same computer.

The host is intended for local development and testing, not public hosting. Keep the 
initial network configuration restricted to the local machine or trusted local network 
as required for testing. Do not expose server ports to the internet or configure router 
port forwarding.

Recommended separation of components:

- Phoenix server repository and build output: E:\PhoenixXI, if this path is available and appropriate.
- Ashita installation: a separate directory such as C:\Ashita.
- FFXI client: its existing valid installation directory.
- Custom Ashita boot configuration and launcher: kept separate from Ashita's default/example configurations.
- Database: a local MariaDB instance configured for the Phoenix server.

Avoid protected Windows folders and avoid using a drive root as the repository root. Do not assume that example paths exist; verify them.

3. Reconnaissance Before Installation

Begin with a read-only inventory and report:

- Current Windows version and architecture.
- Available drives, free disk space, and existing relevant folders.
- Whether Git, Python, CMake, Visual Studio 2022, MariaDB, and Ashita are already installed.
- Installed versions and executable paths for each dependency.
- Whether the FFXI client is installed and where it resides.
- Whether an existing Phoenix checkout or database exists.
- Whether the Phoenix checkout contains local modifications, custom code, or uncommitted work.
- Whether existing launcher files or server startup scripts can be reused.
- The checked-out Phoenix branch, commit hash, submodule status, and repository state.

Do not overwrite, delete, reset, or replace existing files or databases before checking their 
contents and confirming whether they contain user work. Back up any existing custom configuration 
or local changes before editing.

Produce a concise installation plan that identifies which dependencies can be reused, which 
need installation, and any compatibility concerns.

4. Install and Verify Required Dependencies

Install only missing or incompatible dependencies. Use official vendor sources wherever possible.

Required components

- Git for Windows.
- Python, at a version compatible with the checked-out Phoenix revision and its tools/requirements.txt.
- CMake, at a version compatible with the Phoenix CMake configuration.
- Microsoft Visual Studio 2022 Community or another suitable VS 2022 edition.
- The Visual Studio Desktop development with C++ workload, including the required MSVC toolchain and Windows SDK.
- CMake tools for Windows / Ninja as required by the Phoenix build system.
- MariaDB Server at a version compatible with Phoenix's SQL schema and database tooling.
- Ashita v4 and a compatible FFXI client installation.

Inspect the current Phoenix build configuration and official LSB guide before selecting exact versions. 
Do not automatically install the newest version of a dependency if it may break compatibility with the selected Phoenix revision.

MariaDB requirements

- Install or verify the MariaDB server service.
- Confirm that it starts and survives a reboot if configured for automatic startup.
- Secure the local database installation appropriately.
- Create or configure a dedicated database account for Phoenix using a strong local password.
- Create the database using the character set and collation expected by the checked-out Phoenix schema and LSB instructions.
- Configure Phoenix's database connection settings to match the actual database, username, password, host, and port.
- Verify a successful database connection using the repository's supported tooling.
- Do not put real passwords in committed source files, documentation, logs, or Git. If Phoenix's configuration format requires a local 
plaintext credential, keep it in an appropriate local configuration file and ensure it is not accidentally committed.
- Use the database tools shipped with the checked-out repository. Do not import an arbitrary SQL dump from another server fork or a 
mismatched schema version.

Dependency verification

For each component, record its installed version and verify that the relevant command or service works. If a prerequisite requires 
a reboot, administrator approval, or interactive installer action, explain exactly what is needed and pause when the user must intervene.

5. Clone or Validate the Phoenix Repository

If no suitable checkout exists, clone the Phoenix repository recursively into the selected server directory:

git clone --recursive https://github.com/phoenixffxi/Phoenix.git E:\FFXI Forever

If the checkout already exists, inspect it instead of cloning over it. Confirm its remote, branch, commit, local changes, and submodules.

If required, initialize or update submodules using the commands appropriate for the repository. Do not switch branches or update to an 
arbitrary revision merely to make the installation easier.

Record the initial Phoenix commit hash in the installation notes so the baseline can be reproduced.

Install the Python requirements using the repository's documented command and the compatible Python installation. Confirm that the 
dependency installation completes without errors.

Copy default settings into the runtime settings directory only if the repository instructions call for it and the target files do not 
already contain custom configuration. Preserve existing settings and compare files before overwriting.

6. Configure the Server

Inspect the actual settings files in the Phoenix checkout. Identify the configuration responsible for each of the following:

- SQL host, port, username, password, and database name.
- Server name and local environment options.
- Login and game-server bind addresses.
- Advertised server or zone addresses used by the client.
- Login, map, search, world, and other server processes present in this Phoenix revision.
- Ports and IP configuration used by the server's database tables and runtime settings.
- Logging paths and startup options.

Use the settings and process model supported by the checked-out Phoenix version. Do not assume the current upstream LSB configuration 
names or executable layout are identical to Phoenix.

Configure the server for local play. Ensure that the IP address used by the client, the address advertised by the login server, and the 
zone/server addresses are mutually consistent for a same-machine client. Use the local loopback address where supported and appropriate; 
if Phoenix requires a specific LAN address or different configuration for zone routing, document and configure it correctly.

Inspect the server's default ports and the current configuration before making firewall changes. Do not expose services externally. 
Do not disable Windows Firewall as a troubleshooting shortcut.

7. Initialize and Validate the Database

Use the Phoenix repository's database management tool and follow the matching LSB guide for the checked-out version.

Determine the correct sequence for:

- Initial database setup or reset.
- Schema and data import.
- Applying pending migrations.
- Any repository-specific database preparation steps.
- Creating or enabling a local player account, using the supported account-creation mechanism.

Use a fresh database only if necessary and safe. Never reset or drop an existing database without first backing it up and obtaining explicit 
approval if it contains existing data.

Confirm that required tables and baseline game data exist. Confirm that the database tool reports success and that Phoenix can connect to the database.

Document the exact database setup and update commands that work for this checkout. Do not use a database schema copied from a different LSB 
revision or another private-server fork.

8. Compile the Phoenix Server

Build the checked-out Phoenix source using its supported CMake workflow and the required Visual Studio 2022 toolchain.

Inspect CMakePresets.json, the repository build instructions, and any compatibility requirements before choosing a build command.

Use the repository's recommended optimized development configuration for routine play, typically RelWithDebInfo when supported. 
Avoid running a slow Debug build as the normal playable server configuration.

Use the build mechanism documented for this revision, which may be a repository Python build wrapper or CMake presets. 
For example, if supported by the checked-out Phoenix revision: py -3 .\tools\build.py

Or use the equivalent documented CMake preset workflow. Do not run both workflows unnecessarily if one already
configures and builds correctly.

Open the repository in Visual Studio 2022 when useful for initial configuration, debugging, and future C++ development. 
Verify that the C++ workload and CMake integration are installed and that the selected configuration is appropriate.

Check the full build output and confirm that all required server executables and runtime dependencies were produced. 
Record their actual paths.

Do not suppress compiler errors, patch build files blindly, or replace source files with upstream versions to force a 
successful build. Investigate failures and make only evidence-based, minimal compatibility changes.

After a successful build, perform a clean rebuild only if needed to prove that the build is reproducible. Record the 
exact successful command and configuration.

9. Establish a Reliable Server Startup and Shutdown Workflow

Determine every server process required by the checked-out Phoenix revision. Do not assume a three-process or four-process startup 
model without inspecting the repository and its startup scripts.

Create a simple, repeatable local startup mechanism that:

Verifies the expected server directory and required executables exist.
- Checks that MariaDB is running and attempts to start it only when appropriate.
- Performs any required database update or migration step using the documented tool.
- Starts the necessary Phoenix server processes in the correct order.
- Uses separate log files for the relevant processes.
- Detects early startup failures and reports which process failed.
- Avoids starting duplicate server instances.
- Leaves server console output or log files accessible for troubleshooting.

Create a matching shutdown mechanism that stops only the processes belonging to this local Phoenix instance, using a safe method supported by the repository. 
Do not indiscriminately terminate every process with a matching generic executable name if that could affect another server instance.

If a single launcher cannot reliably supervise all processes, provide a clear server-start batch file plus a separate shutdown script. 
Keep the solution straightforward and understandable.

The startup and shutdown scripts should use explicit working directories and quoted paths. 
They must not depend on the current PowerShell directory.

10. Install and Configure Ashita

Install or validate Ashita v4 using the official Ashita documentation and a current compatible distribution.

Keep Ashita in its own directory, separate from both the FFXI client directory and the Phoenix server repository. 
Do not place it under Program Files or another protected folder.

Identify the actual Ashita CLI executable, boot configuration format, and launch syntax for the installed version. 
Do not blindly reuse configuration examples written for a different Ashita version.

Create a dedicated custom configuration named: local-ffxi-forever.ini

If the current installation already contains a working copy, back it up and inspect it before changing it.

Configure it to:

- Launch the correct FFXI client executable through Ashita's supported bootloader.
- Use the proper FFXI game module and required arguments.
- Connect to the local Phoenix server using the correct server address and any required login-server settings.
- Use a custom script/configuration where appropriate.
- Preserve existing display resolution and client settings when possible.
- Avoid modifying Ashita's example boot configurations directly.

Follow Ashita's current guidance on keeping custom configurations separate from files overwritten during updates. Do not bundle 
copyrighted FFXI game files into the project or attempt to download unauthorized client files. Use the user's valid existing FFXI client installation.

Validate the launch syntax from the installed Ashita version. If the existing command is compatible, a launcher may use a pattern such as:

@echo off
title Phoenix XI - Local Client
cd /d "C:\Ashita"
start "" "Ashita-cli.exe" "local-phoenix.ini"
exit /b

This is an example, not an assumption about the correct executable path or arguments. Confirm the actual installation layout and use the correct command for that Ashita release.

11. Create a Convenient Game Launcher

Create a user-friendly Windows launcher that starts the server and client workflow with minimal manual effort.

Prefer separate scripts for server lifecycle and client launch, with an optional top-level launcher that orchestrates them. 
This keeps server troubleshooting and client troubleshooting separate.

The launch workflow should:

Verify that the local Phoenix installation is present.
- Start or verify MariaDB.
- Start the Phoenix server processes if they are not already running.
- Wait for the required processes to initialize, using reliable readiness checks where available rather than a fixed delay alone.
- Launch Ashita with local-phoenix.ini.
- Display understandable error messages if a prerequisite, database connection, server process, or client launch fails.

Do not claim the server is ready merely because a process was spawned. Check logs, process status, or a meaningful readiness condition.

Avoid storing passwords in batch files or passing sensitive credentials as command-line arguments.

Keep the scripts easy to maintain and compatible with the paths discovered on the machine. Document which files are newly 
created and which existing files were modified.


12. End-to-End Acceptance Tests

Do not declare FIRST TASK complete until the following tests have been executed and their results documented.


Infrastructure

- Phoenix repository remote, branch, and commit are recorded.
- All required submodules are present.
- Git, Python, CMake, and the VS 2022 C++ toolchain are usable.
- MariaDB starts and accepts a connection from Phoenix.
- The Phoenix database has been initialized with the matching schema and game data.
- All required Phoenix binaries compile successfully.
- Runtime DLLs and dependencies are available to the server processes.


Server

- Every required server process starts successfully.
- No process immediately exits or crashes.
- Logs show successful database connectivity and server initialization.
- The server advertises the correct local addresses and ports.
- The shutdown mechanism stops the intended processes cleanly.
- The server can be started again after shutdown without manual database repair.


Client

- Ashita starts using the custom local-phoenix.ini.
- The correct FFXI client is launched.
- The client reaches the Phoenix login screen/server connection.
- A local account can be created or an existing local account can authenticate.
- Character creation succeeds.
- The character enters the game world.
- The player can move and perform basic gameplay actions.
- Logs show no blocking connection or zone-transition errors.
- Disconnecting and reconnecting works.

Repeatability
- A full server stop and restart succeeds.
- The client can reconnect after the restart.
- The launcher can be run from a different working directory or a desktop shortcut.
- The setup and recovery steps are documented well enough to repeat.

If a test cannot be completed, state exactly what was attempted, what happened, the relevant log/error evidence, 
and what remains unresolved. Never mark a test successful based solely on reading configuration files or 
assuming that a command should work.


13. Documentation Deliverables

Create or update the following project documentation without overwriting unrelated user documentation:

- docs/LOCAL_SERVER_INSTALL.md — dependencies, version compatibility, installation steps, database initialization, build commands, configuration, and verification.
- docs/LOCAL_SERVER_OPERATIONS.md — startup, shutdown, logs, restart, backup, recovery, and common troubleshooting.
- docs/LOCAL_SERVER_BASELINE.md — Phoenix commit hash, installed dependency versions, configuration files used, successful build command, process list, ports, and acceptance-test results.


Also document:

- The exact paths used on the host.
- The names and purposes of the created launcher files.
- Every file modified and why.
- Every required manual action.
- Any deviations from the LSB guide and why they were necessary for Phoenix.
- Any limitations or unresolved issues.

Do not commit passwords, tokens, or other secrets. Do not commit machine-specific configuration unless it is deliberately designed to be safe and portable.

14. Scope Restrictions and Change Management

This phase is strictly about obtaining a stable playable baseline.

Do not:

- Implement autonomous bots.
- Change combat, experience, item, job, movement, or progression mechanics.
- Implement the Mercantile Guild, gathering, crafting automation, or auction-house logic.
- Import unrelated economy or bot code.
- Perform broad source refactors.
- Change database schemas except where required for a valid baseline installation.
- Update the Phoenix checkout to an unrelated upstream branch or commit.
- Remove existing files, user data, local configuration, or databases without approval.
- Open the server to public internet access.

Keep changes minimal and traceable. Use version control to identify modifications. Preserve the ability to reproduce the original checkout and build.

If a necessary fix would change gameplay logic or require a significant fork-specific patch, stop and explain the issue before proceeding.

15. Execution Protocol for Claude Code

Work in this order:

Stage A — Inspect: Read the Phoenix repository instructions and full relevant LSB installation documentation. Inventory the machine, checkout, installed dependencies, and existing configuration. Do not make destructive changes.
Stage B — Plan: Provide the user with a concise plan, including dependency versions, paths, existing resources to reuse, expected changes, and any required interactive installation steps.
Stage C — Install: Install or repair only the required dependencies, initialize MariaDB safely, configure Phoenix, and install/configure Ashita.
Stage D — Build: Compile the actual Phoenix checkout and resolve build errors with minimal, documented changes.
Stage E — Launch: Create and validate the server startup/shutdown workflow, custom Ashita boot configuration, and convenient game launcher.
Stage F — Test: Run the end-to-end acceptance tests. Verify real login, character creation, and entry into the game world.
Stage G — Document: Produce the installation, operations, and baseline documentation and report all changes.

At each stage, distinguish between completed work, commands that failed, and steps requiring user interaction. Request approval before destructive operations, 
database resets, deletion of user data, or changes with meaningful security implications. Do not fabricate command output or claim successful gameplay tests unless they were actually performed.

Final Completion Report

At the end, provide:

- The Phoenix repository URL, branch, and commit hash.
- Dependency names and installed versions.
- The server, database, client, Ashita, and launcher paths.
- The build command and result.
- The database initialization/update command and result.
- The required server processes and their status.
- The exact command or shortcut to start the local server.
- The exact command or shortcut to launch the game.
- The result of every acceptance test, including actual login and in-game verification.
- The documentation files created or updated.
- All custom source/configuration changes, backups, and outstanding issues.

FIRST TASK is complete only when the local server is demonstrably playable and the setup can be repeated. Once that baseline is stable, stop and await review before beginning Phase 1 of the autonomous Vana'diel implementation.

SECOND TASK --- RECONNAISSANCE ONLY Do not modify code yet. Produce: -
repository inventory and current commit/branch/working-tree status; -
build and test baseline; - actual extension points for bots, AH,
inventory, crafting, gathering and server events; - current bot features
and missing capabilities; - current DB tables/migrations relevant to
characters, AH, crafting, economy and bots; - a map of existing versus
missing functionality; - a risk register and proposed phased
implementation plan; - a list of decisions requiring owner approval.
Clearly label confirmed facts versus assumptions. Stop after presenting
this report.

After reconnaissance is reviewed, ask Claude Code to implement only
Phase 1 and its acceptance tests. Keep the rest of the roadmap as
backlog, not as a license to perform broad changes.

# 27. Phase-specific prompts

## 27.1 Bot persistence and state machine

\`\`\`text Implement only the bot persistence/state-machine slice
described in the master design. First inspect existing bot code and use
its conventions. Add stable bot profiles, durable goals and plans,
explicit states, bounded retries, action-result reason codes, and
startup reconciliation. Do not add economy, market, or advanced combat
behavior in this slice. Acceptance: a test bot preserves identity and
current goal across restart; stale plans are invalidated safely;
repeated failures lead to fallback/quarantine rather than a loop; all
new schema changes migrate cleanly; baseline build/tests pass.

## 27.2 Economic ledger and provenance

\`\`\`text Implement only the economic event journal, guild account,
inventory lots, cost basis, reservations and read-only reconciliation.
Do not enable automated buying, crafting or AH listing yet. Every
fixture must be test-only. Add tests for lot split/merge, partial
reservation, concurrent reservation, duplicate event replay, cost
allocation and unexplained gil/item deltas. Deliver a report that proves
every test stock unit and gil movement has traceable provenance.

## 27.3 Shared Auction House

\`\`\`text Integrate guild-owned listings through the existing Phoenix
AH transaction path. Before coding, map listing creation, fees,
buy/settlement, delivery, cancel, expiry, item eligibility, stack
behavior and failure recovery. Do not create a parallel market.
Implement one end-to-end transaction at a time with idempotency and
crash-recovery tests. Preserve player listing behavior unless an
approved ADR says otherwise. Start with one harmless test item in a
disposable DB and provide reconciliation output.

## 27.4 Demand-aware Mercantile Guild

\`\`\`text Implement guild planning in dry-run mode first. Use completed
sales, actual consumption, valid pending needs, inventory lots, input
feasibility, budget and price confidence. A listing ask is not a
completed sale. Bots' wishes are not realized demand. Use finite stock
targets, a configurable default 20% margin, legitimate acquisition paths
and strict era/item eligibility. Produce a decision report explaining
each proposed purchase, craft, list, reprice or skip. Do not enable
mutations until the dry-run scenarios pass.

## 27.5 Autonomous gathering and fieldcraft

\`\`\`text Implement Fieldcraft as work-order orchestration over real
baseline gathering actions. Use legal tools, skill checks, nodes,
resource depletion, route risk, inventory limits and actual item
acquisition. Connect material demand to Mercantile craft inputs via
explicit orders and ledgered transfers. Do not spawn materials or pay
from an unlimited treasury. Test successful yield, failed attempt,
depleted resource, full inventory, dangerous route, tool shortage,
cancellation, bot death, restart and duplicate work-order delivery.

## 27.6 Combat and progression

\`\`\`text Implement the next combat slice only after bot
persistence/navigation tests pass. Reuse baseline action validation and
combat resolution. Add role-specific action policies, pull risk,
rest/retreat, target selection, gear checks and party composition.
Optimize sustainable net EXP per wall-clock hour rather than raw DPS.
Record reason codes and test low HP/MP, linked adds, unavailable spells,
recast waits, death, gear gaps, unreachable camps and party timeout. Do
not directly grant progression.

## 27.7 Dashboard and soak testing

\`\`\`text Build read-only dashboard views from authoritative state and
economic events. Define each metric's formula, time window, denominator
and source. Include bot state distribution, leveling/death/retreat,
stuck reasons, AH sell-through, stockouts, listing age, guild
inventory/treasury, craft queues, fieldcraft backlog, gil sources/sinks
and reconciliation alerts. Then run 54 bots in staged soak tests,
capture CPU/memory/DB/queue metrics, and produce a report with
bottlenecks and one-variable tuning recommendations.

# 28. Release checklist

-   [ ] Baseline commit and local changes documented; clean backup
    verified.

-   [ ] All custom feature flags and configuration schema validated.

-   [ ] Fresh database migration and upgrade-from-supported-version test
    pass.

-   [ ] Existing player login, zoning, combat, inventory, AH, crafting
    and delivery regressions pass.

-   [ ] Bot identity, goals, plans and memory survive restart.

-   [ ] Bot actions use real server-side legality and state transitions.

-   [ ] Every guild item has provenance; every gil movement is
    classified.

-   [ ] AH listing, settlement, delivery, cancellation and expiration
    are idempotent.

-   [ ] Guild craft and gathering orders recover safely after crash.

-   [ ] Demand forecasting distinguishes completed sales, actual
    consumption and pending intent.

-   [ ] Market dry-run and economic stress scenarios pass.

-   [ ] 54-bot soak test completed; performance and behavior report
    retained.

-   [ ] Dashboard is localhost-only by default and administrative
    mutations are audited.

-   [ ] Backup/restore, start/stop, upgrade, rollback and
    troubleshooting instructions verified.

-   [ ] Known limitations, baseline deviations and next tasks
    documented.

# 29. Glossary

  -----------------------------------------------------------------------
  Term                                Meaning in this design
  ----------------------------------- -----------------------------------
  AH                                  The standard in-game Auction House
                                      and its established transaction
                                      semantics.

  Bot                                 A persistent autonomous adventurer
                                      represented through supported
                                      server-side player/entity
                                      mechanics.

  Cost basis                          Recorded cost allocated to the
                                      remaining units of a stock lot or
                                      crafted output.

  Demand signal                       An observed purchase, consumption
                                      event or valid pending need used to
                                      forecast replenishment.

  Economic event                      Immutable journal record of an
                                      item/gil acquisition, transfer,
                                      consumption, craft, listing or
                                      settlement.

  Fieldcraft Guild                    Gathering/procurement department
                                      that assigns work orders and
                                      delivers legitimately gathered
                                      inputs.

  Guild lot                           A quantity of a specific item with
                                      source, cost, ownership and
                                      lineage.

  Idempotency                         Repeated processing of the same
                                      logical request produces no
                                      duplicate side effects.

  Mercantile Guild                    Merchant/production subsystem that
                                      owns stock, crafts from inputs and
                                      lists through the AH.

  Provenance                          Traceable origin and transformation
                                      history of an item.

  Reconciliation                      Comparing related authoritative
                                      records and reporting or safely
                                      correcting discrepancies.

  Reservation                         A temporary allocation that
                                      prevents stock or funds from being
                                      committed twice.

  Sell-through                        A defined measure of how much
                                      listed stock sells over a specified
                                      cohort and time window.

  Source of truth                     The authoritative subsystem or
                                      record that decides a fact; caches
                                      and plans are not authoritative.

  Vertical slice                      A small end-to-end feature with
                                      persistence, behavior, tests,
                                      observability and operational
                                      documentation.
  -----------------------------------------------------------------------

# 30. Reference notes and implementation caveats

Public reference material reviewed on 18 October 2026:

-   Phoenix XI GitHub repository describes Phoenix as a LandSandBoat
    fork and links to the upstream project's AI-agent guidance and
    repository structure: https://github.com/phoenixffxi/Phoenix

-   Titan XI Mercantile Guild page describes shop-fed goods, guild
    merchant specialties, costed inputs, ingredient sourcing, a typical
    20% margin, stock consolidation, provenance and shared AH behavior:
    https://www.titan-xi.com/mercantile-guild

-   Titan XI Auction House page describes the standard in-game AH model,
    player listing behavior and persistent guild wares:
    https://www.titan-xi.com/auction-house

-   Titan XI overview describes its stated classic level-75 foundation
    and notes that it also includes custom behavior and quality-of-life
    changes: https://www.titan-xi.com/about

These sources describe the public product, not a complete implementation
specification. Claude Code must verify current code and schema before
adopting any exact behavior. The local Phoenix baseline takes precedence
where the user's goal is to preserve Phoenix/2006-era behavior. If a
Titan feature conflicts with the baseline, document the conflict in an
ADR and prefer a configurable, additive implementation rather than
silently importing Titan's balance decisions.

End of master design specification.
