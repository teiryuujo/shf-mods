# SILENT HILL f — UE4SS mods

| folder | what it is |
|--------|------------|
| `SHf_SmartPickup/` | the mod: smarter pickups with a full inventory. README for players, `TESTPLAN.md` with the in-game test results |
| `SHf_Probe/` | reconnaissance mod used to measure the game's behaviour (hooks, inventory snapshots, test spawns); `FINDINGS.md` |
| `SHf_SmartPickup_Legacy/` | the first SmartPickup, kept for history; not installed |
| `tests/` | `smoke_smartpickup.lua`, a test of SHf_SmartPickup under plain Lua 5.4 (run from `SHf_SmartPickup/Scripts`: `../../../tools/lua/lua54.exe ../../tests/smoke_smartpickup.lua`) |

A mod is installed by copying its folder into `SHf\Binaries\Win64\ue4ss\Mods\` and adding `<folder> : 1` to `mods.txt`.
