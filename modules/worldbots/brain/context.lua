-----------------------------------
-- Per-party AI state for Nate's bot Lua.
--
-- Nate's AI keeps one alliance per server in xi.singleplayer.bots.alliance
-- (one player and their bots). World bots need one per bot party, so every
-- party (a solo bot is a party of one) gets its own copy of that table, and
-- the right one is made current before any of Nate's code runs for one of
-- its members: the bot tick, action results, mob skills and PAI listeners
-- (the C++ module wraps world bots' listeners to call activateFor).
-- Nate's code reads bots.alliance on every call and caches no reference to
-- it, so swapping it is safe (checked: no file-level local holds it).
-----------------------------------
local bots = xi.singleplayer.bots

local context = {}

local function deepcopy(value)
    if type(value) ~= 'table' then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deepcopy(v)
    end
    return out
end

-- Nate's defaults, captured before anything changes them (the brain loads after modules/worldbots/bots).
local template = deepcopy(bots.alliance)
template.bot   = {}

-- Current when no world bot is being processed (for example a GM's test alliance).
local idle     = bots.alliance

context.byKey  = {} -- key -> alliance table
context.keyOf  = {} -- charId -> key

function context.activateFor(charId)
    local key        = context.keyOf[charId]
    bots.alliance    = (key and context.byKey[key]) or idle
    return bots.alliance
end

function context.of(charId)
    local key = context.keyOf[charId]
    return key and context.byKey[key] or nil
end

-- Remove a bot from its context; a context nobody belongs to is dropped.
function context.release(charId)
    local key = context.keyOf[charId]
    context.keyOf[charId] = nil
    if key == nil then
        return
    end
    for _, k in pairs(context.keyOf) do
        if k == key then
            return
        end
    end
    context.byKey[key] = nil
end

-- members: { { entity = bot, role = Role.X }, ... }, the first member with role Tank is the assist target,
-- else the first member. options.sc: Nate's skillchain pairs; options.battleFormation.
function context.form(key, members, options)
    options = options or {}
    for _, m in ipairs(members) do
        context.release(m.entity:getID())
    end

    local a = deepcopy(template)
    context.byKey[key] = a

    local assist = members[1].entity
    for _, m in ipairs(members) do
        if m.role == bots.Role.Tank then
            assist = m.entity
            break
        end
    end

    a.mainCharId       = members[1].entity:getID()
    a.mainEntity       = members[1].entity
    a.assistCharId     = assist:getID()
    a.headlessCharIds  = {}
    a.roleMap          = {}
    a.parties          = { { ptLeader = members[1].entity:getName(), trusts = {} } }
    a.battleFormation  = options.battleFormation or 'legacy' -- 'off' holds position in combat
    a.walkingFormation = 'off'                               -- the brain moves the party between fights
    a.aggroMode        = 'off'
    a.sc               = options.sc or {}
    a.solo             = options.solo or {}

    for _, m in ipairs(members) do
        local id = m.entity:getID()
        table.insert(a.headlessCharIds, id)
        a.roleMap[id]      = m.role
        context.keyOf[id]  = key
    end

    -- Per-bot state and roles are created inside the context they belong to.
    for _, m in ipairs(members) do
        local id = m.entity:getID()
        context.activateFor(id)
        bots.ensure_bot(id)
        bots.onSetRole(m.entity, m.role)
    end
    return a
end

function context.solo(entity, role)
    return context.form('solo:' .. entity:getID(), { { entity = entity, role = role } })
end

function context.keyFor(charId)
    return context.keyOf[charId]
end

return context
