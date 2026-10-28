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

Audit of the native side: main loop, frame pacing, threads, sim, loading (author: agent EC, 2026-10). Method: reading the reconstructed engine (`engine/faf-re/src`), our patches and the init files. **Nothing was measured** (no editor, no MSVC, no profiler in the audit environment); the engine changes compile only on the user's machine. Confidence marks: **[code]** = read in the source, certain what the code does; **[guess]** = a conclusion about behaviour on real hardware or drivers that the code cannot show; **[model]** = measured on a stand-alone model of the loop on a 4 core Linux box, not in the editor.

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

## GPU and render

Audit of what the editor renders and what that costs the GPU and the render thread's CPU (author: agent GC, 2026-10). Method: reading the reconstructed engine (`src/moho/app/WxRuntimeTypes.cpp` `WRenViewport::Render`, `render/Shadow.cpp`, `terrain/`, `ui/UiRuntimeTypes.cpp`, `render/d3d/CD3DPrimBatcher.cpp`, `CD3DTextureBatcher.cpp`, `editor/EdOverlay.cpp`, `EdTextBackend.cpp`) and the shaders (`effects/mesh.fx`, `primbatcher.fx`). **Nothing was measured** (no editor, no MSVC, no GPU profiler in the audit environment): every size below is an estimate from counts and formats, marked "est." (derived from code) or "guess" (depends on hardware or on a number the code does not give). Rule used for every change: the picture stays the same (identical, or identical except for the case named in the table), every change has a console variable that switches it off, and nothing throttles the frame rate (the pacing is the other section's business: agent EC owns the main loop). The user's rule applied: use the GPU fully while somebody works, remove only work whose result nobody sees.

### The pipeline as found

`CD3DDevice::Paint` presents the last frame and calls `WRenViewport::D3DWindowOnDeviceRender` -> `Render(head, views)`, which draws, in this order (Ultra settings, one world view, water on):

| # | Pass | Where | Per frame, whatever the camera does? | Notes |
|---|---|---|---|---|
| 1 | clear, Maui "frames" pass (`RenderFrames`, drawMask 1) | `CUIManager::RenderFrames` | yes | draws the control tree's mask-1 controls (backgrounds) |
| 2 | sky dome: atmosphere, sky decals, cirrus, cumulus | `RenderSkyDome` | yes | full screen fill; the terrain draws over most of it later (overdraw, see "Recommended, not done") |
| 3 | `UpdateRenderContext` | `HighFidelityTerrain` | **only when the camera moved**, the decal manager has pending changes (the editor raises it after height edits), or the terrain is in edit mode (never outside `Finalize`) | the tessellator rebuild and the vertex/index upload (DISCARD locks) happen only then; a still camera costs nothing here. Checked: `IsInEditMode()` is true only inside `CWldTerrainRes::Finalize` |
| 4 | terrain normals (`RenderTerrainNormals`) + basis (`TransformTerrainNormals`) | `HighFidelityTerrain::DrawTerrainNormal`, `CRenFrame` "TCreateBasis" | yes | normal tiles into the screen sized secondary target, then one full screen pass into the primary target |
| 5 | **shadow pass** | `Shadow::RenderFrameShadows` | yes (before this change) | `MeshRenderer::Batch` for the light camera, depth pass of every mesh in the light frustum, two separable variance blur passes over the whole shadow map (2048 x 2048 on Ultra), 3 render targets of that size. The light frustum follows the view camera |
| 6 | terrain composite + decals + skirt | `RenderCompositeTerrain` -> `DrawNormals`, `DrawTerrainSkirt` | yes | strata shading ("fidelity 2" = `HighFidelityTerrain`, the heaviest pixel shader of the frame), shadow lookups, decal passes |
| 7 | `MeshRenderer::Batch` (view) | `Render` | yes | CPU: spatial query, LOD, `UpdateInterpolatedFields`, bone palette write + upload |
| 8 | **reflection pass** (`RenderReflections`) | `Render` | yes while `ren_Water` | clears the reflection target and draws every reflected mesh a second time, **also on a map whose water is off** (before this change) |
| 9 | meshes (buckets 0x14, 0x18), effects | `RenderMeshes`, `RenderEffects` | yes | hardware instanced already (`HardwareMeshBatch`: one draw per bucket, instance records in one NOOVERWRITE ring buffer) |
| 10 | water mask, **full screen copy for refraction**, water surface, water albedo decals | `RenderWaterMask`, `RenderCopyForRefraction`, `RenderWater` | yes (before this change, also with water off: the surface quad sat at -10000 and was rejected by the depth test) | the copy is a `StretchRect` of the whole back buffer at fidelity 2 |
| 11 | playable boundary, selection UI, meshes 0x24/0x28, effects, fog of war, refracting effects (a second back buffer copy), the world view's own overlay (`edoverlay::Render`) | `Render` | what exists | the editor overlay is the last 3D thing |
| 12 | Maui "draw" pass (`DrawUI`, mask 4), bloom (off in every preset), `RenderUI` | `CUIManager::DrawUI` | yes | every visible control: bitmaps, borders, texts (glyph quads) |
| 13 | `EndScene`; `Present` at the start of the next paint | `CD3DDevice::Paint` | yes | vsync on by default (`SC_VerticalSync 1`): the swap chain paces it |

Two things the engine already does well (checked, no action): the terrain mesh and its uploads only change with the camera, and meshes are drawn hardware instanced (`DrawBatch`, 2nd stream per instance, the bones of all skinned instances in one palette texture uploaded once per `Batch`).

### Graphics settings the editor applies (`graphics.lua`, Ultra defaults) and what they cost

| Setting (console variable) | Ultra value | What it does to the frame | Hidden cost that does not change the look? |
|---|---|---|---|
| Fidelity (`graphics_Fidelity`) | 2 | `HighFidelityTerrain` + `HighFidelityWater`: strata layers in the terrain pixel shader, normal basis passes, refraction copy, water mask | the water passes ran with water off: **fixed** (`ren_WaterSkipDisabled`). The rest is the look itself |
| Shadows (`shadow_Fidelity`) | 3 | shadow map pass above; the map is re-drawn every frame | **fixed** for a still scene (`ren_ShadowCache`) |
| Shadow resolution (`ren_ShadowSize`) | 2048 | 3 targets of 2048 x 2048 (map, two blur targets); the blur passes dominate the GPU cost of the pass | cached with the map |
| Shadow distance (`ren_ShadowLOD`) | 440 | shadows exist up to a camera zoom of 440 instead of 250: the pass runs at more zoom levels | no |
| Texture detail (`ren_MipSkipLevels`) | 0 | full mip chains | no (VRAM, not time) |
| Model detail (`SC_CameraScaleLOD`) | 2 | longest LOD distances | no |
| Bloom (`ren_bloom`) | **off in all four presets** | nothing: `DoBloom` is skipped (when on: a blit to half size, 4 blur passes at half size, one additive full screen pass) | n/a |
| Anti-aliasing (`SC_AntiAliasingSamples`, or the state FXAA = `ed_fxaa`) | 0 (off) | nothing; FXAA: the frame goes into an off-screen target, one copy + one full-screen pass before the UI, 0.057 ms GPU at 1080p (FXAA.md) | n/a |
| Vertical sync (`SC_VerticalSync`) | on | the swap chain paces the loop at the monitor rate | the right default; the pacing is EC's section |

### Cost centres

Sizes: "est." from counts and formats in the code; "guess" depends on hardware.

| What | Where | GPU / CPU submit | Size | Cut without changing the look? | Risk | Action |
|---|---|---|---|---|---|---|
| Shadow depth pass + two blur passes every frame | `Shadow::RenderShadowMap` | both | blur: 2 passes x 4.2 Mpx = 8.4 Mpx of multi tap filtering (guess 0.3-1.5 ms on a mid range GPU); depth pass: every mesh in the light frustum (trees dominate on forest maps); memory: 3 targets of 2048^2 (est. 100 MB at 8 B/texel, the format token 7 is not decoded here) | **yes, for a still scene** | medium: a stale map is visible | **done**: `ren_ShadowCache` (signature of the batched scene + light camera + settings + targets; a time dependent depth technique is never held; a held map expires after `ren_ShadowCacheMaxAge` frames) |
| `MeshRenderer::Batch` twice per frame (light, view) | `RenderShadowMap`, `Render` | CPU | spatial query + LOD + interpolation for every instance in each frustum (est. 50-150 ns per instance) | no (the shadow batch is needed for the signature) | - | recommended: share one collect between both (see below) |
| Reflection pass on a map without water | `RenderReflections` | GPU + CPU | the whole mesh set drawn a second time + a clear of colour and depth | **yes** | low | **done**: `ren_WaterSkipDisabled` |
| Refraction copy, water mask, water surface with water off | `RenderCopyForRefraction`, `RenderWaterMask`, `HighFidelityWater::RenderWaterSurface` | GPU | one full screen `StretchRect` (est. 8-32 MB at 1080p-4K) + a map sized quad that is depth rejected | **yes** (except below the terrain skirt seen from outside the map: the -10000 plane used to show there) | low | **done**: same variable |
| Water with water on: reflection pass, refraction copy, surface | same | GPU | as above, plus the water shader at fidelity 2 | not without a visibility test | - | recommended: skip when the terrain's lowest point is above the water elevation (needs the height field's minimum, kept up to date after edits) |
| Sky dome under an opaque terrain | `RenderSkyDome` | GPU | 2-3 full screen fills (atmosphere, cirrus, cumulus; est. 0.1-0.5 ms at 4K, guess) | yes, if no sky pixel can be visible | medium (map edges, canyons, low cameras) | recommended, not done |
| Terrain normal buffer + basis pass | `RenderTerrainNormals`, `TransformTerrainNormals` | GPU | terrain draw into a screen sized target + one full screen pass | only with persistent targets (the normal/basis targets are reused by the reflection pass and the refraction copy later in the frame) | medium | recommended, not done |
| Back buffer copies: refraction (water) and refracting effects | `RenderCopyForRefraction`, `RenderRefractingEffects` | GPU | 2 full screen copies | no (the water shader reads the copy) | - | none |
| Maui controls on hidden tabs / off screen | `CMauiBitmap::DoRender`, `CMauiText::DoRender`, `CMauiBorder::DoRender` | CPU (+ atlas pressure) | the tab holder of a panel behind another tab is parked at (-20000, -20000) with all its controls (`dock.lua HideHolder`: `Hide()` alone is not enough, Maui shows a child again that is shown explicitly), the graph panel parks node views outside the canvas the same way (`Gone`), panels park the other kind of a setting at x = -4000. **All of them were walked, laid out, looked up in the atlas, put into it, built into quads, queued, uploaded and clipped by the GPU, every frame.** est. 100-300 ns per control or glyph (atlas lookup with two atomic operations + ~10 compares, 4 vertices, 6 indices, upload of 108 bytes); with a few thousand parked controls and ten thousand parked glyphs this is a millisecond or more per frame (guess; `ed_render_stats` `uiBitmapsCulled + uiTextsCulled` tells the count) | **yes** (a quad outside the window covers no pixel) | low | **done**: `ui_CullOffscreen`, `ui_SkipTransparent` |
| Atlas lookup per bitmap / glyph | `CD3DTextureBatcher::AddTexture` | CPU | est. 150-200 ns (shared_ptr copy = 2 atomic ops, ordered set walk) per quad | yes | low | **done**: `ren_AtlasFastLookup` (hash on the texture address, est. 20-30 ns) |
| Text: layout cache key built as a `std::string` every call, one hash lookup per glyph per frame, 2 `QueryPerformanceCounter` per string | `EdTextBackend.cpp` | CPU | est. 100-300 ns per string + 30-50 ns per glyph | yes | low | **done** (no switch: pure caching) |
| Overlay quads of the slope view / grids / fields (up to ~120k quads) | `edoverlay::Render` -> `DrawDrapeQuads` -> `CD3DPrimBatcher::DrawQuad` | CPU, upload | per quad 4 vertices (24 B) + 6 indices: 108 B through two copies (queue, then the locked buffer): 13 MB per frame for 120k quads; GPU side is cheap (about one layer of translucent pixels, no overdraw to speak of) | partly (see "Overlay") | - | counters added, no change |
| Maui tree walk before drawing | `CMauiControl::Render` -> `RefreshDepthLaneForSubtree` | CPU | walks **every** control of the tree each frame, hidden ones included (a lazy var read per visible one); est. 20-50 ns x controls | not without changing which controls get their depth refreshed | medium | recommended, not done |
| Splat vertex upload | `DrawSplatComposite` | CPU, upload | the whole splat lane is copied into a DISCARD buffer every frame when splats exist (units' tracks: none in the editor) | - | - | none |
| Full redraw of an unchanged picture at the display rate | `CD3DDevice::Paint` | everything | all of the above | only with a trustworthy "nothing changed" (water, clouds move) | medium | **signals added** (`ed_scene_*`), the cap is EC's: see "Still picture" |

### What was changed

All switches are console variables (type them in the Console panel, or `ConExecute`); each default gives the same picture as before.

| Change | Switch (default) | Where | Same picture? | What it removes | Risk / what to watch |
|---|---|---|---|---|---|
| **Shadow map cache.** The pass collects the scene for the light camera as before (`Batch`), then signs it: one hash per instance over mesh, LOD, transform, scale, colour, parameters, dissolve, scroll, shader time, plus the bones of the skinned ones (`BonePaletteTexture::WriteInstance` sums a hash of each instance's bones while `gAccumulateBones` is set), added up so the spatial db's order does not matter. If the light view projection (bit for bit), size, fidelity, blur, owner and the three target objects are the same as when the held map was drawn, the depth pass and both blur passes are skipped and the render target is used as it is | `ren_ShadowCache` (1); `ren_ShadowCacheMaxAge` (300: a held map is drawn again after that many frames, a safety net); `ren_ShadowCacheTrees` (0) | `Shadow.cpp` `RenderShadowMap`, `EdShadowCache.h` (logic, tested), hooks in `Mesh.cpp` `RenderDepth` and `HardwareMeshBatch.cpp` | yes: the depth techniques that read the clock (`UndulatingDepthClip`, the swaying trees; any technique the code does not know) are never held (`ren_ShadowCacheTrees 1` holds them too: the sway is `0.003 * y * sin^2` x wind, a fraction of a texel) | depth pass + 2 blur passes + their draw calls, on every frame the scene and the camera are still | **the first thing to check if a shadow looks stale** (`ren_ShadowCache 0`). A still scene needs a bit identical camera: if `shadowReused` stays 0 with a still camera, the camera's matrices drift in the last bits (see `ed_render_stats`) and the cache simply does not help. Not signed: anything the depth pass would read that is not a `MeshInstance` field (none found; the terrain is not drawn into the map in this build: `terrain` is unused in `RenderShadowMap`; if `DrawTerrainDepth` is ever called there, add the heights epoch to the key). A scene with skinned instances while the mesh effect has no bone texture cannot be signed and is drawn every frame |
| **Cleared shadow targets stay cleared.** In a frame without a valid light camera (zoomed out beyond `ren_ShadowLOD`, e.g. a whole-map overview) the pass cleared all three targets every frame; now it clears once and leaves them while they are the same objects and nothing was drawn into them | `ren_ShadowCache` (1) | `Shadow.cpp`, `EdShadowCache.h` `StillCleared` | yes | three clears of 2048^2 targets per frame (est. 100 MB of writes) | low |
| **Water passes off with water off.** Reflection pass, water mask, refraction copy and the water surface draw are skipped when `STIMap::mWaterEnabled` is 0. The water albedo decals still draw (they are terrain geometry drawn in the water pass), the fog state set before the water pass is kept | `ren_WaterSkipDisabled` (1) | `WxRuntimeTypes.cpp` `Render` + `WaterPassesWanted`, `HighFidelityWater.cpp` / `LowFidelityWater.cpp` `RenderWaterSurface` | yes, except one case: below the terrain skirt, seen from outside the map, the -10000 water plane used to be visible as a dark band | the mesh set drawn twice, a clear, a full screen copy | low. Switching `water_on` takes effect on the next frame (the flag is read every frame) |
| **Maui culling.** A bitmap or border whose rectangle lies completely outside the window, or whose vertex alpha is 0, and a text run that starts right of the window / whose baseline is 256 px or more above or below it / that ends left of it, is not laid out into quads, queued, or put into the atlas (the window size comes from `CD3DPrimBatcher::SetToViewport`, reset at its start so a head that returns early is never culled with another head's size) | `ui_CullOffscreen` (1), `ui_SkipTransparent` (1) | `UiRuntimeTypes.cpp` `CMauiBitmap/CMauiText/CMauiBorder::DoRender`, `EdUiCull.h` (tested), `CD3DPrimBatcher.cpp` | yes: alpha = tex.a x colour.a x AlphaMultiplier with alpha test > 0 and SrcAlpha blending in every UI technique; a quad outside [0, w] x [0, h] covers no pixel | the work of every parked / hidden / transparent control, and the atlas space their pictures took | low. A bitmap with alpha 0 no longer evaluates its layout lazy vars (they are evaluated when something asks). Other control types (groups, edit boxes, lists, scroll bars, world views) are untouched |
| **Atlas lookup by address.** A hash from texture pointer to its UV rectangle in front of the ordered set; dropped on `Reset` and destruction | `ren_AtlasFastLookup` (1) | `CD3DTextureBatcher.cpp` | yes (a texture held by an atlas entry stays at its address; set nodes do not move). One side effect: a file texture the engine wraps twice (the `OnClose` re-wrap) is no longer added to the atlas twice | est. 130-180 ns per quad | low |
| **Text backend.** Layout cache lookup by `string_view` (no `std::string` per call), the glyph bitmaps of a layout resolved once per sub-pixel phase (a pointer per glyph, no hash lookup per glyph per frame), the two timer reads per string only after `ed_text_stats` was first called | none (pure caching) | `EdTextBackend.cpp` | yes | est. 100-300 ns per string, 30-50 ns per glyph | low; `ed_text_stats` numbers start timing with its first call |
| **Counters.** `ed_render_stats()` (table of the last frame, see "How to measure"), the render report in `perf.lua`, `overlayMs/overlayFlushes/overlayVertices` for the editor's overlay | - | `EdRenderStats.h/.cpp`, `Shadow.cpp`, `CD3DPrimBatcher.cpp`, `UiRuntimeTypes.cpp`, `EdOverlay.cpp`, `perf.lua` | - | - | none (counters; a few `steady_clock` reads per frame) |
| **Activity signals** for the pacer: `ed_scene_dirty([consume])`, `ed_scene_activity()`, `ed_scene_touch([reasons])` | - | `EdActivity.h/.cpp`; every `ed_overlay_*` setter and `NotifyHeights` raise it | - | - | none; nothing in the engine uses them yet |

Tests: `EdRenderOptTest` (98 checks, g++ here, `scripts/ed_native_tests.py` runs it with MSVC): the hash (single-ulp change always seen, no collision in 100,000, order independent sum), the cache decision (every part of the key, age limit, time dependent maps, invalidation), a 20,000 frame model of scene / camera / wind changes that checks the held map is never different from a fresh draw, the rectangle and text tests (agree with rectangle intersection on a grid, NaN and unknown viewport never culled), the activity tracker and tick arithmetic. `g++ -fsyntax-only` with stubs: `EdOverlay.cpp`, `EdActivity.cpp`, `EdRenderStats.cpp`, the heterogeneous lookup of the text backend. **Not compiled with MSVC**: `Shadow.cpp`, `Mesh.cpp`, `HardwareMeshBatch.cpp`, `WxRuntimeTypes.cpp`, `UiRuntimeTypes.cpp`, `CD3DPrimBatcher.*`, `CD3DTextureBatcher.cpp`, `CUIManager.cpp`, the two water files, `EdTextBackend.cpp` (their dependencies - boost 1.34, wxWidgets, LuaPlus - are not in this environment): reviewed line by line instead; expect to fix a typo on the first build if I missed one.

### Overlay (`EdOverlay.cpp`): draw call organisation

Read in full. The layers are drawn in this order, each ending with one `Flush`: decals (one flush per texture), slope view, build grid, value grids, field overlays (all four with the depth tested `TEdGroundOverlay` technique), then halos + lines, then icons (one flush per texture). The prim batcher queues up to 32768 vertices (8192 quads) per flush, so 120k quads are 15 draw calls; a layer boundary costs one extra partial draw (the `groundPass()` / `flatPass()` flush) - **3 to 5 draw calls per frame in all**. Merging layers into one queue would save at most 3 draw calls (est. 30-100 us of driver time each), so the draw call organisation is not worth touching; the three solid colour texture lookups per layer are now hash hits. What the overlay does cost is CPU: the cached quads (the slope view keeps them while camera, heights and ratings are unchanged) are rebuilt into vertices every frame, 108 bytes per quad through two copies. Recommended (not done, needs a build and a look): keep the layer's vertices in a static vertex buffer while its cache is valid and draw that (zero per frame CPU for a still camera; the atlas UV of the solid colour texture is baked into the vertices, so the buffer must also be dropped when the atlas resets - `ed_render_stats().atlasResets` - and the batcher needs an entry that does the shader variable setup of `Flush` without the upload). The editor's lines and icons are a handful of quads. Marker meshes and placer ghosts are `MeshInstance`s: instanced by `HardwareMeshBatch` already. `ed_render_stats().overlayMs / overlayFlushes / overlayVertices` give the overlay's share of the frame.

### Vertex buffer handling (checked)

| Buffer | Lock flags | Verdict |
|---|---|---|
| Prim batcher vertices (UI, text, overlay, ranges) | 3 sheets in a ring, `Lock(0, n, false, true)` = DISCARD each flush, only the used part is copied | fine |
| Prim batcher indices | one sheet, DISCARD each flush | fine (could be a static quad index pattern for quad-only batches: saves 12 bytes per quad; not worth it) |
| Mesh instance records | one ring buffer shared by all batches, NOOVERWRITE, DISCARD only on wrap | fine |
| Bone palette texture | DISCARD lock, once per `MeshRenderer::Batch` (twice per frame: light, view) and again only if a draw needs bones nobody prepared | fine; the shadow batch's upload is wasted when the shadow map is reused (the bones are written to the CPU copy and uploaded by the next draw that needs them: skipped now) |
| Terrain vertices / indices | DISCARD, only when the tessellator was rebuilt (camera moved or height edit) | fine |
| Splat vertices | DISCARD copy of the whole lane every frame when splats exist | none in the editor |
| Atlas sheets (UI 1024^2 DXT5, glyph 2048^2 A8R8G8B8) | `Lock` of the whole sheet and a full copy of the CPU mirror whenever a texture was added (`mDirty`) | **watch**: adding one glyph uploads 16 MB for the glyph atlas. Steady state is free; the cost shows as a hitch the first time a new string appears, and every frame if the atlas thrashes (`atlasResets` > 0 in `ed_render_stats`). The parked controls used to put their pictures into the atlas; culling them lowers the pressure |
| Height edits | `UpdateNormalMap(rect)` per 4 x 4 block row clipped to the tile, the rectangle padded by 2 (patch 0051), large updates on the worker pool (EC's `ed_par_normalmap`); error grids by `UpdateError(rect)` | fine; the water map is rebuilt for the **whole map** when a water slider is released with refresh (`ed_world_set(t, true)` -> `UpdateWaterMap()`): a hitch per change, not per frame |

### Still picture (what the pacer can use)

The recovered main loop redraws the window at the display rate even when nothing changes. `EdActivity.h` provides the signals; EC's pacer (`EdPerf.cpp`, `EffectiveCap`) is where they would be used; nothing calls them yet.

* `ed_scene_dirty([consume=true]) -> epoch, reasons, ambient`: the epoch grows with every change; `reasons` (bits 1 camera, 2 overlay, 4 heights, 8 script) are the ones raised since the last consuming call; the world camera is compared when called (view projection and viewport, bit for bit); every `ed_overlay_*` setter and `NotifyHeights` raise the bits; Lua marks other changes with `ed_scene_touch(reasons)` (tool strokes, history steps, panels that change the picture, async work that updates the UI). `ambient`: 1 the map has water, 2 the sky dome is drawn, 4 the simulation ticked since the last call. These never stop, so they are reported apart from `reasons`.
* `ed_scene_activity() -> { idleMs, focused, sinceChangeMs, inputs, wait }`: `idleMs` since the last keyboard or mouse input of the system, `focused` (a window of this process is in front), `sinceChangeMs`, the number of input changes seen by the polls, and `wait` = `RecommendedWaitMs(...)` for a hold time of 2 s.
* Proposed policy (`EdActivity.h RecommendedWaitMs`, tested): full rate (no wait) when anything happened in the last 2 s, when a change is pending, or when the simulation ticks (a test run); otherwise at most 33 ms between frames if water or clouds are on screen, 100 ms if nothing moves. The wait must stay interruptible by any window message, as EC's limiter already is, so the first mouse move gets the full rate back with no latency. This is a change of what the user may see (30 Hz water instead of 60 Hz or more after 2 s of no input), so it should be opt-in or at least one switch (`ed_fps_idle`-style), and EC decides. Poll `ed_scene_dirty` once per loop iteration (a camera lookup and a 128 byte compare).
* A frame that is truly skipped (no render, no present) is only correct when `ambient == 0` and `reasons == 0`; with water on that case does not occur, so the useful saving is the lower rate, not the skip.

### Recommended, not done (ordered by expected value)

1. **Share one `MeshRenderer::Batch` between the shadow pass and the view** (CPU, est. 0.2-1 ms on a prop heavy map): the light frustum's instances are mostly the same as the view's; one collect over the union and a cull per use would halve the spatial query. Needs care: `Batch` writes the buckets, LOD choice depends on the view's fade plane, and `RenderDepth` / `Render` read the same `meshes` map.
2. **Retained vertex buffer for the overlay layers** (CPU 1-4 ms per frame while a big slope / grid view is up and the camera is still; est.): see "Overlay".
3. **Skip the sky dome when the terrain covers the whole window** (GPU, est. 0.1-0.5 ms at 4K, guess): safe predicate = every pixel ray of the frustum hits the map's rectangle going downward and the camera is above the surface; the skirt and the map border need a margin. Risk is a missing sky strip at a map edge, so it needs a look at a real map.
4. **Persistent terrain normal and basis targets** so passes 4 can be skipped for a still camera (GPU, est. 0.3-1 ms): the secondary and primary targets are reused by the reflection pass and the refraction copy later in the frame; two more screen sized targets are needed (2 x 8 B x pixels).
5. **Skip the water passes when the terrain's lowest point is above the water elevation** (needs the height field's global minimum, kept up to date after edits; `CHeightField` has min/max tiers).
6. **Skip walking hidden subtrees in `RefreshDepthLaneForSubtree`**: not safe as it stands, because Maui can show a child under a hidden parent (the comment in `dock.lua HideHolder`); the controls that are parked still cost a visit each frame. Fixing it in Lua (destroy or really hide holders) is cheaper than a change in the walk.
7. **A bulk quad path** in the prim batcher for the overlay's cached quads (write vertices and the fixed 0,1,2,2,3,0 index pattern straight into the queue): est. 1.5-2x on the 30 ns per quad submission; superseded by item 2.
8. **Upload only the changed rows of the glyph atlas.** `GetCompositeTexture` copies the whole CPU mirror (16 MB for the 2048^2 A8R8G8B8 glyph atlas, 1 MB for the UI atlas) into a DISCARD lock whenever one texture was added; a frame in which a panel with new strings opens costs a few ms for it (est.). Keep the first and last row of the added rectangles and use `CD3DDynamicTextureSheet::LockRect` (no discard) for those rows. Low risk, needs a build to check the lock behaviour of the dynamic texture.
9. **`Shoreline::Update` every frame**: `HighFidelityTerrain::UpdateRenderContext` calls it (spatial query + a DISCARD upload of the visible shore triangles) even when the camera did not move. It could follow `dirty || decalsDirty || forceRegenerate`, but the vertex buffer's content is lost on a device reset, so the skip needs the sheet's identity in its key (like the shadow cache's target pointers). Est. 0.05-0.3 ms on a map with long shores.
10. **`ren_ShadowCacheTrees 1`** by default on forest maps: the sway of the shadow is a fraction of a texel, the saving is the whole pass on maps with trees in the light frustum (where the strict cache never hits). Try it, look at the shadows of trees, and set it if you cannot tell.

### How to measure

* **In the editor:** `ed_render_stats()` returns a table for the last frame; `perf.lua` prints it every 5 s with `/perf` (or the "Performance timing" command): `render (last frame)`, `ui controls`, `shadow map`. Fields: `drawCalls primitives vertices` (everything the graphics backend got; the same numbers `FAF_DRAW_STATS_LOG=<frames>` logs), `batcherFlushes batcherVertices` (the prim batcher: UI, text, overlay; quads = vertices / 4), `overlayMs overlayFlushes overlayVertices`, `uiMs`, `uiBitmapsDrawn/Culled/Transparent uiTextsDrawn/Culled uiBordersDrawn/Culled`, `atlasLookups atlasFastHits atlasAdds atlasResets`, `shadowRendered shadowReused shadowMs shadowSceneMs`, `waterSkipped`, `renderMs`, and since the start `shadowHits shadowMisses waterSkippedFrames frames`. The ms values are CPU time on the render thread, not GPU time.
* **A/B, same map, camera still, window in front, 30 s each:** `ren_ShadowCache 0/1`, `ren_WaterSkipDisabled 0/1`, `ui_CullOffscreen 0/1`, `ui_SkipTransparent 0/1`, `ren_AtlasFastLookup 0/1`; read the GPU engine graph in **Task Manager** (Performance > GPU > "3D" and the per engine view in the Details tab: GPU engine column; the "Copy" engine should stay near 0) or **GPU-Z / HWiNFO** sensors ("GPU load"). Expect (guess): a still scene with shadows on: GPU load drops by the share of the shadow pass (the blur passes dominate); a water-off map: the reflection pass and a full screen copy disappear; CPU: `uiMs` drops with the number of parked controls.
* **Expected readings:** with a still camera `shadowReused` is 1 on all but one frame in `ren_ShadowCacheMaxAge`; with swaying trees in view it stays 0 (then try `ren_ShadowCacheTrees 1`); `uiBitmapsCulled + uiTextsCulled` is the number of parked controls that no longer cost anything; `atlasFastHits / atlasLookups` should be close to 1; `atlasResets` should be 0 in steady state.
* **A frame capture** (what the GPU really does per pass): the game is Direct3D 9, so use **PIX for Windows (the DirectX SDK June 2010 version)** or **apitrace**; RenderDoc does not capture D3D9 directly (guess: running the editor with the DXVK `d3d9.dll` next to the exe makes it a Vulkan application that RenderDoc can capture; untested here). In a capture look for: the 2048^2 shadow targets and their two blur draws, the screen sized terrain normal target, the two `StretchRect` copies, the sky dome draws at the top, and how many draws come from the prim batcher (UI: one per texture/technique change, so a handful).
* **Draw call organisation of the UI:** `batcherFlushes` of a typical frame should be single digits to a few dozen (atlas switches, the text technique switches `TTextLcd` <-> UI technique, direct textures larger than half the atlas); a figure in the hundreds means atlas thrashing (`atlasResets`) or many large textures.

### Could not verify

No editor, no MSVC, no GPU, no profiler. Not run or compiled: every engine change in this section (confidence that the logic is right: high for `EdShadowCache.h` / `EdUiCull.h` / `EdActivity.h` (tested); medium-high for the water skip, the Maui culling and the atlas shortcut (small, local, reviewed against the code they sit in); medium for the shadow cache wiring, because the signature has to cover every input of the depth pass and I could only read, not observe it - the safety nets are the time dependent technique rule, the age limit and the switch); **none of the cost numbers is measured**. Not checked: that the UI client size equals the Maui coordinate space on a DPI scaled window (the code treats them as the same, as `SetToViewport`'s own projection does); whether `GetLastInputInfo` sees input for a window in a remote session; the format behind the shadow target token 7. Unfinished from the task list: no draw call merging in the overlay (analysed, not worth it), no retained overlay buffers, no sky dome cull, no shared `Batch`, no use of the activity signals by the main loop (EC's), no GPU timestamp queries (would need a `D3DQUERYTYPE_TIMESTAMP` wrapper in the gal device; `ed_render_stats` therefore reports CPU time only).

## GPU compute (field ops)

Heavy field ops (blur and box today; erosion and generators planned) can run on a separate Direct3D 11 compute device with a CPU fall-back for every failure. Design, kernel language, how to add a kernel, threading rules and the steps to verify it on a machine: [GPU_COMPUTE.md](GPU_COMPUTE.md). The perf report prints `field ops: gpu: N ops ...` (which backend ran how many field ops, and how long); `dev.gpu` shows the adapter and runs the self test. Nothing of it has been run on a GPU yet.

## Measured on the desktop and hybrid-laptop work (2026-10-26)

First measurements with the editor running (AMD Radeon RX 7900 XTX desktop, 100 Hz monitor, blank 2049 map, Ultra graphics; `ed_perf_loop`, `ed_perf_threads`, `/perf`):

| What | Measured |
|---|---|
| An idle scene | 230-240 frames/s although vsync was on (the driver did not block in Present), frame 4.2 ms of which Present 3.4 ms; main thread 22-27 % of one core, `Sim` thread 1 %, Prefetcher 1-3 %, one driver thread 6 % |
| CPU per frame | editor logic 0.2 ms (UI tick 0.07, overlay 0.06), recording the frame 0.45-0.55 ms: the CPU is not the limit, the GPU's work for a still picture drawn 230 times a second is |
| Whole-map height commit, 2049 x 2049 | 267 ms (undo 187 ms); the normal map already runs on the pool |
| Start to ready (blank map, process start included) | 13 s on a 1025 map, 18 s on a 4097 map |

What follows from it: for an editor the GPU cost is frames nobody needs, not missing threads. Changes (`engine/faf-re`, branch `editor`):

* **Frame cap follows the monitor** (`ed_fps_refresh`, default 1): the active cap is the refresh rate of the monitor the window is on + 5 percent, so a driver that does not block in Present (hybrid laptops, vsync off) cannot draw frames nobody sees. The 5 percent keeps the cap from beating against vsync.
* **Idle cap 60** after 3 s without input (`ed_fps_idle` 60, `ed_idle_seconds` 3; both were off / 10 s). Water and clouds still move at 60; the first key or mouse event lifts the cap at once. A 144 Hz laptop panel at Ultra settings drew 2.4 times as many pictures for a still scene.
* **No device Reset for nothing** (`SyncSupComFrameClientSizeAndViewport`): nothing happens while the window is minimized, and maximizing or restoring a window whose back buffer already has the size no longer releases and recreates every render target, shadow map and dynamic texture. Hypothesis (from reading the code, not yet confirmed on the laptop): on an NVIDIA + Intel laptop that Reset also rebuilds the cross-adapter copy to the display, which is where "seconds of flicker, invisible UI" after minimize / maximize come from. On the desktop a minimize / restore cycle now makes no Reset (it made one when the window had been maximized); a real size change makes one of 20-60 ms.
* **Device loss handled in the editor's own Paint**: no present of an unrendered back buffer after a Reset (black or stale frame), a failed Reset is retried every 100 ms (before it waited for the next window message and `mInitialized` stayed 0), a lost device is polled ~100 times a second instead of as fast as the loop runs.
* **Logging**: every Reset logs `EDITOR device reset: WxH, release, IDirect3DDevice9::Reset, resources, viewport init and UI relayout, total ms`; loss and recovery log `EDITOR device: lost` / `back after N ms`.
* **Build grid budget scales with the screen** (`EdOverlay.cpp`): the quadtree's leaf cap (20,000) and segment cap grow with the viewport area above 1920 x 1080. A 2560 x 1600 view needs ~27,000 leaves; when the cap ran out the far ground stayed coarse and the border moved with every camera step ("the grid switches resolution"). That was not enough: on the NVIDIA laptop (view 2066 x 1294, map 2048, `editor_inst.py start --size 3200x1876`) a zoom in 2 percent steps took the leaf count from 7,900 to 25,783 in four steps, flat at the cap (25,800) for three more, and a strip of 16 to 32 cell blocks showed at the far edge of the view (a flat view from above needs area / 100 leaves when every block crosses the 20 px threshold together). The scale is now twice the area ratio (cap ~ area / 52); to be built and checked on the laptop with the same zoom scan (`ed_overlay_perf()` leaves vs. zoom).
* **`SC_CameraScaleLOD` clamps its index** (a damaged saved `level_of_detail` outside 0..2 read past the table: a random level-of-detail scale all session).
* **Display report** (File > Settings > Display report) now also prints: engine build stamp next to the Lua revision, monitor refresh, the frame cap, the renderer adapter / driver / swap chain (proof which GPU draws), the level-of-detail scale, field of view, zoom and view size, and whether the grid is native or the Lua fallback with its leaf count. New native `ed_engine_info()`.

Not found as a cause by the code audit: DPI scaling (the process is system DPI aware, everything runs in physical pixels), frame time, GPU read-backs. The camera-distance symptoms (units fading early, icons late, grid flipping) have two code candidates left, the grid budget above and a wrong level-of-detail scale; the Display report on the laptop separates them (lod scale 0.9 / 1.0 / 1.2 expected, grid leaves near the cap).

### Threads: where the editor stands and what is worth doing

Already off the main thread: the sim (`Sim`, `Issue`), the map loader, the prefetcher, the field pool (generation, erosion, normal map, up to 16 threads), GPU compute on a second D3D11 device, brush dabs native. Main thread only: UI Lua (one state), D3D9 rendering (one device), wx messages. What would be worth doing next, ordered by expected value, not done yet:

1. **Per-tier parallel `UpdateErrorKernel`** (twice per commit; a 2049 whole-map commit is 267 ms, est. 100 ms saved on 8 cores).
2. **Autosave on a worker** (copy the height words and props, write the .scmap on a thread): removes a 50-500 ms hitch every 5 minutes on big maps.
3. **Blueprint load / startup** (13-18 s): serial Lua in one state. Only a persistent parsed set or reading the .bp files ahead on workers helps; high risk.
4. **A render thread** (record on one thread, submit on another): not realistic for this engine (one D3D9 device, UI Lua draws during the frame); no.

### Anti-aliasing hang on a hybrid laptop (2026-10-26)

Clicking Anti-aliasing froze the laptop editor for good. Cause: the recovered `GetAntiAliasingOptions` packed a mode as `type | quality << 5`, while everything that reads it back (and the FAF client, which stores 256 for 8x) uses `(type << 5) | quality`. The editor therefore asked `IDirect3DDevice9::Reset` for MultiSampleType NONE with a quality level: AMD answers D3DERR_INVALIDCALL (the old code then never retried: a dead window), the NVIDIA driver never returned. Also `SC_AntiAliasingSamples <n>` forwarded token 0 (its own name), so the value was always 0. Fixed: the packing, the token, a guard in `GetHeadParameters` (only a mode the adapter offers is requested), `graphics.lua` (labels decode the packed mode; a saved value the adapter does not offer is Off), a retry of a failed Reset while the device still answers, and a watchdog that writes the crash report (all thread stacks) if one Reset takes longer than 15 s. AA 2x / 4x / 8x now really changes the swap chain (it never did before); verified on the AMD desktop, not yet on the laptop.

**Update (the crash report of the frozen laptop):** with the packing fixed, the saved 8x was finally applied at start and the editor froze about 3 s later: the main thread waited inside `nvd3dumx.dll` (the NVIDIA D3D9 driver) while a worker thread waited on the D3D9 device lock behind it. So real swap chain MSAA hangs the D3D9 device of the hybrid NVIDIA laptop (the cause is inside the driver; the mode list and the engine's use of the multisampled back buffer are the only inputs we have). The editor build therefore offers no anti-aliasing mode on NVIDIA adapters (`D3D9Interfaces.cpp`, `FAF_STUDIO_EDITOR`; the list stays empty, `GetHeadParameters` asks for none, saved modes become "Off"); `FAFSTUDIO_NVIDIA_AA=1` restores the list for testing. AMD and Intel adapters keep their modes. Open: a post process anti-aliasing (FXAA / SMAA) would give every adapter a smoother picture without a multisampled back buffer.

## Paint, detail pass and a big mission map (2026-10-27)

Measured on the desktop (RX 7900 XTX), 2049 x 2049 map, ridged noise terrain, shader TTerrainXP:

| What | Time |
|---|---|
| noise heights written to the map | 0.45 s |
| Layered textures (8 layers) | 0.03 s |
| recipe Apply, style Natural / Layered / Erosion paint | 2.1 / 1.7 / 3.2 s (1025 map: 0.5 / 0.5 / 0.8 s) |
| detail pass, 28,000 props and decals (3 prop classes + 3 decal classes) | 3.9 s |

The detail pass took 27.8 s before: `ed_decal_count` counted the map decals with `NthMapDecal` (which walks the decal list from its start), quadratic, and `ed_decal_add` called it once per decal (20 to 34 ms per decal at 900 to 1000 decals). One pass counting
(`CountMapDecals`, `EditorLua.cpp`) made it 7 times faster; props were never the cost (3,300 props placed in 0.02 s, the dart throwing of a class plans in 0.7 to 0.9 s).

Operation Citadel (1025 map, 12,625 props, 971 decals, 8 strata): 22 s from process start to a ready editor; 60 frames per second at the idle cap, render CPU 6 ms per frame (835 draw calls, 3.9 million vertices); the marker overlay is 2.7 ms of it (15,700 quads: 1,000 mission
markers and their labels), the largest single item that could still be trimmed.

FXAA (branch merged from `fxaa`, off by default): 0.057 ms GPU per frame at 1080p (docs/projects/editor/FXAA.md).
