-----------------------------------
-- Login schedules: when a bot plays, by personality, like a 2006 player.
--
-- A schedule is { windows = { { days = { 1..7 } or 'all', s = startMinute, e = endMinute }, ... } }
-- in server-local time (os.date), weekday 1 = Sunday as in os.date('*t').wday.
-- A window may run past midnight (e < s): it then covers s..24:00 on its days
-- and 00:00..e on the following day. Pure functions, unit-tested in tests.lua.
-----------------------------------
local schedule = {}

local ALL = { 1, 2, 3, 4, 5, 6, 7 }

local function dayIn(days, wday)
    if days == 'all' then
        return true
    end
    for _, d in ipairs(days) do
        if d == wday then
            return true
        end
    end
    return false
end

local function prevDay(wday)
    return wday == 1 and 7 or wday - 1
end

-- t: os.date('*t')-style table (wday, hour, min).
function schedule.isOnline(sched, t)
    if sched == nil or sched.windows == nil then
        return false
    end
    local minute = t.hour * 60 + t.min
    for _, w in ipairs(sched.windows) do
        if w.e > w.s then
            if dayIn(w.days, t.wday) and minute >= w.s and minute < w.e then
                return true
            end
        else -- runs past midnight
            if (dayIn(w.days, t.wday) and minute >= w.s) or (dayIn(w.days, prevDay(t.wday)) and minute < w.e) then
                return true
            end
        end
    end
    return false
end

-- Minutes online per week, for reports and tests.
function schedule.weeklyMinutes(sched)
    local total = 0
    for _, w in ipairs(sched.windows or {}) do
        local len  = w.e > w.s and (w.e - w.s) or (24 * 60 - w.s + w.e)
        local days = w.days == 'all' and 7 or #w.days
        total      = total + len * days
    end
    return total
end

local PERSONALITIES = { 'dedicated', 'casual', 'nightowl', 'earlybird', 'weekender', 'steady' }

function schedule.personalities()
    return PERSONALITIES
end

-- A schedule for a personality; rng(a, b) returns an integer in [a, b] (math.random by default).
function schedule.generate(personality, rng)
    rng = rng or math.random
    local function at(h, jitter)
        return (h * 60 + rng(-jitter, jitter)) % (24 * 60)
    end

    local windows = {}
    if personality == 'dedicated' then
        table.insert(windows, { days = 'all', s = at(18, 45), e = at(24, 60) })
        table.insert(windows, { days = { 1, 7 }, s = at(11, 60), e = at(16, 60) })
    elseif personality == 'casual' then
        local days = {}
        for _, d in ipairs(ALL) do
            if rng(1, 100) <= 55 then
                table.insert(days, d)
            end
        end
        while #days < 2 do -- at least two evenings a week
            local d = rng(1, 7)
            local have = false
            for _, x in ipairs(days) do
                have = have or x == d
            end
            if not have then
                table.insert(days, d)
            end
        end
        local s = at(rng(18, 21), 30)
        table.insert(windows, { days = days, s = s, e = (s + rng(90, 150)) % (24 * 60) })
    elseif personality == 'nightowl' then
        table.insert(windows, { days = 'all', s = at(22, 45), e = at(4, 60) })
    elseif personality == 'earlybird' then
        table.insert(windows, { days = 'all', s = at(6, 30), e = at(9, 30) })
        table.insert(windows, { days = { 2, 4, 6 }, s = at(19, 30), e = at(21, 30) })
    elseif personality == 'weekender' then
        table.insert(windows, { days = { 6, 7 }, s = at(20, 60), e = at(2, 60) })
        table.insert(windows, { days = { 1, 7 }, s = at(10, 60), e = at(18, 60) })
    else -- steady: a few short sessions every day
        table.insert(windows, { days = 'all', s = at(7, 30), e = at(8, 30) })
        table.insert(windows, { days = 'all', s = at(12, 20), e = at(13, 20) })
        table.insert(windows, { days = 'all', s = at(19, 45), e = at(22, 45) })
    end
    for _, w in ipairs(windows) do
        if w.e == w.s then -- jitter closed the window; give it an hour
            w.e = (w.s + 60) % (24 * 60)
        end
    end
    return { personality = personality, windows = windows }
end

return schedule
