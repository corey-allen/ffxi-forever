/*
===========================================================================

  FFXI-Forever world bots: module entry point (see worldbots.h).

===========================================================================
*/

#include "worldbots.h"

#include "common/logging.h"
#include "map/utils/moduleutils.h"

class WorldbotsModule : public CPPModule
{
    void OnInit() override
    {
        worldbots::cleanupOnStartup();
        worldbots::registerLuaApi();
        ShowInfo("[worldbots] module loaded: headless sessions, bot Lua API (NatePillow/LandSandBoat@1982bfd348 port)");
    }

    void OnZoneTick(CZone* PZone) override
    {
        worldbots::tickZoneBots(PZone);
    }
};

REGISTER_CPP_MODULE(WorldbotsModule);
