--[[
    Feature 3  —  consumable replace with a full inventory: the discarded stack is dropped on the
    ground where the new item was.

    Driven by game.pickup_watch. Consumable stacks are re-sorted by the game on every change, so
    the diff is done on totals per ID:  lost(ID) = before(ID) + gained(ID) - after(ID),
    where gained is what the pickup itself held. Verified on replacements of another type and of
    the same type (a MedKitA stack replaced by a single MedKitA).

    One pickup per lost stack, giving the whole stack at once. (Laying a stack out as separate single
    pickups was tried on 2026-10-28: at 25 cm their interaction triggers overlap and one of them loses
    its prompt; the variant was removed.) Stacks of different types lost in the same replace are
    placed DropSpacing cm apart.
--]]
local Log         = require("core.log")
local Util        = require("core.util")
local Inventory   = require("game.inventory")
local Drops       = require("game.drops")
local PickupWatch = require("game.pickup_watch")

local M = {}
local config

local function lostPerId(ev)
    local gained = {}
    if ev.pickupId then
        for i, n in ipairs(ev.names) do
            if n == ev.pickupId then gained[i - 1] = ev.pickupCount or 1 end
        end
    end
    local lost = {}
    for idIndex, before in pairs(ev.before) do
        local n = before + (gained[idIndex] or 0) - (ev.after[idIndex] or 0)
        if n > 0 then lost[idIndex] = n end
    end
    return lost
end

local function dropStack(name, removed, loc, rot, dropIndex)
    local l = { X = loc.X + dropIndex * config.DropSpacing, Y = loc.Y, Z = loc.Z }
    Drops.consumable(name, removed, l, rot)
    return dropIndex + 1
end

local function onConsumablesChanged(pickup, ev)
    local lost = lostPerId(ev)
    if next(lost) == nil then return end   -- nothing removed: a plain pickup or a weapon
    Log.dbg("Consumable replace on %s: lost %s", Util.actorName(pickup), Inventory.describeConsumableTotals(lost, ev.names))

    local loc, rot = Util.actorLocRot(pickup)
    local dropIndex = 0
    local ids = {}
    for idIndex in pairs(lost) do ids[#ids + 1] = idIndex end
    table.sort(ids)
    for _, idIndex in ipairs(ids) do
        local name = ev.names[idIndex + 1]
        if name then
            dropIndex = dropStack(name, lost[idIndex], loc, rot, dropIndex)
        else
            Log.warn("Consumable replace: unknown consumable index %d (%d lost)", idIndex, lost[idIndex])
        end
    end
end

function M.install(cfg)
    config = cfg
    if not cfg.DropReplacedConsumables then
        Log.info("feature 3 (drop replaced consumables) is disabled")
        return
    end
    PickupWatch.onConsumablesChanged(onConsumablesChanged)
    Log.info("feature 3 (drop replaced consumables) installed")
end

return M
