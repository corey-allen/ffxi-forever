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
#include "map_engine.h"
#include "map_networking.h"
#include "map_session.h"
#include "map_session_container.h"
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

auto spawn(uint32 charId, CCharEntity* parent) -> CCharEntity*
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

    // Party broadcasts join over accounts_sessions; without a row headless members are skipped (Nate's note).
    // server_addr/port 0: no socket to route to. client_addr 0 marks the row as synthetic.
    db::preparedStmt("REPLACE INTO accounts_sessions (accid, charid, server_addr, server_port, client_addr, version_mismatch) VALUES (?, ?, 0, 0, 0, 0)",
                     PChar->accid, charId);

    if (parent != nullptr)
    {
        PChar->loc.destination = parent->getZone();
        PChar->loc.p           = parent->loc.p;
    }
    // WORLDBOTS: ownerless bots keep LoadChar's saved zone and position.

    if (PChar->health.hp == 0) // never spawn into an immediate death loop (Nate)
    {
        PChar->health.hp = PChar->GetMaxHP();
        PChar->health.mp = PChar->GetMaxMP();
    }

    const auto destination = static_cast<xi::ZoneId>(PChar->loc.destination);
    zoneutils::EnsureZoneLoaded(engine->scheduler(), engine->config(), destination);
    CZone* PZone = zoneutils::GetZone(destination);
    if (PZone == nullptr)
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

    PZone->IncreaseZoneCounter(PChar);
    PChar->status     = xi::Status::Normal;
    PChar->m_worldbot = true;
    PChar->PAI->PathFind = std::make_unique<CPathFind>(PChar); // server-driven movement (core patch: ai_container)
    PChar->clearPacketList();

    // Same post-zone-in step as a real character, then drop what it pushes (no client to read it).
    PChar->PAI->QueueAction(queueAction_t(4000ms, false, zoneutils::AfterZoneIn));
    PChar->PAI->QueueAction(queueAction_t(4100ms, false, [](CBaseEntity* PEntity) { static_cast<CCharEntity*>(PEntity)->clearPacketList(); }));

    g_nextPersist[charId] = std::chrono::steady_clock::now() + kPersistEvery + std::chrono::seconds(charId % 30);
    st.spawnFinalized     = true;

    ShowInfoFmt("[worldbots] spawned {} (charId {}) in zone {}{}", PChar->getName(), charId, static_cast<uint16>(destination),
                parent != nullptr ? fmt::format(" beside {}", parent->getName()) : std::string(" (ownerless)"));
    return PChar;
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
        auto result = onBotTick(CLuaBaseEntity(PChar), static_cast<uint8>(state(PChar)->botMode));
        if (!result.valid())
        {
            sol::error err = result;
            ShowErrorFmt("[worldbots] onBotTick({}): {}", PChar->getName(), err.what());
        }
    }
}

void cleanupOnStartup()
{
    // Synthetic session rows a crash left behind (client_addr 0 and no server): no bot is online at startup.
    db::preparedStmt("DELETE FROM accounts_sessions WHERE client_addr = 0 AND server_addr = 0 AND server_port = 0");
}

} // namespace worldbots
