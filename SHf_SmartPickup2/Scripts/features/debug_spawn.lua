--[[
    Debug only, for TESTPLAN 37b: F6 spawns a consumable pickup one metre in front of the player, each
    press the next type of ITEMS. Remove this file and its line in main.lua before a release.

    The pickup goes through Drops.consumable, like one this mod dropped. One metre keeps its trigger
    clear of a pickup the player stands at (at 25 cm one of them loses its prompt).
--]]
local UEHelpers = require("UEHelpers")
local Log   = require("core.log")
local Util  = require("core.util")
local Drops = require("game.drops")

local M = {}

local ITEMS = { "MedKitB", "DrinkA", "WeaponRecoverA" }
local DISTANCE = 100.0   -- cm in front of the player

local nextItem = 1

local function spawnNext()
    local pawn = UEHelpers.GetPlayer()
    if not Util.valid(pawn) then Log.warn("debug spawn: no player"); return end
    local loc, rot = Util.actorLocRot(pawn)
    local dir = pawn:GetActorForwardVector()
    local at = { X = loc.X + dir.X * DISTANCE, Y = loc.Y + dir.Y * DISTANCE, Z = loc.Z }
    local name = ITEMS[nextItem]
    nextItem = nextItem % #ITEMS + 1
    Drops.consumable(name, 1, at, rot)
end

function M.install()
    RegisterKeyBind(Key.F6, {}, function() ExecuteInGameThread(spawnNext) end)
    Log.info("debug spawn on F6 installed")
end

return M
