-----------------------------------
-- M5: gil. Bots go to town, sell their drops to NPC vendors and buy what
-- they need: spell scrolls their job can learn at their level (used at once
-- to learn the spell) and equipment better than what they wear, within a
-- budget. Everything goes through the client's own actions: talk to the
-- vendor (0x01A), the shop packets (0x083 buy, 0x084/0x085 sell) and item
-- use. The server writes every sale and purchase to audit_vendor
-- (AUDIT_PLAYER_VENDOR); the brain logs gil before and after each trip.
--
-- Shops are learned the way players learn them: by talking to vendors.
-- Stock seen by any bot is shared (economy.stock), as players share
-- knowledge of where things are sold.
-----------------------------------
local travel = require('modules/worldbots/brain/travel')
local gear   = require('modules/worldbots/brain/gear')

local economy = {}

local SCROLL_FIRST, SCROLL_LAST = 4609, 5119 -- white/black magic and song scrolls: spell id = item id - 4608
local KEEP     = { [536] = true } -- Adventurer's Coupon (traded in later, as players did)

local TALK_DIST       = 5.0 -- the server accepts a talk within 6 yalms; vendors often stand behind counters
local TRIP_MAX_SECONDS = 1200
local RESERVE_GIL     = 10 -- never spend the last of it

-- The three city zones of each nation, home first.
local CITIES =
{
    [xi.nation.SANDORIA] = { xi.zone.SOUTHERN_SAN_DORIA, xi.zone.NORTHERN_SAN_DORIA, xi.zone.PORT_SAN_DORIA },
    [xi.nation.BASTOK]   = { xi.zone.BASTOK_MINES, xi.zone.BASTOK_MARKETS, xi.zone.PORT_BASTOK },
    [xi.nation.WINDURST] = { xi.zone.WINDURST_WOODS, xi.zone.WINDURST_WATERS, xi.zone.PORT_WINDURST },
}
economy.CITIES = CITIES

economy.stock     = {} -- npcId -> { name, zone, at, items = { { index, itemId, price } } }
economy.noShop    = {} -- npcId -> true: talked to, no shop opened (or an event)
local vendorCache = {} -- zoneId -> { name, ... }
local magicVendor = {} -- vendor name -> true: its script sells spell scrolls (a "magic shop", common knowledge)

local SURVEYS_PER_TRIP = 6 -- unknown vendors one trip looks at before going home
local KNOWLEDGE_FILE   = 'modules/worldbots/config/shops/shops.json'
local json             = require('modules/worldbots/lib/json')

-- Shop knowledge survives restarts (a local file, not game data).
function economy.loadKnowledge()
    local f = io.open(KNOWLEDGE_FILE, 'r')
    if f == nil then
        return
    end
    local ok, data = pcall(function() return json:decode(f:read('*a')) end)
    f:close()
    if ok and type(data) == 'table' then
        for id, v in pairs(data.stock or {}) do
            economy.stock[tonumber(id)] = v
        end
        for id, v in pairs(data.noShop or {}) do
            economy.noShop[tonumber(id)] = v
        end
    end
end

function economy.saveKnowledge()
    local stock, noShop = {}, {}
    for id, v in pairs(economy.stock) do
        stock[tostring(id)] = v
    end
    for id, v in pairs(economy.noShop) do
        noShop[tostring(id)] = v
    end
    local f = io.open(KNOWLEDGE_FILE, 'w')
    if f then
        f:write(json:encode({ stock = stock, noShop = noShop }))
        f:close()
    end
end

-- Vendor NPC names in a zone: their scripts open a shop (xi.shop.*).
function economy.vendorNames(zoneId)
    if vendorCache[zoneId] then
        return vendorCache[zoneId]
    end
    local zone  = GetZone(zoneId)
    local names = {}
    if zone then
        local dir = 'scripts/zones/' .. zone:getName() .. '/npcs/'
        for _, file in ipairs(WorldbotListDir(dir)) do
            local f = io.open(dir .. file, 'r')
            if f then
                local body = f:read('*a')
                f:close()
                if body:find('xi%.shop%.') then
                    local name = file:gsub('%.lua$', '')
                    table.insert(names, name)
                    if body:find('SCROLL_OF_') then
                        magicVendor[name] = true
                    end
                end
            end
        end
    end
    vendorCache[zoneId] = names
    return names
end

-- Vendor entities in the bot's zone, nearest first, skipping ones known not to open a shop.
function economy.vendorsNear(bot)
    local zone = bot:getZone()
    local out  = {}
    if zone == nil then
        return out
    end
    for _, name in ipairs(economy.vendorNames(bot:getZoneID())) do
        for _, npc in ipairs(zone:queryEntitiesByName(name)) do
            if not economy.noShop[npc:getID()] then
                table.insert(out, { npc = npc, d = travel.dist(bot, npc:getXPos(), npc:getYPos(), npc:getZPos()) })
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function equippedSet(bot)
    local set = {}
    for slot = 0, 15 do
        local id = bot:getEquipID(slot)
        if id and id ~= 0 then
            set[id] = true
        end
    end
    return set
end

-- How much the bot wants an item from a shop: nil (no), or { priority, kind, slot }.
function economy.want(bot, itemId, rec)
    local crafting = xi.worldbots.crafting
    if rec and crafting and crafting.want then
        local w = crafting.want(rec, bot, itemId)
        if w then
            return w
        end
    end
    if itemId >= SCROLL_FIRST and itemId <= SCROLL_LAST then
        local spell = itemId - 4608
        if not bot:hasSpell(spell) and bot:canLearnSpell(spell) == 0 then
            return { priority = 1, kind = 'scroll', spell = spell }
        end
        return nil
    end
    local info  = WorldbotItemInfo(itemId)
    local score = info and gear.score(bot, info)
    if score == nil then
        return nil
    end
    local slot = gear.slotOf(info)
    if score > gear.wornScore(bot, slot) then
        -- Weapons first (they decide kill speed), then body, then the rest.
        local p = info.weapon and 2 or (slot == xi.slot.BODY and 3 or 4)
        return { priority = p, kind = 'gear', slot = slot }
    end
    return nil
end

-- Inventory items to sell: drops, not gear in use or still wanted, scrolls, crystals (crafting) or keepsakes.
function economy.sellable(bot, keep)
    local equipped = equippedSet(bot)
    local out      = {}
    for _, item in ipairs(bot:worldbotInventory()) do
        local id   = item.itemId
        local info = WorldbotItemInfo(id)
        local skip = equipped[id] or KEEP[id] or (id >= SCROLL_FIRST and id <= SCROLL_LAST)
            or info == nil or info.noSale or info.rare or info.exclusive
            or (gear.slotOf(info) and bot:canEquipItem(id, false)) -- gear this job can use, now or later
            or (keep and keep(id))
        if not skip then
            table.insert(out, item)
        end
    end
    return out
end

-- What this bot keeps out of the sale: its own craft's tool, crystals and materials (other crystals sell).
function economy.keepFor(rec)
    local crafting = xi.worldbots.crafting
    return function(itemId)
        return crafting ~= nil and crafting.keepFor ~= nil and crafting.keepFor(rec, itemId)
    end
end

local function freeSlots(bot)
    return bot:getFreeSlotsCount()
end

-- Something in a known stock the bot wants and can afford.
local function stockHasWanted(rec, bot, items)
    local gil = bot:getGil() - RESERVE_GIL
    for _, e in ipairs(items) do
        if e.price <= gil and economy.want(bot, e.itemId, rec) then
            return true
        end
    end
    return false
end

local function learnsSpells(rec)
    return rec.row.job == xi.job.WHM or rec.row.job == xi.job.BLM or rec.row.job == xi.job.RDM
end

-- An unknown vendor is worth a look while the trip has surveys left: magic shops first for spellcasters.
local function worthSurveying(rec, name, sh)
    if (sh.surveys or 0) >= SURVEYS_PER_TRIP then
        return false
    end
    if learnsSpells(rec) and magicVendor[name] then
        return true
    end
    return (sh.surveys or 0) < (learnsSpells(rec) and 2 or SURVEYS_PER_TRIP)
end

function economy.worthVisiting(rec, bot, npcId, sh, name)
    local known = economy.stock[npcId]
    if known == nil then
        return worthSurveying(rec, name, sh) -- never seen (stock knowledge is shared by all bots)
    end
    if not sh.sold and #economy.sellable(bot, economy.keepFor(rec)) > 0 then
        return true
    end
    return stockHasWanted(rec, bot, known.items)
end

-- Another city worth the walk: unknown vendors there, or a known vendor with something wanted.
function economy.cityWorthVisiting(rec, bot, zoneId, sh)
    local zone = GetZone(zoneId)
    if zone == nil then
        return false
    end
    for _, name in ipairs(economy.vendorNames(zoneId)) do
        for _, npc in ipairs(zone:queryEntitiesByName(name)) do
            local id = npc:getID()
            if not economy.noShop[id] then
                local known = economy.stock[id]
                if (known == nil and worthSurveying(rec, name, sh)) or (known and stockHasWanted(rec, bot, known.items)) then
                    return true
                end
            end
        end
    end
    return false
end

-----------------------------------
-- The activity
-----------------------------------
economy.activity = {}
local act = economy.activity

-- Go shopping when the bags are filling up, or with gil to spend after a few levels.
function act.choose(rec, bot, t)
    if rec.mem.party or bot:isEngaged() then
        return false
    end
    local s = rec.state
    local level = bot:getMainLvl()
    if t < (rec.mem.nextShopCheck or 0) then
        return false
    end
    rec.mem.nextShopCheck = t + 120
    if bot.sortInventory then
        bot:sortInventory() -- merge split stacks (Nate's port of the client's sort, packet 0x03A)
    end
    local newLevels = level >= (s.lastShopLevel or 1) + 2
    local toSell    = #economy.sellable(bot, economy.keepFor(rec))
    local fullBags  = freeSlots(bot) <= 4 and toSell > 0 -- full of materials it keeps: crafting's job, not a trip
    local hasGil    = bot:getGil() >= RESERVE_GIL + 40
    -- Or: a vendor the bots know sells something this bot wants and can afford now.
    local knownWant = false
    if t >= (rec.mem.nextKnownWant or 0) then
        rec.mem.nextKnownWant = t + 600
        local mine = {}
        for _, z in ipairs(CITIES[rec.row.nation] or {}) do
            mine[z] = true
        end
        for _, v in pairs(economy.stock) do
            if mine[v.zone] and stockHasWanted(rec, bot, v.items) then -- trips stay in the bot's own nation
                knownWant = true
                break
            end
        end
        -- A spellcaster with some gil goes to see its nation's magic shop once it exists unvisited.
        if not knownWant and learnsSpells(rec) and bot:getGil() >= 70 then
            for _, zoneId in ipairs(CITIES[rec.row.nation] or {}) do
                local zone = GetZone(zoneId)
                for _, name in ipairs(economy.vendorNames(zoneId)) do
                    if magicVendor[name] and zone then
                        local npc = zone:queryEntitiesByName(name)[1]
                        if npc and economy.stock[npc:getID()] == nil and not economy.noShop[npc:getID()] then
                            knownWant = true
                        end
                    end
                end
            end
        end
    end
    if fullBags or knownWant or (newLevels and (hasGil or toSell >= 4)) then
        rec.mem.shop = { startAt = t, zoneIndex = 1, visited = {}, visits = 0, sold = false, gilStart = bot:getGil(),
                         reason = fullBags and 'bags full' or ('lv' .. level .. ' shopping') }
        return true
    end
    return false
end

local function finish(rec, bot, t, why)
    local sh = rec.mem.shop
    rec.state.lastShopLevel = bot:getMainLvl()
    xi.worldbots.brain.log(rec, 'shop', string.format('trip done (%s): gil %d -> %d, %d vendors, %ds',
        why, sh.gilStart, bot:getGil(), sh.visits, t - sh.startAt))
    rec.mem.shop = nil
    xi.worldbots.brain.equipBest(bot)
    return 'done'
end

-- Sell everything sellable to the open shop.
local function sellAll(rec, bot, keep)
    local sold, gilBefore = 0, bot:getGil()
    for _, item in ipairs(economy.sellable(bot, keep)) do
        if bot:worldbotShopSell(item.slot, item.itemId, item.quantity) then
            sold = sold + 1
        end
    end
    if sold > 0 then
        xi.worldbots.brain.log(rec, 'sell', string.format('sold %d stacks for %d gil (gil %d -> %d)', sold, bot:getGil() - gilBefore, gilBefore, bot:getGil()))
    end
end

-- Buy wanted items from the open shop's stock, best priority first, within budget.
local function buyWanted(rec, bot, stock)
    local wants = {}
    for _, e in ipairs(stock) do
        local w = economy.want(bot, e.itemId, rec)
        if w then
            w.entry = e
            table.insert(wants, w)
        end
    end
    table.sort(wants, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.entry.price < b.entry.price
    end)
    local boughtSlot = {}
    for _, w in ipairs(wants) do
        -- Spells and craft tools may take most of the purse; one piece of gear at most half of it.
        local budget = bot:getGil() - RESERVE_GIL
        if w.kind == 'gear' then
            budget = math.min(budget, math.floor(bot:getGil() / 2))
        end
        if w.entry.price <= budget and not (w.slot and boughtSlot[w.slot]) then
            local gilBefore = bot:getGil()
            if bot:worldbotShopBuy(w.entry.index, 1) and bot:getGil() < gilBefore then
                local name = (WorldbotItemInfo(w.entry.itemId) or {}).name or tostring(w.entry.itemId)
                xi.worldbots.brain.log(rec, 'buy', string.format('%s for %d gil (gil %d -> %d)', name, gilBefore - bot:getGil(), gilBefore, bot:getGil()))
                if w.slot then
                    boughtSlot[w.slot] = true
                    xi.worldbots.brain.equipBest(bot) -- wear it now, so later vendors compare against it
                end
                if w.kind == 'scroll' then
                    for _, item in ipairs(bot:worldbotInventory()) do
                        if item.itemId == w.entry.itemId then
                            bot:useItem(0, item.slot, bot) -- learn it (the scroll's own item script)
                            xi.worldbots.brain.log(rec, 'learn', name)
                            break
                        end
                    end
                end
            end
        end
    end
end

function act.step(rec, bot, t)
    local sh = rec.mem.shop
    if sh == nil then
        return 'done'
    end
    if t - sh.startAt > TRIP_MAX_SECONDS then
        return finish(rec, bot, t, 'out of time')
    end
    if bot:worldbotInEvent() then
        bot:worldbotEndEvent(0)
        return 'running'
    end
    local cities = CITIES[rec.row.nation] or CITIES[xi.nation.SANDORIA]
    local zone   = cities[sh.zoneIndex]
    if zone == nil then
        return finish(rec, bot, t, 'visited every city')
    end
    if bot:getZoneID() ~= zone then
        local r = travel.toZone(bot, rec.mem, zone, t)
        if r == 'noroute' or r == 'giveup' then
            sh.zoneIndex = sh.zoneIndex + 1
        end
        return 'running'
    end

    -- In the city: the nearest vendor worth a visit (not visited this trip, and either never seen,
    -- known to sell something wanted, or needed to sell the loot).
    local target = nil
    for _, v in ipairs(economy.vendorsNear(bot)) do
        if not sh.visited[v.npc:getID()] and economy.worthVisiting(rec, bot, v.npc:getID(), sh, v.npc:getName()) then
            target = v
            break
        end
    end
    if target == nil then
        -- Nothing more here: go on only if another city of the nation may have what is wanted.
        local nextZone = nil
        for i = sh.zoneIndex + 1, #cities do
            if economy.cityWorthVisiting(rec, bot, cities[i], sh) then
                nextZone = i
                break
            end
        end
        if nextZone == nil then
            return finish(rec, bot, t, 'nothing more to buy')
        end
        sh.zoneIndex = nextZone
        return 'running'
    end
    local npc = target.npc
    if target.d > TALK_DIST then
        local r = travel.walkTo(bot, rec.mem, npc:getXPos(), npc:getYPos(), npc:getZPos(), TALK_DIST - 0.5, t)
        if r == 'giveup' then
            sh.visited[npc:getID()] = true
        end
        return 'running'
    end

    sh.visited[npc:getID()] = true
    sh.visits = sh.visits + 1
    if economy.stock[npc:getID()] == nil then
        sh.surveys = (sh.surveys or 0) + 1
    end
    bot:worldbotTalk(npc)
    if bot:worldbotInEvent() then
        economy.noShop[npc:getID()] = true -- an event, not a shop (regional or quest NPC)
        economy.saveKnowledge()
        bot:worldbotEndEvent(0)
        return 'running'
    end
    local stock = bot:worldbotShopStock()
    if #stock == 0 then
        economy.noShop[npc:getID()] = true
        economy.saveKnowledge()
        return 'running'
    end
    local isNew = economy.stock[npc:getID()] == nil
    economy.stock[npc:getID()] = { name = npc:getName(), zone = bot:getZoneID(), at = t, items = stock }
    if isNew then
        economy.saveKnowledge()
    end
    if not sh.sold then
        sellAll(rec, bot, economy.keepFor(rec))
        sh.sold = true
    end
    buyWanted(rec, bot, stock)
    return 'running'
end

economy.loadKnowledge()

return economy
