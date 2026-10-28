--[[
    probe.inspect  —  turning UE4SS values into readable strings, plus inventory access.

    Everything here is best-effort: a value that cannot be inspected is described by its
    userdata type name instead of raising. Nothing in this module mutates game state.
--]]
local UEHelpers = require("UEHelpers")

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

--- Human readable form of a value (typically RemoteUnrealParam:get()).
function M.describe(v)
    if type(v) ~= "userdata" then return tostring(v) end
    local kind = try(function() return v:type() end) or "userdata"
    local s = try(function() return v:ToString() end)        -- FName / FText / FString
    if type(s) == "string" then return string.format("%s(%q)", kind, s) end
    local full = try(function() return v:GetFullName() end)  -- UObject
    if type(full) == "string" then return string.format("%s<%s>", kind, full) end
    local n = try(function() return v:GetArrayNum() end)     -- TArray
    if type(n) == "number" then return string.format("%s[%d]", kind, n) end
    return kind
end

--- Elements of a TArray, or of a plain Lua table (UE4SS returns some arrays that way), as a list.
function M.elements(arr)
    local t = {}
    if arr == nil then return t end
    if type(arr) == "table" then
        -- elements of such tables are RemoteUnrealParam wrappers: unwrap when possible
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

--- TArray<FName> (or a Lua table of FName) -> { string } (1-based).
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
    if arr == nil then return t end
    try(function()
        arr:ForEach(function(i, elem)
            local s = elem:get()
            local row = {}
            for _, f in ipairs(fields) do row[f] = try(function() return s[f] end) end
            t[i] = row
        end)
    end)
    return t
end

--- Player inventory component and player state, or nil.
function M.getInventory()
    local pc = UEHelpers.GetPlayerController()
    if not M.valid(pc) then return nil end
    local ps = pc.PlayerState
    if not M.valid(ps) then return nil end
    local inv = ps.InventoryComponent
    if not M.valid(inv) then return nil end
    return inv, ps
end

--- One-line summary of weapons (both lists, equipped marked with *) and consumables.
function M.describeInventory(inv)
    local wnames = M.names(try(function() return inv.AllWeaponIDs end))
    local cnames = M.names(try(function() return inv.AllConsumableIDs end))

    local function weapons(arr, equipped)
        local parts = {}
        for i, w in ipairs(M.structs(arr, { "IDIndex", "Durability" })) do
            local slot = i - 1
            parts[#parts + 1] = string.format("%d:%s(%.1f)%s",
                slot, wnames[(w.IDIndex or -1) + 1] or tostring(w.IDIndex), w.Durability or -1,
                slot == equipped and "*" or "")
        end
        return table.concat(parts, " ")
    end

    local function consumables(arr)
        local parts = {}
        for _, c in ipairs(M.structs(arr, { "IDIndex", "Quantity" })) do
            if (c.Quantity or 0) > 0 then
                parts[#parts + 1] = string.format("%s=%d", cnames[(c.IDIndex or -1) + 1] or tostring(c.IDIndex), c.Quantity)
            end
        end
        return table.concat(parts, " ")
    end

    return string.format("inv: useFog=%s fog[%s] dark[%s] cons[%s] slots=%s",
        tostring(try(function() return inv.CurrentUseFogWeapon end)),
        try(function() return weapons(inv.FogWeapons, inv.FogEquippedWeaponIndex) end, "?"),
        try(function() return weapons(inv.DarkWeapons, inv.DarkEquippedWeaponIndex) end, "?"),
        try(function() return consumables(inv.Consumables) end, "?"),
        tostring(try(function() return inv:GetConsumableSlotNum() end)))
end

--- What the inventory UI may base its item index on: stacks, shortcut slots, last selection.
function M.consumableUiState()
    local inv = M.getInventory()
    if not inv then return "inventory: n/a" end
    local names = M.names(try(function() return inv.AllConsumableIDs end))
    local function stacks(arr)
        local parts = {}
        for i, c in ipairs(M.structs(arr, { "IDIndex", "Quantity" })) do
            parts[#parts + 1] = string.format("%d:%s=%s", i - 1, names[(c.IDIndex or -1) + 1] or tostring(c.IDIndex), tostring(c.Quantity))
        end
        return table.concat(parts, " ")
    end
    -- ShortcutConsumables is TArray<int>: one IDIndex (or -1) per quick-wheel slot
    local shortcut = {}
    for i, v in ipairs(M.elements(try(function() return inv.ShortcutConsumables end))) do
        local idx = tonumber(tostring(v)) or -1
        shortcut[#shortcut + 1] = string.format("%d:%s", i - 1, idx >= 0 and (names[idx + 1] or tostring(idx)) or "-")
    end
    return string.format("Consumables[%s] Shortcut[%s] LastSelect=%s %s",
        try(function() return stacks(inv.Consumables) end, "?"),
        table.concat(shortcut, " "),
        tostring(try(function() return inv.LastSelectConsumableIndex end)),
        M.useState())
end

--- The character / inventory flags that may gate the quick-slot use.
function M.useState()
    local inv = M.getInventory()
    local pawn = UEHelpers.GetPlayer()
    local function b(fn) local v = try(fn); return v == nil and "?" or tostring(v) end
    return string.format("trying=%s useShortcut=%s showShortcutUI=%s duringMotion=%s leftKey=%s upperBody=%s",
        b(function() return inv:GetIsTryingToUseConsumableItem() end),
        b(function() return pawn:IsUseShortcutItem() end),
        b(function() return pawn:IsShowShortcutItemUI() end),
        b(function() return pawn:DuringUseShortcutItemMotion() end),
        b(function() return pawn:IsShortcutItemLeftKeyDown() end),
        b(function() return pawn:DuringUpperBodyMotion() end))
end

--- Inventory summary for hook "extra" callbacks; never raises.
function M.inventoryState()
    local inv = M.getInventory()
    if not inv then return "inventory: n/a" end
    return M.describeInventory(inv)
end

return M
