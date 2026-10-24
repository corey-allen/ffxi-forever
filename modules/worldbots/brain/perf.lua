-----------------------------------
-- M7: performance wrappers around Nate's AI for many parties at once.
--
-- Nate's threat check (ai_threat.off_target_threats) scans every monster in
-- the zone, every 250 ms, for each alliance. With one alliance per server that
-- was cheap; with a party per bot it was 80% of all bot CPU at 1 000 bots
-- (profiled: 0.73 ms of a 0.90 ms tick). Here the zone is scanned once per
-- 250 ms for engaged monsters and every party filters that list for its own
-- members, with the same result as Nate's function. Wrapped once; his file is
-- unchanged.
-----------------------------------
local bots = xi.singleplayer.bots

local perf = {}

local zoneEngaged = {} -- zoneId -> { at = ms, list = { { mob, victim, victimId } } }

local function engagedIn(zone, nowMs)
    local key = zone:getID()
    local s   = zoneEngaged[key]
    if s and nowMs - s.at < 250 then
        return s.list
    end
    local list = {}
    for _, mob in ipairs(zone:getMobs() or {}) do
        if mob:isEngaged() and not mob:isDead() then
            local victim = mob:getTarget()
            if victim ~= nil then
                table.insert(list, { mob = mob, victim = victim, victimId = victim:getID() })
            end
        end
    end
    zoneEngaged[key] = { at = nowMs, list = list }
    return list
end

if bots.threat and bots.threat.off_target_threats and not bots.threat.nateOffTargetThreats then
    bots.threat.nateOffTargetThreats = bots.threat.off_target_threats
    bots.threat.off_target_threats   = function(bot)
        local A   = bots.alliance
        local now = bots.ai_util.get_ms_since_epoch()
        if A and A._offThreats and (now - (A._offThreatsMs or 0)) < 250 then
            return A._offThreats
        end
        local targetId = bots.get_alliance_target_id and bots.get_alliance_target_id() or 0
        local allies   = {}
        for _, member in ipairs(bot:getAlliance() or {}) do
            allies[member:getID()] = true
        end
        local out  = {}
        local zone = bot.getZone and bot:getZone()
        if zone then
            for _, e in ipairs(engagedIn(zone, now)) do
                if allies[e.victimId] and e.mob:getID() ~= targetId and not e.mob:isDead() and not bots.ai_util.is_asleep(e.mob) then
                    table.insert(out, { mob = e.mob, victim = e.victim, victimTier = bots.threat.member_tier(e.victim) })
                end
            end
        end
        if A ~= nil then
            A._offThreats   = out
            A._offThreatsMs = now
        end
        return out
    end
end

return perf
