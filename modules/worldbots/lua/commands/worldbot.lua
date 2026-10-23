-----------------------------------
-- func: worldbot
-- desc: FFXI-Forever world bots (M1 test controls).
--   !worldbot spawn <name>          spawn a character as an ownerless headless bot at its saved position
--   !worldbot despawn <name>        despawn it (position is saved)
--   !worldbot list                  list spawned bots
--   !worldbot fight <name> [mobId]  M1 test: make the bot its own solo party (tank) and fight your target or mobId
-----------------------------------
---@type TCommand
local commandObj = {}

commandObj.cmdprops =
{
    permission = 5,
    parameters = 'sss',
}

local function say(player, msg)
    player:printToPlayer('[worldbot] ' .. msg, xi.msg.channel.SYSTEM_3)
end

-- One ownerless bot as its own one-member alliance in Nate's state model: leader, tank and assist target.
-- (M4 replaces the single alliance with per-party state.)
local function soloAlliance(bot)
    local bots     = xi.singleplayer.bots
    local id       = bot:getID()
    bots.alliance  = bots.alliance or {}
    local alliance = bots.alliance

    alliance.mainCharId       = id
    alliance.mainEntity       = bot
    alliance.headlessCharIds  = { id }
    alliance.roleMap          = { [id] = bots.Role.Tank }
    alliance.solo             = {}
    alliance.bot              = alliance.bot or {}
    alliance.bot[id]          = alliance.bot[id] or {}
    alliance.parties          = { { ptLeader = bot:getName(), trusts = {} } }
    alliance.assistCharId     = id
    alliance.battleFormation  = 'off'
    alliance.walkingFormation = 'off'
    alliance.aggroMode        = 'off'
    bots.onSetRole(bot, bots.Role.Tank)
end

commandObj.onTrigger = function(player, verb, name, arg)
    verb = verb or ''
    if verb == 'list' then
        local list = WorldbotList()
        say(player, string.format('%d bot(s) spawned', #list))
        for _, bot in ipairs(list) do
            say(player, string.format('%s lv%d hp %d/%d zone %d', bot:getName(), bot:getMainLvl(), bot:getHP(), bot:getMaxHP(), bot:getZoneID()))
        end
        return
    end

    if name == nil or name == '' then
        say(player, 'usage: !worldbot spawn|despawn|list|fight <name> [mobId]')
        return
    end

    if verb == 'spawn' then
        local bot = WorldbotSpawn(name)
        say(player, bot ~= nil and string.format('spawned %s in zone %d', bot:getName(), bot:getZoneID()) or ('could not spawn ' .. name))
    elseif verb == 'despawn' then
        say(player, WorldbotDespawn(name) and ('despawned ' .. name) or (name .. ' is not a spawned bot'))
    elseif verb == 'fight' then
        local bot = GetPlayerByName(name)
        if bot == nil or not bot:isHeadless() then
            say(player, name .. ' is not a spawned bot')
            return
        end
        local mobId = tonumber(arg)
        if mobId == nil and player:getCursorTarget() ~= nil then
            mobId = player:getCursorTarget():getID()
        end
        if mobId == nil then
            say(player, 'no target: give a mob id or target a monster')
            return
        end
        soloAlliance(bot)
        xi.singleplayer.bots.set_alliance_target(mobId)
        say(player, string.format('%s engaging %d', bot:getName(), mobId))
    else
        say(player, 'unknown verb: ' .. verb)
    end
end

xi.module.registerCommand('worldbot', commandObj)
