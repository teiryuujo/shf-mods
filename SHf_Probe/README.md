# SHf_Probe

Read-only reconnaissance mod for SILENT HILL f (UE4SS 3.x). It hooks a declared list of
game functions, logs every call with arguments, and runs a few one-shot experiments on a
key press. It never changes game state.

## Install

1. Copy the `SHf_Probe` folder into `SHf\Binaries\Win64\ue4ss\Mods\`.
2. Add `SHf_Probe : 1` to `Mods\mods.txt`.
3. For clean observations disable mods that alter the pickup flow (`SHf_SmartPickup : 0`).

Output goes to the UE4SS console and to `Mods\SHf_Probe\probe.log` (appended per session).

## Keys

| Key | Action |
|-----|--------|
| F9  | run all experiments (soft class paths, max durability sources, weapon accessors, effect classes, consumable order, input actions, abilities, snapshot) |
| F10 | inventory snapshot + list of hooks still pending |
| F7  | capacity experiment: one extra consumable slot, add a unit, roll back in the same tick (F11 is taken by the game's fullscreen toggle) |
| F12 | select the first carried quick slot and run the game's use ability (`TryToUseConsumableItem` + `GA_UseShortcutItem`) |

## Scenarios to record

Run each one, then send `probe.log`.

1. Pick up a weapon with a free weapon slot.
2. Pick up a weapon with full weapon slots and replace one (once the equipped one, once another).
3. Pick up a consumable with a full consumable inventory and replace a stack.
4. Use a repair kit and a health item from the inventory.
5. Press F9 once in a loaded level, F10 at any time.

## Reading the log

```
[SHf_Probe] #00042   12.345s PRE  [pickup] /Script/GameNoce.NocePickupBase:OnPickup | self=UObject<...> | InActor=UObject<...>
[SHf_Probe] #00043   12.345s        inv: useFog=true fog[0:Axe(80.0)* 1:Pipe(50.0)] dark[] cons[MedKitA=2] slots=6
```

* `#n` is a global sequence number, the timestamp is seconds since the mod loaded.
* `PRE` / `POST` is which callback UE4SS fired. If only `PRE` lines appear for a function, the
  runtime does not fire post callbacks for it; compare the inventory lines before and after
  to tell whether `PRE` ran before or after the body.
* `ReturnValue?` marks a trailing parameter that has no declared name (usually the return value).
* A function that never shows up either was not called or is called from C++ without going
  through `ProcessEvent`; `F10` tells whether its hook was registered at all.

## Extending

* Add a function to hook: one table in `Scripts/probe/targets.lua`.
* Add an experiment: one function in `Scripts/probe/experiments.lua` and a line in `runAll`.
* The modules under `Scripts/probe/` have no game-specific state except `targets.lua` and the
  inventory helpers in `inspect.lua`; they can be reused for another UE4SS project as they are.
