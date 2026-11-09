--[[
    core.util  —  small helpers around the UE4SS Lua API. Nothing here is game-specific.
--]]
local M = {}

--- pcall wrapper: the call's result, or `default` (nil) if it raised.
function M.try(fn, default)
    local ok, v = pcall(fn)
    if ok then return v end
    return default
end
local try = M.try

function M.valid(o)
    return o ~= nil and try(function() return o:IsValid() end) == true
end

function M.nop() end

--- Runs fn on the game thread after `ms` milliseconds.
function M.later(ms, fn)
    ExecuteWithDelay(ms, function() ExecuteInGameThread(fn) end)
end

--- Elements of a TArray, or of a plain Lua table of RemoteUnrealParam (some UE4SS returns), as a list.
function M.elements(arr)
    local t = {}
    if arr == nil then return t end
    -- a plain table without ForEach is a list of wrapped values; anything else is iterated with ForEach
    if type(arr) == "table" and type(rawget(arr, "ForEach")) ~= "function" then
        for i, v in ipairs(arr) do
            local inner = try(function() return v:get() end)
            if inner == nil then inner = v end
            t[i] = inner
        end
        return t
    end
    try(function()
        arr:ForEach(function(i, elem) t[i] = elem:get() end)
    end)
    return t
end

--- TArray<FName> -> { string } (1-based).
function M.names(arr)
    local t = {}
    for i, v in ipairs(M.elements(arr)) do
        t[i] = try(function() return v:ToString() end) or tostring(v)
    end
    return t
end

--- TArray<struct> -> { { field = value } } for the requested fields (1-based).
function M.structs(arr, fields)
    local t = {}
    for i, s in ipairs(M.elements(arr)) do
        local row = {}
        for _, f in ipairs(fields) do row[f] = try(function() return s[f] end) end
        t[i] = row
    end
    return t
end

--- Location and rotation of an actor as plain tables (what SpawnActor accepts).
function M.actorLocRot(actor)
    local loc = actor:K2_GetActorLocation()
    local rot = actor:K2_GetActorRotation()
    return { X = loc.X, Y = loc.Y, Z = loc.Z }, { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }
end

--- Short, stable identity of an actor for log lines.
function M.actorName(actor)
    local full = try(function() return actor:GetFullName() end) or "?"
    return full:match("([^%s]+)%s*$") or full
end

return M
