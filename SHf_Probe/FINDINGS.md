# Probe findings (SILENT HILL f, build 1.3.x, UE 5.4.2, UE4SS 3.0.1) — 2026-10-27

Everything below was measured in-game with SHf_Probe (see `probe.log`), not inferred.

## UE4SS hook semantics in this game

| Function kind | PRE callback | POST callback | Notes |
|---|---|---|---|
| Native UFunction called from Blueprint (`NocePickupBase:OnPickup`, `IsWeaponFull`, `UseConsumable`, widget events) | before the body | after the body | true pre/post |
| Blueprint function (`BP_Interact_Pickup_C:*`) | **after** the body | never | out-params readable and settable |
| Native function called from C++ (`AddWeapon`, `ExchangeWeapon`, `RemoveConsumable`, `AddConsumable`, `NoceAnimWidget:Show/Hide`, pause) | never | never | bypasses ProcessEvent |

* POST callbacks receive the **return value first**, then the parameters.
* Hooks on `BP_Interact_Pickup_C` register at mod start (class is loaded in the main menu).
* Out-params when *calling* a UFunction from Lua: pass an empty table per out-param, the value lands in it
  under the parameter's name: `inv:GetWeaponIndex(FName("Axe"), outIdx, outFog)` → `outIdx.OutIndex`, `outFog.OutIsFogWeapon`.
* A struct returned by value (`GetConsumableData`) and some `TArray` return values (`GetConsumableRowNames`)
  arrive as plain Lua tables; table elements are `RemoteUnrealParam` wrappers (`:get()` to unwrap).

## Pickup flow (plain pickup, free slot)

```
NeedShowReplaceWeaponUI (BP, OutValue=false)
NeedShowReplaceConsumableUI (BP, OutValue=false)      ← CanAddConsumable(ID, Qty) hook fires here
NocePickupBase:OnPickup PRE                           ← inventory unchanged
NocePickupBase:OnPickup POST (ReturnValue=true)       ← inventory changed
HandlePickupSuccess (BP)
HandleOnPickup (BP)
ExecuteInstantFeedback (BP)
```

## Replace flow (weapon or consumable, inventory full)

```
IsWeaponFull / CanAddConsumable
NeedShowReplace*UI (BP, OutValue=true)
ShowReplaceWeapon | ShowReplaceConsumableUI (BP)      ← inventory unchanged: take the snapshot here
ExecuteInstantFeedback (BP)
NoceAnimWidget:OnFadeInCompleted  (WBP_ReplaceWeapon_C | WBP_ReplaceItem_C)
NoceFocusableWidget:Confirm       (replace widget)     ← player chose a slot
NoceAnimWidget:OnFadeInCompleted  (WBP_PopWindow_C)    ← "really replace?" confirmation
NoceFocusableWidget:Confirm PRE   (WBP_PopWindow_C)
  HandlePickupSuccess (BP)                             ← inventory ALREADY changed, synchronously
  OnReplaceWeaponUIEnd(IsSuccess, IsEquippedWeapon, ID=NEW item) | OnReplaceConsumableUIEnd(IsSuccess, ID=NEW item)
NoceFocusableWidget:Confirm POST
~190 ms later: NoceAnimWidget:OnFadeOutCompleted for WBP_PopWindow_C, then for the replace widget
```

No retries are needed: the diff can be done in `HandlePickupSuccess`.

## Inventory data model

* **Weapons are slot-based**: `FogWeapons` has 4 slots, `DarkWeapons` 3; an empty slot is `IDIndex = -1`.
  Replace writes into the same slot; a plain pickup fills a `-1` slot. Positions never shift.
  → the changed slot identifies the item exactly, even with duplicates.
* **Consumables are NOT positional**: `Consumables` is one entry per stack, the array is re-sorted on
  every change (by ID order, partial stacks first). → diff per ID by total quantity:
  `lost(ID) = before(ID) + gained(ID) - after(ID)`, verified on 4 replacements including same-type.
* `GetWeaponDurability(Index, IsFog)` and `GetEquippedWeaponIndex()` work from Lua.
* `GetWeaponIndex(ID)` → slot and list of the (first) weapon with that ID, `-1` if none.
* `GetMaxWeaponNumber()` returned 3 while the fog list has 4 slots (slot 0 may be special); not relied upon.

## Consumable data (`NoceInventoryFunctionLibrary:GetConsumableData(FName)`)

* Returns a Lua table: `ItemAttributeCheckType` (mask), `WeaponDurabilityRecoverRatio`, `GameplayEffects`.
* `GameplayEffects` elements are `SoftClassPath` structs; the class path is
  `e.AssetPath.PackageName:ToString() .. "." .. e.AssetPath.AssetName:ToString()`
  (e.g. `/Game/Blueprint/GameplayAbility/Effect/GE_RecoverHealth_S.GE_RecoverHealth_S_C`).
  `KismetSystemLibrary:BreakSoftClassPath` cannot be called with a struct from Lua.
* Masks per row: MedKitA/B, FoodD, FoodE = 1 · Capsule* = 7 · DrinkA/B = 22 · DrinkC, FoodB = 23 ·
  FoodA, FoodC = 0 (effects but no game-side check) · Faith* = 0 (no effects) · WeaponRecoverA = 8, ratio 0.5.
* `NocePlayerState:CanUseConsumableType(mask)` is the game's own "useful now" check (true when health
  is below max for mask 1, false at full health). The inventory UI calls it, then
  `TryToUseConsumableItem(Index)`, then `UseConsumable(ID)` ~1-2 s later.
* **`TryToUseConsumableItem(Index)`: Index is the quick slot (0-based)**, not a stack index.
  `inv.ShortcutConsumables` is `TArray<int>` with the IDIndex per quick slot (8 slots, -1 = empty);
  slots keep their assignment even when the item is not carried. Verified with 4 uses (slots 2/4/5/7).
  The whole use flow (animation, effect, removal) runs from that one call.
* **`TryToUseConsumableItem(slot)` called from Lua does not perform the use.** It sets
  `GetIsTryingToUseConsumableItem()` to true and raises the delegate, but the character never starts
  the motion (`IsUseShortcutItem`, `DuringUseShortcutItemMotion`, `DuringUpperBodyMotion` stay false)
  and `UseConsumable` never follows; the "trying" flag stays true until the next real use. With the
  real quick-slot input the same call is followed within 2 ms by all three flags turning true and by
  `UseConsumable` ~2 s later. The motion is started natively in the input state the quick-slot UI
  sets (`NocePlayerInputHelperComponent:OnShortcutItemEnableStateTagChanged`); no reflected function
  starts it. `NocePlayerFunctionLibrary:SimulateNoceInputAction(ctx, ENoceInputAction, pressed)`
  is the only reflected way to drive that path.
* The quick-slot panel (middle mouse) is not a UI-subsystem widget: `NoceUISubsystem:AddWidget/RemoveWidget`
  never fire while it is used, `WBP_ItemShortcut*` classes never load, and no instance of
  `NoceShortcutItemWidget` exists (`DirectUse` is unrelated to this flow). The panel is native HUD state.
* `ENoceInputAction`: Dodge 0, LightAttack 1, HeavyAttack 2, Sprint 3, UTurn 4, Pause 5, Interact 6,
  Focus 7, Map 8, CameraReset 9, Notebook 10, **UseItem 11**, Equipment 12, ExtraSprint 13,
  TransformLB/RB/KB 14-16. Slot selection (number keys / mouse) is not an action of this enum.
* `NocePlayerFunctionLibrary:SimulateNoceInputAction(ctx, UseItem, true/false)` from Lua: with a
  120 ms hold (and key repeat) the panel flashed open (`IsShowShortcutItemUI` true for a moment);
  with a clean 600 ms hold nothing changed at all. The release never produced
  `TryToUseConsumableItem` or `UseConsumable`, with `SetLastSelectConsumableIndex` set beforehand.
  The simulated action does not reproduce the held-input state the panel needs. Dead end for Lua.
* **SOLVED — the animated use from Lua.** The quick-slot flow is three Blueprint abilities (granted
  to the player, listed through `AbilitySystemComponent.ActivatableAbilities.Items[*].Ability`):
  `GA_ShowShortcutItemUI` (input 5, the panel), `GA_DirectUseShortcutItem` (input 7, number keys)
  and `GA_UseShortcutItem` (no input). Decompiled (`_modding/json/GA_*.json`, convert with
  `UAssetGUI tojson <uasset> <json> VER_UE5_4 SHf` — the 4th argument is the *registered mappings
  name*, not a path): `GA_DirectUseShortcutItem` binds its `OnTryToUseItem` to the inventory's
  `OnTryToUseConsumableItem` delegate and, when it fires, calls
  `TryActivateAbilityByClass(GA_UseShortcutItem_C)`. `GA_UseShortcutItem` reads
  `GetLastUseConsumableID()`, checks the count and `CanUseItem` (repair kit needs a damaged weapon in
  hand), plays the montage chosen by `ItemMotionType` (anim ids 50-53) and calls `UseConsumable(id)`
  on an animation notify. From Lua: `inv:TryToUseConsumableItem(slot)` (sets LastUseConsumableID) then
  `asc:TryActivateAbilityByClass(GA_UseShortcutItem_C, true)` -> motion flags true at once,
  `UseConsumable(id)` ~1 s later (measured 2026-10-27, probe F12). Never activate
  `GA_ShowShortcutItemUI` from Lua: it opened the panel and UE4SS aborted shortly after.
  `K2_CanActivateAbility` of the direct-use ability refuses on gamepad and on player restriction 8.
* **Capacity**: with 14/14 stacks `AddConsumable` returns true and adds nothing (native check).
  `SetConsumableSlotNum(15)` makes `CanAddConsumable` true and `AddConsumable` adds a 15th stack;
  `RemoveConsumable` + `SetConsumableSlotNum(14)` put everything back (stacks re-sorted, totals
  identical). Measured 2026-10-27, probe F7. The slot count is saved with the game: an old mod version
  once left it raised, hence the marker file + F8 in SHf_SmartPickup2.
* **`UseConsumable(ID)` called from Lua only removes the item**: Health stayed 1050 before and after.
  The effect comes from the use animation / ability. `NocePlayerState:OnUseConsumableItem(ID)` fires
  inside UseConsumable (delegate handler) and does not apply it either.
* Gameplay effect classes are readable through their default object (`Default__GE_X_C`):
  `DurationPolicy` (0 instant, 2 has-duration), `Modifiers[i].Attribute.AttributeName` (FString),
  `ModifierOp`, `Executions`. Health / MaxSanity recovery uses Executions (no modifiers);
  GE_FullStamina overrides `Stamina`, GE_FillSanityToCurrentMaxSanity overrides `Sanity`; the buffs
  (StaminaNoCost, SanityNoCost_*) have a duration and modify `*CostRatio` attributes.
  `AbilitySystemComponent:GetGameplayEffectCount(cls, nil, true)` works from Lua (0 when not active).
  Classes not loaded yet need `LoadAsset(path)` first.
* `GetConsumableRowNames()` returns a Lua table of RemoteUnrealParam (unwrap with `:get()`);
  row `Priority`: MedKitA 0, MedKitB 1, DrinkA 2, DrinkB 3, DrinkC 4, WeaponRecoverA 8, FoodE 10,
  FoodD 11, FoodC 12, FoodA 13, FoodB 14, Faith* 30-32, Capsule* -1.

## Weapon subsystem

* `inv.WeaponSubsystem` is null. `NoceFunctionLibrary:GetWeaponSubSystem(ctx)` and
  `FindFirstOf("NoceWeaponSubsystem")` both return `BP_NoceWeaponSubSystem_C` and agree.
* `GetMaxDurability(GetWeaponQueryName(name))` works for all 15 rows; query name == row name
  except `ToySaber` → `ToySaber_Round2`. Values: Pipe/Bat 450, Dagger 240, Sickle/Axe 360, Katana/
  KatanaAlter/Crowbar 540, Hammer/ToySaber 280, Lantern/Claw/Naginata/Kaiken 1000, Pipe_Crazy 1.

## Crashes inside UE4SS (2 so far)

Both `CrashContext.runtime-xml` call stacks share the same tail: game frames `SHf-Win64-Shipping+3eb0ea4
→ 3ea8c10 → 3ea7dfa → 3ea7d7c → 3ea0794` → `UE4SS+466aba → 45d2ca → 2fd818 → 2fc9d0 → 2fcb79` → Lua VM
(`UE4SS+c6…/c7…`), i.e. a Lua hook callback invoked from one and the same game call path. Crash 1
(2026-10-27 20:18, abort) came ~1 s after GA_ShowShortcutItemUI closed its panel; crash 2 (2026-10-28
00:35:42, access violation reading 0x33 at `UE4SS+3e8542`, object access) came 37 s after an inventory
DiscardWeapon while the player was running towards a mod-dropped pickup, with no hook logged in
between. Working hypothesis: a widget-event hook (`NoceAnimWidget:OnFadeIn/OutCompleted`) fired for a
widget that was already dying, and the callback's `GetFullName()` / `GetAddress()` on it faulted
natively, which `pcall` cannot catch. Hardening applied to both mods: the dispatcher skips any `self`
whose `IsValid()` is false before touching it, and SmartPickup2 limits the fade-out hook to its own
two widget classes.

## UI

* `NoceAnimWidget:OnFadeInCompleted` / `OnFadeOutCompleted` fire (PRE+POST) for `WBP_PopWindow_C`,
  `WBP_ReplaceWeapon_C`, `WBP_ReplaceItem_C`. `Show` / `Hide` / `ForceClose` never fire.
* `NoceFocusableWidget:Confirm` / `Cancel` fire for all of them; `NocePopWindowWidget:OnListMouseConfirm`
  fires on mouse confirmation, with `Confirm` nested inside it.
* Pause: `GameplayStatics:SetGamePaused` never fires; `APlayerController::SetPause` is not reflected.
  The pause path cannot be hooked; `IsGamePaused()` polling remains the only way to observe it.
