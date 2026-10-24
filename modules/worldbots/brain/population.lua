-----------------------------------
-- The population: who the bots are. Creates missing bots through the
-- server's character creation (WorldbotCreateCharacter) and registers them.
-----------------------------------
local names    = require('modules/worldbots/brain/names')
local schedule = require('modules/worldbots/brain/schedule')
local json     = require('modules/worldbots/lib/json')

local population = {}

local R = { HUME_M = 1, HUME_F = 2, ELVAAN_M = 3, ELVAAN_F = 4, TARU_M = 5, TARU_F = 6, MITHRA = 7, GALKA = 8 }

-- A plausible race for each starting job in each nation (San d'Oria leans Elvaan, Bastok Hume and
-- Galka, Windurst Tarutaru and Mithra), as on 2006 servers.
local RACE_PLAN =
{
    [xi.nation.SANDORIA] =
    {
        [xi.job.WAR] = R.ELVAAN_M, [xi.job.MNK] = R.HUME_M,  [xi.job.THF] = R.MITHRA,
        [xi.job.WHM] = R.ELVAAN_F, [xi.job.BLM] = R.TARU_M,  [xi.job.RDM] = R.HUME_F,
    },
    [xi.nation.BASTOK] =
    {
        [xi.job.WAR] = R.GALKA,    [xi.job.MNK] = R.HUME_M,  [xi.job.THF] = R.HUME_F,
        [xi.job.WHM] = R.ELVAAN_F, [xi.job.BLM] = R.TARU_F,  [xi.job.RDM] = R.ELVAAN_M,
    },
    [xi.nation.WINDURST] =
    {
        [xi.job.WAR] = R.GALKA,    [xi.job.MNK] = R.MITHRA,  [xi.job.THF] = R.MITHRA,
        [xi.job.WHM] = R.TARU_F,   [xi.job.BLM] = R.TARU_M,  [xi.job.RDM] = R.HUME_M,
    },
}

function population.raceFor(nation, job)
    local plan = RACE_PLAN[nation] or RACE_PLAN[xi.nation.SANDORIA]
    return plan[job] or math.random(1, 8)
end

-- Registry rows with decoded schedule and state.
function population.load()
    local rows = {}
    for _, row in ipairs(WorldbotRegistry()) do
        local okS, sched = pcall(function() return json:decode(row.schedule) end)
        local okT, state = pcall(function() return json:decode(row.state) end)
        row.schedule = okS and type(sched) == 'table' and sched or { windows = {} }
        row.state    = okT and type(state) == 'table' and state or {}
        table.insert(rows, row)
    end
    return rows
end

-- Create one bot: a name that passes the server's checks, then the character, then the registry row.
function population.create(nation, job, race, logBot)
    local personalities = schedule.personalities()
    local personality   = personalities[math.random(#personalities)]
    for _, name in ipairs(names.candidates(race, os.time() + nation * 100 + job)) do
        local face = math.random(0, 15)
        local size = math.random(0, 2)
        local charId, err = WorldbotCreateCharacter(name, race, face, size, nation, job)
        if charId then
            local sched = schedule.generate(personality)
            WorldbotRegister(charId, nation, race, job, personality, json:encode(sched))
            WorldbotLog(charId, 'created', string.format('%s: race %d face %d size %d nation %d job %d, %s', name, race, face, size, nation, job, personality))
            return charId, name
        end
        if logBot then
            logBot(string.format('name %s refused: %s', name, tostring(err)))
        end
    end
    return nil
end

-- Register world-bot characters that have no registry row yet (see WorldbotOrphans).
function population.adoptOrphans(log, only)
    local adopted = 0
    for _, o in ipairs(WorldbotOrphans()) do
        if only == nil or only(o) then
            local personalities = schedule.personalities()
            local personality   = personalities[math.random(#personalities)]
            WorldbotRegister(o.charId, o.nation, o.race, o.job, personality, json:encode(schedule.generate(personality)))
            WorldbotLog(o.charId, 'created', string.format('%s adopted into the registry: nation %d race %d job %d, %s', o.name, o.nation, o.race, o.job, personality))
            adopted = adopted + 1
            if log then
                log(string.format('adopted %s (charId %d)', o.name, o.charId))
            end
        end
    end
    return adopted
end

-- Grow the population to `target` bots (M7): new bots get a random nation and starting job and that
-- nation's usual race for the job. Created through the same character creation, `perCall` at a time
-- so a large step does not stall a tick.
function population.grow(rows, target, nations, jobs, perCall, log)
    local created = 0
    local count   = #rows
    while count < target and created < (perCall or 10) do
        local nation = nations[math.random(#nations)]
        local job    = jobs[math.random(#jobs)]
        local charId, name = population.create(nation, job, population.raceFor(nation, job), nil)
        if charId == nil then
            break
        end
        created = created + 1
        count   = count + 1
        if log then
            log(string.format('created %s (charId %d) nation %d job %d', name, charId, nation, job))
        end
    end
    return created
end

-- Make sure every (nation, job) slot of the development population has a bot.
function population.seed(rows, nations, jobs, log)
    local have = {}
    for _, row in ipairs(rows) do
        have[row.nation * 100 + row.job] = true
    end
    local created = 0
    for _, nation in ipairs(nations) do
        for _, job in ipairs(jobs) do
            if not have[nation * 100 + job] then
                local charId, name = population.create(nation, job, population.raceFor(nation, job), log)
                if charId then
                    created = created + 1
                    if log then
                        log(string.format('created %s (charId %d) nation %d job %d', name, charId, nation, job))
                    end
                end
            end
        end
    end
    return created
end

return population
