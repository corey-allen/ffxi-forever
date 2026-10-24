-----------------------------------
-- World brain settings. Edit here; restart the server to apply.
-----------------------------------
local config =
{
    -- Master switch for the world brain (schedules, goals, travel). Off = bots only spawn by GM command.
    ENABLED = true,

    -- Create the development population (6 jobs x 3 nations) on first start if it is missing.
    SEED_POPULATION = true,

    -- 'schedule': bots log in and out on their own schedules (production).
    -- 'always':   every enabled bot stays online (development and soak tests).
    SCHEDULE_MODE = 'always', -- SOAK: back to 'schedule' when the M3-M7 soak ends

    -- At most this many bots log in per world tick (2.4 s), so a restart does not stall the zone threads.
    MAX_LOGINS_PER_TICK = 2,

    -- Hard cap on bots online at once (M7 raises it step by step).
    MAX_ONLINE = 1000,

    -- How often each bot's brain state is written to the worldbots table, in seconds.
    STATE_SAVE_SECONDS = 60,

    -- Decision-log retention, in days.
    LOG_PRUNE_DAYS = 14,

    -- The development population: the six starting jobs in each nation (owner decision).
    SEED_JOBS = { xi.job.WAR, xi.job.MNK, xi.job.THF, xi.job.WHM, xi.job.BLM, xi.job.RDM },
    SEED_NATIONS = { xi.nation.SANDORIA, xi.nation.BASTOK, xi.nation.WINDURST },

    -- Bots of one nation that are online and within this many levels form a party (M4).
    PARTY_LEVEL_SPREAD = 3,
    PARTY_MIN_LEVEL = 10, -- solo below this, as players did in 2006

    -- Rest before the next fight when below these (out of combat), stand at full.
    REST_HPP = 80,
    REST_MPP = 60,

    -- Seconds a dead bot waits (for a raise that a party member may cast) before returning home.
    HOMEPOINT_AFTER_SECONDS = 60,
}

return config
