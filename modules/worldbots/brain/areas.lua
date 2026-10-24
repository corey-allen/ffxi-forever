-----------------------------------
-- Where to level, by nation and level: the 2006/2007 leveling path (75 cap).
-- Each band lists candidate zones in preference order; the brain picks the first
-- that is reachable and has enough monsters at the right level right now, so a
-- band entry is a hint, never a guarantee.
-----------------------------------
local Z = xi.zone

local areas = {}

-- Home starter zones (solo 1-10).
local START =
{
    [xi.nation.SANDORIA] = { Z.WEST_RONFAURE, Z.EAST_RONFAURE },
    [xi.nation.BASTOK]   = { Z.SOUTH_GUSTABERG, Z.NORTH_GUSTABERG },
    [xi.nation.WINDURST] = { Z.EAST_SARUTABARUTA, Z.WEST_SARUTABARUTA },
}

local SECOND =
{
    [xi.nation.SANDORIA] = { Z.LA_THEINE_PLATEAU, Z.EAST_RONFAURE },
    [xi.nation.BASTOK]   = { Z.KONSCHTAT_HIGHLANDS, Z.NORTH_GUSTABERG },
    [xi.nation.WINDURST] = { Z.TAHRONGI_CANYON, Z.WEST_SARUTABARUTA },
}

-- { minLevel, maxLevel, zones } shared by all nations above the starter bands. Only zones reachable on
-- foot over zone lines: bots do not take ships or airships yet, so Yuhtunga, Yhoator, Ifrit's Cauldron,
-- Sea Serpent Grotto and the Tavnazian zones are left out (tests.lua checks every zone is reachable).
local BANDS =
{
    { 10, 15, { Z.VALKURM_DUNES, Z.BUBURIMU_PENINSULA } },
    { 15, 20, { Z.QUFIM_ISLAND, Z.VALKURM_DUNES, Z.BUBURIMU_PENINSULA } },
    { 20, 25, { Z.QUFIM_ISLAND, Z.JUGNER_FOREST, Z.PASHHOW_MARSHLANDS, Z.MERIPHATAUD_MOUNTAINS } },
    { 25, 30, { Z.ROLANBERRY_FIELDS, Z.SAUROMUGUE_CHAMPAIGN, Z.BATALLIA_DOWNS, Z.CRAWLERS_NEST } },
    { 30, 35, { Z.CRAWLERS_NEST, Z.GARLAIGE_CITADEL, Z.EASTERN_ALTEPA_DESERT } },
    { 35, 40, { Z.EASTERN_ALTEPA_DESERT, Z.GARLAIGE_CITADEL, Z.KUFTAL_TUNNEL } },
    { 40, 45, { Z.EASTERN_ALTEPA_DESERT, Z.KUFTAL_TUNNEL, Z.WESTERN_ALTEPA_DESERT } },
    { 45, 50, { Z.THE_BOYAHDA_TREE, Z.KUFTAL_TUNNEL, Z.WESTERN_ALTEPA_DESERT } },
    { 50, 55, { Z.THE_BOYAHDA_TREE, Z.CAPE_TERIGGAN, Z.KUFTAL_TUNNEL } },
    { 55, 60, { Z.CAPE_TERIGGAN, Z.THE_BOYAHDA_TREE, Z.VALLEY_OF_SORROWS } },
    { 60, 65, { Z.ATTOHWA_CHASM, Z.ULEGUERAND_RANGE, Z.CAPE_TERIGGAN } },
    { 65, 70, { Z.ULEGUERAND_RANGE, Z.ATTOHWA_CHASM, Z.VALLEY_OF_SORROWS } },
    { 70, 76, { Z.ULEGUERAND_RANGE, Z.VALLEY_OF_SORROWS, Z.ROMAEVE } },
}

-- Candidate zones for a bot of this nation and level, most preferred first.
function areas.candidates(nation, level)
    if level < 6 then
        return START[nation] or START[xi.nation.SANDORIA]
    end
    if level < 10 then
        local list = {}
        for _, z in ipairs(SECOND[nation] or {}) do
            table.insert(list, z)
        end
        for _, z in ipairs(START[nation] or {}) do
            table.insert(list, z)
        end
        return list
    end
    for _, band in ipairs(BANDS) do
        if level >= band[1] and level < band[2] then
            return band[3]
        end
    end
    return BANDS[#BANDS][3]
end

-- The nation's home city, where the bot's home point is after creation (character creation city).
areas.HOME =
{
    [xi.nation.SANDORIA] = Z.SOUTHERN_SAN_DORIA,
    [xi.nation.BASTOK]   = Z.BASTOK_MINES,
    [xi.nation.WINDURST] = Z.WINDURST_WOODS,
}

-- Monster levels worth hunting: solo stays at or below its level (Even Match and lower,
-- above Too Weak); a party takes Tough to Incredibly Tough, as 2006 parties did.
function areas.levelWindow(level, inParty)
    if inParty then
        return level, level + 4
    end
    if level <= 3 then
        return 1, level + 1
    end
    return math.max(1, level - 4), level
end

return areas
