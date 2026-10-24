-----------------------------------
-- The world brain: gives each registered bot a life.
--
--   worldTick (every 2.4 s, from the C++ module's time-server hook)
--     schedules (log in / log out), party formation, state saves, log pruning.
--   think (per bot, about once a second, after Nate's AI tick)
--     death and home point, rest, fights, goals (level, sell, shop, gather,
--     craft), travel between zones.
--
-- Everything a bot does goes through game actions: walking on the navmesh,
-- zone-line packets, Nate's combat AI, the death menu, NPC trades and shops.
-- Every decision is written to worldbots_log.
-----------------------------------
local config     = require('modules/worldbots/brain/config')
local context    = require('modules/worldbots/brain/context')
local schedule   = require('modules/worldbots/brain/schedule')
local population = require('modules/worldbots/brain/population')
local travel     = require('modules/worldbots/brain/travel')
local hunt       = require('modules/worldbots/brain/hunt')
local areas      = require('modules/worldbots/brain/areas')
local gear       = require('modules/worldbots/brain/gear')
local telemetry  = require('modules/worldbots/brain/telemetry')
local json       = require('modules/worldbots/lib/json')

local bots = xi.singleplayer.bots

local brain =
{
    recs     = {}, -- charId -> record { charId, row, state, mem, online }
    list     = {}, -- records in registry order
    started  = false,
    nextPrune = 0,
    nextParty = 0,
    activities = {}, -- name -> module with choose(rec, bot, now) / step(rec, bot, now); M5 and M6 add theirs
    -- Tried in this order: Signet first (crystal drops), crafting before selling (materials become goods).
    ACTIVITY_ORDER = { 'signet', 'craft', 'shop', 'gather' },
}

local function now()
    return os.time()
end

local function log(rec, kind, msg)
    WorldbotLog(rec.charId, kind, msg)
end
brain.log = log

local Role = bots.Role

-- Roles for Nate's AI. Solo, every job fights its own target; in a party the WAR tanks.
local SOLO_ROLE =
{
    [xi.job.WAR] = Role.Tank, [xi.job.MNK] = Role.Tank, [xi.job.THF] = Role.Tank,
    [xi.job.WHM] = Role.Healer, [xi.job.BLM] = Role.Nuker, [xi.job.RDM] = Role.Rdm,
}
local PARTY_ROLE =
{
    [xi.job.WAR] = Role.Tank, [xi.job.MNK] = Role.Melee, [xi.job.THF] = Role.Melee,
    [xi.job.WHM] = Role.Healer, [xi.job.BLM] = Role.Nuker, [xi.job.RDM] = Role.Rdm,
}
local MELEE_JOB = { [xi.job.WAR] = true, [xi.job.MNK] = true, [xi.job.THF] = true }
local CASTER_ROLE = { [Role.Healer] = true, [Role.Nuker] = true, [Role.Rdm] = true }

-- Nate's movement follows a player owner; world bots have none, so it would keep stepping a bot
-- toward itself (and cancel /heal every tick). The brain moves world bots; Nate's AI fights.
local function combatOnly(bot)
    bot:setBotMode(bots.BotMode.CombatOnly)
end
brain.combatOnly = combatOnly

-- Nate's roles stand a resting bot up once its MP is above 95% (his bots rest for MP; the player's
-- healer covers HP). A solo world bot rests for HP too, so while the brain rests a bot for HP that
-- rule is ignored, unless a monster is on the bot. Wrapped once, Nate's files unchanged.
if bots.ai_util and not bots.ai_util.nateStopRest then
    bots.ai_util.nateStopRest = bots.ai_util.stop_rest
    bots.ai_util.stop_rest = function(bot)
        local rec = xi.worldbots and xi.worldbots.brain and xi.worldbots.brain.recs[bot:getID()]
        if rec and rec.mem.restingForHp and not bot:isEngaged() then
            local threat = bots.threat and bots.threat.peelable_for and bots.threat.peelable_for(bot)
            if threat == nil then
                return
            end
        end
        return bots.ai_util.nateStopRest(bot)
    end
end

-----------------------------------
-- State persistence
-----------------------------------
local function save(rec)
    rec.state.savedAt = now()
    WorldbotSaveState(rec.charId, json:encode(rec.state))
    rec.lastSave = now()
end
brain.save = save

local function nextLevelGoal(level)
    return { kind = 'level', target = math.min(75, level - (level % 5) + 5) }
end

-----------------------------------
-- Gear: wear the best this bot can use from its inventory (level-appropriate, job-legal).
-- Better = higher required level, which is how 2006 gear progressed.
-----------------------------------
function brain.equipBest(bot)
    -- Best item per equip slot (brain/gear.lua): the job's weapon type, then level, then damage/defense.
    local best = {} -- slot -> { id, score }
    for _, item in ipairs(bot:worldbotInventory()) do
        local info  = WorldbotItemInfo(item.itemId)
        local score = info and gear.score(bot, info)
        if score then
            local slot = gear.slotOf(info)
            if best[slot] == nil or score > best[slot].score then
                best[slot] = { id = item.itemId, score = score }
            end
        end
    end
    local equipped = {}
    for slot, e in pairs(best) do
        if bot:getEquipID(slot) ~= e.id then
            bot:equipItem(e.id, nil, slot)
        end
        table.insert(equipped, e.id)
    end
    return equipped
end

-----------------------------------
-- Life cycle
-----------------------------------
local function roleFor(rec, inParty)
    local map = inParty and PARTY_ROLE or SOLO_ROLE
    return map[rec.row.job] or Role.Tank
end

brain.roleFor = roleFor

-- A solo bot's AI context, with its weapon skill (Nate's AI fires solo weapon skills from this list).
function brain.soloContext(rec, bot)
    local _, solo = brain.weaponSkillsFor({ { rec = rec, bot = bot } }) -- defined further down
    return context.form('solo:' .. rec.charId, { { entity = bot, role = roleFor(rec, false) } }, { solo = solo })
end

function brain.login(rec)
    local bot = WorldbotSpawnId(rec.charId)
    if bot == nil then
        rec.retryAt = now() + 300
        log(rec, 'error', 'login failed; retry in 5 min')
        return false
    end
    rec.online = true
    rec.mem    = { loginAt = now() }
    -- Listeners belong to the old entity after a relog; let Nate's code register them again.
    if bots.bots_listeners and bots.bots_listeners.registered then
        bots.bots_listeners.registered[rec.charId] = nil
    end
    bot:worldbotSetParent(rec.charId)
    combatOnly(bot)
    brain.soloContext(rec, bot)
    local s = rec.state
    s.level  = s.level or bot:getMainLvl()
    s.goal   = s.goal or nextLevelGoal(bot:getMainLvl())
    s.kills  = s.kills or 0
    s.deaths = s.deaths or 0
    s.fights = s.fights or 0
    s.gilStart = s.gilStart or bot:getGil()
    s.logins = (s.logins or 0) + 1
    local equipped = brain.equipBest(bot)
    log(rec, 'login', string.format('zone %d lv%d hp %d/%d gil %d goal %s %s; equipped %d items',
        bot:getZoneID(), bot:getMainLvl(), bot:getHP(), bot:getMaxHP(), bot:getGil(), s.goal.kind, tostring(s.goal.target), #equipped))
    save(rec)
    return true
end

function brain.logout(rec, reason)
    local bot = WorldbotGet(rec.charId)
    if bot ~= nil then
        if (rec.mem and rec.mem.fight) or bot:isEngaged() or bot:worldbotIsZoning() then
            return false -- finish the fight or the zone change first, as a player would
        end
        if rec.mem and rec.mem.party then
            brain.leaveParty(rec, 'logout')
        end
        rec.state.zone = bot:getZoneID()
        log(rec, 'logout', string.format('%s: zone %d lv%d gil %d', reason, bot:getZoneID(), bot:getMainLvl(), bot:getGil()))
    end
    save(rec)
    context.release(rec.charId)
    WorldbotDespawnId(rec.charId)
    rec.online = false
    rec.mem    = {}
    return true
end

-- After a zone change the C++ module reloads the character (as the server does for a client), so the
-- entity Lua knew is gone: rebuild the bot's party context and let Nate's listeners register again.
function brain.onArrive(bot, fromZone)
    local rec = brain.recs[bot:getID()]
    if rec == nil then
        return
    end
    if bots.bots_listeners and bots.bots_listeners.registered then
        bots.bots_listeners.registered[rec.charId] = nil
    end
    rec.mem.route    = nil
    rec.mem.progress = nil
    combatOnly(bot)
    if rec.mem.party then
        brain.refreshParty(rec.mem.party)
    else
        bot:worldbotSetParent(rec.charId)
        brain.soloContext(rec, bot)
    end
end

function brain.start()
    brain.started = true
    -- Bots whose registration failed join before seeding, so a slot they fill is not created twice.
    if population.adoptOrphans(function(msg) print('[worldbots] ' .. msg) end) > 0 then
        print('[worldbots] adopted unregistered world-bot characters')
    end
    local rows = population.load()
    if config.SEED_POPULATION then
        local created = population.seed(rows, config.SEED_NATIONS, config.SEED_JOBS, function(msg) print('[worldbots] ' .. msg) end)
        if created > 0 then
            rows = population.load()
        end
    end
    brain.recs, brain.list = {}, {}
    for _, row in ipairs(rows) do
        local rec = { charId = row.charId, row = row, state = row.state, mem = {}, online = WorldbotIsOnline(row.charId) }
        brain.recs[row.charId] = rec
        table.insert(brain.list, rec)
    end
    print(string.format('[worldbots] brain started: %d bots registered, schedule mode %s', #brain.list, config.SCHEDULE_MODE))
end

-- New registry rows (bots created at runtime, M7) join the brain without a restart.
function brain.refreshRegistry()
    local added = 0
    for _, row in ipairs(population.load()) do
        if brain.recs[row.charId] == nil then
            local rec = { charId = row.charId, row = row, state = row.state, mem = {}, online = WorldbotIsOnline(row.charId) }
            brain.recs[row.charId] = rec
            table.insert(brain.list, rec)
            added = added + 1
        end
    end
    return added
end

-- Grow the population toward `target` bots, a few per call (M7).
function brain.grow(target, perCall)
    local created = population.grow(brain.list, target, config.SEED_NATIONS, config.SEED_JOBS, perCall)
    return created, brain.refreshRegistry()
end

-----------------------------------
-- Parties (M4): bots of one nation at similar levels team up, as 2006 players did from level 10.
-----------------------------------
local function partyCandidates()
    local byNation = {}
    for _, rec in ipairs(brain.list) do
        local bot = rec.online and WorldbotGet(rec.charId) or nil
        if bot and not rec.mem.party and not bot:isDead() and not bot:worldbotIsZoning()
           and bot:getMainLvl() >= config.PARTY_MIN_LEVEL and not rec.mem.activity then
            byNation[rec.row.nation] = byNation[rec.row.nation] or {}
            table.insert(byNation[rec.row.nation], { rec = rec, bot = bot })
        end
    end
    return byNation
end

-- Weapon skills for a party from what its members hold: one skillchain pair (opener, closer) when two
-- members' first weapon skills chain, and every other melee member's skill for Nate's solo-WS list.
-- members: { { rec, bot }, ... }. Returns sc, solo.
local MELEE_ROLES = { [Role.Tank] = true, [Role.Melee] = true }
local function weaponSkillsFor(members)
    local ws = {}
    for _, m in ipairs(members) do
        local w = gear.weaponSkill(m.bot)
        if w then
            table.insert(ws, { m = m, w = w })
        end
    end
    local sc, inPair = {}, {}
    for _, a in ipairs(ws) do
        for _, b in ipairs(ws) do
            if #sc == 0 and a ~= b and gear.chain(a.w.prop, b.w.prop) then
                sc = { { priority = 1, openCharId = a.m.rec.charId, openName = a.m.bot:getName(), openWS = a.w.name,
                         closeCharId = b.m.rec.charId, closeName = b.m.bot:getName(), closeWS = b.w.name, chain = gear.chain(a.w.prop, b.w.prop) } }
                inPair[a.m.rec.charId], inPair[b.m.rec.charId] = true, true
            end
        end
    end
    local solo = {}
    for _, e in ipairs(ws) do
        local role = (#members > 1 and PARTY_ROLE or SOLO_ROLE)[e.m.rec.row.job]
        if not inPair[e.m.rec.charId] and MELEE_ROLES[role] then
            solo[e.m.rec.charId] = e.w.name
        end
    end
    return sc, solo
end
brain.weaponSkillsFor = weaponSkillsFor

function brain.formParty(group)
    table.sort(group, function(a, b)
        local ta = PARTY_ROLE[a.rec.row.job] == Role.Tank and 0 or 1
        local tb = PARTY_ROLE[b.rec.row.job] == Role.Tank and 0 or 1
        if ta ~= tb then
            return ta < tb
        end
        return a.rec.charId < b.rec.charId
    end)
    local leader = group[1]
    local key    = 'party:' .. leader.rec.charId
    leader.bot:formPartyAlone()
    local members = {}
    for i, m in ipairs(group) do
        if i > 1 then
            leader.bot:partyAddMember(m.bot)
        end
        table.insert(members, { entity = m.bot, role = PARTY_ROLE[m.rec.row.job] or Role.Melee })
        m.rec.mem.party = key
        m.rec.mem.fight = nil
        m.bot:worldbotSetParent(leader.rec.charId)
        combatOnly(m.bot)
    end
    local sc, solo = weaponSkillsFor(group)
    context.form(key, members, { sc = sc, solo = solo })
    local names = {}
    for _, m in ipairs(group) do
        table.insert(names, string.format('%s(%d)', m.bot:getName(), m.bot:getMainLvl()))
    end
    for _, m in ipairs(group) do
        log(m.rec, 'party', string.format('joined %s led by %s: %s; skillchain %s', key, leader.bot:getName(), table.concat(names, ' '),
            sc[1] and string.format('%s %s > %s %s (%s)', sc[1].openName, sc[1].openWS, sc[1].closeName, sc[1].closeWS, sc[1].chain) or 'none'))
    end
end

-- Rebuild a party's context from its members' current entities (after one of them zoned).
function brain.refreshParty(key)
    local members, present, leaderId = {}, {}, tonumber(key:match('%d+'))
    for _, other in ipairs(brain.list) do
        if other.mem.party == key then
            local bot = WorldbotGet(other.charId)
            if bot then
                local m = { entity = bot, role = PARTY_ROLE[other.row.job] or Role.Melee }
                if other.charId == leaderId then
                    table.insert(members, 1, m)
                else
                    table.insert(members, m)
                end
                table.insert(present, { rec = other, bot = bot })
            end
        end
    end
    if #members > 0 then
        local sc, solo = weaponSkillsFor(present)
        context.form(key, members, { sc = sc, solo = solo })
    end
end

function brain.leaveParty(rec, reason)
    local key = rec.mem.party
    if key == nil then
        return
    end
    -- The whole party breaks up when a member leaves; the rest go solo and re-form on the next pass.
    for _, other in ipairs(brain.list) do
        if other.mem.party == key then
            local bot = WorldbotGet(other.charId)
            other.mem.party = nil
            other.mem.fight = nil
            if bot then
                local leader = WorldbotGet(tonumber(key:match('%d+')))
                if leader and leader ~= bot then
                    leader:partyRemoveMember(bot)
                end
                bot:worldbotSetParent(other.charId)
                brain.soloContext(other, bot)
            end
            log(other, 'party', 'left ' .. key .. ': ' .. reason)
        end
    end
    -- The leader's engine party is left with only the leader: disband it.
    local leader = WorldbotGet(tonumber(key:match('%d+')))
    if leader and leader.worldbotLeaveParty then
        leader:worldbotLeaveParty()
    end
end

-- A party's members: { { rec, bot }, ... } (online, in the brain).
local function partyMembers(key)
    local out = {}
    for _, other in ipairs(brain.list) do
        if other.mem.party == key then
            local bot = WorldbotGet(other.charId)
            if bot then
                table.insert(out, { rec = other, bot = bot })
            end
        end
    end
    return out
end

-- An eligible solo bot joins its nation's party with room, when its level fits (as players filled a slot).
local joinExisting

-- A solo bot about to start an errand looks for a party first (an invitation beats a shopping trip).
function brain.tryJoin(rec, bot)
    if rec.mem.party or bot:getMainLvl() < config.PARTY_MIN_LEVEL or bot:getFreeSlotsCount() <= 4 then
        return false
    end
    return joinExisting({ rec = rec, bot = bot })
end

joinExisting = function(c)
    for _, other in ipairs(brain.list) do
        local key = other.mem.party
        if key and other.row.nation == c.rec.row.nation and key == 'party:' .. other.charId then -- each party once, via its leader
            local members = partyMembers(key)
            if #members < 6 then
                local lo, hi = math.huge, 0
                for _, m in ipairs(members) do
                    lo, hi = math.min(lo, m.bot:getMainLvl()), math.max(hi, m.bot:getMainLvl())
                end
                local lv = c.bot:getMainLvl()
                if math.max(hi, lv) - math.min(lo, lv) <= config.PARTY_LEVEL_SPREAD then
                    local leader = WorldbotGet(other.charId)
                    leader:partyAddMember(c.bot)
                    c.rec.mem.party = key
                    c.rec.mem.fight = nil
                    c.bot:worldbotSetParent(other.charId)
                    combatOnly(c.bot)
                    brain.refreshParty(key)
                    for _, m in ipairs(partyMembers(key)) do
                        log(m.rec, 'party', string.format('%s (%s lv%d) joined %s', c.bot:getName(), tostring(c.rec.row.job), lv, key))
                    end
                    return true
                end
            end
        end
    end
    return false
end

function brain.updateParties()
    -- Parties whose weakest member is below the party level break up (solo until then).
    for _, rec in ipairs(brain.list) do
        if rec.mem.party and rec.mem.party == 'party:' .. rec.charId then
            local lowest = math.huge
            for _, other in ipairs(brain.list) do
                local b = other.mem.party == rec.mem.party and WorldbotGet(other.charId) or nil
                if b then
                    lowest = math.min(lowest, b:getMainLvl())
                end
            end
            if lowest < config.PARTY_MIN_LEVEL then
                brain.leaveParty(rec, string.format('party level is %d (solo until %d)', lowest, config.PARTY_MIN_LEVEL))
            end
        end
    end
    for _, group in pairs(partyCandidates()) do
        local rest = {}
        for _, c in ipairs(group) do
            if not joinExisting(c) then
                table.insert(rest, c)
            end
        end
        group = rest
        table.sort(group, function(a, b) return a.bot:getMainLvl() > b.bot:getMainLvl() end)
        -- Take runs of bots within PARTY_LEVEL_SPREAD of each other, up to 6.
        local i = 1
        while i <= #group do
            local run = { group[i] }
            local top = group[i].bot:getMainLvl()
            local j   = i + 1
            while j <= #group and #run < 6 and top - group[j].bot:getMainLvl() <= config.PARTY_LEVEL_SPREAD do
                table.insert(run, group[j])
                j = j + 1
            end
            if #run >= 3 then
                brain.formParty(run)
            end
            i = j
        end
    end
end

-----------------------------------
-- World tick
-----------------------------------
function brain.worldTick()
    if not config.ENABLED then
        return
    end
    if not brain.started then
        brain.start()
    end
    local t       = os.date('*t')
    local logins  = 0
    local logouts = 0
    local online = 0
    for _, rec in ipairs(brain.list) do
        if rec.online then
            online = online + 1
        end
    end
    for _, rec in ipairs(brain.list) do
        local want = rec.row.enabled and (config.SCHEDULE_MODE == 'always' or schedule.isOnline(rec.row.schedule, t))
        if want and not rec.online then
            if logins < config.MAX_LOGINS_PER_TICK and online < config.MAX_ONLINE and now() >= (rec.retryAt or 0) then
                if brain.login(rec) then
                    logins = logins + 1
                    online = online + 1
                end
            end
        elseif not want and rec.online then
            rec.mem.leaving = true -- finish the current fight, start nothing new
        end
        if not want and rec.online and logouts < config.MAX_LOGINS_PER_TICK * 2 then
            if brain.logout(rec, rec.row.enabled and 'schedule' or 'disabled') then
                logouts = logouts + 1
            end
        end
        if rec.online and now() - (rec.lastSave or 0) >= config.STATE_SAVE_SECONDS then
            save(rec)
        end
    end
    if now() >= brain.nextParty then
        brain.nextParty = now() + 30
        brain.updateParties()
    end
    if now() >= brain.nextPrune then
        brain.nextPrune = now() + 24 * 3600
        WorldbotPruneLog(config.LOG_PRUNE_DAYS)
    end
end

-----------------------------------
-- Per-bot thinking
-----------------------------------
local function partyLeader(rec)
    if rec.mem.party == nil then
        return nil
    end
    return WorldbotGet(tonumber(rec.mem.party:match('%d+')))
end

local function isPartyLeader(rec)
    return rec.mem.party == nil or rec.mem.party == 'party:' .. rec.charId
end

local function needsRest(bot)
    if bot:getHPP() < config.REST_HPP then
        return true
    end
    return bot:getMaxMP() > 0 and bot:getMPP() < config.REST_MPP
end

local function rested(bot)
    return bot:getHP() >= bot:getMaxHP() and (bot:getMaxMP() == 0 or bot:getMP() >= bot:getMaxMP())
end

local function claimOwner(rec)
    return rec.mem.party or ('solo:' .. rec.charId)
end

local function finishFight(rec, bot, result, t)
    local f = rec.mem.fight
    rec.mem.fight = nil
    hunt.release(f.mobId, claimOwner(rec))
    local s = rec.state
    s.fights = (s.fights or 0) + 1
    if result == 'won' then
        s.kills = (s.kills or 0) + 1
    end
    local expGain = bot:getCurrentJobExp() - f.expStart
    if bot:getMainLvl() > f.lvStart then
        expGain = expGain + 1000 -- crossed a level; the exact figure is in the level log line
    end
    log(rec, 'fight', string.format('%s %s (lv%d, id %d) in %ds; exp %+d; hp %d/%d; zone %d%s%s',
        result, f.mobName, f.mobLevel, f.mobId, t - f.startAt, expGain, bot:getHP(), bot:getMaxHP(), bot:getZoneID(),
        rec.mem.party and (' (' .. rec.mem.party .. ')') or '', telemetry.take(rec)))
    if result ~= 'won' then
        rec.mem.skip = rec.mem.skip or {}
        rec.mem.skip[f.mobId] = t + 120
        bots.set_alliance_target(0)
    end
end

-- Hand a monster to the AI: walk close, set the party target, engage; keep in range while Nate's AI fights.
local function fightStep(rec, bot, t)
    local f   = rec.mem.fight
    local mob = GetMobByID(f.mobId)
    if mob == nil or not mob:isAlive() then
        return
    end
    local d      = travel.dist(bot, mob:getXPos(), mob:getYPos(), mob:getZPos())
    local role   = context.of(rec.charId) and context.of(rec.charId).roleMap[rec.charId] or Role.Tank
    -- Casters in a party (level 10+) keep their distance; everyone else fights in melee range.
    local caster = rec.mem.party ~= nil and CASTER_ROLE[role] and bot:getMainLvl() >= 10
    local reach  = caster and 15 or 2.5

    if bot:isEngaged() then
        if d > reach + 1 then
            travel.walkTo(bot, rec.mem, mob:getXPos(), mob:getYPos(), mob:getZPos(), reach, t)
        else
            bot:lookAt(mob:getPos())
        end
        return
    end
    if d > math.max(reach, 6) then
        travel.walkTo(bot, rec.mem, mob:getXPos(), mob:getYPos(), mob:getZPos(), math.max(reach, 5), t)
        return
    end
    bots.set_alliance_target(f.mobId)
    if not caster then
        bot:engage(mob:getTargID())
    end
end

local huntLevel

local function chooseCamp(rec, bot, exclude)
    local s       = rec.state
    local level   = huntLevel(rec, bot)
    local zone, n = hunt.chooseZone(rec.row.nation, level, rec.mem.party ~= nil, exclude)
    s.campForParty = rec.mem.party ~= nil
    if zone ~= s.campZone then
        log(rec, 'goal', string.format('camp for lv%d: zone %s (%d monsters in range)', level, tostring(zone), n or 0))
    end
    s.campZone  = zone
    s.campLevel = level
end

-- A party hunts for its weakest member: the lowest level among those online.
huntLevel = function(rec, bot)
    local level = bot:getMainLvl()
    if rec.mem.party then
        for _, other in ipairs(brain.list) do
            if other.mem.party == rec.mem.party then
                local b = WorldbotGet(other.charId)
                if b then
                    level = math.min(level, b:getMainLvl())
                end
            end
        end
    end
    return level
end

local function huntStep(rec, bot, t)
    local s     = rec.state
    local level = huntLevel(rec, bot)
    local inBand = false
    for _, z in ipairs(areas.candidates(rec.row.nation, level)) do
        inBand = inBand or z == s.campZone
    end
    local partyChanged = (rec.mem.party ~= nil) ~= (s.campForParty == true)
    if s.campZone == nil or s.campLevel == nil or (not inBand and not s.campForParty) or partyChanged or math.abs(level - s.campLevel) >= 3 then
        chooseCamp(rec, bot)
        rec.mem.emptyPicks = 0
    end
    if s.campZone == nil then
        return
    end
    if bot:getZoneID() ~= s.campZone then
        local r = travel.toZone(bot, rec.mem, s.campZone, t)
        if r ~= rec.mem.lastTravel then
            rec.mem.lastTravel = r
            if r == 'noroute' or r == 'giveup' then
                log(rec, 'travel', string.format('%s from zone %d to %d; choosing another camp', r, bot:getZoneID(), s.campZone))
                s.campZone = nil
            end
        end
        return
    end
    rec.mem.lastTravel = nil
    if t < (rec.mem.nextPick or 0) then
        return
    end
    rec.mem.nextPick = t + 3
    local casterJob    = rec.row.job == xi.job.WHM or rec.row.job == xi.job.BLM or rec.row.job == xi.job.RDM
    local minLv, maxLv = areas.levelWindow(level, rec.mem.party ~= nil, casterJob)

    -- A party settles at the zone's exp camp and hunts around it.
    local camp, radius = nil, nil
    if rec.mem.party then
        camp = rec.mem.camp
        if camp == nil or camp.zone ~= bot:getZoneID() or t >= camp.untilT then
            local spot = hunt.campSpot(bot, minLv, maxLv)
            if spot then
                camp = { zone = bot:getZoneID(), x = spot.x, y = spot.y, z = spot.z, untilT = t + 600 }
                rec.mem.camp = camp
                log(rec, 'camp', string.format('exp camp in zone %d at %.0f %.0f %.0f (%d monsters lv%d-%d around)', camp.zone, camp.x, camp.y, camp.z, spot.count, minLv, maxLv))
            end
        end
        if camp and travel.dist(bot, camp.x, camp.y, camp.z) > config.CAMP_RADIUS then
            travel.walkTo(bot, rec.mem, camp.x, camp.y, camp.z, 10, t) -- to camp first
            return
        end
        radius = camp and config.CAMP_RADIUS
    end

    for _, c in ipairs(hunt.candidates(bot, minLv, maxLv, camp, claimOwner(rec), t, radius)) do
        local skipUntil = rec.mem.skip and rec.mem.skip[c.mob:getID()]
        if skipUntil == nil or t >= skipUntil then
            rec.mem.emptyPicks = 0
            hunt.start(rec.mem, bot, c.mob, t)
            hunt.claim(c.mob:getID(), claimOwner(rec), t)
            log(rec, 'target', string.format('%s (lv%d, id %d) at %.0f yalms', c.mob:getName(), c.mob:getMainLvl(), c.mob:getID(), math.sqrt(c.d2)))
            return
        end
    end
    -- Nothing worth hunting here for a minute (about 20 picks while wandering): try the next camp.
    rec.mem.emptyPicks = (rec.mem.emptyPicks or 0) + 1
    if rec.mem.emptyPicks >= 60 then -- about three minutes of wandering
        rec.mem.emptyPicks = 0
        log(rec, 'goal', string.format('no monsters for lv%d in zone %d; moving camp', level, bot:getZoneID()))
        rec.mem.badCamps = rec.mem.badCamps or {}
        rec.mem.badCamps[bot:getZoneID()] = t + 900
        local exclude = {}
        for z, untilT in pairs(rec.mem.badCamps) do
            if t < untilT then
                exclude[z] = true
            end
        end
        chooseCamp(rec, bot, exclude)
        return
    end
    -- Nothing here: wander to find spawns, never toward aggressive monsters too strong for the bot.
    if camp then
        -- Nothing up at camp right now: wait there for the next spawn, as a party did.
        if travel.dist(bot, camp.x, camp.y, camp.z) > 15 then
            travel.walkTo(bot, rec.mem, camp.x, camp.y, camp.z, 10, t)
        end
        return
    end
    if rec.mem.wander == nil or t > rec.mem.wander.untilT then
        -- Head for where the monsters are; wander at random only when the zone has none in range at all.
        local target = hunt.nearestAnywhere(bot, minLv, maxLv)
        if target then
            rec.mem.wander = { x = target.x, y = target.y, z = target.z, untilT = t + 40 }
            travel.walkTo(bot, rec.mem, target.x, target.y, target.z, 20, t)
            return
        end
        local dangers = hunt.dangers(bot, maxLv)
        for _ = 1, 8 do
            local a = math.random() * math.pi * 2
            local x, z = bot:getXPos() + math.cos(a) * 60, bot:getZPos() + math.sin(a) * 60
            if hunt.isSafe(dangers, x, z) then
                rec.mem.wander = { x = x, y = bot:getYPos(), z = z, untilT = t + 40 }
                break
            end
        end
        rec.mem.wander = rec.mem.wander or { x = bot:getXPos(), y = bot:getYPos(), z = bot:getZPos(), untilT = t + 20 }
    end
    travel.walkTo(bot, rec.mem, rec.mem.wander.x, rec.mem.wander.y, rec.mem.wander.z, 5, t)
end

-- Party members other than the leader stay with the leader between fights.
local function followLeader(rec, bot, t)
    local leader = partyLeader(rec)
    if leader == nil then
        return
    end
    if leader:getZoneID() ~= bot:getZoneID() then
        travel.toZone(bot, rec.mem, leader:getZoneID(), t)
        return
    end
    if travel.dist(bot, leader:getXPos(), leader:getYPos(), leader:getZPos()) > 8 then
        travel.walkTo(bot, rec.mem, leader:getXPos(), leader:getYPos(), leader:getZPos(), 6, t)
    end
end

-- Time spent in think (M7 load reports): { calls, total, max } in seconds, reset by brain.takeProfile().
brain.prof = { calls = 0, total = 0, max = 0 }

function brain.takeProfile()
    local p = brain.prof
    brain.prof = { calls = 0, total = 0, max = 0 }
    return p
end

local thinkImpl

function brain.think(bot)
    local started = os.clock()
    thinkImpl(bot)
    local dt = os.clock() - started
    local p  = brain.prof
    p.calls, p.total = p.calls + 1, p.total + dt
    if dt > p.max then
        p.max = dt
    end
end

thinkImpl = function(bot)
    local rec = brain.recs[bot:getID()]
    if rec == nil or not rec.online then
        return
    end
    local t = now()
    if t < (rec.mem.nextThink or 0) then
        return
    end
    rec.mem.nextThink = t + 1
    local s = rec.state

    -- Death: wait for a raise, then return to the home point as a player would.
    if bot:isDead() then
        if rec.mem.deadAt == nil then
            rec.mem.deadAt = t
            s.deaths = (s.deaths or 0) + 1
            local f = rec.mem.fight
            log(rec, 'death', string.format('died in zone %d to %s at lv%d', bot:getZoneID(), f and f.mobName or 'unknown', bot:getMainLvl()))
            if f then
                finishFight(rec, bot, 'lost', t)
            end
        elseif t - rec.mem.deadAt >= config.HOMEPOINT_AFTER_SECONDS and not rec.mem.homepointAt then
            if bot:worldbotHomePoint() then
                rec.mem.homepointAt = t
                log(rec, 'homepoint', 'returning to home point')
            end
        end
        return
    end
    if rec.mem.deadAt then
        log(rec, 'revive', string.format('back in zone %d with hp %d/%d', bot:getZoneID(), bot:getHP(), bot:getMaxHP()))
        rec.mem.deadAt, rec.mem.homepointAt = nil, nil
        rec.mem.route = nil
    end
    if bot:worldbotIsZoning() then
        return
    end
    if s.lastZone ~= bot:getZoneID() then
        if s.lastZone ~= nil then
            log(rec, 'zone', string.format('%d -> %d', s.lastZone, bot:getZoneID()))
        end
        s.lastZone = bot:getZoneID()
    end

    -- Levels and goals.
    local level = bot:getMainLvl()
    if level ~= s.level then
        log(rec, 'level', string.format('lv%d -> lv%d (%d fights, %d kills, %d deaths so far)', s.level or 0, level, s.fights or 0, s.kills or 0, s.deaths or 0))
        s.level = level
        brain.equipBest(bot)
        save(rec)
    end
    if s.goal and s.goal.kind == 'level' and level >= s.goal.target then
        log(rec, 'goal', string.format('reached lv%d', level))
        s.goal = nextLevelGoal(level)
        log(rec, 'goal', string.format('next: level %d', s.goal.target))
        save(rec)
    end

    -- A fight in progress (ours, or a monster that attacked the party: Nate's threat code sets the target).
    local A = context.of(rec.charId)
    if rec.mem.fight == nil and A and (A.allianceTarget or 0) ~= 0 then
        local mob = GetMobByID(A.allianceTarget)
        if mob and mob:isAlive() then
            hunt.start(rec.mem, bot, mob, t)
            rec.mem.fight.engaged = true
            log(rec, 'aggro', string.format('%s (lv%d) attacked or party target', mob:getName(), mob:getMainLvl()))
        end
    end
    if rec.mem.fight then
        local result = hunt.check(rec.mem, bot, t)
        if result then
            finishFight(rec, bot, result, t)
        else
            rec.mem.restingForHp = nil
            if bot:isBotResting() then
                bot:stopBotResting()
            end
            fightStep(rec, bot, t)
            return
        end
    end

    -- Rest between fights.
    if rec.mem.restingForHp then
        if rested(bot) then
            rec.mem.restingForHp = nil
            bot:stopBotResting()
            log(rec, 'rest', string.format('rested to hp %d/%d mp %d/%d in %ds', bot:getHP(), bot:getMaxHP(), bot:getMP(), bot:getMaxMP(), t - (rec.mem.restStart or t)))
        elseif not bot:isBotResting() then
            bot:startBotResting() -- stood up by something else (a monster, a role); sit again
        end
        return
    end
    if needsRest(bot) and not bot:isEngaged() then
        rec.mem.restingForHp = true
        rec.mem.restStart    = t
        bot:startBotResting()
        return
    end

    if rec.mem.leaving then
        return -- logging out at the next world tick
    end

    -- Activities other than hunting (selling, shopping, gathering, crafting).
    if rec.mem.activity then
        local act = brain.activities[rec.mem.activity]
        if act == nil or act.step(rec, bot, t) ~= 'running' then
            log(rec, 'activity', 'finished ' .. tostring(rec.mem.activity))
            rec.mem.activity = nil
        end
        return
    end
    if isPartyLeader(rec) and t >= (rec.mem.nextActivityCheck or 0) then
        rec.mem.nextActivityCheck = t + 30
        if rec.mem.party == nil and brain.tryJoin(rec, bot) then
            return
        end
        for _, name in ipairs(brain.ACTIVITY_ORDER) do
            local act = brain.activities[name]
            if act and act.choose(rec, bot, t) then
                rec.mem.activity = name
                log(rec, 'activity', 'starting ' .. name)
                return
            end
        end
    end

    if isPartyLeader(rec) then
        huntStep(rec, bot, t)
    else
        followLeader(rec, bot, t)
    end
end

return brain
