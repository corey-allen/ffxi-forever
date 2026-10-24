-----------------------------------
-- Hunting: pick a monster worth experience in the current zone and hand it to
-- Nate's AI as the party's target; watch the fight and record its outcome.
-----------------------------------
local areas = require('modules/worldbots/brain/areas')

local hunt = {}

local SEARCH_RADIUS   = 120  -- yalms around the bot (or camp anchor)
local ENGAGE_TIMEOUT  = 45   -- seconds to reach and engage a chosen mob before dropping it
local FIGHT_TIMEOUT   = 240  -- seconds before a fight that makes no progress is abandoned

local function sq(x)
    return x * x
end

-- Mobs another bot party is already going for: mobId -> { owner = party or bot key, at = time }.
hunt.claims = {}

function hunt.claim(mobId, owner, now)
    hunt.claims[mobId] = { owner = owner, at = now }
end

function hunt.release(mobId, owner)
    local c = hunt.claims[mobId]
    if c and c.owner == owner then
        hunt.claims[mobId] = nil
    end
end

-- One scan of a zone's monsters every 2 s, shared by every bot hunting there (M7: with dozens of bots per
-- zone, each scanning hundreds of monsters on every pick was the largest per-tick cost).
local snapshots = {}

function hunt.snapshot(zone)
    local id = zone:getID()
    local s  = snapshots[id]
    local t  = os.clock()
    if s and t - s.at < 2.0 then
        return s
    end
    s = { at = t, mobs = {} }
    for _, mob in ipairs(zone:getMobs()) do
        if mob:isSpawned() and mob:isAlive() then
            table.insert(s.mobs, { mob = mob, id = mob:getID(), lvl = mob:getMainLvl(), x = mob:getXPos(), y = mob:getYPos(), z = mob:getZPos(),
                                   aggressive = mob:worldbotIsAggressive() })
        end
    end
    snapshots[id] = s
    return s
end

local function claimedByOther(mobId, owner, now)
    local c = hunt.claims[mobId]
    return c ~= nil and c.owner ~= owner and now - c.at < 300
end

-- Aggressive monsters too strong for the bot (above maxLevel + 1): { { x, z }, ... } to keep away from.
function hunt.dangers(bot, maxLevel)
    local out  = {}
    local zone = bot:getZone()
    if zone == nil then
        return out
    end
    for _, m in ipairs(hunt.snapshot(zone).mobs) do
        if m.aggressive and m.lvl > maxLevel + 1 then
            table.insert(out, { x = m.x, z = m.z })
        end
    end
    return out
end

local DANGER_RADIUS = 22 -- yalms: beyond sight and hearing range of starter-zone monsters

function hunt.isSafe(dangers, x, z)
    for _, d in ipairs(dangers) do
        if sq(d.x - x) + sq(d.z - z) < sq(DANGER_RADIUS) then
            return false
        end
    end
    return true
end

-- Monsters in the bot's zone that are alive, unclaimed and in the level window, nearest first.
-- owner/now: skip mobs another bot (or party) has claimed.
function hunt.candidates(bot, minLevel, maxLevel, anchor, owner, now, radius)
    radius = radius or SEARCH_RADIUS
    local zone = bot:getZone()
    if zone == nil then
        return {}
    end
    local ax, az = bot:getXPos(), bot:getZPos()
    if anchor then
        ax, az = anchor.x, anchor.z
    end
    local out     = {}
    local dangers = hunt.dangers(bot, maxLevel)
    local by      = bot:getYPos()
    for _, m in ipairs(hunt.snapshot(zone).mobs) do
        if m.lvl >= minLevel and m.lvl <= maxLevel and not (owner and claimedByOther(m.id, owner, now)) then
            local d2 = sq(m.x - ax) + sq(m.z - az)
            if d2 <= sq(radius) and math.abs(m.y - by) < 15 and hunt.isSafe(dangers, m.x, m.z)
               and m.mob:isAlive() and not m.mob:isEngaged() then -- live checks only for the few nearby
                table.insert(out, { mob = m.mob, d2 = d2 })
            end
        end
    end
    table.sort(out, function(a, b) return a.d2 < b.d2 end)
    return out
end

-- The nearest monster in the level window anywhere in the zone (no radius), away from dangers: where to go
-- when nothing is close. Returns { x, y, z } or nil.
function hunt.nearestAnywhere(bot, minLevel, maxLevel)
    local zone = bot:getZone()
    if zone == nil then
        return nil
    end
    local dangers = hunt.dangers(bot, maxLevel)
    local bx, bz  = bot:getXPos(), bot:getZPos()
    local best, bestD2 = nil, math.huge
    for _, m in ipairs(hunt.snapshot(zone).mobs) do
        if m.lvl >= minLevel and m.lvl <= maxLevel and hunt.isSafe(dangers, m.x, m.z) then
            local d2 = sq(m.x - bx) + sq(m.z - bz)
            if d2 < bestD2 then
                best, bestD2 = { x = m.x, y = m.y, z = m.z }, d2
            end
        end
    end
    return best
end

-- The exp camp in a zone: the 40-yalm cell with the most monsters in the level window (away from dangers),
-- as players camped where the right monsters were densest. Returns { x, y, z, count } or nil.
function hunt.campSpot(bot, minLevel, maxLevel)
    local zone = bot:getZone()
    if zone == nil then
        return nil
    end
    local dangers = hunt.dangers(bot, maxLevel)
    local cells   = {}
    local best    = nil
    for _, m in ipairs(hunt.snapshot(zone).mobs) do
        if m.lvl >= minLevel and m.lvl <= maxLevel and hunt.isSafe(dangers, m.x, m.z) then
            local key = math.floor(m.x / 40) .. ':' .. math.floor(m.z / 40)
            local c   = cells[key] or { n = 0, x = 0, y = 0, z = 0 }
            c.n, c.x, c.y, c.z = c.n + 1, c.x + m.x, c.y + m.y, c.z + m.z
            cells[key] = c
            if best == nil or c.n > best.n then
                best = c
            end
        end
    end
    if best == nil then
        return nil
    end
    return { x = best.x / best.n, y = best.y / best.n, z = best.z / best.n, count = best.n }
end

-- How many huntable monsters a zone has for this level (whole zone), to choose a camp.
function hunt.zoneScore(zone, minLevel, maxLevel)
    if zone == nil then
        return 0
    end
    local n = 0
    for _, m in ipairs(hunt.snapshot(zone).mobs) do
        if m.lvl >= minLevel and m.lvl <= maxLevel then
            n = n + 1
        end
    end
    return n
end

-- First candidate zone with enough monsters for this level.
function hunt.chooseZone(nation, level, inParty, exclude)
    local minLv, maxLv = areas.levelWindow(level, inParty)
    local function best(candidates)
        local zone, score = nil, 0
        for _, zoneId in ipairs(candidates) do
            local n = (exclude and exclude[zoneId]) and -1 or hunt.zoneScore(GetZone(zoneId), minLv, maxLv)
            if n >= 8 then
                return zoneId, n
            end
            if n > score then
                zone, score = zoneId, n
            end
        end
        return zone, score
    end
    -- Parties hunt only in exp-camp zones; solo bots in the zones for their level.
    if inParty then
        return best(areas.campZones(level))
    end
    return best(areas.candidates(nation, level))
end

-- Begin a fight record: called when the brain hands a mob to the AI.
function hunt.start(mem, bot, mob, now)
    mem.fight =
    {
        mobId    = mob:getID(),
        mobName  = mob:getName(),
        mobLevel = mob:getMainLvl(),
        startAt  = now,
        engaged  = false,
        expStart = bot:getCurrentJobExp(),
        lvStart  = bot:getMainLvl(),
        hpStart  = bot:getHP(),
    }
end

-- Follow the fight. Returns nil while it runs, else 'won', 'lost', 'fled', 'timeout' or 'unreached'.
function hunt.check(mem, bot, now)
    local f = mem.fight
    if f == nil then
        return nil
    end
    local mob = GetMobByID(f.mobId)
    if bot:isDead() then
        return 'lost'
    end
    if bot:isEngaged() or (mob and mob:isEngaged() and mob:getTarget() and mob:getTarget():getID() == bot:getID()) then
        f.engaged    = true
        f.lastActive = now
    end
    if mob == nil or not mob:isAlive() then
        if not f.engaged then
            return 'unreached'
        end
        -- Experience and drops arrive a moment after the death: settle before closing the record.
        f.deadAt = f.deadAt or now
        return (now - f.deadAt >= 3) and 'won' or nil
    end
    if not f.engaged then
        if now - f.startAt > ENGAGE_TIMEOUT then
            return 'unreached'
        end
        if mob:isEngaged() and mob:getTarget() and mob:getTarget():getID() ~= bot:getID() then
            return 'unreached' -- someone else took it
        end
    elseif now - f.startAt > FIGHT_TIMEOUT then
        return 'timeout'
    elseif now - (f.lastActive or f.startAt) > 20 then
        return 'disengaged' -- neither the bot nor the monster has been fighting the other for a while
    end
    return nil
end

return hunt
