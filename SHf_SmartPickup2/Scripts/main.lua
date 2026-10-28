--[[
    SHf_SmartPickup2  —  UE4SS Lua mod for SILENT HILL f (UE 5.4.2, module GameNoce, UE4SS 3.x)

    Rewrite of SHf_SmartPickup on top of the behaviour measured with SHf_Probe
    (see ../SHf_Probe/FINDINGS.md). Features are enabled one at a time:

      1. Weapon replace with full weapon slots: the discarded weapon is dropped on the ground
         where the new one was, keeping its durability.                      features/weapon_replace.lua
      2. A weapon dropped by this mod gets its durability back when picked up again.
                                                                             features/durability_restore.lua
      3. Consumable replace with a full inventory: the discarded stack is dropped where the new
         item was.                                                           features/consumable_replace.lua
      4. Consumable pickup with a full inventory: the game's own Yes/No pop-up offers to use the
         item on the spot when it is useful right now.                       features/instant_use.lua

    Hook facts this code relies on (measured, not assumed):
      - Blueprint hooks on BP_Interact_Pickup_C fire ONCE, AFTER the function body ("pre" callback).
      - Native hooks (NocePickupBase:OnPickup, widget events) fire before AND after the body.
      - Inventory mutations called from C++ (ExchangeWeapon, AddWeapon ...) cannot be hooked.
      - Weapon slots are positional (-1 = empty); consumables re-sort on every change.

    Layout:
      core/     log, util, hooks        game-agnostic, reusable
      game/     const, inventory, spawn, drops   access to this game's objects
      features/ one module per feature, each exposes install(config)
--]]

local scriptDir = ((debug and debug.getinfo(1, "S").source) or ""):match("^@?(.*[\\/])") or ""
package.path = scriptDir .. "?.lua;.\\Mods\\SHf_SmartPickup2\\Scripts\\?.lua;" .. package.path

local Log       = require("core.log")
local Hooks     = require("core.hooks")
local SlotGuard = require("game.slot_guard")

------------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------------
local Config = {
    Debug                    = true,   -- verbose log lines (inventory snapshots, hook registration)
    DropReplacedWeapon       = true,   -- feature 1
    RestoreDroppedDurability = true,   -- feature 2
    DropReplacedConsumables  = true,   -- feature 3: one pickup per discarded stack
    DropSpacing              = 25.0,   -- cm between pickups when stacks of several types are dropped at once
    -- feature 4: "off" | "useful" (the game's own usefulness check) | "always" (skip it for effect items)
    InstantUse               = "useful",
    ConfirmInstantUse        = true,   -- ask with the game's Yes/No pop-up first; false = use silently
    -- let the game use the item with its animation (quick slot or not); false applies the effect directly
    -- (TryToUseConsumableItem + the GA_UseShortcutItem ability); otherwise the effect is applied directly
    UseGameAnimation         = true,
}
local INSTANT_USE_MODES = { off = true, useful = true, always = true }
if not INSTANT_USE_MODES[Config.InstantUse] then
    Log.warn("Config.InstantUse = %s is not a valid value, using \"useful\"", tostring(Config.InstantUse))
    Config.InstantUse = "useful"
end

------------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------------
Log.configure({ prefix = "[SHf_SmartPickup2]", debug = Config.Debug })
Log.info("loading")

-- a consumable slot borrowed for an animated use is recorded here until it is given back;
-- if the record survives a restart something was interrupted: F8 puts the slot count back
SlotGuard.configure((scriptDir ~= "" and scriptDir or ".\\Mods\\SHf_SmartPickup2\\Scripts\\") .. "..\\slotcount.pending")
if SlotGuard.pendingCount() then
    Log.warn("a borrowed consumable slot was not given back last time (stored count %d): press F8 in game to restore it",
        SlotGuard.pendingCount())
end
RegisterKeyBind(Key.F8, {}, function()
    ExecuteInGameThread(function()
        local inv = require("game.inventory").get()
        if not inv then Log.warn("F8: no inventory"); return end
        if not SlotGuard.restorePending(inv) then Log.info("F8: nothing to restore") end
    end)
end)

require("features.weapon_replace").install(Config)
require("features.durability_restore").install(Config)
require("features.consumable_replace").install(Config)
require("features.instant_use").install(Config)

Hooks.start(1000, 600)
