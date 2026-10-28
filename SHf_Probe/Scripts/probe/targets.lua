--[[
    probe.targets  —  the list of functions to hook. Data only; see probe/hooks.lua for the fields.

    Paths come from the reflection dump (_modding/ObjectDump.txt, _modding/sdk_inventory.txt).
    Groups:
      pickup  the pickup flow: native NocePickupBase:OnPickup and the Blueprint wrappers around it
      inv     inventory mutations on NocePlayerInventoryComponent (native)
      ui      the pop-up and replace windows (filtered by class name, the base class is shared by all UI)
      pause   GameplayStatics:SetGamePaused
--]]
local Inspect = require("probe.inspect")

local PICKUP_BP = "/Game/Blueprint/InteractUnit/BP_Interact_Pickup.BP_Interact_Pickup_C"
local INV       = "/Script/GameNoce.NocePlayerInventoryComponent"
local UI_ONLY   = { "PopWindow", "ReplaceWeapon", "ReplaceItem" }

local inventory = Inspect.inventoryState

return {
    -- pickup flow -----------------------------------------------------------
    { tag = "pickup", fn = "/Script/GameNoce.NocePickupBase:OnPickup", params = { "InActor" }, extra = inventory },
    { tag = "pickup", fn = PICKUP_BP .. ":ExecuteInstantFeedback" },
    { tag = "pickup", fn = PICKUP_BP .. ":HandleOnPickup" },
    { tag = "pickup", fn = PICKUP_BP .. ":HandlePickupSuccess", extra = inventory },
    { tag = "pickup", fn = PICKUP_BP .. ":HandlePickupFail" },
    { tag = "pickup", fn = PICKUP_BP .. ":NeedShowReplaceWeaponUI",     params = { "OutValue" } },
    { tag = "pickup", fn = PICKUP_BP .. ":NeedShowReplaceConsumableUI", params = { "OutValue" } },
    { tag = "pickup", fn = PICKUP_BP .. ":ShowReplaceWeapon",       extra = inventory },
    { tag = "pickup", fn = PICKUP_BP .. ":ShowReplaceConsumableUI", extra = inventory },
    { tag = "pickup", fn = PICKUP_BP .. ":OnReplaceWeaponUIEnd",     params = { "IsSuccess", "IsEquippedWeapon", "ID" }, extra = inventory },
    { tag = "pickup", fn = PICKUP_BP .. ":OnReplaceConsumableUIEnd", params = { "IsSuccess", "ID" },                     extra = inventory },

    -- inventory mutations (do these fire when the game calls them from C++?) ---
    { tag = "inv", fn = INV .. ":AddWeapon",                   params = { "ID", "Durability" } },
    { tag = "inv", fn = INV .. ":ExchangeWeapon",              params = { "Index", "ID", "Durability" } },
    { tag = "inv", fn = INV .. ":DiscardWeapon",               params = { "Index" } },
    { tag = "inv", fn = INV .. ":SetWeaponDurability",         params = { "Index", "IsFogWeapon", "Durability" } },
    { tag = "inv", fn = INV .. ":SetEquippedWeaponDurability", params = { "ID", "Durability" } },
    { tag = "inv", fn = INV .. ":AddConsumable",               params = { "ID", "Quantity", "ConsumableActorName" } },
    { tag = "inv", fn = INV .. ":RemoveConsumable",            params = { "ID", "Quantity", "RemovedDueSold" } },
    { tag = "inv", fn = INV .. ":UseConsumable",               params = { "ID" } },
    { tag = "inv", fn = INV .. ":CanAddConsumable",            params = { "ID", "Quantity" } },
    { tag = "inv", fn = INV .. ":IsWeaponFull" },

    -- UI ------------------------------------------------------------------------
    { tag = "ui", fn = "/Script/GameNoce.NoceAnimWidget:Show",               only = UI_ONLY },
    { tag = "ui", fn = "/Script/GameNoce.NoceAnimWidget:Hide",               only = UI_ONLY },
    { tag = "ui", fn = "/Script/GameNoce.NoceAnimWidget:ForceClose",         only = UI_ONLY },
    { tag = "ui", fn = "/Script/GameNoce.NoceAnimWidget:OnFadeInCompleted",  only = UI_ONLY },
    { tag = "ui", fn = "/Script/GameNoce.NoceAnimWidget:OnFadeOutCompleted", only = UI_ONLY },
    { tag = "ui", fn = "/Script/GameNoce.NoceFocusableWidget:Confirm",       only = UI_ONLY },
    { tag = "ui", fn = "/Script/GameNoce.NoceFocusableWidget:Cancel",        only = UI_ONLY },
    { tag = "ui", fn = "/Script/GameNoce.NocePopWindowWidget:OnListMouseConfirm" },
    { tag = "ui", fn = "/Script/GameNoce.NocePopWindowWidget:SetType", params = { "InType" } },

    -- using an item from the inventory (where does the "no effect right now" check live?) ---
    { tag = "use", fn = INV .. ":TryToUseConsumableItem",              params = { "Index" }, extra = Inspect.consumableUiState },
    { tag = "use", fn = INV .. ":SetLastSelectConsumableIndex",        params = { "Index" } },
    { tag = "use", fn = "/Script/GameNoce.NocePlayerState:CanUseConsumableType", params = { "Mask" } },
    -- does the player state apply the effect when an item is used (delegate handler)? where in the flow?
    { tag = "use", fn = "/Script/GameNoce.NocePlayerState:OnUseConsumableItem",  params = { "ID" } },
    -- the quick-slot widget: DirectUse is a Blueprint-implemented event on NoceShortcutItemWidget.
    -- Is it the entry point of the real quick-slot use, and what state does it set?
    { tag = "use", fn = "/Script/GameNoce.NoceShortcutItemWidget:DirectUse",                         extra = Inspect.useState },
    { tag = "use", fn = "/Game/UI/Shortcut/WBP_ItemShortcut_PC.WBP_ItemShortcut_PC_C:DirectUse",    extra = Inspect.useState },
    { tag = "use", fn = "/Game/UI/Shortcut/WBP_ItemShortcut.WBP_ItemShortcut_C:DirectUse",          extra = Inspect.useState },
    -- NoceUISubsystem:AddWidget / RemoveWidget were hooked once (2026-10-27) to find the quick-slot UI:
    -- they never fired for it, and describing the widget parameter of RemoveWidget right after an
    -- inventory DiscardWeapon coincided with an access violation inside UE4SS (2026-10-28 00:35).
    -- Do not hook functions whose object parameter may already be dying.
    { tag = "use", fn = "/Script/GameNoce.NoceItemShortcutItemWidget:SelectMark" },
    { tag = "use", fn = "/Script/GameNoce.NoceItemShortcutItemWidget:SetItem", params = { "InID", "InCount", "InIsDisable" } },

    -- pause (SetGamePaused never fired in session 1; APlayerController::SetPause is not reflected,
    -- so the C++ pause path cannot be hooked. These two are the only reflected entry points.) ---
    { tag = "pause", fn = "/Script/Engine.GameplayStatics:SetGamePaused", params = { "WorldContextObject", "bPaused" } },
    { tag = "pause", fn = "/Script/Engine.PlayerController:Pause" },
}
