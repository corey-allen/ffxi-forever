/*
===========================================================================

  FFXI-Forever world bots: population registry, decision log, travel data
  and the Lua functions the world brain (modules/worldbots/brain) uses.
  New for this server (not in Nate's fork): his bots had an owner and no
  life of their own.

  Tables (created here if missing):
  - worldbots      one row per bot: identity, personality, schedule, and the
                   brain's state (goal, plan) as JSON, so a restart resumes it;
  - worldbots_log  the decision and telemetry trail, one row per decision.

===========================================================================
*/

#include "worldbots.h"

#include "common/database.h"
#include "common/logging.h"
#include "common/lua.h"
#include "data/datasets/zones/settings/dataset.h"
#include "data/loader.h"
#include "entities/char_entity.h"
#include "party.h"
#include "lua/lua_base_entity.h"
#include "utils/zoneutils.h"
#include "zone.h"

#include <chrono>

namespace worldbots
{

namespace
{

auto asChar(CLuaBaseEntity* L) -> CCharEntity*
{
    auto* PEntity = L != nullptr ? L->GetBaseEntity() : nullptr;
    return PEntity != nullptr && PEntity->objtype == TYPE_PC ? static_cast<CCharEntity*>(PEntity) : nullptr;
}

} // namespace

void createTables()
{
    db::preparedStmt("CREATE TABLE IF NOT EXISTS worldbots ("
                     "charid INT UNSIGNED NOT NULL PRIMARY KEY, "
                     "nation TINYINT UNSIGNED NOT NULL, "
                     "race TINYINT UNSIGNED NOT NULL, "
                     "job TINYINT UNSIGNED NOT NULL, "
                     "personality VARCHAR(32) NOT NULL DEFAULT '', "
                     "schedule TEXT NOT NULL, "
                     "state MEDIUMTEXT NOT NULL, "
                     "enabled TINYINT UNSIGNED NOT NULL DEFAULT 1, "
                     "created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP"
                     ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
    db::preparedStmt("CREATE TABLE IF NOT EXISTS worldbots_log ("
                     "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, "
                     "charid INT UNSIGNED NOT NULL, "
                     "ts DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3), "
                     "kind VARCHAR(24) NOT NULL, "
                     "msg VARCHAR(512) NOT NULL, "
                     "KEY charid_ts (charid, ts), KEY kind_ts (kind, ts)"
                     ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
}

void registerRegistryLuaApi()
{
    // WorldbotRegistry() -> { { charId, name, nation, race, job, personality, schedule, state, enabled }, ... }
    ::lua.set_function("WorldbotRegistry", []() -> sol::table
    {
        sol::table out  = ::lua.create_table();
        const auto rset = db::preparedStmt("SELECT w.charid, c.charname, w.nation, w.race, w.job, w.personality, w.schedule, w.state, w.enabled "
                                           "FROM worldbots w JOIN chars c ON c.charid = w.charid ORDER BY w.charid");
        int        i    = 1;
        FOR_DB_MULTIPLE_RESULTS(rset)
        {
            sol::table row     = ::lua.create_table();
            row["charId"]      = rset->get<uint32>("charid");
            row["name"]        = rset->get<std::string>("charname");
            row["nation"]      = rset->get<uint8>("nation");
            row["race"]        = rset->get<uint8>("race");
            row["job"]         = rset->get<uint8>("job");
            row["personality"] = rset->get<std::string>("personality");
            row["schedule"]    = rset->get<std::string>("schedule");
            row["state"]       = rset->get<std::string>("state");
            row["enabled"]     = rset->get<uint8>("enabled") != 0;
            out[i++]           = row;
        }
        return out;
    });

    ::lua.set_function("WorldbotRegister", [](uint32 charId, uint8 nation, uint8 race, uint8 job, const std::string& personality, const std::string& schedule) -> bool
    {
        // (The DB layer refuses queries that contain "{}", so the empty JSON state is bound, not written inline.)
        return static_cast<bool>(db::preparedStmt("INSERT INTO worldbots (charid, nation, race, job, personality, schedule, state) VALUES (?, ?, ?, ?, ?, ?, ?) "
                                                  "ON DUPLICATE KEY UPDATE nation = VALUES(nation), race = VALUES(race), job = VALUES(job), "
                                                  "personality = VALUES(personality), schedule = VALUES(schedule)",
                                                  charId, nation, race, job, personality, schedule, std::string("{}")));
    });

    // World-bot characters without a registry row (created, then the registration failed or the server
    // stopped in between): { { charId, name, nation, race, job }, ... }, so they are adopted, not duplicated.
    ::lua.set_function("WorldbotOrphans", []() -> sol::table
    {
        sol::table out  = ::lua.create_table();
        const auto rset = db::preparedStmt("SELECT c.charid, c.charname, c.nation, l.race, s.mjob FROM chars c "
                                           "JOIN accounts a ON a.id = c.accid JOIN char_look l ON l.charid = c.charid "
                                           "JOIN char_stats s ON s.charid = c.charid "
                                           "LEFT JOIN worldbots w ON w.charid = c.charid "
                                           "WHERE a.password = ? AND w.charid IS NULL ORDER BY c.charid",
                                           kNoLoginPassword);
        int        i    = 1;
        FOR_DB_MULTIPLE_RESULTS(rset)
        {
            sol::table row = ::lua.create_table();
            row["charId"]  = rset->get<uint32>("charid");
            row["name"]    = rset->get<std::string>("charname");
            row["nation"]  = rset->get<uint8>("nation");
            row["race"]    = rset->get<uint8>("race");
            row["job"]     = rset->get<uint8>("mjob");
            out[i++]       = row;
        }
        return out;
    });

    ::lua.set_function("WorldbotSaveState", [](uint32 charId, const std::string& state) -> bool
    {
        return static_cast<bool>(db::preparedStmt("UPDATE worldbots SET state = ? WHERE charid = ?", state, charId));
    });

    ::lua.set_function("WorldbotSetEnabled", [](uint32 charId, bool enabled) -> bool
    {
        return static_cast<bool>(db::preparedStmt("UPDATE worldbots SET enabled = ? WHERE charid = ?", enabled ? 1 : 0, charId));
    });

    // The decision and telemetry trail: WorldbotLog(charId, kind, msg).
    ::lua.set_function("WorldbotLog", [](uint32 charId, const std::string& kind, const std::string& msg)
    {
        db::preparedStmt("INSERT INTO worldbots_log (charid, kind, msg) VALUES (?, ?, ?)", charId, kind.substr(0, 24), msg.substr(0, 512));
    });

    // Keep the trail bounded: rows older than `days` days are dropped.
    ::lua.set_function("WorldbotPruneLog", [](uint32 days)
    {
        db::preparedStmt("DELETE FROM worldbots_log WHERE ts < NOW() - INTERVAL ? DAY", days);
    });

    // WorldbotZoneLines(zoneId) -> { { id, x, y, z, toZone, tx, ty, tz }, ... } from the zone's data file
    // (the same records the zone loads), so routes can be planned without loading every zone.
    ::lua.set_function("WorldbotZoneLines", [](uint16 zoneId) -> sol::table
    {
        sol::table out      = ::lua.create_table();
        const auto settings = xi::data::loadZoneFile<xi::data::datasets::zones::settings::Dataset>(static_cast<xi::ZoneId>(zoneId));
        if (!settings)
        {
            return out;
        }
        int i = 1;
        for (const auto& line : settings->ZoneLines)
        {
            sol::table row = ::lua.create_table();
            row["id"]      = line.Id;
            row["x"]       = line.Origin.x;
            row["y"]       = line.Origin.y;
            row["z"]       = line.Origin.z;
            row["toZone"]  = static_cast<uint16>(line.DestinationZone);
            row["tx"]      = line.Destination.x;
            row["ty"]      = line.Destination.y;
            row["tz"]      = line.Destination.z;
            out[i++]       = row;
        }
        return out;
    });

    ::lua.set_function("WorldbotSpawnId", [](uint32 charId, sol::optional<uint16> zone, sol::optional<float> x, sol::optional<float> y,
                                             sol::optional<float> z, sol::optional<uint8> rot) -> sol::object
    {
        std::optional<Placement> at;
        if (zone.has_value())
        {
            at = Placement{ *zone, x.value_or(0.0f), y.value_or(0.0f), z.value_or(0.0f), rot.value_or(0) };
        }
        auto* PBot = spawn(charId, nullptr, at);
        return PBot != nullptr ? sol::make_object(::lua, CLuaBaseEntity(PBot)) : sol::make_object(::lua, sol::lua_nil);
    });

    ::lua.set_function("WorldbotDespawnId", [](uint32 charId) -> bool
    {
        return despawn(charId);
    });

    // A spawned bot by id, also while it is between zones (GetPlayerByID only finds characters in a zone).
    ::lua.set_function("WorldbotGet", [](uint32 charId) -> sol::object
    {
        auto* PChar = zoneutils::GetChar(charId);
        return PChar != nullptr && isBot(PChar) ? sol::make_object(::lua, CLuaBaseEntity(PChar)) : sol::make_object(::lua, sol::lua_nil);
    });

    ::lua.set_function("WorldbotIsOnline", [](uint32 charId) -> bool
    {
        const auto ids = bots();
        return std::ranges::find(ids, charId) != ids.end();
    });

    // { bots, zoning, tickCalls, tickUs } since the last call: what M7's load reports measure.
    ::lua.set_function("WorldbotStats", []() -> sol::table
    {
        sol::table out   = ::lua.create_table();
        const auto stats = takeTickStats();
        out["bots"]      = bots().size();
        out["tickCalls"] = stats.calls;
        out["tickUs"]    = stats.micros;
        out["maxTickUs"] = stats.maxMicros;
        out["zoneTicks"] = stats.zoneTicks;
        out["zoneGapMaxMs"] = stats.zoneGapMaxMs;
        out["zoneGapAvgMs"] = stats.zoneTicks > 0 ? stats.zoneGapSumMs / stats.zoneTicks : 0;
        return out;
    });

    sol::usertype<CLuaBaseEntity> E = ::lua["CBaseEntity"];

    // Touch a zone line: the zone-line packet (0x05E) for this bot. The bot must be within 40 yalms of it.
    E["worldbotUseZoneLine"] = [](CLuaBaseEntity* L, uint32 zoneLineId) -> bool
    {
        auto* PChar = asChar(L);
        return PChar != nullptr && isBot(PChar) && useZoneLine(PChar, zoneLineId);
    };

    // Nate's AI finds a headless bot's "primary" through getParentCharId; for world bots that is the
    // party leader (the bot itself when solo).
    E["worldbotSetParent"] = [](CLuaBaseEntity* L, uint32 parentCharId)
    {
        if (auto* st = state(asChar(L)))
        {
            st->parentCharId = parentCharId;
        }
    };

    // Leave the party (a last member's party is disbanded), as /pcmd leave does.
    E["worldbotLeaveParty"] = [](CLuaBaseEntity* L)
    {
        auto* PChar = asChar(L);
        if (PChar == nullptr || PChar->PParty == nullptr)
        {
            return;
        }
        if (PChar->PParty->members.size() <= 1)
        {
            PChar->PParty->DisbandParty();
        }
        else
        {
            PChar->PParty->RemoveMember(PChar);
        }
    };

    // Dead bot: return to the home point, as the death menu does.
    E["worldbotHomePoint"] = [](CLuaBaseEntity* L) -> bool
    {
        auto* PChar = asChar(L);
        return PChar != nullptr && isBot(PChar) && homePoint(PChar);
    };

    // A world bot's PAI listeners (Nate's MAGIC_USE, ENGAGE, ...) fire from the engine, outside the bot's
    // own Lua tick. Wrap them so the bot's party context (brain/context.lua) is active when they run.
    static sol::function wrapListener = ::lua.safe_script(
        "return function(id, fn) return function(...) "
        "local w = xi.worldbots if w and w.activateFor then w.activateFor(id) end "
        "return fn(...) end end");
    E["addListener"] = [](CLuaBaseEntity* L, const std::string& eventName, const std::string& identifier, const sol::function& func)
    {
        auto* PChar = asChar(L);
        if (PChar != nullptr && PChar->m_worldbot)
        {
            sol::function wrapped = wrapListener(PChar->id, func);
            L->addListener(eventName, identifier, wrapped);
            return;
        }
        L->addListener(eventName, identifier, func);
    };

    // Between zones (taken out of the old zone, not yet in the new one).
    E["worldbotIsZoning"] = [](CLuaBaseEntity* L) -> bool
    {
        auto* PChar = asChar(L);
        return PChar != nullptr && (PChar->loc.zone == nullptr || PChar->requestedZoneChange || PChar->requestedWarp != WarpRequest::None);
    };
}

} // namespace worldbots
