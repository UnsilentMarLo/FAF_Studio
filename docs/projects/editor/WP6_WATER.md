# WP6: water bodies, shore waves (2026-11-11)

Work package 6 of `EDITOR_PORT_ANALYSIS.md`. Engine branch `port/wp6-water` of faf-re (worktree `C:\Users\Marlo\Documents\GitHub\faf-re-port-wp6`, on `port/wp3-exact-save`), Lua side in this repository. Not pushed.

## What is bound

`src/moho/editor/EdUpWaterLua.cpp` over upstream's logic (`EdWaterBodies`, `EdWaves`, unchanged). `EdWaterBodies.cpp` is compiled into the exe (`editor_sources.cmake`), not into `faf_editor_logic`: it includes the engine's `moho/sim/WaterBodies.h` and the exe already links `WaterBodies.cpp` once.

| native | does |
|---|---|
| `ed_waterbodies_fill(bodies[, {install, cells}])` | fills a list of bodies (Lua tables with the scenario's own field names) over the open map's heights with the game's `CWaterBodies::Build` and `WaterBodyDescs` (same defaults, same skips); `install` puts the result on the map (`STIMap::mWaterBodies`), rebuilds the water map, the shore and the water surfaces |
| `ed_waterbodies_clear / _info` | take the bodies off the map / what is on it |
| `ed_waterbodies_crosscheck(bodies)` | the same bodies through the editor's fill and through `STIMap::InstallWaterBodies` (the game's reader, the sim fix forced on for the call), compared per vertex and cell; the map is left as it was |
| `ed_waterbodies_simfix(on)` | the console variable `sim_FixWaterBodies` (a Play of the editor needs it; `water.lua` sets it when a map has bodies) |
| `ed_water_texel(x, z)` | one texel of the water map the renderers use (the finer one with `ed_water_hires`): shore flag, depth byte. For checks |
| `ed_waves_get / _set` | the wave generators of the open map through `WaveSystem::Save` / `Load` (as `EdDocument::WavesNow / ApplyWaves`) |
| `ed_waves_read / _write` | `.scmwaves` text |
| `ed_waves_patterns([lua])`, `ed_waves_generate{...}` | wave patterns (built in or a `wavepatterns.lua`), generators along the shore of the sea (`FindShorePoints`, `PickShorePoints`, `MakeShoreWave`) |

`.scmwtr` is WP2's (`ed_scmwtr_*`, `fafme.lua`); upstream's `WaterPresetTests` pass in this branch too. `.scmwaves` import / export is here (`File > Import / Export > Shore waves`).

Lua: `water.lua` (model in `Map.Doc.info.WaterBodies`, one undo step per edit, a slider drag is one step, refill after height edits, guides on the map, the Water body tool's click), `gui/panels_waterbodies.lua` (panels **Water bodies** and **Shore waves**, Environment workspace, tabs beside Water), `gui/feature_water.lua` (menu entries), the tool `waterbody` in `ui.lua`, `control.lua` starts it with the session, tips in `tipdata.lua` / `tooltips.lua`, `selftest_waterbodies.lua` (in `selftests.extra`), `scripts/ed_waterbodies_check.py`.

## The main risk: hi-res water map and bodies (what was found, what changed)

Both editors changed the water-map path. Facts, from the code of this branch:

* Our `ed_water_hires` (patch 0104, `WATER_SHORE.md`): `GetWaterMap()` hands the renderers a finer texture (4 texels per cell) built from the bilinear height and **the sea's level only** (`FillWaterHiRes`). Rebuilt for the cells that `RebuildWaterMapRect` marked dirty.
* The engine's bodies (`sim_FixWaterBodies`, `WaterBodySurfaces`): with bodies `RebuildWaterMapRect` takes the `RebuildWaterMapRectWithBodies` branch (each 2 x 2 block takes the level and abyss of its own body; a dry body has none). That branch **returned before the hi-res mark**, and `FillWaterHiRes` knew nothing of bodies.
* So with both on, the renderers would have drawn the shore from the sea's level: a lake above the sea had no water alpha at all (ground "above the water" by the sea's level), a lake below the sea was drawn as sea. Nothing refreshed the finer map when bodies were installed, either.

Changes (`CWldTerrainRes.cpp`, 42 lines; nothing differs for a map without bodies):

1. `FillWaterHiRes` takes each texel's water from its 2 x 2 block (`WaterOfBlock`) when the map has bodies: its level, its abyss for the depth byte, "ground above the water" against that level. Without bodies the numbers are the old ones (same code path, same results).
2. `RebuildWaterMapRectWithBodies` marks the cells dirty for the finer map (height edits).
3. The finer map remembers the `WaterBodiesGeneration` it was made for and is rebuilt whole when the bodies change (install, clear, refill).
4. **Saving**: while bodies are on the map the half-resolution sheet holds their depth and shore; `CWldTerrainRes::Save` takes the bodies off for the write of the water map and puts them back (the game fills them again at load from the scenario). A `.scmap` written with bodies on the map is the same bytes as one written without them (checked in `selftest_waterbodies`, with edited heights so the exact writer re-encodes the sheet instead of keeping the file's bytes). WP3's "sources unchanged" rule is untouched: bodies are not a source of the water map.

Not changed: the half-resolution water map is still what is saved and edited (foam, flatness brush); wave generators stay at the sea (as in the engine's doc).

## Semantics worth knowing

* A lake whose level is **below the sea** is a hole in the sea: the sea owns the ground around it (the 2 x 2 block rule), so the border between the lake and the surrounding sea is a step between two levels, not a shore. A lake **above** the sea (or on a map without sea) has a shore against dry ground.
* A body needs ground below its level at the seed; a later body cannot take ground an earlier one has; at most 255 bodies (the game's rules, not the editor's).
* The game needs `sim_FixWaterBodies` for a map's bodies; no FAF release has it on. `water.lua` switches it on in the editor process as soon as a map has bodies (the editor is never a multiplayer game). Without it the map plays as sea only.
* Fill preview = the live map: every edit fills again (150 ms after the last slider move), a height stroke or undo fills again when it is over.

## Checks (2026-11-11, exe `main_ed_wp6`, branch `port/wp6-water`)

* **Fill preview = `STIMap::InstallWaterBodies`**: `python scripts/ed_waterbodies_check.py wp6 --only SCMP_001 SCMP_003 SCMP_005 SCMP_009 X1MP_004 --hires0`: three bodies made from each map's own lowest points (a lake, a lake with an outline, a dry body with bounds): **0 vertices and 0 cells differ on all 5 retail maps**, body counts equal (SCMP_005: 27809, 3132, 3741 cells; bodies that cannot fill are skipped by both for the same reason). Synthetic cases (outline, bounds, dry, no seed, seed above the level, 2-point outline, non-numbers) in `selftest_waterbodies.Run`: equal.
* **Shore with hi-res on / off**: `ed_water_texel` along a row across the bank of a round basin (level 15, analytic shore at x = 153.67): with hi-res 4 the depth byte falls 30, 26, 22 ... 4, 0 and reaches 0 at x = 153.5; with hi-res 0 the half-resolution steps (31 constant over 2 units, flag on from 152, as before). Selftest: shore flag off at the water and on at the land beyond (above the sea too), depth > 0 under the water. Screenshots `img/wp6_shore_hires4_vs_hires0.png` (left 4 texels per cell, right 0) and `img/wp6_lake_above_sea.png`: a lake whose banks are above the sea shows a clean arc both ways, the finer one tighter. On the retail maps the rim check is "n/a" (the lakes picked sit under their sea).
* **Save and load**: `Build()` / `Verify()` (selftest): a map with one body (with an outline) saved by the WP3 writer into `mapout/wp6_lakes.v0001`, opened in a new session: the scenario has the body field for field, the session fills it (1681 cells), it is what the game fills, the render water map shows the water. The scenario text of retail maps is patched in place with the table added (SCMP_001 +968 chars, X1MP_004 +991).
* **Waves**: 64 generators made on a test shore, the same seed makes the same waves, they are put on the map and read back as put, `.scmwaves` round trip, undo / redo.
* **Upstream tests** (`faf_editor_brush_tests`, `FAF_RETAIL_MAPS` set): `WaterBodiesEdit*` 9, `Waves*` 4 (retail maps' wave sections), `WaterPreset*` 2: pass; no adaptation was needed (WP1's test target already compiles `EdWaterBodies.cpp` with the engine's `WaterBodies.cpp`). The engine's own `faf_water_bodies_tests` (14) and `faf_water_bodies_map_tests` (6) pass.
* `selftest_waterbodies.Run`: 47 checks, PASS. `python scripts/editor_lint.py`: nothing in the new files (its one error is WP5's `selftest_adaptive.lua:451`). `tipcheck`: Water bodies 46 widgets, Shore waves 32, tool, panels and menu entries all have text.

## Sim checksum of an unedited retail map

No sim source changed. The diff of the branch against WP3 is `CWldTerrainRes.cpp` (the client's terrain resource: water-map textures and the file writer), `editor_sources.cmake` and the new editor-only `EdUpWaterLua.cpp`; `STIMap`, `WaterBodies.cpp`, `STIMapWaterBodies.cpp` and `FafGameVersion.*` are as they were, and `sim_FixWaterBodies` stays "unreleased, off unless set". A map without `ScenarioInfo.WaterBodies` never reaches the new branches (`HasWaterBodies()` is false: the finer map's per-texel code is the old code, the save writes the sheet as before), and `water.lua` sets `sim_FixWaterBodies` only when a map has bodies.

**I did not run a before / after sim checksum.** The replays I had (`replays_pr`) need vault maps that are not installed (the headless runner stops at the map load; I built `headless_x64` from this branch for it), so there was no replay to digest. What was run: the engine's water-body tests (above). Tried and failed: 8 replays in `replays_pr` (all stop at the map load: vault maps not installed). Not tried: `run_ai_games.py` with the baseline exe (`main_ed_wp3`) and this one on an installed retail map, whose harness is in the SupCom_Dev_Workspace repository. A replay or AI game of a retail map played by both exes (`--digests`) is the check still to be run; nothing here claims it.

## Limits / not done

* Bounds are four sliders, not a rectangle dragged on the map; the Water body tool places the seed and the outline points (click, drag a point). A point is removed with Clear outline (all of them).
* A body's seed is a pin; there is no per-cell fill overlay (the live water is the preview; `ed_waterbodies_fill{cells=true}` gives the cell bytes).
* A water level change in a running Play reaches the render side only (WP9's note); a Play of a map with bodies needs `sim_FixWaterBodies` (set by `water.lua`): **Play with bodies was not run**.
* Keys removed from `ScenarioInfo` make the scenario fall back to the full write (WP3): deleting the last body of a map whose file had `WaterBodies` does that once.
* Waves: generators are shown as short lines (up to 400); no per-generator editing (the list is replaced as a whole, one undo step); retail maps have thousands.
* `.scmwtr` natives are WP2's, not in this branch (it is not merged with WP2); the Lua menu entries of `.scmwtr` are WP2's too.
* The nightly was not run; `selftest_waterbodies` needs WP5's `ed_adaptive_tables_path` stub only for `Build()` (map.lua's save calls `adaptive.lua`, which needs WP5's natives that this build does not have).
