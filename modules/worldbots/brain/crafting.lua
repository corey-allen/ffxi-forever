-----------------------------------
-- M6: gathering and crafting, the way a 2006 player started a craft.
--
--   signet  Ask a gate guard of the bot's nation for Signet (talk, then pick the
--           Signet option in the guard's menu: event option 1). Monsters in the
--           starter regions drop crystals only to players with Signet.
--   gather  Take the nation's HELM tool (bought from a vendor on a shopping
--           trip) to the nearby gathering points and trade it to them; the
--           point's own script decides the item and whether the tool breaks.
--   craft   Synthesize a recipe of the nation's craft when the crystal and
--           materials are in the bags (the 0x096 synthesis packet); the
--           server's synthesis code rolls success, HQ and skill-ups.
--
-- Recipes and HELM tables are the server's (synth_recipes, helm/data.lua).
-----------------------------------
local travel = require('modules/worldbots/brain/travel')

local crafting = { activities = {} }

local CRYSTAL = { FIRE = 4096, ICE = 4097, WIND = 4098, EARTH = 4099, LIGHTNING = 4100, WATER = 4101, LIGHT = 4102, DARK = 4103 }

-- Each nation's starting craft: tool, gathering zone and point, recipes (from synth_recipes; lowest level first).
local PLAN =
{
    [xi.nation.SANDORIA] =
    {
        craft = 'woodworking', skill = xi.skill.WOODWORKING,
        tool = xi.item.HATCHET, zone = xi.zone.EAST_RONFAURE, point = 'Logging_Point',
        recipes =
        {
            { name = 'Arrowwood Lumber', level = 2, result = 705, crystal = CRYSTAL.WIND, items = { 688 } },
            { name = 'Maple Lumber',     level = 5, result = 708, crystal = CRYSTAL.WIND, items = { 691 } },
            { name = 'Ash Lumber',       level = 8, result = 715, crystal = CRYSTAL.WIND, items = { 698 } },
        },
    },
    [xi.nation.BASTOK] =
    {
        craft = 'smithing', skill = xi.skill.SMITHING,
        tool = xi.item.PICKAXE, zone = xi.zone.ZERUHN_MINES, point = 'Mining_Point',
        recipes =
        {
            { name = 'Bronze Ingot', level = 2, result = 649, crystal = CRYSTAL.FIRE, items = { 640, 640, 640, 641 } },
            { name = 'Bronze Sheet', level = 4, result = 660, crystal = CRYSTAL.FIRE, items = { 649 } },
        },
    },
    [xi.nation.WINDURST] =
    {
        craft = 'clothcraft', skill = xi.skill.CLOTHCRAFT,
        tool = xi.item.SICKLE, zone = xi.zone.WEST_SARUTABARUTA, point = 'Harvesting_Point',
        recipes =
        {
            { name = 'Grass Thread', level = 3, result = 817, crystal = CRYSTAL.LIGHTNING, items = { 833, 833 } },
            { name = 'Grass Cloth',  level = 4, result = 824, crystal = CRYSTAL.EARTH,     items = { 817, 817, 817 } },
        },
    },
}
crafting.PLAN = PLAN

-- Gate guards that give each nation's Signet in its home city (the conquest overseer script, option 1).
local GUARDS =
{
    [xi.nation.SANDORIA] = { zone = xi.zone.SOUTHERN_SAN_DORIA, names = { 'Arpevion_TK', 'Aravoge_TK' } },
    [xi.nation.BASTOK]   = { zone = xi.zone.BASTOK_MINES,       names = { 'Crying_Wind_IM' } },
    [xi.nation.WINDURST] = { zone = xi.zone.WINDURST_WOODS,     names = { 'Harara_WW' } },
}

local GATHER_TRIES   = 12   -- trades per gathering trip (tools break; points move)
local GATHER_EVERY   = 1800 -- seconds of play between gathering trips
local MAX_SYNTHS     = 12   -- per crafting session
local TRIP_MAX       = 900

-- Craft skill in tenths (the server keeps crafts to 0.1); getSkillLevel only has whole levels.
function crafting.skill(bot, skillId)
    if bot.worldbotSkillTenths then
        return bot:worldbotSkillTenths(skillId)
    end
    return bot:getSkillLevel(skillId) * 10
end

local function planFor(rec)
    return PLAN[rec.row.nation]
end

local function countItem(bot, itemId)
    local n, slot = 0, nil
    for _, item in ipairs(bot:worldbotInventory()) do
        if item.itemId == itemId then
            n    = n + item.quantity
            slot = slot or item.slot
        end
    end
    return n, slot
end

-- Items the economy must not sell for this bot: its craft's tool, crystals and materials.
function crafting.keepFor(rec, itemId)
    local plan = rec and PLAN[rec.row.nation]
    if plan == nil then
        return false
    end
    if itemId == plan.tool then
        return true
    end
    for _, r in ipairs(plan.recipes) do
        if itemId == r.crystal then
            return true
        end
        for _, id in ipairs(r.items) do
            if id == itemId then
                return true
            end
        end
    end
    return false
end

-- Any nation's craft material (for reports and tools that have no bot at hand).
function crafting.keep(itemId)
    for nation in pairs(PLAN) do
        if crafting.keepFor({ row = { nation = nation } }, itemId) then
            return true
        end
    end
    return false
end

-- Shopping: the HELM tool, when the bot has none (economy.want asks this first).
function crafting.want(rec, bot, itemId)
    local plan = planFor(rec)
    if plan and itemId == plan.tool and bot:getMainLvl() >= 3 and countItem(bot, plan.tool) == 0 then
        return { priority = 2, kind = 'tool' }
    end
    return nil
end

local function hasSignet(bot)
    return bot:hasStatusEffect(xi.effect.SIGNET)
end

-- NPC trades and talks are accepted within 6 yalms; gathering points often sit against rock or trees
-- the navmesh can't reach, so 5 yalms (3D) counts as there.
local function walkToNpc(rec, bot, npc, t)
    local d = travel.dist(bot, npc:getXPos(), npc:getYPos(), npc:getZPos())
    if d <= 5.0 then
        return 'arrived'
    end
    return travel.walkTo(bot, rec.mem, npc:getXPos(), npc:getYPos(), npc:getZPos(), 2.5, t)
end

-----------------------------------
-- signet
-----------------------------------
local signet = {}
crafting.activities.signet = signet

function signet.choose(rec, bot, t)
    local g = GUARDS[rec.row.nation]
    -- When passing through the home city (after login, a home point or a shopping trip).
    if g == nil or hasSignet(bot) or bot:getZoneID() ~= g.zone or t < (rec.mem.nextSignet or 0) then
        return false
    end
    rec.mem.nextSignet = t + 600
    rec.mem.signet     = { startAt = t }
    return true
end

function signet.step(rec, bot, t)
    local g = GUARDS[rec.row.nation]
    if hasSignet(bot) or t - rec.mem.signet.startAt > 300 or bot:getZoneID() ~= g.zone then
        xi.worldbots.brain.log(rec, 'signet', hasSignet(bot) and 'received Signet' or 'no Signet this time')
        rec.mem.signet = nil
        return 'done'
    end
    if bot:worldbotInEvent() then
        bot:worldbotEndEvent(1) -- the guard's menu: Signet
        return 'running'
    end
    local zone, guard = bot:getZone(), nil
    for _, name in ipairs(g.names) do
        guard = guard or zone:queryEntitiesByName(name)[1]
    end
    if guard == nil then
        rec.mem.signet.startAt = -1000 -- give up
        return 'running'
    end
    if walkToNpc(rec, bot, guard, t) == 'arrived' then
        bot:worldbotTalk(guard)
    end
    return 'running'
end

-----------------------------------
-- gather
-----------------------------------
local gather = {}
crafting.activities.gather = gather

function gather.choose(rec, bot, t)
    local plan = planFor(rec)
    if plan == nil or rec.mem.party or bot:getMainLvl() < 3 then
        return false
    end
    local s = rec.state
    if countItem(bot, plan.tool) == 0 or bot:getFreeSlotsCount() < 6 or t < (s.nextGather or 0) then
        return false
    end
    s.nextGather   = t + GATHER_EVERY
    rec.mem.gather = { startAt = t, tries = 0, got = 0, toolsStart = countItem(bot, plan.tool) }
    return true
end

local function gatherDone(rec, bot, t, why)
    local g, plan = rec.mem.gather, planFor(rec)
    xi.worldbots.brain.log(rec, 'gather', string.format('%s: %d trades, %d items, tools %d -> %d, %ds',
        why, g.tries, g.got, g.toolsStart, countItem(bot, plan.tool), t - g.startAt))
    rec.mem.gather = nil
    return 'done'
end

function gather.step(rec, bot, t)
    local g, plan = rec.mem.gather, planFor(rec)
    if bot:worldbotInEvent() then
        bot:worldbotEndEvent(0) -- the gathering cutscene
        return 'running'
    end
    if t - g.startAt > TRIP_MAX then
        return gatherDone(rec, bot, t, 'out of time')
    end
    if g.tries >= GATHER_TRIES or bot:getFreeSlotsCount() == 0 then
        return gatherDone(rec, bot, t, 'done')
    end
    local tools, toolSlot = countItem(bot, plan.tool)
    if tools == 0 then
        return gatherDone(rec, bot, t, 'tool broke')
    end
    if bot:getZoneID() ~= plan.zone then
        local r = travel.toZone(bot, rec.mem, plan.zone, t)
        if r == 'noroute' or r == 'giveup' then
            return gatherDone(rec, bot, t, 'cannot reach the gathering zone')
        end
        return 'running'
    end
    -- Nearest gathering point the bot has not failed to reach.
    g.unreachable = g.unreachable or {}
    local best, bestD = nil, math.huge
    for _, npc in ipairs(bot:getZone():queryEntitiesByName(plan.point)) do
        if npc:isSpawned() and t >= (g.unreachable[npc:getID()] or 0) then
            local d = travel.dist(bot, npc:getXPos(), npc:getYPos(), npc:getZPos())
            if d < bestD then
                best, bestD = npc, d
            end
        end
    end
    if best == nil then
        return gatherDone(rec, bot, t, 'no gathering point')
    end
    local walk = walkToNpc(rec, bot, best, t)
    if walk == 'giveup' then
        g.unreachable[best:getID()] = t + 600
        return 'running'
    end
    if walk ~= 'arrived' then
        return 'running'
    end
    if t < (g.nextTrade or 0) then
        return 'running'
    end
    local free = bot:getFreeSlotsCount()
    if bot:worldbotTrade(best, { { slot = toolSlot, quantity = 1 } }) then
        g.tries     = g.tries + 1
        g.nextTrade = t + 4 -- the server enforces 3 s between attempts
        if bot:getFreeSlotsCount() < free then
            g.got = g.got + 1
        end
    end
    return 'running'
end

-----------------------------------
-- craft
-----------------------------------
local craft = {}
crafting.activities.craft = craft

-- The best recipe the bot can make now: materials in the bags, level close to its skill.
local function pickRecipe(rec, bot)
    local plan = planFor(rec)
    if plan == nil then
        return nil
    end
    local skill = crafting.skill(bot, plan.skill) / 10
    local best  = nil
    for _, r in ipairs(plan.recipes) do
        if r.level <= skill + 10 then
            local need = { [r.crystal] = 1 }
            for _, id in ipairs(r.items) do
                need[id] = (need[id] or 0) + 1
            end
            local ok = true
            for id, n in pairs(need) do
                ok = ok and countItem(bot, id) >= n
            end
            -- As players did: the recipe closest above the current skill (skill-ups come from recipes
            -- a little above it); below the skill only when nothing above it can be made.
            local function rank(x)
                return x.level >= skill and (x.level - skill) or (100 + skill - x.level)
            end
            if ok and (best == nil or rank(r) < rank(best)) then
                best = r
            end
        end
    end
    return best
end

function craft.choose(rec, bot, t)
    if rec.mem.party or t < (rec.mem.nextCraftCheck or 0) then
        return false
    end
    rec.mem.nextCraftCheck = t + 300
    if pickRecipe(rec, bot) == nil then
        return false
    end
    rec.mem.craft = { startAt = t, synths = 0, made = 0, skillStart = crafting.skill(bot, planFor(rec).skill) }
    return true
end

local function craftDone(rec, bot, t, why)
    local c, plan = rec.mem.craft, planFor(rec)
    xi.worldbots.brain.log(rec, 'craft', string.format('%s: %d syntheses, %d made, %s skill %.1f -> %.1f, %ds',
        why, c.synths, c.made, plan.craft, c.skillStart / 10, crafting.skill(bot, plan.skill) / 10, t - c.startAt))
    rec.mem.craft = nil
    return 'done'
end

function craft.step(rec, bot, t)
    local c = rec.mem.craft
    if bot:worldbotIsCrafting() then
        return 'running'
    end
    if bot:worldbotInEvent() then
        bot:worldbotEndEvent(0)
        return 'running'
    end
    if c.pending then
        -- The last synthesis finished: record the outcome (result item count) and the skill.
        local p    = c.pending
        local made = countItem(bot, p.result) - p.resultBefore
        if made > 0 then
            c.made = c.made + 1
        end
        xi.worldbots.brain.log(rec, 'synth', string.format('%s: %s; %s skill %.1f -> %.1f', p.name, made > 0 and ('made ' .. made) or 'failed',
            planFor(rec).craft, p.skill / 10, crafting.skill(bot, planFor(rec).skill) / 10))
        c.pending = nil
    end
    if c.synths >= MAX_SYNTHS or t - c.startAt > TRIP_MAX then
        return craftDone(rec, bot, t, 'session over')
    end
    local r = pickRecipe(rec, bot)
    if r == nil then
        return craftDone(rec, bot, t, 'out of materials')
    end
    local _, crystalSlot = countItem(bot, r.crystal)
    local used, ingredients = {}, {}
    for _, id in ipairs(r.items) do
        -- Each ingredient slot can supply as many as its stack holds; the packet lists one entry per item.
        for _, item in ipairs(bot:worldbotInventory()) do
            if item.itemId == id and (used[item.slot] or 0) < item.quantity then
                used[item.slot] = (used[item.slot] or 0) + 1
                table.insert(ingredients, { itemId = id, slot = item.slot })
                break
            end
        end
    end
    if bot:worldbotSynth(r.crystal, crystalSlot, ingredients) then
        c.synths  = c.synths + 1
        c.pending = { name = r.name, result = r.result, resultBefore = countItem(bot, r.result), skill = crafting.skill(bot, planFor(rec).skill) }
    else
        return craftDone(rec, bot, t, 'synthesis refused')
    end
    return 'running'
end

return crafting
