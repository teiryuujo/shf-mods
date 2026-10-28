--[[
    game.pickup_watch  —  observes the inventory around every pickup and tells listeners what changed.

    Measured flow on BP_Interact_Pickup_C (Blueprint hooks run after the body):
        NeedShowReplaceWeaponUI      first thing every interaction does, inventory untouched -> snapshot
        ShowReplace*UI               (replace path) dialog opened, inventory still untouched
        OnReplace*UIEnd              IsSuccess = false: the player cancelled                   -> forget
        HandlePickupFail                                                                      -> forget
        HandlePickupSuccess          inventory changed (plain pickup or exchange)              -> diff, notify

    Weapon listeners get (interactActor, ev):
        ev.before / ev.after    slot snapshots { fog = {...}, dark = {...} }
        ev.changes              Inventory.diffWeaponSlots(before, after)
        ev.names                weapon row names by IDIndex + 1
        ev.inv                  the inventory component
    Consumable listeners get (interactActor, ev):
        ev.before / ev.after    { [IDIndex] = total quantity }
        ev.pickupId / ev.pickupCount   what the pickup itself held (nil for a weapon pickup)
        ev.names, ev.inv
--]]
local Log       = require("core.log")
local Util      = require("core.util")
local Hooks     = require("core.hooks")
local Const     = require("game.const")
local Inventory = require("game.inventory")

local M = {}

local snapshots = {}   -- interact actor address -> snapshot
local weaponListeners, consumableListeners = {}, {}
local hooksInstalled = false

local function take(self, why)
    local inv = Inventory.get()
    if not inv then Log.warn("pickup watch: no inventory (%s)", why); return end
    local pickupId, pickupCount = Inventory.pickupConsumable(self)
    local snap = {
        weaponNames     = Inventory.weaponNames(inv),
        weaponSlots     = Inventory.weaponSlots(inv),
        consumableNames = Inventory.consumableNames(inv),
        consumables     = Inventory.consumableTotals(inv),
        pickupId        = pickupId,
        pickupCount     = pickupCount,
        pickupWeaponId  = Inventory.pickupWeapon(self),
        replace         = false,   -- set once a replace dialog opened for this pickup
    }
    snapshots[self:GetAddress()] = snap
    Log.dbg("%s on %s (%s): %s %s", why, Util.actorName(self),
        pickupId and string.format("%s x%d", pickupId, pickupCount) or "weapon",
        Inventory.describeWeaponSlots(snap.weaponSlots, snap.weaponNames),
        Inventory.describeConsumableTotals(snap.consumables, snap.consumableNames))
end

local function forget(self, why)
    if snapshots[self:GetAddress()] then
        snapshots[self:GetAddress()] = nil
        Log.dbg("pickup %s on %s", why, Util.actorName(self))
    end
end

local function notify(listeners, self, ev, what)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, self, ev)
        if not ok then Log.warn("%s listener failed: %s", what, tostring(err)) end
    end
end

local function onInteractionStarted(self) take(self, "interaction started") end

-- The replace dialog is the real "before" of an exchange: re-snapshot, because the instant-use
-- feature may have consumed an item between the interaction start and the dialog.
local function onReplaceDialogOpened(self)
    take(self, "replace dialog opened")
    local snap = snapshots[self:GetAddress()]
    if snap then snap.replace = true end
end

--- A replace that leaves the slots byte-for-byte identical: the picked-up weapon has the same ID as
--- the one it replaced and enters at full durability, like the one it replaced (measured 2026-10-28
--- 01:07: a dropped Crowbar picked back up over a full Crowbar -> "0 slot change(s)"). The diff
--- cannot see it, but the pickup itself names the weapon, and every other slot is unchanged, so the
--- replaced slot is one holding that ID. Several such slots are indistinguishable: the first is used.
local function identicalReplace(snap, after)
    if not snap.replace or not snap.pickupWeaponId then return nil end
    local idIndex = nil
    for i, n in ipairs(snap.weaponNames) do
        if n == snap.pickupWeaponId then idIndex = i - 1 end
    end
    if idIndex == nil then return nil end
    for _, list in ipairs({ "fog", "dark" }) do
        for i, slot in ipairs(after[list] or {}) do
            if slot.IDIndex == idIndex then
                return { list = list, index = i - 1, before = snap.weaponSlots[list][i], after = slot, identical = true }
            end
        end
    end
    return nil
end

local function onReplaceUIEnd(self, IsSuccess)
    if Util.try(function() return IsSuccess:get() end) == false then forget(self, "cancelled") end
end

local function onHandlePickupFail(self) forget(self, "failed") end

local function onHandlePickupSuccess(self)
    local addr = self:GetAddress()
    local snap = snapshots[addr]
    if not snap then Log.dbg("pickup success on %s without a snapshot", Util.actorName(self)); return end
    snapshots[addr] = nil

    local inv = Inventory.get()
    if not inv then Log.warn("pickup watch: inventory vanished"); return end

    local weaponsNow = Inventory.weaponSlots(inv)
    local changes = Inventory.diffWeaponSlots(snap.weaponSlots, weaponsNow)
    if #changes == 0 then
        local same = identicalReplace(snap, weaponsNow)
        if same then
            changes = { same }
            Log.dbg("identical replace of %s resolved to %s slot %d", snap.pickupWeaponId, same.list, same.index)
        end
    end
    local weaponEv = {
        inv = inv, names = snap.weaponNames, before = snap.weaponSlots, after = weaponsNow,
        changes = changes,
    }
    local consumablesNow = Inventory.consumableTotals(inv)
    local consumableEv = {
        inv = inv, names = snap.consumableNames, before = snap.consumables, after = consumablesNow,
        pickupId = snap.pickupId, pickupCount = snap.pickupCount,
    }
    Log.dbg("pickup done on %s: %s (%d slot change(s)) %s", Util.actorName(self),
        Inventory.describeWeaponSlots(weaponsNow, snap.weaponNames), #weaponEv.changes,
        Inventory.describeConsumableTotals(consumablesNow, snap.consumableNames))

    notify(weaponListeners, self, weaponEv, "weapon")
    notify(consumableListeners, self, consumableEv, "consumable")
end

local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true
    Hooks.on(Const.PICKUP_BP .. ":NeedShowReplaceWeaponUI",    { pre = onInteractionStarted })
    Hooks.on(Const.PICKUP_BP .. ":ShowReplaceWeapon",          { pre = onReplaceDialogOpened })
    Hooks.on(Const.PICKUP_BP .. ":ShowReplaceConsumableUI",    { pre = onReplaceDialogOpened })
    Hooks.on(Const.PICKUP_BP .. ":OnReplaceWeaponUIEnd",       { pre = onReplaceUIEnd })
    Hooks.on(Const.PICKUP_BP .. ":OnReplaceConsumableUIEnd",   { pre = onReplaceUIEnd })
    Hooks.on(Const.PICKUP_BP .. ":HandlePickupFail",           { pre = onHandlePickupFail })
    Hooks.on(Const.PICKUP_BP .. ":HandlePickupSuccess",        { pre = onHandlePickupSuccess })
end

function M.onWeaponsChanged(fn)
    installHooks()
    weaponListeners[#weaponListeners + 1] = fn
end

function M.onConsumablesChanged(fn)
    installHooks()
    consumableListeners[#consumableListeners + 1] = fn
end

return M
