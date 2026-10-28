--[[
    game.drops  —  pickups spawned by this mod, and what was dropped into them.

    Later features look an actor up here (Drops.take) to tell a dropped item from a level pickup,
    e.g. to restore the durability of a weapon the player picks up again.
--]]
local Log   = require("core.log")
local Util  = require("core.util")
local Const = require("game.const")
local Spawn = require("game.spawn")

local M = {}

local byAddress = {}   -- actor address -> { kind, id, durability?, count?, name }

local function remember(actor, info)
    local addr = Util.try(function() return actor:GetAddress() end)
    if not addr then return end
    info.name = Util.try(function() return actor:GetFullName() end)
    byAddress[addr] = info
end

--- Drops a weapon with the given durability. Returns the spawned actor or nil.
function M.weapon(name, durability, location, rotation)
    local path  = string.format(Const.WEAPON_INTERACT_FMT, name, name)
    local actor = Spawn.interact(path, location, rotation)
    if not actor then return nil end
    remember(actor, { kind = "weapon", id = name, durability = durability })
    Log.info("Dropped weapon %s (durability %.1f) at %.0f %.0f %.0f", name, durability, location.X, location.Y, location.Z)
    return actor
end

--- Drops a stack of `count` consumables. Returns the spawned actor or nil.
--- The count lives on the child actor (NocePickupBase.Count), set right after spawning.
function M.consumable(name, count, location, rotation)
    local path  = string.format(Const.CONSUMABLE_INTERACT_FMT, name, name)
    local actor = Spawn.interact(path, location, rotation)
    if not actor then return nil end
    if count > 1 then
        local ok, err = pcall(function() actor.PickupClass.ChildActor.Count = count end)
        if not ok then Log.warn("Could not set Count=%d on dropped %s: %s", count, name, tostring(err)) end
    end
    remember(actor, { kind = "consumable", id = name, count = count })
    Log.info("Dropped %d x %s at %.0f %.0f %.0f", count, name, location.X, location.Y, location.Z)
    return actor
end

--- The record of a pickup this mod spawned, removed from the registry; nil for any other actor.
--- The full name is compared as well, because an address can be reused after the actor is gone.
function M.take(actor)
    local addr = Util.try(function() return actor:GetAddress() end)
    local info = addr and byAddress[addr]
    if not info then return nil end
    byAddress[addr] = nil
    local name = Util.try(function() return actor:GetFullName() end)
    if info.name and name and info.name ~= name then
        Log.dbg("Drop registry: address reused by another actor (%s), ignoring", name)
        return nil
    end
    return info
end

return M
