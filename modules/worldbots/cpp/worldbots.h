/*
===========================================================================

  FFXI-Forever world bots (github.com/corey-allen/ffxi-forever)

  Headless characters and the engine side of the bot AI, ported from
  NatePillow/LandSandBoat@1982bfd348 (src/map/singleplayer, GPL-3.0,
  "Single Player Dev Teams") to Phoenix as a module. Differences from Nate's
  fork are marked WORLDBOTS:
  - bots can be ownerless (parentCharId 0): they live in their own zone and
    position, not beside a player; the world brain drives them;
  - per-bot state lives here, not on CCharEntity (one core flag: m_worldbot);
  - no line-of-sight bypass, no mob-aggro immunity: bots play by player rules.

===========================================================================
*/

#pragma once

#include "common/cbasetypes.h"

#include <cstdint>
#include <string>
#include <vector>

class CCharEntity;
class CZone;

namespace worldbots
{

// Nate's BotMode values, kept so his Lua works unchanged.
enum class BotMode : uint8
{
    Off          = 0,
    CombatOnly   = 1,
    Full         = 2,
    MovementOnly = 3,
};

struct BotState
{
    uint32  parentCharId{ 0 };  // 0 = ownerless world bot
    BotMode botMode{ BotMode::Full };
    uint8   tickPriority{ 255 }; // lower ticks earlier within a zone (healers first)
    uint8   aggroMode{ 1 };      // 1 = Full: monsters treat the bot like any player (no immunity)
    bool    spawnFinalized{ false };
};

// Spawn a character as a headless bot. parent == nullptr: ownerless, at its saved zone and position.
// Otherwise beside `parent`, Nate's companion model. Returns the character, or nullptr on failure.
auto spawn(uint32 charId, CCharEntity* parent) -> CCharEntity*;

// Despawn a headless bot (position and state are saved by the engine). Returns true if one was found.
auto despawn(uint32 charId) -> bool;

auto isBot(const CCharEntity* PChar) -> bool;
auto state(const CCharEntity* PChar) -> BotState*; // nullptr for non-bots
auto bots() -> std::vector<uint32>;                // char ids of all spawned bots

void registerLuaApi();
void tickZoneBots(CZone* PZone);
void cleanupOnStartup();

} // namespace worldbots
