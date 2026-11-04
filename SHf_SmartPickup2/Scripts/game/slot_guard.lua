--[[
    game.slot_guard  —  freeing one consumable slot for the duration of a game-side use.

    Measured: AddConsumable refuses silently when the slots are full (returns true, adds nothing), but
    RemoveConsumable leaves an emptied entry (-1:0) that the next AddConsumable fills. So all stacks of
    one ID are taken out, the unit goes into their place, and they are put back once the unit is gone.
    The slot count, which is part of the save game, is never touched.

    The stack lives only in `out` meanwhile. A crash loses nothing (the save on disk still has it). A
    save in that second would store the inventory without it: such saves are logged as WARN, see
    installSaveWatch. Quick slots keep their assignment when the item is not carried (FINDINGS), but a
    stack outside them is preferred, and the layout is compared and repaired after the put-back.
--]]
local Log       = require("core.log")
local Util      = require("core.util")
local Hooks     = require("core.hooks")
local Const     = require("game.const")
local Inventory = require("game.inventory")
local Drops     = require("game.drops")

local M = {}

local out = nil   -- { name, count } while a stack is out of the inventory

--- Raw stack list "IDIndex:Quantity ..." including emptied entries, for the log.
local function describeStacks(inv)
    local parts = {}
    for _, c in ipairs(Util.structs(Util.try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
        parts[#parts + 1] = string.format("%s:%s", tostring(c.IDIndex), tostring(c.Quantity))
    end
    return string.format("%d entries [%s]", #parts, table.concat(parts, " "))
end

--- IDIndex per quick slot, 1-based (slot number + 1).
local function quickSlots(inv)
    local slots = {}
    for i, v in ipairs(Util.elements(Util.try(function() return inv.ShortcutConsumables end))) do
        slots[i] = tonumber(tostring(v))
    end
    return slots
end

--- What to take out: all stacks of one ID, since a full inventory usually splits every ID over several
--- stacks (measured 2026-11-01: six IDs in 14 stacks) and removing part of one may free no entry.
--- Outside the quick slots if possible, the smallest total.
--- Returns { idIndex, count = total, parts = { quantity per stack } } or nil.
local function pickStack(inv, slots)
    local onQuickSlot, byId = {}, {}
    for _, idIndex in ipairs(slots) do onQuickSlot[idIndex] = true end
    for _, c in ipairs(Util.structs(Util.try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
        if c.IDIndex and c.IDIndex >= 0 and (c.Quantity or 0) > 0 then
            local e = byId[c.IDIndex] or { idIndex = c.IDIndex, count = 0, parts = {} }
            e.count = e.count + c.Quantity
            e.parts[#e.parts + 1] = c.Quantity
            byId[c.IDIndex] = e
        end
    end
    local best, bestQuick = nil, nil
    for idIndex, e in pairs(byId) do
        local quick = onQuickSlot[idIndex] == true
        if not best or (bestQuick and not quick) or (bestQuick == quick and e.count < best.count) then
            best, bestQuick = e, quick
        end
    end
    return best
end

--- Adds back what is missing of the stack, one original stack per call so that no call exceeds the
--- stack limit. Compared with the total, so that a save loaded in the meantime, which brought the
--- stack back by itself, does not duplicate it. If it does not fit, the rest goes on the ground
--- rather than being lost.
local function putBack(inv, stack, loc, rot)
    local total = function() return Util.try(function() return inv:GetConsumableTotalNum(stack.idIndex) end, 0) or 0 end
    if total() >= stack.count then
        Log.dbg("slot guard: %s is already back", stack.name)
        return
    end
    for _, quantity in ipairs(stack.parts) do
        local add = math.min(quantity, stack.count - total())
        if add > 0 then Util.try(function() inv:AddConsumable(FName(stack.name), add, FName("None")) end) end
    end
    local missing = stack.count - total()
    if missing > 0 then
        Log.warn("slot guard: %d x %s did not fit back, dropping them", missing, stack.name)
        if not Drops.consumable(stack.name, missing, loc, rot) then
            Log.warn("slot guard: %d x %s lost, the drop failed", missing, stack.name)
        end
    end
end

local function repairQuickSlots(inv, slots, names)
    local now = quickSlots(inv)
    for i, idIndex in ipairs(slots) do
        local name = names[idIndex + 1]
        if now[i] ~= idIndex and name then
            Log.warn("slot guard: quick slot %d changed (%s, was %s), restoring", i - 1, tostring(now[i]), name)
            Util.try(function() inv:EquipConsumable(FName(name), i - 1) end)
        end
    end
end

--- Adds one unit of `id` to a full inventory by taking one stack out for a moment.
--- Returns a release function `release(removeUnit)` on success, nil when nothing was changed.
--- The release puts the stack back; with removeUnit = true it first removes the unit again.
--- loc, rot: where the stack lands should it not fit back.
function M.borrowSlotFor(inv, id, idIndex, loc, rot)
    local slots = quickSlots(inv)
    local names = Inventory.consumableNames(inv)
    local stack = pickStack(inv, slots)
    if stack then stack.name = names[stack.idIndex + 1] end
    if not stack or not stack.name then Log.dbg("slot guard: no stack can be taken out"); return nil end

    Util.try(function() inv:RemoveConsumable(FName(stack.name), stack.count, false) end)
    if Util.try(function() return inv:GetConsumableTotalNum(stack.idIndex) end, 1) ~= 0 then
        Log.warn("slot guard: %d x %s could not be taken out", stack.count, stack.name)
        putBack(inv, stack, loc, rot)
        return nil
    end
    out = stack
    Util.try(function() inv:AddConsumable(FName(id), 1, FName("None")) end)
    if (Util.try(function() return inv:GetConsumableTotalNum(idIndex) end, 0) or 0) < 1 then
        Log.warn("slot guard: %s was not added in the place of %s", id, stack.name)
        out = nil
        putBack(inv, stack, loc, rot)
        return nil
    end
    Log.dbg("slot guard: %d x %s taken out for one %s", stack.count, stack.name, id)

    local released = false
    return function(removeUnit)
        if released then return end
        released = true
        out = nil
        if not Util.valid(inv) then Log.info("slot guard: the inventory is gone (a save was loaded?), nothing to put back"); return end
        -- the stack is back without us: a save was loaded, and any unit of `id` now is the save's own
        local reloaded = (Util.try(function() return inv:GetConsumableTotalNum(stack.idIndex) end, 0) or 0) >= stack.count
        if removeUnit and not reloaded then Util.try(function() inv:RemoveConsumable(FName(id), 1, false) end) end
        putBack(inv, stack, loc, rot)
        repairQuickSlots(inv, slots, names)
        Log.dbg("slot guard: %d x %s back%s, stacks now: %s", stack.count, stack.name, removeUnit and " (unit removed)" or "", describeStacks(inv))
    end
end

--- True while a stack is out of the inventory.
function M.isOut()
    return out ~= nil
end

--- Logs every game save, and warns when one happens while a stack is out: that save lacks the stack.
--- OnSaveGameSlot is a delegate handler and also sees saves started from C++, which the *_BP entry
--- points do not, so one save can give several lines.
function M.installSaveWatch()
    for _, fn in ipairs(Const.SAVE_FUNCTIONS) do
        Hooks.on(fn, { pre = function()
            local what = fn:match("[^:]+$")
            if out then
                Log.warn("game save (%s) while %d x %s is out of the inventory: that save does not have the stack", what, out.count, out.name)
            else
                Log.dbg("game save: %s", what)
            end
        end })
    end
end

return M
