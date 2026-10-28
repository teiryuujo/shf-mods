--[[
    game.slot_guard  —  borrowing one consumable slot for the duration of a game-side use.

    Measured: AddConsumable refuses silently when the slots are full (returns true, adds nothing), but
    with GetConsumableSlotNum() + 1 it adds a 15th stack, and the count can be put back once the
    stack is gone. The slot count is part of the save game: an earlier mod version once left it
    raised. So the original count is written to a file while a slot is borrowed, the file is removed
    on restore, and main.lua checks it at start (F8 restores by hand).
--]]
local Log       = require("core.log")
local Util      = require("core.util")
local Inventory = require("game.inventory")

local M = {}

local pendingFile = nil   -- path of the marker file, set by configure()

function M.configure(path)
    pendingFile = path
end

local function writeMarker(count)
    if not pendingFile then return end
    local f = io.open(pendingFile, "w")
    if f then f:write(tostring(count)); f:close() end
end

local function clearMarker()
    if pendingFile then os.remove(pendingFile) end
end

--- The slot count stored by an interrupted borrow, or nil.
function M.pendingCount()
    if not pendingFile then return nil end
    local f = io.open(pendingFile, "r")
    if not f then return nil end
    local n = tonumber(f:read("*a"))
    f:close()
    return n
end

--- Puts the slot count back to the stored value (after an interrupted borrow). Returns true on success.
function M.restorePending(inv)
    local n = M.pendingCount()
    if not n then return false end
    local ok, err = pcall(function() inv:SetConsumableSlotNum(n) end)
    if not ok then Log.warn("could not restore the consumable slot count to %d: %s", n, tostring(err)); return false end
    clearMarker()
    Log.info("consumable slot count restored to %d", n)
    return true
end

--- Raw stack list "IDIndex:Quantity ..." including emptied entries, for the log.
local function describeStacks(inv)
    local parts = {}
    for _, c in ipairs(Util.structs(Util.try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
        parts[#parts + 1] = string.format("%s:%s", tostring(c.IDIndex), tostring(c.Quantity))
    end
    return string.format("%d entries [%s]", #parts, table.concat(parts, " "))
end

--- SetConsumableSlotNum(n) truncates the stack array to n entries (measured 2026-10-28 11:05, raw
--- lists in the log). After the game's own UseConsumable the emptied entry (-1:0) is sorted to the
--- end, so the truncation drops exactly that one. After RemoveConsumable from Lua (the interrupted
--- use) the emptied entry stays where the stack was, and the truncation drops the LAST real stack
--- instead (three FoodD at 10:45, one FoodD at 09:49). The totals from before the borrow are
--- therefore the reference, and whatever is missing afterwards is added back: the emptied entry
--- is a free slot by then, so the add succeeds and the inventory ends up exactly as before.
local function restoreLost(inv, totalsBefore)
    local after = Inventory.consumableTotals(inv)
    local names = Inventory.consumableNames(inv)
    for idIndex, wanted in pairs(totalsBefore) do
        local have = after[idIndex] or 0
        if have < wanted then
            local name = names[idIndex + 1] or tostring(idIndex)
            Util.try(function() inv:AddConsumable(FName(name), wanted - have, FName("None")) end)
            local now = Util.try(function() return inv:GetConsumableTotalNum(idIndex) end, have) or have
            if now >= wanted then
                Log.info("slot guard: the shrink dropped %d x %s (emptied entry not last), added back -> %d", wanted - have, name, now)
            else
                Log.warn("slot guard: %d x %s lost when the slot count went back, could only restore to %d (wanted %d)",
                    wanted - have, name, now, wanted)
            end
        end
    end
    for idIndex, have in pairs(after) do
        if have > (totalsBefore[idIndex] or 0) then
            Log.warn("slot guard: %s has %d after the borrow, %d before", names[idIndex + 1] or tostring(idIndex), have, totalsBefore[idIndex] or 0)
        end
    end
end

--- Adds one unit of `id` to a full inventory by granting one extra slot.
--- Returns a release function `release(removeUnit)` on success, nil when nothing was added.
--- The release puts the slot count back; with removeUnit = true it first removes the unit again.
function M.borrowSlotFor(inv, id, idIndex)
    local slots = Util.try(function() return inv:GetConsumableSlotNum() end)
    if not slots then Log.warn("slot guard: cannot read the slot count"); return nil end
    local before = Util.try(function() return inv:GetConsumableTotalNum(idIndex) end, 0) or 0
    local totalsBefore = Inventory.consumableTotals(inv)

    writeMarker(slots)
    local ok, err = pcall(function() inv:SetConsumableSlotNum(slots + 1) end)
    if not ok then Log.warn("slot guard: SetConsumableSlotNum failed: %s", tostring(err)); clearMarker(); return nil end
    Util.try(function() inv:AddConsumable(FName(id), 1, FName("None")) end)
    local after = Util.try(function() return inv:GetConsumableTotalNum(idIndex) end, 0) or 0
    if after <= before then
        Log.warn("slot guard: %s was not added even with an extra slot", id)
        Util.try(function() inv:SetConsumableSlotNum(slots) end)
        clearMarker()
        return nil
    end
    Log.dbg("slot guard: borrowed slot %d for one %s", slots + 1, id)

    local released = false
    return function(removeUnit)
        if released then return end
        released = true
        if removeUnit then Util.try(function() inv:RemoveConsumable(FName(id), 1, false) end) end
        Log.dbg("slot guard: stacks before giving the slot back: %s", describeStacks(inv))
        local okR, errR = pcall(function() inv:SetConsumableSlotNum(slots) end)
        if okR then clearMarker() else Log.warn("slot guard: could not give the slot back: %s", tostring(errR)) end
        Log.dbg("slot guard: slot count back to %d%s, stacks now: %s", slots, removeUnit and " (unit removed)" or "", describeStacks(inv))
        restoreLost(inv, totalsBefore)
    end
end

return M
