--[[
    SHf_Probe  —  read-only reconnaissance mod for SILENT HILL f (UE 5.4.2, module GameNoce, UE4SS 3.x)

    The mod changes nothing in the game. It registers pre/post hooks on a declared list of
    functions (probe/targets.lua), logs every call with its arguments, and offers a few one-shot
    experiments on a key press (probe/experiments.lua). Every log line carries a sequence number
    and a timestamp, so the order and nesting of calls can be read back from the log.

    Questions it answers:
      1. Which hooks fire at all, and does UE4SS run the "pre" callback before or after the body?
      2. Do hooks on the inventory component (AddWeapon, ExchangeWeapon, RemoveConsumable ...) fire
         when the game calls them from C++ (replace widgets, NocePickupBase::OnPickup)?
      3. Does NoceAnimWidget:OnFadeOutCompleted / Hide fire for the pop-up and replace windows?
      4. Can FSoftClassPath elements of NoceConsumableData.GameplayEffects be read from Lua?
      5. Which weapon-subsystem source returns a usable GetMaxDurability value?

    Output: UE4SS console + <ModDir>/probe.log (appended per session).
    Keys:   F9 = run all experiments, F10 = log inventory snapshot + hook status.

    Layout:
      Scripts/main.lua              entry point, configuration
      Scripts/probe/log.lua         logger (console + file, sequence numbers, timestamps)
      Scripts/probe/inspect.lua     value / inventory description helpers
      Scripts/probe/hooks.lua       declarative hook registry with retry
      Scripts/probe/targets.lua     the list of hooked functions (data only)
      Scripts/probe/experiments.lua one-shot checks run on demand
--]]

-- Resolve `require("probe.x")` next to this file regardless of what UE4SS put into package.path.
local scriptDir = ((debug and debug.getinfo(1, "S").source) or ""):match("^@?(.*[\\/])") or ""
package.path = scriptDir .. "?.lua;.\\Mods\\SHf_Probe\\Scripts\\?.lua;" .. package.path

local Log         = require("probe.log")
local Hooks       = require("probe.hooks")
local Experiments = require("probe.experiments")
local targets     = require("probe.targets")

------------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------------
local Config = {
    LogFile      = (scriptDir ~= "" and scriptDir or ".\\Mods\\SHf_Probe\\Scripts\\") .. "..\\probe.log",
    HookRetryMs  = 1000,   -- Blueprint classes load later than the mod: retry until they exist
    HookMaxTries = 600,    -- ~10 minutes, then give up and report what is still missing
    Keys = {
        Experiments  = Key.F9,
        Snapshot     = Key.F10,
        DirectUseTest = Key.F7,   -- AddConsumable beyond the slot capacity, then remove it again (F11 toggles fullscreen)
        SimulateUse   = Key.F12,  -- selects the slot and activates the use ability (ability system)
    },
}

------------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------------
local fileOk = Log.open(Config.LogFile)
Log.section("SHf_Probe loaded")
Log.line("log file: %s (%s)", Config.LogFile, fileOk and "ok" or "could not open, console only")
Log.line("%d hook targets declared", #targets)

for _, target in ipairs(targets) do Hooks.add(target) end
Hooks.start(Config.HookRetryMs, Config.HookMaxTries)

RegisterKeyBind(Config.Keys.Experiments, {}, function()
    ExecuteInGameThread(Experiments.runAll)
end)
RegisterKeyBind(Config.Keys.Snapshot, {}, function()
    ExecuteInGameThread(function()
        Experiments.snapshot()
        Hooks.report()
    end)
end)
RegisterKeyBind(Config.Keys.DirectUseTest, {}, function()
    ExecuteInGameThread(Experiments.addBeyondCapacity)
end)
RegisterKeyBind(Config.Keys.SimulateUse, {}, function()
    ExecuteInGameThread(Experiments.activateUseAbility)
end)
