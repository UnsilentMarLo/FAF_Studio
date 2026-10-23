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

## Engine CPU

Audit of the native side: main loop, frame pacing, threads, sim, loading (author: agent EC, 2026-10). Method: reading the reconstructed engine (`engine/faf-re/src/sdk`), our patches and the init files. **Nothing was measured** (no editor, no MSVC, no profiler in the audit environment); the engine changes compile only on the user's machine. Confidence marks: **[code]** = read in the source, certain what the code does; **[guess]** = a conclusion about behaviour on real hardware or drivers that the code cannot show; **[model]** = measured on a stand-alone model of the loop on a 4 core Linux box, not in the editor.

Rule used for every change (user guidance): the editor needs no determinism (no desync partner, no replay), but needs smoothness and stability. Nothing waits for input; every change has a console variable that switches it off; workers only do pure data work (the Lua state and the D3D device stay on the main thread).

### Why one core is at 100 %, before the editor loads and while it idles

The main loop is `WIN_AppExecute` (`moho/app/WinApp.cpp`, loop at ~2490): wx messages first, then idle, then `app->Main()` (`CScApp::Main`, `CScApp.cpp:1009`: sim sync `WLD_Frame`, camera, `UserFrame` = the UI Lua tick, `REN_Frame`), then `MsgWaitEx` (wait for messages). **Nothing in the loop sleeps between two frames** [code]: `Main` ends with `CD3DDevice::Refresh()` (`CScApp.cpp:1083`) = `wxWindow::Refresh` = invalidate; the `WM_PAINT` that causes is a message, so the wait after `Main` returns at once; the paint (`WD3DViewport::OnPaint` -> `CD3DDevice::Paint`, `CD3DDevice.cpp:1713`) presents the last frame and renders the next one. The only pacing is the swap chain: `PresentationInterval` ONE when `context.mVSync` (`D3D9Interfaces.cpp`, `GetHeadParameters`), IMMEDIATE otherwise. The loading screen and the start screen go through exactly the same loop and paint a frame per iteration, which is why the core is busy before the editor is up.

Three things keep that one core at 100 % even when the frame rate itself is bounded:

1. **`DeviceD3D9::Present` spins** [code] (`D3D9Interfaces.cpp:3299`, original code): before presenting, it polls the frame's event query in `while (query->GetData(nullptr, 0, D3DGETDATA_FLUSH) == 1) {}`: a hot loop, with a driver flush on every pass, for as long as the GPU has not reached the frame's start marker. With vsync on, that is the whole vsync wait of the frame before; when the GPU is the bottleneck it is the whole frame. This is the most probable reason a core is at 100 % in a still scene on a fast machine **[guess]**: the code leaves no doubt that the loop spins, but how long it spins on your GPU can only be measured. **Changed** (see below).
2. **No frame rate limiter** [code]. `sc_FrameTimeClamp` ("Minimum time between frames", default 10 ms) is declared (`CConCommand.cpp:4876`) and FAF's `gamemain.lua AdjustFrameRate` sets it, but nothing in the recovered engine reads it. With vsync off the loop draws as fast as the GPU lets it. The editor starts with vsync on (`graphics.lua` `Default('vsync') = 1`; the engine reads FAF's option default 1 at device creation, `CScApp.cpp:1178`) **[code]**, but see 6: the Off setting did not work.
3. **The main thread was pinned to the lowest CPU** [code] (`THREAD_SetAffinity(true)`, `WinApp.cpp`, the 2007 original): it shares that core with whatever else lands there (map loader, sim, driver threads) and cannot move. **Changed**.
4. **The whole scene is redrawn every iteration** whether anything changed or not [code] (see GPU section; agent GC's `EdActivity.h` has the signals a "still scene" pacer would use). Not changed here: water, sky and effects move all the time, so a still picture is rare, and drawing a moving water surface at a lower rate is a visible change.
5. **A forced full garbage collection of the UI Lua state every 5 seconds, on the main thread, idle or not** [code] (`CUIManager::UpdateFrameRate`, `CUIManager.cpp:455`, `lua_setgcthreshold(state, 0)`; Lua 5.0 collects stop-the-world). The editor's UI state holds ~190 modules, the unit / prop / texture catalogs and FAF's UI libraries, so the pause grows with that live heap (est. tens to hundreds of ms, **[guess]** for the size) and an idle editor pays it for nothing. The sim state does the same every 70 ticks (7 s) on the Sim thread (`Sim.cpp:10678`). **Changed**: both run only after the heap grew (see below).
6. **`SC_VerticalSync` was a no-op** [code] (`ResolutionCommands.cpp`): it reset the device with the context it already had and never read its argument (the recovered body even says so), so the editor's Settings > Vertical sync could not switch it off. **Changed**: the argument is applied.

The loading phase itself is not single threaded by the loop: the map loads on a worker thread (`Map loader <map>`, `WldSessionInfo.cpp RunWorkerThread`, entry `WorldSessionUserLoad`, `CWldSessionLoaderImpl.cpp:102`). What that thread does is serial Lua and file work: `RRuleGameRules::Create` (about 4500 `.bp` files, see "Startup" above), a new Lua state with the core and user bindings, `SessionInit.lua`, then `CWldMap::MapLoad` (terrain, props, normal map, water map). The main thread meanwhile draws the loading screen and, with the old spin, burned a core doing it.

### Threads of the process

| Thread | Where | Behaviour | Note |
|---|---|---|---|
| main | `WIN_AppExecute` | paint-driven loop above; UI Lua, rendering, D3D | pinned before, free now |
| `Sim` | `CSimDriver::ThreadCreateSim`, `SimDriver.cpp:1100` | builds the sim, then `ExecuteDispatchStepLocked` per beat; waits on a condition variable between beats | the sim is **not** on the main thread already; 24 bit x87 precision (no effect on x64) |
| `Issue` | `CSimDriver::ThreadRun`, `SimDriver.cpp:1206`, priority HIGHEST | decides how many beats may run, then `WaitForSingleObject(mConnectionEvent, <= 1000 ms)` until the next beat is due (10 Hz at normal speed) | cheap; spins only while the sim is behind schedule (`waitMilliseconds = 0`, catching up) |
| `Map loader <map>` | `SWldScenarioLoadControl::RunWorkerThread` | one per map load, serial | see above |
| `Prefetcher thread.` | `ResourceManager::PrefetchThread`, `ResourceManager.cpp:329` | idle priority; one resource at a time, waits `res_PrefetcherActivityDelay` s after any foreground load and naps `res_AfterPrefetchDelay` = 250 ms after each | conservative on purpose; only textures asked for with `RES_PrefetchResource` |
| field pool | `EdFieldCore.cpp` `Pool`, `min(hardware threads, 16)` threads including the caller, created on first use | terrain generation, erosion, and now the normal map | `ed_field_threads([n])` |
| `CSimWorkerPool` | `SimWorkerPool.cpp` | engine addition for deterministic parallel sim phases | **no caller** apart from a worker-aware path in `COGrid.cpp` [code]: not used by anything |
| GpgNet, movie, audio | `CGpgNetInterface.cpp:1003`, `IndependentSfdBackend.cpp`, XACT | only with `/gpgnet`, movies, sound | off in the editor (`/nomovie /nosound`) |
| D3D / driver threads | not ours | | see `ed_perf_threads` |

Sim facts [code]: replay recording is off (`SinglePlayerLaunch.lua` `createReplay = false`; `WLD_DoLoading` only opens a replay sink when the session is recorded). The beat checksum runs every `sim_ChecksumPeriod` = 50 beats (`SimDebugCommandRegistrations.cpp:189`, `Sim.cpp:10667`): one MD5 pass over the armies and entities every 5 s, est. milliseconds, not worth removing (and `Sim::Sync` divides by the period, so `0` would crash). Entities without a motor return -2 from `Entity::MotionTick` (`Entity.cpp:3109`) and are parked by the task scheduler, so frozen props and idle structures cost almost nothing per beat; `AdvanceBeat` itself walks all units twice per beat (`ForEachAllArmyUnit`, `Sim.cpp:10540`, `10616`), est. microseconds per thousand units. The sim state's Lua gets a **full garbage collection every 70 ticks** (`lua_setgcthreshold(.., 0)`, `Sim.cpp:10678`): with ~4500 blueprints in that state it is a pause of est. 100 ms on the Sim thread every 7 s; the main thread is not blocked by it, a `SimCallback` that arrives during it is answered later. Two `TEMPORARY PROBE` blocks open and close `faf_diag.log` every 100 Issue passes and every 200 beats (`SimDriver.cpp` ~1315, `Sim.cpp` ~10515): cheap, but pointless in the editor.

### Hot spots

| What | Where | Cost class | Can it move to another core | Risk | Status |
|---|---|---|---|---|---|
| Present's event-query spin | `D3D9Interfaces.cpp:3299` | 100 % of the main core while the GPU is behind (frame time to vsync wait) | not needed: sleep instead | low | **done** (`ed_present_wait`) |
| Unpaced paint loop | `WinApp.cpp` loop | a core and the GPU whenever vsync does not bound it (vsync off, or a driver that does not block) | n/a, a cap | low | **done** (`ed_fps_limit` ...) |
| Main thread pin | `WinApp.cpp` | contention with the loader / sim / driver on one core | n/a | low | **done** (`/edpin` restores) |
| Normal map (4x4 DXT blocks, 16 `GetNormal` each) | `CWldMap.cpp UpdateNormalMap` | est. 2 us per block: 0.15 s on a 1025 map, 1.4 s on 4097; runs on a load and on every whole map commit (`EditorDocument.cpp ProjectHeights`) | yes, rows are independent | low | **done** (`ed_par_normalmap`); model: 350 -> 88 ms on 4 cores for 2049 x 2049 [model] |
| Tier error grids | `STIMap.cpp UpdateErrorKernel` | est. 10 passes over the rectangle, ~50 ms on 1025, ~1 s on 4097; **twice** per commit (view field on the main thread, sim field on the sim thread, `ApplyPendingHeightEdits`) | yes per tier (a tier reads the one below; cells of one tier are independent) | medium: has to stay bit exact, the loop ticks the abort check per row | recommended, not done |
| Blueprint load (4500 `.bp`) | `RRuleGameRules::Create` on `Map loader` | est. seconds, serial Lua | not by threads (one Lua state); a persistent parsed set across map opens, or reading / decompressing the files ahead on a worker | high (changes load order and the rules object) | not done |
| UI state forced full GC | `CUIManager.cpp:455` | one stop-the-world collection of the UI heap every 5 s on the main thread: est. tens to hundreds of ms, a visible hitch and idle CPU | no (Lua state, main thread); do less of it | low-medium | **done** (`ed_ui_gc_kb`, `ed_gc_max_seconds`) |
| Sim state forced full GC | `Sim.cpp:10678` | est. 100 ms / 7 s on the Sim thread (every blueprint is in that state); a `SimCallback` arriving during it waits | already off the main thread | low-medium: more garbage is allowed to pile up (bounded by the gate and by Lua's own doubling threshold) | **done** (`ed_sim_gc_kb`) |
| Present's driver wait itself | the driver | unknown | no | - | measure with `ed_perf_loop` (`presentMs` vs CPU %) |
| `D3DCREATE_MULTITHREADED` | `D3D9Interfaces.cpp:1753` (flags 0x44) | every D3D call takes the device lock, est. 5-10 % of the D3D CPU time | no | **needed**: the map loader creates D3D textures from its thread | left |
| Per frame stat publishing | `CScApp.cpp PublishAllocatorHeapStats` | takes the allocator lock, six string formats, est. < 20 us | - | low | left |
| Prefetcher pacing | `ResourceManager.cpp` | slow background texture preload | - | low | experiment: `res_AfterPrefetchDelay 20` and `res_PrefetcherActivityDelay 0` |
| Texture / mesh creation | main thread, on first use | est. ms per texture | file read yes (prefetcher), the D3D part no | medium | not done |

### What was changed

All in `engine/faf-re` branch `editor`, patch series 0060 and later. Console variables work in the editor's console (`ed_fps_limit 144`); `0` switches a cap off.

| Change | File | Console variable | Default | Risk and thread safety |
|---|---|---|---|---|
| Present sleeps in 0.3 ms steps (after 100 us of spinning) instead of a flush-spin | `D3D9Interfaces.cpp`, hook in `EdPerf.cpp` | `ed_present_wait` | 1 | Low. Same query, same condition; the first poll still flushes. Adds at most ~1 ms to a frame only when the GPU is behind (then the CPU was waiting anyway). No high resolution timer (Windows < 10 1803): the original loop. Main thread only. |
| Frame rate cap in the main loop. Input never waits: the wait is a waitable timer plus the message queue and ends at the first message, which is dispatched before the frame runs; at most 3 interruptions per frame so a stuck message cannot starve it. Cadence keeps its grid, no catch-up bursts. Minimized windows are not capped (the engine's own wake-up timer paces them). | `WinApp.cpp`, `EdPerf.cpp`, `EdPerfPolicy.h` | `ed_fps_throttle` 1, `ed_fps_limit` 300 (in use), `ed_fps_loading` 60 (map loading), `ed_fps_background` 60 (another program has the focus), `ed_fps_idle` 0 and `ed_idle_seconds` 10 (no input at all) | see left | Low. 300 is far above any monitor, so it only stops an unbounded loop. Background and loading caps do not touch what a user in front of the editor sees. **Idle is off**: a watched test run or a camera animation is "idle" too. Main thread only; no engine state is touched. |
| Main thread no longer pinned to one core | `WinApp.cpp` | `/edpin` on the command line restores | free | Low. Only the original's 2007 timer workaround is dropped; the clocks are QueryPerformanceCounter / steady_clock. |
| `SC_VerticalSync 0/1` applies its argument | `ResolutionCommands.cpp` | the editor's Vertical sync setting | - | Low. Same device reset as before; anything but "0" / "1" is ignored. |
| Threads get a system name (`SetThreadDescription`: `Sim`, `Issue`, `Map loader ...`, `Prefetcher thread.`) | `gpg/core/utils/Global.cpp SetThreadName` | - | - | None. Process Explorer / Process Hacker / profilers show the names; `ed_perf_threads` reports them. |
| Normal map update on the field pool: batches of 64 block rows, the loading progress (which throws on abort) stays on the calling thread; updates under 4096 blocks (brush dabs) stay serial | `CWldMap.cpp UpdateNormalMap` | `ed_par_normalmap` | 1 | Low. Pure reads of the height field, each row writes its own bytes; `EdNormalMapParTest` proves identical bytes for 1, 2, 3, 8 threads and batch sizes 1, 7, 64 on aligned, unaligned and clipped rectangles. The pool tolerates concurrent callers (the loader thread and the main thread): each caller runs all of its own items itself. |
| Forced full Lua collections gated: UI state (every 5 s) and sim state (every 70 ticks) run the collection only if the heap grew by 8192 KiB since the last one, or 60 s passed | `CUIManager.cpp`, `Sim.cpp`, `GcGate` in `EdPerfPolicy.h` | `ed_ui_gc_kb`, `ed_sim_gc_kb` (8192; **0 = always, the original**), `ed_gc_max_seconds` (60) | see left | Low-medium. An idle editor stops collecting (one collection a minute instead of one every 5 s); while the heap grows by 8 MB per 5 s or more (anything busy) nothing changes. Lua's own threshold (collect when the heap doubled) is untouched, so memory stays bounded. Native resources held by dead Lua objects (textures) wait at most 60 s instead of 5 s when nothing allocates. Each state's gate is touched by its own thread only. |
| Natives `ed_perf_loop([reset])`, `ed_perf_threads()`; `perf.lua` prints both in its report | `EdPerf.cpp`, `perf.lua` | - | - | None (read only). |

Tests: `EdPerfPolicyTest` (cap selection truth table, cadence, no drift, no catch-up burst, interrupted wait, the GC gate; 1088 checks, g++ here), `EdNormalMapParTest` (above; 577 checks, g++ here; `--bench` prints the model timings). Both are in `scripts/ed_native_tests.py`. `EdPerf.cpp` was syntax-checked against stubs only; `WinApp.cpp`, `D3D9Interfaces.cpp`, `CWldMap.cpp`, `Global.cpp`, `ResolutionCommands.cpp`, `CD3DDevice.cpp` were not compiled at all (no MSVC here).

### Recommended, not changed

1. **Skip redrawing a still picture** (the real fix for an idle editor's GPU and driver cost): needs a dirty signal the renderer can trust. Agent GC's `EdActivity.h` has the pieces (camera, overlay, heights, Lua touch, ambient animation). The pacer here already takes the cap from a `Situation`; a "still for 2 s" state would add a cap to `EffectiveCap`. Risk: ambient water and clouds move, so a lower rate for them is a visible change; keep it opt-in (`ed_fps_idle`-style) and never while the sim ticks (a test run).
2. **Per-tier parallel `UpdateErrorKernel`** and removing the second copy on the sim thread (the sim field could share the work of the view field in the editor).
3. **Persistent parsed blueprints / reading `.bp` data ahead on a worker** (the biggest startup block, serial Lua; see "Startup" above).
4. Delete the two `faf_diag.log` probes in the editor build (`SimDriver.cpp`, `Sim.cpp`); cheap, but they open and close a file on the sim threads. A full collection is still a pause when it does run: an incremental setting (`lua_setgcthreshold` with a pause factor, or `LUA_GCSTEP` slices per frame) would remove the hitch itself; it changes the collector's behaviour for the whole UI, so it needs profiling first.
5. **Overlap `MapLoad` with the Lua / rules part of `WorldSessionUserLoad`** (terrain and props do not depend on the rules object): a real multi-core win for the load, but the Lua state is passed into `MapLoad` and D3D resources are created in it. High risk, needs profiling first.
6. `res_AfterPrefetchDelay` / `res_PrefetcherActivityDelay` experiments for faster texture warm-up (console variables, no code).
7. `sc_FrameTimeClamp` is dead in this engine; if you want a hard cap without the editor's limiter, use `ed_fps_limit`.

### How to measure on your machine

Do the A/B in the same state (map open, camera still, window in front), 30 s each, and write down the main thread's CPU %.

* **Per thread CPU:** Process Explorer / Process Hacker, the process's Threads tab (Task Manager only shows the process total). Threads are named now (`Sim`, `Issue`, `Map loader ...`). In the editor: the performance report (command palette *Performance timing: on*, or `/perf`) prints `engine loop: ... fps (cap, state, vsync), frame ms: logic, paint and messages (Present, render), limiter wait, OS wait` and `threads, percent of one core: <name> N% ...` every 5 s (the thread line is empty the first time: it needs two samples). From Lua: `ed_perf_loop()` and `ed_perf_threads()`.
* **Reading `ed_perf_loop`:** `presentMs` high with a main thread near 100 % = the driver spins inside Present or the old query loop is on; `waitMs` is what the limiter slept (a healthy capped editor shows most of the frame there); `mainMs` is the frame's logic (sim sync, UI Lua), `renderMs` the CPU time recording the frame.
* **Toggles:** `ed_present_wait 0` (the old spin), `ed_fps_throttle 0` (no limiter), `ed_fps_limit 0`, `ed_par_normalmap 0`, `ed_ui_gc_kb 0` / `ed_sim_gc_kb 0` (forced collections every time, as before), `/edpin` (pinned main thread), `ed_field_threads 1`. The Lua heap line of the performance report shows the forced collection as a sawtooth every 5 s before and none while idle after. Vsync on/off is in Settings (it works now).
* Expected, **not measured**: with vsync on and the old code the main thread sat near 100 % [guess]; with `ed_present_wait 1` it should drop by about the share of the frame the GPU was behind. With vsync off the limiter bounds the rate at 300 fps. A full map load or whole map edit on a 1025+ map should be shorter by the normal map's share (est. 0.1 s per 1025 map on one core).

### Could not verify

No editor, no MSVC, no GPU here. Not run: every engine change in the editor; the high resolution timer path and its fallback; that `MsgWaitForMultipleObjectsEx(..., QS_ALLINPUT, 0)` ends on the first message in the editor's wx loop (it is the same API call and mask the original wait uses, `CWaitHandleSet.cpp:292`, with flags 0 instead of ALERTABLE | INPUTAVAILABLE: only messages that arrive after the loop last looked wake it); the claim that the query spin is what a real driver shows as 100 % (the code spins; whether a driver burns CPU inside `Present` as well is a driver question); that unpinning does not move the main thread onto an efficiency core on hybrid CPUs (Windows keeps a foreground thread on a performance core in practice). Single player creates its client manager without a connector (`SessionStartup.cpp:1402`, `CLIENT_CreateClientManager(1, nullptr, 0, true)`), so there is no UDP thread or socket traffic in a plain editor session [code]; `createReplay` is read from the launch data (`SessionStartup.cpp:633`) and the editor passes false. All cost numbers marked "est." are estimates from loop counts.
