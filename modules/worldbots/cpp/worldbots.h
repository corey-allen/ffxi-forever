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
#include <optional>
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

struct Placement
{
    uint16 zone;
    float  x, y, z;
    uint8  rot;
};

// Spawn a character as a headless bot. parent == nullptr: ownerless, at `at` if given, else at its saved
// zone and position. Otherwise beside `parent`, Nate's companion model. Returns the character, or nullptr.
auto spawn(uint32 charId, CCharEntity* parent, std::optional<Placement> at = std::nullopt) -> CCharEntity*;

// Despawn a headless bot (position and state are saved by the engine). Returns true if one was found.
auto despawn(uint32 charId) -> bool;

// Zoning, as a client does it: walk to a zone line and send the zone-line packet (0x05E); the engine moves
// the character out, and processArrivals logs it into the new zone through the login handler (0x00A).
auto useZoneLine(CCharEntity* PChar, uint32 zoneLineId) -> bool;
auto homePoint(CCharEntity* PChar) -> bool; // dead bots only: the death menu's "return to home point"
auto arrive(CCharEntity* PChar) -> bool;     // run the login handler for a bot's session
void processArrivals();

// Marks world-bot accounts: not a bcrypt hash, so no password logs into them.
inline constexpr const char* kNoLoginPassword = "!worldbot:no-login";

auto isBot(const CCharEntity* PChar) -> bool;
auto state(const CCharEntity* PChar) -> BotState*; // nullptr for non-bots
auto bots() -> std::vector<uint32>;                // char ids of all spawned bots

// Create a world-bot character in the DB (account it cannot log in with, intro-cutscene end-state).
// Starting gear comes from xi.player.charCreate on its first spawn.
struct CreateResult
{
    uint32      charId{ 0 }; // 0 on failure
    std::string error;
};
auto createCharacter(const std::string& name, uint8 race, uint8 face, uint8 size, uint8 nation, uint8 job) -> CreateResult;

void registerLuaApi();
void registerRegistryLuaApi();
void registerActionsLuaApi();
void createTables();

// Time spent in the bots' Lua tick since the last call (M7 load measurements).
struct TickStats
{
    uint64 calls{ 0 };
    uint64 micros{ 0 };
    uint64 maxMicros{ 0 };
};
auto takeTickStats() -> TickStats;
void tickZoneBots(CZone* PZone);
void cleanupOnStartup();

} // namespace worldbots
