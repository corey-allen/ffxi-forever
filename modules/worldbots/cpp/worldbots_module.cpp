/*
===========================================================================

  FFXI-Forever world bots: module entry point (see worldbots.h).

===========================================================================
*/

#include "worldbots.h"

#include "common/logging.h"
#include "common/lua.h"
#include "map/utils/moduleutils.h"

#include <filesystem>
#include <fstream>
#include <sstream>

namespace
{

// Dev hook: an operator drops modules/worldbots/dev/run.lua on the server's disk; it runs once on the
// main thread, is renamed to run.lua.done, and what it returns is logged. Local file access only.
void runDevScript()
{
    const std::filesystem::path script = "modules/worldbots/dev/run.lua";
    std::error_code             ec;
    if (!std::filesystem::exists(script, ec))
    {
        return;
    }
    std::ostringstream body;
    body << std::ifstream(script).rdbuf();
    std::filesystem::rename(script, std::filesystem::path(script).concat(".done"), ec);
    if (ec)
    {
        std::filesystem::remove(script, ec); // never run the same file twice
    }

    auto result = ::lua.safe_script(body.str(), sol::script_pass_on_error, "@worldbots/dev/run.lua");
    if (!result.valid())
    {
        sol::error err = result;
        ShowErrorFmt("[worldbots] dev/run.lua failed: {}", err.what());
        return;
    }
    ShowInfoFmt("[worldbots] dev/run.lua: {}", result.get_type() == sol::type::string ? result.get<std::string>() : std::string("done"));
}

} // namespace

class WorldbotsModule : public CPPModule
{
    void OnInit() override
    {
        worldbots::cleanupOnStartup();
        worldbots::createTables();
        worldbots::registerLuaApi();
        worldbots::registerRegistryLuaApi();
        worldbots::registerActionsLuaApi();
        ready_ = true;
        ShowInfo("[worldbots] module loaded: headless sessions, bot Lua API (NatePillow/LandSandBoat@1982bfd348 port)");
    }

    void OnTimeServerTick() override
    {
        if (ready_) // the time server can tick before OnInit has registered the Lua API
        {
            worldbots::processArrivals();
            runDevScript();
            // The world brain (modules/worldbots/brain): schedules, goals, travel.
            sol::protected_function onWorldTick = ::lua["xi"]["worldbots"]["onWorldTick"];
            if (onWorldTick.valid())
            {
                auto result = onWorldTick();
                if (!result.valid())
                {
                    sol::error err = result;
                    ShowErrorFmt("[worldbots] onWorldTick: {}", err.what());
                }
            }
        }
    }

    void OnZoneTick(CZone* PZone) override
    {
        worldbots::processArrivals();
        worldbots::tickZoneBots(PZone);
    }

    bool ready_{ false };
};

REGISTER_CPP_MODULE(WorldbotsModule);
