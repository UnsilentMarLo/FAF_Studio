# Editor performance

Sections by area: Lua CPU (agent LC); other sections are added by the engine and GPU audits.

## Lua CPU

Audit of everything that runs in Lua per frame, periodically and at start, in both Lua states (author: agent LC, 2026-10). Method: reading the code. **Nothing was measured** (the editor cannot be run in the audit environment); all costs below are estimates from loop counts and sizes, marked "est.". Measure with the tools at the end of this section before treating any number as fact.

The Lua state is single threaded, so the goal is that an idle editor costs close to nothing per frame and that bulky work is either keyed (done only when its inputs changed) or native. Rule used for every change: lag-free interaction beats saved cycles, so no refresh a user waits for was delayed; only idle nets and hidden or unchanged work were cut. Sim-state Lua does not need determinism in the editor (no desync partner), so the cheapest form was used there.

### Finding that matters most: frame-count timers

Several "about four times a second" or "once a second" timers were counted in frames (15, 60, 120, 300 frames), i.e. they assumed 60 fps. With an unlimited frame rate (a small scene, no vsync cap, which is also what makes the process run at 100 % of one core) they ran 5 to 15 times as often: the shell's panel refresh (30 `Refresh` functions), the marker height sync (one `ed_terrain_get` per marker, 3000 on a mission map), the marker mesh net, the validation signature walk and the terrain epoch net. All of them are clocks now (`GetSystemTimeSeconds`), so the rates are the designed ones at any frame rate. At 60 fps nothing changes.

### Inventory

UI state, every frame

| What | Where | Cost class (est.) | Action |
|---|---|---|---|
| Shell tick (`S.poller` `OnFrame`): world view attach check, edit-mode check, window events | gui/shell.lua `Tick` | was ~10 us: an `import` and a closure + pcall per frame | **done**: modules kept in `S`, `IsEditing` is a named function (no closure, no import per frame) |
| Held-key camera movement | camera.lua `UpdateKeys` | was ~100-200 us/frame: walked ~200 commands, `ParseKeys` (gsub, find, two tables) 20 times | **done**: binding parsed once per key text (`Binding` cache), hold commands listed once (`HoldCommands`), move table only when a key is held |
| Unit viewer camera lock | camera.lua `Update` -> unitview.lua `Tick` | closure + import per frame | **done**: `LockTick` named function, module cached; returns at once unless the lock is on |
| ui.lua tick (`ui.tick` `OnFrame`): hide game HUD check, brush stroke pump, overlay | ui.lua `FinishCreate` | 2 imports + 1 import of itself per frame | **done**: the three modules are kept in `ui`; Perf marks `ui: frame tick (all)` and `ui: brush stroke pump` added |
| Overlay update (grid, slope, rings, paths, chains, ghosts, labels, handles ...) | overlay.lua `Update` | the largest per-frame Lua block; has Perf marks per section already | not touched (agent GC). See "Recommended" |
| `TerrainEpoch.Step` | terrainepoch.lua | built a string per frame; 300-frame net | **done**: two number compares, 5 s clock net (`NET_SECONDS`) |
| `Validate.Update` | validate.lua | `import` per frame; 60-frame signature net (walks every marker) | **done**: module cached, 1 s clock net |
| `MarkerVis.Update` | markervis.lua | 120-frame height sync (3000 native reads) and 60-frame mesh net | **done**: 2 s and 1 s clock nets |
| `Throttle.Pump` | throttle.lua (called by maskgen `DrawOverlay`) | a table per frame | **done**: no table when nothing waits (selftest_overlayfield already checks Pump) |
| Tooltip poller `OnFrame` | gui/tooltip.lua:108 | one compare per frame when no tooltip is pending | fine |
| Start screen `OnFrame` | gui/startscreen.lua:253 | only while the start screen is open; one thumbnail per frame, a size compare | fine |
| Command channel poller (`/edcmd`) | control.lua:125 | 4 Hz, `ed_file_stamp`, plus one `ed_read_file` of the .stamp file when the stamp exists | dev only (flag), left |
| Perf marks | perf.lua | `Perf.Begin()` is one call returning nil when off, `End` ignores nil, `Time` is a plain call when off | fine (checked); `Perf.Tick` returns at once when off |

UI state, about four times a second (shell tick, now by clock: `REFRESH_SECONDS = 0.25`)

| What | Where | Cost class (est.) | Action |
|---|---|---|---|
| Panel module `Refresh()` of 30 modules (`PanelModules`) | gui/shell.lua tick; list: panels_armies, chains, console, editor, effects, erosion, graph, graphinspector, history, images, interop, maptextures, mission, missionrun, mods, objects, paths, platoons, recipes, sctools, settings, strata, terrainchecks, toolsettings, ttlayers, unitlab, unitview, unitwiz, view; feature_branding | a pcall each; most return at once (`live.x` nil or a revision compare). Panel instances behind another tab are skipped by dock.lua (`HideHolder` swaps their `Refresh` for a no-op, `PlaceHolder` runs it once when the tab is back) | rate fixed (clock). Hidden-tab skipping already existed and was verified. Panels with module-level work that ignores visibility: `TC.Tick` (terrainchecks), `SC.Tick` / `SC.Water.Tick` (sctools), `Interop.LinkPoll` (its own interval), `Opts.Sync` (toolsettings), `Test.Resume` (unitwiz): each is a few compares at idle (est. < 20 us) |
| `StatusText()` | ui.lua:1114 | one `string.format`, a pointer ray (`MouseWorld`), `GroundHeight`, slope readout (a native call only with the slope view on) | est. 20-40 us; compared with the shown text before `SetText` |
| `AutosaveTick` | maps.lua:333 | two compares; a synchronous `Map.SaveAs` every 300 s when the history moved | the save is a hitch of the size of the map (est. 50-500 ms on a big mission map); moving it to a thread is not possible (it is one native call chain); left |
| `W.ScrollTick`, pop-out window signature, `persist.Tick`, `UserData.Flush` | gui/shell.lua, widgets.lua:328, persist.lua:61 | a few table walks / string formats; `Flush` writes only when dirty | fine |
| Brush panel preview | panels_editor.lua:170 | 48 `Terrain.BrushWeight` calls + 48 `string.format` per refresh while the Brush panel is shown | est. 50 us; could be keyed by (radius, strength, mode, shape): recommended, not done |
| Paths panel | panels_paths.lua:481 | signature string every refresh; the panel's own refresh only on change or every 8th (2 s) | fine, and now really 2 s |

Threads (UI state)

| What | Where | Period | Action |
|---|---|---|---|
| Asset thumbnail worker | assetthumbs.lua:418 | every 2 ticks while thumbnails are wanted or warming (12 ms budget, warm-up 8 ms); the thread ends when the queue is empty | idle cost nil |
| Image panel worker | gui/panels_images.lua:296 | 0.03 s while stale thumbnails exist, then ends | fine |
| Browser dialog folder watch | gui/browser.lua:668 | 2 s, only while a browser dialog with `signature` is open (`Texmap.Signature`) | fine |
| Scroll redraw deferral | widgets.lua:443, grid.lua:72 | one shot of <= 30 ms | fine |
| Icon generator, unit viewer threads | icongen.lua:75.., unitview.lua:490.. | on demand, 0.08-1.2 s steps while a render runs | fine |
| Test-run start | ui.lua:756 | 25 x 0.2 s once per Play | fine |
| Session restart helpers | shell.lua `Start` (1.5 s once), resize.lua:663 | once | fine |

Sim state

| What | Where | Period | Cost class (est.) | Action |
|---|---|---|---|---|
| Peace sweep (hold fire for units another feature made) | editorsim/peace.lua `StartSweep` | woke every 10 ticks (1 s) and walked **every unit** with `GetUnitsInRect(Rect(0,0,100000,100000))` (builds a Lua table of all units, then `Hold` per unit) | est. 1-5 ms per second on a map with 2000-5000 units, plus the garbage | **done**: wakes every second but compares the engine's unit count (`brain:GetCurrentUnits(categories.ALLUNITS)` per army, native, allocation free); walks the units only when the count changed or as a net every `SWEEP_NET` (10) wakes. Without `api.count` (tests, or the call failing) it walks every wake as before. selftest_peace.lua checks both |
| Viewer heal thread | editorsim/viewer.lua:58 | every 5 ticks, only while the viewer unit lives | negligible | left |
| Unit lab feed / tests | editorsim/unittest.lua:96 | one shot | - | left |
| FAF `EnergyManagerBrainComponent:ToggleEnergyExcessUnitsThread` | faf lua/aibrains/components, started by `AIBrain:OnCreateHuman` | every tick for the human army: ~5 engine calls | est. < 0.1 ms/s | left; killing it for edit mode and starting it at Play is possible but saves almost nothing |
| FAF unit scripts of placed units | FAF `Unit.lua` etc. | threads each unit starts in `OnCreate` (idle effects, intel, shields ...) | scales with unit count, not measurable here | not touched (changes how units look / behave); the structure hook already removes tarmac and terrain flattening in edit mode |
| Resnap callback | sim.lua / `EdResnap` | after terrain strokes, <= every 0.15 s | walks the units and props in the rectangle only | fine |

### Startup

What runs before the editor is usable, by cost (all estimates; no timings exist):

1. **Blueprint load, "Rules" Lua state** (`/lua/RuleInit.lua` -> `LoadBlueprints()`, run by the engine in `RRuleGameRulesImpl`'s constructor on every session start, including every "open map"): `doscript` of every `.bp` in `/effects /env /meshes /projectiles /props /units` and the active mods, then `ModBlueprints` and registration. From the asset index: about 2800 effect (emitter, beam, trail) files, 580 unit, 290 projectile, 335 env and 33 mesh blueprints in the vanilla archives, plus FAF's own and the mods': **about 4500 files, ~60 % of them effects**. This is almost certainly the largest single block of Lua time before the editor opens (read + compile + run per file; est. seconds). Does the editor need all of it? Units and projectiles yes (placement, the unit lab, the viewer, test runs); props and env yes (prop placement); emitters, beams and trails are used by the effects panel, the unit viewer and test runs, and the engine looks emitter blueprints up in this rules object (there is no Lua call-back when one is missing), so skipping them at start and loading them later would need a native "register blueprint file" entry in the engine: **not possible from Lua, not done**. Recommended for the engine side: keep the parsed blueprint set across session restarts (a map open currently loads all 4500 files again) or load the effects directory on a worker thread.
2. **FAF game HUD creation, UI state** (`gamemain.lua` `CreateUI`): builds the complete game interface (borders, economy bar, orders, construction, multifunction, avatars, score, chat, minimap ... dozens of modules and hundreds of controls), which the editor hides at once (`ui.lua GameUIHidden`) and only needs for a test run. Candidate for lazy creation at Play; **not done**: the editor's world view, cursor and key map depend on pieces created there, and I could not run it to check.
3. **Editor modules, UI state**: `control.Start` -> `ui.Create` -> `shell` imports every `gui/panels_*.lua` and `feature_*.lua`. Counted from the top-level `import` calls: **about 190 editor modules, ~65,000 lines** (plus ~9,000 lines of game UI libraries). Top-level work is registration only (panels, commands, menu items); the heavy builders (`Units.Catalog`, `Props.Catalog`, `Decals.Catalog`, `Brushes.List`, asset index builds, `Maps.List`, help data, tip data) are already lazy and cached. Compile time of 65k lines is est. 0.1-0.3 s. About 35,000 of those lines are only needed when their panel is first shown (paths 1600, mission 1536, graph* ~3100, unitwiz + scm + meshimport ~2100, sctools 862, maptextures 844, recipes 774, platoons 725, interop 685, icongen 669, maskgen 643 ...). Making those imports lazy is possible per file (`local X = import(...)` -> a function that imports on first use) but each is an edit of a large file with the 32-upvalue limit in view, for an est. gain of 50-150 ms in total: **recommended only if the profile shows it; not done**.
4. Session start in the shell: `Hotkeys.Load`, `Keys.Apply`, `ShowWorkspace` (creates only the panels of the visible tabs: hidden tabs are created when first shown), `Persist.Restore`, `feature_start.OnStart`, `strata.Normalize`: small.
5. Start screen map list: **not** at start (recent maps only); `Maps.List()` (a `DiskFindFiles` over the whole `/maps` tree) now shares one walk per second between `List`, `UserMapsDir` and `ListUser`.

### Changes made

| File | Change |
|---|---|
| gui/shell.lua | refresh by clock (`REFRESH_SECONDS`), `IsEditing`, modules kept in `S` (`uiMod`, `builtinMod`, `lastRefresh`) |
| camera.lua | `Binding` cache, `HoldCommands`, lazy move table, `LockTick` |
| ui.lua | modules kept in `ui` (`gameMainMod`, `worldViewMod`, `selfMod`); `local Perf`; marks `ui: frame tick (all)`, `ui: brush stroke pump` |
| terrainepoch.lua | allocation free `Step`, clock net, `Step(stroking, now)` for tests, `NET_SECONDS` |
| validate.lua | clock net, cached tools module |
| markervis.lua | clock nets for the height sync (2 s) and the mesh walk (1 s) |
| throttle.lua | `Pump` allocates only when something waits |
| maps.lua | `ScenarioFiles()` shares one `/maps` walk per second |
| editorsim/peace.lua | sweep keyed by the engine's unit count (see above) |
| perf.lua | the report prints the Lua heap (`lua heap: X MB (+Y MB since the last report)`) |
| selftest_peace.lua, selftest_graphbase.lua | new checks: sweep walks only on a count change and as a net; `TerrainEpoch.Step` net by clock |

### Recommended, not done (ordered by expected value)

1. **overlay.lua `UpdateLabels`** (agent GC's file, line ~380): when zoomed in it loops over **every marker every frame** (selection set lookup, hover compare, bounds test); est. 1-3 ms per frame with 3000 markers, i.e. 6-18 % of a core at 60 fps and proportionally more at an uncapped rate. Key it on (`Tools.Changed`, `Tools.HoverRev`, the camera's visible bounds, filter state) and keep the list of visible names between frames; only the projection of the <= 150 shown labels needs to run per frame. Same pattern in `Handles`, and `unitFrames` (overlay.lua:941) is also a frame counter.
2. **overlay.lua `DrawLayers`**: 11 `pcall(function() import(...).X() end)` per frame make 11 closures and 11 import calls; cache the modules in a table and call named functions.
3. **Units cache net** (units.lua `CacheFresh`): `Units.All()` (2100 tables on a mission map) is rebuilt at the latest every 1.5 s while any caller (unit tools, rings, gizmo) uses it; it is keyed already, so the net could be 5 s. Est. 10 ms per rebuild.
4. **Brush panel preview** keyed by (radius, strength, mode, shape).
5. **Blueprint load** (startup item 1) and **lazy HUD** (item 2): the two big startup costs; both need an engine or deeper session change.
6. **Native candidates** (user guidance: use several cores where a native op exists or is easy): the marker height sync (`ed_terrain_get` x 3000) as one native batch call; `Validate.CheckMap` prop loop (`ed_prop_get` per prop, up to 10,000); `Units.All()` as a native snapshot. None is needed at idle any more.
7. Autosave (`Map.SaveAs`) is synchronous: a native background writer would remove the periodic hitch.

### How to measure

* Start the editor with `/perf` or run the command palette entry **Performance timing: on / off** (command `dev.perf`, Ctrl+Shift+P). A report goes to the log and the Console panel every 5 seconds: `--- 5.0 s, N frames/s ---`, then `lua heap: X MB (+Y MB ...)`, then up to 24 sections, largest first: name, ms per second of wall time, calls, average ms, worst ms. More than ~2 ms/s is worth a look; a worst value above ~30 ms is a visible hitch.
* Sections: `shell: tick (all)`, `shell: camera keys`, `shell: 4 Hz refresh (all)`, `shell: status text`, `shell: autosave check`, `shell: scroll tick`, `shell: persist`, `refresh panels_xxx.lua` (one per panel module, only while timing is on), `ui: frame tick (all)`, `ui: brush stroke pump`, `overlay: update (all)` and its parts (`overlay: labels`, `overlay: validate`, `overlay: marker meshes`, `overlay: rebuild objects` ...).
* Frame-rate dependence: the first line of a report shows frames/s. Before this audit `shell: 4 Hz refresh (all)` showed `calls` = frames/15; now it shows about 20 calls per 5 s at any frame rate. That is the quickest check that the clock change works.
* Heap: a heap that rises and falls by many MB within a report is per-frame garbage (the collector runs on the same core); one that only rises is a leak.
* Sim state has no Perf report. Check the peace sweep with the log: `GetUnitsInRect` is no longer called while the unit count is steady; the sim's own cost shows in the engine's frame statistics (agent EC).
* Selftests: `return import('/lua/editor/selftest_peace.lua').Run()` and `return import('/lua/editor/selftest_graphbase.lua').Run()` through `/edcmd` (graphbase needs a map open).

### Could not verify

Nothing here was run in the editor. All files parse with the Moho parser (32-upvalue limit) and `python3 -I scripts/studio.py check` passes; `selftest_peace.lua` was also run in a Lua 5.1 shim (lupa) and passes. Not run: the shell refresh change, the camera key cache (needs the engine's key table), the validate / markervis / terrain epoch clocks, and the `GetCurrentUnits` call in the sim (if the engine's active-unit stat does not move for a unit created by a callback, the sweep falls back to its 10 s net instead of 1 s; hold fire for such a unit is then late, but every army pair is neutral anyway, which is the first line of defence). All cost numbers are estimates.
