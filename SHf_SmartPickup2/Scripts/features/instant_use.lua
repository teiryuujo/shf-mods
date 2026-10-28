--[[
    Feature 4  —  consumable pickup with a full inventory: offer to use the item on the spot.

    Measured flow of BP_Interact_Pickup_C:ExecuteInstantFeedback:
        NeedShowReplaceConsumableUI(OutValue)   OutValue = not CanAddConsumable(id, count)
        OutValue true  -> ShowReplaceConsumableUI (the replace dialog)
        OutValue false -> HandleOnPickup -> NocePickupBase.OnPickup(...) -> success / fail
    Blueprint hooks run after the body, and out-params can still be overridden. So when the item
    qualifies, OutValue is forced to false and NocePickupBase is cleared: HandleOnPickup then calls
    OnPickup on nothing, fails, and the pickup stays untouched on the ground. The question is asked
    once the Blueprint flow has returned, and the actor is restored (UpdatePickupClass) before acting.

    Decision (Config.InstantUse):
        "off"     never
        "useful"  the game's own CanUseConsumableType(mask) when the row has a mask; rows without one
                  (FoodA, FoodC) are judged by their effect classes (attribute below max / buff not
                  active); offerings (no effects, no repair) never
        "always"  like useful, but effect items skip the check; the repair kit keeps it
    Only single items are offered: a stack always goes to the replace dialog.

    Using it:
        case A  one of this kind is already carried
                -> the game's own use with its animation: the item is selected (TryToUseConsumableItem
                   when it sits in a quick slot, otherwise LastUseConsumableID is written directly),
                   TryActivateAbilityByClass(GA_UseShortcutItem) plays the montage, applies the
                   effect and calls UseConsumable(id) on a notify (see game/consumables.lua). Once that
                   UseConsumable fires, the new item is picked up normally (or the replace dialog
                   opens if it still does not fit). If the ability cannot be started, or the game
                   does not get there in time: UseConsumable(id) removes one and the effects are
                   applied through the ability system (UseConsumable alone changes no attribute).
        case B  not carried -> one consumable slot is borrowed (game/slot_guard.lua), one unit is
                added, the game's use ability plays the animation and removes it, the slot is given
                back and HandlePickupSuccess consumes the pickup. If the ability cannot be started:
                the effects are applied through the ability system (repair kit: the weapon in hand),
                then HandlePickupSuccess consumes the pickup.
--]]
local UEHelpers   = require("UEHelpers")
local Log         = require("core.log")
local Util        = require("core.util")
local Hooks       = require("core.hooks")
local Const       = require("game.const")
local Inventory   = require("game.inventory")
local Consumables = require("game.consumables")
local Dialog      = require("game.dialog")
local Texts       = require("game.texts")
local SlotGuard   = require("game.slot_guard")

local M = {}
local config
local ASK_DELAY_MS        = 100    -- let ExecuteInstantFeedback return before opening our dialog
local USE_ANIMATION_MS    = 5000   -- the use animation takes ~1 s; after this the direct path is used

local pending = {}      -- pickup actor address -> { id, count, haveIt, data, asked }
local pendingUses = {}  -- consumable id -> { used = fn, interrupted = fn(why), done } while the game's use ability runs

local function restorePickupActor(self)
    Util.try(function() self:UpdatePickupClass() end)           -- re-caches NocePickupBase from the child actor
    Util.try(function() self.InteractPawn = UEHelpers.GetPlayer() end)
end

--- Returns an offer table when the pickup qualifies, nil (with a reason in the log) otherwise.
--- Any interactable built on BP_Interact_Pickup qualifies as long as its child actor is a consumable:
--- BP_Interact_Pickup_Exchange_* (decompiled) only swaps the child class in PrepareToSetupClass and
--- then runs the plain pickup flow; Letter / Oma / Key pickups have no consumable child.
local function evaluate(self)
    local id, count = Inventory.pickupConsumable(self)
    if not id then return nil end
    local inv, ps = Inventory.get()
    if not inv or not ps then Log.dbg("instant use: no inventory / player state"); return nil end
    local data = Consumables.data(id)
    if not data then return nil end

    local effects = #Consumables.effectClassPaths(data)
    local recover = Consumables.recoverRatio(data)
    if effects == 0 and recover <= 0 then Log.dbg("%s has no effect of its own, leaving the replace UI", id); return nil end
    if count > 1 then Log.dbg("%s x%d is a stack, leaving the replace UI", id, count); return nil end

    local skipCheck = config.InstantUse == "always" and effects > 0
    if not skipCheck and not Consumables.usefulNow(ps, data) then
        Log.dbg("%s is not useful right now (%s), leaving the replace UI", id, Consumables.describeAttributes(ps))
        return nil
    end

    local names = Inventory.consumableNames(inv)
    local totals = Inventory.consumableTotals(inv)
    local haveIt = false
    for i, n in ipairs(names) do
        if n == id then haveIt = (totals[i - 1] or 0) > 0 end
    end
    return { id = id, count = count, haveIt = haveIt, data = data }
end

--- Applies the item's effects (and the repair, for a repair kit). Returns true when something was applied.
local function applyItem(inv, ps, offer)
    local applied, total = Consumables.applyEffects(ps, offer.data)
    local repaired = false
    local ratio = Consumables.recoverRatio(offer.data)
    if ratio > 0 then
        repaired = Consumables.repairWeaponInHand(ratio) or Consumables.repairEquippedInInventory(inv, ratio)
    end
    local ok = (total > 0 and applied == total) or repaired
    Log.info("%s: %d/%d effects applied%s -> %s", offer.id, applied, total,
        repaired and ", weapon repaired" or "", Consumables.describeAttributes(ps))
    return ok
end

--- The pickup is no longer ours to steer: repeated interactions go back to the game's own flow.
--- Kept until the whole use (dialog, animation, pickup) is over, so that pressing "interact" again
--- while the animation runs does not open a second question over it (measured 2026-10-28 01:32).
--- Every interaction while the pickup is ours leaves NocePickupBase nil and InteractPawn null
--- (the Blueprint's HandleOnPickup clears the pawn), so the actor is put back in order here:
--- measured 2026-10-28 09:18:53, a second press during the animation left the pickup dead and
--- HandleOnPickup after the use failed silently.
--- The game's own way of hiding a pickup for a while (HideMe / ShowMe in BP_Interact_Pickup, gated
--- there by PickupThenHideMe): trigger off (the prompt goes away and presses miss the actor), the
--- actor hidden, the hint areas off. Used while the game's use animation runs, so the item does not
--- lie on the ground for another second or two; shown again on every exit through releasePickup.
local hidden = {}   -- pickup actor address -> true while hidden by this module

local function hidePickup(self)
    local addr = Util.try(function() return self:GetAddress() end)
    if not addr or hidden[addr] then return end
    hidden[addr] = true
    Util.try(function() self.TriggerBox:SetCollisionEnabled(0) end)
    Util.try(function() self:SetActorHiddenInGame(true) end)
    Util.try(function() self:SetHintCollisionsType(0) end)
end

local function showPickup(self)
    local addr = Util.try(function() return self:GetAddress() end)
    if not addr or not hidden[addr] then return end
    hidden[addr] = nil
    if not Util.valid(self) then return end
    Util.try(function() self.TriggerBox:SetCollisionEnabled(1) end)
    Util.try(function() self:SetActorHiddenInGame(false) end)
    Util.try(function() self.PickupClass:SetHiddenInGame(false, false) end)
    Util.try(function() self:SetHintCollisionsType(1) end)
end

local function releasePickup(self)
    local addr = Util.try(function() return self:GetAddress() end)
    if addr then pending[addr] = nil end
    showPickup(self)
    if Util.valid(self) then restorePickupActor(self) end
end

--- Case A, last step: the carried one is gone, take the new one.
local function takeNewOne(self, inv, offer)
    releasePickup(self)
    if not Util.valid(self) then Log.dbg("pickup actor vanished after the use"); return end
    if Util.try(function() return inv:CanAddConsumable(FName(offer.id), offer.count) end, false) then
        Util.try(function() self:HandleOnPickup() end)
        Log.info("Used one %s from the inventory and picked the new one up", offer.id)
    else
        Log.dbg("Used one %s but the new one still does not fit, opening the replace UI", offer.id)
        Util.try(function() self:ShowReplaceConsumableUI() end)
    end
end

--- Case A without the game's animation: remove one, apply the effects ourselves.
local function useDirectly(self, inv, ps, offer)
    local ok, err = pcall(function() inv:UseConsumable(FName(offer.id)) end)
    if not ok then Log.warn("UseConsumable(%s) failed: %s", offer.id, tostring(err)); releasePickup(self); return end
    if not applyItem(inv, ps, offer) then Log.warn("%s: effect could not be applied", offer.id) end
    takeNewOne(self, inv, offer)
end

--- Runs the game's use ability for `id` from `slot` and routes its outcome:
---   handlers.used()        UseConsumable(id) fired: the game played the animation and removed the unit
---   handlers.interrupted() the ability ended without using it (hit, dodge ...) or never got there
--- Returns false (nothing registered) when the ability could not be started.
--- How the game's use was selected, for the log.
local function via(slot)
    return slot and string.format("from quick slot %d", slot) or "by id (no quick slot)"
end

local function startAnimatedUse(inv, ps, id, slot, handlers)
    local entry = { done = false }
    local function finish(kind, why)
        if entry.done then return end
        entry.done = true
        if pendingUses[id] == entry then pendingUses[id] = nil end
        if kind == "used" then handlers.used() else Log.info("%s: use interrupted (%s), nothing changed", id, why); handlers.interrupted() end
    end
    entry.used        = function() finish("used") end
    entry.interrupted = function(why) finish("interrupted", why) end
    pendingUses[id] = entry
    local started
    if slot then started = Consumables.useFromQuickSlot(inv, ps, id, slot) else started = Consumables.useById(inv, ps, id) end
    if not started then
        pendingUses[id] = nil
        return false
    end
    -- the ability can end inside the activation call itself (measured 2026-10-28 01:31:58):
    -- then the entry is already finished as interrupted and there is nothing to wait for
    if entry.done then return true end
    Log.dbg("%s: use ability started %s, waiting for UseConsumable", id, via(slot))
    Util.later(USE_ANIMATION_MS, function() entry.interrupted("no UseConsumable within " .. USE_ANIMATION_MS .. " ms") end)
    return true
end

--- True while the game is using an item for us (animation running).
local function useInProgress()
    return next(pendingUses) ~= nil
end

--- Case A through the game's use ability: it plays the animation, applies the effect and removes the item.
--- An interruption (the game's own rule for being hit while using) leaves everything as it was: the
--- carried unit stays, the pickup stays on the ground, no effect is applied.
local function useWithAnimation(self, inv, ps, offer, slot)
    local id = offer.id
    local started = startAnimatedUse(inv, ps, id, slot, {
        used = function()
            Log.info("%s used by the game %s -> %s", id, via(slot), Consumables.describeAttributes(ps))
            takeNewOne(self, inv, offer)
        end,
        interrupted = function() releasePickup(self) end,
    })
    if not started then
        Log.warn("%s: the game's use ability could not be started, using it directly", id)
        useDirectly(self, inv, ps, offer)
    elseif pendingUses[id] then
        hidePickup(self)                     -- still waiting for the animation: nothing on the ground meanwhile
    end
end

--- Case B without the animation: the pickup itself is consumed without ever entering the inventory.
local function consumeDirectly(self, inv, ps, offer)
    releasePickup(self)
    if applyItem(inv, ps, offer) then
        Util.try(function() self:HandlePickupSuccess() end)
        Log.info("Used %s directly on pickup", offer.id)
    else
        Log.warn("%s: effects could not be applied, opening the replace UI", offer.id)
        Util.try(function() self:ShowReplaceConsumableUI() end)
    end
end

--- Case B with the animation: one slot is borrowed, the unit is added, the game uses it (and removes
--- it on its notify), the slot is given back and the ground pickup is consumed.
local function consumeWithAnimation(self, inv, ps, offer, slot)
    local id = offer.id
    local idIndex = nil
    for i, n in ipairs(Inventory.consumableNames(inv)) do
        if n == id then idIndex = i - 1 end
    end
    local release = idIndex and SlotGuard.borrowSlotFor(inv, id, idIndex)
    if not release then
        consumeDirectly(self, inv, ps, offer)
        return
    end
    local started = startAnimatedUse(inv, ps, id, slot, {
        used = function()
            release(false)                       -- the game removed the unit on its notify
            releasePickup(self)
            Log.info("%s used by the game %s -> %s", id, via(slot), Consumables.describeAttributes(ps))
            if Util.valid(self) then Util.try(function() self:HandlePickupSuccess() end) end
            Log.info("Used %s on pickup through the game's animation", id)
        end,
        interrupted = function()
            release(true)                        -- take the unit back out, give the slot back; the pickup stays
            releasePickup(self)
        end,
    })
    if not started then
        release(true)
        Log.warn("%s: the game's use ability could not be started, consuming the pickup directly", id)
        consumeDirectly(self, inv, ps, offer)
    elseif pendingUses[id] then
        hidePickup(self)
    end
end

local function useNow(self, offer)
    local inv, ps = Inventory.get()
    if not inv or not ps then return end
    -- with a quick slot the game selects the item itself (TryToUseConsumableItem); without one the
    -- id is written to LastUseConsumableID directly (Consumables.useById). Both run the same ability.
    local animate = config.UseGameAnimation
    local slot = animate and Consumables.quickSlotOf(inv, offer.id) or nil

    if offer.haveIt then
        if animate then useWithAnimation(self, inv, ps, offer, slot) else useDirectly(self, inv, ps, offer) end
        return
    end
    if animate then consumeWithAnimation(self, inv, ps, offer, slot) else consumeDirectly(self, inv, ps, offer) end
end

local function ask(self, offer)
    if offer.asked then return end
    offer.asked = true
    local addr = self:GetAddress()

    local function decide(yes)
        if not Util.valid(self) then pending[addr] = nil; Log.dbg("pickup actor vanished before the decision"); return end
        restorePickupActor(self)
        if yes then
            useNow(self, offer)              -- the pickup stays "ours" until the use is over (releasePickup)
        else
            pending[addr] = nil
            Log.dbg("player declined instant use of %s, opening the replace UI", offer.id)
            Util.try(function() self:ShowReplaceConsumableUI() end)
        end
    end

    if not config.ConfirmInstantUse then decide(true); return end
    local text = Texts.get("use", Consumables.displayName(offer.data, offer.id))
    if not Dialog.ask(self, text, decide) then
        Log.warn("dialog unavailable, leaving %s to the replace UI", offer.id)
        decide(false)
    end
end

local function onNeedShowReplaceConsumableUI(self, OutValue)
    local addr = self:GetAddress()
    if pending[addr] then
        -- the player interacted again while our question is pending: keep the Blueprint idle
        Util.try(function() OutValue:set(false) end)
        Util.try(function() self.NocePickupBase = nil end)
        return
    end
    if Util.try(function() return OutValue:get() end) ~= true then return end   -- fits: vanilla pickup
    if Dialog.isOpen() then Log.dbg("a dialog is already open, leaving this pickup to the game"); return end
    if useInProgress() then Log.dbg("an item is being used right now, leaving this pickup to the game"); return end

    local offer = evaluate(self)
    if not offer then return end

    local ok, err = pcall(function() OutValue:set(false) end)
    if not ok then Log.warn("OutValue:set failed: %s", tostring(err)); return end
    Util.try(function() self.NocePickupBase = nil end)
    pending[addr] = offer
    Log.dbg("offering instant use of %s (carried: %s)", offer.id, tostring(offer.haveIt))
    Util.later(ASK_DELAY_MS, function()
        local o = pending[addr]
        if o and Util.valid(self) then ask(self, o) end
    end)
end

--- Safety net: the replace dialog opened although OutValue was overridden -> close it, then ask.
local function onShowReplaceConsumableUI(self)
    local offer = pending[self:GetAddress()]
    if not offer or offer.asked then return end
    Log.warn("replace UI opened despite the override, closing it and asking")
    local w = Util.try(function() return self.ReplaceConsumableUI end)
    if not Util.valid(w) then pending[self:GetAddress()] = nil; restorePickupActor(self); return end
    local closed = Util.try(function() w:Cancel(); return true end) or Util.try(function() w:ForceClose(); return true end)
    if closed and Dialog.onceFadedOut(w, function()
        if Util.valid(self) and pending[self:GetAddress()] then ask(self, pending[self:GetAddress()]) end
    end) then return end
    pending[self:GetAddress()] = nil
    restorePickupActor(self)
end

local function onHandlePickupSuccess(self)
    pending[self:GetAddress()] = nil
end

--- The game consumed an item (quick slot, inventory UI or our ability run): wake the pending use, if any.
local function onUseConsumable(self, ID)
    local id = Util.try(function() return ID:get():ToString() end)
    local entry = id and pendingUses[id]
    if entry then entry.used(); return end
    -- not ours: the quick slot, the inventory UI or a direct call. Logged so that a stack that
    -- goes missing between two pickups can be traced (2026-10-28 09:49: one FoodD vanished unseen)
    Log.dbg("game used %s on its own -> %s", tostring(id),
        Inventory.describeConsumableTotals(Inventory.consumableTotals(self), Inventory.consumableNames(self)))
end

--- GA_UseShortcutItem ended (Blueprint hook, runs after the body). In a normal run UseConsumable has
--- already fired on the montage notify; a pending entry that is still waiting means the use was
--- interrupted (hit, dodge, cancelled) and the game did not consume the item.
local function onUseAbilityEnd(_, bWasCancelled)
    local cancelled = Util.try(function() return bWasCancelled:get() end)
    for id, entry in pairs(pendingUses) do
        entry.interrupted(cancelled and "ability cancelled" or "ability ended without UseConsumable")
    end
end

function M.install(cfg)
    config = cfg
    if cfg.InstantUse == "off" then
        Log.info("feature 4 (instant use) is off")
        return
    end
    Hooks.on(Const.PICKUP_BP .. ":NeedShowReplaceConsumableUI", { pre = onNeedShowReplaceConsumableUI })
    Hooks.on(Const.PICKUP_BP .. ":ShowReplaceConsumableUI",     { pre = onShowReplaceConsumableUI })
    Hooks.on(Const.PICKUP_BP .. ":HandlePickupSuccess",         { pre = onHandlePickupSuccess })
    if cfg.UseGameAnimation then
        Hooks.on(Const.INVENTORY_COMPONENT .. ":UseConsumable", { post = onUseConsumable })
        Hooks.on(Const.USE_ABILITY_BP .. ":K2_OnEndAbility",    { pre = onUseAbilityEnd })
    end
    if cfg.ConfirmInstantUse then Dialog.prepare() end
    Log.info("feature 4 (instant use, mode %s, confirm %s, animation %s) installed",
        cfg.InstantUse, tostring(cfg.ConfirmInstantUse), tostring(cfg.UseGameAnimation))
end

return M
