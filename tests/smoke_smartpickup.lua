-- Smoke test for SHf_SmartPickup under plain Lua 5.4: stubs the UE4SS globals, loads the mod,
-- then replays the measured pickup flows against a fake inventory.
-- Run from the mod's Scripts directory:  ../../../tools/lua/lua54.exe ../../tests/smoke_smartpickup.lua

local hooks = {}
RegisterHook = function(fn, pre, post) hooks[fn] = { pre = pre, post = post } end
LoopAsync = function() end
ExecuteInGameThread = function(f) f() end
-- short delays (dialog / ask scheduling) run at once; longer ones (the use-animation watch, dialog
-- timeouts) stay queued until runTimers()
local timers = {}
ExecuteWithDelay = function(ms, f) if ms <= 100 then f() else timers[#timers + 1] = f end end
local function runTimers()
    local due = timers
    timers = {}
    for _, f in ipairs(due) do f() end
end
local gameTime = 100.0   -- GameplayStatics:GetTimeSeconds; stops while "paused"
-- log capture, for the WARN checks
local logLines = {}
local realPrint = print
print = function(s) logLines[#logLines + 1] = s end
local function logged(pattern)
    for _, l in ipairs(logLines) do if l:find(pattern) then return true end end
    return false
end
FName = function(s) return { ToString = function() return s end } end
FText = function(s) return s end
Key = { F8 = 8 }
RegisterKeyBind = function() end

-- consumable rows as GetConsumableData returns them (Lua tables); effects carry SoftClassPath-like structs
local function effect(pkg, asset) return { AssetPath = { PackageName = FName(pkg), AssetName = FName(asset) } } end
local CONSUMABLE_DATA = {
    MedKitA = { Name = "Med Kit A", ItemAttributeCheckType = 1, WeaponDurabilityRecoverRatio = 0, GameplayEffects = { effect("/Game/GE_RecoverHealth_L", "GE_RecoverHealth_L_C") } },
    MedKitB = { Name = "Med Kit B", ItemAttributeCheckType = 1, WeaponDurabilityRecoverRatio = 0, GameplayEffects = { effect("/Game/GE_RecoverHealth_XL", "GE_RecoverHealth_XL_C") } },
    DrinkA  = { Name = "Drink A",   ItemAttributeCheckType = 22, WeaponDurabilityRecoverRatio = 0, GameplayEffects = { effect("/Game/GE_Sanity", "GE_Sanity_C") } },
    FaithB  = { Name = "Offering",  ItemAttributeCheckType = 0, WeaponDurabilityRecoverRatio = 0, GameplayEffects = {} },
    FoodA   = { Name = "Higashi",   ItemAttributeCheckType = 0, WeaponDurabilityRecoverRatio = 0, GameplayEffects = { effect("/Game/GE_FullStamina", "GE_FullStamina_C") } },
    DrinkB  = { Name = "Drink B",   ItemAttributeCheckType = 22, WeaponDurabilityRecoverRatio = 0, GameplayEffects = { effect("/Game/GE_Sanity", "GE_Sanity_C") } },
    FoodD   = { Name = "Yokan",     ItemAttributeCheckType = 1, WeaponDurabilityRecoverRatio = 0, GameplayEffects = { effect("/Game/GE_RecoverHealth_L", "GE_RecoverHealth_L_C") } },
}
local usefulNow = true
-- gameplay effect class default objects as the reflection exposes them
local GE_CDO = {
    GE_FullStamina_C     = { DurationPolicy = 0, Executions = {}, Modifiers = { { Attribute = { AttributeName = FName("Stamina") } } } },
    GE_RecoverHealth_L_C = { DurationPolicy = 0, Executions = { "exec" }, Modifiers = {} },
}
StaticFindObject = function(path)
    local cdoName = path:match("Default__([%w_]+)$")
    if cdoName and GE_CDO[cdoName] then
        local o = { IsValid = function() return true end }
        for k, v in pairs(GE_CDO[cdoName]) do o[k] = v end
        return o
    end
    if path:find("NoceInventoryFunctionLibrary") then
        return { IsValid = function() return true end, GetConsumableData = function(_, fn) return CONSUMABLE_DATA[fn:ToString()] end }
    elseif path:find("KismetInternationalizationLibrary") then
        return { IsValid = function() return true end, GetCurrentLanguage = function() return FName("en") end }
    elseif path:find("WidgetBlueprintLibrary") then
        return { IsValid = function() return true end }
    end
    return { path = path, IsValid = function() return true end }
end
LoadAsset = StaticFindObject

-- fake UE objects --------------------------------------------------------------
local function fname(s) return { ToString = function() return s end } end
local function tarray(items)
    return { ForEach = function(_, cb) for i, v in ipairs(items) do cb(i, { get = function() return v end }) end end }
end
local function param(v) return { get = function() return v end } end
local function slot(id, dur) return { IDIndex = id, Durability = dur } end

local durabilityWrites, equippedWrites = {}, {}
local inv = {
    IsValid = function() return true end,
    AllWeaponIDs = tarray({ fname("Pipe"), fname("Axe"), fname("Bat"), fname("Crowbar"), fname("Katana") }),
    CurrentUseFogWeapon = true,
    GetEquippedWeaponIndex = function() return 2 end,
    SetWeaponDurability = function(_, index, isFog, dur) durabilityWrites[#durabilityWrites + 1] = { index = index, isFog = isFog, dur = dur } end,
    SetEquippedWeaponDurability = function(_, id, dur) equippedWrites[#equippedWrites + 1] = { id = id:ToString(), dur = dur } end,
}
local function setFog(...) inv.FogWeapons = tarray({ ... }) end
inv.DarkWeapons = tarray({ slot(0, 1000), slot(-1, 1000), slot(-1, 1000) })
-- consumables: a model of the measured rules. Up to 3 per stack, 14 entries; RemoveConsumable leaves an
-- emptied entry (-1:0) that the next AddConsumable fills; AddConsumable adds nothing when there is no room.
local CONSUMABLE_IDS = { "MedKitA", "MedKitB", "DrinkA", "FoodA", "FaithB", "DrinkB", "FoodD" }
local ID_INDEX = {}
local idNames = {}
for i, n in ipairs(CONSUMABLE_IDS) do ID_INDEX[n] = i - 1; idNames[i - 1] = n end
local fnames = {}
for _, n in ipairs(CONSUMABLE_IDS) do fnames[#fnames + 1] = fname(n) end
inv.AllConsumableIDs = tarray(fnames)
local MAX_STACK, MAX_ENTRIES = 3, 14
local stacks = {}
local function stack(id, qty) return { IDIndex = id, Quantity = qty } end
local function setConsumables(...) stacks = { ... } end
setmetatable(inv, { __index = function(_, k) if k == "Consumables" then return tarray(stacks) end end })
local function totalOf(idx)
    local n = 0
    for _, c in ipairs(stacks) do if c.IDIndex == idx then n = n + c.Quantity end end
    return n
end
local function addUnits(idx, qty)
    for _, c in ipairs(stacks) do
        if qty > 0 and c.IDIndex == idx and c.Quantity < MAX_STACK then
            local k = math.min(qty, MAX_STACK - c.Quantity); c.Quantity = c.Quantity + k; qty = qty - k
        end
    end
    for _, c in ipairs(stacks) do
        if qty > 0 and c.IDIndex == -1 then
            local k = math.min(qty, MAX_STACK); c.IDIndex, c.Quantity = idx, k; qty = qty - k
        end
    end
    while qty > 0 and #stacks < MAX_ENTRIES do
        local k = math.min(qty, MAX_STACK); stacks[#stacks + 1] = stack(idx, k); qty = qty - k
    end
end
local function removeUnits(idx, qty)
    for i = #stacks, 1, -1 do
        local c = stacks[i]
        if qty > 0 and c.IDIndex == idx then
            local k = math.min(qty, c.Quantity); c.Quantity = c.Quantity - k; qty = qty - k
            if c.Quantity == 0 then c.IDIndex = -1 end
        end
    end
end
--- "MedKitA=9 DrinkA=7 ... entries=14": totals per ID and the number of occupied entries
local function inventoryKey()
    local parts, used = {}, 0
    for i = 0, #CONSUMABLE_IDS - 1 do if totalOf(i) > 0 then parts[#parts + 1] = idNames[i] .. "=" .. totalOf(i) end end
    for _, c in ipairs(stacks) do if c.IDIndex >= 0 then used = used + 1 end end
    return table.concat(parts, " ") .. " entries=" .. used
end
setConsumables(stack(0, 3), stack(0, 3), stack(0, 3), stack(2, 3), stack(2, 1))

local spawned, nextAddr = {}, 1000
--- consumable = { id = "MedKitA", count = 1 } makes the fake interactable hold a consumable child actor;
--- weapon = "Crowbar" a weapon child actor
local function makePickup(name, consumable, weapon)
    nextAddr = nextAddr + 1
    local addr = nextAddr
    local child = { IsValid = function() return true end, Count = consumable and consumable.count or 1 }
    if consumable then child.ConsumableID = { RowName = fname(consumable.id) } end
    if weapon then child.WeaponID = { RowName = fname(weapon) } end
    return {
        IsValid = function() return true end,
        GetAddress = function() return addr end,
        GetFullName = function() return name .. "_" .. addr end,
        K2_GetActorLocation = function() return { X = 1, Y = 2, Z = 3 } end,
        K2_GetActorRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end,
        PickupClass = { ChildActor = child },
    }
end
local world = { IsValid = function() return true end,
    SpawnActor = function(_, cls, loc, rot)
        local con = cls.path:match("Pickup_Con_([%w_]+)_C$")
        local wep = cls.path:match("Pickup_Wep_([%w_]+)_C$")
        local a = makePickup(cls.path:match("([%w_]+)_C$"), con and { id = con, count = 1 } or nil, wep)
        a.cls, a.loc = cls, loc
        spawned[#spawned + 1] = a
        return a
    end }
local effectsApplied = 0
local playerState = {
    IsValid = function() return true end,
    InventoryComponent = inv,
    CanUseConsumableType = function(_, mask) return usefulNow end,
    AbilitySystemComponent = { IsValid = function() return true end, BP_ApplyGameplayEffectToSelf = function() effectsApplied = effectsApplied + 1 end },
    PlayerAttributeSet = { Health = { CurrentValue = 50 }, MaxHealth = { CurrentValue = 100 }, Stamina = { CurrentValue = 1 },
                           MaxStamina = { CurrentValue = 1 }, Sanity = { CurrentValue = 1 }, CurrentMaxSanity = { CurrentValue = 1 } },
}
package.preload["UEHelpers"] = function()
    return {
        GetPlayerController = function() return { IsValid = function() return true end, PlayerState = playerState } end,
        GetWorld = function() return world end,
        GetPlayer = function() return { IsValid = function() return true end } end,
        GetGameplayStatics = function() return { GetTimeSeconds = function() return gameTime end } end,
        GetWorldContextObject = function() return world end,
    }
end
package.path = "./?.lua;" .. package.path

dofile("main.lua")

local BP = "/Game/Blueprint/InteractUnit/BP_Interact_Pickup.BP_Interact_Pickup_C"
local function interactionStarted(pickup) hooks[BP .. ":NeedShowReplaceWeaponUI"].pre(param(pickup), param(false)) end
local function pickupSuccess(pickup)     hooks[BP .. ":HandlePickupSuccess"].pre(param(pickup)) end
local function replaceCancelled(pickup)  hooks[BP .. ":HandlePickupFail"].pre(param(pickup)); hooks[BP .. ":OnReplaceWeaponUIEnd"].pre(param(pickup), param(false), param(false), param(fname("x"))) end

-- 1. replace: Crowbar(325) in slot 2 -> Bat(450). Expect: Crowbar dropped with 325.
setFog(slot(1, 135), slot(-1, 0), slot(3, 325), slot(4, 540))
local batPickup = makePickup("BP_Interact_Pickup_Wep_Bat")
interactionStarted(batPickup)
setFog(slot(1, 135), slot(-1, 0), slot(2, 450), slot(4, 540))
pickupSuccess(batPickup)
assert(#spawned == 1 and spawned[1].cls.path:find("Wep_Crowbar"), "step 1: expected a Crowbar drop")
assert(#durabilityWrites == 0, "step 1: a level pickup must not restore anything")

-- 2. cancel: nothing happens
interactionStarted(makePickup("BP_Interact_Pickup_Wep_Pipe"))
replaceCancelled(makePickup("BP_Interact_Pickup_Wep_Pipe"))
assert(#spawned == 1, "step 2: cancel must not drop")

-- 3. pick the dropped Crowbar up into the free slot 1 (plain pickup, game gives it 540)
local crowbarDrop = spawned[1]
interactionStarted(crowbarDrop)
setFog(slot(1, 135), slot(3, 540), slot(2, 450), slot(4, 540))
pickupSuccess(crowbarDrop)
assert(#spawned == 1, "step 3: a plain pickup must not drop anything")
assert(#durabilityWrites == 1 and durabilityWrites[1].index == 1 and durabilityWrites[1].isFog == true and durabilityWrites[1].dur == 325,
    "step 3: expected SetWeaponDurability(1, true, 325)")
assert(#equippedWrites == 0, "step 3: slot 1 is not equipped")

-- 4. replace Bat(450, equipped slot 2) with a Sickle -> Bat dropped; then pick the Bat up replacing
--    the Axe in slot 0 -> Axe dropped AND the Bat's durability restored in slot 0
local sickle = makePickup("BP_Interact_Pickup_Wep_Sickle")
interactionStarted(sickle)
setFog(slot(1, 135), slot(3, 540), slot(0, 360), slot(4, 540))   -- "Pipe" stands in for Sickle (not in the id list)
pickupSuccess(sickle)
assert(#spawned == 2 and spawned[2].cls.path:find("Wep_Bat"), "step 4a: expected a Bat drop")
local batDrop = spawned[2]
interactionStarted(batDrop)
setFog(slot(2, 450), slot(3, 540), slot(0, 360), slot(4, 540))   -- Bat replaced the Axe in slot 0
pickupSuccess(batDrop)
assert(#spawned == 3 and spawned[3].cls.path:find("Wep_Axe"), "step 4b: expected an Axe drop")
assert(#durabilityWrites == 2 and durabilityWrites[2].index == 0 and durabilityWrites[2].dur == 450, "step 4b: expected Bat restored to 450 in slot 0")

-- 5. a mod drop whose registry entry is gone (address reused by another actor) is left alone
local stranger = makePickup("BP_Interact_Pickup_Wep_Katana")
interactionStarted(stranger)
setFog(slot(2, 450), slot(3, 540), slot(0, 360), slot(4, 540))
pickupSuccess(stranger)
assert(#durabilityWrites == 2, "step 5: unknown pickup must not restore")

-- 6. consumable replace of another type: MedKitA x1 picked up, the DrinkA=3 stack discarded.
--    The game re-sorts the array; only totals matter. Expect one DrinkA drop with Count=3.
local medkit = makePickup("BP_Interact_Pickup_Con_MedKitA", { id = "MedKitA", count = 1 })
interactionStarted(medkit)
setConsumables(stack(0, 1), stack(0, 3), stack(0, 3), stack(0, 3), stack(2, 1))
pickupSuccess(medkit)
assert(#spawned == 4 and spawned[4].cls.path:find("Con_DrinkA"), "step 6: expected a DrinkA drop")
assert(spawned[4].PickupClass.ChildActor.Count == 3, "step 6: expected Count=3 on the drop")
assert(#durabilityWrites == 2, "step 6: a consumable pickup must not touch weapons")

-- 7. same-type replace: MedKitA x1 picked up, a MedKitA=3 stack discarded -> lost = 10+1-8 = 3
setConsumables(stack(0, 1), stack(0, 3), stack(0, 3), stack(0, 3), stack(2, 1))
local medkit2 = makePickup("BP_Interact_Pickup_Con_MedKitA", { id = "MedKitA", count = 1 })
interactionStarted(medkit2)
setConsumables(stack(0, 1), stack(0, 1), stack(0, 3), stack(0, 3), stack(2, 1))
pickupSuccess(medkit2)
assert(#spawned == 5 and spawned[5].cls.path:find("Con_MedKitA") and spawned[5].PickupClass.ChildActor.Count == 3,
    "step 7: expected a MedKitA x3 drop")

-- 8. plain consumable pickup into a free slot: nothing lost, nothing dropped
local drink = makePickup("BP_Interact_Pickup_Con_DrinkA", { id = "DrinkA", count = 1 })
interactionStarted(drink)
setConsumables(stack(0, 1), stack(0, 1), stack(0, 3), stack(0, 3), stack(2, 2))
pickupSuccess(drink)
assert(#spawned == 5, "step 8: a plain consumable pickup must not drop")

-- 9. cancelled consumable replace
local faith = makePickup("BP_Interact_Pickup_Con_FaithB", { id = "FaithB", count = 1 })
interactionStarted(faith)
hooks[BP .. ":HandlePickupFail"].pre(param(faith))
hooks[BP .. ":OnReplaceConsumableUIEnd"].pre(param(faith), param(false), param(fname("FaithB")))
pickupSuccess(faith)   -- must be ignored: no snapshot any more
assert(#spawned == 5, "step 9: cancel must not drop")

-- instant use ------------------------------------------------------------------------------------
-- the dialog is replaced by an immediate answer; the pickup actor gets the BP functions the feature calls
local dialogs = 0
local answer = true
require("game.dialog").ask = function(_, text, cb) assert(text:find("Inventory is full"), "dialog text"); dialogs = dialogs + 1; cb(answer); return true end
local calls = {}
local function instantPickup(id, count)
    local p = makePickup("BP_Interact_Pickup_Con_" .. id, { id = id, count = count or 1 })
    p.NocePickupBase = "child"
    p.hidden = false
    p.UpdatePickupClass = function() calls[#calls + 1] = "UpdatePickupClass" end
    p.HandleOnPickup = function() calls[#calls + 1] = "HandleOnPickup" end
    p.HandlePickupSuccess = function() calls[#calls + 1] = "HandlePickupSuccess"; pickupSuccess(p) end
    p.ShowReplaceConsumableUI = function() calls[#calls + 1] = "ShowReplaceConsumableUI" end
    p.SetActorHiddenInGame = function(_, h) p.hidden = h end
    return p
end
local function outParam(v) return { get = function() return v end, set = function(_, nv) v = nv end, value = function() return v end } end
--- interaction on a consumable pickup with a full inventory: the Blueprint asks NeedShowReplaceConsumableUI
local function interact(p)
    interactionStarted(p)
    local out = outParam(true)
    hooks[BP .. ":NeedShowReplaceConsumableUI"].pre(param(p), out)
    return out
end
local function callsAre(expected, step) assert(table.concat(calls, ",") == expected, step .. ": calls were " .. table.concat(calls, ",")) end

local usedIds, quickUses = {}, {}
inv.UseConsumable = function(_, fn) usedIds[#usedIds + 1] = fn:ToString(); removeUnits(ID_INDEX[fn:ToString()], 1) end
inv.CanAddConsumable = function(_, fn, qty)
    local idx = ID_INDEX[fn:ToString()]
    local room = 0
    for _, c in ipairs(stacks) do
        if c.IDIndex == idx then room = room + MAX_STACK - c.Quantity elseif c.IDIndex == -1 then room = room + MAX_STACK end
    end
    return room + (MAX_ENTRIES - #stacks) * MAX_STACK >= qty
end
inv.GetConsumableTotalNum = function(_, idx) return totalOf(idx) end
inv.AddConsumable = function(_, fn, qty) addUnits(ID_INDEX[fn:ToString()], qty); return true end
inv.RemoveConsumable = function(_, fn, qty) removeUnits(ID_INDEX[fn:ToString()], qty); return true end
local slotCountWrites = 0
inv.GetConsumableSlotNum = function() return MAX_ENTRIES end
inv.SetConsumableSlotNum = function() slotCountWrites = slotCountWrites + 1 end
-- quick slots: MedKitB (IDIndex 1) sits in slot 2, MedKitA (IDIndex 0) in slot 3. The game's chain, as
-- decompiled: TryToUseConsumableItem stores the slot's item as LastUseConsumableID; GA_UseShortcutItem
-- reads it, plays the montage and calls UseConsumable(id) on a notify.
local slotItems = { -1, -1, 1, 0, -1, -1, -1, -1 }
inv.ShortcutConsumables = tarray(slotItems)
inv.LastUseConsumableID = FName("None")
inv.GetLastUseConsumableID = function(self) return self.LastUseConsumableID end
inv.TryToUseConsumableItem = function(self, slot)
    quickUses[#quickUses + 1] = slot
    self.LastUseConsumableID = FName(idNames[slotItems[slot + 1]] or "None")
end
local useAbilityClass = { IsValid = function() return true end, GetFullName = function() return "BlueprintGeneratedClass /Game/.../GA_UseShortcutItem.GA_UseShortcutItem_C" end }
playerState.AbilitySystemComponent.ActivatableAbilities = { Items = tarray({ { Ability = { IsValid = function() return true end, GetClass = function() return useAbilityClass end } } }) }
local USE_ABILITY = "/Game/Character/Player/Base/GameplayAbility/Ability/GA_UseShortcutItem.GA_UseShortcutItem_C"
local USE_HOOK = "/Script/GameNoce.NocePlayerInventoryComponent:UseConsumable"
local SAVE_HOOK = "/Script/GameNoce.AsyncActionHandleNoceStorage:NoceAsyncSaveGameToSlot"
local function abilityEnds(cancelled) hooks[USE_ABILITY .. ":K2_OnEndAbility"].pre(param({ IsValid = function() return true end }), param(cancelled)) end
--- the montage notify: the game removes the unit, UseConsumable fires, then the ability ends
local function notifyUse()
    local id = inv.LastUseConsumableID:ToString()
    removeUnits(ID_INDEX[id], 1)
    hooks[USE_HOOK].post(param(inv), param(FName(id)))
    abilityEnds(false)
end
local abilityActivations, abilityMode = 0, "use"   -- "use" | "interrupt" | "hold" | "refuse"
playerState.AbilitySystemComponent.TryActivateAbilityByClass = function(_, cls, _)
    assert(cls == useAbilityClass, "wrong ability class")
    if abilityMode == "refuse" then return false end
    abilityActivations = abilityActivations + 1
    if abilityMode == "use" then notifyUse()
    elseif abilityMode == "interrupt" then abilityEnds(true) end   -- hit or dodge before the notify
    return true                                                      -- "hold": the montage is still playing
end
--- 14 entries, MedKitB not carried; outside the quick slots DrinkA has the smallest total
local function fullInventory()
    setConsumables(stack(0, 3), stack(0, 3), stack(0, 3), stack(2, 3), stack(2, 3), stack(2, 1),
        stack(5, 3), stack(5, 3), stack(5, 3), stack(5, 1), stack(6, 3), stack(6, 3), stack(6, 3), stack(6, 1))
end
local FULL = "MedKitA=9 DrinkA=7 DrinkB=10 FoodD=10 entries=14"
local spawnedBefore = #spawned

-- 10. case A with the animation: MedKitA x1, MedKitA carried and in quick slot 3. OutValue forced to
--     false, TryToUseConsumableItem(3), the game uses one, then the new one is picked up (HandleOnPickup)
fullInventory()
local pA = instantPickup("MedKitA")
local outA = interact(pA)
assert(outA.value() == false, "step 10: OutValue must be forced to false")
assert(pA.NocePickupBase == nil, "step 10: NocePickupBase must be cleared")
assert(#quickUses == 1 and quickUses[1] == 3 and abilityActivations == 1, "step 10: TryToUseConsumableItem(3) and one activation expected")
assert(#usedIds == 0 and effectsApplied == 0, "step 10: the game applies the effect in the animated path")
callsAre("UpdatePickupClass,UpdatePickupClass,HandleOnPickup", "step 10")
assert(inventoryKey() == "MedKitA=8 DrinkA=7 DrinkB=10 FoodD=10 entries=14", "step 10: one MedKitA used, was " .. inventoryKey())

-- 10b. case A without a quick slot: LastUseConsumableID written directly, same ability
calls = {}
fullInventory()
inv.ShortcutConsumables = tarray({ -1, -1, -1, -1, -1, -1, -1, -1 })
interact(instantPickup("MedKitA"))
assert(#quickUses == 1 and abilityActivations == 2 and #usedIds == 0, "step 10b: the ability by id expected, no direct use")
callsAre("UpdatePickupClass,UpdatePickupClass,HandleOnPickup", "step 10b")
inv.ShortcutConsumables = tarray(slotItems)

-- 11. case B with the animation: MedKitB not carried, in quick slot 2. All DrinkA stacks (outside the
--     quick slots, smallest total) are taken out, the unit added, the game uses it, the stacks come back
--     and the ground pickup is consumed. The slot count is never written.
calls = {}
fullInventory()
interact(instantPickup("MedKitB"))
assert(quickUses[#quickUses] == 2 and abilityActivations == 3, "step 11: the use ability must run on slot 2")
assert(logged("slot guard: 7 x DrinkA taken out for one MedKitB"), "step 11: DrinkA must be the stack taken out")
assert(inventoryKey() == FULL, "step 11: the inventory must be as before, was " .. inventoryKey())
assert(slotCountWrites == 0, "step 11: the slot count must not be written")
assert(effectsApplied == 0, "step 11: the game applies the effect in the animated path")
callsAre("UpdatePickupClass,UpdatePickupClass,HandlePickupSuccess", "step 11")
assert(#spawned == spawnedBefore, "step 11: instant use must not drop anything")

-- 11b. case B without a quick slot (by id): the same, no quick-slot call
calls = {}
local quickBefore = #quickUses
inv.ShortcutConsumables = tarray({ -1, -1, -1, -1, -1, -1, -1, -1 })
interact(instantPickup("MedKitB"))
assert(#quickUses == quickBefore and abilityActivations == 4, "step 11b: the ability by id expected")
assert(inventoryKey() == FULL, "step 11b: the inventory must be as before, was " .. inventoryKey())
callsAre("UpdatePickupClass,UpdatePickupClass,HandlePickupSuccess", "step 11b")
inv.ShortcutConsumables = tarray(slotItems)

-- 11c. case B interrupted: the ability ends without UseConsumable -> unit removed, stacks back, no
--      effect, the pickup stays on the ground and is shown again
calls, abilityMode = {}, "interrupt"
local pBi = instantPickup("MedKitB")
interact(pBi)
assert(inventoryKey() == FULL, "step 11c: the inventory must be as before, was " .. inventoryKey())
assert(effectsApplied == 0 and not pBi.hidden, "step 11c: no effect, pickup shown")
callsAre("UpdatePickupClass,UpdatePickupClass", "step 11c")

-- 11d. case A interrupted: the carried unit stays, the pickup stays, nothing applied
calls = {}
interact(instantPickup("MedKitA"))
assert(inventoryKey() == FULL and #usedIds == 0 and effectsApplied == 0, "step 11d: nothing used after an interruption")
callsAre("UpdatePickupClass,UpdatePickupClass", "step 11d")

-- 11e. case B, the ability refuses to start (another use still running): stacks back, effect applied
--      directly, pickup consumed, intentional WARN
calls, abilityMode = {}, "refuse"
interact(instantPickup("MedKitB"))
assert(inventoryKey() == FULL, "step 11e: the inventory must be as before, was " .. inventoryKey())
assert(effectsApplied == 1, "step 11e: the effect must be applied directly")
assert(logged("WARN MedKitB: the game's use ability could not be started, consuming the pickup directly"), "step 11e: WARN expected")
callsAre("UpdatePickupClass,UpdatePickupClass,HandlePickupSuccess", "step 11e")
abilityMode = "use"

-- 11f. a second press right after a pickup was used up (HandlePickupSuccess only schedules the
--      destruction): no new question, nothing used again (measured 2026-11-08 02:24:16: repaired twice)
calls = {}
fullInventory()
local pD2 = instantPickup("MedKitB")
interact(pD2)
callsAre("UpdatePickupClass,UpdatePickupClass,HandlePickupSuccess", "step 11f")
local activationsBefore11f, dialogsBefore11f = abilityActivations, dialogs
calls = {}
pD2.NocePickupBase = "child"
local outLate = interact(pD2)
assert(outLate.value() == false and pD2.NocePickupBase == nil, "step 11f: a late interaction must be swallowed")
assert(abilityActivations == activationsBefore11f and dialogs == dialogsBefore11f and #calls == 0, "step 11f: nothing asked or used again")
assert(inventoryKey() == FULL, "step 11f: the inventory must be as before, was " .. inventoryKey())

-- 12. not useful right now -> OutValue untouched, nothing happens
calls, usefulNow = {}, false
local pC = instantPickup("MedKitB")
local outC = interact(pC)
assert(outC.value() == true and #calls == 0 and pC.NocePickupBase == "child", "step 12: a useless item must be left to the game")

-- 13. an offering (no effects) is never offered even when "useful"
usefulNow = true
local outD = interact(instantPickup("FaithB"))
assert(outD.value() == true and #calls == 0, "step 13: offerings go to the replace UI")

-- 13b. a stack on the ground (x3) always goes to the replace UI
local outS = interact(instantPickup("MedKitB", 3))
assert(outS.value() == true and #calls == 0, "step 13b: stacks go to the replace UI")

-- 14. an item with effects but no game-side check (FoodA, restores Stamina): judged by the effect data.
--     Stamina is full -> nothing to restore -> not offered
local outE = interact(instantPickup("FoodA"))
assert(outE.value() == true and #calls == 0, "step 14: a mask-0 item with nothing to restore goes to the replace UI")

-- 15. same item with Stamina below max -> offered and used through the animation (case B: not carried)
playerState.PlayerAttributeSet.Stamina.CurrentValue = 0.5
local outF = interact(instantPickup("FoodA"))
assert(outF.value() == false, "step 15: a mask-0 item with something to restore is offered")
assert(inventoryKey() == FULL, "step 15: the inventory must be as before, was " .. inventoryKey())
callsAre("UpdatePickupClass,UpdatePickupClass,HandlePickupSuccess", "step 15")
playerState.PlayerAttributeSet.Stamina.CurrentValue = 1

-- 16. an exchange interactable (NextRoundExchange) whose child is a consumable behaves like a plain
--     consumable pickup: it is offered and used
calls = {}
local pX = instantPickup("MedKitA")
pX.GetFullName = function() return "BP_Interact_Pickup_Exchange_Ch12Ema12_C exchange" end
local outX = interact(pX)
assert(outX.value() == false, "step 16: exchange pickups with a consumable child are handled like plain ones")
callsAre("UpdatePickupClass,UpdatePickupClass,HandleOnPickup", "step 16")
fullInventory()

-- 17. "No": the replace dialog opens, nothing is used
calls, answer = {}, false
local usedBefore, activationsBefore = #usedIds, abilityActivations
interact(instantPickup("MedKitA"))
assert(abilityActivations == activationsBefore and #usedIds == usedBefore, "step 17: nothing used after No")
callsAre("UpdatePickupClass,ShowReplaceConsumableUI", "step 17")
answer = true

-- 18. while the game's use animation runs: interacting with the same pickup is swallowed (no second
--     question), another pickup is left to the game; once the use completes, the new item is picked up
--     exactly once and the pickup is free again
calls, abilityMode, dialogs = {}, "hold", 0
local pH = instantPickup("MedKitA")
interact(pH)
assert(dialogs == 1 and quickUses[#quickUses] == 3 and pH.hidden, "step 18: the use must have started with the pickup hidden")
pH.NocePickupBase = "child"
local outAgain = outParam(true)
hooks[BP .. ":NeedShowReplaceConsumableUI"].pre(param(pH), outAgain)
assert(outAgain.value() == false and pH.NocePickupBase == nil and dialogs == 1, "step 18: a repeated interaction must be swallowed")
local outOther = interact(instantPickup("MedKitA"))
assert(outOther.value() == true and dialogs == 1, "step 18: another pickup during the use is left to the game")
abilityMode = "use"
notifyUse()
assert(not pH.hidden, "step 18: the pickup is shown again")
callsAre("UpdatePickupClass,UpdatePickupClass,HandleOnPickup", "step 18")
calls = {}
pH.NocePickupBase = "child"
interact(pH)
assert(dialogs == 2, "step 18: after the use the pickup is free again (a new question is allowed)")
fullInventory()

-- 19. the wait for the animation counts game time: a pause or menu (game time stopped) never runs it
--     out, however long; 5 s of game time without UseConsumable does
calls, abilityMode = {}, "hold"
interact(instantPickup("MedKitA"))
for _ = 1, 40 do runTimers() end                       -- 20 s of wall clock in 500 ms ticks, game paused
assert(not logged("MedKitA: use interrupted %(no UseConsumable"), "step 19: a paused game must not time out")
notifyUse()                                            -- the game resumes and finishes the use
callsAre("UpdatePickupClass,UpdatePickupClass,HandleOnPickup", "step 19")
calls = {}
fullInventory()
interact(instantPickup("MedKitA"))
for _ = 1, 12 do gameTime = gameTime + 0.5; runTimers() end
assert(logged("MedKitA: use interrupted %(no UseConsumable within 5000 ms of game time%)"), "step 19b: 5 s of game time must time out")
callsAre("UpdatePickupClass,UpdatePickupClass", "step 19b")

-- 20. case B during which a save is loaded: world time starts over -> the wait ends, the stacks are back
calls = {}
fullInventory()
interact(instantPickup("MedKitB"))
assert(require("game.slot_guard").isOut(), "step 20: a stack must be out during the animation")
-- 21. meanwhile another consumable pickup is ignored (no question, no replace UI)
local dialogsBefore = dialogs
local pI = instantPickup("DrinkA")
local outI = interact(pI)
assert(outI.value() == false and pI.NocePickupBase == nil and dialogs == dialogsBefore, "step 21: pickups are ignored while a stack is out")
-- 22. meanwhile a game save is reported
hooks[SAVE_HOOK].pre()
assert(logged("WARN game save %(NoceAsyncSaveGameToSlot%) while 7 x DrinkA is out of the inventory"), "step 22: WARN expected")
gameTime = 1.0
runTimers()
assert(logged("MedKitB: use interrupted %(world changed"), "step 20: the wait must end on a new world")
assert(not require("game.slot_guard").isOut() and inventoryKey() == FULL, "step 20: stacks back, was " .. inventoryKey())
abilityMode = "use"

-- 23. a save with no stack out is only logged; in-memory save steps are not watched at all
hooks[SAVE_HOOK].pre()
assert(logged("dbg game save: NoceAsyncSaveGameToSlot"), "step 23: the save must be logged")
assert(hooks["/Script/GameNoce.NoceSaveSubsystem:RequestSaveGeneralActor"] == nil, "step 23: RequestSaveGeneralActor must not be hooked")

local warns = 0
for _, l in ipairs(logLines) do if l:find("%] WARN ") then warns = warns + 1 end end
print = realPrint
assert(warns == 2, "expected exactly the two intentional WARN lines (11e, 22), got " .. warns)
print(string.format("SMOKE OK: %d drops, %d durability writes, %d use activations, %d log lines", #spawned, #durabilityWrites, abilityActivations, #logLines))
