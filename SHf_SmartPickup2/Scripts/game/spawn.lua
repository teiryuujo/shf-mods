--[[
    game.spawn  —  loading Blueprint classes and spawning interactable pickups.
--]]
local UEHelpers = require("UEHelpers")
local Log  = require("core.log")
local Util = require("core.util")

local M = {}

local classCache = {}   -- path -> UClass

--- Finds or loads a class by its full object path; cached while the object stays valid.
function M.loadClass(path)
    local cls = classCache[path]
    if cls and Util.valid(cls) then return cls end
    cls = StaticFindObject(path)
    if not Util.valid(cls) then
        cls = Util.try(function() return LoadAsset(path) end)
        if not Util.valid(cls) then cls = StaticFindObject(path) end
    end
    if not Util.valid(cls) then
        Log.warn("Could not load class %s", path)
        return nil
    end
    classCache[path] = cls
    return cls
end

--- Spawns a BP_Interact_Pickup_* at the given location/rotation. Returns the actor or nil.
--- Spawned pickups are not part of the level: IsDynamic makes the save system ignore them.
function M.interact(classPath, location, rotation)
    local cls = M.loadClass(classPath)
    if not cls then return nil end
    local world = UEHelpers.GetWorld()
    if not Util.valid(world) then Log.warn("No world to spawn in"); return nil end
    local actor = nil
    local ok, err = pcall(function() actor = world:SpawnActor(cls, location, rotation) end)
    if not ok or not Util.valid(actor) then
        Log.warn("SpawnActor failed for %s: %s", classPath, tostring(err))
        return nil
    end
    Util.try(function() actor.IsDynamic = true end)
    Log.dbg("Spawned %s", Util.actorName(actor))
    return actor
end

return M
