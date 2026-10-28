--[[
    game.const  —  object paths of SILENT HILL f (build 1.3.x), verified against the reflection dump.
--]]
return {
    -- the interactable that hosts every weapon / consumable pickup in the game
    PICKUP_BP               = "/Game/Blueprint/InteractUnit/BP_Interact_Pickup.BP_Interact_Pickup_C",
    -- pickup classes spawned by this mod; %s = weapon / consumable row name (twice)
    WEAPON_INTERACT_FMT     = "/Game/Blueprint/InteractUnit/Pickup/Weapon/BP_Interact_Pickup_Wep_%s.BP_Interact_Pickup_Wep_%s_C",
    CONSUMABLE_INTERACT_FMT = "/Game/Blueprint/InteractUnit/Pickup/Consumable/BP_Interact_Pickup_Con_%s.BP_Interact_Pickup_Con_%s_C",

    -- native entry point of a pickup: real pre/post hooks, inventory changes inside
    PICKUP_ON_PICKUP        = "/Script/GameNoce.NocePickupBase:OnPickup",
    -- the player's inventory component (its functions hook only when Blueprint / UI calls them)
    INVENTORY_COMPONENT     = "/Script/GameNoce.NocePlayerInventoryComponent",
    -- the ability that plays the item-use animation and calls UseConsumable on its notify
    USE_ABILITY_BP          = "/Game/Character/Player/Base/GameplayAbility/Ability/GA_UseShortcutItem.GA_UseShortcutItem_C",

    -- function libraries (class default objects)
    INVENTORY_FUNCLIB       = "/Script/GameNoce.Default__NoceInventoryFunctionLibrary",
    NOCE_FUNCLIB            = "/Script/GameNoce.Default__NoceFunctionLibrary",
    WIDGET_BP_FUNCLIB       = "/Script/UMG.Default__WidgetBlueprintLibrary",
    I18N_FUNCLIB            = "/Script/Engine.Default__KismetInternationalizationLibrary",

    -- the game's own Yes/No pop-up and the widget events it goes through (all measured to fire)
    POPWINDOW_CLASS         = "/Game/UI/PopWindow/WBP_PopWindow.WBP_PopWindow_C",
    POPWINDOW_TYPE_ENUM     = "/Script/GameNoce.ENoceUIPopWindowType",
    WIDGET_CONFIRM_FN       = "/Script/GameNoce.NoceFocusableWidget:Confirm",
    WIDGET_CANCEL_FN        = "/Script/GameNoce.NoceFocusableWidget:Cancel",
    WIDGET_FADE_IN_FN       = "/Script/GameNoce.NoceAnimWidget:OnFadeInCompleted",
    WIDGET_FADE_OUT_FN      = "/Script/GameNoce.NoceAnimWidget:OnFadeOutCompleted",

    -- an empty weapon slot
    EMPTY_SLOT              = -1,
}
