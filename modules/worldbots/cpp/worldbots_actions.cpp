/*
===========================================================================

  FFXI-Forever world bots: client actions.

  A headless bot has no client, so the brain acts by handing the server the
  same packets a client would send, through each packet's own validate() and
  process(): talking to an NPC, ending an event, buying and selling at a shop,
  trading items to an NPC (HELM points, guild NPCs), and synthesis. The game
  rules and logs (audit_vendor, synthesis results) are the server's own.

===========================================================================
*/

#include "worldbots.h"

#include "common/logging.h"
#include "common/lua.h"
#include "entities/char_entity.h"
#include "entities/mob_entity.h"
#include "entities/npc_entity.h"
#include "item_container.h"
#include "items/item_equipment.h"
#include "items/item_weapon.h"
#include "lua/lua_base_entity.h"
#include "packets/c2s/0x01a_action.h"
#include "packets/c2s/validation.h"
#include "packets/c2s/0x036_item_transfer.h"
#include "packets/c2s/0x05b_eventend.h"
#include "packets/c2s/0x083_shop_buy.h"
#include "packets/c2s/0x084_shop_sell_req.h"
#include "packets/c2s/0x085_shop_sell_set.h"
#include "packets/c2s/0x096_combine_ask.h"
#include "trade_container.h"
#include "utils/itemutils.h"

#include <filesystem>

namespace worldbots
{

namespace
{

auto asChar(CLuaBaseEntity* L) -> CCharEntity*
{
    auto* PEntity = L != nullptr ? L->GetBaseEntity() : nullptr;
    return PEntity != nullptr && PEntity->objtype == TYPE_PC ? static_cast<CCharEntity*>(PEntity) : nullptr;
}

// The packet's own checks, then its handler, as the packet dispatcher does for a client.
template <typename T>
auto sendAsClient(CCharEntity* PChar, const T& packet, uint16 packetType, const char* what) -> bool
{
    if (PChar == nullptr || PChar->PSession == nullptr || !isBot(PChar))
    {
        return false;
    }
    const auto result = packet.validate(PChar->PSession, PChar);
    if (!result.valid())
    {
        ShowDebugFmt("[worldbots] {} {} refused: {}", PChar->getName(), what, result.errorString());
        return false;
    }
    packet.process(PChar->PSession, PChar);
    PChar->m_LastPacketType = packetType;
    return true;
}

} // namespace

void registerActionsLuaApi()
{
    sol::usertype<CLuaBaseEntity> E = ::lua["CBaseEntity"];

    // Talk to an NPC (0x01A Talk): runs its onTrigger, which may open a shop or start an event.
    E["worldbotTalk"] = [](CLuaBaseEntity* L, CLuaBaseEntity* npc) -> bool
    {
        auto* PChar = asChar(L);
        auto* PNpc  = npc != nullptr ? npc->GetBaseEntity() : nullptr;
        if (PChar == nullptr || PNpc == nullptr)
        {
            return false;
        }
        GP_CLI_COMMAND_ACTION packet{};
        packet.UniqueNo = PNpc->id;
        packet.ActIndex = PNpc->targid;
        packet.ActionID = GP_CLI_COMMAND_ACTION_ACTIONID::Talk;
        return sendAsClient(PChar, packet, 0x01A, "talk");
    };

    E["worldbotInEvent"] = [](CLuaBaseEntity* L) -> bool
    {
        auto* PChar = asChar(L);
        return PChar != nullptr && PChar->isInEvent();
    };

    // End the current event with an option (0x05B), as a client does when a cutscene or menu closes.
    E["worldbotEndEvent"] = [](CLuaBaseEntity* L, sol::optional<uint32> option) -> bool
    {
        auto* PChar = asChar(L);
        if (PChar == nullptr || !PChar->isInEvent())
        {
            return false;
        }
        GP_CLI_COMMAND_EVENTEND packet{};
        packet.UniqueNo = PChar->currentEvent->targetEntity != nullptr ? PChar->currentEvent->targetEntity->id : PChar->id;
        packet.ActIndex = PChar->currentEvent->targetEntity != nullptr ? PChar->currentEvent->targetEntity->targid : PChar->targid;
        packet.EndPara   = option.value_or(0);
        packet.EventPara = static_cast<uint16>(PChar->currentEvent->eventId); // the handler's event id
        packet.Mode      = static_cast<uint16>(GP_CLI_COMMAND_EVENTEND_MODE::End);
        return sendAsClient(PChar, packet, 0x05B, "event end");
    };

    // The open shop's stock: { { index, itemId, price }, ... } (empty when no shop is open).
    E["worldbotShopStock"] = [](CLuaBaseEntity* L) -> sol::table
    {
        sol::table out   = ::lua.create_table();
        auto*      PChar = asChar(L);
        if (PChar == nullptr || PChar->Container == nullptr || PChar->Container->getShopVendorId() == 0)
        {
            return out;
        }
        int n = 1;
        for (uint8 i = 0; i < PChar->Container->getExSize(); ++i)
        {
            const uint16 itemId = PChar->Container->getItemID(i);
            if (itemId == 0)
            {
                continue;
            }
            sol::table row = ::lua.create_table();
            row["index"]   = i;
            row["itemId"]  = itemId;
            row["price"]   = PChar->Container->getQuantity(i); // the shop stores the price as the quantity
            out[n++]       = row;
        }
        return out;
    };

    // Buy from the open shop (0x083).
    E["worldbotShopBuy"] = [](CLuaBaseEntity* L, uint16 shopIndex, uint32 quantity) -> bool
    {
        GP_CLI_COMMAND_SHOP_BUY packet{};
        packet.ShopItemIndex = shopIndex;
        packet.ItemNum       = quantity;
        return sendAsClient(asChar(L), packet, 0x083, "shop buy");
    };

    // Sell an inventory slot to the open shop: the price query (0x084) then the confirmation (0x085).
    E["worldbotShopSell"] = [](CLuaBaseEntity* L, uint8 slot, uint16 itemId, uint32 quantity) -> bool
    {
        auto*                        PChar = asChar(L);
        GP_CLI_COMMAND_SHOP_SELL_REQ req{};
        req.ItemIndex = slot;
        req.ItemNo    = itemId;
        req.ItemNum   = quantity;
        if (!sendAsClient(PChar, req, 0x084, "shop sell request"))
        {
            return false;
        }
        GP_CLI_COMMAND_SHOP_SELL_SET set{};
        set.SellFlag = 1;
        return sendAsClient(PChar, set, 0x085, "shop sell");
    };

    // Trade inventory items to an NPC (0x036): items = { { slot = s, quantity = q }, ... } (gil is slot 0).
    E["worldbotTrade"] = [](CLuaBaseEntity* L, CLuaBaseEntity* npc, sol::table items) -> bool
    {
        auto* PNpc = npc != nullptr ? npc->GetBaseEntity() : nullptr;
        if (PNpc == nullptr)
        {
            return false;
        }
        GP_CLI_COMMAND_ITEM_TRANSFER packet{};
        packet.UniqueNo = PNpc->id;
        packet.ActIndex = PNpc->targid;
        uint8 n         = 0;
        for (const auto& kv : items)
        {
            if (n >= 10)
            {
                break;
            }
            sol::table entry                = kv.second.as<sol::table>();
            packet.PropertyItemIndexTbl[n] = entry.get_or<uint8>("slot", 0);
            packet.ItemNumTbl[n]           = entry.get_or<uint32>("quantity", 1);
            ++n;
        }
        packet.ItemNum = n;
        return sendAsClient(asChar(L), packet, 0x036, "trade");
    };

    // Synthesis (0x096): crystal item id and inventory slot, ingredients = { { itemId = i, slot = s }, ... }.
    E["worldbotSynth"] = [](CLuaBaseEntity* L, uint16 crystal, uint8 crystalSlot, sol::table ingredients) -> bool
    {
        GP_CLI_COMMAND_COMBINE_ASK packet{};
        packet.Crystal    = crystal;
        packet.CrystalIdx = crystalSlot;
        uint8 n           = 0;
        for (const auto& kv : ingredients)
        {
            if (n >= 8)
            {
                break;
            }
            sol::table entry  = kv.second.as<sol::table>();
            packet.ItemNo[n]  = entry.get_or<uint16>("itemId", 0);
            packet.TableNo[n] = entry.get_or<uint8>("slot", 0);
            ++n;
        }
        packet.Items = n;
        return sendAsClient(asChar(L), packet, 0x096, "synthesis");
    };

    // Whether a monster attacks on sight or sound (read-only; for keeping low-level bots out of its way).
    E["worldbotIsAggressive"] = [](CLuaBaseEntity* L) -> bool
    {
        auto* PEntity = L != nullptr ? L->GetBaseEntity() : nullptr;
        return PEntity != nullptr && PEntity->objtype == TYPE_MOB && static_cast<CMobEntity*>(PEntity)->m_Aggro;
    };

    // Skill with tenths (crafts rise by 0.1): RealSkills holds it times ten.
    E["worldbotSkillTenths"] = [](CLuaBaseEntity* L, uint16 skillId) -> uint16
    {
        auto* PChar = asChar(L);
        return PChar != nullptr && skillId < MAX_SKILLTYPE ? PChar->RealSkills.skill[skillId] : 0;
    };

    E["worldbotIsCrafting"] = [](CLuaBaseEntity* L) -> bool
    {
        auto* PChar = asChar(L);
        return PChar != nullptr && PChar->isCrafting();
    };

    // Inventory with slots: { { slot, itemId, quantity }, ... } (slot 0, the gil, is left out).
    E["worldbotInventory"] = [](CLuaBaseEntity* L) -> sol::table
    {
        sol::table out   = ::lua.create_table();
        auto*      PChar = asChar(L);
        if (PChar == nullptr)
        {
            return out;
        }
        auto* PInv = PChar->getStorage(LOC_INVENTORY);
        int   n    = 1;
        for (uint8 slot = 1; slot <= PInv->GetSize(); ++slot)
        {
            if (auto* PItem = PInv->GetItem(slot))
            {
                sol::table row  = ::lua.create_table();
                row["slot"]     = slot;
                row["itemId"]   = PItem->getID();
                row["quantity"] = PItem->getQuantity();
                out[n++]        = row;
            }
        }
        return out;
    };

    // Static item facts for buying and gear decisions.
    ::lua.set_function("WorldbotItemInfo", [](uint16 itemId) -> sol::object
    {
        const CItem* PItem = xi::items::lookup(itemId);
        if (PItem == nullptr)
        {
            return sol::make_object(::lua, sol::lua_nil);
        }
        sol::table out    = ::lua.create_table();
        out["id"]         = itemId;
        out["name"]       = PItem->getName();
        out["basePrice"]  = PItem->getBasePrice();
        out["stack"]      = PItem->getStackSize();
        out["noSale"]     = PItem->hasFlag(ItemFlag::NoSale);
        out["rare"]       = PItem->hasFlag(ItemFlag::Rare);
        out["exclusive"]  = PItem->hasFlag(ItemFlag::Exclusive);
        out["equipment"]  = PItem->isType(ITEM_EQUIPMENT);
        if (const auto* PEquip = dynamic_cast<const CItemEquipment*>(PItem))
        {
            out["slots"]  = PEquip->getEquipSlotId();
            out["slot"]   = PEquip->getSlotType();
            out["reqLvl"] = PEquip->getReqLvl();
            out["jobs"]   = PEquip->getJobs();
            out["def"]    = PEquip->getModifier(xi::Mod::DEF);
            out["weapon"] = PItem->isType(ITEM_WEAPON);
        }
        if (const auto* PWeapon = dynamic_cast<const CItemWeapon*>(PItem))
        {
            out["damage"] = PWeapon->getDamage();
            out["delay"]  = PWeapon->getDelay();
            out["skill"]  = static_cast<uint8>(PWeapon->getSkillType());
        }
        return sol::make_object(::lua, out);
    });

    // File names in a server directory (for example scripts/zones/<zone>/npcs), to find vendors and HELM points.
    ::lua.set_function("WorldbotListDir", [](const std::string& path) -> sol::table
    {
        sol::table      out = ::lua.create_table();
        std::error_code ec;
        int             n   = 1;
        for (const auto& entry : std::filesystem::directory_iterator(path, ec))
        {
            if (entry.is_regular_file())
            {
                out[n++] = entry.path().filename().string();
            }
        }
        return out;
    });
}

} // namespace worldbots
