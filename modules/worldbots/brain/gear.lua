-----------------------------------
-- Gear choices shared by equipping (brain.equipBest) and shopping (economy.want).
-- Each job fights with its usual weapon type, as 2006 players did; better gear
-- is a higher level requirement, then more damage (weapons) or defense.
-----------------------------------
local gear = {}

local S = xi.skill

-- Weapon skills each job prefers, best first.
local WEAPON_PREF =
{
    [xi.job.WAR] = { S.AXE, S.GREAT_AXE, S.SWORD },
    [xi.job.MNK] = { S.HAND_TO_HAND },
    [xi.job.THF] = { S.DAGGER, S.SWORD },
    [xi.job.WHM] = { S.CLUB, S.STAFF },
    [xi.job.BLM] = { S.STAFF, S.CLUB },
    [xi.job.RDM] = { S.SWORD, S.DAGGER },
}

local function lowestSlot(mask)
    for slot = 0, 15 do
        if bit.band(mask, bit.lshift(1, slot)) ~= 0 then
            return slot
        end
    end
    return nil
end

-- The equip slot an item goes in, or nil when bots don't use it (ranged and ammo: bows, rods, bait, pet food).
function gear.slotOf(info)
    if info == nil or not info.equipment or not info.slots then
        return nil
    end
    local slot = lowestSlot(info.slots)
    if slot == xi.slot.RANGED or slot == xi.slot.AMMO then
        return nil
    end
    return slot
end

-- 1 = most preferred weapon type for the job; nil = a weapon type the job doesn't use.
function gear.weaponRank(job, info)
    local prefs = WEAPON_PREF[job]
    if prefs == nil or info.skill == nil then
        return 1
    end
    for i, skill in ipairs(prefs) do
        if skill == info.skill then
            return i
        end
    end
    return nil
end

-- Comparable score (bigger is better), or nil when the bot should not wear the item at all.
function gear.score(bot, info)
    if gear.slotOf(info) == nil or not bot:canEquipItem(info.id, true) then
        return nil
    end
    local base = (info.reqLvl or 0) * 1000 + (info.damage or info.def or 0)
    if info.weapon then
        local rank = gear.weaponRank(bot:getMainJob(), info)
        if rank == nil then
            return nil
        end
        return (10 - rank) * 100000 + base
    end
    return base
end

-- Score of what is worn in a slot (-1 when empty or not something the bot would choose).
function gear.wornScore(bot, slot)
    local id = bot:getEquipID(slot)
    if id == nil or id == 0 then
        return -1
    end
    return gear.score(bot, WorldbotItemInfo(id) or {}) or -1
end

-- The first weapon skill of each weapon type (skill 5), with its skillchain property, as 2006 players used.
local FIRST_WS =
{
    [S.HAND_TO_HAND] = { name = 'Combo',          prop = 'Impaction' },
    [S.DAGGER]       = { name = 'Wasp Sting',     prop = 'Scission' },
    [S.SWORD]        = { name = 'Fast Blade',     prop = 'Scission' },
    [S.AXE]          = { name = 'Raging Axe',     prop = 'Detonation' },
    [S.CLUB]         = { name = 'Shining Strike', prop = 'Impaction' },
    [S.STAFF]        = { name = 'Heavy Swing',    prop = 'Impaction' },
}

-- Level-1 skillchains: opener property -> closer property -> resulting skillchain.
local CHAINS =
{
    Scission   = { Detonation = 'Detonation', Liquefaction = 'Liquefaction' },
    Impaction  = { Detonation = 'Detonation', Liquefaction = 'Liquefaction' },
    Detonation = { Scission = 'Scission', Compression = 'Gravitation' },
}

-- The weapon skill a bot can use with what it holds ({ name, prop }), or nil.
function gear.weaponSkill(bot)
    local id    = bot:getEquipID(xi.slot.MAIN)
    local info  = (id and id ~= 0) and WorldbotItemInfo(id) or nil
    local skill = info and info.skill or S.HAND_TO_HAND -- empty hands: hand-to-hand
    return FIRST_WS[skill]
end

-- The skillchain an opener and a closer make, or nil.
function gear.chain(openProp, closeProp)
    return CHAINS[openProp] and CHAINS[openProp][closeProp] or nil
end

return gear
