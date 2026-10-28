--[[
    Feature 1  —  weapon replace with full weapon slots: the discarded weapon is dropped on the
    ground where the new one was, keeping its durability.

    Driven by game.pickup_watch. Weapon slots are positional, so a replace shows up as exactly one
    slot that held a weapon before and differs now: a different ID, or the same ID with a different
    durability (the new copy is full). A plain pickup fills an empty slot and never matches.
--]]
local Log         = require("core.log")
local Util        = require("core.util")
local Const       = require("game.const")
local Inventory   = require("game.inventory")
local Drops       = require("game.drops")
local PickupWatch = require("game.pickup_watch")

local M = {}

local function onWeaponsChanged(pickup, ev)
    local replaced = {}
    for _, c in ipairs(ev.changes) do
        if c.before and c.after and c.before.IDIndex ~= Const.EMPTY_SLOT then replaced[#replaced + 1] = c end
    end
    if #replaced == 0 then return end   -- plain pickup into a free slot
    if #replaced > 1 then
        Log.warn("Weapon replace: %d occupied slots changed at once, nothing dropped (before %s)",
            #replaced, Inventory.describeWeaponSlots(ev.before, ev.names))
        return
    end

    local old  = replaced[1].before
    local name = ev.names[old.IDIndex + 1]
    if not name then Log.warn("Weapon replace: unknown weapon index %d", old.IDIndex); return end

    local loc, rot = Util.actorLocRot(pickup)
    Drops.weapon(name, old.Durability or 0, loc, rot)
end

function M.install(config)
    if not config.DropReplacedWeapon then
        Log.info("feature 1 (drop replaced weapon) is disabled")
        return
    end
    PickupWatch.onWeaponsChanged(onWeaponsChanged)
    Log.info("feature 1 (drop replaced weapon) installed")
end

return M
