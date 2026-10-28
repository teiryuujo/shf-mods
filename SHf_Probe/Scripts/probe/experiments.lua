--[[
    probe.experiments  —  one-shot checks run on a key press (always on the game thread).

    Each experiment is a function that only reads game state and logs what it finds.
    runAll() executes them in order, isolating failures so one broken experiment does
    not hide the others.
--]]
local UEHelpers = require("UEHelpers")
local Log       = require("probe.log")
local Inspect   = require("probe.inspect")

local try = Inspect.try

local INVENTORY_FUNCLIB = "/Script/GameNoce.Default__NoceInventoryFunctionLibrary"
local NOCE_FUNCLIB      = "/Script/GameNoce.Default__NoceFunctionLibrary"
local KISMET_SYSTEM     = "/Script/Engine.Default__KismetSystemLibrary"
local MAX_ROWS_WITH_EFFECTS = 3   -- how many consumable rows to dig into (every element is logged 7 ways)

local M = {}

------------------------------------------------------------------------------
-- 1. Can FSoftClassPath elements of NoceConsumableData.GameplayEffects be read?
------------------------------------------------------------------------------
function M.softClassPaths()
    Log.section("experiment: GameplayEffects soft class paths")
    local lib  = StaticFindObject(INVENTORY_FUNCLIB)
    local ksl  = StaticFindObject(KISMET_SYSTEM)
    if not Inspect.valid(lib) then Log.line("inventory function library not found"); return end
    Log.line("KismetSystemLibrary: %s", Inspect.describe(ksl))

    local raw  = try(function() return lib:GetConsumableRowNames() end)
    local rows = Inspect.names(raw)
    Log.line("GetConsumableRowNames -> %s (%d names read)", Inspect.describe(raw), #rows)
    if #rows == 0 then
        -- a TArray return value may not be readable from Lua: use the inventory's ID list instead
        local inv = Inspect.getInventory()
        rows = inv and Inspect.names(try(function() return inv.AllConsumableIDs end)) or {}
        Log.line("falling back to inv.AllConsumableIDs: %d names", #rows)
    end

    -- every way of reading one element that might work, in a fixed order
    -- Session 3 showed: the element is a UScriptStruct SoftClassPath, v.AssetPath is a
    -- TopLevelAssetPath struct whose reflected fields are PackageName and AssetName (FName).
    local readers = {
        { "describe",              function(v) return Inspect.describe(v) end },
        { "AssetPath.PackageName", function(v) return v.AssetPath.PackageName:ToString() end },
        { "AssetPath.AssetName",   function(v) return v.AssetPath.AssetName:ToString() end },
        { "SubPathString",         function(v) return v.SubPathString end },
        { "BreakSoftClassPath",    function(v) return ksl:BreakSoftClassPath(v) end },
    }

    -- one line per row (what the data looks like, the game-side check mask, the effect count),
    -- then every reader on every element for the first few rows that have effects
    local shown = 0
    for _, id in ipairs(rows) do
        local data  = try(function() return lib:GetConsumableData(FName(id)) end)
        local ge    = data and try(function() return data.GameplayEffects end)
        local elems = Inspect.elements(ge)
        Log.line("%-18s data=%s effects=%s n=%d mask=%s recover=%s", id,
            type(data) == "table" and "table" or Inspect.describe(data),
            type(ge) == "table" and "table" or Inspect.describe(ge), #elems,
            tostring(try(function() return data.ItemAttributeCheckType end)),
            tostring(try(function() return data.WeaponDurabilityRecoverRatio end)))
        if #elems > 0 and shown < MAX_ROWS_WITH_EFFECTS then
            shown = shown + 1
            for i, v in ipairs(elems) do
                Log.line("   [%d] lua type=%s", i, type(v))
                for _, r in ipairs(readers) do
                    local ok, res = pcall(r[2], v)
                    Log.line("   [%d] %-20s -> %s", i, r[1], ok and Inspect.describe(res) or ("ERR " .. tostring(res):sub(1, 100)))
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- 2. Which weapon-subsystem source answers GetMaxDurability?
------------------------------------------------------------------------------
function M.maxDurability()
    Log.section("experiment: GetMaxDurability sources")
    local inv = Inspect.getInventory()
    if not inv then Log.line("no inventory"); return end

    local sources = {
        { "inv.WeaponSubsystem",            function() return inv.WeaponSubsystem end },
        { "NoceFunctionLibrary",            function() return StaticFindObject(NOCE_FUNCLIB):GetWeaponSubSystem(UEHelpers.GetWorldContextObject()) end },
        { "FindFirstOf(NoceWeaponSubsystem)", function() return FindFirstOf("NoceWeaponSubsystem") end },
    }
    local subsystems = {}
    for _, s in ipairs(sources) do
        local ws = try(s[2])
        Log.line("%-34s -> %s", s[1], Inspect.describe(ws))
        if Inspect.valid(ws) then subsystems[#subsystems + 1] = { name = s[1], ws = ws } end
    end

    for _, wname in ipairs(Inspect.names(try(function() return inv.AllWeaponIDs end))) do
        local parts = {}
        for _, s in ipairs(subsystems) do
            local direct = try(function() return s.ws:GetMaxDurability(FName(wname)) end)
            local query  = try(function() return s.ws:GetWeaponQueryName(FName(wname)) end)
            local viaQ   = query and try(function() return s.ws:GetMaxDurability(query) end)
            parts[#parts + 1] = string.format("%s: direct=%s query=%s viaQuery=%s",
                s.name, tostring(direct), Inspect.describe(query), tostring(viaQ))
        end
        Log.line("%-24s %s", wname, table.concat(parts, " | "))
    end
end

------------------------------------------------------------------------------
-- 3. Index / durability accessors of the inventory component (incl. out-params from Lua)
------------------------------------------------------------------------------
function M.weaponAccessors()
    Log.section("experiment: weapon index accessors")
    local inv = Inspect.getInventory()
    if not inv then Log.line("no inventory"); return end

    Log.line("GetEquippedWeaponIndex=%s GetEquippedOrTargetWeaponIndex=%s IsWeaponFull=%s GetMaxWeaponNumber=%s GetAvailableWeaponNumber=%s",
        tostring(try(function() return inv:GetEquippedWeaponIndex() end)),
        tostring(try(function() return inv:GetEquippedOrTargetWeaponIndex() end)),
        tostring(try(function() return inv:IsWeaponFull() end)),
        tostring(try(function() return inv:GetMaxWeaponNumber() end)),
        tostring(try(function() return inv:GetAvailableWeaponNumber() end)))

    local wnames = Inspect.names(try(function() return inv.AllWeaponIDs end))
    for _, listName in ipairs({ "FogWeapons", "DarkWeapons" }) do
        local isFog = listName == "FogWeapons"
        for i, w in ipairs(Inspect.structs(try(function() return inv[listName] end), { "IDIndex", "Durability" })) do
            local name = wnames[(w.IDIndex or -1) + 1]
            local viaGet = try(function() return inv:GetWeaponDurability(i - 1, isFog) end)
            -- GetWeaponIndex has two out-params: UE4SS wants a Lua table per out-param and fills it in.
            -- Log the tables' contents to learn under which key the value lands.
            local outIndex, outFog = {}, {}
            local ok, ret = pcall(function() return inv:GetWeaponIndex(FName(name or "None"), outIndex, outFog) end)
            local function dump(t)
                local parts = {}
                for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. Inspect.describe(v) end
                return "{" .. table.concat(parts, ",") .. "}"
            end
            Log.line("%s[%d] %s dur=%s GetWeaponDurability=%s GetWeaponIndex-> ok=%s ret=%s OutIndex=%s OutIsFog=%s",
                listName, i - 1, tostring(name), tostring(w.Durability), tostring(viaGet),
                tostring(ok), ok and Inspect.describe(ret) or tostring(ret):sub(1, 120), dump(outIndex), dump(outFog))
        end
    end
end

------------------------------------------------------------------------------
-- 4. Can the gameplay effect classes themselves be read (duration policy, modified attributes),
--    and does the ability system tell whether one of them is currently active?
------------------------------------------------------------------------------
local MAX_EFFECT_ROWS = 4
function M.effectDetails()
    Log.section("experiment: gameplay effect classes")
    local inv, ps = Inspect.getInventory()
    local asc = ps and try(function() return ps.AbilitySystemComponent end)
    Log.line("AbilitySystemComponent: %s", Inspect.describe(asc))
    local lib = StaticFindObject(INVENTORY_FUNCLIB)
    if not Inspect.valid(lib) or not inv then Log.line("no library / inventory"); return end
    -- rows with a game-side check mask of 0 are the interesting ones (FoodA, FoodC), plus a few others
    local shown = 0
    for _, id in ipairs(Inspect.names(try(function() return inv.AllConsumableIDs end))) do
        local data  = try(function() return lib:GetConsumableData(FName(id)) end)
        local elems = Inspect.elements(data and data.GameplayEffects)
        local mask  = try(function() return data.ItemAttributeCheckType end) or 0
        if #elems > 0 and (mask == 0 or shown < MAX_EFFECT_ROWS) then
            shown = shown + 1
            Log.line("%s: mask=%s priority=%s", id, tostring(mask), tostring(try(function() return data.Priority end)))
            for _, e in ipairs(elems) do
                local pkg   = try(function() return e.AssetPath.PackageName:ToString() end) or "?"
                local asset = try(function() return e.AssetPath.AssetName:ToString() end) or "?"
                local cls   = StaticFindObject(pkg .. "." .. asset)
                if not Inspect.valid(cls) then cls = try(function() return LoadAsset(pkg .. "." .. asset) end) end
                local cdo   = StaticFindObject(pkg .. ".Default__" .. asset)
                if not Inspect.valid(cdo) then cdo = try(function() return cls:GetDefaultObject() end) end
                Log.line("  %s: class=%s cdo=%s", asset, Inspect.describe(cls), Inspect.describe(cdo))
                if Inspect.valid(cdo) then
                    Log.line("    DurationPolicy=%s executions=%d active=%s",
                        tostring(try(function() return cdo.DurationPolicy end)),
                        #Inspect.elements(try(function() return cdo.Executions end)),
                        tostring(try(function() return asc:GetGameplayEffectCount(cls, nil, true) end)))
                    for i, m in ipairs(Inspect.elements(try(function() return cdo.Modifiers end))) do
                        Log.line("    modifier[%d] attr=%s op=%s calc=%s value=%s", i,
                            tostring(try(function() return m.Attribute.AttributeName:ToString() end)),
                            tostring(try(function() return m.ModifierOp end)),
                            tostring(try(function() return m.ModifierMagnitude.MagnitudeCalculationType end)),
                            tostring(try(function() return m.ModifierMagnitude.ScalableFloatMagnitude.Value end)))
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- 5. In which order does the game hand out consumables (the inventory UI index)?
------------------------------------------------------------------------------
function M.consumableOrder()
    Log.section("experiment: consumable order")
    local inv = Inspect.getInventory()
    if not inv then Log.line("no inventory"); return end
    local names = Inspect.names(try(function() return inv.AllConsumableIDs end))
    local function stacks(list)
        local parts = {}
        for i, c in ipairs(list) do
            parts[#parts + 1] = string.format("%d:%s=%s", i - 1, names[(c.IDIndex or -1) + 1] or tostring(c.IDIndex), tostring(c.Quantity))
        end
        return table.concat(parts, " ")
    end
    Log.line("Consumables array: %s", stacks(Inspect.structs(try(function() return inv.Consumables end), { "IDIndex", "Quantity" })))
    local out = {}
    local ok, err = pcall(function() inv:GetAllConsumables(out) end)
    Log.line("GetAllConsumables ok=%s keys=%s", tostring(ok), (function()
        local k = {}
        for key, v in pairs(out) do k[#k + 1] = tostring(key) .. "=" .. Inspect.describe(v) end
        return table.concat(k, ",")
    end)())
    if not ok then Log.line("  error: %s", tostring(err):sub(1, 120)) end
    -- the out table holds one wrapped element per entry: unwrap and read the struct fields
    local list = Inspect.structs(out, { "IDIndex", "Quantity" })
    Log.line("GetAllConsumables order: %s", stacks(list))
    Log.line("Shortcut wheel: %s", Inspect.consumableUiState():match("Shortcut%[[^%]]*%]") or "?")
    local lib = StaticFindObject(INVENTORY_FUNCLIB)
    for _, id in ipairs(names) do
        local data = try(function() return lib:GetConsumableData(FName(id)) end)
        Log.line("  %-16s priority=%s maxStack=%s", id,
            tostring(try(function() return data.Priority end)), tostring(try(function() return data.MaxStackNum end)))
    end
end

------------------------------------------------------------------------------
-- 7. Names of the input actions the game can simulate (NocePlayerFunctionLibrary:SimulateNoceInputAction)
------------------------------------------------------------------------------
function M.inputActions()
    Log.section("experiment: ENoceInputAction")
    local enum = StaticFindObject("/Script/GameNoce.ENoceInputAction")
    if not Inspect.valid(enum) then Log.line("enum not found"); return end
    local parts = {}
    try(function()
        enum:ForEachName(function(fname, v) parts[#parts + 1] = string.format("%s=%s", fname:ToString():gsub("^ENoceInputAction::", ""), tostring(v)) end)
    end)
    Log.line("%s", table.concat(parts, " "))
end

------------------------------------------------------------------------------
-- 8. (F11) Use the first carried quick-slot item exactly like the quick-slot UI would:
--    SetLastSelectConsumableIndex(slot) then TryToUseConsumableItem(slot). The UseConsumable hook
--    shows whether the game performs the use when the call comes from Lua, outside any pickup.
------------------------------------------------------------------------------
function M.quickUseTest()
    Log.section("F11: quick-slot use from Lua")
    local inv = Inspect.getInventory()
    if not inv then Log.line("no inventory"); return end
    local names = Inspect.names(try(function() return inv.AllConsumableIDs end))
    local totals = {}
    for _, c in ipairs(Inspect.structs(try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
        if c.IDIndex and (c.Quantity or 0) > 0 then totals[c.IDIndex] = (totals[c.IDIndex] or 0) + c.Quantity end
    end
    local slot, id = nil, nil
    for i, v in ipairs(Inspect.elements(try(function() return inv.ShortcutConsumables end))) do
        local idx = tonumber(tostring(v)) or -1
        if idx >= 0 and (totals[idx] or 0) > 0 then slot, id = i - 1, names[idx + 1]; break end
    end
    if not slot then Log.line("no carried item in any quick slot"); return end
    Log.line("before: %s", Inspect.useState())
    local ok1, e1 = pcall(function() inv:SetLastSelectConsumableIndex(slot) end)
    local ok2, e2 = pcall(function() inv:TryToUseConsumableItem(slot) end)
    Log.line("slot %d (%s): SetLastSelectConsumableIndex ok=%s %s | TryToUseConsumableItem ok=%s %s",
        slot, tostring(id), tostring(ok1), ok1 and "" or tostring(e1):sub(1, 80), tostring(ok2), ok2 and "" or tostring(e2):sub(1, 80))
    Log.line("after:  %s", Inspect.useState())
    ExecuteWithDelay(1500, function() ExecuteInGameThread(function() Log.line("1.5 s later: %s", Inspect.useState()) end) end)
end

------------------------------------------------------------------------------
-- 9. (F11) Call the quick-slot widget's own DirectUse (Blueprint event) after selecting a slot.
--    If the game performs the use, DirectUse is the reflected entry point the mod can call.
------------------------------------------------------------------------------
function M.directUseTest()
    Log.section("F11: quick-slot widget DirectUse from Lua")
    local inv = Inspect.getInventory()
    if not inv then Log.line("no inventory"); return end
    local widgets = {}
    for _, cls in ipairs({ "WBP_ItemShortcut_PC_C", "WBP_ItemShortcut_C", "NoceShortcutItemWidget" }) do
        local list = try(function() return FindAllOf(cls) end)
        for _, w in ipairs(Inspect.elements(list)) do
            if Inspect.valid(w) then widgets[#widgets + 1] = w end
        end
        Log.line("FindAllOf(%s): %d", cls, #Inspect.elements(list))
    end
    if #widgets == 0 then Log.line("no quick-slot widget instance found"); return end
    for i, w in ipairs(widgets) do Log.line("  widget[%d] %s", i, Inspect.describe(w)) end

    -- first carried item in a quick slot, as in quickUseTest
    local names = Inspect.names(try(function() return inv.AllConsumableIDs end))
    local totals = {}
    for _, c in ipairs(Inspect.structs(try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
        if c.IDIndex and (c.Quantity or 0) > 0 then totals[c.IDIndex] = (totals[c.IDIndex] or 0) + c.Quantity end
    end
    local slot, id = nil, nil
    for i, v in ipairs(Inspect.elements(try(function() return inv.ShortcutConsumables end))) do
        local idx = tonumber(tostring(v)) or -1
        if idx >= 0 and (totals[idx] or 0) > 0 then slot, id = i - 1, names[idx + 1]; break end
    end
    if not slot then Log.line("no carried item in any quick slot"); return end

    local w = widgets[1]
    Log.line("before: %s", Inspect.useState())
    try(function() inv:SetLastSelectConsumableIndex(slot) end)
    local ok, res = pcall(function() return w:DirectUse() end)
    Log.line("slot %d (%s): DirectUse on %s -> ok=%s result=%s", slot, tostring(id), Inspect.describe(w), tostring(ok), ok and Inspect.describe(res) or tostring(res):sub(1, 100))
    Log.line("after:  %s", Inspect.useState())
    ExecuteWithDelay(1500, function() ExecuteInGameThread(function() Log.line("1.5 s later: %s", Inspect.useState()) end) end)
end

------------------------------------------------------------------------------
-- 10. (F12) Select a quick slot, then simulate the game's own "UseItem" input action
--     (ENoceInputAction::UseItem = 11) through NocePlayerFunctionLibrary:SimulateNoceInputAction.
--     Shows whether the native input path starts the use motion when driven from Lua.
------------------------------------------------------------------------------
local NOCE_PLAYER_FUNCLIB = "/Script/GameNoce.Default__NocePlayerFunctionLibrary"
local INPUT_USE_ITEM      = 11
local RELEASE_AFTER_MS    = 600   -- 120 ms opened the panel but the release did nothing: hold longer
local MID_HOLD_MS         = 300

function M.simulateUseItem()
    Log.section("F12: simulate UseItem input")
    local inv = Inspect.getInventory()
    local lib = StaticFindObject(NOCE_PLAYER_FUNCLIB)
    if not inv or not Inspect.valid(lib) then Log.line("no inventory / player function library"); return end
    local names = Inspect.names(try(function() return inv.AllConsumableIDs end))
    local totals = {}
    for _, c in ipairs(Inspect.structs(try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
        if c.IDIndex and (c.Quantity or 0) > 0 then totals[c.IDIndex] = (totals[c.IDIndex] or 0) + c.Quantity end
    end
    local slot, id = nil, nil
    for i, v in ipairs(Inspect.elements(try(function() return inv.ShortcutConsumables end))) do
        local idx = tonumber(tostring(v)) or -1
        if idx >= 0 and (totals[idx] or 0) > 0 then slot, id = i - 1, names[idx + 1]; break end
    end
    if not slot then Log.line("no carried item in any quick slot"); return end

    local ctx = UEHelpers.GetWorldContextObject()
    Log.line("slot %d (%s) before: %s", slot, tostring(id), Inspect.useState())
    try(function() inv:SetLastSelectConsumableIndex(slot) end)
    local ok, err = pcall(function() lib:SimulateNoceInputAction(ctx, INPUT_USE_ITEM, true) end)
    Log.line("UseItem pressed  ok=%s %s | %s", tostring(ok), ok and "" or tostring(err):sub(1, 100), Inspect.useState())
    ExecuteWithDelay(MID_HOLD_MS, function() ExecuteInGameThread(function()
        Log.line("mid-hold (%d ms): %s", MID_HOLD_MS, Inspect.useState())
    end) end)
    ExecuteWithDelay(RELEASE_AFTER_MS, function() ExecuteInGameThread(function()
        local ok2, err2 = pcall(function() lib:SimulateNoceInputAction(ctx, INPUT_USE_ITEM, false) end)
        Log.line("UseItem released ok=%s %s | %s", tostring(ok2), ok2 and "" or tostring(err2):sub(1, 100), Inspect.useState())
    end) end)
    ExecuteWithDelay(1500, function() ExecuteInGameThread(function() Log.line("1.5 s later: %s", Inspect.useState()) end) end)
    ExecuteWithDelay(3500, function() ExecuteInGameThread(function() Log.line("3.5 s later: %s", Inspect.useState()) end) end)
end

------------------------------------------------------------------------------
-- 11. The ability side of the quick-slot use: the input helper's event tag, the tag data asset's
--     ability tags, and every ability currently granted to the player (class + input id).
------------------------------------------------------------------------------
local function tagName(tag)
    return try(function() return tag.TagName:ToString() end) or "?"
end
local function containerNames(container)
    local names = {}
    for _, t in ipairs(Inspect.elements(try(function() return container.GameplayTags end))) do names[#names + 1] = tagName(t) end
    return table.concat(names, ",")
end

--- Granted abilities: { { ability = obj, class = fullname, inputId = n }, ... }
local function grantedAbilities(asc)
    local list = {}
    for _, spec in ipairs(Inspect.elements(try(function() return asc.ActivatableAbilities.Items end))) do
        local ability = try(function() return spec.Ability end)
        if Inspect.valid(ability) then
            list[#list + 1] = {
                ability = ability,
                class   = try(function() return ability:GetClass():GetFullName() end) or Inspect.describe(ability),
                inputId = try(function() return spec.InputID end),
            }
        end
    end
    return list
end

function M.abilityInfo()
    Log.section("experiment: shortcut-item ability")
    local helper = FindFirstOf("NocePlayerInputHelperComponent")
    Log.line("input helper: %s", Inspect.describe(helper))
    if Inspect.valid(helper) then
        Log.line("  ShortcutItemEventTag=%s delay=%s", tagName(try(function() return helper.ShortcutItemEventTag end)),
            tostring(try(function() return helper.ShortcutItemEventDelayTime end)))
        Log.line("  EnableStateTags=[%s] DisableStateTags=[%s] ShortcutTags=[%s]",
            containerNames(try(function() return helper.ShortcutItemEnableStateTags end)),
            containerNames(try(function() return helper.ShortcutItemDisableStateTags end)),
            containerNames(try(function() return helper.ShortcutTags end)))
    end
    local tags = FindFirstOf("NoceGameplayTagDataAsset")
    Log.line("tag data asset: %s", Inspect.describe(tags))
    if Inspect.valid(tags) then
        for _, f in ipairs({ "AbilityPlayerUseShortcutItem", "AbilityPlayerUseShortcutItemMotion", "AbilityPlayerShowShortcutItemUI" }) do
            Log.line("  %s = %s", f, tagName(try(function() return tags[f] end)))
        end
    end
    local _, ps = Inspect.getInventory()
    local asc = ps and try(function() return ps.AbilitySystemComponent end)
    local abilities = Inspect.valid(asc) and grantedAbilities(asc) or {}
    Log.line("granted abilities: %d", #abilities)
    for i, a in ipairs(abilities) do Log.line("  [%d] input=%s %s", i, tostring(a.inputId), a.class) end
end

------------------------------------------------------------------------------
-- 12. (F12) Select a quick slot and activate the use ability through the ability system:
--     TryActivateAbilityByClass on the granted ability whose class name mentions the shortcut item,
--     else SendGameplayEventToActor with the input helper's ShortcutItemEventTag.
------------------------------------------------------------------------------
local ABILITY_BPLIB = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"

function M.activateUseAbility()
    Log.section("F12: activate the use ability")
    local inv, ps = Inspect.getInventory()
    local asc = ps and try(function() return ps.AbilitySystemComponent end)
    if not inv or not Inspect.valid(asc) then Log.line("no inventory / ability system"); return end

    local names = Inspect.names(try(function() return inv.AllConsumableIDs end))
    local totals = {}
    for _, c in ipairs(Inspect.structs(try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
        if c.IDIndex and (c.Quantity or 0) > 0 then totals[c.IDIndex] = (totals[c.IDIndex] or 0) + c.Quantity end
    end
    local slot, id = nil, nil
    for i, v in ipairs(Inspect.elements(try(function() return inv.ShortcutConsumables end))) do
        local idx = tonumber(tostring(v)) or -1
        if idx >= 0 and (totals[idx] or 0) > 0 then slot, id = i - 1, names[idx + 1]; break end
    end
    if not slot then Log.line("no carried item in any quick slot"); return end
    try(function() inv:SetLastSelectConsumableIndex(slot) end)
    Log.line("slot %d (%s) before: %s", slot, tostring(id), Inspect.useState())

    -- Decompiled chain (GA_DirectUseShortcutItem -> OnTryToUseItem -> GA_UseShortcutItem):
    -- GA_UseShortcutItem reads InventoryComponent.GetLastUseConsumableID(), checks the count and
    -- CanUseItem, plays the montage by ItemMotionType and calls UseConsumable(name) on a notify.
    -- So: TryToUseConsumableItem(slot) sets the id, then the use ability is activated directly.
    local ok1, err1 = pcall(function() inv:TryToUseConsumableItem(slot) end)
    Log.line("TryToUseConsumableItem(%d) ok=%s %s | LastUseConsumableID=%s | %s", slot, tostring(ok1),
        ok1 and "" or tostring(err1):sub(1, 80),
        tostring(try(function() return inv:GetLastUseConsumableID():ToString() end)), Inspect.useState())

    local wanted = "GA_UseShortcutItem_C"
    local target = nil
    for _, a in ipairs(grantedAbilities(asc)) do
        if a.class:sub(-#wanted) == wanted then target = a; break end
    end
    if not target then Log.line("%s is not granted", wanted); return end
    local ok, res = pcall(function() return asc:TryActivateAbilityByClass(target.ability:GetClass(), true) end)
    Log.line("TryActivateAbilityByClass(%s) ok=%s result=%s | %s", wanted, tostring(ok),
        ok and tostring(res) or tostring(res):sub(1, 100), Inspect.useState())
    Log.line("after: %s", Inspect.useState())
    ExecuteWithDelay(300,  function() ExecuteInGameThread(function() Log.line("0.3 s later: %s", Inspect.useState()) end) end)
    ExecuteWithDelay(1500, function() ExecuteInGameThread(function() Log.line("1.5 s later: %s", Inspect.useState()) end) end)
    ExecuteWithDelay(3500, function() ExecuteInGameThread(function() Log.line("3.5 s later: %s", Inspect.useState()) end) end)
end

------------------------------------------------------------------------------
-- 13. (F11) Does AddConsumable itself enforce the slot capacity? With a full inventory, add one unit of a
--     type that is not carried, log the result and the stacks, then remove it again right away.
--     If it adds a 15th stack, case B of the instant use could run the game's animated use on it.
------------------------------------------------------------------------------
function M.addBeyondCapacity()
    Log.section("F11: AddConsumable beyond capacity")
    local inv = Inspect.getInventory()
    if not inv then Log.line("no inventory"); return end
    local names = Inspect.names(try(function() return inv.AllConsumableIDs end))
    local function totals()
        local t = {}
        for _, c in ipairs(Inspect.structs(try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
            if c.IDIndex and (c.Quantity or 0) > 0 then t[c.IDIndex] = (t[c.IDIndex] or 0) + c.Quantity end
        end
        return t
    end
    local function stacks()
        local parts = {}
        for i, c in ipairs(Inspect.structs(try(function() return inv.Consumables end), { "IDIndex", "Quantity" })) do
            parts[#parts + 1] = string.format("%d:%s=%s", i - 1, names[(c.IDIndex or -1) + 1] or tostring(c.IDIndex), tostring(c.Quantity))
        end
        return table.concat(parts, " ")
    end

    -- a type with effects that is not carried, so a new stack is unambiguous
    local before = totals()
    local id = nil
    for _, candidate in ipairs({ "WeaponRecoverA", "DrinkC", "FoodB", "FoodC", "MedKitB", "DrinkA" }) do
        for i, n in ipairs(names) do
            if n == candidate and (before[i - 1] or 0) == 0 then id = candidate end
        end
        if id then break end
    end
    if not id then Log.line("every candidate type is carried; nothing to test"); return end

    Log.line("slots=%s stacks=%d CanAddConsumable(%s,1)=%s", tostring(try(function() return inv:GetConsumableSlotNum() end)),
        #Inspect.structs(try(function() return inv.Consumables end), { "IDIndex" }), id,
        tostring(try(function() return inv:CanAddConsumable(FName(id), 1) end)))
    local original = stacks()
    Log.line("before: %s", original)
    local idx = nil
    for i, n in ipairs(names) do if n == id then idx = i - 1 end end

    -- Measured 2026-10-27: AddConsumable returns true but adds nothing when the slots are full (the
    -- capacity check is native). Second option: one extra slot for the duration of the add.
    local slotsBefore = try(function() return inv:GetConsumableSlotNum() end)
    local okS, errS = pcall(function() inv:SetConsumableSlotNum(slotsBefore + 1) end)
    Log.line("SetConsumableSlotNum(%d) ok=%s %s -> slots=%s CanAdd=%s", slotsBefore + 1, tostring(okS), okS and "" or tostring(errS):sub(1, 80),
        tostring(try(function() return inv:GetConsumableSlotNum() end)), tostring(try(function() return inv:CanAddConsumable(FName(id), 1) end)))
    local ok, res = pcall(function() return inv:AddConsumable(FName(id), 1, FName("None")) end)
    Log.line("AddConsumable(%s, 1) ok=%s result=%s", id, tostring(ok), ok and tostring(res) or tostring(res):sub(1, 100))
    Log.line("after add: %s", stacks())
    local added = (totals()[idx] or 0) - (before[idx] or 0)
    Log.line("added %d unit(s); GetConsumableTotalNum=%s", added, tostring(try(function() return inv:GetConsumableTotalNum(idx) end)))

    -- roll back in the same tick: remove what was added, then the slot count
    if added > 0 then
        local ok2, res2 = pcall(function() return inv:RemoveConsumable(FName(id), added, false) end)
        Log.line("RemoveConsumable(%s, %d) ok=%s result=%s", id, added, tostring(ok2), ok2 and tostring(res2) or tostring(res2):sub(1, 100))
    end
    local okR, errR = pcall(function() inv:SetConsumableSlotNum(slotsBefore) end)
    local final = stacks()
    Log.line("SetConsumableSlotNum(%d) ok=%s %s -> slots=%s", slotsBefore, tostring(okR), okR and "" or tostring(errR):sub(1, 80),
        tostring(try(function() return inv:GetConsumableSlotNum() end)))
    Log.line("final:  %s", final)
    Log.line(final == original and "inventory restored exactly" or "WARNING: inventory differs from the original snapshot")
end

------------------------------------------------------------------------------
-- 6. Plain inventory snapshot
------------------------------------------------------------------------------
function M.snapshot()
    Log.section("snapshot")
    Log.line("%s", Inspect.inventoryState())
end

------------------------------------------------------------------------------
function M.runAll()
    local list = {
        { "snapshot",        M.snapshot },
        { "softClassPaths",  M.softClassPaths },
        { "maxDurability",   M.maxDurability },
        { "weaponAccessors", M.weaponAccessors },
        { "effectDetails",   M.effectDetails },
        { "consumableOrder", M.consumableOrder },
        { "inputActions",    M.inputActions },
        { "abilityInfo",     M.abilityInfo },
    }
    for _, e in ipairs(list) do
        local ok, err = pcall(e[2])
        if not ok then Log.line("experiment %s failed: %s", e[1], tostring(err)) end
    end
    Log.section("experiments done")
end

return M
