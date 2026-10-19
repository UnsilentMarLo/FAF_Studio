# Editor crash when a map is loaded: root causes and fixes (2026-10-18)

User report: "when loading a map the editor crashes". Session `crashfix` (tag `crashfix`, `crashfix2`), driver `scripts/ed_stress_load.py`.

## The crash reports, classified

All `faf_crash_*.txt` of `engine_decomp/run_x64/bin` and `engine_decomp/runs/*/bin` (2026-10-18):

| Report (stamp) | Stack | Class | Verdict |
|---|---|---|---|
| graph 22:06 (exe 19:14 UTC) | `SpatialDB<UserEntity>::~SpatialDB` -> `erase_range` in `WLD_Teardown` (garbage tree head `8000530023D00006`) | heap corruption, teardown of the old session | cause 1 (heap overflow in the height field) |
| run_x64 / fields 17:44 .. 17:49 (3 reports) | `luaH_set` -> `resize` inside `LuaState::Init` (`DISK_SetupDataAndSearchPaths`), session none | three instances died at start within one minute: exes built mid-edit (stale objects against changed Lua headers), not a load problem | not reproduced; rebuild clears it |
| run_x64 11:46 (`..._icon.exe`) | `GetGlobal` null state in `CameraImpl` ctor via `RCamManager::CreateCamera` from `D3DWindowOnDeviceRender` | the icon pass created a camera without a Lua state | already fixed (icon pass borrows `WorldCamera`); `RenderPreviewImage` still passes `nullptr`, no caller (see Open) |
| run_x64 01:01 / 01:04 | `EdRefreshWaterSurfaces` call through a null/unresolved address | old exe with an unresolved `/FORCE` link symbol | gone in later exes |
| sctools 20:52 | `luaV_execute` null in a sim thread resume | Lua-side, one sim thread; not reproduced | open |
| integrate 15:33 / 18:47 | `Failed assertion ... SessionLoader.cpp:320` | the map load task aborted (`kReadyForDestroy`) | a load that fails (missing/corrupt map); not a memory error |

## Root cause 1: heap overflow in `CHeightField::SetElevationRectRaw` (the load crash)

`sim/STIMap.cpp`. The copy loops are inclusive (`x <= x1`, `z <= z1`) over a `width * height` buffer, but the rectangle was clamped to
`height` on **both** axes (recovered code). A rectangle that ends on the last row/column, or on the map edge of a non-square field, writes one
row (about 2 KB at 1025 x 1025) behind the allocation.

The editor produced such rectangles: `EditorDocument.cpp` `ProjectHeights` added 1 to the rect for `NotifyMapChange` without clamping, so every
whole-map commit (import, graph / generate commit, symmetrize, set_rect over the map, erosion finish) queued a dirty rect with `z1 = Height`.
`CWldTerrainRes::SyncTerrain` (every beat, when the camera zoom is below `ren_SyncTerrainLOD` = 200) then copied it into the field with
`SetElevationRectRaw`: the overflow lands in whichever block follows the 2 MB height array: SpatialDB nodes, LuaPlus tables, the Lua allocator,
`RtlAllocateHeap` metadata. That is why the stacks differ and why the crash shows up one or two loads later (the teardown of the old session
frees the damaged blocks).

Fixes:
- `SetElevationRectRaw`: clamp `x1` to `width-1`, `z1` to `height-1`; reject only when `x0 > x1 || z0 > z1` (a one-cell rect was dropped before).
- `ProjectHeights`: clamp the dirty rect to the field.
- Reproduced before the fix: `ed_stress_load.py --mode dirty` died in the second load (`RtlAllocateHeap` access violation, the 19:14 exe).
  After the fix: see the table below.

## Root cause 2: maps that hide the terrain crash on the first frame (`tournament_dome`)

`Tournament_Dome_script.lua` runs `ren_terrain 0` in `OnStart`. In `WRenViewport::Render` the terrain's `UpdateRenderContext` (which binds the
terrain's camera) only ran inside `if (ren_Terrain && terrain)`, while the water passes (`DrawWaterLine`, `DrawWaterTerrain`) run for any terrain
and read `mCamera->view`. In the stock game the first frames render before `OnStart`, so the camera is bound already; in the editor the first
frame already has the terrain off: `&mCamera->view` = null + 0x5C went into d3dx9 `SetMatrix` (AV target 0x5C). Deterministic: opening that map,
or starting on it, died every time.

Fixes: `Render` also calls `UpdateRenderContext` when the terrain is off and water is on; `HighFidelityTerrain::DrawWaterLine` /
`DrawWaterTerrain` skip when no camera is bound (and log `[WATERDIAG]` once).

## Cause 3: a scenario whose `.scmap` is missing (1 of the 414 maps)

`setons_mini_clutch_aix`: the scenario names `setons_mini_clutch_aix.scmap`, the folder has no such file. The engine's map loader task aborts
("Error in background task: Das System kann den angegebenen Pfad nicht finden"), the loader loop (`CWldSessionLoaderImpl::Update`) reaches
`kReadyForDestroy` and hits the fatal assertion `SessionLoader.cpp:320` (the two `integrate` reports), and the session launch then reads a null
(AV at null + 8). Found by the stress loop (`rapid`/`mixed`, load 9 of seed 33). Fix: `Maps.Open` checks that the scenario's map file exists
and refuses with a message otherwise (a scan of all 414 scenarios finds only this one). The engine itself still dies on any aborted load; making the
loader fail soft is open (below). Also: `Maps.Open` of a path the game does not know no longer leaves a dead front end.

## Hardening found by the native audit (read-only audit of all `moho/editor/*.cpp`)

- New session-end hook: `moho::editor::EndSession()` (`EditorDocument.cpp`), registered as an `ISessionListener` with `WLD_AddOnTeardownCallback`;
  it runs in `WLD_Teardown` before the old session is deleted. It drops the queued height edits (they used to be applied to the **next** session's
  field at its first beat), forgets the attached terrain (a new session may reuse the addresses and was treated as the same document) and runs the
  handlers registered with `OnSessionEnd(fn)`: the strata mask shadow (`EdStrata.cpp`) and the erosion working copy (`EdErosionLua.cpp`).
  Other editor modules with per-session caches register the same way.
- `CUIManager::RemovePopoutFrame` released the frame and deleted the key handler inline; from a pop-out's own control or key that is a use after
  free (the engine defers frames while a MAUI event is dispatching). Both are parked until the next UI tick now.
- Field ops: `MakeOut` (`EdFieldCore.cpp`, `EdFieldPath.cpp`) now refuses `like` and `a` of different sizes (blur wrote `src.w * src.h` into a
  smaller `out`; the graph canvas can wire any input).

## Regression test

`python scripts/ed_stress_load.py <tag> --loads 12 --mode dirty --maps small` (modes `plain`, `dirty`, `rapid`, `all`).
`dirty` writes the whole map's heights with the camera low, which kills the unfixed exe within two loads.
Instance tags: use your own (`editor_inst.py new <tag>`); a crashed instance keeps its process (and the engine PDB open, which makes the
engine link fail with LNK1201): stop it with `editor_inst.py stop <tag>`.

## Sweep findings (2026-10-19, ed/sweep)

**The unreproduced sim-thread crash (`luaV_execute` null in a resumed sim thread).** The report file is gone. `scripts/editor_sim_stress.py` plays generated missions (timers, waits, triggers, spawns, a second army), fires sim callbacks
(EdEffect, EdSpawnUnit, EdMissionFlag / Scale / Skip / Jump, EdFire) and leaves play mode five ways (Stop, Stop twice, open another map, open the same map while paused, play again), checking the process and the crash folder after every cycle.
Result: about 80 cycles over 4 seeds without a crash; the only failures were environmental or a different bug (below). No code path that resumes a thread of an old session was found; the mission `Wait()` / `Timer()` helpers run in the
sim's own fork threads, which the engine tears down with the session. Not reproduced, so nothing was changed for it; the stress tool stays as the regression net (it is a nightly step).

**Found by that stress: a map whose armies break the game's score UI left the session as a plain game without the editor** (`score.lua CreateArmyLine`, `filespec` nil, thrown inside `OnFirstUpdate`, so `control.Start()` never ran).
Fixed in `schook/lua/ui/game/gamemain.lua`: the game's `OnFirstUpdate` runs under `pcall` (warning in the log), the editor starts anyway.

**Environmental: D3D "Not available" crash** with many engines at once (6+ instances on one GPU): not an editor fault; run at most 3 instances at a time.

**A play test now runs the edited mission.** The sim runs the script it was loaded with, so a mission edited in the session did not play (or played an old one). `ui.Play` now reloads the saved `_playtest` copy and starts in play mode when
`mission.Revision ~= mission.LoadedRevision` (`control.SessionExtra`, `gui/shell.lua Start`). The sim stress waits for that reload (`wait_play`).

**Flaky self tests** (found with `scripts/editor_selftest_loop.py`: every test N times in one process, shuffled, and across fresh starts): `selftest_paths` (line pick took the nearest 2-unit sample, so a zoomed-in camera missed the line: `pathtool.HitTest` now measures the distance to the
polyline), `selftest_unitwiz` (the ghost unit id came from the clock, so a second run found the first run's files: the id is now searched among files that do not exist), `selftest_parity` (the 200 entry history cap broke `pos == base + 3` after many runs:
`History.Clear()` first), `selftest_cmd` (`SetRect(.., 30)` changed nothing when a previous test had left the terrain flat at 30: a second value is tried). The last full shuffled loop: 20 runs + 2 fresh starts, one failure (`selftest_cmd`, now fixed).

**Memory growth over loads** (`scripts/ed_stress_load.py --mode full`, measured with working set, private bytes and the Lua heap; `--maps <one path>` repeats one map):
- The Lua heap is flat (82-100 MB) over 60 loads: no Lua leak.
- Different maps: working set grows about 20-25 MB per load (810 MB at load 1, 1960 MB at load 51, 2590 MB at load 60 after a big map); the engine keeps per-map resources.
- The same map 25 times in `plain` mode: 880 MB -> 959 MB, about 3-4 MB per load, slowing (the first loads 5 MB, the last ones 1-3 MB). Small native growth per session that the editor and the engine share; not attributed further without a native allocator trace.
- One real editor leak was found by reading the natives: the field engine's grids (`gGrids` in `EdField.cpp`, up to 64 MB each, also the graph node results and undo copies) live in a static table that nothing frees at session end. Fixed from Lua
  (`control.FreeNativeStores`: `ed_field_free_all()` at every session start and map load). A native `OnSessionEnd` handler would be cleaner (needs an exe rebuild; not done here).
- The 200-load run on the full mode did not finish (60 loads were measured; the rest was interrupted to merge the landed batches): rerun `python scripts/ed_stress_load.py <tag> --loads 200 --mode full` on the rebuilt exe.

## Open / not done

- `WRenViewport::RenderPreviewImage` still calls `CreateCamera(..., nullptr)` (crash 11:46 shape); no caller found, so left.
- The engine loader (`CWldSessionLoaderImpl::Update`, kReadyForDestroy branch) still asserts and the session launch dereferences null when a map load aborts for any other reason (corrupt `.scmap`, disk error): needs a fail-soft path (drop the scenario, return to the front end).
- SC2 campaign ports (`sc2_ca_*`) opened in the editor need the SC2 campaign mod: without it the mission script fails and no editor UI starts (no crash).
- `EdOverlay` caches and the popout event queue are not cleared at session end (`gGrids` are freed from Lua since the sweep, see above; no crash found).
- Hooks that are never unregistered (device listeners of EdPopout and the ARGB atlas) are benign as long as the device outlives them.
