-----------------------------------
-- FFXI-Forever world bots: the world brain's entry point.
--
-- Loads after Nate's bot Lua (modules/worldbots/bots) and wraps its hooks so
-- each world bot runs in its own party's AI context, then gives the bot its
-- own life (modules/worldbots/brain). The C++ module calls
-- xi.worldbots.onWorldTick every 2.4 s and xi.worldbots.activateFor around
-- world bots' PAI listeners.
-----------------------------------
require('modules/module_utils')

local m = Module:new('worldbots_brain')

local context = require('modules/worldbots/brain/context')
local brain   = require('modules/worldbots/brain/brain')
require('modules/worldbots/brain/economy')  -- M5: selling and shopping activities
require('modules/worldbots/brain/crafting') -- M6: gathering and crafting activities

xi.worldbots              = xi.worldbots or {}
xi.worldbots.brain        = brain
xi.worldbots.context      = context
xi.worldbots.activateFor  = context.activateFor
xi.worldbots.onWorldTick  = function()
    brain.worldTick()
end
xi.worldbots.onArrive     = function(bot, fromZone)
    brain.onArrive(bot, fromZone)
end

-- Every bot tick: make the bot's party context current, run Nate's AI, then the brain.
m:addOverride('xi.singleplayer.bots.onBotTick', function(entity, mode)
    if entity ~= nil then
        context.activateFor(entity:getID())
    end
    if super then
        super(entity, mode)
    end
    if entity ~= nil and brain.recs[entity:getID()] then
        local ok, err = pcall(brain.think, entity)
        if not ok then
            print('[worldbots] think(' .. entity:getName() .. '): ' .. tostring(err))
        end
    end
end)

-- Action results and mob skills reach Nate's handlers in the context of the world bot involved.
m:addOverride('xi.singleplayer.bots.onActionResult', function(actor, tbl)
    local id = nil
    if actor ~= nil and actor:isPC() and actor:isHeadless() then
        id = actor:getID()
    elseif tbl and tbl.targets then
        for _, target in ipairs(tbl.targets) do
            if context.keyFor(target.actorId) then
                id = target.actorId
                break
            end
        end
    end
    if id then
        context.activateFor(id)
    end
    if super then
        super(actor, tbl)
    end
end)

m:addOverride('xi.singleplayer.bots.onMobSkillStart', function(actor, castTimeMs)
    local target = actor and actor:getTarget()
    if target ~= nil then
        context.activateFor(target:getID())
    end
    if super then
        super(actor, castTimeMs)
    end
end)

return m
