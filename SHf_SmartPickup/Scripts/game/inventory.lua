--[[
    game.inventory  —  read access to NocePlayerInventoryComponent.

    Weapon model (measured): FogWeapons has 4 slots, DarkWeapons 3; a slot is { IDIndex, Durability }
    with IDIndex = -1 when empty. Slots are positional: a replace rewrites one slot in place and a
    pickup fills an empty one, so the slot that changed identifies the item exactly.
--]]
local UEHelpers = require("UEHelpers")
local Util  = require("core.util")
local Const = require("game.const")

local M = {}

local SLOT_FIELDS = { "IDIndex", "Durability" }

--- Inventory component and player state of the local player, or nil.
function M.get()
    local pc = UEHelpers.GetPlayerController()
    if not Util.valid(pc) then return nil end
    local ps = pc.PlayerState
    if not Util.valid(ps) then return nil end
    local inv = ps.InventoryComponent
    if not Util.valid(inv) then return nil, ps end
    return inv, ps
end

--- Weapon row names by IDIndex + 1.
function M.weaponNames(inv)
    return Util.names(Util.try(function() return inv.AllWeaponIDs end))
end

--- Snapshot of both weapon lists: { fog = { slot... }, dark = { slot... } }.
function M.weaponSlots(inv)
    return {
        fog  = Util.structs(Util.try(function() return inv.FogWeapons end),  SLOT_FIELDS),
        dark = Util.structs(Util.try(function() return inv.DarkWeapons end), SLOT_FIELDS),
    }
end

local function sameSlot(a, b)
    if not a or not b then return false end
    return a.IDIndex == b.IDIndex and math.abs((a.Durability or 0) - (b.Durability or 0)) < 0.001
end

--- Slots that differ between two snapshots: { { list = "fog"|"dark", index = 0-based, before, after } }.
function M.diffWeaponSlots(before, after)
    local changes = {}
    for _, list in ipairs({ "fog", "dark" }) do
        local b, a = before[list] or {}, after[list] or {}
        for i = 1, math.max(#b, #a) do
            if not sameSlot(b[i], a[i]) then
                changes[#changes + 1] = { list = list, index = i - 1, before = b[i], after = a[i] }
            end
        end
    end
    return changes
end

------------------------------------------------------------------------------
-- Consumables: one entry per stack, re-sorted by the game on every change -> compare totals per ID
------------------------------------------------------------------------------

--- Consumable row names by IDIndex + 1.
function M.consumableNames(inv)
    return Util.names(Util.try(function() return inv.AllConsumableIDs end))
end

--- { [IDIndex] = total quantity } over all stacks.
function M.consumableTotals(inv)
    local totals = {}
    for _, c in ipairs(Util.structs(Util.try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
        if c.IDIndex and (c.Quantity or 0) > 0 then
            totals[c.IDIndex] = (totals[c.IDIndex] or 0) + c.Quantity
        end
    end
    return totals
end

function M.describeConsumableTotals(totals, names)
    local keys = {}
    for idIndex in pairs(totals) do keys[#keys + 1] = idIndex end
    table.sort(keys)
    local parts = {}
    for _, idIndex in ipairs(keys) do
        parts[#parts + 1] = string.format("%s=%d", names[idIndex + 1] or tostring(idIndex), totals[idIndex])
    end
    return "cons[" .. table.concat(parts, " ") .. "]"
end

--- Row name of the weapon a pickup interactable holds; nil for consumables and others.
function M.pickupWeapon(interactActor)
    local child = Util.try(function() return interactActor.PickupClass.ChildActor end)
    if not Util.valid(child) then return nil end
    local id = Util.try(function() return child.WeaponID.RowName:ToString() end)
    if not id or id == "" or id == "None" then return nil end
    return id
end

--- Row name and count of the consumable a pickup interactable holds; nil for weapons and others.
function M.pickupConsumable(interactActor)
    local child = Util.try(function() return interactActor.PickupClass.ChildActor end)
    if not Util.valid(child) then return nil end
    local id = Util.try(function() return child.ConsumableID.RowName:ToString() end)
    if not id or id == "" or id == "None" then return nil end
    local count = Util.try(function() return child.Count end, 1)
    if not count or count < 1 then count = 1 end
    return id, count
end

function M.describeWeaponSlots(slots, names)
    local function one(list)
        local parts = {}
        for i, w in ipairs(list or {}) do
            local idx = w.IDIndex or Const.EMPTY_SLOT
            local name = idx == Const.EMPTY_SLOT and "-" or (names[idx + 1] or tostring(idx))
            parts[#parts + 1] = string.format("%d:%s(%.0f)", i - 1, name, w.Durability or -1)
        end
        return table.concat(parts, " ")
    end
    return string.format("fog[%s] dark[%s]", one(slots.fog), one(slots.dark))
end

return M
