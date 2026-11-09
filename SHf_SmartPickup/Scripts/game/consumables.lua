--[[
    game.consumables  —  consumable data, effects, the repair kit and the quick slots, all read from
    the game at runtime.

    Measured:
      - GetConsumableData(FName) returns a Lua table: ItemAttributeCheckType (mask),
        WeaponDurabilityRecoverRatio, GameplayEffects (SoftClassPath structs; the class path is
        AssetPath.PackageName .. "." .. AssetPath.AssetName).
      - NocePlayerState:CanUseConsumableType(mask) is the game's own "useful right now" check.
        Masks: MedKit/FoodD/FoodE 1, Capsule 7, Drinks 22/23, FoodB 23, repair kit 8,
        FoodA/FoodC 0 (effects but no game-side check), offerings 0 and no effects.
      - A gameplay effect class default object exposes DurationPolicy (0 = instant, 2 = has duration),
        Modifiers[i].Attribute.AttributeName and Executions; AbilitySystemComponent:GetGameplayEffectCount
        tells whether a duration effect is active. Health/Sanity recovery runs through Executions
        (no modifiers), FullStamina / FillSanity through an Override modifier on Stamina / Sanity.
      - inv.ShortcutConsumables is TArray<int>: the IDIndex in each of the 8 quick slots (or -1).
        TryToUseConsumableItem(slot) is what the quick-slot UI calls; the use animation plays and
        ~1 s later UseConsumable(ID) fires. UseConsumable alone only removes the item.
      - inv.WeaponSubsystem is null; NoceFunctionLibrary:GetWeaponSubSystem answers GetMaxDurability
        for every row (query name = row name except ToySaber -> ToySaber_Round2).
--]]
local UEHelpers = require("UEHelpers")
local Log   = require("core.log")
local Util  = require("core.util")
local Const = require("game.const")
local Spawn = require("game.spawn")

local M = {}

local ATTRIBUTES = { "Health", "MaxHealth", "Stamina", "MaxStamina", "Sanity", "CurrentMaxSanity" }
-- attribute -> the attribute holding its current maximum (PlayerAttributeSet)
local MAX_OF = { Health = "MaxHealth", Stamina = "MaxStamina", Sanity = "CurrentMaxSanity", CurrentMaxSanity = "MaxSanity" }
local DURATION_INSTANT = 0

--- Row data as a Lua table, or nil.
function M.data(id)
    local lib = StaticFindObject(Const.INVENTORY_FUNCLIB)
    if not Util.valid(lib) then Log.warn("inventory function library not found"); return nil end
    local data = Util.try(function() return lib:GetConsumableData(FName(id)) end)
    if type(data) ~= "table" then Log.warn("GetConsumableData(%s) returned %s", id, type(data)); return nil end
    return data
end

--- Full class paths of the row's gameplay effects.
function M.effectClassPaths(data)
    local paths = {}
    for _, e in ipairs(Util.elements(data and data.GameplayEffects)) do
        local pkg   = Util.try(function() return e.AssetPath.PackageName:ToString() end)
        local asset = Util.try(function() return e.AssetPath.AssetName:ToString() end)
        if pkg and asset and pkg ~= "None" then paths[#paths + 1] = pkg .. "." .. asset end
    end
    return paths
end

function M.recoverRatio(data)
    return Util.try(function() return data.WeaponDurabilityRecoverRatio end, 0) or 0
end

function M.checkMask(data)
    return Util.try(function() return data.ItemAttributeCheckType end, 0) or 0
end

--- Display name for dialogs (FText or string), falling back to the row name.
function M.displayName(data, id)
    local name = Util.try(function() return data.Name end)
    if type(name) == "string" and name ~= "" then return name end
    local s = Util.try(function() return name:ToString() end)
    if type(s) == "string" and s ~= "" then return s end
    return id
end

local function attributeValue(ps, name)
    return Util.try(function() return ps.PlayerAttributeSet[name].CurrentValue end)
end

--- What one effect class does: { cls, duration, executions, attributes = { "Stamina", ... } }.
--- Only classes that are already in memory are inspected: this runs inside a Blueprint hook, and a
--- synchronous LoadAsset there froze the game (2026-10-28 00:54, FoodC from an exchange pickup).
--- An effect whose class is not loaded is reported as unknown (nil -> treated as pending).
local function effectInfo(path)
    local cls = StaticFindObject(path)
    if not Util.valid(cls) then Log.dbg("effect class %s is not loaded, counting it as pending", path); return nil end
    local cdo = StaticFindObject(path:gsub("%.([^.]+)$", ".Default__%1"))
    if not Util.valid(cdo) then cdo = Util.try(function() return cls:GetDefaultObject() end) end
    if not Util.valid(cdo) then Log.dbg("no default object for %s", path); return { cls = cls } end
    local info = {
        cls = cls,
        duration = Util.try(function() return cdo.DurationPolicy end, DURATION_INSTANT),
        executions = #Util.elements(Util.try(function() return cdo.Executions end)),
        attributes = {},
    }
    for _, m in ipairs(Util.elements(Util.try(function() return cdo.Modifiers end))) do
        local attr = Util.try(function() return m.Attribute.AttributeName:ToString() end)
        if attr and attr ~= "" then info.attributes[#info.attributes + 1] = attr end
    end
    return info
end

--- True when applying this effect would still change something:
--- a duration effect that is not active, or an instant one whose attribute is below its maximum.
--- Effects whose attribute cannot be read (executions, unknown maxima) count as pending.
local function effectPending(ps, asc, info)
    if not info or not info.duration then return true end
    if info.duration ~= DURATION_INSTANT then
        local active = Util.try(function() return asc:GetGameplayEffectCount(info.cls, nil, true) end)
        return active == nil or active == 0
    end
    if info.executions > 0 or #info.attributes == 0 then return true end
    for _, attr in ipairs(info.attributes) do
        local maxName = MAX_OF[attr]
        if not maxName then return true end
        local cur, max = attributeValue(ps, attr), attributeValue(ps, maxName)
        if not cur or not max or cur < max - 0.01 then return true end
    end
    return false
end

--- "Useful right now": the game's own check when the row has one, otherwise the effect data.
function M.usefulNow(ps, data)
    local mask = M.checkMask(data)
    if mask ~= 0 then
        local ok, res = pcall(function() return ps:CanUseConsumableType(mask) end)
        if not ok then Log.warn("CanUseConsumableType failed: %s", tostring(res)); return false end
        return res == true
    end
    local asc = Util.try(function() return ps.AbilitySystemComponent end)
    for _, path in ipairs(M.effectClassPaths(data)) do
        if effectPending(ps, asc, effectInfo(path)) then return true end
    end
    return false
end

--- Applies the row's gameplay effects through the ability system. Returns applied, total.
function M.applyEffects(ps, data)
    local paths = M.effectClassPaths(data)
    if #paths == 0 then return 0, 0 end
    local asc = Util.try(function() return ps.AbilitySystemComponent end)
    if not Util.valid(asc) then Log.warn("no AbilitySystemComponent on the player state"); return 0, #paths end
    local applied = 0
    for _, path in ipairs(paths) do
        local cls = Spawn.loadClass(path)
        if cls then
            local ok, err = pcall(function() asc:BP_ApplyGameplayEffectToSelf(cls, 1.0, {}) end)
            if ok then applied = applied + 1 else Log.warn("ApplyGameplayEffect %s failed: %s", path, tostring(err)) end
        end
    end
    return applied, #paths
end

--- The game's own use of a carried item, with its animation (decompiled from the ability Blueprints):
---   TryToUseConsumableItem(slot) stores the slot's item as LastUseConsumableID (and raises a delegate
---   that only the quick-slot UI ability listens to), then GA_UseShortcutItem reads that id, checks
---   the count and CanUseItem, plays the montage by ItemMotionType and calls UseConsumable(id) on an
---   animation notify. Activating that ability directly is what the UI ability does on the delegate.
--- Returns true when the ability started; the caller waits for UseConsumable(id).
local USE_ABILITY_CLASS = "GA_UseShortcutItem_C"

local function grantedAbilityClass(asc, suffix)
    for _, spec in ipairs(Util.elements(Util.try(function() return asc.ActivatableAbilities.Items end))) do
        local ability = Util.try(function() return spec.Ability end)
        local cls = Util.valid(ability) and Util.try(function() return ability:GetClass() end)
        local name = cls and Util.try(function() return cls:GetFullName() end)
        if name and name:sub(-#suffix) == suffix then return cls end
    end
    return nil
end

local function activateUse(ps)
    local asc = Util.try(function() return ps.AbilitySystemComponent end)
    local cls = Util.valid(asc) and grantedAbilityClass(asc, USE_ABILITY_CLASS)
    if not cls then Log.warn("%s is not granted to the player", USE_ABILITY_CLASS); return false end
    local started = Util.try(function() return asc:TryActivateAbilityByClass(cls, true) end)
    if started ~= true then Log.dbg("%s refused to activate", USE_ABILITY_CLASS); return false end
    return true
end

function M.useFromQuickSlot(inv, ps, id, slot)
    local ok, err = pcall(function() inv:TryToUseConsumableItem(slot) end)
    if not ok then Log.warn("TryToUseConsumableItem(%d) failed: %s", slot, tostring(err)); return false end
    local selected = Util.try(function() return inv:GetLastUseConsumableID():ToString() end)
    if selected ~= id then Log.warn("quick slot %d selected %s, expected %s", slot, tostring(selected), id); return false end
    return activateUse(ps)
end

--- The same use for an item that sits in no quick slot. The ability reads nothing but
--- LastUseConsumableID (decompiled GA_UseShortcutItem: no reference to ShortcutConsumables), so the
--- id is written into that field directly and the ability activated; the quick-slot layout is not
--- touched. Returns false when the field did not take the id (the caller falls back to the direct use).
function M.useById(inv, ps, id)
    local ok, err = pcall(function() inv.LastUseConsumableID = FName(id) end)
    if not ok then Log.warn("LastUseConsumableID = %s failed: %s", id, tostring(err)); return false end
    local selected = Util.try(function() return inv:GetLastUseConsumableID():ToString() end)
    if selected ~= id then Log.warn("LastUseConsumableID reads %s after writing %s", tostring(selected), id); return false end
    return activateUse(ps)
end

--- Quick slot (0-based) holding the given consumable, or nil.
function M.quickSlotOf(inv, id)
    local names = Util.names(Util.try(function() return inv.AllConsumableIDs end))
    local idIndex = nil
    for i, n in ipairs(names) do
        if n == id then idIndex = i - 1 end
    end
    if idIndex == nil then return nil end
    for slot, v in ipairs(Util.elements(Util.try(function() return inv.ShortcutConsumables end))) do
        if tonumber(tostring(v)) == idIndex then return slot - 1 end
    end
    return nil
end

--- Repairs the weapon in the player's hand by ratio * max (what the game's repair kit does).
--- Returns true when the durability went up, false when there is nothing to repair or it failed.
function M.repairWeaponInHand(ratio)
    local pawn = UEHelpers.GetPlayer()
    if not Util.valid(pawn) then return false end
    local weapon = Util.try(function() return pawn.CurrentWeapon end)
    if not Util.valid(weapon) then Log.dbg("repair: no weapon actor in hand"); return false end
    local cur = Util.try(function() return weapon:GetDurability() end)
    local max = Util.try(function() return weapon:GetMaxDurability() end)
    if not cur or not max or max <= 0 then Log.dbg("repair: durability unknown (%s/%s)", tostring(cur), tostring(max)); return false end
    if cur >= max - 0.01 then Log.dbg("repair: weapon already at max durability"); return false end
    local add = math.min(max - cur, ratio * max)
    local ok, err = pcall(function() weapon:AddDurability(add) end)
    if not ok then Log.warn("AddDurability failed: %s", tostring(err)); return false end
    local after = Util.try(function() return weapon:GetDurability() end, cur)
    Log.info("Repaired weapon in hand: %.1f -> %.1f (max %.1f)", cur, after, max)
    return after > cur + 0.01
end

--- Fallback repair through the inventory (no weapon actor in hand): the equipped slot of the active list.
function M.repairEquippedInInventory(inv, ratio)
    local idx = Util.try(function() return inv:GetEquippedWeaponIndex() end)
    if idx == nil or idx < 0 then Log.dbg("repair: no equipped weapon"); return false end
    local isFog = Util.try(function() return inv.CurrentUseFogWeapon end) == true
    local cur = Util.try(function() return inv:GetWeaponDurability(idx, isFog) end)
    local names = Util.names(Util.try(function() return inv.AllWeaponIDs end))
    local slots = Util.structs(Util.try(function() return inv[isFog and "FogWeapons" or "DarkWeapons"] end), { "IDIndex" })
    local name = slots[idx + 1] and names[(slots[idx + 1].IDIndex or -1) + 1]
    if not cur or not name then Log.dbg("repair: equipped slot unreadable"); return false end
    local max = Util.try(function()
        local ws = StaticFindObject(Const.NOCE_FUNCLIB):GetWeaponSubSystem(UEHelpers.GetWorldContextObject())
        return ws:GetMaxDurability(ws:GetWeaponQueryName(FName(name)))
    end)
    if not max or max <= 0 then Log.warn("repair: unknown max durability for %s", name); return false end
    local newDur = math.min(max, cur + ratio * max)
    if newDur <= cur + 0.01 then Log.dbg("repair: %s already at max durability", name); return false end
    local ok, err = pcall(function()
        inv:SetWeaponDurability(idx, isFog, newDur)
        inv:SetEquippedWeaponDurability(FName(name), newDur)
    end)
    if not ok then Log.warn("repair via inventory failed: %s", tostring(err)); return false end
    Log.info("Repaired %s via inventory: %.1f -> %.1f (max %.1f)", name, cur, newDur, max)
    return true
end

--- "Health=80 MaxHealth=100 ..." for log lines.
function M.describeAttributes(ps)
    local parts = {}
    for _, name in ipairs(ATTRIBUTES) do
        local v = attributeValue(ps, name)
        parts[#parts + 1] = string.format("%s=%s", name, v and string.format("%.0f", v) or "?")
    end
    return table.concat(parts, " ")
end

return M
