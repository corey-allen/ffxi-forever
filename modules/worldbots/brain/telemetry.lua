-----------------------------------
-- Combat telemetry from the server's own action results (the packet each
-- action sends to clients, handed to Lua by the C++ module): cures, nukes and
-- weapon skills per bot, and every skillchain a bot closes. Counts go on the
-- bot's next fight record; skillchains get a log line of their own.
-----------------------------------
local bots = xi.singleplayer.bots

local telemetry = {}

local CATEGORY_SKILL_FINISH = 3 -- weapon skills
local CATEGORY_MAGIC_FINISH = 4

local CURES = {}
for id = 1, 11 do
    CURES[id] = true -- Cure I-VI, Curaga I-V
end

local SKILLCHAIN = { 'Light', 'Darkness', 'Gravitation', 'Fragmentation', 'Distortion', 'Fusion', 'Compression', 'Liquefaction',
                     'Induration', 'Reverberation', 'Transfixion', 'Scission', 'Detonation', 'Impaction', 'Radiance', 'Umbra' }

local function counters(rec)
    rec.mem.combat = rec.mem.combat or { cures = 0, cured = 0, nukes = 0, nukeDmg = 0, ws = 0 }
    return rec.mem.combat
end

-- Summary for the fight record, then reset.
function telemetry.take(rec)
    local c = rec.mem.combat
    rec.mem.combat = nil
    if c == nil then
        return ''
    end
    local parts = {}
    if c.cures > 0 then
        table.insert(parts, string.format('%d cures (+%d hp)', c.cures, c.cured))
    end
    if c.nukes > 0 then
        table.insert(parts, string.format('%d nukes (%d dmg)', c.nukes, c.nukeDmg))
    end
    if c.ws > 0 then
        table.insert(parts, string.format('%d weapon skills', c.ws))
    end
    return #parts > 0 and ('; ' .. table.concat(parts, ', ')) or ''
end

function telemetry.onAction(actor, tbl)
    local brain = xi.worldbots and xi.worldbots.brain
    if brain == nil or actor == nil or tbl == nil then
        return
    end
    local rec = brain.recs[tbl.actorId]
    if rec == nil then
        return
    end
    if tbl.actiontype == CATEGORY_MAGIC_FINISH then
        local c = counters(rec)
        for _, target in ipairs(tbl.targets or {}) do
            for _, r in ipairs(target.results or {}) do
                if CURES[tbl.actionid] then
                    c.cures, c.cured = c.cures + 1, c.cured + (r.param or 0)
                elseif brain.recs[target.actorId] == nil then -- a spell on a monster
                    c.nukes, c.nukeDmg = c.nukes + 1, c.nukeDmg + (r.param or 0)
                end
            end
        end
    elseif tbl.actiontype == CATEGORY_SKILL_FINISH then
        local c = counters(rec)
        c.ws = c.ws + 1
        for _, target in ipairs(tbl.targets or {}) do
            for _, r in ipairs(target.results or {}) do
                local m  = r.addEffectMessage or 0
                local sc = (m >= 288 and m <= 303) and (m - 287) or ((m >= 385 and m <= 400) and (m - 384) or nil)
                if sc then
                    local ws = GetWeaponskillNameByID and GetWeaponskillNameByID(tbl.actionid) or tostring(tbl.actionid)
                    brain.log(rec, 'skillchain', string.format('closed %s with %s for %d damage on %s', SKILLCHAIN[sc] or tostring(sc), tostring(ws),
                        r.addEffectParam or 0, tostring(target.actorId)))
                    rec.state.skillchains = (rec.state.skillchains or 0) + 1
                end
            end
        end
    end
end

-- Wrapped once around Nate's handler chain; looks the brain up on every call (hot reload safe).
if not bots.worldbotsTelemetryWrapped then
    bots.worldbotsTelemetryWrapped = true
    local nate = bots.onActionResult
    bots.onActionResult = function(actor, tbl)
        if nate then
            nate(actor, tbl)
        end
        local t = xi.worldbots and xi.worldbots.telemetry
        if t then
            local ok, err = pcall(t.onAction, actor, tbl)
            if not ok then
                print('[worldbots] telemetry: ' .. tostring(err))
            end
        end
    end
end

xi.worldbots           = xi.worldbots or {}
xi.worldbots.telemetry = telemetry

return telemetry
