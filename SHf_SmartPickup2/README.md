# SHf_SmartPickup2

UE4SS Lua mod for SILENT HILL f. Rewrite of SHf_SmartPickup on measured game behaviour
(see `../SHf_Probe/FINDINGS.md`), built up one feature at a time.

| # | Feature | Status |
|---|---------|--------|
| 1 | Weapon replace: the discarded weapon is dropped where the new one was, durability kept | implemented |
| 2 | A dropped weapon gets its durability back when picked up again | implemented |
| 3 | Consumable replace: the discarded stack is dropped where the new one was | implemented |
| 4 | Consumable pickup with a full inventory: offer to use it on the spot | implemented |

## Install

Copy the folder into `SHf\Binaries\Win64\ue4ss\Mods\`, add `SHf_SmartPickup2 : 1` to `mods.txt`.
Do not run it together with the old `SHf_SmartPickup`.

## Configuration

`Scripts/main.lua`, table `Config`:

| key | default | meaning |
|-----|---------|---------|
| `Debug` | `true` | verbose log lines in the UE4SS console / UE4SS.log |
| `DropReplacedWeapon` | `true` | feature 1 |
| `RestoreDroppedDurability` | `true` | feature 2 |
| `DropReplacedConsumables` | `true` | feature 3: one pickup per discarded stack |
| `DropSpacing` | `25.0` | cm between pickups when stacks of several types are dropped at once |
| `InstantUse` | `"useful"` | feature 4: `"off"`, `"useful"` (the game's own check via `CanUseConsumableType`; items without such a check, FoodA/FoodC, are judged by their effect classes: attribute below max or buff not active), `"always"` (effect items skip the check) |
| `ConfirmInstantUse` | `true` | ask with the game's Yes/No pop-up; `false` uses the item silently |
| `UseGameAnimation` | `true` | the game uses the item with its animation (the `GA_UseShortcutItem` ability; the item is selected with `TryToUseConsumableItem` when it sits in a quick slot, otherwise by writing `LastUseConsumableID`); `false` applies the effect directly |

## Layout

```
Scripts/main.lua               configuration, wiring
Scripts/core/log.lua           logger
Scripts/core/util.lua          Try / Valid / array helpers / actor helpers
Scripts/core/hooks.lua         one RegisterHook per function, many handlers, retry until the class loads
Scripts/game/const.lua         object paths
Scripts/game/inventory.lua     inventory access, weapon slot snapshots and diffs
Scripts/game/spawn.lua         class loading, spawning interactables
Scripts/game/drops.lua         registry of pickups spawned by the mod
Scripts/game/pickup_watch.lua  snapshots the weapon slots around every pickup, notifies listeners of the diff
Scripts/features/*.lua         one module per feature, `install(config)`
```

Log lines are prefixed with `[SHf_SmartPickup2]`.

## Backlog

* Dropped pickups reuse the location and rotation of the interactable they replace, yet the mesh lies
  differently (confirmed in game). Lead: the game itself poses the mesh through the relative transform
  of the `PickupClass` child-actor component (`BP_Interact_Pickup_Exchange_Base` applies
  `OverrideExchangeRelativeTransform` with `K2_SetRelativeTransform` on it). Read that transform from
  the original interactable at pickup time and apply it to the spawned one.
* Instant use of a stack on the ground (x2 and more, e.g. a stack this mod dropped): currently always
  the replace dialog. Ideas: show how many units the pickup holds; offer to use one unit and pick up
  the rest (the pickup's `Count` is writable, see `game/drops.lua`).
* Feature 5 idea: discarding a weapon from the inventory (`NocePlayerInventoryComponent:DiscardWeapon`,
  called by the inventory UI, hookable with real pre/post) currently destroys it. Drop it at the
  player's feet instead, with its durability, through the same `game/drops.lua` registry.
* Items without a quick slot (Capsule, DrinkC, FoodB, FoodC with the default layout) get the
  animation by writing `LastUseConsumableID` directly (`Consumables.useById`): the use ability reads
  only that field. If the write does not take, the log says so and the effect is applied directly as
  before. `EquipConsumable(ID, slot)` / `UnequipConsumable(slot)` remain the fallback plan.

## Pickup during the animation

While the game's use animation runs the pickup is hidden the way the game itself hides pickups
(`HideMe` / `ShowMe` in `BP_Interact_Pickup`): trigger box off, actor hidden, hint areas off. It is
shown again on every exit that leaves it on the ground (use interrupted, the new one does not fit).

## Borrowed consumable slot

For an item that is not carried, the animated use needs it in the inventory, which is full. The mod
raises the consumable slot count by one, adds the unit, lets the game use it and puts the count back
once the game's `UseConsumable` has fired (`Scripts/game/slot_guard.lua`). While a slot is borrowed
the original count is stored in `slotcount.pending` next to this file. If that file still exists when
the mod starts, something was interrupted: the log says so and **F8** in game restores the count.

`SetConsumableSlotNum(n)` truncates the stack array to `n` entries. After the game's own
`UseConsumable` the emptied entry is sorted to the end and the truncation drops just that; after
`RemoveConsumable` from Lua (an interrupted use) the emptied entry stays in place and the last real
stack is dropped instead (measured 2026-10-28 11:05). The guard keeps the totals from before the
borrow and adds back whatever is missing after the shrink, logging `slot guard: the shrink dropped
N x <item> ..., added back`. The raw stack lists around the shrink are in the debug log.
