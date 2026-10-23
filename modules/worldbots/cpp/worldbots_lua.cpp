/*
===========================================================================

  FFXI-Forever world bots: the engine API Nate's bot Lua calls.

  Ports of the CLuaBaseEntity additions and Lua globals from
  NatePillow/LandSandBoat@1982bfd348 (src/map/singleplayer/lua_bindings.cpp,
  lua_hooks.cpp, lua/lua_baseentity.cpp, lua/luautils.cpp; GPL-3.0,
  "Single Player Dev Teams"), registered onto Phoenix's existing usertypes from
  this module instead of being compiled into the core. WORLDBOTS differences:
  - isHeadless() is true for every world bot (owned or ownerless);
  - raycastClampTo/raycastClear use navmesh moveAlongSurface (Phoenix has no raycast);
  - addon-only pushes (log, DPS, party status, puller names, state snapshot) go to the
    server log instead of Ashita v3 packets;
  - summonTrustDirect is absent (no trusts on this server).

===========================================================================
*/

#include "worldbots.h"

#include "action/action.h"
#include "ai/ai_container.h"
#include "ai/helpers/pathfind/pathfind.h"
#include "ai/states/ability_state.h"
#include "ai/states/magic_state.h"
#include "ai/states/range_state.h"
#include "ai/states/weaponskill_state.h"
#include "alliance.h"
#include "common/database.h"
#include "common/logging.h"
#include "common/lua.h"
#include "common/settings.h"
#include "entities/char_entity.h"
#include "entities/mob_entity.h"
#include "item_container.h"
#include "items/item_equipment.h"
#include "lua/lua_base_entity.h"
#include "lua/lua_statuseffect.h"
#include "navmesh/navmesh.h"
#include "packets/c2s/0x03a_item_stack.h"
#include "party.h"
#include "spell.h"
#include "status_effect.h"
#include "status_effect_container.h"
#include "treasure_pool.h"
#include "utils/battleutils.h"
#include "utils/charutils.h"
#include "utils/zoneutils.h"
#include "weapon_skill.h"
#include "worldbots_hooks.h"
#include "zone.h"

#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <tuple>

using namespace std::chrono_literals;

namespace worldbots
{

namespace
{

auto asChar(CLuaBaseEntity* L) -> CCharEntity*
{
    return L != nullptr ? dynamic_cast<CCharEntity*>(L->GetBaseEntity()) : nullptr;
}

auto entityOf(const sol::object& target) -> CBaseEntity*
{
    if (target != sol::lua_nil && target.is<CLuaBaseEntity*>())
    {
        return target.as<CLuaBaseEntity*>()->GetBaseEntity();
    }
    return nullptr;
}

template <typename TState>
auto inState(CLuaBaseEntity* L) -> bool
{
    auto* PEntity = L != nullptr ? L->GetBaseEntity() : nullptr;
    return PEntity != nullptr && PEntity->PAI != nullptr && PEntity->PAI->IsCurrentState<TState>();
}

// Nate's ConsolidateContainerStacks was the server-side 0x03A sort. WORLDBOTS: run the server's own 0x03A handler instead
// (the packet a client sends), so the bot gets exactly the player behaviour, anti-spam check included.
void consolidateStacks(CCharEntity* PChar, uint8 location)
{
    if (PChar == nullptr || PChar->PSession == nullptr || PChar->getStorage(location) == nullptr)
    {
        return;
    }
    GP_CLI_COMMAND_ITEM_STACK packet{};
    packet.Category = location;
    packet.process(PChar->PSession, PChar);
}

// GetServerConfig(category, name) -> body, mtime. Nate cached these in C++; we read modules/worldbots/config/<category>/<name>.json|.xml.
auto getServerConfig(const std::string& category, const std::string& name) -> std::tuple<sol::object, int64_t>
{
    if (category.find_first_of("/\\.") != std::string::npos || name.find_first_of("/\\") != std::string::npos || name.find("..") != std::string::npos)
    {
        return { sol::lua_nil, 0 };
    }
    for (const char* ext : { ".json", ".xml" })
    {
        const std::filesystem::path path = std::filesystem::path("modules/worldbots/config") / category / (name + ext);
        std::error_code             ec;
        if (!std::filesystem::is_regular_file(path, ec))
        {
            continue;
        }
        std::ifstream      in(path, std::ios::binary);
        std::ostringstream body;
        body << in.rdbuf();
        const auto mtime = std::chrono::duration_cast<std::chrono::seconds>(std::filesystem::last_write_time(path, ec).time_since_epoch()).count();
        return { sol::make_object(::lua, body.str()), static_cast<int64_t>(mtime) };
    }
    return { sol::lua_nil, 0 };
}

void logPush(CLuaBaseEntity* L, const std::string& tag, const std::string& msg)
{
    auto* PChar = asChar(L);
    ShowDebugFmt("[worldbots] {} [{}] {}", PChar != nullptr ? PChar->getName() : std::string("?"), tag, msg);
}

void dispatchActionResult(const action_t& action)
{
    sol::protected_function dispatcher = ::lua["xi"]["singleplayer"]["bots"]["onActionResult"];
    if (!dispatcher.valid())
    {
        return;
    }
    CBaseEntity* PActor = zoneutils::GetEntity(action.actorId);
    if (PActor == nullptr)
    {
        return;
    }
    // Same table shape as Nate's luautils::OnActionResult.
    sol::table tbl    = ::lua.create_table();
    tbl["actorId"]    = action.actorId;
    tbl["actiontype"] = static_cast<uint8_t>(action.actiontype);
    tbl["actionid"]   = action.actionid;
    sol::table targets = ::lua.create_table();
    int        ti      = 1;
    for (const auto& target : action.targets)
    {
        sol::table t   = ::lua.create_table();
        t["actorId"]   = target.actorId;
        sol::table rs  = ::lua.create_table();
        int        ri  = 1;
        for (const auto& result : target.results)
        {
            sol::table r          = ::lua.create_table();
            r["param"]            = result.param;
            r["messageID"]        = static_cast<uint16_t>(result.messageID);
            r["spikesParam"]      = result.spikesParam;
            r["spikesMessage"]    = static_cast<uint16_t>(result.spikesMessage);
            r["addEffectParam"]   = result.addEffectParam;
            r["addEffectMessage"] = static_cast<uint16_t>(result.addEffectMessage);
            rs[ri++]              = r;
        }
        t["results"]   = rs;
        targets[ti++]  = t;
    }
    tbl["targets"] = targets;
    auto res       = dispatcher(CLuaBaseEntity(PActor), tbl);
    if (!res.valid())
    {
        sol::error err = res;
        ShowErrorFmt("[worldbots] onActionResult: {}", err.what());
    }
}

void dispatchMobSkillStart(CBaseEntity* PActor, std::chrono::milliseconds castTime)
{
    sol::protected_function dispatcher = ::lua["xi"]["singleplayer"]["bots"]["onMobSkillStart"];
    if (!dispatcher.valid() || PActor == nullptr)
    {
        return;
    }
    auto res = dispatcher(CLuaBaseEntity(PActor), static_cast<int32>(castTime.count()));
    if (!res.valid())
    {
        sol::error err = res;
        ShowErrorFmt("[worldbots] onMobSkillStart: {}", err.what());
    }
}

} // namespace

void registerLuaApi()
{
    worldbots::onActionResult  = &dispatchActionResult;
    worldbots::onMobSkillStart = &dispatchMobSkillStart;

    sol::usertype<CLuaBaseEntity> E = ::lua["CBaseEntity"];

    // ---- actions (Nate: lua_bindings.cpp) -------------------------------------------------------------------------
    E["weaponSkill"] = [](CLuaBaseEntity* L, uint16 wsId, const sol::object& target)
    {
        CBaseEntity* PTarget = entityOf(target);
        if (PTarget == nullptr)
        {
            return;
        }
        const EntityId id(PTarget);
        L->GetBaseEntity()->PAI->QueueAction(queueAction_t(0ms, true, [id, wsId](CBaseEntity* PEntity) { PEntity->PAI->WeaponSkill(id, wsId); }));
        L->GetBaseEntity()->PAI->checkQueueImmediately();
    };
    E["rangedAttack"] = [](CLuaBaseEntity* L, const sol::object& target)
    {
        CBaseEntity* PTarget = entityOf(target);
        if (PTarget == nullptr)
        {
            return;
        }
        const EntityId id(PTarget);
        L->GetBaseEntity()->PAI->QueueAction(queueAction_t(0ms, true, [id](CBaseEntity* PEntity) { PEntity->PAI->RangedAttack(id); }));
        L->GetBaseEntity()->PAI->checkQueueImmediately();
    };
    E["useItem"] = [](CLuaBaseEntity* L, uint8 location, uint8 slotId, const sol::object& target)
    {
        CBaseEntity* PTarget = entityOf(target);
        if (PTarget == nullptr)
        {
            return;
        }
        const EntityId id(PTarget);
        L->GetBaseEntity()->PAI->QueueAction(queueAction_t(0ms, true, [id, location, slotId](CBaseEntity* PEntity) { PEntity->PAI->UseItem(id, location, slotId); }));
        L->GetBaseEntity()->PAI->checkQueueImmediately();
    };

    // ---- bot state (WORLDBOTS: held by the module, not CCharEntity) ------------------------------------------------
    E["isHeadless"]      = [](CLuaBaseEntity* L) { return isBot(asChar(L)); };
    E["getParentCharId"] = [](CLuaBaseEntity* L) -> uint32
    {
        auto* st = state(asChar(L));
        return st != nullptr ? st->parentCharId : 0;
    };
    E["getBotMode"] = [](CLuaBaseEntity* L) -> uint8
    {
        auto* st = state(asChar(L));
        return st != nullptr ? static_cast<uint8>(st->botMode) : 0;
    };
    E["setBotMode"] = [](CLuaBaseEntity* L, uint8 mode)
    {
        if (auto* st = state(asChar(L)); st != nullptr && mode <= static_cast<uint8>(BotMode::MovementOnly))
        {
            st->botMode = static_cast<BotMode>(mode);
        }
    };
    E["setBotTickPriority"] = [](CLuaBaseEntity* L, uint8 priority)
    {
        if (auto* st = state(asChar(L)))
        {
            st->tickPriority = priority;
        }
    };
    // Recorded for Nate's Lua; WORLDBOTS gives it no effect: monsters always treat bots like players.
    E["getAggroMode"] = [](CLuaBaseEntity* L) -> uint8
    {
        auto* st = state(asChar(L));
        return st != nullptr ? st->aggroMode : 1;
    };
    E["setAggroMode"] = [](CLuaBaseEntity* L, uint8 mode)
    {
        if (auto* st = state(asChar(L)))
        {
            st->aggroMode = mode;
        }
    };
    // No client drives a bot, so there is never recent player movement input.
    E["getLastClientMoveInputMs"] = [](CLuaBaseEntity*) { return std::numeric_limits<uint32>::max(); };

    // ---- spawning, parties, alliances ----------------------------------------------------------------------------
    E["spawnHeadless"] = [](CLuaBaseEntity* L, const std::string& name, uint8 /*spawnIndex*/) -> sol::object
    {
        auto* PParent = asChar(L);
        if (PParent == nullptr || name.empty() || zoneutils::GetCharByName(name) != nullptr)
        {
            return sol::lua_nil;
        }
        const auto rset = db::preparedStmt("SELECT charid FROM chars WHERE charname = ? LIMIT 1", name);
        if (!rset || !rset->next())
        {
            ShowWarningFmt("[worldbots] spawnHeadless: unknown character '{}'", name);
            return sol::lua_nil;
        }
        const auto charId = rset->get<uint32>("charid");
        if (charId == PParent->id)
        {
            return sol::lua_nil;
        }
        auto* PBot = spawn(charId, PParent);
        return PBot != nullptr ? sol::make_object(::lua, CLuaBaseEntity(PBot)) : sol::lua_nil;
    };
    E["destroyAsHeadless"] = [](CLuaBaseEntity* L)
    {
        if (auto* PChar = asChar(L); isBot(PChar))
        {
            despawn(PChar->id);
        }
    };
    E["formAllianceFromSpec"] = [](CLuaBaseEntity*, sol::table spec) -> bool
    {
        struct Slot
        {
            CCharEntity*              leader = nullptr;
            std::vector<CCharEntity*> members;
        };
        std::vector<Slot> slots;
        for (size_t i = 1; i <= 3; ++i) // resolve everything first: fail closed before changing anything (Nate)
        {
            sol::object entry = spec[i];
            if (!entry.valid() || !entry.is<sol::table>())
            {
                break;
            }
            sol::table  party      = entry.as<sol::table>();
            std::string leaderName = party.get_or<std::string>("leader", "");
            Slot        slot;
            slot.leader = leaderName.empty() ? nullptr : zoneutils::GetCharByName(leaderName);
            if (slot.leader == nullptr || slot.leader->PParty != nullptr)
            {
                ShowWarningFmt("[worldbots] formAllianceFromSpec: leader '{}' missing or already in a party", leaderName);
                return false;
            }
            sol::object members = party["members"];
            if (members.valid() && members.is<sol::table>())
            {
                sol::table list = members.as<sol::table>();
                for (size_t m = 1; m <= 5; ++m)
                {
                    sol::object nameObj = list[m];
                    if (!nameObj.valid())
                    {
                        break;
                    }
                    auto* PMember = zoneutils::GetCharByName(nameObj.as<std::string>());
                    if (PMember == nullptr || PMember->PParty != nullptr)
                    {
                        ShowWarningFmt("[worldbots] formAllianceFromSpec: member '{}' missing or already in a party", nameObj.as<std::string>());
                        return false;
                    }
                    slot.members.push_back(PMember);
                }
            }
            slots.push_back(std::move(slot));
        }
        if (slots.empty())
        {
            return false;
        }
        for (auto& slot : slots)
        {
            slot.leader->PParty = new CParty(slot.leader);
            for (auto* PMember : slot.members)
            {
                slot.leader->PParty->AddMember(PMember);
            }
        }
        if (slots.size() > 1)
        {
            slots[0].leader->PParty->m_PAlliance = new CAlliance(slots[0].leader);
            for (size_t s = 1; s < slots.size(); ++s)
            {
                slots[0].leader->PParty->m_PAlliance->addParty(slots[s].leader->PParty);
            }
        }
        return true;
    };
    E["formPartyAlone"] = [](CLuaBaseEntity* L)
    {
        if (auto* PChar = asChar(L); PChar != nullptr && PChar->PParty == nullptr)
        {
            PChar->PParty = new CParty(PChar);
        }
    };
    E["partyAddMember"] = [](CLuaBaseEntity* L, CLuaBaseEntity* other)
    {
        auto* PSelf  = asChar(L);
        auto* POther = asChar(other);
        if (PSelf == nullptr || POther == nullptr || PSelf->PParty == nullptr || POther->PParty != nullptr || PSelf->PParty->IsFull())
        {
            return;
        }
        PSelf->PParty->AddMember(POther);
    };
    E["partyRemoveMember"] = [](CLuaBaseEntity* L, CLuaBaseEntity* other)
    {
        auto* PSelf  = asChar(L);
        auto* POther = asChar(other);
        if (PSelf != nullptr && POther != nullptr && PSelf->PParty != nullptr && POther->PParty == PSelf->PParty)
        {
            PSelf->PParty->RemoveMember(POther);
        }
    };
    E["attachToAlliance"] = [](CLuaBaseEntity* L, CLuaBaseEntity* anchor)
    {
        auto* PSelf   = asChar(L);
        auto* PAnchor = asChar(anchor);
        if (PSelf == nullptr || PAnchor == nullptr || PSelf->PParty == nullptr || PAnchor->PParty == nullptr || PSelf->PParty == PAnchor->PParty)
        {
            return;
        }
        if (PAnchor->PParty->m_PAlliance == nullptr)
        {
            PAnchor->PParty->m_PAlliance = new CAlliance(PAnchor);
        }
        else if (PAnchor->PParty->m_PAlliance->partyList.size() >= 3)
        {
            return;
        }
        PAnchor->PParty->m_PAlliance->addParty(PSelf->PParty);
    };
    E["detachFromAlliance"] = [](CLuaBaseEntity* L)
    {
        if (auto* PSelf = asChar(L); PSelf != nullptr && PSelf->PParty != nullptr && PSelf->PParty->m_PAlliance != nullptr)
        {
            PSelf->PParty->m_PAlliance->removeParty(PSelf->PParty);
        }
    };
    E["getAllianceParty"] = [](CLuaBaseEntity* L) -> uint8
    {
        auto* PBattle = dynamic_cast<CBattleEntity*>(L->GetBaseEntity());
        if (PBattle == nullptr)
        {
            return 0;
        }
        if (PBattle->PParty == nullptr || PBattle->PParty->m_PAlliance == nullptr)
        {
            return 1;
        }
        const auto& list = PBattle->PParty->m_PAlliance->partyList;
        for (size_t i = 0; i < list.size(); ++i)
        {
            if (list[i] == PBattle->PParty)
            {
                return static_cast<uint8>(i + 1);
            }
        }
        return 1;
    };

    // ---- treasure pool -------------------------------------------------------------------------------------------
    E["botLotItem"] = [](CLuaBaseEntity* L, uint8 slotId, sol::object lotValue)
    {
        if (auto* PChar = asChar(L); PChar != nullptr && PChar->PTreasurePool != nullptr)
        {
            const uint16 lot = (lotValue.valid() && lotValue.is<uint16>()) ? lotValue.as<uint16>() : static_cast<uint16>(999);
            PChar->PTreasurePool->lotItem(PChar, slotId, lot);
        }
    };
    E["botPassItem"] = [](CLuaBaseEntity* L, uint8 slotId)
    {
        if (auto* PChar = asChar(L); PChar != nullptr && PChar->PTreasurePool != nullptr)
        {
            PChar->PTreasurePool->passItem(PChar, slotId);
        }
    };

    // ---- AI state queries, resting ---------------------------------------------------------------------------------
    E["isBotCasting"]         = [](CLuaBaseEntity* L) { return inState<CMagicState>(L); };
    E["isBotRangedAttacking"] = [](CLuaBaseEntity* L) { return inState<CRangeState>(L); };
    E["isBotUsingAbility"]    = [](CLuaBaseEntity* L) { return inState<CAbilityState>(L); };
    E["isBotWeaponSkilling"]  = [](CLuaBaseEntity* L) { return inState<CWeaponSkillState>(L); };
    E["isBotResting"]         = [](CLuaBaseEntity* L) { return L->GetBaseEntity()->animation == xi::Animation::Healing; };
    E["startBotResting"]      = [](CLuaBaseEntity* L)
    {
        auto* PChar = asChar(L);
        if (PChar == nullptr || PChar->animation == xi::Animation::Healing || PChar->PAI->IsEngaged())
        {
            return;
        }
        PChar->PAI->ClearStateStack();
        PChar->StatusEffectContainer->AddStatusEffect(xi::StatusEffect::Healing, 0, 0, std::chrono::seconds(settings::get<uint8>("map.HEALING_TICK_DELAY")), 0s);
    };
    E["stopBotResting"] = [](CLuaBaseEntity* L)
    {
        if (auto* PChar = asChar(L); PChar != nullptr && PChar->animation == xi::Animation::Healing)
        {
            PChar->StatusEffectContainer->DelStatusEffectSilent(xi::StatusEffect::Healing);
        }
    };
    E["acceptRaise"] = [](CLuaBaseEntity* L)
    {
        if (auto* PChar = asChar(L))
        {
            PChar->Raise();
        }
    };

    // ---- abilities, spells, experience -----------------------------------------------------------------------------
    E["hasJobAbility"] = [](CLuaBaseEntity* L, uint16 abilityId)
    {
        auto* PChar = asChar(L);
        return PChar != nullptr && charutils::hasAbility(PChar, abilityId) != 0;
    };
    E["canUseSpell"] = [](CLuaBaseEntity* L, uint16 spellId)
    {
        auto* PBattle = dynamic_cast<CBattleEntity*>(L->GetBaseEntity());
        return PBattle != nullptr && spell::CanUseSpell(PBattle, static_cast<SpellID>(spellId));
    };
    E["getCurrentJobExp"] = [](CLuaBaseEntity* L) -> uint32
    {
        auto* PChar = asChar(L);
        return PChar != nullptr ? PChar->jobs.exp[static_cast<uint8>(PChar->GetMJob())] : 0;
    };
    E["getRequiredJobExp"] = [](CLuaBaseEntity* L) -> uint32
    {
        auto* PChar = asChar(L);
        return PChar != nullptr ? charutils::GetExpNEXTLevel(PChar->jobs.job[static_cast<uint8>(PChar->GetMJob())]) : 0;
    };
    E["setRankByNation"] = [](CLuaBaseEntity* L, uint8 nation, uint8 rank)
    {
        if (auto* PChar = asChar(L); PChar != nullptr && nation <= 2)
        {
            PChar->profile.rank[nation] = rank;
            charutils::SaveMissionsList(PChar);
        }
    };

    // ---- inventory and equipment -----------------------------------------------------------------------------------
    E["sortInventory"] = [](CLuaBaseEntity* L, const sol::object& locId)
    {
        auto* PChar = asChar(L);
        if (PChar == nullptr)
        {
            return;
        }
        const uint8 location = (locId != sol::lua_nil) ? locId.as<uint8>() : static_cast<uint8>(LOC_INVENTORY);
        consolidateStacks(PChar, location);
    };
    // Equip a specific copy of an item: prefer one not already worn in another slot (two identical rings).
    E["equipItemUnique"] = [](CLuaBaseEntity* L, uint16 itemId, uint8 containerId, uint8 equipSlot)
    {
        auto* PChar = asChar(L);
        if (PChar == nullptr)
        {
            return;
        }
        auto* PStorage = PChar->getStorage(containerId);
        if (PStorage == nullptr)
        {
            return;
        }
        const auto matches = PStorage->SearchItems(itemId);
        if (matches.empty())
        {
            return;
        }
        uint8 chosen = matches.front();
        for (const uint8 slot : matches)
        {
            auto* PCandidate = PStorage->GetItem(slot);
            bool  elsewhere  = false;
            for (uint8 esi = 0; esi < 16 && PCandidate != nullptr; ++esi)
            {
                if (esi != equipSlot && PChar->getEquip(static_cast<SLOTTYPE>(esi)) == PCandidate)
                {
                    elsewhere = true;
                    break;
                }
            }
            if (PCandidate != nullptr && !elsewhere)
            {
                chosen = slot;
                break;
            }
        }
        if (dynamic_cast<CItemEquipment*>(PStorage->GetItem(chosen)) != nullptr)
        {
            charutils::EquipItem(PChar, chosen, equipSlot, containerId);
            PChar->setPersist(CharPersist::Equip);
        }
    };

    // ---- movement ---------------------------------------------------------------------------------------------------
    // WORLDBOTS: Phoenix's pathTo refuses all players; world bots are server-driven, so they may path (Nate's change).
    E["pathTo"] = [](CLuaBaseEntity* L, float x, float y, float z, const sol::object& flags) -> bool
    {
        CBaseEntity* PEntity = L->GetBaseEntity();
        if (PEntity->objtype == TYPE_PC && !isBot(static_cast<CCharEntity*>(PEntity)))
        {
            ShowWarning("Invalid entity (Player: %s) calling function.", PEntity->getName());
            return false;
        }
        if (!PEntity->PAI->PathFind)
        {
            return false;
        }
        position_t point{};
        point.x               = x;
        point.y               = y;
        point.z               = z;
        const uint8 pathFlags = (flags != sol::lua_nil) ? flags.as<uint8>() : static_cast<uint8>(PATHFLAG_RUN | PATHFLAG_SCRIPT);
        return PEntity->PAI->PathFind->PathTo(point, pathFlags);
    };
    // WORLDBOTS: no navmesh raycast in Phoenix; walking the surface toward the point finds the first obstacle.
    // Step destination, held 1.5 y short of a wall (Nate's wall clearance, #189).
    E["raycastClampTo"] = [](CLuaBaseEntity* L, float tx, float ty, float tz) -> std::tuple<float, float, float>
    {
        CBaseEntity* PEntity = L->GetBaseEntity();
        if (PEntity->loc.zone == nullptr || PEntity->loc.zone->navMesh() == nullptr)
        {
            return { tx, ty, tz };
        }
        constexpr float clearance = 1.5f;
        const position_t start    = PEntity->loc.p;
        const float      dx       = tx - start.x;
        const float      dy       = ty - start.y;
        const float      dz       = tz - start.z;
        const float      len      = std::sqrt(dx * dx + dz * dz);
        if (len < 0.001f)
        {
            return { tx, ty, tz };
        }
        position_t probe = start;
        probe.x += dx * (len + clearance) / len;
        probe.y += dy * (len + clearance) / len;
        probe.z += dz * (len + clearance) / len;
        position_t reached{};
        PEntity->loc.zone->navMesh()->moveAlongSurface(start, probe, reached);
        const float reachedLen = std::sqrt((reached.x - start.x) * (reached.x - start.x) + (reached.z - start.z) * (reached.z - start.z));
        if (reachedLen >= len + clearance - 0.05f)
        {
            return { tx, ty, tz }; // nothing within the step plus the clearance
        }
        const float t = std::min(1.0f, std::max(0.0f, reachedLen - clearance) / len);
        return { start.x + dx * t, start.y + dy * t, start.z + dz * t };
    };
    E["raycastClear"] = [](CLuaBaseEntity* L, float ax, float ay, float az, float bx, float by, float bz) -> bool
    {
        CBaseEntity* PEntity = L->GetBaseEntity();
        if (PEntity->loc.zone == nullptr || PEntity->loc.zone->navMesh() == nullptr)
        {
            return true;
        }
        position_t a{};
        a.x = ax;
        a.y = ay;
        a.z = az;
        position_t b{};
        b.x = bx;
        b.y = by;
        b.z = bz;
        position_t reached{};
        PEntity->loc.zone->navMesh()->moveAlongSurface(a, b, reached);
        return std::abs(reached.x - bx) < 0.5f && std::abs(reached.z - bz) < 0.5f;
    };

    // ---- addon pushes: no Ashita v3 client here, so they go to the log (or nowhere) ----------------------------
    E["pushPullerNearbyNames"] = [](CLuaBaseEntity*, const sol::table&) {};
    E["publishBotState"]       = [](CLuaBaseEntity*, const std::string&) {};
    E["pushAutoskillState"]    = [](CLuaBaseEntity*, const std::string&, uint8) {};
    E["applyStyleLock"]        = [](CLuaBaseEntity*, sol::table) {}; // cosmetic; bots keep their real look
    E["clearStyleLock"]        = [](CLuaBaseEntity*) {};

    // ---- status effects -----------------------------------------------------------------------------------------
    sol::usertype<CLuaStatusEffect> S = ::lua["CStatusEffect"];
    S["getStartTimeMs"]               = [](CLuaStatusEffect* L) -> uint64
    {
        return static_cast<uint64>(std::chrono::duration_cast<std::chrono::milliseconds>(timer::to_utc(L->GetStatusEffect()->GetStartTime()).time_since_epoch()).count());
    };

    // ---- globals (Nate: luautils.cpp, lua_hooks.cpp) ------------------------------------------------------------
    ::lua.set_function("GetServerConfig", &getServerConfig);
    ::lua.set_function("BotPushLog", &logPush);
    ::lua.set_function("BotPushState", [](CLuaBaseEntity*, const sol::object&) {});
    ::lua.set_function("BotPushDps", [](CLuaBaseEntity*, uint32, bool, uint32, uint32, sol::table) {});
    ::lua.set_function("PushPartyStatus", [](CLuaBaseEntity*, uint8, sol::table) {});
    ::lua.set_function("GetWeaponskillByName", [](const std::string& name) -> uint16
    {
        for (uint16 id = 0; id < MAX_WEAPONSKILL_ID && !name.empty(); ++id)
        {
            auto* PWS = battleutils::GetWeaponSkill(id);
            if (PWS != nullptr && PWS->getName() == name)
            {
                return id;
            }
        }
        return 0;
    });
    ::lua.set_function("GetWeaponskillNameByID", [](uint16 id) -> std::string
    {
        auto* PWS = id < MAX_WEAPONSKILL_ID ? battleutils::GetWeaponSkill(id) : nullptr;
        return PWS != nullptr ? PWS->getName() : std::string();
    });
    ::lua.set_function("GetWeaponskillProperties", [](uint16 id) -> sol::object
    {
        auto* PWS = id < MAX_WEAPONSKILL_ID ? battleutils::GetWeaponSkill(id) : nullptr;
        if (PWS == nullptr)
        {
            return sol::lua_nil;
        }
        sol::table t   = ::lua.create_table();
        t["primary"]   = PWS->getPrimarySkillchain();
        t["secondary"] = PWS->getSecondarySkillchain();
        t["tertiary"]  = PWS->getTertiarySkillchain();
        return t;
    });
    ::lua.set_function("GetSpellMetaByID", [](uint16 spellId) -> sol::object
    {
        CSpell* PSpell = spell::GetSpell(static_cast<SpellID>(spellId));
        if (PSpell == nullptr)
        {
            return sol::lua_nil;
        }
        sol::table t = ::lua.create_table();
        t["id"]      = static_cast<uint16>(PSpell->getID());
        t["name"]    = PSpell->getName();
        t["element"] = PSpell->getElement();
        t["skill"]   = PSpell->getSkillType();
        t["mpcost"]  = PSpell->getMPCost();
        return t;
    });

    // ---- world-bot control (FFXI-Forever) -------------------------------------------------------------------------
    ::lua.set_function("WorldbotSpawn", [](const std::string& name) -> sol::object
    {
        const auto rset = db::preparedStmt("SELECT charid FROM chars WHERE charname = ? LIMIT 1", name);
        if (!rset || !rset->next())
        {
            return sol::lua_nil;
        }
        auto* PBot = spawn(rset->get<uint32>("charid"), nullptr);
        return PBot != nullptr ? sol::make_object(::lua, CLuaBaseEntity(PBot)) : sol::lua_nil;
    });
    ::lua.set_function("WorldbotDespawn", [](const std::string& name) -> bool
    {
        auto* PChar = zoneutils::GetCharByName(name);
        return PChar != nullptr && isBot(PChar) && despawn(PChar->id);
    });
    ::lua.set_function("WorldbotList", []() -> sol::table
    {
        sol::table t = ::lua.create_table();
        int        i = 1;
        for (const auto id : bots())
        {
            if (auto* PChar = zoneutils::GetChar(id))
            {
                t[i++] = CLuaBaseEntity(PChar);
            }
        }
        return t;
    });
}

} // namespace worldbots
