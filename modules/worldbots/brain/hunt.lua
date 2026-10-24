-----------------------------------
-- Hunting: pick a monster worth experience in the current zone and hand it to
-- Nate's AI as the party's target; watch the fight and record its outcome.
-----------------------------------
local areas = require('modules/worldbots/brain/areas')

local hunt = {}

local SEARCH_RADIUS   = 80   -- yalms around the bot (or camp anchor)
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

local function claimedByOther(mobId, owner, now)
    local c = hunt.claims[mobId]
    return c ~= nil and c.owner ~= owner and now - c.at < 300
end

-- Monsters in the bot's zone that are alive, unclaimed and in the level window, nearest first.
-- owner/now: skip mobs another bot (or party) has claimed.
function hunt.candidates(bot, minLevel, maxLevel, anchor, owner, now)
    local zone = bot:getZone()
    if zone == nil then
        return {}
    end
    local ax, az = bot:getXPos(), bot:getZPos()
    if anchor then
        ax, az = anchor.x, anchor.z
    end
    local out = {}
    for _, mob in ipairs(zone:getMobs()) do
        if mob:isSpawned() and mob:isAlive() and not mob:isEngaged() and mob:getMainLvl() >= minLevel and mob:getMainLvl() <= maxLevel
           and not (owner and claimedByOther(mob:getID(), owner, now)) then
            local d2 = sq(mob:getXPos() - ax) + sq(mob:getZPos() - az)
            if d2 <= sq(SEARCH_RADIUS) and math.abs(mob:getYPos() - bot:getYPos()) < 15 then
                table.insert(out, { mob = mob, d2 = d2 })
            end
        end
    end
    table.sort(out, function(a, b) return a.d2 < b.d2 end)
    return out
end

-- How many huntable monsters a zone has for this level (whole zone), to choose a camp.
function hunt.zoneScore(zone, minLevel, maxLevel)
    if zone == nil then
        return 0
    end
    local n = 0
    for _, mob in ipairs(zone:getMobs()) do
        local lv = mob:getMainLvl()
        if lv >= minLevel and lv <= maxLevel then
            n = n + 1
        end
    end
    return n
end

-- First candidate zone with enough monsters for this level.
function hunt.chooseZone(nation, level, inParty)
    local minLv, maxLv = areas.levelWindow(level, inParty)
    local best, bestScore = nil, 0
    for _, zoneId in ipairs(areas.candidates(nation, level)) do
        local score = hunt.zoneScore(GetZone(zoneId), minLv, maxLv)
        if score >= 8 then
            return zoneId, score
        end
        if score > bestScore then
            best, bestScore = zoneId, score
        end
    end
    return best, bestScore
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
        f.engaged = true
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
    end
    return nil
end

return hunt
