-----------------------------------
-- Travel: routes over the zone lines in the zone data files, walked on the
-- navmesh with Nate's pathTo, crossing each line with the client's zone-line
-- packet (bot:worldbotUseZoneLine), so the engine zones the bot exactly as it
-- zones a player.
-----------------------------------
local travel = {}

local ARRIVE_DIST   = 4.0  -- yalms: close enough to a walk target
local LINE_USE_DIST = 6.0  -- touch the zone line from here (the server allows up to 40)
local LINE_FAR_DIST = 35.0 -- navmesh can't reach the box centre: try the line from this close
local STUCK_SECONDS = 25   -- no progress for this long: try a detour
local GIVEUP_SECONDS = 150 -- no progress for this long: give up the route

local linesCache = {}

local function isMogHouseLine(id)
    -- Zone-line ids are fourcc tags packed little-endian; "zmr*" / "zms*" are Mog House doors.
    local a = id % 256
    local b = math.floor(id / 256) % 256
    local c = math.floor(id / 65536) % 256
    return a == string.byte('z') and b == string.byte('m') and (c == string.byte('r') or c == string.byte('s'))
end

-- Usable outbound lines of a zone (no Mog House doors, no lines back into the same zone).
function travel.lines(zoneId)
    local cached = linesCache[zoneId]
    if cached then
        return cached
    end
    local out = {}
    for _, line in ipairs(WorldbotZoneLines(zoneId)) do
        if line.toZone ~= zoneId and line.toZone ~= 0 and not isMogHouseLine(line.id) then
            table.insert(out, line)
        end
    end
    linesCache[zoneId] = out
    return out
end

-- Shortest route (fewest zone lines) from one zone to another: { line, line, ... }, or nil.
-- avoid: optional set of zone ids never entered (e.g. zones known to be dangerous for the bot's level).
function travel.route(fromZone, toZone, avoid, maxDepth)
    if fromZone == toZone then
        return {}
    end
    maxDepth = maxDepth or 24 -- Windurst to the Altepa deserts is over a dozen zone lines
    local prev  = { [fromZone] = false }
    local queue = { fromZone }
    local depth = { [fromZone] = 0 }
    local head  = 1
    while head <= #queue do
        local zone = queue[head]
        head       = head + 1
        if depth[zone] < maxDepth then
            for _, line in ipairs(travel.lines(zone)) do
                local nextZone = line.toZone
                if prev[nextZone] == nil and not (avoid and avoid[nextZone]) then
                    prev[nextZone]  = { zone = zone, line = line }
                    depth[nextZone] = depth[zone] + 1
                    if nextZone == toZone then
                        local route = {}
                        local z     = toZone
                        while prev[z] do
                            table.insert(route, 1, prev[z].line)
                            z = prev[z].zone
                        end
                        return route
                    end
                    table.insert(queue, nextZone)
                end
            end
        end
    end
    return nil
end

local function dist(bot, x, y, z)
    local dx, dy, dz = bot:getXPos() - x, bot:getYPos() - y, bot:getZPos() - z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
travel.dist = dist

local function flatDist(bot, x, z)
    local dx, dz = bot:getXPos() - x, bot:getZPos() - z
    return math.sqrt(dx * dx + dz * dz)
end

-- Progress tracking shared by walks: returns 'ok', 'stuck' (detour) or 'giveup'.
local function progress(st, bot, now)
    local p = st.progress
    if p == nil or p.target ~= st.walkKey then
        st.progress = { target = st.walkKey, bestAt = now, best = math.huge, startedAt = now }
        p = st.progress
    end
    local d = st.walkDist or math.huge
    if d < p.best - 1.0 then
        p.best   = d
        p.bestAt = now
    end
    if now - p.bestAt >= GIVEUP_SECONDS then
        return 'giveup'
    end
    if now - p.bestAt >= STUCK_SECONDS then
        return 'stuck'
    end
    return 'ok'
end

-- One step toward a point in the bot's zone. Returns 'arrived', 'walking', 'stuck' or 'giveup'.
function travel.walkTo(bot, st, x, y, z, arriveDist, now)
    arriveDist  = arriveDist or ARRIVE_DIST
    st.walkKey  = string.format('%d:%.0f:%.0f:%.0f', bot:getZoneID(), x, y, z)
    st.walkDist = flatDist(bot, x, z)
    if st.walkDist <= arriveDist then
        st.progress = nil
        return 'arrived'
    end
    local state = progress(st, bot, now)
    if state == 'giveup' then
        st.progress = nil
        return 'giveup'
    end
    if state == 'stuck' then
        -- Detour: a random nearby point, then try again from there.
        local a = math.random() * math.pi * 2
        bot:pathTo(bot:getXPos() + math.cos(a) * 8, bot:getYPos(), bot:getZPos() + math.sin(a) * 8)
        st.progress.bestAt = now - STUCK_SECONDS + 8 -- give the detour a few seconds
        return 'stuck'
    end
    if not bot:pathTo(x, y, z) then
        -- No navmesh route to the exact point; aim a little short along the line from the bot.
        local d  = math.max(st.walkDist, 0.1)
        local t  = math.max(0, (d - arriveDist * 0.5) / d)
        local tx = bot:getXPos() + (x - bot:getXPos()) * t
        local tz = bot:getZPos() + (z - bot:getZPos()) * t
        bot:pathTo(tx, y, tz)
    end
    return 'walking'
end

-- One step along a route to a zone. st.route is kept on the bot's travel state.
-- Returns 'arrived' (in the zone), 'walking', 'zoning', 'noroute' or 'giveup'.
function travel.toZone(bot, st, zoneId, now, avoid)
    if bot:getZoneID() == zoneId then
        st.route = nil
        return 'arrived'
    end
    if bot:worldbotIsZoning() then
        return 'zoning'
    end
    if st.route == nil or st.routeFrom ~= bot:getZoneID() or st.routeTo ~= zoneId then
        st.route     = travel.route(bot:getZoneID(), zoneId, avoid)
        st.routeFrom = bot:getZoneID()
        st.routeTo   = zoneId
        if st.route == nil then
            return 'noroute'
        end
    end
    local line = st.route[1]
    if line == nil then
        st.route = nil
        return 'noroute'
    end
    -- Horizontal distance, as the server's zone-line check (0x05E) measures it: a line's box centre can sit
    -- several yalms above or below the ground.
    local d = flatDist(bot, line.x, line.z)
    if d <= LINE_USE_DIST then
        if bot:worldbotUseZoneLine(line.id) then
            st.route = nil -- recomputed from the next zone
            return 'zoning'
        end
    end
    local step = travel.walkTo(bot, st, line.x, line.y, line.z, LINE_USE_DIST - 1.0, now)
    if (step == 'giveup' or step == 'stuck') and d <= LINE_FAR_DIST then
        -- The box centre is off the navmesh (in a wall or over water): touch it from here, as the server allows.
        if bot:worldbotUseZoneLine(line.id) then
            st.route = nil
            return 'zoning'
        end
    end
    if step == 'giveup' then
        st.route = nil
        return 'giveup'
    end
    return 'walking'
end

return travel
