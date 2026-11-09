--[[
    Feature 2  —  a weapon dropped by this mod gets its durability back when it is picked up again.

    The game creates every picked-up weapon at full durability (AddWeapon / ExchangeWeapon are
    called from C++ and cannot be intercepted). So after the pickup the slot that now holds the
    weapon is found through the slot diff from game.pickup_watch, and its durability is written back
    with the inventory's own SetWeaponDurability. Only pickups registered in game.drops are touched.

    The slot is identified by the diff, never by durability: a free slot going from -1 to the ID,
    or (replace path) an occupied slot whose ID changed to it. Two copies of the same weapon are
    therefore never confused.
--]]
local Log         = require("core.log")
local Util        = require("core.util")
local Const       = require("game.const")
local Inventory   = require("game.inventory")
local Drops       = require("game.drops")
local PickupWatch = require("game.pickup_watch")

local M = {}

local function indexOfName(names, name)
    for i, n in ipairs(names) do
        if n == name then return i - 1 end
    end
    return nil
end

local function onWeaponsChanged(pickup, ev)
    local info = Drops.take(pickup)
    if not info or info.kind ~= "weapon" then return end

    local idIndex = indexOfName(ev.names, info.id)
    if idIndex == nil then Log.warn("Restore durability: unknown weapon %s", info.id); return end

    -- the slot the picked-up copy went into
    local target = nil
    for _, c in ipairs(ev.changes) do
        local b, a = c.before, c.after
        if a and a.IDIndex == idIndex and (not b or b.IDIndex ~= idIndex) then
            target = c
            break
        end
    end
    if not target then
        -- same weapon replaced by the same weapon: only the durability of that slot changed
        for _, c in ipairs(ev.changes) do
            if c.after and c.after.IDIndex == idIndex then target = c; break end
        end
    end
    if not target then
        Log.warn("Restore durability: %s not found among the changed slots", info.id)
        return
    end

    local isFog = target.list == "fog"
    local ok, err = pcall(function() ev.inv:SetWeaponDurability(target.index, isFog, info.durability) end)
    if not ok then Log.warn("SetWeaponDurability failed: %s", tostring(err)); return end

    -- the weapon in hand keeps its own copy of the value
    local equipped = Util.try(function() return ev.inv:GetEquippedWeaponIndex() end)
    local useFog   = Util.try(function() return ev.inv.CurrentUseFogWeapon end)
    if equipped == target.index and useFog == isFog then
        Util.try(function() ev.inv:SetEquippedWeaponDurability(FName(info.id), info.durability) end)
    end
    Log.info("Restored durability of %s (%s slot %d) to %.1f", info.id, target.list, target.index, info.durability)
end

function M.install(config)
    if not config.RestoreDroppedDurability then
        Log.info("feature 2 (restore dropped durability) is disabled")
        return
    end
    PickupWatch.onWeaponsChanged(onWeaponsChanged)
    Log.info("feature 2 (restore dropped durability) installed")
end

return M
