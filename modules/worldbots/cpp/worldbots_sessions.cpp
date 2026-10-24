/*
===========================================================================

  FFXI-Forever world bots: headless sessions and the bot tick.

  Session creation follows Nate's createHeadlessSession
  (NatePillow/LandSandBoat@1982bfd348, src/map/singleplayer/bot_sessions.cpp, GPL-3.0),
  ported to Phoenix's public session API. WORLDBOTS: ownerless bots spawn at their own
  saved position; the module (not CCharEntity::Tick) drives the Lua tick.

===========================================================================
*/

#include "worldbots.h"

#include "ai/ai_container.h"
#include "ai/helpers/pathfind/pathfind.h"
#include "common/blowfish.h"
#include "common/database.h"
#include "common/logging.h"
#include "common/lua.h"
#include "common/settings.h"
#include "entities/char_entity.h"
#include "lua/lua_base_entity.h"
#include "lua/luautils.h"
#include "map_engine.h"
#include "map_networking.h"
#include "map_session.h"
#include "map_session_container.h"
#include "packets/c2s/0x00a_login.h"
#include "packets/c2s/0x05e_maprect.h"
#include "persist_batch.h"
#include "utils/charutils.h"
#include "utils/zoneutils.h"
#include "worldbots_hooks.h"
#include "zone.h"

#include <algorithm>
#include <chrono>
#include <map>

using namespace std::chrono_literals;

namespace worldbots
{

namespace
{

std::map<uint32, BotState> g_state; // charId -> state, spawned bots only
TickStats                  g_tickStats;

constexpr auto kPersistEvery = 60s;
std::map<uint32, std::chrono::steady_clock::time_point> g_nextPersist;

auto sessions() -> MapSessionContainer&
{
    return engine->networking().sessions();
}

// Synthetic client address: IP 0.0.0.x is never a real client, and the char id keeps it unique (Nate's scheme).
auto syntheticIpp(uint32 charId) -> IPP
{
    return IPP(charId >> 16, static_cast<uint16>(charId & 0xFFFF));
}

} // namespace

auto spawn(uint32 charId, CCharEntity* parent, std::optional<Placement> at) -> CCharEntity*
{
    if (engine == nullptr)
    {
        return nullptr;
    }
    if (sessions().getSessionByCharId(charId) != nullptr || sessions().getSessionByIPP(syntheticIpp(charId)) != nullptr)
    {
        ShowWarningFmt("[worldbots] spawn: charId {} is already online", charId);
        return nullptr;
    }
    if (parent != nullptr && parent->loc.zone == nullptr)
    {
        ShowWarningFmt("[worldbots] spawn: parent of charId {} is not in a zone", charId);
        return nullptr;
    }

    auto PCharOwned = charutils::LoadChar(charId);
    if (PCharOwned == nullptr)
    {
        ShowWarningFmt("[worldbots] spawn: LoadChar failed for charId {}", charId);
        return nullptr;
    }

    MapSession* session = sessions().createSession(syntheticIpp(charId));
    if (session == nullptr)
    {
        ShowWarningFmt("[worldbots] spawn: could not create a session for charId {}", charId);
        return nullptr;
    }
    session->charID          = charId;
    session->accountID       = PCharOwned->accid;
    session->blowfish.status = BLOWFISH_ACCEPTED;
    session->PChar           = std::move(PCharOwned);
    CCharEntity* PChar       = session->PChar.get();
    PChar->PSession          = session;
    session->tapLastUpdate();

    // Party broadcasts and /sea join over accounts_sessions; without a row headless members are skipped
    // (Nate's note). The login handler's updateSession fills in the zone server address.
    db::preparedStmt("REPLACE INTO accounts_sessions (accid, charid, server_addr, server_port, client_addr, version_mismatch) VALUES (?, ?, 0, 0, 0, 0)",
                     PChar->accid, charId);

    if (parent != nullptr)
    {
        PChar->loc.destination = parent->getZone();
        PChar->loc.p           = parent->loc.p;
    }
    else if (at.has_value())
    {
        PChar->loc.destination = static_cast<xi::ZoneId>(at->zone);
        PChar->loc.p           = position_t{ at->x, at->y, at->z, 0, at->rot };
    }
    // WORLDBOTS: otherwise ownerless bots keep LoadChar's saved zone and position.
    if (static_cast<uint16>(PChar->loc.destination) == 0 || static_cast<uint16>(PChar->loc.destination) >= MAX_ZONEID)
    {
        // A saved position no zone can take (an interrupted zone change): wake up at the home point.
        ShowWarningFmt("[worldbots] spawn: {} saved in zone {}; using the home point", PChar->getName(), static_cast<uint16>(PChar->loc.destination));
        PChar->loc.destination = PChar->profile.home_point.destination;
        PChar->loc.p           = PChar->profile.home_point.p;
    }

    if (PChar->health.hp == 0) // never spawn into an immediate death loop (Nate)
    {
        PChar->health.hp = PChar->GetMaxHP();
        PChar->health.mp = PChar->GetMaxMP();
    }

    const auto destination = static_cast<xi::ZoneId>(PChar->loc.destination);
    zoneutils::EnsureZoneLoaded(engine->scheduler(), engine->config(), destination);
    if (zoneutils::GetZone(destination) == nullptr)
    {
        ShowWarningFmt("[worldbots] spawn: zone {} for charId {} is not available", static_cast<uint16>(destination), charId);
        db::preparedStmt("DELETE FROM accounts_sessions WHERE charid = ?", charId);
        sessions().destroySession(session);
        return nullptr;
    }

    BotState& st      = g_state[charId];
    st                = BotState{};
    st.parentCharId   = parent != nullptr ? parent->id : 0;
    st.spawnFinalized = false; // no Lua tick against a half-wired entity (Nate's m_spawnFinalized)

    PChar->m_worldbot    = true;
    PChar->PAI->PathFind = std::make_unique<CPathFind>(PChar); // server-driven movement (core patch: ai_container)

    // WORLDBOTS: enter the world through the login packet's own handler (0x00A), as a client does after
    // the lobby. It places the character in the zone and runs OnZoneIn and OnGameIn; on the first login of a
    // new character OnGameIn runs xi.player.charCreate (starting gear, gil, title).
    const bool firstLogin    = charutils::hasTitle(PChar, 206) == 0; // 206 = NEW_ADVENTURER, the check OnGameIn uses
    session->blowfish.status = BLOWFISH_WAITING;
    if (!arrive(PChar))
    {
        ShowWarningFmt("[worldbots] spawn: {} could not enter zone {}", PChar->getName(), static_cast<uint16>(destination));
        g_state.erase(charId);
        db::preparedStmt("DELETE FROM accounts_sessions WHERE charid = ?", charId);
        sessions().destroySession(session);
        return nullptr;
    }
    if (firstLogin)
    {
        // The intro cutscene's reward, which charCreate leaves to the cutscene when it is enabled.
        sol::protected_function onFirstSpawn = ::lua["xi"]["worldbots"]["onFirstSpawn"];
        if (onFirstSpawn.valid())
        {
            onFirstSpawn(CLuaBaseEntity(PChar));
        }
        PChar->SetPlayTime(std::chrono::seconds(1));
        charutils::SavePlayTime(PChar);
        persist::flush(PChar, IsLogout::No);
    }

    g_nextPersist[charId] = std::chrono::steady_clock::now() + kPersistEvery + std::chrono::seconds(charId % 30);
    st.spawnFinalized     = true;

    ShowInfoFmt("[worldbots] spawned {} (charId {}) in zone {}{}", PChar->getName(), charId, static_cast<uint16>(destination),
                parent != nullptr ? fmt::format(" beside {}", parent->getName()) : std::string(" (ownerless)"));
    return PChar;
}

auto arrive(CCharEntity* PChar) -> bool
{
    GP_CLI_COMMAND_LOGIN packet{};
    packet.UniqueNo = PChar->id;
    packet.process(PChar->PSession, PChar);
    if (PChar->loc.zone == nullptr)
    {
        return false;
    }
    if (PChar->currentEvent->eventId >= 0)
    {
        // Nobody watches a headless cutscene: drop it rather than leave the bot locked in an event.
        ShowInfoFmt("[worldbots] {}: skipped zone-in cutscene {}", PChar->getName(), PChar->currentEvent->eventId);
        PChar->currentEvent->reset();
        PChar->m_isPCHidden = false;
        PChar->setLocked(false);
    }
    PChar->clearPacketList();
    PChar->PSession->tapLastUpdate();
    // The handler queues AfterZoneIn at 4 s; drop what it pushes right after.
    PChar->PAI->QueueAction(queueAction_t(4100ms, false, [](CBaseEntity* PEntity) { static_cast<CCharEntity*>(PEntity)->clearPacketList(); }));
    return true;
}

auto takeTickStats() -> TickStats
{
    return std::exchange(g_tickStats, TickStats{});
}

void processArrivals()
{
    // Called from every zone tick; once per 100 ms is plenty.
    static auto nextRun = std::chrono::steady_clock::time_point{};
    const auto  now     = std::chrono::steady_clock::now();
    if (now < nextRun)
    {
        return;
    }
    nextRun = now + 100ms;

    // A zoning bot is in no zone, so no zone tick reaches it: keep its session alive and, once the
    // engine has taken it out of the old zone (blowfish pending zone, as for a client), do what the
    // server does when the client reconnects (map_networking.cpp): load the character afresh from the
    // database, then log it into the new zone through the login handler.
    std::vector<uint32> ready;
    for (const auto& [charId, st] : g_state)
    {
        MapSession* session = sessions().getSessionByCharId(charId);
        if (session == nullptr || session->PChar == nullptr || session->PChar->loc.zone != nullptr)
        {
            continue;
        }
        session->tapLastUpdate();
        if (session->blowfish.status == BLOWFISH_PENDING_ZONE)
        {
            ready.push_back(charId);
        }
    }

    for (const auto charId : ready)
    {
        MapSession* session = sessions().getSessionByCharId(charId);
        session->PChar.reset();
        auto PCharOwned = charutils::LoadChar(charId);
        if (PCharOwned == nullptr)
        {
            ShowWarningFmt("[worldbots] charId {}: LoadChar failed after zoning; logging the bot out", charId);
            g_state.erase(charId);
            g_nextPersist.erase(charId);
            db::preparedStmt("DELETE FROM accounts_sessions WHERE charid = ?", charId);
            sessions().destroySession(session);
            continue;
        }
        session->PChar       = std::move(PCharOwned);
        CCharEntity* PChar   = session->PChar.get();
        PChar->PSession      = session;
        PChar->m_worldbot    = true;
        PChar->PAI->PathFind = std::make_unique<CPathFind>(PChar);

        zoneutils::EnsureZoneLoaded(engine->scheduler(), engine->config(), PChar->loc.destination);
        if (!arrive(PChar))
        {
            ShowWarningFmt("[worldbots] {} could not enter zone {}", PChar->getName(), static_cast<uint16>(PChar->loc.destination));
            continue;
        }
        const auto from = static_cast<uint16>(PChar->loc.prevzone); // saved by the engine's zone change
        ShowInfoFmt("[worldbots] {} zoned {} -> {}", PChar->getName(), from, static_cast<uint16>(PChar->getZone()));

        // The Lua side holds the old entity: let the brain rebuild what refers to it.
        sol::protected_function onArrive = ::lua["xi"]["worldbots"]["onArrive"];
        if (onArrive.valid())
        {
            auto result = onArrive(CLuaBaseEntity(PChar), from);
            if (!result.valid())
            {
                sol::error err = result;
                ShowErrorFmt("[worldbots] onArrive({}): {}", PChar->getName(), err.what());
            }
        }
    }
}

auto useZoneLine(CCharEntity* PChar, uint32 zoneLineId) -> bool
{
    if (PChar == nullptr || PChar->loc.zone == nullptr || PChar->loc.zone->GetZoneLine(zoneLineId) == nullptr)
    {
        return false;
    }
    // The packet a client sends on touching the zone line (0x05E); the handler checks distance and the destination.
    GP_CLI_COMMAND_MAPRECT packet{};
    packet.RectID   = zoneLineId;
    packet.x        = PChar->loc.p.x;
    packet.y        = PChar->loc.p.y;
    packet.z        = PChar->loc.p.z;
    packet.ActIndex = PChar->targid;
    packet.process(PChar->PSession, PChar);
    return PChar->requestedZoneChange;
}

auto homePoint(CCharEntity* PChar) -> bool
{
    if (PChar == nullptr || !PChar->isDead())
    {
        return false;
    }
    // What the death menu's "Return to home point" does (0x01A HomepointMenu).
    PChar->setCharVar("expLost", 0);
    PChar->requestedWarp = WarpRequest::HomePoint;
    return true;
}

auto despawn(uint32 charId) -> bool
{
    if (engine == nullptr || !g_state.contains(charId))
    {
        return false;
    }
    g_state.erase(charId);
    g_nextPersist.erase(charId);
    MapSession* session = sessions().getSessionByCharId(charId);
    if (session == nullptr)
    {
        return false;
    }
    if (session->PChar != nullptr)
    {
        if (session->PChar->loc.zone != nullptr)
        {
            sol::protected_function onBotDespawn = ::lua["xi"]["singleplayer"]["bots"]["onBotDespawn"];
            if (onBotDespawn.valid())
            {
                auto result = onBotDespawn(CLuaBaseEntity(session->PChar.get()));
                if (!result.valid())
                {
                    sol::error err = result;
                    ShowErrorFmt("[worldbots] onBotDespawn: {}", err.what());
                }
            }
        }
        session->PChar->status = xi::Status::Shutdown;
        charutils::removeCharFromZone(session->PChar.get()); // persists position and effects
    }
    db::preparedStmt("DELETE FROM accounts_sessions WHERE charid = ?", charId);
    sessions().destroySession(session);
    ShowInfoFmt("[worldbots] despawned charId {}", charId);
    return true;
}

auto isBot(const CCharEntity* PChar) -> bool
{
    return PChar != nullptr && g_state.contains(PChar->id);
}

auto state(const CCharEntity* PChar) -> BotState*
{
    if (PChar == nullptr)
    {
        return nullptr;
    }
    const auto it = g_state.find(PChar->id);
    return it == g_state.end() ? nullptr : &it->second;
}

auto bots() -> std::vector<uint32>
{
    std::vector<uint32> out;
    for (const auto& [id, st] : g_state)
    {
        out.push_back(id);
    }
    return out;
}

void tickZoneBots(CZone* PZone)
{
    if (g_state.empty() || PZone == nullptr)
    {
        return;
    }
    const auto now = std::chrono::steady_clock::now();

    std::vector<CCharEntity*> due;
    PZone->ForEachChar(
        [&](CCharEntity* PChar)
        {
            auto* st = state(PChar);
            if (st == nullptr || !st->spawnFinalized || PChar->PSession == nullptr)
            {
                return;
            }
            // Headless housekeeping (Nate's post_tick): keep the session alive, drop packets nobody reads,
            // and mark the position dirty so the engine's persist sweep saves it.
            PChar->PSession->tapLastUpdate();
            PChar->clearPacketList();
            if (now >= g_nextPersist[PChar->id])
            {
                g_nextPersist[PChar->id] = now + kPersistEvery;
                PChar->setPersist(CharPersist::Position | CharPersist::Effects | CharPersist::Equip);
            }
            due.push_back(PChar);
        });

    // Role order within the zone (healers resolve first), replacing Nate's zone-tick sort.
    std::stable_sort(due.begin(), due.end(), [](const CCharEntity* a, const CCharEntity* b) { return state(a)->tickPriority < state(b)->tickPriority; });

    sol::protected_function onBotTick = ::lua["xi"]["singleplayer"]["bots"]["onBotTick"];
    if (!onBotTick.valid())
    {
        return;
    }
    for (auto* PChar : due)
    {
        const auto started = std::chrono::steady_clock::now();
        auto       result  = onBotTick(CLuaBaseEntity(PChar), static_cast<uint8>(state(PChar)->botMode));
        const auto micros  = static_cast<uint64>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - started).count());
        g_tickStats.calls++;
        g_tickStats.micros += micros;
        g_tickStats.maxMicros = std::max(g_tickStats.maxMicros, micros);
        if (!result.valid())
        {
            sol::error err = result;
            ShowErrorFmt("[worldbots] onBotTick({}): {}", PChar->getName(), err.what());
        }
    }
}

void cleanupOnStartup()
{
    // Session rows of world-bot accounts a crash left behind: no bot is online at startup.
    db::preparedStmt("DELETE FROM accounts_sessions WHERE accid IN (SELECT id FROM accounts WHERE password = ?)", kNoLoginPassword);
}

} // namespace worldbots
