-----------------------------------
-- Unit tests for the brain's pure decision logic. Run inside the server
-- (they use the server's zone data): put `return require('modules/worldbots/brain/tests').run()`
-- in modules/worldbots/dev/run.lua. Returns "N passed, M failed: ..." for the log.
-----------------------------------
local tests = {}

local cases = {}
local function case(name, fn)
    table.insert(cases, { name = name, fn = fn })
end

local function eq(a, b, what)
    if a ~= b then
        error(string.format('%s: expected %s, got %s', what or 'value', tostring(b), tostring(a)), 2)
    end
end

local function truthy(v, what)
    if not v then
        error((what or 'condition') .. ' was false', 2)
    end
end

-----------------------------------
-- schedule
-----------------------------------
case('schedule: inside and outside a same-day window', function()
    local schedule = require('modules/worldbots/brain/schedule')
    local s = { windows = { { days = { 2 }, s = 18 * 60, e = 20 * 60 } } } -- Monday 18:00-20:00
    eq(schedule.isOnline(s, { wday = 2, hour = 19, min = 0 }), true, 'Mon 19:00')
    eq(schedule.isOnline(s, { wday = 2, hour = 20, min = 0 }), false, 'Mon 20:00 (end is exclusive)')
    eq(schedule.isOnline(s, { wday = 3, hour = 19, min = 0 }), false, 'Tue 19:00')
end)

case('schedule: window past midnight covers the next morning', function()
    local schedule = require('modules/worldbots/brain/schedule')
    local s = { windows = { { days = { 7 }, s = 22 * 60, e = 2 * 60 } } } -- Saturday 22:00-02:00
    eq(schedule.isOnline(s, { wday = 7, hour = 23, min = 30 }), true, 'Sat 23:30')
    eq(schedule.isOnline(s, { wday = 1, hour = 1, min = 30 }), true, 'Sun 01:30')
    eq(schedule.isOnline(s, { wday = 1, hour = 2, min = 30 }), false, 'Sun 02:30')
    eq(schedule.isOnline(s, { wday = 7, hour = 1, min = 0 }), false, 'Sat 01:00')
end)

case('schedule: every personality plays between 2 and 80 hours a week', function()
    local schedule = require('modules/worldbots/brain/schedule')
    for _, p in ipairs(schedule.personalities()) do
        for seed = 1, 20 do
            math.randomseed(seed)
            local minutes = schedule.weeklyMinutes(schedule.generate(p))
            truthy(minutes >= 120 and minutes <= 80 * 60, string.format('%s seed %d: %d min/week', p, seed, minutes))
        end
    end
end)

-----------------------------------
-- areas
-----------------------------------
case('areas: level windows', function()
    local areas = require('modules/worldbots/brain/areas')
    local lo, hi = areas.levelWindow(1, false)
    eq(lo, 1, 'lv1 min'); eq(hi, 2, 'lv1 max')
    lo, hi = areas.levelWindow(8, false)
    eq(lo, 4, 'lv8 min'); eq(hi, 8, 'lv8 max')
    lo, hi = areas.levelWindow(20, true)
    eq(lo, 20, 'party lv20 min'); eq(hi, 24, 'party lv20 max')
end)

case('areas: every level 1-75 has candidate zones for every nation', function()
    local areas = require('modules/worldbots/brain/areas')
    for _, nation in ipairs({ xi.nation.SANDORIA, xi.nation.BASTOK, xi.nation.WINDURST }) do
        for level = 1, 75 do
            truthy(#areas.candidates(nation, level) > 0, string.format('nation %d lv%d', nation, level))
        end
    end
end)

-----------------------------------
-- travel (uses the zone data files)
-----------------------------------
case('travel: each home city reaches its starter zones', function()
    local travel = require('modules/worldbots/brain/travel')
    local areas  = require('modules/worldbots/brain/areas')
    for nation, home in pairs(areas.HOME) do
        for _, zone in ipairs(areas.candidates(nation, 1)) do
            local route = travel.route(home, zone)
            truthy(route ~= nil, string.format('route %d -> %d', home, zone))
            truthy(#route <= 3, string.format('route %d -> %d has %d hops', home, zone, route and #route or -1))
        end
    end
end)

case('travel: every leveling zone is reachable from every home city', function()
    local travel = require('modules/worldbots/brain/travel')
    local areas  = require('modules/worldbots/brain/areas')
    for nation, home in pairs(areas.HOME) do
        for level = 1, 75, 2 do
            for _, zone in ipairs(areas.candidates(nation, level)) do
                truthy(travel.route(home, zone) ~= nil, string.format('nation %d: %d -> %d (lv%d)', nation, home, zone, level))
            end
        end
    end
end)

case('travel: routes never use Mog House doors', function()
    local travel = require('modules/worldbots/brain/travel')
    for _, line in ipairs(travel.lines(xi.zone.SOUTHERN_SAN_DORIA)) do
        truthy(line.toZone ~= xi.zone.SOUTHERN_SAN_DORIA, 'line back into the same zone')
    end
end)

-----------------------------------
-- names
-----------------------------------
case('names: every candidate is letters only and 3-15 long', function()
    local names = require('modules/worldbots/brain/names')
    for race = 1, 8 do
        for _, n in ipairs(names.candidates(race, 42)) do
            truthy(n:match('^%a+$') ~= nil, 'letters only: ' .. n)
            truthy(#n >= 3 and #n <= 15, 'length: ' .. n)
        end
    end
end)

case('names: curated lists have no duplicates across races', function()
    local names = require('modules/worldbots/brain/names')
    local seen  = {}
    for race = 1, 8 do
        for _, n in ipairs(names.byRace[race]) do
            truthy(seen[n:lower()] == nil, 'duplicate ' .. n)
            seen[n:lower()] = true
        end
    end
end)

-----------------------------------
-- context
-----------------------------------
case('context: release drops an empty context and keeps a shared one', function()
    local context = require('modules/worldbots/brain/context')
    context.byKey['t:1'] = { test = true }
    context.keyOf[-1] = 't:1'
    context.keyOf[-2] = 't:1'
    context.release(-1)
    truthy(context.byKey['t:1'] ~= nil, 'still used by -2')
    context.release(-2)
    eq(context.byKey['t:1'], nil, 'dropped')
end)

-----------------------------------
-- weapon skills and skillchain pairs (stub bots: an axe WAR and a sword RDM chain Detonation > Scission)
-----------------------------------
case('brain: weapon skills pair an axe opener with a sword closer', function()
    local brain = xi.worldbots.brain
    local function stub(name, main)
        return { getEquipID = function(_, slot) return slot == xi.slot.MAIN and main or 0 end, getName = function() return name end }
    end
    local war = { rec = { charId = -11, row = { job = xi.job.WAR } }, bot = stub('Axeman', 16640) } -- Bronze Axe
    local rdm = { rec = { charId = -12, row = { job = xi.job.RDM } }, bot = stub('Blade', 16534) } -- Onion Sword
    local sc, solo = brain.weaponSkillsFor({ war, rdm })
    eq(#sc, 1, 'pairs')
    eq(sc[1].openWS, 'Raging Axe', 'opener')
    eq(sc[1].closeWS, 'Fast Blade', 'closer')
    eq(sc[1].chain, 'Scission', 'skillchain')
    truthy(sc[1].openCharId == -11 and sc[1].closeCharId == -12, 'char ids for the pair lookup')
    eq(next(solo), nil, 'nobody left over for solo weapon skills')
end)

function tests.run()
    local passed, failed = 0, {}
    for _, c in ipairs(cases) do
        local ok, err = pcall(c.fn)
        if ok then
            passed = passed + 1
        else
            table.insert(failed, c.name .. ' -- ' .. tostring(err))
        end
    end
    return string.format('%d passed, %d failed%s', passed, #failed, #failed > 0 and (': ' .. table.concat(failed, ' | ')) or '')
end

return tests
