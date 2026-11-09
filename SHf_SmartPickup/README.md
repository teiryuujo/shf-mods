# SHf_SmartPickup

UE4SS Lua mod for SILENT HILL f. It makes picking things up with a full inventory less wasteful.
Rewrite of the first SmartPickup (kept as `SHf_SmartPickup_Legacy` in the repository) on measured game behaviour (see `../SHf_Probe/FINDINGS.md`).

## What it does

1. **Weapon replace keeps the old weapon.** When the weapon slots are full and you replace a weapon,
   the discarded one is dropped on the ground where the new one was, instead of being destroyed.
2. **A dropped weapon keeps its durability.** Picking it up again restores the durability it had.
3. **Consumable replace keeps the old stack.** When you replace a stack in a full inventory, the
   discarded stack is dropped where the new item was, as one pickup with the whole stack.
4. **Use it on the spot.** When the inventory is full and the item on the ground is useful right now
   (health, sanity or stamina below maximum, a buff not active, a damaged weapon for the repair kit),
   the game's own Yes/No pop-up asks "Inventory is full. Use <item> right now?".
   * **Yes**: the game uses one with its usual animation, the inventory stays as it was. If you carry
     the same item, one from the inventory is used and the new one is picked up; if you do not, the
     one from the ground is used.
   * **No** (or the back button): the usual replace dialog.
   * Being hit or dodging during the animation cancels the use as in the base game: nothing is spent,
     the item stays on the ground.
   * Items that would do nothing right now, stacks of two or more and offerings go straight to the
     replace dialog.

The question is in the game's language (Russian, English and nine more).

## Requirements and install

* UE4SS 3.0.1 (tested with `v3.0.1 Beta #0`, git `83330635`) with the SILENT HILL f game config
  (`MemberVariableLayout.ini` and `UE4SS-settings.ini` from `zCustomGameConfigs.zip`); without it
  UE4SS crashes on this game.
* Copy the `SHf_SmartPickup` folder into `SHf\Binaries\Win64\ue4ss\Mods\` and add the line
  `SHf_SmartPickup : 1` to `Mods\mods.txt`.
* If a test build is installed as `SHf_SmartPickup2`, delete that folder and its line in `mods.txt`:
  it is an earlier version of this mod and must not run next to it.

To remove it, delete the folder and its line in `mods.txt`. Saves made with the mod load without it:
the mod never changes the number of consumable slots or anything else that is saved.

## Configuration

`Scripts/main.lua`, table `Config`:

| key | default | meaning |
|-----|---------|---------|
| `Debug` | `true` | detailed log lines in the UE4SS console / `UE4SS.log`; useful for bug reports |
| `DropReplacedWeapon` | `true` | feature 1 |
| `RestoreDroppedDurability` | `true` | feature 2 |
| `DropReplacedConsumables` | `true` | feature 3: one pickup per discarded stack |
| `DropSpacing` | `25.0` | cm between pickups when stacks of several types are dropped at once |
| `InstantUse` | `"useful"` | feature 4: `"off"`, `"useful"` (the game's own check via `CanUseConsumableType`; items without such a check, FoodA/FoodC, are judged by their effect classes: attribute below max or buff not active), `"always"` (effect items skip the check; the repair kit keeps it) |
| `ConfirmInstantUse` | `true` | ask with the game's Yes/No pop-up; `false` uses the item silently |
| `UseGameAnimation` | `true` | the game uses the item with its animation (the `GA_UseShortcutItem` ability; the item is selected with `TryToUseConsumableItem` when it sits in a quick slot, otherwise by writing `LastUseConsumableID`); `false` applies the effect directly |

## Known limitations

* **Dropped items do not last.** They are spawned by the mod and are not part of the save: they are gone
  after loading a save, and the game also removes them at an autosave (observed on a zone transition).
  The base game destroys them at once, so nothing is lost compared to playing without the mod.
* **A dropped weapon lies differently** from how the original pickup lay (same place and rotation, but
  the mesh pose differs).
* After Ctrl+R, weapons dropped before it come back at full durability when picked up: the mod's record
  of them is gone, as after loading a save.
* **Restarting mods during the use animation** (UE4SS hot reload, Ctrl+R, on by default in UE4SS):
  for an item you did not carry, one type of stack is out of the inventory for the ~2 s of the
  animation, and the mod state that would put it back is gone, so those items are missing afterwards.
  **Load your last save without saving first**: the save on disk still has them. Saving before that
  writes the inventory without them for good (seen in testing: two med kits lost this way). Not an
  issue in normal play, only when pressing Ctrl+R in the middle of a use.
* Weapons the game does not let you discard (Katana, Naginata, Lantern, Kaiken, ToySaber) never open
  the replace dialog, so the mod does not touch them.

## Testing and compatibility

Tested in game on one save, in short sessions aimed at each
feature, setting and edge case: replace dialogs, the use on the spot with and without the animation,
interruptions, pausing, saving and loading during the use, an autosave on a zone transition, Russian and
English. The test plan with every result is kept in the repository (`TESTPLAN.md`, in Russian).
**Not tested: a long ordinary playthrough.** If something goes wrong in normal play, the log lines
prefixed `[SHf_SmartPickup]` (in `UE4SS.log`) show what the mod did.

Other mods: the mod reads slot counts, stack sizes and durability maxima from the game, nothing is
hard-coded, so mods that change those values (bigger stacks, more inventory slots, higher weapon
durability, infinite stamina) should not conflict; with a big enough inventory this mod simply has little
to do. Not tested together with any of them. Mods that change the pickup or replace dialogs themselves
may conflict.

## How the use on the spot works

For an item you carry, the mod selects it (quick slot or `LastUseConsumableID`) and starts the game's
use ability; the game plays the animation, applies the effect and removes one unit, then the mod picks
the new one up. While the animation runs, the pickup is hidden the way the game hides pickups
(`HideMe` / `ShowMe` in `BP_Interact_Pickup`) and other pickups are left to the game.

For an item you do not carry, the use ability needs it in the inventory, which is full. The mod takes
all stacks of one type out for the animation (a type outside the quick slots if possible, the smallest
total), adds the unit, lets the game use it and puts the stacks back (`Scripts/game/slot_guard.lua`).
The slot count, which is part of the save game, is never changed. The put-back compares totals, so a
save loaded during the animation does not duplicate anything; should a stack not fit back, it is dropped
on the ground. Consumable pickups are ignored while a stack is out.

The wait for the animation counts game time, so a pause or a menu during it changes nothing. If the game
refuses to start the ability (another use still running), the effect is applied directly and the log
says so with a WARN.

Every save to disk is logged (`game save: NoceAsyncSaveGameToSlot`, manual and autosave alike). A save
that happens while a stack is out gives a WARN `game save (...) while N x <item> is out of the
inventory`: that save lacks the stack. It needs the save to land in the ~2 s of the animation and was
never observed.

Log lines are prefixed with `[SHf_SmartPickup]`; WARN lines are worth reporting.

## Layout

```
Scripts/main.lua                    configuration, wiring
Scripts/core/log.lua                logger
Scripts/core/util.lua               try / valid / array helpers / actor helpers
Scripts/core/hooks.lua              one RegisterHook per function, many handlers, retry until the class loads
Scripts/game/const.lua              object paths, the save functions that are watched
Scripts/game/inventory.lua          inventory access, weapon slot snapshots and diffs
Scripts/game/consumables.lua        consumable data, usefulness, effects, repair, quick slots, the use ability
Scripts/game/slot_guard.lua         takes a stack out for a use and puts it back; watches game saves
Scripts/game/dialog.lua             the game's Yes/No pop-up
Scripts/game/texts.lua              the question in the game's language
Scripts/game/spawn.lua              class loading, spawning interactables
Scripts/game/drops.lua              registry of pickups spawned by the mod
Scripts/game/pickup_watch.lua       snapshots around every pickup, notifies listeners of the diff
Scripts/features/weapon_replace.lua      feature 1
Scripts/features/durability_restore.lua  feature 2
Scripts/features/consumable_replace.lua  feature 3
Scripts/features/instant_use.lua         feature 4
TESTPLAN.md                         in-game test plan and results (Russian; in the repository, not in the release archive)
```

## Backlog

* Survive a mod restart (Ctrl+R) during case B: write what was taken out to a marker file before the
  take-out, delete it after the put-back; on start, put back what a leftover marker names if the
  inventory lacks it. Today the player has to reload without saving (see Known limitations).
* Find out what removes dropped pickups at an autosave (hook the destruction of a spawned actor and log
  the caller); if it is a cleanup of dynamic actors, the drops may be kept.
* Dropped weapon pose: the game poses the mesh through the relative transform of the `PickupClass`
  child-actor component (`BP_Interact_Pickup_Exchange_Base` applies `OverrideExchangeRelativeTransform`
  with `K2_SetRelativeTransform`). Read that transform from the original interactable at pickup time
  and apply it to the spawned one.
* Instant use of a stack on the ground (x2 and more): currently always the replace dialog. Idea: offer
  to use one unit and pick up the rest (the pickup's `Count` is writable, see `game/drops.lua`).
* Discarding a weapon from the inventory (`NocePlayerInventoryComponent:DiscardWeapon`, hookable with
  real pre/post) destroys it. Drop it at the player's feet instead, through `game/drops.lua`.
