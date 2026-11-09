--[[
    SHf_SmartPickup  —  UE4SS Lua mod for SILENT HILL f (UE 5.4.2, module GameNoce)

    1. Weapon swap with a full weapon inventory: the weapon you discard in the
       "replace" dialog is placed on the ground exactly where the new weapon was,
       keeping its durability.
    2. Consumable pickup with a full consumable inventory: if the item is useful right
       now (health not full, weapon damaged, sanity not full ...; see Config.InstantUse) the
       game's own Yes/No pop-up asks whether to use it on the spot. "No" opens the normal replace dialog.
    3. Consumable replace with a full inventory: the stack you discard in the
       "replace" dialog is placed on the ground where the new item was.

    IMPORTANT: in this game UE4SS fires the "pre" callback of RegisterHook AFTER the Blueprint function
    body has executed, and never fires the "post" callback. Every hook below therefore sees the state
    after the function ran; out-parameters can still be overridden (the caller reads them afterwards).
    Hook points are Blueprint functions of /Game/Blueprint/InteractUnit/BP_Interact_Pickup
    (the interactable that hosts every weapon / consumable pickup in the game):
        ExecuteInstantFeedback -> NeedShowReplaceWeaponUI / NeedShowReplaceConsumableUI
                               -> ShowReplaceWeapon / ShowReplaceConsumableUI   (snapshot inventory, feature 2 entry)
                               -> (C++ widget swaps items) -> OnReplace*UIEnd -> HandlePickupSuccess (diff + drop)
--]]

local UEHelpers = require("UEHelpers")

------------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------------
-- Lua has no enums: the allowed values of Config.InstantUse are the fields of this table.
local InstantUseMode = {
    Off    = "off",    -- never offer: the game's own replace dialog, as in vanilla
    Useful = "useful", -- offer when the item restores something that is below max right now
    Always = "always", -- offer even at full health/sanity/stamina (repair kits still need a damaged weapon)
}

local Config = {
    -- Weapon replace with a full inventory: drop the discarded weapon where the new one was.
    DropReplacedWeapon = true,
    -- Consumable replace with a full inventory: drop the discarded stack where the new one was.
    DropReplacedConsumables = true,
    -- Consumable pickup with a full inventory: offer to use the item on the spot instead of replacing.
    -- Only single items on the ground are offered; stacks always go to the replace dialog.
    InstantUse = InstantUseMode.Useful,
    -- true = ask with the game's own Yes/No pop-up before using, false = use silently.
    ConfirmInstantUse = true,
    -- How a discarded consumable stack is dropped: 0 = one pickup that gives the whole stack at once,
    -- N = up to N separate pickups laid out next to each other (the rest goes into the last one).
    SeparateDropsUpTo = 0,
    -- cm between dropped pickups
    DropSpacing = 25.0,
    -- Verbose logging to the UE4SS console / UE4SS.log
    Debug = true,

    -- Advanced / recovery ---------------------------------------------------------------------------
    -- Last-resort unpause if the game stays paused with no menu open after one of this mod's dialogs.
    -- Off by default: the game's own pickup preview pauses briefly and must not be interrupted.
    ForceUnpauseFallback = false,
    -- Pressing F8 in game sets the consumable slot count to this value (nil = key does nothing).
    -- Only needed to undo a slot count left wrong by an earlier version of this mod.
    FixConsumableSlotCount = nil,
    -- Seconds an inventory snapshot taken when a replace dialog opens stays valid.
    SnapshotTTL = 180,
}

------------------------------------------------------------------------------
-- Constants (verified against the game's reflection dump, build 1.3.x / UE 5.4.2)
------------------------------------------------------------------------------
local PICKUP_BP_CLASS = "/Game/Blueprint/InteractUnit/BP_Interact_Pickup.BP_Interact_Pickup_C"
local WEAPON_INTERACT_FMT     = "/Game/Blueprint/InteractUnit/Pickup/Weapon/BP_Interact_Pickup_Wep_%s.BP_Interact_Pickup_Wep_%s_C"
local CONSUMABLE_INTERACT_FMT = "/Game/Blueprint/InteractUnit/Pickup/Consumable/BP_Interact_Pickup_Con_%s.BP_Interact_Pickup_Con_%s_C"
local INVENTORY_FUNCLIB = "/Script/GameNoce.Default__NoceInventoryFunctionLibrary"
local POPWINDOW_CLASS = "/Game/UI/PopWindow/WBP_PopWindow.WBP_PopWindow_C"
local POPWINDOW_TYPE_ENUM = "/Script/GameNoce.ENoceUIPopWindowType"
local UI_SUBSYSTEM_CLASS  = "/Script/GameNoce.NoceUISubsystem"
local NOCE_FUNCLIB        = "/Script/GameNoce.Default__NoceFunctionLibrary"
local FOCUSABLE_CONFIRM_FN = "/Script/GameNoce.NoceFocusableWidget:Confirm"
local FOCUSABLE_CANCEL_FN  = "/Script/GameNoce.NoceFocusableWidget:Cancel"
-- engine-side helpers
local WIDGET_BP_FUNCLIB  = "/Script/UMG.Default__WidgetBlueprintLibrary"
local SUBSYSTEM_FUNCLIB  = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local I18N_FUNCLIB       = "/Script/Engine.Default__KismetInternationalizationLibrary"

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------
local function Log(fmt, ...)
    print(string.format("[SHf_SmartPickup] " .. fmt .. "\n", ...))
end
local function Dbg(fmt, ...)
    if Config.Debug then Log(fmt, ...) end
end
do -- reject an InstantUse value that is not one of InstantUseMode
    local known = false
    for _, v in pairs(InstantUseMode) do if v == Config.InstantUse then known = true end end
    if not known then
        Log("Config.InstantUse = %s is not a valid value, using \"%s\"", tostring(Config.InstantUse), InstantUseMode.Useful)
        Config.InstantUse = InstantUseMode.Useful
    end
end
local function Valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local nop = function() end
-- Calls fn in protected mode: its result on success, `default` (nil) if it raised.
local function Try(fn, default)
    local ok, v = pcall(fn)
    if ok then return v end
    return default
end

local function GetPlayerState()
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) then return nil end
    local ps = pc.PlayerState
    if not Valid(ps) then return nil end
    return ps
end

local function GetInventory()
    local ps = GetPlayerState()
    if not ps then return nil, nil end
    local inv = ps.InventoryComponent
    if not Valid(inv) then return nil, ps end
    return inv, ps
end

local function GetConsumableData(id)
    local lib = StaticFindObject(INVENTORY_FUNCLIB)
    if not Valid(lib) then return nil end
    local data = nil
    local ok, err = pcall(function() data = lib:GetConsumableData(FName(id)) end)
    if not ok then Dbg("GetConsumableData(%s) failed: %s", id, tostring(err)); return nil end
    return data
end

local function GetUISubsystem()
    local sub = Try(function()
        local lib = StaticFindObject(SUBSYSTEM_FUNCLIB)
        local cls = StaticFindObject(UI_SUBSYSTEM_CLASS)
        return lib:GetWorldSubsystem(UEHelpers.GetWorldContextObject(), cls)
    end)
    if Valid(sub) then return sub end
    return nil
end

local function IsGamePaused()
    return Try(function() return UEHelpers.GetGameplayStatics():IsGamePaused(UEHelpers.GetWorldContextObject()) end, false)
end

-- TArray<T> -> lua table (1-based); map(elem) converts one element
local function ArrayToTable(arr, name, map)
    local t = {}
    if arr == nil then return t end
    local ok, err = pcall(function()
        arr:ForEach(function(i, elem) t[i] = map(elem:get()) end)
    end)
    if not ok then Dbg("%s failed: %s", name, tostring(err)) end
    return t
end

-- Number of elements of a TArray (or a plain lua table); 0 if it cannot be read.
local function ArrayNum(arr)
    if type(arr) == "table" then return #arr end
    return Try(function() return arr:GetArrayNum() end, 0)
end

-- TArray<FName>
local function NamesToTable(arr)
    return ArrayToTable(arr, "NamesToTable", function(s) return s:ToString() end)
end

-- TArray<FNoceInventoryWeapon> {IDIndex, Durability}
local function SnapshotWeapons(arr)
    return ArrayToTable(arr, "SnapshotWeapons", function(s)
        return { IDIndex = s.IDIndex, Durability = s.Durability }
    end)
end

-- TArray<FNoceInventoryConsumable> {IDIndex, Quantity}
local function SnapshotConsumables(arr)
    return ArrayToTable(arr, "SnapshotConsumables", function(s)
        return { IDIndex = s.IDIndex, Quantity = s.Quantity }
    end)
end

local function DescribeConsumables(list, names)
    local parts = {}
    for _, c in ipairs(list) do
        if c.Quantity and c.Quantity > 0 then
            parts[#parts + 1] = string.format("%s=%d", tostring(names[c.IDIndex + 1] or c.IDIndex), c.Quantity)
        end
    end
    return table.concat(parts, " ")
end
local function DescribeWeapons(list, names)
    local parts = {}
    for _, w in ipairs(list) do
        parts[#parts + 1] = string.format("%s(%.0f)", tostring(names[w.IDIndex + 1] or w.IDIndex), w.Durability or -1)
    end
    return table.concat(parts, " ")
end

local function ActiveWeaponArray(inv)
    if inv.CurrentUseFogWeapon then return inv.FogWeapons, true end
    return inv.DarkWeapons, false
end

local ClassCache = {}
local function LoadClass(path)
    if ClassCache[path] and ClassCache[path]:IsValid() then return ClassCache[path] end
    local cls = StaticFindObject(path)
    if not Valid(cls) then
        cls = Try(function() return LoadAsset(path) end)
        if not Valid(cls) then cls = StaticFindObject(path) end
    end
    if Valid(cls) then ClassCache[path] = cls; return cls end
    Log("Could not load class %s", path)
    return nil
end

-- Spawns a BP_Interact_Pickup_* at the given location/rotation. Returns the actor or nil.
local function SpawnInteract(classPath, location, rotation)
    local cls = LoadClass(classPath)
    if not cls then return nil end
    local world = UEHelpers.GetWorld()
    if not Valid(world) then Log("No world to spawn in"); return nil end
    local actor = nil
    local ok, err = pcall(function() actor = world:SpawnActor(cls, location, rotation) end)
    if not ok or not Valid(actor) then
        Log("SpawnActor failed for %s: %s", classPath, tostring(err))
        return nil
    end
    -- Spawned pickups are not part of the level: mark them dynamic so the save system ignores them.
    pcall(function() actor.IsDynamic = true end)
    Dbg("Spawned %s", actor:GetFullName())
    return actor
end

local function ActorLocRot(actor)
    local loc = actor:K2_GetActorLocation()
    local rot = actor:K2_GetActorRotation()
    return { X = loc.X, Y = loc.Y, Z = loc.Z }, { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }
end

local function Later(ms, fn)
    ExecuteWithDelay(ms, function() ExecuteInGameThread(fn) end)
end

------------------------------------------------------------------------------
-- Per-actor transient state (keyed by actor address)
------------------------------------------------------------------------------
local WeaponSnapshot = {}      -- addr -> { list, isFog, time }
local ConsumableSnapshot = {}  -- addr -> { list, time }
local DroppedWeaponInfo = {}   -- addr(of spawned interact actor) -> { id = "Axe", durability = 123.0 }

local function Fresh(snap) return snap ~= nil and (os.time() - (snap.time or 0)) <= Config.SnapshotTTL end

------------------------------------------------------------------------------
-- In-game confirmation dialog (the game's own WBP_PopWindow / UNocePopWindowWidget)
------------------------------------------------------------------------------
local DialogTexts = {
    ru = { use = "Инвентарь полон.\nИспользовать «%s» сейчас?" },
    en = { use = "Inventory is full.\nUse %s right now?" },
    ja = { use = "持ち物がいっぱいです。\n「%s」を今使いますか？" },
    de = { use = "Inventar ist voll.\n%s jetzt benutzen?" },
    fr = { use = "Inventaire plein.\nUtiliser %s maintenant ?" },
    es = { use = "Inventario lleno.\n¿Usar %s ahora?" },
    it = { use = "Inventario pieno.\nUsare %s adesso?" },
    pl = { use = "Ekwipunek pełny.\nUżyć %s teraz?" },
    pt = { use = "Inventário cheio.\nUsar %s agora?" },
    ko = { use = "소지품이 가득 찼습니다.\n%s을(를) 지금 사용할까요?" },
    zh = { use = "物品栏已满。\n现在使用“%s”？" },
}
local function GetDialogText(key, ...)
    local lang = "en"
    pcall(function()
        local lib = StaticFindObject(I18N_FUNCLIB)
        if Valid(lib) then lang = lib:GetCurrentLanguage():ToString() end
    end)
    local short = string.lower(string.sub(lang, 1, 2))
    local t = DialogTexts[short] or DialogTexts.en
    return string.format(t[key] or DialogTexts.en[key], ...)
end

-- Resolve ENoceUIPopWindowType::<Name> to its numeric value at runtime (falls back to the dumped order).
local PopTypeCache = {}
local function PopWindowTypeValue(name)
    if PopTypeCache[name] then return PopTypeCache[name] end
    local fallback = { Invalid = 0, Yes = 1, YesNoDefaultY = 2, YesNoDefaultN = 3, Custom = 4 }
    local value = fallback[name]
    pcall(function()
        local enum = StaticFindObject(POPWINDOW_TYPE_ENUM)
        if Valid(enum) then
            enum:ForEachName(function(fname, v)
                local n = fname:ToString()
                if n == name or n == "ENoceUIPopWindowType::" .. name then value = v end
            end)
        end
    end)
    PopTypeCache[name] = value
    return value
end

local ActiveDialog = nil   -- { widget, result = nil|true|false, cb }

-- Polls (100 ms) until the game is no longer paused (max `maxTicks`), then runs fn on the game thread.
function WaitForGameUnpaused(widget, maxTicks, fn)
    local ticks, done = 0, false
    LoopAsync(100, function()
        if done then return true end
        ticks = ticks + 1
        ExecuteInGameThread(function()
            if done then return end
            local paused = IsGamePaused()
            local showing = false
            if widget and Valid(widget) then showing = Try(function() return widget:IsShowing() end, false) end
            if (not paused and not showing) or ticks >= maxTicks then
                done = true
                if paused then
                    Dbg("Game still paused after the dialog closed (%d ticks)", ticks)
                    if widget and Valid(widget) then
                        local ui = GetUISubsystem()
                        if ui then pcall(function() ui:RemoveWidget(widget) end) end
                    end
                end
                fn()
                Later(1200, function() EnsureGameUnpaused("after dialog") end)
            end
        end)
        return done
    end)
end

-- Safety net: if nothing of the game's UI is open but the game is still paused, release it.
local function IsFocusableWidget(w)
    local ok, v = pcall(function() return w.NeedPauseGame end)
    return ok and v ~= nil
end
local function AnyFocusableWidgetOpen()
    local ui = GetUISubsystem()
    if not ui then return false, nil end
    local found = nil
    pcall(function()
        local st = ui:GetWidgetStack()
        local function check(w)
            if Valid(w) and IsFocusableWidget(w) then
                local showing = Try(function() return w:IsShowing() end, true)
                if showing then found = w end
            end
        end
        if type(st) == "table" then for _, w in ipairs(st) do check(w) end
        else st:ForEach(function(_, e) check(e:get()) end) end
    end)
    return found ~= nil, found
end
function EnsureGameUnpaused(reason) -- global: referenced from WaitForGameUnpaused above
    if ActiveDialog ~= nil then return end
    if not IsGamePaused() then return end
    local open, w = AnyFocusableWidgetOpen()
    if open then Dbg("Game paused but a UI widget is open (%s), leaving it", w:GetFullName()); return end
    if not Config.ForceUnpauseFallback then
        Dbg("Game is paused with no focusable widget detected (%s); not touching it (ForceUnpauseFallback=false)", reason)
        return
    end
    Log("Game was left paused with no UI open (%s) - unpausing", reason)
    pcall(function() UEHelpers.GetGameplayStatics():SetGamePaused(UEHelpers.GetWorldContextObject(), false) end)
    pcall(function()
        local pc = UEHelpers.GetPlayerController()
        StaticFindObject(WIDGET_BP_FUNCLIB):SetInputMode_GameOnly(pc)
        pc.bShowMouseCursor = false
    end)
end

-- Confirm/Cancel of NoceFocusableWidget: hooked best-effort (pre hooks). If they never fire,
-- LastSelectedIndex is used when the window closes.
local FocusHooksDone = false
local function RegisterFocusHooks()
    if FocusHooksDone then return end
    FocusHooksDone = true
    local ok1 = pcall(function()
        RegisterHook(FOCUSABLE_CONFIRM_FN, function(ctx)
            local w = ctx:get()
            if ActiveDialog and ActiveDialog.widget and ActiveDialog.widget:GetAddress() == w:GetAddress() then
                local idx = Try(function() return w.List.SelectingIndex end, -1)
                local last = Try(function() return w.LastSelectedIndex end, -1)
                if idx == nil or idx < 0 then idx = last end
                ActiveDialog.result = (idx == 0)
                Dbg("Dialog Confirm, List.SelectingIndex=%s LastSelectedIndex=%s -> %s", tostring(idx), tostring(last), tostring(ActiveDialog.result))
            end
        end, nop)
    end)
    local ok2 = pcall(function()
        RegisterHook(FOCUSABLE_CANCEL_FN, function(ctx)
            local w = ctx:get()
            if ActiveDialog and ActiveDialog.widget and ActiveDialog.widget:GetAddress() == w:GetAddress() then
                ActiveDialog.result = false
                Dbg("Dialog Cancel")
            end
        end, nop)
    end)
    Dbg("Focus hooks: Confirm=%s Cancel=%s", tostring(ok1), tostring(ok2))
end

-- Shows a Yes/No pop-up (default = No) and calls cb(true|false) once it is closed.
-- Returns false if the dialog could not be created (caller should fall back).
local function ShowYesNoDialog(worldContext, text, cb)
    if ActiveDialog then Dbg("A dialog is already open"); return false end
    local cls = LoadClass(POPWINDOW_CLASS)
    if not cls then return false end
    local pc = UEHelpers.GetPlayerController()
    local wbl = StaticFindObject(WIDGET_BP_FUNCLIB)
    if not Valid(pc) or not Valid(wbl) then return false end
    local w = nil
    local ok, err = pcall(function() w = wbl:Create(worldContext, cls, pc) end)
    if not ok or not Valid(w) then Log("Could not create pop window: %s", tostring(err)); return false end

    RegisterFocusHooks()
    local okT, errT = pcall(function() w:SetType(PopWindowTypeValue("YesNoDefaultN")) end)
    if not okT then Dbg("SetType failed: %s", tostring(errT)) end
    local okD, errD = pcall(function() w:SetDialog(FText(text)) end)
    if not okD then Dbg("SetDialog failed: %s", tostring(errD)) end
    pcall(function() w:SetDefaultIndex(1) end)
    -- same flags as the game's own WBP_ReplaceItem / WBP_ReplaceWeapon: pause + UI input mode
    pcall(function() w.NeedPauseGame = true end)
    pcall(function() w.NeedSetUIGameMode = true end)

    ActiveDialog = { widget = w, result = nil, cb = cb }
    ok, err = pcall(function() w:Show() end)
    if not ok then Log("PopWindow Show() failed: %s", tostring(err)); ActiveDialog = nil; return false end
    Dbg("Dialog shown: %s", (text:gsub("\n", " ")))

    local ticks, seenShowing, finished = 0, false, false
    LoopAsync(100, function()
        if finished then return true end
        ticks = ticks + 1
        ExecuteInGameThread(function()
            if finished or not ActiveDialog then return end
            local showing = Try(function() return ActiveDialog.widget:IsShowing() end, false)
            if showing then seenShowing = true; return end
            -- not showing any more: closed (or it never appeared within 1.5 s)
            if seenShowing or ticks > 15 then
                finished = true
                local res = ActiveDialog.result
                if res == nil then
                    local idx = Try(function() return ActiveDialog.widget.LastSelectedIndex end, -1)
                    Dbg("Dialog closed without Confirm/Cancel hook (LastSelectedIndex=%s) -> treated as No", tostring(idx))
                    res = false
                end
                local callback = ActiveDialog.cb
                local widget = ActiveDialog.widget
                ActiveDialog = nil
                -- The widget restores pause / input mode at the end of its fade-out. Opening the next UI
                -- before that point makes that UI cache "paused" as the state to restore -> soft lock.
                WaitForGameUnpaused(widget, 25, function() pcall(callback, res == true) end)
            end
        end)
        return finished
    end)
    return true
end

------------------------------------------------------------------------------
-- Feature 1: weapon replace -> drop old weapon (diff done in HandlePickupSuccess)
------------------------------------------------------------------------------
local function OnShowReplaceWeapon_Pre(ctx)
    Dbg("[hook] ShowReplaceWeapon (pre)")
    if not Config.DropReplacedWeapon then return end
    local self = ctx:get()
    local inv = GetInventory()
    if not inv then return end
    local arr, isFog = ActiveWeaponArray(inv)
    local list = SnapshotWeapons(arr)
    WeaponSnapshot[self:GetAddress()] = { list = list, isFog = isFog, time = os.time() }
    Dbg("Weapon replace UI opened (fog=%s): %s", tostring(isFog), DescribeWeapons(list, NamesToTable(inv.AllWeaponIDs)))
end

local function FinishWeaponReplace(snap, loc, rot, attempt)
    local inv = GetInventory()
    if not inv then Dbg("Weapon replace: no inventory"); return end
    local arr = snap.isFog and inv.FogWeapons or inv.DarkWeapons
    local now = SnapshotWeapons(arr)
    local names = NamesToTable(inv.AllWeaponIDs)
    Dbg("Weapon replace (attempt %d): before [%s] after [%s]", attempt, DescribeWeapons(snap.list, names), DescribeWeapons(now, names))

    local old = nil
    for i, o in ipairs(snap.list) do
        local n = now[i]
        if n == nil or n.IDIndex ~= o.IDIndex or math.abs(n.Durability - o.Durability) > 0.001 then
            old = o
            break
        end
    end
    if not old then
        if attempt < 3 then
            Later(400, function() FinishWeaponReplace(snap, loc, rot, attempt + 1) end)
        else
            Dbg("Weapon replace: nothing changed, nothing to drop")
        end
        return
    end
    local oldName = names[old.IDIndex + 1]
    if not oldName then Log("Weapon replace: unknown weapon index %d", old.IDIndex); return end
    local dropped = SpawnInteract(string.format(WEAPON_INTERACT_FMT, oldName, oldName), loc, rot)
    if dropped then
        DroppedWeaponInfo[dropped:GetAddress()] = { id = oldName, durability = old.Durability }
        Log("Dropped weapon %s (durability %.1f) at %.0f %.0f %.0f", oldName, old.Durability, loc.X, loc.Y, loc.Z)
    end
end

-- When a dropped weapon is picked up again, restore its durability.
local function RestoreDroppedWeaponDurability(self)
    local addr = self:GetAddress()
    local info = DroppedWeaponInfo[addr]
    if not info then return end
    DroppedWeaponInfo[addr] = nil
    local inv = GetInventory()
    if not inv then return end
    local names = NamesToTable(inv.AllWeaponIDs)
    local idIndex = nil
    for i, n in ipairs(names) do if n == info.id then idIndex = i - 1; break end end
    if idIndex == nil then return end
    -- the freshly added copy has the highest durability (full) -> that is the one we just picked up
    local bestIdx, bestDur, bestFog = nil, -1, nil
    for _, isFog in ipairs({ true, false }) do
        local list = SnapshotWeapons(isFog and inv.FogWeapons or inv.DarkWeapons)
        for i, w in ipairs(list) do
            if w.IDIndex == idIndex and w.Durability > bestDur then
                bestIdx, bestDur, bestFog = i - 1, w.Durability, isFog
            end
        end
    end
    if bestIdx == nil then Dbg("Restore durability: %s not found in inventory", info.id); return end
    local ok, err = pcall(function() inv:SetWeaponDurability(bestIdx, bestFog, info.durability) end)
    if ok then
        Log("Restored durability of %s to %.1f", info.id, info.durability)
    else
        Log("SetWeaponDurability failed: %s", tostring(err))
    end
end

------------------------------------------------------------------------------
-- Feature 2: consumable pickup with full inventory -> ask, then use it now
------------------------------------------------------------------------------
local function GetPickupConsumable(self)
    local pc = self.PickupClass
    if not Valid(pc) then return nil end
    local child = pc.ChildActor
    if not Valid(child) then return nil end
    local ok, id = pcall(function() return child.ConsumableID.RowName:ToString() end)
    if not ok or id == nil or id == "" or id == "None" then return nil end
    local count = Try(function() return child.Count end, 1)
    if count == nil or count < 1 then count = 1 end
    return child, id, count
end

-- Applies the item effect without it ever entering the inventory (case B).

-- Gameplay effect classes per consumable row (DT_ConsumableItem, game build 1.3.x).
-- Kept static because UE4SS cannot hand a lua table back to the game as TArray<FSoftClassPath>.
local GE_PATHS = {
    Capsule = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_S.GE_RecoverHealth_S_C",
                "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverMaxSanity_S.GE_RecoverMaxSanity_S_C",
                "/Game/Character/Player/Base/GameplayAbility/Effect/GE_FillSanityToCurrentMaxSanity.GE_FillSanityToCurrentMaxSanity_C" },
    CapsuleShiromuku2 = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_XL.GE_RecoverHealth_XL_C",
                "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverMaxSanity_XL.GE_RecoverMaxSanity_XL_C",
                "/Game/Character/Player/Base/GameplayAbility/Effect/GE_FillSanityToCurrentMaxSanity.GE_FillSanityToCurrentMaxSanity_C" },
    MedKitA = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_L.GE_RecoverHealth_L_C" },
    MedKitB = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_XL.GE_RecoverHealth_XL_C" },
    DrinkA = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverMaxSanity_L.GE_RecoverMaxSanity_L_C",
               "/Game/Character/Player/Base/GameplayAbility/Effect/GE_FillSanityToCurrentMaxSanity.GE_FillSanityToCurrentMaxSanity_C",
               "/Game/Blueprint/GameplayAbility/Effect/GE_BackMarkRound3_RecoverClawTransform_L.GE_BackMarkRound3_RecoverClawTransform_L_C" },
    DrinkB = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverMaxSanity_XL.GE_RecoverMaxSanity_XL_C",
               "/Game/Character/Player/Base/GameplayAbility/Effect/GE_FillSanityToCurrentMaxSanity.GE_FillSanityToCurrentMaxSanity_C",
               "/Game/Blueprint/GameplayAbility/Effect/GE_Buff_SanityDamageRatioDown.GE_Buff_SanityDamageRatioDown_C",
               "/Game/Blueprint/GameplayAbility/Effect/GE_BackMarkRound3_RecoverClawTransform_XL.GE_BackMarkRound3_RecoverClawTransform_XL_C" },
    DrinkC = { "/Game/Blueprint/GameplayAbility/Effect/GE_Buff_HealthRegen_L.GE_Buff_HealthRegen_L_C",
               "/Game/Blueprint/GameplayAbility/Effect/GE_Buff_SanityRegen_L.GE_Buff_SanityRegen_L_C",
               "/Game/Blueprint/GameplayAbility/Effect/GE_Buff_Regen_ShowHUDHint_L.GE_Buff_Regen_ShowHUDHint_L_C",
               "/Game/Blueprint/GameplayAbility/Effect/GE_BackMarkRound3_Buff_ClawTransformRegen_L.GE_BackMarkRound3_Buff_ClawTransformRegen_L_C" },
    FoodA = { "/Game/Character/Player/Base/GameplayAbility/Effect/GE_FullStamina.GE_FullStamina_C",
              "/Game/Blueprint/GameplayAbility/Effect/GE_Buff_StaminaNoCost.GE_Buff_StaminaNoCost_C" },
    FoodB = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_XL.GE_RecoverHealth_XL_C",
              "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverMaxSanity_XL.GE_RecoverMaxSanity_XL_C",
              "/Game/Character/Player/Base/GameplayAbility/Effect/GE_FillSanityToCurrentMaxSanity.GE_FillSanityToCurrentMaxSanity_C",
              "/Game/Character/Player/Base/GameplayAbility/Effect/GE_FullStamina.GE_FullStamina_C",
              "/Game/Blueprint/GameplayAbility/Effect/GE_BackMarkRound3_RecoverClawTransform_XL.GE_BackMarkRound3_RecoverClawTransform_XL_C" },
    FoodC = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverMaxSanity_S.GE_RecoverMaxSanity_S_C",
              "/Game/Character/Player/Base/GameplayAbility/Effect/GE_FillSanityToCurrentMaxSanity.GE_FillSanityToCurrentMaxSanity_C",
              "/Game/Blueprint/GameplayAbility/Effect/GE_Buff_SanityNoCost_Focus.GE_Buff_SanityNoCost_Focus_C",
              "/Game/Blueprint/GameplayAbility/Effect/GE_Buff_SanityNoCost_FocusAttack.GE_Buff_SanityNoCost_FocusAttack_C",
              "/Game/Blueprint/GameplayAbility/Effect/GE_BackMarkRound3_RecoverClawTransform_S.GE_BackMarkRound3_RecoverClawTransform_S_C" },
    FoodD = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_L.GE_RecoverHealth_L_C" },
    FoodE = { "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_S_FoodE.GE_RecoverHealth_S_FoodE_C",
              "/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_S_FoodE_DuringTimerTick.GE_RecoverHealth_S_FoodE_DuringTimerTick_C",
              "/Game/Character/Player/Base/GameplayAbility/Effect/GE_Pl_FoodETimerTick.GE_Pl_FoodETimerTick_C" },
}
-- Last-resort approximation of the main effects (magnitudes read from the GE assets: S=0.2 L=0.5 XL=1.0).
local GE_MANUAL = {
    GE_RecoverHealth_S = { attr = "Health", max = "MaxHealth", ratio = 0.2 },
    GE_RecoverHealth_S_FoodE = { attr = "Health", max = "MaxHealth", ratio = 0.2 },
    GE_RecoverHealth_L = { attr = "Health", max = "MaxHealth", ratio = 0.5 },
    GE_RecoverHealth_XL = { attr = "Health", max = "MaxHealth", ratio = 1.0 },
    GE_RecoverMaxSanity_S = { attr = "CurrentMaxSanity", max = "MaxSanity", ratio = 0.2 },
    GE_RecoverMaxSanity_L = { attr = "CurrentMaxSanity", max = "MaxSanity", ratio = 0.5 },
    GE_RecoverMaxSanity_XL = { attr = "CurrentMaxSanity", max = "MaxSanity", ratio = 1.0 },
    GE_FillSanityToCurrentMaxSanity = { attr = "Sanity", max = "CurrentMaxSanity", ratio = 1.0 },
    GE_FullStamina = { attr = "Stamina", max = "MaxStamina", ratio = 1.0 },
}
local TRACKED = { { "Health", "MaxHealth" }, { "Stamina", "MaxStamina" }, { "Sanity", "CurrentMaxSanity" }, { "CurrentMaxSanity", "MaxSanity" } }

local function AttrValue(ps, name)
    return Try(function() return ps.PlayerAttributeSet[name].CurrentValue end)
end
local function ReadAttributes(ps)
    local t = {}
    for _, pair in ipairs(TRACKED) do t[pair[1]] = AttrValue(ps, pair[1]); t[pair[2]] = AttrValue(ps, pair[2]) end
    return t
end
local function DescribeAttributes(t)
    local parts = {}
    for _, pair in ipairs(TRACKED) do
        parts[#parts + 1] = string.format("%s=%s/%s", pair[1], tostring(t[pair[1]] and math.floor(t[pair[1]] + 0.5)), tostring(t[pair[2]] and math.floor(t[pair[2]] + 0.5)))
    end
    return table.concat(parts, " ")
end
-- true if any tracked attribute changed, or if every attribute the item targets was already full
local function EffectVerified(before, after, id)
    for _, pair in ipairs(TRACKED) do
        local a, b = before[pair[1]], after[pair[1]]
        if a and b and math.abs(a - b) > 0.01 then return true end
    end
    local targets = 0
    for _, path in ipairs(GE_PATHS[id] or {}) do
        local m = GE_MANUAL[path:match("([^./]+)_C$") or ""]
        if m then
            targets = targets + 1
            local cur, mx = before[m.attr], before[m.max]
            if not (cur and mx and cur >= mx - 0.01) then return false end
        end
    end
    return targets > 0
end

-- Applies the item's effects to the player. Returns true when verified (or at least attempted via the game's code).
local function ApplyItemEffects(ps, id, data)
    local paths = GE_PATHS[id]
    if not paths or #paths == 0 then return true end -- nothing to apply (e.g. repair kit handled separately)
    local before = ReadAttributes(ps)
    Dbg("Attributes before: %s", DescribeAttributes(before))

    local after = before
    -- 1. gameplay effect classes through the ability system component (verified to work in-game)
    local asc = ps.AbilitySystemComponent
    if Valid(asc) then
        local applied, firstErr = 0, nil
        for _, path in ipairs(paths) do
            local cls = LoadClass(path)
            if cls then
                local ok2, err2 = pcall(function() asc:BP_ApplyGameplayEffectToSelf(cls, 1.0, {}) end)
                if ok2 then applied = applied + 1 else firstErr = firstErr or tostring(err2) end
            end
        end
        after = ReadAttributes(ps)
        -- Every class applied without error -> done. Buffs / regeneration effects change attributes over
        -- time, so an unchanged snapshot is not a failure here.
        if applied == #paths or (applied > 0 and EffectVerified(before, after, id)) then
            Log("Effect of %s applied via AbilitySystem (%d/%d classes, %s)", id, applied, #paths, DescribeAttributes(after)); return true
        end
        Dbg("AbilitySystem path: applied=%d/%d err=%s", applied, #paths, tostring(firstErr))
    end

    -- 2. manual approximation: write the attribute values directly
    local touched = 0
    for _, path in ipairs(paths) do
        local m = GE_MANUAL[path:match("([^./]+)_C$") or ""]
        if m then
            local cur, mx = AttrValue(ps, m.attr), AttrValue(ps, m.max)
            if cur and mx then
                local newV = math.min(mx, cur + m.ratio * mx)
                local okW = pcall(function()
                    local a = ps.PlayerAttributeSet[m.attr]
                    a.CurrentValue = newV
                    a.BaseValue = newV
                end)
                if okW then touched = touched + 1 end
            end
        end
    end
    after = ReadAttributes(ps)
    if touched > 0 then
        Log("Effect of %s applied by direct attribute write (approximation, %s)", id, DescribeAttributes(after)); return true
    end
    Log("Effect of %s could not be applied by any method", id)
    return false
end

-- Repairs the weapon the player is holding through the weapon actor itself (what the game's own
-- repair kit does). Returns true when the durability went up.
local function RepairWeaponInHand(ratio)
    local pawn = UEHelpers.GetPlayer()
    if not Valid(pawn) then return false end
    local weapon = Try(function() return pawn.CurrentWeapon end)
    if not Valid(weapon) then Dbg("No weapon actor in hand"); return false end
    local cur = Try(function() return weapon:GetDurability() end)
    local max = Try(function() return weapon:GetMaxDurability() end)
    if not cur or not max or max <= 0 then Dbg("Weapon in hand: durability unknown (%s/%s)", tostring(cur), tostring(max)); return false end
    if cur >= max - 0.01 then error("weapon already at max durability") end
    local add = math.min(max - cur, ratio * max)
    local ok, err = pcall(function() weapon:AddDurability(add) end)
    if not ok then Dbg("AddDurability failed: %s", tostring(err)); return false end
    local after = Try(function() return weapon:GetDurability() end, cur)
    Log("Repaired weapon in hand (%s): %.1f -> %.1f (max %.1f)", weapon:GetFullName():match("([^./:]+)_C") or "?", cur, after, max)
    return after > cur + 0.01
end

-- Max durability of a weapon row, via the weapon subsystem (several lookups, never trusts a zero).
local function GetWeaponMaxDurability(inv, wname)
    if not wname then return nil end
    local candidates = {}
    pcall(function() if Valid(inv.WeaponSubsystem) then candidates[#candidates + 1] = inv.WeaponSubsystem end end)
    pcall(function()
        local lib = StaticFindObject(NOCE_FUNCLIB)
        local ws = lib:GetWeaponSubSystem(UEHelpers.GetWorldContextObject())
        if Valid(ws) then candidates[#candidates + 1] = ws end
    end)
    pcall(function() local ws = FindFirstOf("NoceWeaponSubsystem"); if Valid(ws) then candidates[#candidates + 1] = ws end end)
    for _, ws in ipairs(candidates) do
        local v = Try(function() return ws:GetMaxDurability(FName(wname)) end)
        if v and v > 0 then return v end
        v = Try(function() return ws:GetMaxDurability(ws:GetWeaponQueryName(FName(wname))) end)
        if v and v > 0 then return v end
    end
    Dbg("GetWeaponMaxDurability(%s): %d subsystem candidate(s), none returned a value", tostring(wname), #candidates)
    return nil
end

local function ApplyConsumableDirectly(ps, inv, id, data)
    local ok, err = pcall(function()
        if not ApplyItemEffects(ps, id, data) then error("no gameplay effect could be applied") end
        -- Repair kit (WeaponRecoverA): WeaponDurabilityRecoverRatio of max durability on the equipped weapon.
        local ratio = data.WeaponDurabilityRecoverRatio or 0
        if ratio > 0 and RepairWeaponInHand(ratio) then return end
        if ratio > 0 then
            local idx = inv:GetEquippedWeaponIndex()
            if idx == nil or idx < 0 then error("no equipped weapon to repair") end
            local isFog = inv.CurrentUseFogWeapon
            local names = NamesToTable(inv.AllWeaponIDs)
            local list = SnapshotWeapons(isFog and inv.FogWeapons or inv.DarkWeapons)
            local w = list[idx + 1]
            if not w then error("equipped weapon slot not found") end
            local wname = names[w.IDIndex + 1]
            local maxDur = GetWeaponMaxDurability(inv, wname)
            if not maxDur or maxDur <= 0 then error("unknown max durability for " .. tostring(wname)) end
            local newDur = math.min(maxDur, w.Durability + ratio * maxDur)
            if newDur <= w.Durability + 0.01 then error("weapon already at max durability") end
            inv:SetWeaponDurability(idx, isFog, newDur)
            -- the weapon in hand keeps its own durability: push the value to it as well
            pcall(function() inv:SetEquippedWeaponDurability(FName(wname), newDur) end)
            Log("Repaired %s: %.1f -> %.1f (max %.1f)", tostring(wname), w.Durability, newDur, maxDur)
        end
    end)
    if not ok then Log("ApplyConsumableDirectly(%s) failed: %s", id, tostring(err)) end
    return ok
end

-- Performs the actual "use now" once the player agreed.
local function DoInstantUse(self, id, count, haveIt, data)
    local inv, ps = GetInventory()
    if not inv or not ps then return end
    pcall(function() self.InteractPawn = UEHelpers.GetPlayer() end)
    if haveIt then
        -- Case A: one unit of this kind is already carried -> remove one, apply its effect, take the new one.
        local ok, err = pcall(function() inv:UseConsumable(FName(id)) end)
        if not ok then Log("UseConsumable(%s) failed: %s", id, tostring(err)); return end
        if not ApplyConsumableDirectly(ps, inv, id, data) then Log("Effect of %s could not be applied", id) end
        local canAdd = Try(function() return inv:CanAddConsumable(FName(id), count) end, false)
        if canAdd then
            pcall(function() self:HandleOnPickup() end)
            Log("Used one %s from the inventory and picked the new one up", id)
        else
            Dbg("Used one %s but still cannot add %d, opening replace UI", id, count)
            pcall(function() self:ShowReplaceConsumableUI() end)
        end
        return
    end
    -- Case B: not carried -> apply the effect directly and consume the pickup.
    if ApplyConsumableDirectly(ps, inv, id, data) then
        pcall(function() self:HandlePickupSuccess() end)
        Log("Used %s directly on pickup", id)
    else
        pcall(function() self:ShowReplaceConsumableUI() end)
    end
end

-- Decides whether the instant-use offer applies. Returns id, count, haveIt, data (or nil).
local function EvaluateInstantUse(self)
    local child, id, count = GetPickupConsumable(self)
    if not id then Dbg("No consumable id on this pickup"); return nil end
    local inv, ps = GetInventory()
    if not inv or not ps then Dbg("No inventory/player state"); return nil end
    local data = GetConsumableData(id)
    if data == nil then Dbg("No consumable data for %s", id); return nil end
    local mask = data.ItemAttributeCheckType or 0
    local hasEffects = ArrayNum(data and data.GameplayEffects) > 0
    local recover = data.WeaponDurabilityRecoverRatio or 0
    -- Offerings (Faith items) have no effect of their own: never auto-use them.
    if not hasEffects and recover <= 0 then Dbg("%s has no direct effect, leaving replace UI", id); return nil end
    -- Only single items are offered: a stack (e.g. one this mod dropped) always goes to the replace dialog.
    if count > 1 then Dbg("%s x%d is a stack, leaving replace UI", id, count); return nil end
    -- "always": skip the "useful right now" checks for items with gameplay effects. A repair kit has
    -- nothing to apply at max durability, so it keeps the game-side check.
    local skipUseful = Config.InstantUse == InstantUseMode.Always and hasEffects
    if mask == 0 and not skipUseful then
        -- no game-side check: look at the attributes this item restores
        local attrs = ReadAttributes(ps)
        local below, targets = false, 0
        for _, path in ipairs(GE_PATHS[id] or {}) do
            local m = GE_MANUAL[path:match("([^./]+)_C$") or ""]
            if m then
                targets = targets + 1
                local cur, mx = attrs[m.attr], attrs[m.max]
                if cur and mx and cur < mx - 0.01 then below = true end
            end
        end
        if targets > 0 and not below then Dbg("%s: nothing to restore right now (%s), leaving replace UI", id, DescribeAttributes(attrs)); return nil end
    end
    local usable = true
    if mask ~= 0 and not skipUseful then
        local ok, res = pcall(function() return ps:CanUseConsumableType(mask) end)
        usable = ok and res == true
        if not ok then Dbg("CanUseConsumableType failed: %s", tostring(res)) end
    end
    Dbg("Instant-use check for %s x%d: mask=%d usable=%s", id, count, mask, tostring(usable))
    if not usable then return nil end
    local names = NamesToTable(inv.AllConsumableIDs)
    local idIndex = nil
    for i, n in ipairs(names) do if n == id then idIndex = i - 1; break end end
    local haveIt = false
    if idIndex ~= nil then
        for _, c in ipairs(SnapshotConsumables(inv.Consumables)) do
            if c.IDIndex == idIndex and c.Quantity > 0 then haveIt = true; break end
        end
    end
    return id, count, haveIt, data
end

-- Puts the interactable back into a state where its own Blueprint flow can run again.
local function RestorePickupActor(self)
    pcall(function() self:UpdatePickupClass() end)          -- re-caches NocePickupBase from the child actor
    pcall(function() self.InteractPawn = UEHelpers.GetPlayer() end)
end

local PendingOffer = {}   -- addr -> { id, count, haveIt, data, asked = bool }

local function AskInstantUse(self, offer)
    local addr = self:GetAddress()
    if offer.asked then return end
    offer.asked = true
    local function decide(yes)
        PendingOffer[addr] = nil
        if not Valid(self) then Dbg("Pickup actor vanished before the decision"); return end
        RestorePickupActor(self)
        if yes then
            ConsumableSnapshot[addr] = nil
            DoInstantUse(self, offer.id, offer.count, offer.haveIt, offer.data)
            Later(2500, function() EnsureGameUnpaused("after instant use") end)
        else
            Dbg("Player declined instant use of %s, opening replace UI", offer.id)
            pcall(function() self:ShowReplaceConsumableUI() end)
        end
    end
    if not Config.ConfirmInstantUse then decide(true); return end
    local displayName = offer.id
    pcall(function()
        if type(offer.data.Name) == "string" then displayName = offer.data.Name else displayName = offer.data.Name:ToString() end
    end)
    if not ShowYesNoDialog(self, GetDialogText("use", displayName), decide) then
        Log("Dialog unavailable, using %s without asking", offer.id)
        decide(true)
    end
end

-- Runs right after the Blueprint computed OutValue (= "inventory cannot take it").
local function OnNeedShowReplaceConsumableUI(ctx, OutValue)
    local self = ctx:get()
    local addr = self:GetAddress()
    local outRaw = Try(function() return OutValue:get() end)
    Dbg("[hook] NeedShowReplaceConsumableUI OutValue=%s", tostring(outRaw))
    if Config.InstantUse == InstantUseMode.Off then return end
    if PendingOffer[addr] then
        -- the player interacted again while our question is pending: keep the Blueprint idle
        pcall(function() OutValue:set(false) end)
        pcall(function() self.NocePickupBase = nil end)
        Dbg("Interaction repeated while an offer is pending - ignored")
        return
    end
    local child, id, count = GetPickupConsumable(self)
    local inv = GetInventory()
    if not id or not inv then return end
    local canAdd = Try(function() return inv:CanAddConsumable(FName(id), count) end, true)
    if canAdd then return end -- fits into the inventory: vanilla
    local oid, ocount, haveIt, data = EvaluateInstantUse(self)
    if not oid then return end

    -- Steer the Blueprint away from the replace UI: OutValue=false makes ExecuteInstantFeedback call
    -- HandleOnPickup(); with NocePickupBase cleared that call does nothing (HandlePickupFail is empty).
    local okSet, errSet = pcall(function() OutValue:set(false) end)
    if not okSet then Dbg("OutValue:set failed: %s", tostring(errSet)) end
    pcall(function() self.NocePickupBase = nil end)
    PendingOffer[addr] = { id = oid, count = ocount, haveIt = haveIt, data = data, asked = false }
    -- Ask once the Blueprint flow has returned.
    Later(150, function()
        local offer = PendingOffer[addr]
        if offer and Valid(self) then AskInstantUse(self, offer) end
    end)
end

local function OnShowReplaceConsumableUI(ctx)
    Dbg("[hook] ShowReplaceConsumableUI (after body: the replace UI is open now)")
    local self = ctx:get()
    local addr = self:GetAddress()
    local inv = GetInventory()

    -- Feature 3: remember what the inventory looked like before the exchange.
    if Config.DropReplacedConsumables and inv then
        local list = SnapshotConsumables(inv.Consumables)
        ConsumableSnapshot[addr] = { list = list, time = os.time() }
        Dbg("Consumable snapshot (%d slots): %s", #list, DescribeConsumables(list, NamesToTable(inv.AllConsumableIDs)))
    end

    -- Feature 2 fallback: the OutValue override did not stop the replace UI. Close it and ask instead.
    local offer = PendingOffer[addr]
    if offer and not offer.asked then
        Log("Replace UI opened despite the override - closing it and asking")
        local w = self.ReplaceConsumableUI
        local closed = false
        if Valid(w) then closed = pcall(function() w:Cancel() end) end
        if not closed and Valid(w) then closed = pcall(function() w:ForceClose() end) end
        if closed then
            WaitForGameUnpaused(w, 25, function()
                if Valid(self) and PendingOffer[addr] then AskInstantUse(self, PendingOffer[addr]) end
            end)
        else
            PendingOffer[addr] = nil
            RestorePickupActor(self)
        end
    end
end

------------------------------------------------------------------------------
-- Feature 3: consumable replace -> drop the discarded stack (diff done in HandlePickupSuccess)
------------------------------------------------------------------------------
local function FinishConsumableReplace(snap, newId, newCount, loc, rot, attempt)
    local inv = GetInventory()
    if not inv then Dbg("Consumable replace: no inventory"); return end
    local names = NamesToTable(inv.AllConsumableIDs)
    local nowList = SnapshotConsumables(inv.Consumables)
    Dbg("Consumable replace (attempt %d): before [%s] after [%s]", attempt, DescribeConsumables(snap.list, names), DescribeConsumables(nowList, names))
    local before, after = {}, {}
    for _, c in ipairs(snap.list) do before[c.IDIndex] = (before[c.IDIndex] or 0) + c.Quantity end
    for _, c in ipairs(nowList) do after[c.IDIndex] = (after[c.IDIndex] or 0) + c.Quantity end
    -- what the inventory should have gained from the pickup itself (same kind as a discarded stack or not)
    local gained = {}
    if newId then
        for i, n in ipairs(names) do if n == newId then gained[i - 1] = newCount or 1 end end
    end
    local function lostOf(idIndex) return (before[idIndex] or 0) + (gained[idIndex] or 0) - (after[idIndex] or 0) end
    local anyRemoved = false
    for idIndex, _ in pairs(before) do
        if lostOf(idIndex) > 0 then anyRemoved = true end
    end
    if not anyRemoved then
        if attempt < 3 then
            Later(400, function() FinishConsumableReplace(snap, newId, newCount, loc, rot, attempt + 1) end)
        else
            Dbg("Consumable replace: nothing was removed from the inventory, nothing to drop")
        end
        return
    end

    local dropIndex = 0
    for idIndex, _ in pairs(before) do
        local removed = lostOf(idIndex)
        local name = names[idIndex + 1]
        if removed > 0 and name then
            local classPath = string.format(CONSUMABLE_INTERACT_FMT, name, name)
            if Config.SeparateDropsUpTo > 0 then
                local n = math.min(removed, Config.SeparateDropsUpTo)
                for k = 1, n do
                    local l = { X = loc.X + (dropIndex % 3) * Config.DropSpacing,
                                Y = loc.Y + math.floor(dropIndex / 3) * Config.DropSpacing, Z = loc.Z }
                    local a = SpawnInteract(classPath, l, rot)
                    if a and k == n and removed > n then
                        pcall(function() a.PickupClass.ChildActor.Count = removed - n + 1 end)
                    end
                    dropIndex = dropIndex + 1
                end
                Log("Dropped %d x %s as separate pickups", removed, name)
            else
                local l = { X = loc.X + dropIndex * Config.DropSpacing, Y = loc.Y, Z = loc.Z }
                local a = SpawnInteract(classPath, l, rot)
                if a then
                    local ok, err = pcall(function() a.PickupClass.ChildActor.Count = removed end)
                    if not ok then Log("Could not set Count on dropped %s: %s", name, tostring(err)) end
                    Log("Dropped a stack of %d x %s", removed, name)
                end
                dropIndex = dropIndex + 1
            end
        end
    end
end

------------------------------------------------------------------------------
-- HandlePickupSuccess (pre): the moment right after the game changed the inventory
------------------------------------------------------------------------------
local function OnHandlePickupSuccess_Pre(ctx)
    local self = ctx:get()
    local addr = self:GetAddress()
    Dbg("[hook] HandlePickupSuccess (pre) on %s", self:GetFullName())
    local loc, rot = ActorLocRot(self)

    local wsnap = WeaponSnapshot[addr]
    WeaponSnapshot[addr] = nil
    if wsnap and Fresh(wsnap) and Config.DropReplacedWeapon then
        FinishWeaponReplace(wsnap, loc, rot, 1)
    end

    local csnap = ConsumableSnapshot[addr]
    ConsumableSnapshot[addr] = nil
    if csnap and Fresh(csnap) and Config.DropReplacedConsumables then
        local _, newId, newCount = GetPickupConsumable(self)
        FinishConsumableReplace(csnap, newId, newCount, loc, rot, 1)
    end

    RestoreDroppedWeaponDurability(self)
    PendingOffer[addr] = nil
end

-- Replace dialogs closed: drop stale snapshots when the player cancelled.
local function OnReplaceWeaponUIEnd_Pre(ctx, IsSuccess, IsEquippedWeapon, ID)
    local success = Try(function() return IsSuccess:get() end)
    Dbg("[hook] OnReplaceWeaponUIEnd (pre) IsSuccess=%s", tostring(success))
    if success == false then WeaponSnapshot[ctx:get():GetAddress()] = nil end
end
local function OnReplaceConsumableUIEnd_Pre(ctx, IsSuccess, ID)
    local success = Try(function() return IsSuccess:get() end)
    Dbg("[hook] OnReplaceConsumableUIEnd (pre) IsSuccess=%s", tostring(success))
    if success == false then ConsumableSnapshot[ctx:get():GetAddress()] = nil end
    Later(2500, function() EnsureGameUnpaused("after replace dialog") end)
end

------------------------------------------------------------------------------
-- Hook registration (the Blueprint class must be loaded before hooks can be registered)
------------------------------------------------------------------------------
local HooksRegistered = false
local function RegisterHooks()
    if HooksRegistered then return true end
    local cls = StaticFindObject(PICKUP_BP_CLASS)
    if not Valid(cls) then return false end
    local function Hook(fn, pre)
        local ok, err = pcall(function() RegisterHook(PICKUP_BP_CLASS .. ":" .. fn, pre, nop) end)
        if not ok then Log("Failed to hook %s: %s", fn, tostring(err)) end
        return ok
    end
    local all = true
    all = Hook("ShowReplaceWeapon",           OnShowReplaceWeapon_Pre) and all
    all = Hook("NeedShowReplaceConsumableUI", OnNeedShowReplaceConsumableUI) and all
    all = Hook("ShowReplaceConsumableUI",     OnShowReplaceConsumableUI) and all
    all = Hook("HandlePickupSuccess",         OnHandlePickupSuccess_Pre) and all
    all = Hook("OnReplaceWeaponUIEnd",     OnReplaceWeaponUIEnd_Pre) and all
    all = Hook("OnReplaceConsumableUIEnd", OnReplaceConsumableUIEnd_Pre) and all
    HooksRegistered = true
    Log("Hooks registered on BP_Interact_Pickup_C%s", all and "" or " (some failed, see above)")
    return true
end

NotifyOnNewObject(PICKUP_BP_CLASS, function(obj)
    if not HooksRegistered then ExecuteInGameThread(function() RegisterHooks() end) end
end)
RegisterLoadMapPostHook(function()
    if HooksRegistered then return end
    local tries = 0
    LoopAsync(2000, function()
        tries = tries + 1
        ExecuteInGameThread(function() RegisterHooks() end)
        return HooksRegistered or tries > 60
    end)
end)
RegisterHooks()

RegisterKeyBind(Key.F8, {}, function()
    ExecuteInGameThread(function()
        if not Config.FixConsumableSlotCount then Log("F8: FixConsumableSlotCount is not set"); return end
        local inv = GetInventory()
        if not inv then Log("F8: no inventory"); return end
        local before = Try(function() return inv:GetConsumableSlotNum() end, -1)
        local used = #SnapshotConsumables(inv.Consumables)
        if used > Config.FixConsumableSlotCount then
            Log("F8: %d slots are in use, cannot set the slot count to %d", used, Config.FixConsumableSlotCount)
            return
        end
        pcall(function() inv:SetConsumableSlotNum(Config.FixConsumableSlotCount) end)
        local after = Try(function() return inv:GetConsumableSlotNum() end, -1)
        Log("F8: consumable slot count %d -> %d", before, after)
    end)
end)

Log("loaded (DropReplacedWeapon=%s, DropReplacedConsumables=%s, InstantUse=%s, ConfirmInstantUse=%s, SeparateDropsUpTo=%d)",
    tostring(Config.DropReplacedWeapon), tostring(Config.DropReplacedConsumables), Config.InstantUse,
    tostring(Config.ConfirmInstantUse), Config.SeparateDropsUpTo)
