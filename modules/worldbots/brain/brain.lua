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
    local best = {} -- equip slot -> { id, req }
    for _, item in ipairs(bot:worldbotInventory()) do
        local info = WorldbotItemInfo(item.itemId)
        if info and info.equipment and bot:canEquipItem(item.itemId, true) then
            local key = info.slots
            if best[key] == nil or info.reqLvl > best[key].req then
                best[key] = { id = item.itemId, req = info.reqLvl }
            end
        end
    end
    local equipped = {}
    for _, e in pairs(best) do
        bot:equipItem(e.id)
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
    context.solo(bot, roleFor(rec, false))
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
    if rec.mem.party then
        brain.refreshParty(rec.mem.party)
    else
        bot:worldbotSetParent(rec.charId)
        context.solo(bot, roleFor(rec, false))
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

-----------------------------------
-- Parties (M4): bots of one nation at similar levels team up, as 2006 players did from level 10.
-----------------------------------
local function partyCandidates()
    local byNation = {}
    for _, rec in ipairs(brain.list) do
        local bot = rec.online and WorldbotGet(rec.charId) or nil
        if bot and not rec.mem.party and not rec.mem.fight and not bot:isDead() and not bot:worldbotIsZoning()
           and bot:getMainLvl() >= config.PARTY_MIN_LEVEL and not rec.mem.activity then
            byNation[rec.row.nation] = byNation[rec.row.nation] or {}
            table.insert(byNation[rec.row.nation], { rec = rec, bot = bot })
        end
    end
    return byNation
end

-- Skillchain pairs Nate's AI can run: open with the first, close with the second (both level-1 weapon skills).
local SC_PAIRS =
{
    { open = xi.job.MNK, openWS = 'Combo', close = xi.job.WAR, closeWS = 'Raging Axe' },     -- Impaction > Detonation
    { open = xi.job.THF, openWS = 'Wasp Sting', close = xi.job.WAR, closeWS = 'Raging Axe' }, -- Scission > Detonation
}

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
    local byJob   = {}
    for i, m in ipairs(group) do
        if i > 1 then
            leader.bot:partyAddMember(m.bot)
        end
        table.insert(members, { entity = m.bot, role = PARTY_ROLE[m.rec.row.job] or Role.Melee })
        byJob[m.rec.row.job] = m.bot
        m.rec.mem.party = key
        m.rec.mem.fight = nil
        m.bot:worldbotSetParent(leader.rec.charId)
    end
    local sc = {}
    for i, p in ipairs(SC_PAIRS) do
        if byJob[p.open] and byJob[p.close] then
            table.insert(sc, { priority = i, openName = byJob[p.open]:getName(), openWS = p.openWS, closeName = byJob[p.close]:getName(), closeWS = p.closeWS })
            break -- one pair at a time; Nate's AI rotates pairs it is given
        end
    end
    context.form(key, members, { sc = sc })
    local names = {}
    for _, m in ipairs(group) do
        table.insert(names, string.format('%s(%d)', m.bot:getName(), m.bot:getMainLvl()))
    end
    for _, m in ipairs(group) do
        log(m.rec, 'party', string.format('joined %s led by %s: %s; skillchain pairs %d', key, leader.bot:getName(), table.concat(names, ' '), #sc))
    end
end

-- Rebuild a party's context from its members' current entities (after one of them zoned).
function brain.refreshParty(key)
    local members, leaderId = {}, tonumber(key:match('%d+'))
    local sc = context.byKey[key] and context.byKey[key].sc or {}
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
            end
        end
    end
    if #members > 0 then
        context.form(key, members, { sc = sc })
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
                context.solo(bot, roleFor(other, false))
            end
            log(other, 'party', 'left ' .. key .. ': ' .. reason)
        end
    end
end

function brain.updateParties()
    for _, group in pairs(partyCandidates()) do
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
    local t      = os.date('*t')
    local logins = 0
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
            brain.logout(rec, 'schedule')
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
    log(rec, 'fight', string.format('%s %s (lv%d, id %d) in %ds; exp %+d; hp %d/%d; zone %d',
        result, f.mobName, f.mobLevel, f.mobId, t - f.startAt, expGain, bot:getHP(), bot:getMaxHP(), bot:getZoneID()))
    if result ~= 'won' then
        rec.mem.skip = rec.mem.skip or {}
        rec.mem.skip[f.mobId] = t + 120
        bots.set_alliance_target(0)
    end
end

-- Hand a monster to the AI: walk close, set the party target, engage.
local function fightStep(rec, bot, t)
    local f   = rec.mem.fight
    local mob = GetMobByID(f.mobId)
    if mob == nil then
        return
    end
    if bot:isEngaged() then
        return -- Nate's AI fights; legacy battle formation chases the target
    end
    local d = travel.dist(bot, mob:getXPos(), mob:getYPos(), mob:getZPos())
    if d > 6 then
        travel.walkTo(bot, rec.mem, mob:getXPos(), mob:getYPos(), mob:getZPos(), 5, t)
        return
    end
    bots.set_alliance_target(f.mobId)
    if MELEE_JOB[rec.row.job] or bot:getMainJob() == xi.job.RDM or bot:getMainLvl() < 10 or not mob:isEngaged() then
        bot:engage(mob:getTargID())
    end
end

local function chooseCamp(rec, bot)
    local s       = rec.state
    local level   = bot:getMainLvl()
    local zone, n = hunt.chooseZone(rec.row.nation, level, rec.mem.party ~= nil)
    if zone ~= s.campZone then
        log(rec, 'goal', string.format('camp for lv%d: zone %s (%d monsters in range)', level, tostring(zone), n or 0))
    end
    s.campZone  = zone
    s.campLevel = level
end

local function huntStep(rec, bot, t)
    local s     = rec.state
    local level = bot:getMainLvl()
    if s.campZone == nil or s.campLevel == nil or math.abs(level - s.campLevel) >= 3 then
        chooseCamp(rec, bot)
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
    local minLv, maxLv = areas.levelWindow(level, rec.mem.party ~= nil)
    for _, c in ipairs(hunt.candidates(bot, minLv, maxLv, nil, claimOwner(rec), t)) do
        local skipUntil = rec.mem.skip and rec.mem.skip[c.mob:getID()]
        if skipUntil == nil or t >= skipUntil then
            hunt.start(rec.mem, bot, c.mob, t)
            hunt.claim(c.mob:getID(), claimOwner(rec), t)
            log(rec, 'target', string.format('%s (lv%d, id %d) at %.0f yalms', c.mob:getName(), c.mob:getMainLvl(), c.mob:getID(), math.sqrt(c.d2)))
            return
        end
    end
    -- Nothing here: wander toward the zone's other side to find spawns.
    if rec.mem.wander == nil or t > rec.mem.wander.untilT then
        local a = math.random() * math.pi * 2
        rec.mem.wander = { x = bot:getXPos() + math.cos(a) * 60, y = bot:getYPos(), z = bot:getZPos() + math.sin(a) * 60, untilT = t + 40 }
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

function brain.think(bot)
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
            if bot:isBotResting() then
                bot:stopBotResting()
            end
            fightStep(rec, bot, t)
            return
        end
    end

    -- Rest between fights.
    if bot:isBotResting() then
        if rested(bot) then
            bot:stopBotResting()
            log(rec, 'rest', string.format('rested to hp %d/%d mp %d/%d', bot:getHP(), bot:getMaxHP(), bot:getMP(), bot:getMaxMP()))
        end
        return
    end
    if needsRest(bot) and not bot:isEngaged() then
        bot:startBotResting()
        return
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
        for name, act in pairs(brain.activities) do
            if act.choose(rec, bot, t) then
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
