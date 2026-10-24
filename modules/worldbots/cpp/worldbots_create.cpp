/*
===========================================================================

  FFXI-Forever world bots: server-side character creation.

  Ported from Nate's char_create (NatePillow/LandSandBoat@1982bfd348,
  src/map/singleplayer/char_create.cpp, GPL-3.0). The rows mirror Phoenix's
  loginHelpers::saveCharacter (login_helpers.cpp) and the account INSERT of
  auth_session.cpp, with the same name checks as validateCharacterName.
  WORLDBOTS differences:
  - called from Lua on the main thread (no HTTP server, no op queue);
  - the account cannot log in: its login is "wb<accid>" and its password field
    holds a marker that is not a bcrypt hash, so BCrypt::validatePassword
    (libbcrypt bcrypt_checkpw) fails for every password;
  - the NPC/mob name check always runs (bot names must never look like an NPC);
  - no LoadChar here. Phoenix runs xi.player.charCreate from the login packet,
    not from LoadChar, so the bot gets its starting gear on its first spawn
    (worldbots::spawn runs the same OnZoneIn/OnGameIn as a login). Creation only
    writes the end-state of the intro cutscene: position at the city's CS exit,
    home point there, and no newCharacterCS var, so the cutscene never plays.

===========================================================================
*/

#include "worldbots.h"

#include "common/database.h"
#include "common/enum_traits.h"
#include "common/logging.h"
#include "common/lua.h"
#include "common/utils.h"
#include "data/datasets/zones/mobs/dataset.h"
#include "data/datasets/zones/npcs/dataset.h"
#include "data/enums/zone.h"
#include "data/loader.h"

#include <algorithm>
#include <cctype>
#include <unordered_set>

namespace worldbots
{

namespace
{

// xi_test creates (and wipes) accounts and characters from id 20000000 up; bots stay below it.
constexpr uint32 kTestIdFloor = 20000000;

struct StartCity
{
    uint16 zone;
    float  x, y, z;
    uint8  rot;
};

// One city per nation, at the intro cutscene's exit spot (Nate's stamp, from the newCharacterCS hidden quest).
auto startCity(uint8 nation) -> StartCity
{
    switch (nation)
    {
        case 1: return { 234, -45.0f, 0.0f, 25.0f, 192 };   // Bastok Mines
        case 2: return { 241, 30.0f, 2.0f, -40.0f, 128 };   // Windurst Woods
        default: return { 230, -100.0f, 1.0f, -40.0f, 224 }; // Southern San d'Oria
    }
}

// Same normalization as login_helpers.cpp comparableName: drop '-' and '_', upper-case.
auto comparableName(const std::string_view name) -> std::string
{
    std::string out;
    out.reserve(name.size());
    for (const char ch : name)
    {
        if (ch != '-' && ch != '_')
        {
            out.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(ch))));
        }
    }
    return out;
}

// Every name the client can show on an NPC or mob (login_helpers.cpp entityNames), read once.
auto entityNames() -> const std::unordered_set<std::string>&
{
    static const auto names = []
    {
        std::unordered_set<std::string> collected;

        const auto poolNames = db::preparedStmt("SELECT packet_name FROM mob_pools WHERE packet_name != ''");
        FOR_DB_MULTIPLE_RESULTS(poolNames)
        {
            collected.emplace(comparableName(poolNames->get<std::string>("packet_name")));
        }

        const auto npcNames = db::preparedStmt("SELECT polutils_name FROM npc_list WHERE polutils_name != ''");
        FOR_DB_MULTIPLE_RESULTS(npcNames)
        {
            collected.emplace(comparableName(npcNames->get<std::string>("polutils_name")));
        }

        for (const auto& [key, zoneId] : xi::data::EnumTraits<xi::ZoneId>::kEntries)
        {
            if (const auto npcs = xi::data::loadZoneFile<xi::data::datasets::zones::npcs::Dataset>(zoneId))
            {
                for (const auto& npc : *npcs)
                {
                    if (!npc.DisplayName.empty())
                    {
                        collected.emplace(comparableName(npc.DisplayName));
                    }
                }
            }
            if (const auto mobs = xi::data::loadZoneFile<xi::data::datasets::zones::mobs::Dataset>(zoneId))
            {
                for (const auto& [templateName, mobTemplate] : mobs->Templates)
                {
                    collected.emplace(comparableName(mobTemplate.DisplayName));
                }
            }
        }
        return collected;
    }();
    return names;
}

// validateCharacterName (login_helpers.cpp), with the NPC/mob check always on. Empty string = valid.
auto validateName(const std::string& name) -> std::string
{
    if (!std::all_of(name.begin(), name.end(), [](const char c) { return std::isalpha(static_cast<unsigned char>(c)) != 0; }))
    {
        return "Invalid characters present in name.";
    }
    if (name.size() < 3 || name.size() > 15)
    {
        return "Invalid name length.";
    }
    const auto rset = db::preparedStmt("SELECT charname FROM chars WHERE charname LIKE ?", name);
    if (!rset)
    {
        return "Internal entity name query failed.";
    }
    if (rset->rowsCount() != 0)
    {
        return "Name already in use.";
    }
    if (entityNames().contains(comparableName(name)))
    {
        return "Name is used by an NPC or monster.";
    }
    const auto loginSettings = ::lua["xi"]["settings"]["login"].get<sol::table>();
    if (auto badWords = loginSettings.get_or<sol::table>("BANNED_WORDS_LIST", sol::lua_nil); badWords.valid())
    {
        const auto upper = to_upper(name);
        for (const auto& entry : badWords)
        {
            const auto badWord = to_upper(entry.second.as<std::string>());
            if (upper.contains(badWord))
            {
                return fmt::format("Name matched with bad words list <{}>.", badWord);
            }
        }
    }
    return {};
}

void rollback(uint32 accid, uint32 charid)
{
    for (const auto* table : { "chars", "char_look", "char_stats", "char_exp", "char_flags", "char_jobs", "char_points",
                               "char_unlocks", "char_profile", "char_storage", "char_inventory", "char_vars" })
    {
        db::preparedStmt(fmt::format("DELETE FROM {} WHERE charid = ?", table), charid);
    }
    db::preparedStmt("DELETE FROM accounts WHERE id = ?", accid);
}

} // namespace

auto createCharacter(const std::string& name, uint8 race, uint8 face, uint8 size, uint8 nation, uint8 job) -> CreateResult
{
    // Same ranges as login_helpers.cpp createCharacter.
    if (race < 1 || race > 8 || size > 2 || face > 15 || nation > 2 || job < 1 || job > 6)
    {
        return { 0, "invalid race, face, size, nation or job" };
    }
    if (auto reason = validateName(name); !reason.empty())
    {
        return { 0, reason };
    }

    // accid = MAX(id)+1, floored to 1000 (auth_session.cpp).
    uint32 accid = 0;
    if (const auto rset = db::preparedStmt("SELECT COALESCE(MAX(id), 0) AS max_id FROM accounts WHERE id < ?", kTestIdFloor); rset && rset->next())
    {
        accid = std::max<uint32>(rset->get<uint32>("max_id") + 1, 1000);
    }
    if (accid == 0 || !db::preparedStmt("INSERT INTO accounts(id, login, password, timecreate, timelastmodify, status, priv) "
                                        "VALUES(?, ?, ?, NOW(), NULL, 1, 1)",
                                        accid, fmt::format("wb{}", accid), kNoLoginPassword))
    {
        return { 0, "could not create the account" };
    }

    // charid = MAX(charid)+1 (login_helpers.cpp createCharacter).
    uint32 charid = 0;
    if (const auto rset = db::preparedStmt("SELECT COALESCE(MAX(charid), 0) AS max_id FROM chars WHERE charid < ?", kTestIdFloor); rset && rset->next())
    {
        charid = rset->get<uint32>("max_id") + 1;
    }
    if (charid == 0)
    {
        db::preparedStmt("DELETE FROM accounts WHERE id = ?", accid);
        return { 0, "could not allocate a character id" };
    }

    const auto city = startCity(nation);

    // loginHelpers::saveCharacter, statement for statement (minus the newCharacterCS var).
    bool ok = true;
    ok      = ok && db::preparedStmt("INSERT INTO chars(charid, accid, charname, pos_zone, nation) VALUES(?, ?, ?, ?, ?)", charid, accid, name, city.zone, nation);
    ok      = ok && db::preparedStmt("INSERT INTO char_look(charid, face, race, size) VALUES(?, ?, ?, ?)", charid, face, race, size);
    ok      = ok && db::preparedStmt("INSERT INTO char_stats(charid, mjob) VALUES(?, ?)", charid, job);
    ok      = ok && db::preparedStmt("INSERT INTO char_exp(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charid);
    ok      = ok && db::preparedStmt("INSERT INTO char_flags(charid) VALUES(?) ON DUPLICATE KEY UPDATE disconnecting = disconnecting", charid);
    ok      = ok && db::preparedStmt("INSERT INTO char_jobs(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charid);
    ok      = ok && db::preparedStmt("INSERT INTO char_points(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charid);
    ok      = ok && db::preparedStmt("INSERT INTO char_unlocks(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charid);
    ok      = ok && db::preparedStmt("INSERT INTO char_profile(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charid);
    ok      = ok && db::preparedStmt("INSERT INTO char_storage(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charid);
    ok      = ok && db::preparedStmt("DELETE FROM char_inventory WHERE charid = ?", charid);
    ok      = ok && db::preparedStmt("INSERT INTO char_inventory(charid) VALUES(?)", charid);

    // End-state of the intro cutscene: standing at its exit, home point set there.
    ok = ok && db::preparedStmt("UPDATE chars SET pos_x = ?, pos_y = ?, pos_z = ?, pos_rot = ?, "
                                "home_zone = ?, home_x = ?, home_y = ?, home_z = ?, home_rot = ? WHERE charid = ? LIMIT 1",
                                city.x, city.y, city.z, city.rot, city.zone, city.x, city.y, city.z, city.rot, charid);

    if (!ok)
    {
        rollback(accid, charid);
        return { 0, "could not write the character rows" };
    }

    ShowInfoFmt("[worldbots] created {} (charId {}, account {}), race {} job {} nation {}", name, charid, accid, race, job, nation);
    return { charid, {} };
}

} // namespace worldbots
