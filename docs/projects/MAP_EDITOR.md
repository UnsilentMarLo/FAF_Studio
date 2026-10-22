# Project: FAF Studio (map, prop, mesh-map and mod editor; replaces the Unity editor)

Shared rules and tools: [README.md](README.md). Native editor: `automation/mapeditor/`. Python format layer and the
frozen web harness: `map_editor/`. Decompile of the original GPG editor: `external_projects/SCEditorDecomp/`
(`decomp.py`; output in `out/`, git-ignored).

Architecture rules, deliverable order (M1-M8), cut list for the `FAF_EDITOR` build profile and decisions of
2026-10-17: [MAP_EDITOR_DESIGN.md](MAP_EDITOR_DESIGN.md).

## Product definition (user, 2026-10-15)

A **complete, mature map and mission editor**, built as its own application (an exe you run), that **replaces the
FAF Unity editor and is not worse than it**. Not a mod, not a web app, not a prototype.

- **1:1 rendering**: the editor is the game engine. Terrain, strata, water, lighting, fog, decals, props, units and
  shaders are drawn by FA's own renderer. We use the decompile for the engine's editing API.
- **UI** built with the game's own UI system (no ImGui, no browser), shipped as the editor's own data, not as a hook
  into the playable game.
- **Good performance**: starts fast, opens a 20 km map in seconds, edits at the game's frame rate.
- Terrain editing, stratum painting, terrain types, water, lighting, fog, `.scmap` data, props, units, decals,
  markers, areas, armies and teams, **mission making** on SupCom's scenario framework.
- **Mesh terrain compatibility** (`TerrainSystem = 'mesh'`, [TERRAIN_MESH_MAPS.md](TERRAIN_MESH_MAPS.md)): not editing
  the mesh itself, but everything around it: drawing the playable area, splitting a mesh into SCM patches,
  textures, materials and shaders.
- Mods (blueprints, props, units, textures) are first class; QoL features are part of the bar.

## Parity bar: what the Unity editor has (from its source tree: UI classes, `Undo/HistoryObjects`) and our answer

| Area | Unity editor | Studio |
|---|---|---|
| Map | New map, map info, save as, recent maps, version control popup, render map (preview/minimap), upload popup | all, plus backups on every save |
| Terrain | Heightmap brushes, import / export height images, symmetry window, ruler | brushes via `CHeightField` + engine redraw; symmetry; RAW/PNG import export; ruler |
| Stratum | 10 layers, order, per-layer scale and textures, brush painting, previews | `UpdateStratumMask`, layer browser, per-layer preview, blend order |
| Terrain type | Terrain type layers, custom layers, window | terrain type grid, brush, overlay (engine's own type overlay) |
| Props | Browser, selection, placement, scatter, renderer, per-prop edit | blueprint browser incl. mods, scatter / brush, transforms, blueprint-driven reclaim values |
| Units | Unit browser, groups, instances per army | unit browser incl. mods, army groups, initial units |
| Markers | Marker list, presets, chains (connected markers), layers, new marker types | all marker types, chains, graphs (land / naval / air nodes), validation |
| Areas | Area info | rectangles + script names |
| Armies | Armies window, alliances, teams | armies, teams, alliances, colours, extra armies |
| Decals | Decal list, settings, merge, selection | decal manager (`IDecalManager`), groups, cut-off LOD |
| Lighting / water | Lighting info, water info, waves | all `IWldTerrainRes` setters, wave generators, water shader properties |
| Scripting | Scenario / save / script files | scenario framework tooling (see below) |
| Undo | 28 history object types | one command stack over every edit |
| Misc | Neroxis generator runner, resource browser, window state saving, settings | generator runner, resource browser, saved layout |

## Mission suite (scenario framework)

Armies, unit groups (`INITIAL`, named groups), platoons and platoon builders, chains and orders, areas, markers used
by `_script.lua`, objectives, triggers; script scaffolding from templates with the `ScenarioUtils` /
`ScenarioFramework` API outline (`faf_repo/fa/lua/ScenarioFramework.lua`, `lua/sim/ScenarioUtilities.lua`); run the
mission from the editor with the game's own loader; lint of `_save.lua` / `_scenario.lua` against the framework.

## Mesh terrain suite

For maps with a mesh terrain: the `terrain/terrain.lua` manifest (materials with `blending`, `glow`, `alpha_test`,
`highlight`, `additive`, texture slots, light masks), playable rectangle (`playable_x0..z1`, `AREA_1`), water level
and `water_inside` / `water_beyond` outlines, `ground_low` / `ground_high`, haze / void colours, shadow and sun values;
mesh splitting into SCM version 5 patches of at most 65,535 vertices cut by map tile; texture checks (atlas padding,
DXT, mips); cut-out preview (`Display.TerrainCutout`). Reader / writer exist in `scripts/meshmaps/` (`scm.py`,
`convert.py`) and become the editor's golden files.

## Decisions, second round (user, 2026-10-15)

- **Lua UI is fine, with native C functions for I/O exposed to Lua** so the editor is moddable without rebuilding the
  binary. Therefore **all required functionality lives in the binary** and Lua only orchestrates: map formats,
  textures, mesh converters, project I/O, undo, dialogs.
- **A full SupCom editing suite, one application ("Editor")**, not just a map editor:
  Map Editor, **Prop Creator**, **Mesh Map Creator** (convert and adjust materials, meshes and textures into the
  SupCom formats), texture and format converters, and on the roadmap a **Mod / Unit Editor** (blueprints, hitboxes,
  animations, effects, everything about units).
- **Build the decompile into the editor** instead of relying on engine patches (see "Engine strategy").
- **No determinism needed** (no multiplayer): the editor sim may run far faster than the game, and the editor gets
  **play / pause / stop with a timeline**, like other engines' editors: play animations and effects, start a test run
  on the map, stop to reset, pause to freeze the whole sim.

## Engine strategy: build the decompile (faf-re) into the editor

**Evidence that it is buildable and runnable** (read, not yet built here): `engine_decomp/faf-re-master/src/sdk/
main.vcxproj` is an *Application* project (1,043 .cpp files, 99.7% of FAF's 67,170 functions recovered); its link
list is empty of unresolved symbols (`scripts/forced_unresolved.md`); `main.vcxproj.user` documents "F5 = build, stage
main.exe next to the game's `SupComDataPath.lua` and launch it", with the failure mode it hit and fixed
(`gpg::Die("Failed to setup initial search path.")`); the source carries runtime probes and bug notes from running it
(for example the `NotifyMapChange` re-finalize stall). So the recovered tree *is* a runnable FA engine.

**What it gives us over patching the retail exe:** source-level hooks instead of addresses; real Lua C functions
through LuaPlus; terrain, tessellation, decals and the sim are ours to change (live re-tessellation, instant edits);
no fixed-step lock-step (non-deterministic fast sim, pause / stop / step / time scale, snapshot and restore); we can
cut networking, movies and lobby out; and the editor becomes one exe with no patcher.

**Upstream is far ahead of our old snapshot** (`Draiget/faf-re`, cloned shallow to `engine_decomp/faf-re-upstream`,
commit of 2026-10-13): `main.exe` x86 and `main_x64.exe` link and run; main menu, cinematics and the in-game world
view render; native save / load works; **x86 <-> x64 lockstep multiplayer ran hundreds of checksum-identical beats**;
retail parity is "under test, first divergence at beat ~50 (float / RNG finalisation)". Movies use FFmpeg instead of
CRI. The old local snapshot (`faf-re-master`) is superseded.

**Dependencies (2026-10-15):**

| Dependency | State |
|---|---|
| Boost 1.34.1 | downloaded (`engine_decomp/_deps_src/boost_1_34_1.zip`), header-only + 12 thread sources, patch in `dependencies/patches/` |
| wxWindows 2.4.2 | downloaded from the wxWidgets git tag, extracted; patches for VS 2022+ and x64 exist |
| zlib 1.2.3 | downloaded; patch exists |
| DirectX SDK June 2010 | downloaded (600 MB installer), libs / headers to extract |
| LuaPlus Build 1081 | **header shim only**: Lua 5.0.2 `lua.h`/`lauxlib.h`/`lualib.h` + the fork's `%f` scan format + `lua_{set,get}globaluserdata` C-linkage prototypes (`dependencies/LuaPlus_Build1081/Src/LuaPlus/include`). The engine tree already carries the whole VM; the link needed nothing more |
| Wild Magic 3.8 | **reconstructed** (`dependencies/WildMagic3p8/Foundation`): WM4 files renamed Wm4 -> Wm3 + `wildmagic3p8_faf_required.patch` (hand-fixed rejects) + hand-written AxisAlignedBox3, Circle2, IntrBox2Circle2, DistVector3Box3, IntrSegment3Sphere3, IntrBox3Sphere3, ContBox3 `InBox`. New small `Foundation.vcxproj` (static lib, /MD). IntrBox3Sphere3::Find is a simplified swept test |
| Toolset | VS 2026 (v145) here; project targets v143 |

**What the two gaps really are (read from the tree, 2026-10-15):**
- *Wild Magic 3.8*: the engine includes only ~22 Wild Magic headers (Vector2/3, Quaternion, AxisAlignedBox3, Box2/3,
  Sphere3, Segment3, Plane3, Line3, Circle2 and a few distance / intersection helpers) and builds the Foundation
  project. Public Wild Magic 4.x (`FreeCAD/src/3rdParty/WildMagic4`, 220 files, LGPL, cloned to
  `engine_decomp/_deps_src/freecad_wm4`) has most of them (Vector2/3, Quaternion, Box2/3, Sphere3, Segment3,
  Plane3, Line3, DistVector3Segment3, IntrSegment3Box3, IntrLine3Box3, ContBox3, Math, Matrix2/3). Missing in it:
  AxisAlignedBox3, Circle2, IVector2, DistVector3Box3, IntrSegment3Sphere3, IntrBox3Sphere3, IntrBox2Circle2: small
  classes written from the standard algorithms. FAF's `wildmagic3p8_faf_required.patch` says what the FA extensions
  (field-style `v.x`, `Fafextras`) must look like.
- *LuaPlus 1081*: the retail exe statically links LuaPlus and faf-re has already recovered most of the VM in-tree
  (`src/sdk/lua/LuaObject.cpp` defines `luaV_execute`, `luaD_*`, `luaH_*`, GC, `lua_*` API, `luaB_*`, `str_format`;
  `LuaParser.cpp` / `LuaDump.cpp` the parser pieces and dump / undump). The code includes only `lua.h`, `lauxlib.h`,
  `lualib.h` from the external tree, plus whatever the external static library still supplies. Official Lua 5.0.2
  (`engine_decomp/_deps_src/x/lua-5.0.2`) has those headers and the sources of anything not yet recovered; GPG's
  language changes are in FAF's `lua-lang`. The unresolved-symbol list of a first build is the exact residue.

**Resolved 2026-10-15:** neither gap blocked the build. Wild Magic was rebuilt from WM4 + the FAF patch + seven small hand-written classes; LuaPlus needed only its headers (the VM is in-tree). The engine links. The retail-exe bridge and the engine-independent core remain as fallback and shared format layer.

## Status

**2026-10-15 (evening): the recovered engine builds, links and boots here.**
- `engine_decomp/faf-re-upstream/src/sdk/main_ed.vcxproj` (copy of `main.vcxproj` without the Dx9Renderer /
  Dx9Application references; the engine sources never use them) builds Release|x64 with VS 2026 (v145) to
  `output/main/x64/Release/main_x64.exe` (12 MB, /FORCE link, one LNK4088 warning).
- Build recipe that worked: `_deps_src/build_engine.bat` (msbuild, `/p:PlatformToolset=v145`, DirectXInclude /
  DirectXLibX64 pointed at `_deps_src/dxsdk/DXSDK`). wx 2.4.2 must be built **with native wchar_t** (the official
  `nmake ... UNICODE=1 "OVERRIDEFLAGS=/DUNICODE /D_UNICODE /EHsc"`, no `/Zc:wchar_t-`) and `lib/mswu/wx/setup.h`
  stamped `wxUSE_UNICODE 1`; libs copied to `lib/x64`.
- Boot test from a private run dir (`engine_decomp/run_x64/`, junctions to FAForever `gamedata`, `sounds`, `movies`,
  copies of `init_faf.lua` / `SupComDataPath.lua` / `fa_path.lua`; never the FAF bin dir): the Lua VM runs
  `init_faf.lua`, mounts the archives, loads maps / sound banks / fonts, user Lua environment up. It stops at
  `IDirect3D9::CreateDevice`.
- That first failure was the locked workstation (`GetDeviceCaps(HAL) = NOTAVAILABLE` even in a standalone test).
  **Unlocked (2026-10-15 20:3x): the device is created, all shaders compile, and the engine auto-loads a skirmish
  (`/maps/SCMP_009`) and runs its session.** Findings, in order:
  1. Built with `/LARGEADDRESSAWARE:NO` (2 GB) the process hits its address-space ceiling during map load
     (`bad_alloc` in the map loader / `Sim::Create`, then a null deref in `CWldSession::CWldSession`). Fix: build with
     `/p:FafX64LargeAddress=heap` (`main_x64_la.exe`, now in `_deps_src/build_engine.bat`); virtual size then ~6.4 GB,
     private ~1 GB, the session stays up.
  2. Black window: the wx frame came out 1280x729 for a 1280x720 request, so `StretchRect` after
     `RenderCompositeTerrain` read past the 720-line MSAA back buffer (INVALIDCALL), the scene stayed open and every
     `Present` failed. **Fixed** in `CScApp.cpp` (device head size := actual client size). Also needed `/EHs`
     (`<ExceptionHandling>SyncCThrow`, in `main_ed.vcxproj`): Lua errors are C++ throws through `extern "C"`
     functions and `/EHsc` turned them into `std::terminate`.
     **Result (2026-10-15 ~21:00): the game renders** - terrain, ACU, mass points, full HUD, clock running
     (capture with `PrintWindow(..., PW_RENDERFULLCONTENT)`; `CopyFromScreen` only sees what is in front).
  3. Sim Lua methods nil: **fixed.** ~40 `CScrLuaMetatableFactory<T>` specializations were visible to only some
     translation units (declared inside one .cpp, or in a per-type header): any other unit instantiated the generic
     template, so method binders and the class binder sat on different factory objects. They now all live in
     `moho/lua/CScrLuaObjectFactory.h` (out-of-line members stay in their .cpp files). Rule for new code: a
     specialization of a template must be declared where every user sees it.
  4. wx 2.4.2 on Win64: `WXLPARAM` was `long` (32 bit), so a heap pointer above 2 GB in a message LPARAM was
     truncated and sign-extended (crash in riched20 via the log window's `AppendText`). Widened in
     `include/wx/defs.h` for `_WIN64` (+ `mdi.cpp` signature, `window.cpp` `rc.result`, rich-edit stream cookie in
     `textctrl.cpp`). wx must be rebuilt after any change there; engine objects only need a relink if no header moved.
  **Result (2026-10-15 ~22:00): a real skirmish runs on the recovered engine** (SCMP_009, `main_x64_la.exe`):
  economy ticking, factory built, engineer produced, clock 1:16, stable for 90 s+, mouse picking works.
  Follow-ups done (22:10): `GetDepositsAroundPoint` is now also bound in the User set (`Sim.cpp`; resources come from
  `WLD_GetActiveSession()->mSimResources` when the Lua state has no Sim), the `score.lua` nil `width` error went away
  with the method fix, and every `EDITOR-DIAG` block is stripped (kept: the `CScApp.cpp` client-size fix and the
  `FAF_LOGTHROW=<n>` count in `CrashHooks.cpp`). The log of a 60 s session is free of Lua errors and crashes.
  Open: first load takes 60-150 s (sound banks, shader compile); the engine auto-launches a map and an AI
  (`SCMP_009`, "FAF_Degulum"), so an empty editor start is the next step; `main_x64_la` keeps the heap above 2 GB, so
  any remaining 32-bit pointer store in the engine tree shows up as `FFFFFFFF8...` access violations.
  **Editor start (2026-10-15 22:35):** the "auto-launched map and AI" was not an engine bug: it was a real click on
  *Skirmish* (event at the button's position) in the front-end menu. The engine itself boots to the FAF main menu.
  The editor start is now a hook, not a patch:
  - `engine_decomp/run_x64/bin/init_editor.lua` = FAF's `init_faf.lua` + our content dir mounted on `/`
    (`editor/schook/...` is picked up through FAF's own hook mechanism) + `/maps/editor_blank`.
  - `editor/schook/lua/SinglePlayerLaunch.lua` replaces `StartCommandLineSession` when `/editor` is given: one human
    army, every other army a passive civilian (no AI), `Victory = sandbox`, fog off, `Options.EditorMode = true`.
  - `scripts/ed_make_blank_map.py` writes the blank world (flat 5 km grass map, one army) with the Python format
    layer; the engine loads it unchanged, which also confirms the `.scmap` writer against the real loader.
  - Launch: `main_x64_la.exe /init init_editor.lua /editor /map editor_blank /nomovie /nosound /windowed 1280 720`;
    `/nosound` takes the start from ~150 s to ~7 s (hundreds of wave banks are skipped).
  **Map on demand + first native layer (2026-10-15 23:00):**
  - Editor Lua data now lives in the repo: `editor/runtime/` (`init_editor.lua`, `schook/...`, `lua/editor/control.lua`);
    `engine_decomp/run_x64/editor` is a junction to it. `scripts/ed_run.py [map] [--sound] [--wait]` starts it.
  - `moho/editor/EditorLua.cpp` (new, in `main_ed.vcxproj`): the first native `ed_*` globals of the user Lua state,
    bound like every other startup binder: `ed_file_exists`, `ed_file_stamp`, `ed_read_file`, `ed_write_file`
    (disk I/O outside the VFS, creating parent folders). The rest of `ed.*` follows this pattern.
  - Dev command channel: `/edcmd <file>`: whenever the file changes, `control.lua` runs it as a Lua chunk in the live
    UI state and writes `<file>.out` (`OK: ...` / `ERROR: ...`). This is how the running editor is driven and
    tested without a debugger.
  - Open another map in the same process: `import('/lua/editor/control.lua').LoadMap('<map>')` writes the name to
    `editor_next_map.txt` and calls `ExitGame()`; the `uimain` hook then starts the queued map instead of the main
    menu (verified: blank world -> Seton's Clutch, command channel stays alive).
  Facts learned: `SetFrontEndData` asserts (`state->l_G == ...`) outside the front-end state, and `SessionEndGame()`
  only stops the sim (the front end is not re-entered); `/EnableDiskWatch` stalled the sim clock in this build;
  Lua modules are cached per process (restart after editing `editor/runtime/lua`).
  **ed.terrain on the live world (2026-10-15 23:30):** native `ed_terrain_info / get / raise / set_rect`
  (`moho/editor/EditorLua.cpp`). Heights are `uint16` words, world height = word / 128, one sample per world unit,
  a 256-unit map has 257 x 257 samples (the blank map is 256 units: coordinates 0..256, centre 128). An edit writes
  the sim field (`CSimDriver::GetSimForEditor()->mMapData->mHeightField`, accessor added to `SimDriver.h`) and the
  view field (`CWldMap::mTerrainRes->GetHeightField()`) with `SetElevationRectRaw` + `UpdateError`, then
  `NotifyMapChange(rect +1)` rebuilds normals. Verified through `/edcmd`: a 40 x 40 mesa at 85 units next to the
  start shows as raised geometry with a cliff face on the next frame (capture `run_x64/shot11.png`).
  Open: units already standing on edited ground keep their old height (no re-snap); the sim thread reads its field
  while the UI thread writes it (pause the sim around edits when the editor UI exists); no undo yet; the cliff
  texture is stretched (no slope-based strata in the generated map).
  **Terrain brushes with undo (2026-10-15 23:50):** two more natives, `ed_terrain_read_rect(x0,z0,x1,z1)` (array of
  height words + the clamped rectangle) and `ed_terrain_write_rect(x0,z0,x1,z1,words)`, and the first editor tool in
  Lua, `editor/runtime/lua/editor/terrain.lua`: `Brush` (mode raise / lower / flatten / smooth / noise, radius,
  strength, falloff, level), `BeginStroke / Dab / EndStroke / Line`, `Undo / Redo` over whole strokes,
  `Checksum`. The tool never touches the engine except through the natives, so brushes are data and can be added
  by mods. Regression test in the live engine:
  `echo "return import('/lua/editor/selftest_terrain.lua').Run()" > <edcmd file>` -> `PASS` with 15 checks
  (flat start, raise, far field untouched, undo / redo exactness by checksum, flatten, smooth, deterministic noise,
  map-corner clamping). Visual check: a 120-unit ridge stroke shows as a shaded diagonal ridge in the pitched
  camera (`run_x64/shot12.png`).
  Lua dialect trap seen here: a redo group must be replayed first-dab-first (overlapping dabs store absolute words).
  **Save (2026-10-16 00:00):** `ed_map_save(path)` (native; `CWldMap::MapSaveToDiskPath` added next to `MapSave`, same
  container, explicit disk path) writes the live map through the engine's own `.scmap` writer: preview chunk,
  terrain payload (heights from the view field, strata, lighting, water, normal map, masks, decals) and props.
  Round trip verified with the independent Python reader: after a ridge stroke and a 60-unit mesa, the saved file
  parses (minor 60, 256 x 256), the edited heights match the engine's own readback (40.140625 on the ridge, 60.0 on
  the mesa), 5,214 words differ from the blank map and strata / lighting / shader are preserved.
  Not yet covered: the scenario and `_save.lua` side (armies, markers, areas, props placed as units), reloading the
  saved file as a map folder, and saving over the source map with a backup.
  **Map document: props, decals, markers, areas, full folder save and reload (2026-10-16):**
  - Natives (`EditorLua.cpp`): `ed_vfs_to_disk`, `ed_vfs_mount` (a freshly saved folder is mounted at
    `/maps/<folder>` at run time through `CVFSImpl::mMountpoints`), `ed_prop_count/get/add/move/remove` (the
    `CWldProps` list the `.scmap` save writes) and `ed_decal_count/get/add/remove` (map decals through
    `IDecalManager::NewDecal`; simulation-created decals, `mArmy >= 0`, are skipped everywhere). The file natives are
    also bound in the sim Lua state (callbacks report through them).
  - Lua (`editor/runtime/lua/editor/`): `luaser.lua` (table -> FAF map-file text; `VECTOR3 / RECTANGLE` tagged tables
    become calls, keys sorted so saves are stable), `map.lua` (`Load`, markers incl. resource markers with the
    fields `CreateResourceDeposit` needs, areas, armies, props, decals, `SaveAs(diskDir, stem)`), `sim.lua`
    (`Resnap`), sim callbacks `EdResnap / EdSpawnProp / EdRemovePropAt / EdSpawnUnit / EdDumpUnits`
    (`schook/lua/simcallbacks.lua`).
  - `SaveAs` writes `<stem>.scmap` (engine writer), `_scenario.lua`, `_save.lua`, `_script.lua`, then mounts the
    folder; `control.LoadMap(<scenario path>)` opens it. `init_editor.lua` also mounts every folder under
    `<run>/mapout/` and `editor/runtime/maps/` at start, so a saved map opens in a fresh process too.
  - Verified (`selftest_map.lua`: `Build` in one session, `Verify` in the reopened one; fresh-process reopen also
    works): 12 checks PASS: markers (position and fields), area, army, prop (blueprint, position), decal (texture,
    type, position), edited terrain, untouched terrain.
  **Annoying issues found and fixed on the way** (the user asked for these to be hunted down):
  1. Units, props and ground objects did not follow edited terrain. Terrain edits (`dab`, undo, redo, `SetRect`)
     now call `EdResnap` on the edited rectangle; a unit placed at 25 and lifted by a 12-unit hill stands on it
     (y 36.88 on terrain 37.0, `selftest_snap.lua`).
  2. Saved maps contained decals the simulation had created (scorch marks of the commander). `CDecalManager::Save`
     now writes only map decals (`mArmy < 0`).
  3. Every editor world got a commander. `schook/lua/sim/scenarioutilities.lua` skips the ACU when
     `Options.EditorMode`; the map's own INITIAL groups stay.
  4. Opening a second map in the same process kept stale UI state (`score.lua` caches the scenario table, nil
     `PlayableAreaWidth`). The uimain hook drops `__modules` before a map is opened, like a fresh Lua state.
  5. Dropping the module cache re-ran the same `/edcmd` command in every new session (module-local stamp). The stamp
     is a global now (`rawget(_G, ...)`: FAF globals are strict).
  6. `.scmap` props / decals / terrain edits showed nothing in the simulation's own height field before the
     sim field write was added (see ed.terrain above); still open: the sim thread reads while the UI thread writes.
  **Pathing and buildability follow terrain edits (2026-10-17):** what the simulation derives from heights falls in two
  groups. (1) Occupancy / buildability caps (`STIMap::OccupancyCapsOfFootprintAt`: slope against the footprint's
  `MaxSlope`, water depth) are computed from the sim's height field at query time, so they were already live once the
  sim field is written: probe with a power generator across a new 150-unit wall: blocked on the wall and its
  neighbouring cell, fits 5 cells away. (2) The pathfinder keeps cluster maps (`PathTables`, `ClusterMap` check
  levels) that only change when told: `COGrid::ExecuteOccupy / ReleaseOccupy` call `PathTables::DirtyClusters(rect)`;
  terrain edits did not. New sim-lane native `ed_sim_terrain_changed(x0,z0,x1,z1)` dirties the rectangle plus a 10-cell
  margin; `EdResnap` (the sim callback every terrain edit already sends, so it runs on the sim thread) calls it first.
  Test with real movement (`selftest_path.lua`; `Unit:CanPathTo` in this engine tree is only a goal check and says
  yes through any wall): a land scout, a wall across the map with a gap off its line, move order to the far side.
  Without the dirtying (control, `Sim.NoDirtyForTest = true`) the scout walks into the wall and stops at x = 99.0;
  with it the scout detours through the gap and arrives at (180.27, 128.47). Reachable terrain edits need no reopen.
  Still open: units already following a long path are not re-pathed until they ask again; terrain-type / blocking
  layers are not editable yet; vision / line-of-sight caches were not checked; steep slopes show stretched textures (needs slope-based
  strata or cliff decals in the map); markers and areas have no in-world visual yet; editing a prop that came from
  the map file removes the nearest reclaimable entity only (non-reclaimable decor props are not found by
  `GetReclaimablesInRect`).
  **Editor UI shell (2026-10-17):** `editor/runtime/lua/editor/ui.lua`, started by `control.lua` when `/editor` runs
  (`/noeditorui` turns it off). Plain Maui bitmaps and text (no skin files): tool panel (Raise, Lower, Flatten,
  Smooth, Noise, Marker, Area, Camera), brush steppers (radius, strength), Undo / Redo / Save map, a status line
  (cursor world x z and ground height, tool, brush values, undo / redo depth, last message) and in-world overlays:
  marker dots with their names and area rectangles (edges as rows of small squares, because a rotated line cannot be
  made from axis-aligned bitmaps), projected every frame through `WorldView:Project`. Tool entry points take world
  coordinates (`SelectTool, BeginStroke / StrokeMove / EndStroke, PlaceMarkerAt, MakeArea, SetRadius, SetStrength,
  DoUndo / DoRedo / DoSave`), so the mouse handler and tests use the same code.
  Verified with the real mouse (physical cursor driven with `mouse_event`): a left-drag in the world paints a brush
  stroke (dabs spaced radius / 3, unprojected from the dragger's screen coordinates because the view stops
  tracking the hover position during a drag), a click on **Undo** undoes the stroke; terrain self test still PASS.
  Trap: **`AddInputCapture` roots hit testing at the capture control** (C++ `ResolveTopInputCaptureControl`), so a
  capture control starves every panel and the world. World clicks are taken instead by a hook on
  `WorldView.HandleEvent` (`schook/lua/ui/controls/worldview.lua` -> `ui.HandleWorldPress`): the tool gets the
  left press, everything else (camera, right button, wheel, hover) goes the normal way, and panels sit above the
  world view and take their own clicks.
  **Edit mode has no game UI; play mode has it (2026-10-17).** In edit mode the game HUD (resources, orders,
  minimap, score, tabs ...) is hidden through `gamemain.HideGameUI`; the per-frame tick re-hides it, because the
  game's own start-up shows it again after `Create()`. Every left press on the world is swallowed by the hook
  (a tool that cannot use the click still consumes it), so the game's selection box and orders never start.
  **Play test** autosaves the document to `mapout/_playtest.v0001`, shows the game UI, hides the editor panels and
  overlays and shows a Pause / Stop bar; **Stop** reopens the autosave, so whatever the run changed is gone and the
  editor comes back in edit mode (verified: play shows the HUD and the edited terrain, Pause pauses the sim, Stop
  reloads into the edit view with the HUD hidden again). Undo / redo depth in the status line counts strokes.
  **Mods (2026-10-17), see [../EDITOR_MODDING.md](../EDITOR_MODDING.md).** The editor chooses the active mods
  itself: editor mods (`editor_mod = true` in `mod_info.lua`) always, game mods only when loaded in the in-editor
  Mods dialog (applied by autosave + reopen, stored per map as `<stem>_editor.lua`), UI-only mods never. Trap that
  led to this: `hover-to-build` wrapped `WorldView.HandleEvent` and dropped its return value, which defeated
  "return true = consumed" (the selection box came back); the world-click wrapper now sits on the final class after
  all hooks (`ui.InstallWorldHook`). Verified: example editor mod adds a Crater tool, `No Friendly Fire` loads and
  stays after Apply, a leftover trial file restores the previous list. BrewLAN v84 fails to load (blueprint mod
  error, mod side) and shows why the trial recovery exists.
  **Terrain mesh refresh (2026-10-17):** heights written under a still camera only changed the shading (the normal
  map is updated at once) because the tessellator rebuilds only when the camera moved, the terrain is in edit mode or
  the decal manager has pending changes. `ApplyTerrainRect` now raises the decal manager's pending-changes flag and
  the three terrain fidelity classes clear it after the rebuild; verified with a 265-unit hill appearing at once.
  The `/edcmd` poller keeps its stamp in `<file>.stamp` (the reopened session's Lua state loses globals).
  **Prop-scale compat layer (2026-10-17).** `CWldPropEntry` carries the three scale lanes of the `.scmap` prop record
  (`mScale`, 0x44 bytes; retail drops them on load and writes 1,1,1). `CWldProps::Load/Save` keep them, `Sim::Setup`
  multiplies the new prop's draw scale by them (same contract as the patched exe's `MapPropScale`: multiplies the
  blueprint's `Display.UniformScale`, 1,1,1 / non-positive / above 1000 change nothing), `ed_prop_get` returns
  `sx, sy, sz`, `ed_prop_add(..., sx[, sy, sz])` and `ed_prop_scale(i, ...)` set them, `Map.AddProp` / `Map.SetPropScale`
  drive the sim entity (`EdSpawnProp` / `EdScalePropAt` callbacks). The round trip found a second bug: `Save` wrote the
  **transpose** of the rotation `Load` read, so a map saved by the engine came back rotated the other way round; `Save`
  is now the exact inverse. Check: `python scripts/ed_prop_roundtrip.py` (Python writes 4 props with rotation,
  non-uniform and negative scale; the engine loads, saves untouched and edited; the Python reader compares position,
  rotation vectors and scale: PASS). Not checked by eye: the draw scale of the sim entity.
  **M1 core (2026-10-17): `MapDocument`, command stack, commit path** (`moho/editor/MapDocument.*`, `EditorDocument.*`,
  natives `ed_doc_*` / `ed_cmd_*`). The document owns the height words; every edit is a command (`Do`, `Undo`, `Redo`,
  `TryMerge`, `Seal`, label, bounds). A brush stroke is one command: per-dab deltas merge into sparse 32x32 tile deltas
  that are packed (zero runs + zigzag varints) when the stroke ends, with before / after checksums, so undo proves it
  restored the exact samples (`verified`). History is capped (2000 commands, 256 MB); dirty tracking follows a save point
  through undo, redo and dropped redo branches. **Commit path:** the document's sink writes the view field, the normal
  map and the mesh refresh flag on the UI thread at once and queues the rectangle; `Sim::AdvanceBeat` applies the queue
  to the sim's field and dirties the path clusters at the start of each beat (`ApplyPendingHeightEdits`), and the
  `EdResnap` callback drains it first. The UI thread no longer writes the sim's field (the race is gone). `terrain.lua`
  now only computes heights; undo, redo, depth and history live in the document (`ui.lua` unchanged: same
  `Terrain.*` API). Raw `ed_terrain_write_rect` / `set_rect` / `raise` stay for tests and import: they go through the
  document as an external write that clears the history. New session: `control.Start` calls `ed_doc_attach()`.
  Checks: `python scripts/ed_native_tests.py` (engine-free `MapDocumentTest`: 2500 random edits, strokes, undo, redo
  against a model, sink mirror, dirty, trim: PASS) and `python scripts/ed_run_selftest.py` (live: 4 strokes + set rect
  exact by checksum, dirty, branch drop, and the sim's own field equals the document; terrain self test PASS; pathing
  through a gap wall edited via the commit path PASS). Still M1: snapshot play / stop, autosave and crash recovery,
  `Map.SaveAs` should call `ed_doc_mark_clean` only for user saves (play and mod-reload autosaves must not), non-height
  edits (markers, areas, props) are not commands yet (M2).
  **Native brush dab:** `ed_terrain_brush(cx, cz, radius, mode, strength, dir, falloff, level, seed)` (`moho/editor/EdBrush.cpp`, math in the
  header-only `EdBrush.h`) does one round-brush dab of raise / lower / plateau / flatten / smooth / noise in a single call (read the window from
  the document, the brush math, `MapDocument::EditHeights`) and returns `changed, x0, z0, x1, z1, level`; `terrain.lua DabOne` uses it for the round
  brush when the exe has it (`Terrain.NativeBrush = false` forces the Lua loop, which stays for shaped brushes and as the fallback). The math keeps the
  game's float-per-operation rounding so both paths give the same words; test: `EdBrushTest` (`python scripts/ed_native_tests.py`, also builds with
  g++: compares against a line-by-line transliteration of the Lua, a plain double reference and the document write path) and the `native ... dab`
  checks of `selftest_terrain.lua`. A stroke's re-snap of units is coalesced (`sim.lua ResnapLater`: one `EdResnap` per ~0.15 s, flushed at the
  stroke's end) and `ui.lua PumpStroke` lays the dabs within a ~6 ms budget per frame. The noise brush's hash was replaced (the old one was -1 nearly
  everywhere in 32-bit float Lua numbers).
  **Shaped brushes (native):** `ed_brush_shape_set(handle, n, values)` stores a shape mask (n x n over the unit square, `brushes.lua Grid`: procedural shapes
  rasterised once at 129 x 129, image masks at 64 x 64, cached until `Brushes.Rescan`); `ed_terrain_brush` takes the handle and the turn angle as arguments
  13 and 14 and reads the mask bilinearly in place of the falloff profile (same maths as `Brushes.Weight`, `EdBrush.h ShapeSampler`), so ridge / mountain /
  plateau / image brushes cost the same as the round one. `ed_erode_dab` takes `opts.shape` / `opts.angle` the same way. Lua falls back to `Brushes.Fill`
  (a tight loop, also used by the cursor preview) and the old per-sample loop when the exe lacks the natives. Tests: the shaped checks of `EdBrushTest`,
  `selftest_brushshape.lua`. Perf marks: `brush.mask`, `brush.upload`, `brush.fill`, `terrain.dab.native.shaped`, `terrain.dab.lua.shaped`, `strata.dab.shaped`, `stamp.dab`.
  **Noise brush:** smooth value noise on a lattice (seeded integer hash with intermediates below 2^24, smoothstep blend, 1-4 octaves), sampled at the
  world position with the stroke id as seed, so the dabs of one stroke join into continuous bumps. Settings `Brush.noiseScale` (lattice cell, default 8),
  `noiseOctaves` (2), `noiseRoughness` (0.5), sliders in the Brush panel while the Noise tool is active, passed to `ed_terrain_brush` as arguments 10-12
  (an older exe ignores them and keeps its white noise). `terrain.lua Noise` and `EdBrush.h SmoothNoise` do the same operations in the same order;
  `EdBrushTest` compares them and checks smoothness and the coherence across dabs.
  **Terrain type brush and overlay:** `terraintype.lua Dab` paints with one `ed_tt_disc` call and keeps the undo data per 32 x 32 tile (the tiles a dab
  reached are read once per stroke, the ones that changed form the undo entry); `Mark` / `TakeDirty` report the changed cell rectangle; `ttoverlay.lua`
  keeps the node layers and, for a dab, re-reads only the nodes under the dirty rectangle (`ed_tt_nodes` returns the codes under a node window in one call),
  at most ~10 times a second and at most 160 nodes per side (fewer with many types: the engine projects every node of every layer each frame). Test:
  `selftest_ttype.lua`, `EdTerrainTypeTest`.
  **Symmetry detection:** `symmetry.lua Detect` (pure) / `AutoDetect` (called by `Map.Load`, and by the Symmetry panel's "Detect again"): start positions and
  resource markers must map onto each other under the mode (tolerance ~0.012 of the map size, axis offsets are measured), confirmed by a 33 x 33 height
  sample; test `selftest_symdetect.lua`.
  Open: no marker / area selection, move or delete by mouse yet; no prop / decal tool; the Save button writes to
  `mapout/editor_map.v0001` next to the exe (no folder picker).
  Next: selection / move / delete for markers and areas, prop and decal tools,
  terrain-type layer.
  Debug switches that exist: `FAF_LOGTHROW=<n>` (log first n C++ throws with stacks), `faf_diag.log`,
  `faf_crash_latest.txt`; symbolize an RVA with a small DbgHelp tool against `main_x64*.pdb`.
  Removable diagnostics from this session: `EDITOR-DIAG` in `D3D9Interfaces.cpp`, `ResourceFactory.cpp`
  (`scm_diag.txt`), `CrashHooks.cpp` (`FAF_LOGTHROW` count).
- Command-line fact: `/windowed W H` sets `mWindowed = false` (the field means "fullscreen"); no arguments gives a
  1024x768 fullscreen head with 0 Hz.
- Still open from before: seeing an edited height in the retail-exe bridge picture (superseded in value by the
  engine build, which has source-level access to terrain).
- Not started: the editor UI, saving through the engine, props, units, decals, markers, areas, mission and mesh suites,
  converters, the mod / unit editor. Next: get a window up (device), then strip lobby / network / movies, add the
  `ed.*` Lua API and a first editor screen.

- **2026-10-18 (autonomous session, details in MAP_EDITOR_DESIGN.md 19.11 / 19.12):** M3 largely in place and M4 started.
  Environment workspace (lighting, fog, water panels, water surface quad rebuilt on change), symmetry for brushes / markers / areas,
  ruler, heightmap import / export (PNG, TIFF, raw, resampling), terrain-type layer (tool, panel, overlay), prop brush with catalog
  browser and eraser, texture-brush blend modes, slider widget fix, map life cycle (New from 5 / 10 / 20 km templates, Open any
  map of the game data, Save, Save as, map info, backup outside the maps folder before the first overwrite). Real FAF maps open
  (Abrogation: 1025 samples, 4141 props). Regression: terrain, command stack, map round trip self tests PASS; save + reopen keeps
  lighting, water, terrain types, masks, layer textures, heights, props.
  Since: map preview, plateau / erode brushes, mesh terrain manifest panel + checks (MAP_EDITOR_DESIGN.md 19.18).
  Also since: mission suite first slices (army setup, stages / nodes compiled to the script, unit groups; 19.19-19.21) and the mod / unit editor first slices (unit lab, viewer, effects, derived units; 19.22, MOD_UNIT_EDITOR_DESIGN.md).
  Open: select / move / delete of single props and decals, decal and unit tools, gizmos, copy / paste (M2); slope-based strata,
  brush masks, mask preview (M3); preview / minimap render, project mod list, recent maps (M4); 12 `Evaluating LazyVar failed ...
  circular dependency` warnings at start-up (harmless so far, source not found); the editor session's uncommitted files
  (control.lua, luaser.lua, init_editor.lua) are still uncommitted.

## Tests

```
python map_editor/tests/test_scmap_roundtrip.py     # every .scmap byte for byte
python map_editor/tests/test_project_roundtrip.py   # folder -> client JSON -> folder
python scripts/binpatch.py mapeditor                 # build the native module + test bin
```
