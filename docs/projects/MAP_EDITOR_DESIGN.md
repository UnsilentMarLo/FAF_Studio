# FAF Studio: design (v0.1, 2026-10-17)

Status of this file: **proposal from the brainstorm of 2026-10-17**. Product definition, parity table, engine strategy
and the running status log stay in [MAP_EDITOR.md](MAP_EDITOR.md); this file holds the architecture rules, the
deliverable order, the cut list and the open questions. Update both when a decision changes.

Evidence tags: **[verified]** read in the tree or run in the editor; **[inferred]** from file or folder names only;
**[open]** not checked.

## 1. Decisions

| # | Decision | Choice | Why |
|---|---|---|---|
| D1 | Track upstream or hard fork | **Gate cuts behind a `FAF_EDITOR` build profile; keep tracking `Draiget/faf-re`** (user, 2026-10-17) | Upstream moves fast (x64, FFmpeg, parity fixes). Deleted files make every merge a conflict. `main_ed.vcxproj` is already a one-file divergence; keep divergences small and listed. |
| D2 | Distribution | **Source + build script that uses the user's own FA / FAF install; no redistributed binary** (recommendation) | The exe is compiled from a decompile of a commercial game and loads its data from the FAF install. Matches the workspace rule "never commit or upload a built exe". Not legal advice: **[open]** check before any public release. Changes packaging (M4), not the architecture. |
| D3 | Suite order after M1-M4 | **Mesh-map suite first, mission suite second** (recommendation) | Mesh suite has a live consumer ([TERRAIN_MESH_MAPS.md](TERRAIN_MESH_MAPS.md)) and golden files already (`scripts/meshmaps/`). The mission suite has the largest design surface and needs the M2 object tools and inspector to be mature first. |
| D4 | Edit-mode sim | **Sim exists but is frozen; edits are applied between ticks** (recommendation) | Keeps live buildability and path checks (already verified working after terrain edits), keeps unit snapping, and removes the sim-thread / UI-thread race. Cost: memory, slower map open. The sim machinery for pausing exists in `moho/sim` (`Sim.cpp`, `SimDriver.cpp`, `PauseListener`) **[inferred]**. |

## 2. Architecture rules

1. **One document, derived views.** A native `MapDocument` owns the truth: heights, strata masks, terrain type,
   water and lighting, props, decals, markers, areas, armies, scenario tables. The sim field
   (`mMapData->mHeightField`), the view field (`CWldMap::mTerrainRes`), the sim's occupancy and path caches and the
   renderer are projections, refreshed through **one commit path** that runs on the sim thread between ticks.
   Today `ed_terrain_*` writes two fields by hand and the UI thread writes while the sim thread reads **[verified,
   MAP_EDITOR.md status]**. The commit path replaces that.
2. **One command stack.** Every edit is a native `Command` (`Do`, `Undo`, `TryMerge`, dirty rectangle, label).
   Large payloads (height, mask, type rectangles) are stored as compressed diffs. Lua tools only build commands. This
   replaces the per-tool Lua undo in `terrain.lua`. Dirty state, autosave and the status-line depth all read the
   stack.
3. **Natives are data in, data out; tools are data.** Everything required stays in the binary (formats, converters,
   I/O, undo, dialogs, picking, drawing). Lua orchestrates UI and tools, so tools are moddable without rebuilding.
   Existing pattern: `moho/editor/EditorLua.cpp` (`ed_*`) **[verified]**.
4. **Edit mode and play mode are two states of one process.** Play takes a snapshot with the engine's own savegame
   serialization (`moho/serialization`) **[inferred]**, unfreezes the sim and shows the game UI; Stop restores the
   snapshot in memory. Replaces the autosave-to-disk-and-reopen used now. The editor sim has no lockstep and may run
   above real time.
5. **Gate, do not delete.** `FAF_EDITOR` selects the editor profile. Cut code is excluded from `main_ed.vcxproj` or
   compiled out with `#if !defined(FAF_EDITOR)`. Every divergence from upstream is listed in section 5 so a merge
   can be checked against it.
6. **Editor UI is the game's own Maui, with a small set of real controls.** The shell today is plain bitmaps and text
   (`ui.lua`). Needed: panels with docking and saved layout, lists and trees, text/number fields, sliders, tabs,
   a color picker, a file dialog (native), context menus, tooltips.
7. **Overlays are drawn in the world, not projected bitmaps.** Markers, area edges, gizmos and brush rings need real
   world-space lines and handles. `SDebugLine` / `SDebugDecal` and the `RDebug*` classes exist in the tree
   **[inferred]**; confirm they can be driven from `ed.*` before building a new line renderer.
8. **User mods never load in the editor** except the ones the map or project declares (`init_editor.lua` removes
   `/mods/*` mounts; a hook mod dropped a return value and broke input once). Mod content (blueprints, props,
   textures) is first class through an explicit project mod list.
9. **Testing is part of every feature.** A feature ships with a live self-test run through `/edcmd`
   (like `selftest_terrain.lua`) and, for formats, a byte-exact comparison against the Python layer in `map_editor/`.

## 3. Deliverables

Each milestone ends with: self-test PASS, a saved map that reloads in the editor and in the retail game, and a status
entry in MAP_EDITOR.md.

| M | Name | Contents | Done when |
|---|---|---|---|
| M1 | Core | `MapDocument`, commit path, native command stack, dirty tracking, snapshot play/stop, autosave and crash recovery | Terrain brushes run on the stack; edit, play, stop, undo are exact by checksum; no sim/UI thread race |
| M2 | Object tools | Selection (click, box, multi), move / rotate / scale gizmos, delete, copy / paste, snapping to terrain and grid, inspector, for markers, areas, props, decals, units | Every object type editable by mouse and undoable |
| M3 | Terrain complete | Strata layers and masks, terrain-type layer, water and waves, lighting and fog, symmetry, RAW/PNG import and export, ruler, slope-based strata or cliff decals | Parity with the terrain / stratum / lighting rows of the parity table |
| M4 | Map lifecycle and shell | New-map wizard (size, theme, template), open / save as with backups, recent maps, map info, preview and minimap render, settings, hotkeys, docking, project mod list, build / run script (D2) | A user can make a map from nothing and play it without leaving the editor |
| M5 | Mesh-map suite | `terrain.lua` manifest editor, playable rectangle, water and outlines, SCM v5 splitting, texture checks, cut-out preview | Round trip against `scripts/meshmaps/` golden files |
| M6 | Mission suite | Armies / teams / alliances, groups, platoons, chains, objectives, triggers, script scaffolding, framework lint, run-from-editor | A scripted mission built and played without a text editor |
| M7 | Prop Creator and converters | Mesh / texture import, material setup, SCM / DDS conversion, LODs, preview with lighting | A prop made from a source mesh appears in the prop browser |
| M8 | Mod / Unit editor | Blueprints, hitboxes, animations, effects | Separate design document before starting |

Open items from the status log that land inside these milestones: no marker/area mouse selection and no prop or decal
tool yet (M2); Save writes only to `mapout/` with no folder picker (M4); units following a long path are not re-pathed
after terrain edits (M1, by commit path); vision / LOS caches after terrain edits unchecked (M3); status line walks the
undo stack every frame (M1).

## 4. Features and rules by area (checklist for the spec)

- **Terrain:** brushes (raise, lower, flatten, smooth, noise, plateau, ramp, erosion), brush shapes and falloff
  curves, stroke spacing, symmetry (mirror, rotate, quadrant) shared with every other tool, height import / export,
  map resize and crop, 20 km (1024) maps edit at game frame rate.
- **Strata and type:** per-layer scale, order, preview and mask brush; terrain-type grid with overlay; engine blend.
- **Water and sky:** all `IWldTerrainRes` setters, wave generators, water shader properties, fog, lighting presets.
- **Objects:** blueprint browser incl. mods, scatter by density and mask, random scale / rotation, groups, layers
  (visibility and lock), reclaim values from blueprints.
- **Markers and graphs:** all marker types, chains, land / naval / air node graphs, validation (resource markers need
  the fields `CreateResourceDeposit` expects).
- **Armies and mission:** see M6. Rule: the editor writes the same `_scenario.lua` / `_save.lua` / `_script.lua`
  files the Unity editor does, so maps stay editable in both.
- **Validation panel:** start positions, mass and hydro counts, unreachable areas (path check from the live sim),
  missing blueprints, bad marker names, file sizes.
- **Files:** `.scmap` through the engine writer **[verified]**; `_save.lua` through `luaser.lua` with sorted keys for
  stable diffs **[verified]**; backup on every save; never overwrite the source map without one.
- **QoL:** hot reload of textures and blueprints (`CDiskWatch` exists in `moho/misc` **[inferred]**; `/EnableDiskWatch`
  stalled the sim clock once **[verified]**, so edit-mode only), camera bookmarks, measurement tools, screenshot,
  command palette.

## 5. Cut list for `FAF_EDITOR`

**This is the hypothesis. It becomes fact only by compiling each item out of `main_ed.vcxproj` and reading the
unresolved symbols.** Order of work: one item per build, note the result in the table, commit.

| Item | Where | Size | Action | Result |
|---|---|---|---|---|
| Lobby, GpgNet, discovery, UDP/TCP sockets | `moho/net` (38 .cpp) | ~17.7k lines | Gate off; keep local and null client the sim driver needs **[open]** whether single-player still pulls `CClientManagerImpl` | not tried |
| Movies / Sofdec / FFmpeg | `moho/movie`, `moho/audio/SofdecRuntime` | ~1.7k lines | Gate off | not tried |
| Replay client | `moho/net/CReplayClient` | small | Gate off | not tried |
| Beat checksum and desync detection | `moho/sim` (`SimDriver`, `Sim`) | small | Gate at call sites; keep deterministic code paths intact so snapshot behaviour matches the game | not tried |
| Crash reporting and telemetry | BugSplat in `moho/app`, `CrashHooks.cpp` | small | Gate off (keep `FAF_LOGTHROW` and `faf_diag.log` while developing) | not tried |
| FAF front end | Lua only: lobby, vault, chat, main menu, campaign menu | n/a | Not mounted by `init_editor.lua` | partly done (editor start hook) |
| Audio banks | `moho/audio` (22 .cpp, ~9.3k lines) | | **Lazy-load, do not cut.** `/nosound` takes start from ~150 s to ~7 s **[verified]**; load banks on first preview | not tried |
| Debug overlays | `moho/debug` (14 .cpp) | ~2.5k lines | **Keep** as editor views (nav, path, radar, grid) | n/a |
| Unit AI C++ | `moho/ai` (101 .cpp) | ~55k lines | **Keep.** It is navigation, attack, transport, formation, path: play-test needs it **[inferred]** | n/a |
| Sim, unit, entity, path, collision, effects, particles, animation, serialization | `moho/*` | | **Keep** (play-test, previews, snapshots) | n/a |
| Terrain, render, resource, mesh, lua, ui, gpg core | `moho/*`, `gpg/*` | | **Keep** | n/a |

**Add (new, editor-only), all under `moho/editor/`:** `MapDocument`, `CommandStack`, commit path, picking and
gizmos, selection model, world-space overlay drawing, file dialogs, format and texture converters, settings store.
`EditorLua.cpp` splits by area as it grows (terrain, objects, files, converters).

**Divergence log (required by D1):** keep a table here of every upstream file edited, with the reason, so each
upstream merge is a checklist. Known so far: `main_ed.vcxproj` (no Dx9Renderer / Dx9Application), `CScApp.cpp`
(device head size = client size), `Sim.cpp` (`GetDepositsAroundPoint` in the User set), `SimDriver.h`
(`GetSimForEditor`), `CWldMap` (`MapSaveToDiskPath`), `CDecalManager::Save` (map decals only), wx `defs.h` /
`mdi.cpp` / `window.cpp` / `textctrl.cpp` (64-bit message parameters), `CScrLuaObjectFactory.h` (template
specializations), `moho/editor/EditorLua.cpp` (new). Added 2026-10-17: `CWldMap.h` / `CWldMap.cpp` (prop entry keeps
its scale: 0x44 bytes, `Load` / `Save` carry it; `Save` writes the exact inverse of the loader's rotation), `Sim.cpp` (prop
scale at `Setup`; `AdvanceBeat` applies queued editor height edits), `HighFidelityTerrain` / `MediumFidelityTerrain` /
`LowFidelityTerrain` (clear the decal manager's pending flag after the rebuild), new `moho/editor/MapDocument.*`,
`EditorDocument.*`. Source: MAP_EDITOR.md status log.

## 6. Risks

- **Maintenance of the third-party stack:** wx 2.4.2 on Win64 is patched by hand; Wild Magic was rebuilt from WM4;
  `/LARGEADDRESSAWARE` needs the heap build. Any rebuild of wx follows the recorded recipe.
- **Upstream parity gap:** upstream says retail parity first diverges around beat 50. Fine for an editor, but play-test
  results are not guaranteed identical to the retail game; the doc and UI must say so.
- **Load time:** first start is 7 s without sound, 150 s with; shader compile is a one-time cost. Target in the product
  definition: 20 km map in seconds.
- **First-use friction:** 60-150 s first load noted in the status log; needs a measured breakdown before M4.
- **Legal and distribution:** see D2.

## 7. Next steps

1. Create the `FAF_EDITOR` define in `main_ed.vcxproj` and gate the first two cut-list items (`moho/net`,
   `moho/movie`); record link results in section 5.
2. Spec the `MapDocument` and `Command` interfaces (fields, ownership, thread rules) before writing M1 code.
3. Check that `SDebugLine` can be driven from `ed.*` (rule 7).
4. Move the Lua terrain undo onto the native stack as the first M1 user.

---

# Round 2 (user requests of 2026-10-17)

Four research reports back this section; claims here are summaries, details and evidence are in them:

| Report | Topic |
|---|---|
| [GPG_EDITOR_FEATURES.md](editor_research/GPG_EDITOR_FEATURES.md) | GPG and Unity editor features, brush system, complaints |
| [UI_CAMERA_FEASIBILITY.md](editor_research/UI_CAMERA_FEASIBILITY.md) | What Maui can and cannot do, docking design, camera |
| [MISSION_SCRIPT_ANALYSIS.md](editor_research/MISSION_SCRIPT_ANALYSIS.md) | Campaign and coop scripts, node catalogue, compile targets |
| [MESH_MAP_EDITOR_NEEDS.md](editor_research/MESH_MAP_EDITOR_NEEDS.md) | Mesh-terrain data contract, F1-F19 features, V1-V20 rules, P1-P16 port list |

Project history, release, validators and loading: [EDITOR_WORKFLOW_DESIGN.md](EDITOR_WORKFLOW_DESIGN.md).

## 8. UI shell (modern, modular, moddable)

**Goal:** the look and behaviour of Blender / Photoshop: areas the user splits, resizes, tabs, drags and saves.

- **Layout model:** a tree of splits and tab stacks stored as data (ratios, active tabs, floating groups). Panels
  register through `Panels.Register{id, title, icon, create, defaults}`; editor mods add panels, tools, brushes,
  validators, node types and workspaces the same way. Dock geometry is computed in plain Lua, not in lazy-variable
  chains (lazy variables re-evaluate through `pcall` and are slow during splitter drags).
- **Workspaces** (presets, user-savable, switch with a tab bar): Layout, Terrain, Objects, Mesh, Scenario, Script,
  Validate. Per-panel state and window scale are saved per workspace.
- **Core panels:** viewport (several allowed), outliner (tree of every object with visibility / lock / army / group),
  properties inspector (context sensitive, multi-select edit), asset browser (virtualised list with thumbnails,
  search, tags, favourites, drag to world), brush browser, history (see workflow doc), validator list, console and log,
  node editor, timeline (play / pause / stop), command palette (Ctrl+Shift+P, searches every action and setting).
- **Interaction:** drag and drop between panels and from assets to the world, Explorer file drop, context menus
  everywhere, tooltips with hotkeys, multi-select with box and lasso, rename in place, drag-to-scrub number fields,
  eyedropper, copy and paste, toast notifications.
- **Smart scrollbars:** thin overlay bars that appear on hover or scroll, fade out, support thumb drag, track click,
  wheel with momentum and Shift for horizontal; auto-hide when the content fits; virtualised lists so thousands of
  props cost the same as ten.
- **Visual design (user decision 2026-10-17: no theme system, pragmatic):** one clean, high-contrast look; functionality
  and readability first. Colours, spacing and sizes are plain constants in one Lua file, not a skinning or theme
  feature; no light / high-contrast variants, no skin mods. Icons come from one atlas. UI scale (50-200 %) stays and
  rebuilds the panel tree from the layout data, because Maui reads scale only at layout time.
- **Text rendering (user decision: proper clean text wanted, an editor shows a lot of it):** the game's grayscale
  DXT glyph fonts are replaced in editor controls by a native text renderer inside `CMauiCanvas`: system fonts rasterised
  at the exact pixel size (DirectWrite or GDI) into a glyph atlas, sub-pixel positioning, hinting, DPI-aware, full
  Unicode, kerning, and an editor-wide font setting. ClearType-style per-channel coverage needs a shader blend pass
  on D3D9 and a known opaque background (panels are opaque, so this fits); text over the world uses grayscale
  coverage. **[open]** needs a spike: atlas glyph cache plus shader, verified against a screenshot.
- **Keymap:** every action has an id; bindings are data, user-editable, with conflict detection and a search box;
  presets (Blender-like, Unity-like, GPG-like with F1-F11 layers).
- **Native work needed** (new files under `moho/editor/`, a few one-line upstream hooks): `CMauiCanvas` (retained
  draw list of quads, lines, text, rounded rects, with clipping; carries node wires and custom widgets) and a clip
  property for groups (about 3-4 days), native file dialogs (`wxFileDialog` is already in the tree), Explorer file
  drop (OLE built in, x64 untested), clipboard, DPI awareness, runtime textures, world-overlay lines through
  `DRAW_Wire*` in `CUIWorldView::Render`. FAF's `UI_DrawLine`, `CopyToClipboard`, `SetColorMask` and
  `ProjectMultiple` are exe patches that do **not** exist in the recovered engine.
- **Build order:** Lua widget kit and docking first (no C++), then `CMauiCanvas` and the small natives, then the
  node editor on the canvas.
- **Panel pop-out to other monitors (user decision: wanted, as a user choice at run time, like other modern
  editors):** any panel or panel group can be dragged out into its own native window and back, on any monitor,
  remembered in the workspace. The research found display "heads" (window + swap chain + Maui root frame) are fixed
  at start, so this is native work in M0: create and destroy heads at run time (a new window, D3D9 additional swap
  chain, its own Maui root), route input per head, and keep the viewport(s) on their own heads. **[open]** feasibility
  spike first (can a head be added after device creation; fall back to a multi-window host where only panels, not
  viewports, pop out). Panels must not assume they live in the main window.
- **Limits to accept:** no per-pixel rotation and no render-to-texture for panels.

## 9. Camera

- **Today:** an orbit camera around a terrain-snapped focus; orbit, pan, zoom-to-cursor, focus, top view,
  bookmarks and WASD pan already work from Lua. Limits: zoom clamped (`cam_NearZoom` 5 up to map size x 1.4), pitch
  0.1-1.56 rad, FOV and pitch derived from zoom, ortho top-down only, no eye-vs-terrain collision, `cam_Free` removes
  the edge clamp but hides strategic icons.
- **Editor camera (about 150 lines in `CameraImpl.cpp`):** free-fly branch, ortho in any orientation, FOV override,
  wide pitch range, optional eye collision, exports for pan / spin / zoom / heading / pitch.
- **Default keymap (rebindable):** MMB orbit, Shift+MMB pan, Ctrl+MMB or wheel zoom to cursor, hold RMB + WASD/QE
  fly with Shift fast and Ctrl slow, wheel while flying sets speed, F focus selection, Home frame map, numpad 1/3/7
  front, side, top with Ctrl for opposite, numpad 5 ortho toggle, Alt+1..9 jump to bookmark, Ctrl+Alt+1..9 set
  bookmark, Tab to swap with the previous view, smooth damped movement with a toggle for instant.
- **Key routing:** the engine keymap has no contexts, key-up or mouse chords. Plan: a focus-holding key-router
  control feeding an editor input layer (context, modifiers, chords). Untested.
- **Decided (user): strategic icons are never hidden by the free camera**, "this is an editor". `cam_Free`'s side
  effect of hiding them is not acceptable, so the editor camera uses a new free mode that lifts only the map-edge
  clamp (bounds-rect variant) and leaves icon rendering alone. Part of the camera C++ in M2.

## 10. Brush system

- **Sources found:** the GPG editor ships about 40 `.brush` files plus 4 `.filter`, 1 `.raze` and 12 raw 16-bit
  stamps in `editor.scd`; the Unity editor has 11 greyscale PNGs. GPG has strength, size, min / max height, no
  rotation, spacing, falloff or symmetry; Unity has four height brush types, nine symmetry modes and a 1-pixel
  symmetry offset bug caused by nearest-neighbour sampling.
- **Our design (dynamic menu):**
  - A brush is a greyscale mask (PNG / DDS / RAW, 8 or 16 bit) plus a small sidecar (`name.brush.json`: display
    name, category, default size, spacing, falloff, rotation mode, tags). No sidecar means sensible defaults.
  - Brush folders are scanned at start and by file watch: built-in, user folder, mod folders. Drop a file in and it
    appears in the menu with a thumbnail; legacy GPG `.brush` / `.raw` import converts on load.
  - Procedural brushes (circle, square, noise, ridge, crater, plateau) defined in data, parameterised.
  - Brush engine: bilinear sampling at sub-pixel positions (fixes the symmetry offset), size without a hard limit,
    rotation (fixed, random, follow stroke), jitter, stroke spacing, pressure curve, falloff curve editor, flow vs.
    opacity, mirror through the symmetry system, stroke smoothing, and a height clamp window (min / max).
  - Modes: raise, lower, set, flatten to cursor height, smooth, sharpen, noise, erode, plateau, ramp between two
    points, stamp (full-size greyscale stamp as a one-click shape), height filters (blur, sharpen, unsharpen),
    "raze" to a target height. The same brushes paint strata masks, terrain type, water flatness / foam / depth bias,
    decal and prop density.
  - GPU or tiled CPU application on dirty tiles only, so 20 km maps stay interactive; each stroke is one command.
- **Per-pixel maths of the original** (mask-weighted lerp to a target, clamped 0..65535) is the compatibility
  reference; the `.brush` header layout is not yet traced (report lists it as unverified).

## 11. Scenario editor (node-based missions)

Summary of [MISSION_SCRIPT_ANALYSIS.md](editor_research/MISSION_SCRIPT_ANALYSIS.md): 19 map folders scanned, 7,333
framework calls over 130 targets, the top 30 cover 86 %. About 70 candidate nodes catalogued with signatures.

- **Model:** a sidecar `<stem>_mission.lua` holds the graph (stages, nodes, exec and typed data ports, bases,
  variables, strings). The compiler generates `_script.lua` between region markers. Engine lifecycle: `doscript(save)`,
  `doscript(script)`, then `OnPopulate` and `OnStart` (errors are only warnings, so run-from-editor reads the log).
- **Stages as tabs:** each stage has *On Enter* (compiles to `IntroMissionN`, the cutscene part) and *On Ready*
  (compiles to `StartMissionN`), objective completion advances the stage, with a failsafe timer node. Stage tabs
  can start and end with a Cutscene node.
- **Node families:** events and triggers (16 types: timer, unit killed, area entered, counts, objective result ...),
  objectives (12 types: Kill, Capture, Protect, Reclaim, Timer, UnitsInArea ...), actions (spawn groups, orders,
  platoons, transports, army setup, restrictions, vision, dialogue, taunts, camera / cinematic, resources, unit
  cap), flow (branch, difficulty switch, wait, parallel, loop), variables, compound nodes (Failsafe Timer Advance,
  Wave Respawner, Ambush With Cooldown, Drop Reinforcements, Spawn Player Commanders, Nuke Barrage, Economy Trickle,
  Unlock Tech With VO, Cutscene) and a **Raw Lua node** as the escape hatch.
- **Bases:** the user drags a base area; the editor derives area, marker, radius, difficulty-nested groups (the save
  nests D3 within D2 within D1, so a per-unit minimum-difficulty tag suffices) and `<Base>_EngineerChain`. Base
  properties (engineers, scouts, defence layers, build levels and priorities, expansion rules) live in a **properties
  table**, not on the canvas. The Bases tab shows one node per base wired to stages. BaseManager and OpAI
  (1,638 `AddOpAI` calls, 413 of 440 conditions are the same human-count check) are better edited in tables with
  template conditions.
- **Round trip:** region markers with hashes; hand edits are detected per region and the user chooses keep, detach
  to Raw Lua, or three-way merge. Existing hand-written missions are adopted as a read-only legacy region plus a
  reference scan; auto-converting arbitrary Lua into nodes is out of scope.
- **Unit placement for missions** (the editor around the nodes): grid and snap (grid, formation slots, terrain,
  object, angle), formation placement (line, block, circle, wedge), quick-place mode with the last blueprint, army
  and group repeating on click, **building templates** (select, save as `.scunits`-style template, preview ghost,
  rotate / mirror, place with snapping, library with thumbnails; format of the existing `.scunits` still to be
  checked), move selection between armies / groups with a hotkey and recolour, per-unit properties (orders,
  health, veterancy, difficulty tag, name), group manager, patrol / attack-chain drawing with markers, area drawing,
  paste-in-place, find / replace blueprint across armies, army overview (counts, cost, power), unit-cap estimation.
- **Mission validators:** dead stage (found in the real corpus: `MissionP1` never called), undefined callback
  (`PlayerDeath` passed undefined), wrong `CreateArmyUnit` arguments, objective with no trigger, group never spawned,
  global leaks, left-on debug flags, unchecked array indices. Coop API (`PlayerDeath`, `SetSharedUnitCap`,
  `ScenarioInfo.HumanPlayers`) comes from the `lobby_coop.cop` mod, not from `faf_repo/fa/lua`, so the editor must
  mount it for scripts to run. No shipped mission scales enemy strength by player count; offer it as a node.
- **Coop (required):** a mission has a Mode setting (campaign single player / coop / both). In coop mode the editor
  mounts `lobby_coop.cop` so its API resolves (`GetLeaderAndLocalFactions`, `SetSharedUnitCap`, `PlayerDeath`,
  `RemoveRestrictionForAllHumans`, `SimAnnouncement`, `ScenarioInfo.HumanPlayers`) and the compiler knows it. Coop
  nodes: Spawn Player Commanders (per human slot), Shared Unit Cap, Player Death handling (fail only when all humans
  are dead), Drop Reinforcements per player, Restriction for all humans, Announce, human-count conditions for OpAI
  (the 413 of 440 common condition becomes a template), and a Player-count switch node for scaling enemy strength
  (no shipped mission does it, so it is new). The play-test panel simulates 1-4 human slots (extra humans as
  passive controllers), and the validators check coop rules (every human slot has a start and a commander, no
  hard-coded army indices beyond the player slots).
- **Run from editor:** play-test the mission with the game's loader, show script errors and objectives in a mission
  debug panel, jump to a stage, set flags, fast-forward timers (the editor sim has no lockstep).

## 12. Mesh-terrain support

Summary of [MESH_MAP_EDITOR_NEEDS.md](editor_research/MESH_MAP_EDITOR_NEEDS.md):

- The mesh patch is four parts: the render DLL `automation/terrainmesh/meshterrain.cpp` (x86 detours, not in
  FA-Binary-Patches), three sim exe patches in `FA-Binary-Patches-mesh` (`MapPropScale` still untracked in git), the
  Lua mod `my_mods/Mesh Terrain`, and a map-side convention (`TerrainSystem='mesh'`, `TerrainMesh='/maps/<folder>/
  terrain/terrain.lua'` in `_scenario.lua`).
- **The mesh is visual only.** Sim, picking, decals, range rings and fog keep using the `.scmap` height field, and no
  mesh-to-height bake exists. Under a mesh, height brushes and strata stop affecting the visible ground.
- **Editor features (report F1-F19):** manifest editor, mesh import, tile split into SCM v5 patches, material and
  texture assignment, light-mask baker, **height-field bake from the mesh with a divergence report**, water map and
  outline generator, cut-out preview, preview render, round trip. **Validators V1-V20:** vertex limit 65,535, tile
  bounds, manifest syntax (parsed line by line, no exponents), atlas padding, DXT / mips, outlines.
- **In the source-built engine** no patch is needed; the 16 behaviours (P1-P16) are ported to source level, e.g.
  `HighFidelityTerrain::DrawTriangles`, `DrawTerrainDepth`, `DrawWaterTerrain`, `DrawDecalPass`, `FlattenMapRect`,
  `OCCUPY_Check`. Maps stay loadable by the patched retail exe because the file contract is unchanged.
- **Must fix first:** `CWldProps::Load` drops per-prop scale and `Save` writes 1,1,1 (`CWldMap.cpp:1235-1250`,
  `1287-1289`); saving a converted SC2 map would destroy prop sizes.
- **Height field (decided):** user-supplied, or baked from the mesh with a part selection (one or several patches /
  objects / regions); divergence report and "block from mesh" (unbuildable where the mesh is steep or absent).
- **Prop scale compat layer (decided, required):** per-prop scale round-trips through the editor and the file stays
  compatible with the patched exe's `MapPropScale`.
- Converted SC2 content must not be committed (existing rule).

## 13. Where we beat both editors

| Area | GPG editor | FAF Unity editor | FAF Studio |
|---|---|---|---|
| Renderer | engine, 2007 | Unity approximation | the real engine, 1:1, plus mesh terrain |
| Save safety | single file, undo only in session | backups, play-map bugs | journal, history, restore, compare, release |
| Brushes | fixed `.brush` set, no rotation / falloff | 11 PNGs, nearest sampling | dynamic folder menu, bilinear, rotation, spacing, falloff, procedural, mod folders |
| Symmetry | none | nine modes with a 1 px offset | all modes, sub-pixel exact, shared by every tool |
| Undo | EditStack per domain | 28 history classes | one native command stack incl. objects, masks, script graph |
| Test | none | Play Map (reported broken) | play / pause / stop with snapshot, mission debugger, smoke load |
| Validation | none | partial | live, full scan, release gate, quick fixes |
| Missions | order and platoon editing | files only | node editor, bases, templates, compile, round trip |
| Hot reload | none | none (open issue) | textures, blueprints, scripts |
| Mods | none | none | panels, tools, brushes, validators, nodes as data |
| Mesh maps | n/a | n/a | full suite |
| Maintenance | closed | last release April 2021 | in-tree, tests per feature |

Known Unity-editor complaints we design out: no PNG height import, BMP scaling bug, brush size limit, lost unit
names, no hot reload, broken Play Map. (The Unity build also ships API credentials in a plain-text config file;
do not copy or reuse them.)

## 14. Milestones, revised (supersedes the table in section 3)

| M | Name | Contents |
|---|---|---|
| M0 | UI foundation | Widget kit, docking, workspaces, panel registry, virtual lists, overlay scrollbars, command palette, keymap system; then `CMauiCanvas` with native text rendering, clip, file dialogs, file drop; spikes: run-time extra windows (panel pop-out), clean text |
| M1 | Core | `MapDocument`, commit path, command stack, journal and chunked history (save / restore / compare / branches / merge), in-process map open, play / stop snapshot, prop-scale compat layer |
| M2 | Camera and objects | Editor camera, input router, selection, gizmos, outliner, inspector, markers, areas, props, decals, units, templates, asset browser with drag-and-drop |
| M3 | Terrain and brushes | Brush engine and dynamic menu, strata, terrain type, water, lighting, symmetry, import / export, ruler |
| M4 | Lifecycle and validators | Start screen, open from maps folder, release, validator framework (live + full + smoke load), map info, preview render |
| M5 | Mesh suite | F1-F19 and V1-V20 of the mesh report |
| M6 | Scenario editor | M6a: data model, stage tabs, trigger / objective / action nodes, bases by area, compile, run-from-editor. M6b: BaseManager / OpAI tables, compound nodes, Raw Lua, round trip, mission validators |
| M7 | Prop Creator and converters | |
| M8 | Mod / Unit editor | Separate design |

Order rationale: M0 first because every later feature needs panels; M1 before tools because history, undo and thread
safety are far more expensive to retrofit; mesh before scenario (live consumer, golden files).

## 15. Open decisions (with recommendation)

1. **Theme: decided, none.** One pragmatic, clean look; constants in one file; no skins.
2. **Second monitor pop-out: decided, wanted as a run-time user choice.** Needs the run-time multi-head spike in M0.
3. **Free camera and strategic icons: decided, icons stay visible** (bounds-rect variant of `cam_Free`).
4. **Text quality: decided, proper clean text rendering wanted.** Native glyph-atlas text in `CMauiCanvas`, spike in
   M0 (ClearType-style vs grayscale over the world).
5. **Branches and merge: decided, part of the editor** (user, 2026-10-17). A branch ("variant") is a named line of
   saves that forks from any save, so the user can try "more mass" or "naval version" without touching the main
   line, and later merge it back. Merge works per chunk and per region (terrain tile, object list, script stage);
   conflicts show side by side and the user picks a side per chunk or region. Specified in the workflow doc.
   Still open there: git mirror of the text parts, retention defaults, release packaging for the vault.
6. **Mesh: height field decided** (user): the user either supplies a height field, or the editor **bakes it from the
   mesh**, and the user can select **one or several parts of the mesh** (patches, objects or regions) as the source;
   the other parts do not contribute. Bake result is shown with a divergence report. **Prop scaling decided: it must
   work**, as a special compatibility layer: the editor reads and writes per-prop scale (fix `CWldProps::Load/Save`),
   and the file contract stays compatible with the patched retail exe's `MapPropScale` behaviour (the exe patch
   `MapPropScale` is therefore needed and gets tracked in git; how it is stored in the map is specified in M1/M5).
   Still open: SC2-style materials or a simpler one for our own maps; light-mask baker in scope (recommended: yes,
   M5b); how a map enables the Mesh Terrain UI mod in the lobby.
7. **Scenario: coop support decided, required** (user). The editor mounts `lobby_coop.cop` and models coop in the
   mission (see section 11, "Coop"). Open: plain text or `LOC` keys for
   dialogue (recommended: plain text with an optional key); check the `.scunits` template format before designing
   ours.
8. **Brush header:** trace the GPG `.brush` header layout and the 13-entry RAW size table, or skip legacy `.brush`
   import (recommended: import PNG / RAW / DDS first, legacy later).

## 16. M0 spike results (2026-10-17)

Both spikes were read-only code analyses; nothing was built or run. Evidence is in
[SPIKE_EXTRA_WINDOWS.md](editor_research/SPIKE_EXTRA_WINDOWS.md) and
[SPIKE_CLEAN_TEXT.md](editor_research/SPIKE_CLEAN_TEXT.md). The first prototypes below are the real test.

### 16.1 Panel pop-out to other monitors

- **Finding:** "heads are fixed at startup" is true, but not because of the UI manager. `CUIManager::AddFrame` can be
  called any time. The blockers are in the renderer: a head is an implicit swap chain of one D3D9 device, nothing in
  the tree uses `CreateAdditionalSwapChain`, every second-head path is fullscreen-only, and the renderer is
  hard-wired to two heads. Any head-list change needs a full device Reset.
- **Designs:** A) real engine heads, 12-18 days, high risk, wasteful (full world pipeline per head). B) pop-outs that
  are not engine heads, 6-8 days, medium risk. C) second process, 8-12 days plus permanent sync, rejected.
- **Decision (recommended, adopted as plan): design B.** New `moho/editor/EdPopout.{h,cpp}`: a wx frame with a child
  window, its own D3D9 swap chain and its own small Maui root, drawn by one hook at the end of the main viewport
  render; `CUIManager::AddRootFrame / RemoveRootFrame`; a device-event listener rebuilds swap chains after a Reset.
  The head count the game sees stays at the real heads so FAF's multi-head Lua is not triggered.
- **Limits of B:** panels, node graph and lists pop out; **the 3D viewport does not** (a later extension of about
  6-10 days). Popup menus cannot leave a pop-out's client area. No DPI or monitor enumeration exists yet (add
  `EnumDisplayMonitors` and DPI awareness).
- **Prototype natives:** `ed_window_create(x, y, w, h[, title])`, `ed_window_set_rect / get_rect / destroy /
  capture`, `ed_monitors`, and a Lua event callback for close / move / size.
- **Pass criteria:** create, draw a Bitmap and Text, resize (the known +9 px wx client bug), move to monitor 2,
  mouse and keys, cross-window drag, survive a main-window Reset and a Lua-state restart, clean 50x create/destroy
  soak.
- **Open:** hardware cursor over extra windows, `PrintWindow` on D3D windows (fallback `ed_window_capture`),
  present pacing across monitors, key delivery to a child wx window on wx 2.4.2 x64.
- **Question for the user:** is a pop-out viewport required, or are panels enough for v1? (Recommendation: panels
  in v1.)

### 16.2 Clean text rendering

- **Today:** GDI with ANTIALIASED_QUALITY, one glyph at a time, read back with `GetPixel` and encoded into a 1024 x
  1024 DXT5 atlas; integer advances, kerning loaded but unused, BMP-only Unicode, no DPI awareness, integer font
  sizes. All UI text goes through one abstraction, `CD3DFont` (6 members), and one blend technique.
- **Hook:** a new font backend chosen inside `CD3DFont::Create` by a family prefix such as `ed:Segoe UI`. No Maui
  control changes, and retail UI stays pixel-identical.
- **Options:** GDI ClearType 3-4 days (no sub-pixel placement, table kerning only, no fallback). DirectWrite 4-5
  days (system fonts, fallback, kerning, sub-pixel phases). FreeType 7-9 days (identical output on every machine,
  but no system fonts or fallback).
- **Decision (recommended, adopted as plan): DirectWrite** via `IDWriteGlyphRunAnalysis` with the 3x1 ClearType mode,
  built into a separate `edtext.dll` because the DirectX SDK 2010 `DWrite.h` on the engine include path would
  shadow the Windows SDK headers.
- **Atlas:** native A8R8G8B8 glyph sheet with 4 sub-pixel phases, a CPU shadow copy, a layout cache; uploads through
  the existing dynamic texture sheet.
- **Blending on D3D9:** two passes, no known background needed, so it also works over the world. Pass 0 uses
  Zero / InvSrcColor with coverage output; pass 1 uses One / One with coverage times text colour. The blend macros
  already exist and `DrawTriangleList` already loops technique passes. Two techniques (`TTextLcd`, `TTextGray`) go
  into a script-generated editor copy of `primbatcher.fx`. Gamma is a luminance-dependent coverage curve to be tuned.
- **Plan:** P0 offline text lab (about 1.5 days), P1 in-engine grayscale backend with the hook, tested with `/edcmd`
  and screenshots at 11 / 12 / 14 px and DPI 100 / 150 (about 3 days), P2 LCD (about 2.5 days). Total 11-14 days,
  6-7 days for the grayscale MVP. DPI awareness (1 day) is shared with the UI work.
- **Acceptance criteria (9):** centroid steps, kerning, Unicode, sharpness, LCD reference blend within 2/255, cost,
  retail regression.
- **Risks:** draw-call growth from technique and texture switches per text run, header shadowing, atlas survival over
  device Reset, Edit caret and clipping on kerned text, bundled fonts invisible to DirectWrite (needs a custom font
  collection loader).
- **Questions for the user:** must output be identical across machines (decides DirectWrite vs FreeType)? Which UI
  font ships (system Segoe UI Variable, or a bundled Inter)? Is LCD the default or a setting?

### 16.3 Plan impact

M0 gains two prototype stages that run before the rest of the panel work: **M0-A text** (P0 then P1; P2 after) and
**M0-B pop-out** (design B prototype natives). Total native effort for M0: about 7 days text (MVP plus LCD 11-14),
6-8 days pop-out, 3-4 days canvas and clip, plus file dialogs and DPI. Pop-out and LCD text are valuable but not on
the critical path to M1; the MVP text backend is, because every panel is text.

### 16.4 Decisions on the spike questions (user, 2026-10-17)

- **Pop-out scope in v1: panels only.** The 3D viewport pop-out is a later extension.
- **UI font: the system Segoe UI Variable** (Text optical size for small sizes; Segoe UI as fallback). No bundled font in v1.
- **LCD text: a setting, default on.** Gray coverage is used for text over the world and for translucent controls.
- **Output need not be identical across machines**, so DirectWrite stays the choice.
- **Next:** M0-A step P0, the offline text lab, in `editor/textlab/` (own build file, no change to shared files).

### 16.5 M0-A step P0 result: offline text lab (2026-10-17)

Built and ran `editor/textlab/` (DirectWrite, 4 sub-pixel phases, software LCD blends). Full results: [P0_TEXT_LAB_RESULTS.md](editor_research/P0_TEXT_LAB_RESULTS.md).
- **Passes:** sub-pixel positioning (steps 0.23-0.25 px per 0.25), kerning, Unicode incl. surrogate pair, LCD fringes (gray has none), two-pass
  blend within 1/255, cold glyph raster 4.1 ms for 376 bitmaps (budget 40 ms).
- **Criterion 5 (stem coverage 0.90) is wrong as written:** 0.78 in every mode for this unhinted font; replaced by "contrast not below GDI ClearType".
- **Decisions for P1/P2:** sRGB-space blend with plain coverage; optional luma exponent as one constant; natural-symmetric rendering; gray mode
  needs a coverage boost (the mean of the three LCD samples looks dimmer). Legacy text is clearly worse at all sizes.
- **Next:** P1, the in-engine grayscale backend behind `CD3DFont` (`ed:` family prefix), needs edits in the engine tree
  (`CD3DFont.{h,cpp}`, `main_ed.vcxproj`, new `moho/editor/EdTextBackend.*`) which the editor session owns, so it must be coordinated.

### 16.6 M0-A step P1 result: DirectWrite text in the engine (2026-10-17)

The grayscale `ed:` text backend runs in the recovered engine: see [P1_TEXT_BACKEND.md](editor_research/P1_TEXT_BACKEND.md).
`ed:Segoe UI Variable Text` renders with kerning, fractional advances and system-font fallback (Latin, Greek, Cyrillic, CJK) next to unchanged
retail text. It needed one correction to the spike: all batch textures share a 1024 x 1024 **DXT5 atlas**, so glyphs got a second, A8R8G8B8
atlas (`CD3DTextureBatcher(width, height, format)`, selected through the new `CD3DBatchTexture::GetSheetFormat()`), which P2's LCD glyphs will reuse.
Open before M0 text is done: engine-side cost and device-reset checks, fractional sizes and DPI, `Edit` caret and clip, the gray boost constant,
then P2 (LCD two-pass blend). Divergence from upstream is listed in the P1 report.

### 16.7 M0-A step P2 result: LCD text and the P1 measurements (2026-10-17)

Details and numbers: [P2_LCD_TEXT.md](editor_research/P2_LCD_TEXT.md). `ed:Family` now draws ClearType-style LCD text through a two-pass
shader technique (`TTextLcd`, editor `primbatcher.fx` generated from FAF's file and mounted first through `editor/runtime/override`); `ed:Family;g`
draws gray.
- **Cost (250 labels, 4,650 quads, 12 px):** gray and LCD cost 0.47-0.55 ms of CPU per frame in the backend and leave the frame time unchanged (4.17 ms);
  the first LCD version flushed per run (500 flushes per frame, +2 ms) and was fixed by keeping the technique active across runs. Cold frame: 111 glyph
  bitmaps in about 0.2 ms.
- **Device reset:** survives window resizes after the shared atlas clears itself on device exit; the first version showed stray lines.
- **Fractional sizes:** work natively (`SetNewFont`, 1/16 px cache key); FAF's `Text:SetFont` floors the size through `ScaleNumber`, so the editor's own
  widgets call `SetNewFont`.
- **Findings that change the plan:** mounts earlier in `path` win (override folder mounted first); a minimised engine window stops the `/edcmd` poller.
- **Decisions taken:** LCD is the default for `ed:` fonts, `;g` selects gray; plain coverage (boost constants off).
- **Open:** one 525 ms first-use hitch seen once, `Edit` caret and clip, translucent LCD, DPI awareness, BGR order, text outside the UI pass.
- **M0-A status:** the text backend is usable by the widget kit (kerned, sub-pixel, Unicode, LCD or gray, fractional sizes). Remaining text work is polish and
  DPI awareness (shared with the UI scale work).

### 16.8 M0-B result: pop-out prototype, design B (2026-10-17)

Details, test table and open items: [P3_POPOUT.md](editor_research/P3_POPOUT.md). Panels can now live in their own native windows: `ed_window_create / destroy /
get_rect / set_rect / capture`, each window with its own swap chain on the engine's device, its own Maui root frame (`CUIManager::AddPopoutFrame`),
mouse and keyboard input, resize, close, device-reset survival and Lua-state restarts, all tested in the engine.
- **Verified:** create, draw (Maui bitmap, LCD and legacy text), resize and move without a device reset, input in the pop-out's own frame (mouse events at local
  coordinates, characters into an `Edit`), main-window resets with a pop-out open, 2 x 50 create / destroy cycles without a leak (718 MB flat, handles flat),
  `WM_CLOSE`, `LoadMap` with a pop-out open, `GetNumRootFrames` stays 1.
- **Cost:** a pop-out is redrawn every frame; 3 static pop-outs raise the main frame from 4.17 ms to 6.0 ms. Needs dirty-only or throttled redraw.
- **Not yet tested:** a second monitor and remembered rects, cross-window drag, hardware cursor shape, DPI per monitor, real keyboard / IME, a Lua event
  callback for close / move / size, destroy-all at shutdown, slot reuse.
- **Next for M0:** the Lua panel layer on top (`Panels.Register`, dock tree, workspaces) can now assume a pop-out window per detached panel group. The effort
  estimate of 6-8 days for design B held for the core (about one working session of prototyping for create / draw / input / reset); polish is the rest.

### 16.9 Decisions of 2026-10-17 (third round)

- **Mesh materials:** one path only, the SC2-style materials the mesh renderer already supports. No simplified alternative.
- **Light-mask baker: in scope**, and it serves **Forged Alliance maps too**, not only mesh maps.
- **Engine tree:** the nested clone `engine_decomp/faf-re-upstream` now has a local branch `editor` (not pushed, base upstream `13ce9e5`) holding the editor session's work and
  the prototypes (`15010b7`, then `cee0942` for the pop-out polish). Commit engine work there; `editor/engine_patches/` is only a historical subset.
- **Baked-lighting research** ([BAKED_LIGHTING.md](editor_research/BAKED_LIGHTING.md)), summary:
  - FAF has **no lightmap**. "Baked lighting" is the *terrain info texture* (`env/layers/mapInfo.dds`) loaded into the `.scmap`'s **Stratum 7 albedo slot**; the terrain shader
    reads **A as baked sun shadow and G as baked ambient occlusion** (R is water depth for one shader family) and switches it on when the Stratum 7 albedo scale exceeds the
    map size (`terrain.fx`). No binary patch is needed; the cost is that the Stratum 7 paint layer is lost. Decals share the baked shadow; units and props do not read it.
  - The FAF Map Editor contains **no baker**: its button runs `neroxis-toolsuite export-map-info` and loads the result. The Neroxis baker is weak (height-field-only azimuth
    march, constant AO).
  - SC2 light masks: three RGB radiosity-normal-map masks (Half-Life 2 basis) over a unique UV2 atlas, alpha 0 = sun occlusion, alpha 1 = layer-blend paint (must be preserved);
    564 shipped files, DXT5, one mip. No SC2 baker exists in the workspace.
  - Proposal: **one baker** = scene rays (height field plus props, or a triangle BVH) x sample domain (ground grid, or UV2 texels) x encoder (info texture or RNM masks),
    CPU with background tiles, draft / normal / final quality, incremental from the commit path's dirty rectangles, live preview through the engine slot, validators BL1-6 and
    BM1-6. Effort about 12 days for the FA target, about 23 with the mesh target.
  - **Recommendations (not yet confirmed by the user):** default bake = terrain-only shadow in A and props in AO (the dynamic shadow map already casts props); build the FA
    info-texture baker in M3/M4 (it helps every map) and the mesh RNM baker in M5b; drop the legacy shadow-decal export; start with validation of imported UV2 and add our own UV2
    generation later.

## 17. M0 UI framework: first working slice (2026-10-17)

Lua on the game's own Maui, in `editor/runtime/lua/editor/gui/` (no engine change beyond the pop-out natives). Started with
`import('/lua/editor/gui/dev.lua').Restart('Terrain')` (the edit-test loop: stop shell, reload modules, start) or `shell.Start(workspace)`. It is **not yet wired into the editor's
start-up** (the existing `ui.lua` shell stays until its tools become panels).

| Module | What it does |
|---|---|
| `skin.lua` | One set of colours, sizes and the `ed:` font; UI scale (`S(n)`, `FontSize(n)`); no theme system |
| `widgets.lua` | `Place`, `Label`, `Button` (toggle), `VirtualList` (pooled rows, whole-row scrolling, wheel, overlay scrollbar with draggable thumb), `TextField` |
| `panels.lua` | Panel registry (`Register{id, title, create, transparent}`); mods register panels the same way |
| `dock.lua` | Dock host: split / tab-stack tree per Maui root frame; draggable splitters; tab dragging with drop zones (join tabs, split at an edge); drop outside the host tears the panel off into a pop-out window; panel controls survive chrome rebuilds |
| `workspace.lua` | Presets (Terrain, Objects, Review), serialization, save / load (`workspaces/<name>.lua`) |
| `commands.lua` | Command registry and the **command palette** (filter field, list, Enter / click runs, Esc closes) |
| `keys.lua` | Hotkeys from the command registry through the engine key map (`IN_AddKeyMapTable`), exclusive of game hotkeys, nothing written to preferences |
| `shell.lua` | Top bar (workspace tabs, Commands, Reset, UI scale), main dock host, status bar, pop-out lifecycle (tear-off, 'size' events, closing redocks the panels) |
| `model.lua`, `panels_builtin.lua` | Sample model and panels (outliner with 2,500 items and a filter, properties, console, brushes, transparent viewport) |

**Verified in the engine (posted input, screenshots):** shell renders (tabs, LCD text, transparent viewport hole, 2,500-row virtual list); wheel scrolling, row click, selection
updating the Properties panel; workspace buttons; splitter drag (ratio 0.20 -> 0.27); tab drag joining another stack (empty split collapses); tab drag out creating a pop-out
window with its own dock host and panel; closing that window with the X button redocks the panel; UI scale 75 % rebuilds everything at the new size; command palette opens,
filters while typing and runs the selected command with Enter; layout save, reset and load round trip; a bound key (F9) runs its command. Cost: `Layout` 0.6 ms, full `Rebuild`
1.4 ms, frame time unchanged (4.17 ms) with a relayout every frame. Pop-out polish: redraw only on input / resize / invalidate / 100 ms heartbeat (3 static pop-outs 6.0 -> 4.15 ms),
second monitor works (this machine has two), window events for Lua (`ed_window_poll_event`), id reuse.

**Maui and Moho traps found while building it** (each cost a debugging round; keep them in mind for every panel):
1. **Siblings share one depth and the first created wins hit testing and drawing.** Give backgrounds, rows, scrollbars and buttons explicit `Depth` offsets (the widgets do).
2. **Module variables set to `nil` do not exist** (strict globals): reading one throws. Use `false` for "none" (`palette`, `selection`).
3. **Closures in `for` loops capture the loop variable, which is nil afterwards** (the CLAUDE.md rule): copy it to a local before building lazy variables.
4. Maui has **no child clipping**: lists scroll by whole rows and show only rows that fit.
5. `Text:SetFont` floors the size; fractional sizes need `SetNewFont` (the widgets use it).
6. Only `Edit` controls take keyboard focus; global hotkeys go through the engine key map, not a focus holder. The engine reads modifier state from the real keyboard, so posted
   test messages can only exercise unmodified keys.
7. `import` caches modules per process: `dev.Restart` drops the GUI modules; a Lua state restart (`LoadMap`) recreates all root frames empty, so the shell must be started again after it.

**Open (next):** tab reordering inside a stack and tab close; scrollbar auto-hide; dropping onto another window's host (drag across windows) and pop-out workspaces restored
on the right monitor; a per-user folder for saved layouts (with the file dialogs); wiring the shell into `control.lua` and moving the existing tools into panels; accessibility
(keyboard navigation of lists and tabs); native `CMauiCanvas` for node-graph wires and clipping.

### 17.x Shell wired into the editor (2026-10-17)

- The docking shell is now the editor's default UI (`/oldui` keeps the legacy panel). `control.lua` calls `ui.Create{ shell = true }` and then `shell.Start('Terrain', { editor = true })`; `ui.lua` keeps all editor logic (tool state, undo, save, play) and the shell only shows it (`gui/panels_editor.lua`: Tools and Brush panels, status line from `ui.StatusText()`).
- Verified in the engine with posted input: brush stroke (undo 1, mound visible), marker, area, Undo, Save, Play test (shell hides, Pause/Stop bar, game HUD), Stop (autosave reloaded, shell back).
- Trap: a Maui container that does not call `DisableHitTest()` swallows every click, and an unhandled click never falls through to the world view below. Dock root, chrome, tab group and the transparent viewport holder now disable hit testing.
- Trap: `dev.Restart` must keep the editor flag, else the shell is not connected to `ui.OnModeChange`.

## 18. M8 Mod / Unit editor: scope (user, 2026-10-17; design document still to be written before M8 starts)

**Product:** mod creators work inside the editor: preview animations, unit effects and projectiles in the engine, change unit stats, test them in game
within seconds, import meshes, validate, and generate the mod files. One editor for unit, effect, projectile and animation. Plus a **unit icon generator**
whose output matches the vanilla icons.

**Why it fits the architecture:** the editor is the game engine, so a preview is the real renderer, the real effect system (`CreateEmitterAtBone`, trails,
beams) and the real animation controller, not an approximation. Blueprints are Lua loaded by the game's own loader, so an edit can be applied and the
unit respawned without leaving the editor. Meshes (SCM), animations (SCA) and textures (DDS) already have readers in `editor/core`.

**Parts (each a panel set in the shell):**
1. **Unit viewer:** orbit camera, wireframe / bones / hitbox / collision / weapon-range overlays, team colour, lighting presets, LOD switch.
2. **Animation viewer:** list the unit's `.sca` files and the blueprint `AnimationWalk` / `AnimationOpen` etc., scrub and loop, bone selector, speed.
3. **Effect and projectile preview:** pick an effect template (`/lua/EffectTemplates.lua` groups) or a projectile blueprint, spawn it on a bone, replay, show
   emitter count and cost; edit emitter `.bp` fields live.
4. **Stats and blueprint inspector:** a form over the blueprint (economy, weapons, intel, physics, categories) written as a **merge blueprint** (delta only,
   never a whole copy), with the base value shown beside each field; presets from the unit's tech tier.
5. **Test in game:** spawn the edited unit in a blank test map with a dummy target, quick commands (move, attack, build), and a restart that re-reads the
   blueprint. Same edit / play / stop loop as the map editor.
6. **Import and validate:** mesh import (source mesh to SCM with bones, UVs, LODs), texture import to the unit's DDS set (`_Albedo`, `_NormalsTS`, `_SpecTeam`),
   then validators: missing files, bone names used by blueprint / scripts, weapon labels vs script names, ID casing, categories, footprint, icon present.
7. **Generate files:** `<id>_unit.bp`, `<id>_script.lua`, projectile and effect stubs, `<mod>_mod_info.lua`, strings, build-menu entry; mod folder written
   under the editor's mod project root.
8. **Unit icon generator:** below.

**Unit icon generator.** Findings from `_asset_index`: vanilla icons are `/textures/ui/common/icons/units/<ID>_icon.dds`, 538 files, two file-size classes
(4224 B = 64 x 64 DXT5 without mipmaps, 5616 B = the same with some mipmaps; to be confirmed from the headers) and carry an **alpha channel** (transparent
background). The generator renders the unit offscreen with a fixed recipe so every icon matches the set:
- camera: yaw / pitch / distance / FOV and a fit rule (bounding sphere of the mesh fills the frame with a fixed margin), stored as a named recipe;
- lighting: one fixed sun and ambient rig, no map lighting, no shadows (or a soft one, to be matched), team colour as a setting (vanilla icons are neutral);
- output: 64 x 64 (size setting for HD variants), alpha from the render (clear colour alpha 0, premultiplication handled), DXT5 DDS with the mip chain chosen
  to match, plus a PNG preview;
- **matching the vanilla set** is measured, not eyeballed: render a batch of vanilla units with the recipe, compare against the shipped icons (per-pixel
  difference, silhouette overlap), and tune the recipe until the error is small; the comparison view overlays our render on the vanilla icon.
- batch mode: all units of a mod, one command, skip units with a hand-made icon.

**Dependencies:** M1 core (command stack, snapshot), M7 mesh / texture import and material setup (shared with the Prop Creator), the offscreen render path
(also needed for the map preview and minimap in M4), and the blueprint merge writer. Order inside M8: viewers first (1-3), then inspector and test loop
(4-5), then import / validate / generate (6-7), icon generator (8) as soon as the offscreen path exists because it is small and independent.

**Open questions for the M8 design document:** exact vanilla icon recipe and file format (read the DDS headers), whether effects are edited as `.bp` data
only or also as Lua templates, how a unit's script is edited (text editor panel vs forms only), and how much of animation authoring (bone keyframes)
is in scope versus viewing and re-timing.

### 17.y Viewport hole sizes the world view (2026-10-17)

- The `viewport` panel makes the engine's `viewLeft` follow its holder (`Left/Top/Right/Bottom` lazy variables, as the game's split view does); play mode releases it to fill the window, edit mode re-attaches it. The camera, picking and aspect ratio now match the visible hole; workspace switches move it (checked: Terrain, Objects, Review).
- Trap (calibrated in the engine): `UnProject(view, v)` takes **window** coordinates and so does a mouse event, but `view:Project(p)` returns coordinates **local to the view**. Overlays drawn in window space must add `view.Left()` / `view.Top()`. The two only agree while the view fills the window.
- Known, not caused by this change: 2 circular-LazyVar warnings per shell restart (an unplaced control); to be found when the framework gets its error-trace pass.

## 19. Object tools, overlay and resource validation (2026-10-17)

**What exists (all verified in the engine with posted input):**
- **Overlay renderer** (`EdOverlay.cpp`, engine branch `editor`, hooked into `CUIWorldView::Render` after the projectile arcs, main view only). Lua registers
  retained primitives, the engine draws them every frame: `ed_overlay_set(id, points, color, worldWidth, minPx, maxPx, closed, halo)` is a terrain-hugging
  ribbon with a width in world units that never gets thinner than `minPx` (distance-scaled thickness) and a dark halo; `ed_overlay_icon(id, x, y, z, texture,
  px, color)` is a constant-size textured square at a world point; `ed_overlay_remove / clear / count`. Coordinates handed to the batcher are view-local pixels.
- **Areas** are terrain-aligned boxes (sides sampled every 2 units), brighter and thicker when selected, with 8 resize handles when exactly one area is selected.
- **Markers** are drawn the way the game and the GPG editor do: the template's prop mesh as a sim entity (`EdMarkerSync`; Mass / Hydrocarbon also get the
  deposit prop and the ground splat like `ScenarioUtilities.CreateResources`; path nodes have no mesh and get no prop), plus a distinct **icon per type**
  (`editor/tools/gen_marker_icons.py`: badge shape = family, template colour, white glyph; `army` for start positions, `default` for mod types), because the
  props vanish beyond their LOD distance. Selection and hover are ring textures under the icon.
- **Select tool:** click, shift+click toggles, drag on empty ground draws a selection box (markers by position, areas by centre), dragging a selected object
  moves the whole selection as one undo step, area handles resize. Delete / Ctrl+Z / Ctrl+Y / Q M A are commands with key bindings.
- **Cursors:** brush crosshair per mode (+ - = ~ .), pin for markers, box crosshair for areas, pointer / move cross / resize arrows for the select tool
  (`gen_cursors.py`, set through the world view's `Cursor` table). Brush ring and marker / area ghosts are overlay lines under the pointer.
- **Panels:** Markers (palette from `MarkerTemplates.lua`), Outliner, context-sensitive Properties (marker, area, multi-selection, tool help, map), Validation.
- **Resource footprints:** Mass and Hydrocarbon markers show the skirt of their structure from the unit blueprint (2 x 2 and 6 x 6) as a box.
- **Validation** (`validate.lua`): *stacked* = footprints of two resource markers overlap (checked in Lua); *blocked* = the sim's own `CanBuildStructureAt` says no.
  The editing sim has no deposits, and mex / hydro need one, so `ed_sim_clear_deposits` + `CreateResourceDeposit` recreate them from the markers first.
  Results come back through a result file; validation re-runs by itself after the markers or the terrain changed. Offenders get a red / orange footprint and
  a tinted icon; the panel lists them, a click selects and frames them.
- Undo for object edits is `history.lua` (one order with terrain strokes); it goes away when objects move onto the native MapDocument stack (M2).

**Facts measured, worth keeping:**
- Mex and hydro blueprints have `MaxGroundVariation = 512`: steep ground does not block them (a 250-unit cliff under a mex builds); water, the map edge and
  other structures do. Do not invent slope rules for them.
- `view:Project` returns view-local coordinates, `UnProject` and mouse events use window coordinates. The camera's viewport is set from the control rect in
  `CUIWorldView::DoRender`; before the shell attaches the world view it is the whole window.
- The world view does not exist yet when the shell starts: the viewport panel retries every frame (`EnsureWorldView`).
- `link.exe` fails with LNK1201 (PDB write) while a test instance of the engine runs: stop it by PID before building.
- A minimised engine window stops the `/edcmd` poller and posted-input tests; restore it first.
- Marker props only render within their LOD cutoff (about 230-280 zoom); icons and the footprint boxes do not depend on it.

**Not done yet:** marker orientation gizmo, drag-copy / duplicate, snapping, area polygons, marker chains / graph editing and path-node validation (reachability),
blocked-footprint reasons beyond water / map edge, the validators' tier-2 / tier-3 rules, moving this history onto the native command stack.

### 19.1 Follow-up round (2026-10-17, later)

- **Marker visuals moved to the UI lane.** The marker mesh, the deposit mesh and (new) the ground splat are `WorldMesh` objects plus a native ground decal
  (`ed_overlay_decal`), updated every frame, so dragging a marker no longer lags a sim tick behind and no splats are left behind (the sim version leaked decals).
  The sim callback `EdMarkerSync` is gone. Marker heights follow the terrain (the stored `position[2]` is refreshed when the ground under a marker changes).
- **Build grid** (`grid.lua`, `Grid` button / `G`): the grid of the game is fixed to the map, not to the pointer. Lines at whole world coordinates over the part of
  the map the camera sees (plus a margin), every 4th brighter, coarser (4, 16, 64) when the cells get small, sampled finer than the spacing so they follow slopes,
  rebuilt only when the view leaves the built region. The visible region is found by unprojecting the view corners.
- **Snapping and alignment:** structures sit on the 1 x 1 cell grid; the centre of an odd footprint is n + 0.5, of an even one n. Mass (1 x 1) and Hydrocarbon (3 x 3)
  markers snap on placement and when dragged (typed coordinates stay exact). The validator flags **unaligned** resource markers (yellow footprint) and structure units
  of the armies that are off the grid; `Snap to grid` fixes the markers in one undo step. Footprint (solid) and skirt (faint) are both shown; skirt and footprint come
  from the unit blueprints (`Footprint`, `Physics.SkirtSizeX`).
- **Resize fix (engine):** after a window-border drag every frame failed in `Present` (black window). `CD3DDevice::Clear()` opened a scene, its depth clear throws by
  design when no depth-stencil is bound, and the scene was never ended. It now always ends the scene, `Paint` closes a scene left open by a failed frame, and the frame's
  size sync re-reads the live client size (wx 2.4.2 reports a client size that differs from the one requested). Verified with a real border drag and with maximize / restore.
- **Cursors over the panels:** the editor's pointer is the default cursor while the shell runs (the game's own cursor again in play mode and after `Stop`); the dock
  splitters show the resize arrows. Pointer rings crossing a steep wall are kept within the ring's radius of the pointer height.
- **Test harness traps:** the engine idles (no frames, no `/edcmd`, no log) while its window is not the active application. `SetForegroundWindow` is not enough; a real
  click on the title bar wakes it (`C:/tmp/restore_win.ps1` pattern: restore if minimised, click the title bar, put the cursor back). A 512-unit terrain spike (word limit)
  is a wall for every terrain-hugging line: test with realistic hills.

**Roadmap:** buildability overlay (cells where a mex / hydro / any footprint can or cannot be built, from the sim's build check), grid-snapped placement for units and
structures, a settings panel for snap and grid step.

### 19.2 Slope view (2026-10-17)

The engine rates slope in two ways, both read from its own code and computed natively from the live height field (`EdOverlay.cpp`, `ed_overlay_slope`,
`ed_slope_at`; the gradient is drawn draped over the ground, one quad per 1-unit cell like the engine's cells):

- **Mobile units** (`STIMap::OccupancyCapsOfFootprintAt`, `OCCUPY_MobileCheck`): a footprint of N x N cells is blocked when the largest height difference between
  neighbouring samples inside its window exceeds the footprint's `MaxSlope`: 0.75 for every land, amphibious and hover footprint (`lua/footprints.lua`), in world
  units per cell. Bigger footprints see a bigger window (the Footprint stepper). Air and naval footprints have no slope rule. (Unit blueprints with `Footprint.MaxSlope = 0.25`
  are air units: no effect.)
- **Structures** (`OCCUPY_CheckAreaFlatness`): the height range (highest minus lowest sample) over the skirt must stay within `Physics.MaxGroundVariation`: 1.1 for most
  structures, 1.0 when unspecified, 1.2 and 50 for a few; mass extractors and hydrocarbon plants allow 512, i.e. they ignore slope (the Next button steps the limit).
  The skirt is taken as N + 1 samples per side (the engine's rect convention for the area check was not pinned down further).
- **Colours:** clear below 4 % of the limit, green, yellow at half the limit, red at the limit, purple beyond it (blocked). The status line shows the rating of the cell under
  the pointer (`slope 0.62 / 0.75 (1x1)`), the View panel (and `S`, or the Slope button) holds mode, footprint size and legend. Verified: the native ratings equal a hand
  calculation from `ed_terrain_get` cell for cell.
- **Not covered yet:** terrain-type "blocking" cells (`STIMap::IsBlockingTerrain`, from TerrainTypes.lua and the terrain-type layer), water depth limits, and the
  `FlattenSkirt` perimeter check (`OCCUPY_CheckEdgeFlatness`) that normal structures use on top of the flatness rule.
- The grid and slope views draw without a map document (they used to wait for the first edit).
- **Wide views:** the whole visible region is rated (separable passes, cost about cells x footprint) and drawn in blocks of N x N cells once it is wider than 190 cells, each
  block showing the steepest cell it contains so a thin cliff never vanishes when zoomed far out. Ratings are cached and refreshed every 20 frames or when the view, mode
  or footprint changes. (A first version capped the region at 190 cells and cut the gradient off at far zoom.)

### 19.3 GUI fixes (2026-10-17)

- **Hidden panels showed through.** `Hide()` on a panel's holder is not enough: panels that refresh themselves (lists, outliner, View, Properties) show their child
  controls again, and Maui draws a child that was shown explicitly even under a hidden parent. A hidden holder now also leaves the screen (-20000), and everything in it with it.
- **A tab switch rebuilt the panel** (lost scroll position, selection, edited text) because every layout pass called `OnResize`. `Host:PlaceHolder` now only calls it
  when the size really changed.
- **Workspace layouts are kept** while the session runs: leaving a workspace remembers how the user arranged it, `Reset` restores the preset. (Not saved to disk yet.)
- **Text no longer runs into the next panel** (Maui does not clip): `Widgets.Fit` cuts list rows with "...", `Widgets.Paragraph` word-wraps help text to the panel width
  (View notes, tool help, selection help).
- **The mod dialog** is centred and drawn above the panels (it used to sit under the tool panel at a fixed position).
- The select tool loads the map document on first use (a click on empty ground before the first edit raised a Lua error).

### 19.4 Brush settings, camera, hotkey manager, permanent-black fix (2026-10-17)

- **Brush panel**: Radius, Strength, Falloff each with a draggable bar (`W.Slider`, strength on a squared scale), - / + buttons and an editable
  value field (Enter applies, values are clamped), plus a profile preview of the brush weight. The world preview keeps its last position while
  the pointer is over a panel, so settings can be tuned with live feedback (the preview used to vanish when the pointer left the world, which
  looked like "does not update"). The Properties panel refreshes live while a brush tool is active.
- **Camera** (`camera.lua`): `cam_Free` on, nothing resets the view by itself. Mouse gestures (rebindable): pan = middle drag, rotate = Alt + left
  drag or right drag, zoom = Ctrl + middle drag; the wheel zooms to the pointer as before. Held keys, polled per frame (Shift = 3x): W/A/S/D and the
  arrows move, Q/E turn, PageUp/PageDown tilt, Z/X zoom. One-shots: Home reset view, N face north, T top-down, F focus the selection. The game's own
  key map is cleared by `Keys.Apply{exclusive=true}`; the tool hotkeys moved to 1 / 2 / 3 (select, marker, area) and the slope view to H.
  `IsKeyDown` is already false while the window is in the background or a text field has the keyboard, so typing never moves the camera.
- **Hotkey manager** (`gui/hotkeys.lua`, panel "Hotkeys" next to Properties): every command and camera gesture with its binding, Bind / Bind 2nd
  (press the key; mouse gestures: press the button with the modifiers), Clear, Default, Reset all; a key already used elsewhere is taken from the
  other command; saved in `config/editor_hotkeys.lua` and loaded before the key map is applied.
- **Permanent black window (engine)**: `WRenViewport::D3DWindowOnDeviceRender` set `gRenderLock` and cleared it only on a normal return. One
  exception inside a frame (here: the bloom pass's `StretchRect`, `DeviceD3D9.cpp(637)` Invalid call) left the lock set, every later paint returned
  at once, and the window stayed black while Lua kept running (found by walking the main thread's stack with the PDB, `editor/tools/stackwalk.py`: dbghelp `StackWalk64`; reading `sDevice` then showed clear mode off and an otherwise normal device). The lock is now
  released by a scope guard, and a failing bloom seeding blit skips bloom for that frame instead of aborting it. The trigger of the single failed
  blit is still unknown (a device reset or resize leaving a bloom target that does not match the back buffer is the suspect).

### 19.5 Workspaces own their tools, menu bar, context menus (2026-10-17)

- **Document at start.** The shell loads the map document when it starts (`ui.EnsureDocument`). Before, the select tool loaded it on first
  use, so the map's own `ARMY_1` start marker (it is in the blank map's `_save.lua`) seemed to appear out of nowhere.
- **Workspaces own their tools** (`ui.Workspaces`, `ui.SetWorkspace`): Terrain = brush tools, Objects = select / marker / area / mod tools,
  Review = select (inspect) and camera, read only (`Tools.ReadOnly`: nothing in the document changes, Undo / Redo are hidden). The tool
  panel lists only the tools of the showing workspace, a tool of another workspace cannot be selected, and switching to a workspace that
  excludes the current tool selects its default (Terrain: raise, Objects / Review: select). The digit keys pick the Nth tool of the workspace.
  The three layouts share one skeleton (tools top left, the context panel under them: Brush / Markers / Outliner; viewport; properties right;
  console / validation below), so the brush panel no longer jumps sides.
- **Menu bar** (second row above the tabs): File, Edit, View, Workspace, Window, Help; hovering another title switches the open menu.
  `gui/menu.lua` is the popup widget and the registry (`Menu.Extend(id, fn, order)`, ids `menubar.<Title>`, `context.world`,
  `context.object`, `context.list`), `gui/menus.lua` registers the editor's own entries. Entries run commands, so a menu item, a key,
  the palette and a button are one action; mods extend any menu with `Menu.Extend`.
- **Context menus.** A short right click in the viewport (a right drag still rotates) opens `context.world` (coordinates, the marker or
  area under the pointer, place marker, camera); right click in the outliner, marker palette and hotkey list opens `context.list`.
- Trap fixed on the way: a menu row handler read the `for` loop variable after the loop (nil), so rows did nothing; rows copy it to a local.
- **Insert / Delete rotated the camera** (the "paste and delete keys"): not the key map, but `CUIWorldView::Frame` polls Insert / Delete (rotate),
  the arrow keys (pan) and the screen edge (pan) while the view `GetsGlobalCameraCommands`. The editor switches that off for its world view
  (`panels_builtin.AttachWorldView`; a test run switches it back on). Testing note: `IsKeyDown` is false unless the engine window is the
  foreground window, so key tests must foreground it first (`SwitchToThisWindow`) and use real key events (`keybd_event`), not posted messages.
  Arrow keys are named `UpArrow` etc. in the key name table.
- **Undo of terrain strokes** stopped working: the native command stack counts a stroke at its first write (`ed_cmd_depth` goes up at the first dab),
  but `ui.EndStroke` compared the depth before and after ending the stroke, saw no change and never recorded the stroke in `history.lua`.
  `ui.BeginStroke` now remembers the depth from before the stroke. Checked with real Ctrl+Z / Ctrl+Y.
- **Overlapping panels.** Maui does not clip, so a panel with more content than room drew over the panel below (the View panel's slope note over
  Properties). While the dock creates or lays a panel out it now sets a clip height (`W.SetClip`); `W.Place` / `W.Label` move whatever would end below it
  off the screen, wrapped paragraphs are cut with "..." (`W.Paragraph(..., maxBottom)`), and panels that place everything at creation
  (`rebuildOnResize`, the View panel) are created again when their size changes. What does not fit is not shown until the panel is taller.
  Real clipping needs the canvas clip rectangle planned for the native canvas.
- **Camera focus** is kept within 25% of the map size around the map (held keys at far zoom used to fly the focus off; the engine then tilts the
  camera by itself). The pitch itself stays where you put it (checked over time and through wheel zoom).

### 19.6 Terrain strata: layers panel and paint / erase brushes (2026-10-17)

- **Natives** (`moho/editor/EdStrata.cpp`): `ed_stratum_info` (mask size, 128 x 128 for the 256 map: half the height-map resolution), `ed_stratum_layer(i)` /
  `ed_stratum_set_layer(i, path, tileSize)` (0..9 albedo = base, eight painted layers, upper; 10..19 their normal maps; a changed layer loads its texture
  through `CStratumMaterial::SetSize`), `ed_stratum_read` / `ed_stratum_write` (mask rectangles; the engine's own `GetStratumMask` / `UpdateStratumMask`).
  The map writer saves the same textures, so painted masks and layer paths end up in the `.scmap` (paths checked in the saved file).
- **Engine fix on the way:** `CWldTerrainRes::GetStratumMask` passed the "keep the other lanes" mask table to `GetTextureChannel`, which isolates a lane with
  `pixel & mask`; reading a painted mask returned zeros. It now passes the complement. (The decomp had no caller that read masks back.)
- **Lua:** `strata.lua` (layer list, `Active` layer, stroke painting on the mask with the brush's weight and falloff, undo entry per stroke in the shared
  `history.lua` order; `terrain.lua` hands paint / erase strokes to it, `ui.EndStroke` pushes the entry), tools **Paint layer** / **Erase layer**
  (Terrain workspace), and the **Layers** panel (tab next to Brush): rows with texture and tile size, click = paint with that layer, albedo / normal
  texture picker over every `/layers/` texture found under `/env`, tile size field, preview, right-click menu.
- **Free camera keeps strategic icons** (user decision of section 9): `cam_Free` no longer hides resource splats and strategic icons in the world view.
- Not done: a texture picker with thumbnails, mask preview / per-layer coverage view, upper layer painting (it has no mask), stratum import/export,
  slope-based auto paint, undo of layer texture changes (they are not on the history).

### 19.7 Why painted layers did not show, and the strata fixes (2026-10-17, later)

- **The blank map's Upper layer was opaque.** The terrain shader lerps the Upper layer over everything below with its alpha
  (`albedo = lerp(albedo, upper, upper.w)`); the blank map's Upper (Evergreen `Dirt001`, a grass texture) is opaque, so the base layer and every painted
  layer were hidden. A layer cannot be unset (an empty path keeps the old texture bound), so "none" is a transparent texture
  (`textures/editor/layers/clear_albedo.dds`, written by `editor/tools/gen_layer_textures.py`, output is gitignored like the cursors). `strata.Normalize()` makes the
  Upper layer transparent when the editor starts on the blank map (and only there); any layer can be given "none" in the picker or the row menu.
- **Layers 5..8 need `TTerrainXP`.** The map's `TTerrain` technique blends strata 0..3 only; `ed_stratum_shader` reads / sets the technique and `strata.lua` switches to
  `TTerrainXP` when a layer 5..8 gets a texture or is painted.
- **Mask encoding.** The shader reads a mask byte as `saturate(2 * m / 255 - 1)`: bytes up to 127 mean nothing. The brushes work on that effective value and store it in the shader's
  encoding; brush strength is the opacity per dab (4 and more = full).
- **Masks are locked with DISCARD.** A partial update (or a read) of a mask texture is undefined outside / inside the rectangle (diagonal garbage stripes). EdStrata keeps a copy of the
  eight masks and rewrites a whole mask texture in one lock per change.
- **Texture browser:** thumbnails on every row, a large preview of the texture under the pointer, a filter, "(none)" first; the Layers list shows a thumbnail per layer.
- A strong normal map (for example `rock_wall_1_symmetric`) lights diagonal stripes into a painted area; that is the texture, not the mask.

### 19.8 Texture brush and layer settings (after the FAF Map Editor's strata window, 2026-10-17)

- **Rendering fix:** a layer with an albedo but no normal map made the terrain shader sample nothing and light the painted area dark (the dark patches and halos).
  Every layer now has a normal map: the matching file next to the albedo (`x_albedo.dds` -> `x_normals.dds`, `x_normal.dds`) when there is one, otherwise the engine's neutral
  `none_normal.dds` (`strata.NormalFor`); layers loaded without a normal map get one at start. Painting with a layer that has no albedo is refused with a message.
- **Texture brush panel** (tab "Texture brush" next to Brush, Terrain workspace): Size, Strength % (the FAF editor's curve, `(s/100)^1.5 * 0.6` per dab), Falloff, Target % (the opacity
  a stroke may reach), Scatter %, minimum / maximum slope angle (cells outside are skipped, from the height samples around the cell), minimum / maximum height, Invert (Paint <-> Erase), Reset.
  Not taken over: rotation (there are no brush shapes yet), the linear-blend toggle, smooth / invert on modifier keys (Alt is the camera's rotate gesture).
- **Layer settings** (Layers panel, right column of the Terrain workspace): albedo and normal pick separately, **separate tile sizes** for albedo and normal, layer order **Up / Down**
  (textures, sizes and masks swap), **Clear / Fill** mask, the **TerrainXP** switch (layers 5..8), thumbnails, remove texture; every change is one undo step in the shared history.
- Tests (scripted, in the engine): default normals, slope / height / target filters, fill / clear / move with undo and redo.

### 19.9 Signed brush strength, Shift inverts, brush stays after a stroke (2026-10-17)

- **Strength is -100..+100 percent** for every brush (height brushes and the texture brush). A negative strength inverts the brush (raise lowers, paint erases, flatten
  moves away from the level, smooth sharpens, noise flips), and **holding Shift inverts again while painting** (`IsKeyDown('Shift')`, read per dab). Height brushes keep
  `Brush.strength` as the magnitude (percent = strength * 10, so the old default 2.0 is 20 %) plus `Brush.sign`, so the self tests keep their units; flatten / smooth blend by
  `strength * 0.2` per dab. `ui.GetStrengthPercent / SetStrengthPercent` are what the panels use.
- **The brush jumped back to where the stroke began** after the button was released: the engine's hover position is not tracked while the dragger holds the mouse, so the
  overlay fell back to the stale position. The last dab position is held (`State.holdPointer`) until the real mouse moves. Checked with a real mouse drag.
- Not run after this change: `selftest_terrain.lua` (it flattens the whole map to 25, which would wipe a map being edited).

### 19.10 Falloff 0..100 %, dabs along the path (2026-10-17)

- **Falloff is 0..100 %** (was an exponent): 0 = a flat disc (full strength to the rim, an edge one grid cell wide so it does not staircase), 100 = a cosine falloff from the
  centre, in between a flat core with a soft edge over that share of the radius (`Terrain.Weight(distance, radius, minEdge)`; the mask brush uses an edge of at least 1.5 mask cells).
  Height profile at radius 10 and 30 % strength: falloff 0 -> 3.0 3.0 3.0 3.0 3.0 0.0 (every 2 units), 0.5 -> 3.0 3.0 3.0 2.7 1.0 0.0, 1 -> 3.0 2.7 2.0 1.0 0.3 0.0.
- **Staircase edges** came from one dab per mouse event (fast strokes left gaps, each flat disc was quantized to the 2-unit mask cells). `ui.StrokeMove` now lays the dabs along the
  path at an even spacing (radius / 3 for height brushes, radius / 8 for the texture brush); the texture brush scales a dab's opacity by its distance to the previous dab, so a stroke
  covers the same at any spacing.

### 19.11 Stroke blending, slider fixes, Environment workspace (2026-10-17 / 18)

- **Texture brush blend** (`strata.lua Brush.blend`, Blend buttons in the Texture brush panel): `max` = a cell takes the strongest dab of the stroke, passes over it add nothing (default, smooth
  edge); `add` = build up, every dab combines with what the cell has (`coverage = 1 - (1 - coverage) * (1 - opacity * weight)`, opacity scaled by the distance between dabs).
  Mask uploads are deferred per mouse event (`ed_stratum_write(..., defer)` + `ed_stratum_flush`).
- **Crashes found with page heap** (IFEO `GlobalFlag 0x02000000` for `main_x64_la_p2.exe`, removed again; remember it slows every allocation): `Cluster::cmp` compared the
  payload of the first cluster against a possibly smaller second one (read past its allocation); fixed by deciding on the node count first. `EdStrata` now refuses a mask whose texture
  size or pitch does not match.
- **Slider widget** used panel-relative geometry against the screen mouse position: broken in every panel not docked at x = 0. It reads the track's own position now.
  Every number setting is a `W.Slider` (field + bar + - / +); Properties position, rotation, amount, size and area coordinates are fields with - / + only (no bar makes sense).
- **Environment workspace** (M3 start): panels Lighting (sun azimuth / elevation, multiplier, bloom, sun colour), Ambient and fog (ambient, shadow fill, fog colour, fog start / end),
  Water (switch, surface / deep / abyss elevation), Water look (colour, lerp, refraction, fresnel, reflections, sun, wave scales). Natives `ed_world_get` / `ed_world_set` in
  `moho/editor/EdWorld.cpp`, Lua side `world.lua` (one undo entry per slider drag). The renderers read the engine fields every frame, so changes show at once; `Save` writes the same
  fields. **Trap:** the engine header names the fog block start / cutoff / clamp / curve; the values of a stock map (0.8 0.8 0.8 1000 2000) show it is fog colour r g b, start, end.

### 19.12 Water surface, symmetry, ruler, heightmap files, terrain types (2026-10-18, autonomous session)

- **Water surface was never drawn:** the water quad (`HighFidelityWater::InitVerts`) is built once at map load at the water elevation of that moment (-10000 for a map without water), and the
  terrain shader's own tint is what moved with the elevation. `EdRefreshWaterSurfaces` (WaterFactory.cpp; per-fidelity hooks in the three terrain files) rebuilds the quad; `ed_world_set(t, true)`
  calls it with the water map rebuild, and every `ed_world_set` raises the decal manager's pending-changes flag so the render context is rebuilt with a still camera. Water look (colour, fresnel,
  reflections, waves) and lighting now change live (checked by screenshot pixel means: sun colour 1 -> 0.1 darkens, water colour blue -> red recolours the water, sun blue 1 -> 0 drops the blue
  channel of a textured area; on the olive blank-map base layer blue has no effect because the albedo has no blue).
- **Symmetry** (`symmetry.lua`, Symmetry panel, overlay axes and brush images): off, mirror left/right, top/bottom, both (4), rotate 180, rotate 90 (4), diagonal, both diagonals (4), with a free centre.
  Applies to height brushes, the texture brush (per-image dab tracking), markers and areas (copies are one undo step through `History.Merge`).
- **Ruler tool** (`ruler.lua`): drag measures a straight line, Shift+drag continues the path; label with units, ground length, height change and slope; View menu clears it.
- **Heightmap import / export** (`heightio.lua`, natives `ed_image_read16` / `ed_image_write16` / `ed_file_dialog` in EdImageIO.cpp, WIC): 16-bit greyscale PNG / TIFF or raw 16-bit; exact round trip,
  resampling to the map grid, one undo step. File menu entries.
- **Terrain type layer** (`terraintype.lua`, natives `ed_tt_*` in EdTerrainType.cpp, Terrain type panel and tool, coloured overlay): paints the TypeCode of `/lua/TerrainTypes.lua` entries with a hard disc,
  Shift paints the default back, undo through the shared history; written to the session's map and the sim's copy. The editor blank map stores 0 (no type) in every cell.
- **Persistence checked:** lighting, fog, water, terrain types, strata masks and layer textures, and heights survive Save + reopen (`persist_test` round trip in the test instance).
- **Traps:** `continue` is a Moho Lua keyword (an import error shows only in the log); a `Dragger` must be imported in every module that creates one; MSVC mangles a top-level `const` parameter
  (`T* const p`) into the symbol, so a definition with it does not match a declaration without it (link error LNK2019 only; the /FORCE link still produces an exe that jumps to null) -
  `C:/tmp/build_deploy.ps1` refuses to deploy when the log has LNK2019.

### 19.13 Props, decals, shapes, start positions, map life cycle (2026-10-18, autonomous session, later)

- **Props** (`props.lua`, Props panel, Properties panel for the settings): catalog of the 554 `/env/**/*_prop.bp` blueprints (marker props excluded), Prop brush (click = one prop at the pointer,
  drag = scatter by density per 100 square units, random scale range and heading, minimum spacing inside a stroke), Erase props (all or only the active blueprint), Select props (click, Shift,
  drag moves the selection; Properties: X / Z / rotation / scale steppers, Delete); every operation is an undo entry (props are removed and re-added, so the sim entity follows). Symmetry
  copies props with mirrored / rotated heading. Verified with the self test scripts and a screenshot.
- **Decals** (`decals.lua`, Decals panel with thumbnails): 738 `*_albedo.dds` decal textures, Decal brush (scatter, size and variance, view distance, with the matching `_normals` decal), Erase decals, undo.
- **Brush shapes** (`brushes.lua`, Shapes panel): 9 procedural shapes (square, diamond, cone, plateau, ring, ridge, mountain, rocks, bump) and greyscale image masks from `/brushes`
  (`python editor/tools/gen_brush_masks.py` writes crater, volcano, canyon, dunes, ridgeline; PNGs are git-ignored, regenerate them); mask angle and random turn per stroke; the shape replaces the
  falloff profile of the height and texture brushes. Trap found: a smoothstep written with `a > b` returned 0 everywhere.
- **Start positions** (`armies.lua`, Start position tool): places `ARMY_<n>` markers (symmetry copies get the next numbers); `Map.SaveAs` makes the scenario's army list and the save file's `Armies`
  table follow the markers (armies not named ARMY_<n> are left alone, so mission maps are untouched).
- **Map life cycle** (`maps.lua`, `gui/dialog.lua`, `gui/dialogs_map.lua`): File > New (5 / 10 / 20 km templates from `scripts/ed_make_blank_map.py`), Open (all 423 maps of the game data in a
  filter list; a real 20 km FAF map with 4141 props opens), Save (back to where the map came from), Save as (common dialog; folder `<name>.v0001`), Map info. The first save of a session over
  existing files copies them to `<maps folder>/../editor_backups/<folder>/<n>/` (outside the maps folder: the game lists every `*_scenario.lua` below it).
- Regression: `selftest_terrain`, `selftest_cmd` (+ `Check2`) and the `selftest_map` Build / Verify round trip all PASS after these changes.

### 19.14 Terrain tools and safety (2026-10-18, autonomous session, end)

- **Terrain menu** (new top-level menu): Generate terrain (`terraingen.lua`: value-noise fractal on a permutation table, rolling / ridged / billow, octaves, persistence, height range, base height,
  island mask, replace or add; 0.17 s for 257 x 257), Flatten the map, Import / Export heightmap. **Ramp tool** (`ramp.lua`): drag between two points, exact linear slope (checked: quarter and mid heights equal
  the line), width and sides from the brush radius and falloff, symmetry images, one undo step. **Auto paint / auto erase** (Texture brush panel): applies the slope and height limits of the texture brush to the
  whole map for the active layer (one undo entry).
- **Autosave**: every 5 minutes, and only when the history version changed, the open map is written to `mapout/_autosave.v0001`; File > Recover autosave opens it (checked: an edit survives the round trip).
- **Committed at last**: `control.lua`, `luaser.lua`, `mods.lua`, `sim.lua`, the self tests, `schook/` callbacks, the example mod and `init_editor.lua` had never been committed (the checkout would not have run).
- **Start-up warnings**: the 12 `circular dependency` LazyVar warnings came from every `VirtualList` being evaluated before `SetRect`; the list now has a first position (6 left, source not found).
- Everything under 19.11 - 19.14 was checked by script (values, undo / redo, save + reopen) and by screenshots of the test instance; nothing of it has been tried with a physical mouse over longer sessions except
  the slider drags, the ruler, the ramp drag and the Open dialog click.

### 19.15 Terrain types from the texture layers (2026-10-18)

- `terraintype.lua` `Generate`: for every mask cell the layers are blended in order (a layer's visible share = its mask value x what the layers above leave free, base = what nothing covers); the cell takes the
  terrain type of the layer with the largest share; written to the whole grid as one undo entry. Option "only unset cells" keeps cells that already have a type.
- Slots: Base and layers 1..8 each have a terrain type. Default = `DefaultFor(texture)` (file-name rules: lava, snow, ice, sand, grass, rock, gravel, dirt, tarmac ... -> the matching `/lua/TerrainTypes.lua`
  entry, Default when nothing matches); a type you assign is marked `*` and travels with the map in `<stem>_editor.lua` (`TerrainTypeLayers`). Panel "Auto type" (Terrain workspace, next to Terrain type):
  list of layers with texture thumbnail and assigned type, click = type list, Defaults, Generate.

### 19.16 Clipboard, validation, bookmarks, decal and unit tools (2026-10-18, later)

- **Copy / cut / paste / duplicate** (`clipboard.lua`, Ctrl+C / X / V / D): markers, areas, props and decals of the selections together; paste centres the group at the pointer; one undo step;
  copied start positions get the next `ARMY_<n>`.
- **Validation** (`validate.lua CheckMap`): no / one start position, mass markers per start position, start positions and resource markers outside the map or under water, props whose blueprint is
  missing, scenario name / description; listed in the Validation panel with the existing resource checks.
- **Camera bookmarks**: Ctrl+n goes, Ctrl+Shift+n saves (1..9), View > Camera > Bookmarks (session only).
- **Decal selection** (`decals.lua`, Select decals tool): picks the smallest decal under the pointer together with its normals decal, Shift toggles, drag moves, Properties: X / Z / rotation / size / delete.
- **Units** (`units.lua`, Units panel, Unit tool / Select units): the 675 unit blueprints of `__blueprints`, placed for an army (a button steps through the armies), stored in the save file's
  `Armies[<army>].Units.Units.INITIAL.Units`, shown by the editing sim (`EdSpawnUnit` / `EdRemoveUnitAt`), move / rotate / delete / change army with undo; symmetry copies units with mirrored heading.
  An army that was added in this session (a new start position) has no brain in the running sim: its units appear after saving and reopening. Save + reopen keeps the unit and the sim spawns it again.

### 19.17 Gizmo, unit clipboard, playable area (2026-10-18, later)

- **Transform gizmo** (`gizmo.lua`): with a select tool (Select, Select props / decals / units) and a selection, a red x arrow, a blue z arrow and a yellow ring appear at the middle of the selection. The press is taken
  before the tool sees it: an arrow moves the selection along that axis only (props / decals / units preview the offset live, markers and areas apply on release; markers snap to the build grid), the ring turns every
  selected object about its own centre by the angle the pointer travels around the gizmo. Checked with real mouse drags (x arrow: x 130 -> 151.8, z unchanged; z arrow: z 125 -> 142.2, x unchanged; ring: 90 -> 1 degree).
- **Units** are copyable (clipboard) like everything else.
- **Playable area** (`playable.lua`, Terrain > Playable area...): edits the area `AREA_1` of the save file; `Map.SaveAs` adds `SetPlayableArea('AREA_1', false)` after `ScenarioUtils.InitializeArmies()`
  of the map script when the area exists and the script does not call it (a script without that line is left alone and a log line says so). Checked: the saved script compiles, the save file has the area, a
  play test runs without script errors.

### 19.18 Preview, plateau / erode, mesh terrain manifest (2026-10-18, later)

- **Map preview** (`preview.lua`): saving from the editor writes the 256 x 256 lobby picture into the `.scmap` (top-down render: each texture layer's average colour weighted by its visible share, hill shade from the sun,
  water tint). Natives `ed_image_avg` (WIC average colour, also from inside `.scd` / `.nx2` archives) and `ed_scmap_set_preview` (replaces the DDS blob at the header). Autosave and play test skip it.
- **Plateau and Erode brushes** (`terrain.lua`): plateau pulls the ground to the stroke level in one go (shoulder from the falloff); erode is thermal erosion (talus 0.9 sample, 3 passes per dab). Flatten / plateau have a
  Fixed level toggle and slider in the brush panel.
- **Mesh terrain manifest** (`meshmap.lua`, panel `gui/panels_mesh.lua` "Mesh terrain", Environment workspace): the reader / writer follows the dialect of `scripts/meshmaps/convert.py` (MESH_MAP_EDITOR_NEEDS.md 1.3): one
  entry per line, single-quoted strings, fixed decimals, key order. `Write(Parse(text)) == text` byte for byte on a convert.py-shaped manifest (self test `selftest_mesh.lua`); anything off-dialect (exponents, double
  quotes, two settings on a line, unknown keys) is a warning. The panel loads / creates / saves the manifest, takes size, playable area, water, ground heights and sun from the map ("Sync map"), edits any setting
  with a slider, and switches the scenario fields `TerrainSystem` / `TerrainMesh`. Saving the map into a new folder copies the terrain folder (files the manifest names, only when missing or a different size)
  and rewrites `TerrainMesh` to the new folder.
- **Checks** (validators of MESH_MAP_EDITOR_NEEDS.md section 3 that need no mesh renderer): V1 SCM header / limits / index range, V2 material indices and unused materials, V5 textures and water files exist, V9 playable
  rectangle vs map and AREA_1, V11 size, V12 water vs map, V13 water file sizes, V14 height maximum, V15 ground / mesh heights ordered, V18 dialect, V19 scenario lines, V20 budget (info). Checked against a generated
  fixture (real SCM files from `scm.py`) and a corrupted copy (truncated patch, wrong material index, short water file): each finding fires. Not done: V3, V4, V6-V8, V10, V16, V17 (need the mesh / textures decoded),
  mesh import and splitting (F3-F5), and rendering the mesh in the editor (the renderer is a separate x86 patch).

### 19.19 Mission suite, first slice: army setup (2026-10-18, later)

- **Army setup** (`armysetup.lua`, panel `gui/panels_armies.lua`, new **Mission** workspace): armies of the save file in index order (the army index is the position in `Configurations.standard.teams[1].armies`; `Sync`
  of `armies.lua` now keeps that order and writes `ArmyIndex` = position), with faction (UEF / Aeon / Cybran / Seraphim), colour (0-19, `GameColors.ArmyColors`), start mass / energy and the alliance every army holds
  towards the others (one direction per army like `SetAllianceOneWay`, "Both ways" sets the other side too). Add (name dialog), Remove (not for `ARMY_<n>`, which follow their markers), Up / Down, all with undo.
  Checks (`armysetup.Check`, also in the validation panel): army list vs save file, index vs position, faction range, alliances with unknown armies or bad states, one-sided alliances (info).
- The Mission workspace has the select / marker / area / unit / start position tools and the Armies panel; stages, objectives and triggers (section 11) come next in it.
- Checked: add / duplicate name / remove / move with 5 undos and 5 redos, saving writes `Alliances`, `Economy`, `faction` and the army list in order, real clicks on add dialog, colour slider, alliance rows.

### 19.20 Mission suite, second slice: stages, nodes, compiled script (2026-10-18, later)

- **Model** (`mission.lua`): a mission is a list of stages; a stage has an *enter* and a *ready* list of nodes and a failsafe timer. 14 node types in the catalogue (spawn group, spawn platoon on a patrol chain, send a group on
  a chain, mission text, wait, restrict / allow, give resources, playable area, reveal a place, Raw Lua, End, and the objectives destroy / protect / survive a time / units in an area). The model travels with the map in
  the `_editor.lua` sidecar (`Mission = {...}`), every edit has undo (typing in a field is one step).
- **Compiler**: each stage becomes `Stage[i] = function()` (forked, so waits work) with a `MissionNumber` guard; the objectives of a stage go into one `Objectives.CreateGroup`, whose completion starts the next stage (the
  last one ends the operation with a win unless it has an End node); the failsafe starts the next stage after N seconds. The result is written into `_script.lua` between `-- >>> EDITOR MISSION v1 ... hash=` and
  `-- <<< EDITOR MISSION` marker lines by `Map.SaveAs`: an empty default script is replaced, a script with its own OnPopulate / OnStart keeps them and gets the region appended (call
  `ForkThread(EditorMissionStart)` from OnStart), a hand edit inside the region (hash mismatch) leaves it alone and logs a line.
- **Edit mode is quiet**: the editor's sim runs while editing, so the generated start function waits for `ScenarioInfo.EditorPlaying` when `Options.EditorMode` is set; `ui.SetMode` sends `EdSetPlay` (new sim callback)
  on Play / Edit. Checked in the engine: a saved mission map opened in edit mode spawned nothing; after Play the Spawn node created the unit, killing it completed the Kill objective, stage 2 ran (log line from a Raw Lua node).
- **Checks** (in the Stages panel and the validation panel): undefined variable, unknown army / group / chain / area / marker, empty stage, failsafe without next stage, last stage that never ends, unknown node type, and the
  generated script must compile (a Raw Lua syntax error is reported instead of emptying the script).
- **UI**: Mission workspace, panel **Stages** (stage list with add / remove / up / down, name, failsafe slider, node list with add / edit / remove / up / down and the enter / ready switch), node palette dialog, node editor
  dialog (fields for texts, sliders for numbers, click-to-cycle choices, pickers for armies, groups of that army, chains, areas, markers and earlier variables). Self test `selftest_mission.lua` (18 checks).
- Not yet: unit groups are only the `INITIAL` group from the Unit tool (a group manager to put units into named groups comes next), triggers (timer, area, unit killed) as nodes, BaseManager / OpAI tables, cutscene
  nodes (these three: see 19.23), compound nodes, coop mode, difficulty branching, and the node canvas (the list is the same model).

### 19.21 Unit groups and wait nodes (2026-10-18, later)

- **Unit groups** (`units.lua`, Units panel): the Unit tool puts units into the active group (`Units.Group`, default `INITIAL`, which spawns with the map); other groups are the ones a mission's Spawn node creates. The Units panel has
  a Group button (picker with the army's groups and "new group...") and "Selection to group" (undoable). `All()` lists the units of every top-level group; the units of the non-INITIAL groups get editor entities at map
  load (`SpawnGroupEntities`) so they can be seen and edited, and `EdSetPlay(on)` destroys those entities when Play starts (the mission script spawns them). Checked: edit mode showed the unit once, after Play there was
  still exactly one (the Spawn node's).
- **More nodes**: wait until a group is destroyed (at most N left), wait until units of an army are in an area (compare / count), set alliance, destroy a group, give a group to an army. A wait node blocks the stage's thread,
  so the nodes after it are the "then" of a trigger. Checked in the engine: Spawn, wait until destroyed, set alliance, Raw Lua log line after killing the group.

### 19.22 Mod / unit editor, first slice (2026-10-18, later)

Design document: [MOD_UNIT_EDITOR_DESIGN.md](MOD_UNIT_EDITOR_DESIGN.md). Built: **Mod workspace** with the Units panel and the **Unit lab** panel; mod projects live in `modproj/<Name>/` next to the exe folder (mounted as
`/mods/<Name>` by `init_editor.lua` at start and by `ed_vfs_mount` when created; the engine's mod list cache is cleared); `bpedit.lua` holds the edits (`Economy.BuildCostMass`, `Weapon:<Label>.Damage`, ... with
the game's base value beside each) with undo, writes `edits.lua` and one merge blueprint per edited unit (`Merge = true`, delta only, weapons through `ModWeapon` / `MergeLabel`), and refuses to overwrite a file it did
not generate. "Test" writes the project, enables it for the map and reloads the session (`ui.ApplyMods`). Checked in the engine: a project created in the editor, two edits written, the mod enabled and the session
reloaded: `__blueprints.uel0106` read mass 60 / health 500 (base 30 / 60), the log shows the mod's blueprint load.

**Unit viewer (S2, same day):** panel **Unit viewer** (`unitview.lua`, `gui/panels_unitview.lua`, in the Mod workspace beside the Unit lab). "Show unit" stands the Units panel's unit (or the Unit lab's) beside the middle of the map as a real
unit of the editing sim, frames it three quarters from the side (`Frame('unit')`; the editor camera's `MoveTo` keeps the pitch, so the viewer uses `SnapTo`) or far enough out for the largest ring (`Frame('range')`).
Rings: weapon max / min range, vision / radar / sonar / omni / water vision radius, footprint and skirt, hit box. The animations the blueprint names (`Display.Animation*`, death animations) are listed; a click plays
one, the slider sets the speed, the second slider scrubs and holds a position (sim callback `EdAnim`: `CreateAnimator`, `PlayAnim`, `SetRate`, `SetAnimationFraction`). Checked: walk animation of `uel0106` at 0 / 0.5 / 0.9
shows different poses. Not yet: bone overlay, LOD switch, team colour / lighting presets.

**Effects panel (S3 preview, same day):** `effectview.lua` + `gui/panels_effects.lua`. The effect templates of `/lua/EffectTemplates.lua` (799 tables of emitter paths) with a filter field: a click plays every emitter at the lab spot
(sim callback `EdEffect`: an entity, `CreateEmitterAtEntity` per emitter, destroyed after 6 s), height slider. The 380 projectile blueprints: a click fires one from the unit of the Unit viewer (`EdFire`:
`CreateProjectile`, `SetVelocity`, 8 s lifetime), speed slider. Checked: `ExplosionLarge` (4 emitters) filled the view, `EdFire` ran without a warning. Editing emitter / projectile fields is open.

### 19.23 Mission suite, third slice: triggers, bases, difficulty, cutscene (2026-10-18, later)

- **Nested nodes** (`mission.lua`): a node of a *container* type holds a child list (`children`). A node is addressed by `(stage, section, path)`, the path being the index in the section's list or a table `{ i, j, ... }` through
  the children (`AddNode(stage, section, id, at, parent)`, `RemoveNode`, `MoveNode`, `SetParam`, new `IndentNode` / `OutdentNode`, `Flatten(stage)` for the panel, `LocateNode`); every edit has undo, typing in a field is one step.
  Depth is limited to 6. The compiler passes a context to every emitter (`C.stage`, `C.nextCall`, `C.Body(node, prefix, callback)` = the lines of the children), so a container compiles its children inline.
- **Trigger nodes** (family `trigger`, children run when the event happens, compiled as callbacks / forked threads; the stage guard `MissionNumber ~= <stage> -> return` is on by default and keeps a trigger quiet after the stage has moved on):
  *timer* (`CreateTimerTrigger`), *group destroyed* (`CreateGroupDeathTrigger`, or `CreateSubGroupDeathTrigger` for "N dead"), *unit killed* (`CreateUnitDeathTrigger` on a named unit of an army, children in their own thread),
  *units in an area* (a forked polling thread over the `CountInArea` helper with compare / count, once or re-arming), *objective decided* (`AddResultCallback` of a **named** objective: every objective node now has an optional name,
  stored as `V.<name>`). Objectives made inside a trigger stand alone (not part of the stage's group; info finding when primary). New flow nodes: **Next stage** (so a trigger can end a stage that has no objectives; a stage with
  Next stage or End no longer advances by itself), **Set a flag** (`ScenarioInfo.VarTable`, read by OpAI build conditions), **If the difficulty is ...** (compare + level, container), Spawn group *per difficulty*
  (`<group>_D1 .. _D3`, all three checked), **Cutscene** (container: `EnterNISMode` / `ExitNISMode`) with *camera: move to an area* and *camera reset* (marker cameras need a Camera Info marker, so areas only).
- **Variable scope** (`WalkAll`, `DefinedVars(stage, section, path, vtype)`): a variable set inside a trigger is visible only inside it; group variables and objective names are separate types, the checks and the pickers use them.
- **Bases** (`mbase.lua`, panel **Bases**, `Mission.Data.bases`): BaseManager tables. A base = army, marker, radius, build groups with priorities (unit groups of the army, optionally `_D1 .. _D3`), start mode (all groups / empty), engineers and permanent
  assisters per difficulty, details (max constructing engineers, always assist, support ACUs, `SetActive` on / off lists, `SetBuild` never-build list) and **attacks** (OpAI): family (BasicLandAttack / AirAttacks / NavalAttacks / EngineerAttack),
  child kinds with size per difficulty, orders (patrol chain picker / one chain / random patrol / default), priority, locking style and two build conditions (humans have N units per difficulty, flag is set, stage reached).
  **Define from area**: the army's units inside an area move into a group named like the base, a marker `<Base>_Marker` appears at the area's center, the radius is half the diagonal, one undo step.
  Compiled into one `Base.Start_<name>()` function per base (BaseManager import, `Initialize` / `InitializeDifficultyTables`, `StartNonZeroBase` / `StartEmptyBase` with `{ {easy, normal, hard}, {assist...} }`, switches, `AddOpAI` blocks);
  the **Start a base** and **Switch a base on / off** nodes call it. The function refuses with a warning when the army has no campaign brain.
- **Campaign armies**: BaseManager needs the campaign AI brain (`PBMAddBuildLocation`...). Map info has a **Type** button (skirmish / campaign, `Maps.SetInfo{ type }`); in an editor session of a `campaign` map every army except the first
  (and except ones named like civilians) is an AI army instead of a passive civilian (`schook/lua/SinglePlayerLaunch.lua`), and adding a base gives the army the blank plan list `/lua/ai/OpAI/DefaultBlankPlanlist.lua` (without it the
  campaign brain ran the skirmish plan loader and logged `HasBuilderList` errors). Checks: army, marker, groups, chains, start node, plan list, campaign map type, zero economy (info).
- **Checked** (`selftest_mission.lua`, 69 checks, all pass, repeatable in one session): nested add / path / indent / outdent / undo, variable scope, every new node compiles to loadable Lua, sidecar round trip with children and bases, define-from-area with one undo, base compile and
  problem findings. **Play test in the engine** (map `m6_play`, type campaign): a Start-a-base node, timer trigger (spawned a unit), group-destroyed trigger (-> Next stage -> stage 2), unit-killed trigger, area trigger: every
  callback fired, no script warnings; the BaseManager was created (`Initialize`, level `EBase`, engineer count 2, marker position and radius, OpAI `Attack1` registered) and spawned its group (factory and two generators of the Enemy army).
  Real clicks: select a trigger, Add inside, palette, node editor, Bases panel, attack form.
- **Open finding:** in the engine build used by the editor the base's *engineers and OpAI platoons are not produced*: `CAiBrain:CanBuildPlatoon` returned false for the T1 engineer template on the UEF T1 factory although
  `factory:CanBuild('uel0105')` is true and all PBM build conditions (`BaseActive`, `FactoryCountAndNeed`, ...) hold, so `PBMGetPossibleBuilders` finds nothing. The scripts are the standard BaseManager calls; the cause is in the engine function (or an
  unmet precondition of it) and needs a look in the reconstructed sources (`CAiBrain.cpp`, `cfunc_CAiBrainCanBuildPlatoonL`). Starting groups, triggers and everything else work.
- **Not yet:** expansion bases (`AddExpansionBase`), unit upgrades (`SetUnitUpgrades`), naval / reactive AI, named-unit builds, delayed groups, base buffs, coop mode and player-count scaling, an editable list of conditions beyond two slots, marker cameras, the node canvas (the list is the same model).

### 19.24 Mission suite, fourth slice: run panel, strings, coop mode (2026-10-18, later)

- **Run from editor** (`missionrun.lua`, `gui/panels_missionrun.lua`, sim callbacks in `lua/editorsim/mission.lua`): the generated script exposes `ScenarioInfo.EditorMission = { Stage, V, Objectives }` and its waits and timers go through two
  helpers, `Wait(s)` and `Timer(callback, s)` (also used by the Wait / wait-until / area-trigger / timer-trigger / failsafe nodes), that honour `ScenarioInfo.EditorSkip` (a counter: every waiting thread returns when it changes) and
  `ScenarioInfo.EditorTimeScale`; neither is ever set in a real game. Callbacks: `EdMissionDump` (writes tick, stage, flags, objectives with open / done, group variables with units alive to `../mission_state.txt`),
  `EdMissionJump` (starts a stage now), `EdMissionFlag`, `EdMissionSkip`, `EdMissionScale`. The **Run** panel shows the state and the warnings (log lines of the play test since Play: `warning:` lines minus engine diagnostics such as
  `[SIMGATE]`, with their traceback), buttons Jump to stage (the stage selected in the Stages panel), Skip waits, Timers x1 / x4 / x16, New flag, and a click on a flag row toggles it. **During a test run the docked shell is hidden**, so the
  play bar got a **Run...** button that opens the Run panel in a window of its own (a pop-out with the Run panel stays visible during a run: `shell.lua` `OnMode`, `OpenRunWindow`).
- **Strings** (`Mission.Data.dialogues`, panel **Strings**): a dialogue = a name and a list of lines (text, speaker, seconds), edited in a list dialog (add / edit / remove / up / down, undo for every edit). They compile to a
  `Strings` table of ScenarioFramework dialogue tables (`{ text = '<speaker>: <text>', delay = <seconds> }`). The **Play a dialogue** node plays one; every objective has an optional **reminder** dialogue repeated every N seconds
  while the objective is open (and, at stage level, the stage runs). Checks: unknown dialogue, empty dialogue.
- **Coop mode**: the Stages panel has a **Mode** button (campaign / coop / both, undo). Coop and both-mode missions are saved as scenario type `campaign_coop` (a campaign-mode mission turns a `campaign_coop` map back into `campaign`);
  in a real game the lobby loads the FAF coop support mod for that type. Coop nodes: *spawn the player commanders* (per `ScenarioInfo.HumanPlayers`, by faction `UEFPlayer` / `AeonPlayer` / `CybranPlayer`, arrival effect, optional PlayerDeath trigger),
  *shared unit cap*, *restrict / allow units for all humans*, *announcement*, *lose when all player commanders are dead*, and the flow container **If the number of human players is ...** (works in single player as 1 player). The coop nodes
  call the mod's functions only when they exist (`rawget`), and a coop node in a campaign-mode mission is an error. The existing OpAI condition "humans have N units" is the human-count template. All armies except the first of a
  campaign map get the blank plan list when saved (`Mission.PrepareArmies`): every non-human army of a campaign session gets the campaign brain, civilians included, and without plans it raises `HasBuilderList` errors every second.
- **Coop in the editor session**: the coop mod's hooks are **not** applied to the sim of an editor session (the mod was discovered, selected and listed in "Active mods in session", but its `/mods/coop/hook` files were never hooked, and
  `doscript` cannot read files inside the `.cop` archive although `DiskGetFileInfo` finds them), so `lua/editor/coopshim.lua` (own implementation, same names) defines `SetSharedUnitCap`, `Add/RemoveRestrictionForAllHumans`,
  `SimAnnouncement`, `PlayerDeath` and fills `ScenarioInfo.HumanPlayers` from the armies named `Player<N>`; the script calls it from `EditorMissionStart` only when `Options.EditorMode` is set (armies are created after the script loads, so it
  cannot run earlier). Name the armies `Player1` ... in the Armies panel; the first army of the list is the one human, the other `Player<N>` slots stay passive.
- **Checked**: self tests all pass (strings, reminders, coop nodes, mode, scenario type, plan lists, parsers; repeatable). Play test (map `m6_play2`, mode both, army `Player1` with a `Commander` unit): `ScenarioInfo.HumanPlayers` = 1,
  commanders spawned, shared unit cap / restriction / player-death nodes without a warning, the dialogue played and the objective reminder loop ran; the Run panel read stage, objectives, flags and group variables; Skip waits ended a
  300 s timer at once (flag LONG set), Timers x4 reported scale 4, a flag set from the panel appeared in the dump, Jump to stage 1 re-ran the stage; a deliberate `WARN` showed up in Warnings and engine noise did not; the script
  warnings count was 0 for the whole run.
- **Not yet**: per-player commander coordinates / slot count simulation (1-4 human slots), Spawn-Player-Commanders per faction with enhancements, drop reinforcements per player, taunt tables, voice-over (bank / cue) per dialogue line.

### 19.24b Mission import: a hand-written mission shows up read-only (2026-10-21)

- A campaign map whose `_script.lua` was written by hand (Operation Citadel: `ScenarioInfo.MissionNumber` stages, `IntroMissionN` / `StartMissionN`, `Objectives.*`, timer triggers, AI base modules) used to open with an empty mission editor.
  `missionimport.lua` reads the script and its `_strings.lua` as **text** (strings and comments blanked first; never executed) and builds an outline: stages (numbers set by `ScenarioInfo.MissionNumber = N`, or named
  `IntroMissionN` / `StartMissionN`), named functions with line ranges (a function belongs to the stage that sets the number, whose name carries it, or that is its only caller), objectives with their literal type / title / description,
  trigger callbacks (`Create...Trigger`, `:Add...Callback`, taunts), AI module / OpAI / platoon helpers by name, `ScenarioInfo.Options.*` and the difficulty uses, dialogue tables the script plays. `Map.Load` calls
  `Mission.ImportScript(Doc)` after the sidecar loader: it imports when the sidecar holds no editor mission (or the sidecar says `keepImport`).
- Imported stages (`imported = true`, `info` = the outline, no nodes) and dialogues (`imported = true`, from `BriefingData`, the line tables with `text / character / vid / bank / cue / faction` and the plain strings) are **read-only**: the
  Stages panel shows the outline instead of nodes (and dims the buttons that cannot work, tooltip and click say why), the Strings panel lists the lines (read-only dialog), the Run panel refuses Jump / Skip / Timers on them.
  `Compile` and `PatchScript` skip imported stages: a mission that is only imported writes **nothing** (`PatchScript` -> `'none'`, the script stays byte for byte as it is; `Map.SaveAsCore` also skips the playable-area patch for it,
  `PrepareArmies` and `ScenarioType` leave armies and type alone). Imported entries are not in the sidecar (it keeps `keepImport = true` next to the editor stages, so the next load imports again from the script); editor stages added
  behind them are numbered by their position in the list (`Stage[4]` after three imported entries) and Check warns when the script uses that number itself. The editor has no text viewer, so there is no "Open in editor" action; the
  outline lists line numbers to look up in an external editor.
- Test: `selftest_mission_import.lua` (inline scripts and strings, the model rules, and the Citadel script when its file is on disk).

### 19.25 Erosion suite and erosion brushes (2026-10-18, later; details in editor/TERRAIN_GEN_DESIGN.md section 12)

- **Native erosion in the field engine**: `erode_hydraulic` (pipe model), `erode_droplet` (particles), `erode_stream` (stream power on a drainage network with pit breaching), `slope_area`, `basin_depth`; deterministic for any thread count, golden checksums, `ed_field_op_multi` returns height + wear + deposit + flow + accum masks from one run.
- **Erosion panel** (Terrain workspace): six presets (Mountain, Hills, Canyon, Alpine, Desert, River valley), every parameter a field + slider + - / +, live preview at low resolution (thumbnail, optionally written onto the real terrain with Revert), Apply = one history entry, optional wear / deposit / flow / accum masks into texture layers.
- **Brushes**: Erode (rebuilt on the native session: iterations of the hydraulic kernels on the brush window, water and sediment kept between the dabs of a stroke, one undo step per stroke, symmetry aware), new Rain and Deposit tools. The old thermal erode of `terrain.lua` stays only as the fallback when the natives are missing.


### 19.27 Parity audit and the gaps it closed (2026-10-19, overnight session; table in editor/PARITY_AUDIT.md)

The audit lists about 90 features against the Unity and GPG editors with status, priority and effort. Terrain, strata, water, lighting, props, decals, units, validation, the mission suite and the Gaea-class terrain tools were already at or above
both. The holes were in the data of the objects around the terrain. Built (self test `selftest_parity.lua`, 73 checks, all pass; every item also driven with real input and a screenshot):

- **Marker properties of every type** (`markerprops.lua`, Properties panel): one field per key of the marker's template (numbers with a stepper, text, toggles, vectors as `x, y, z`), a type button that changes the type (new template fields added, old dropped,
  one undo step), Camera Info markers show heading / pitch / zoom / flags and the buttons *Look through this camera* and *Set from the current camera*.
- **Chains** (`chains.lua`, panel **Chains**, lines in the world): create from the selected markers (selection order) or empty, rename (the mission's platoon-patrol nodes and OpAI chains follow in the same undo step), delete, add / remove / reorder markers, select
  the chain's markers, length; problems (fewer than two markers, dead members, a marker twice in a row) are in the Validation panel.
- **Outliner**: search field, toggles for markers / areas / chains, chain rows. **History** panel (`History.Entries / JumpTo`): the undo stack as a list, click to jump. **Statistics** panel (`mapstats.lua`): counts, mass / hydrocarbon points and prop reclaim (from the
  prop blueprints) per start position, spread of the shares, units per army, markers by type.
- **Selection tools** (Edit menu): align (6 ways), distribute, arrange in a circle, snap to a 1 / 2 / 4 / 8 unit grid for markers and areas, units, props and decals (the tool decides), **find and replace** (marker type, prop blueprint, unit blueprint, decal
  texture; select matches or replace all, one undo step), **mirror the selection through the symmetry** (markers, areas, props; headings mapped).
- **Browsers**: the Units panel shows each unit's game icon; a star per entry in the Props, Decals and Units panels (favourites first, *Starred only*, kept in `editor_favourites.lua`). **Marker layers**: View panel toggles per marker category hide icons, labels and marker props in the world. **Range rings** of up to 8
  selected units (weapon, minimum, vision, radar, sonar).
- **Files and scenario**: Map info edits version, no-rush radius and the starts flag and shows the player count; File > Export > Preview image (PNG, 256 / 512; `png.lua` is a small RGB PNG writer, the CRC runs on two 16-bit halves because Lua numbers are
  32-bit floats; checked against zlib's CRC and a Python decode); Map > Save / Load the environment style (lighting, ambient, fog, water look as a text file).
- **Mission**: node *Cutscene camera: move to a camera marker* (the picker lists Camera Info markers only).
- Shell conventions used: auto-imported `gui/panels_*.lua` and `gui/feature_parity.lua`, panel stack hints (`stack` may now be a list of hints, one per workspace: `workspace.lua` `AttachPanels`), module-level `Refresh()`.
- **Not done** (follow-up tasks with design sketches in PARITY_AUDIT.md section 4): map resize / crop, platoons and orders panels, unified asset browser with prop / unit thumbnails, sky and water extras (engine setters), strata themes and shipped lighting presets,
  mirror for units and decals, tooltips, image brushes.

### 19.28 Asset browser, tooltips everywhere, stamp brushes (2026-10-19, branch ed/assets)

**Asset browser** (`assetcat.lua` catalog, `assetthumbs.lua` pictures, `gui/grid.lua` widget, `gui/panels_assets.lua` panel, `gui/feature_assets.lua` command; Window > Asset browser, Ctrl+Alt+A).
- One panel for units, props, decals, marker templates, terrain textures (strata albedo / normals), effects and mod projects, as a thumbnail grid or a list (size slider), with a search field (every word must occur in name, id, group or a category), facets per kind
  (units: faction / tech / layer / type; props and decals: environment / type; textures: environment / map; effects: faction / type), Starred only, Recent (last 60 used, newest first, stored with the favourites in `editor_favourites.lua`), and a preview of the entry under the
  pointer. The panel has three layouts by size: a column (docked beside the tools), wide (controls left, grid, preview right: a pop-out), short and wide (the bottom dock: two rows above the grid, the thumbnails fit the height).
- Click = pick for the matching tool, double click = use (a texture goes to the active terrain layer, one undo step; an effect plays; a mod project opens), right click = menu, drag into the viewport = place at the pointer, at every symmetry image, one undo step (`Props.PlaceAt`, `Decals.PlaceAt`,
  `Units.Place`, `UI.PlaceMarkerAt`). A drag from a pop-out window works: the pointer's screen position is turned into the main window's.
- Pictures: units use the game's icons (an entry without an icon gets a tile with its id); decals and textures are reduced natively (`ed_dds_thumb`, area average, DXT5, one call however big the source); props are rendered offscreen by the icon generator's pass (`ed_icon_request`): the prop (sim callback `EdThumbProp`)
  stands 30 units above a spot of the map where the offscreen scene is empty (`FindSpot`: the offscreen pass draws all scenery of the map, the blank map has 3D walls beyond the playable area; candidates are probed at three camera distances), the camera is fixed (heading 0.6, pitch 0.5, fov 22) and is fitted by the alpha box
  of probe renders (the icon generator's loop), pieces smaller than 15 percent of the largest are ignored (a stray speck near the prop would shrink it). One prop takes about 2 s; only what the grid shows is requested, the most recent request first. Never while the unit viewer has a unit or an icon capture runs.
- Cache: `<user data>/assetthumbs/v<Version>/`, mounted as `/edassets`; a file is `<kind>_<hash>.dds` where the hash covers the key, the time stamp of the source file (of the archive for files inside a .scd) and the version: a changed source gets a new name, a new recipe is a new `Version` (a new folder). `ed_file_delete` (.dds / .png only) exists for pruning.
- Natives: `ed_dds_thumb(src, dst, size)`, `ed_file_delete(path)` (EdIcon.cpp; **a new engine exe is needed**: instances use the exe built from the `editor` branch of the engine repo, commits 8825fd1 and 15d0f0a).
- Self test: `selftest_assets.lua` (catalog, filters, favourites, cache names, native thumbnails, drops with symmetry and undo, the grid widget, the live prop render).

**Tooltips**: `W.Button`, `W.Slider` (bar, thumb, - / + and the value field) and `W.TextField` have a tooltip. The text is the `tip` option (string or function) or, when there is none, `tooltips.ForWidget(panel, label)` from `tipdata.lua`: the panel is found through the `panelId` the panel host puts on the group a panel builds into
  (dialogs: `dialog`, top bar: `shell`, start screen, tour), the label is matched without case, without what follows a ':' or '(', without a trailing '...', digits as `#`; a `*/<label>` entry serves every panel. `cmd = 'edit.undo'` adds a dim "Shortcut: Ctrl+Z" line from the command registry (so a rebound key shows at once). The text may have several
  paragraphs (`\n`); menu items show a tooltip from their `tip`, their command's text (`tipdata.Command`, rules for `panel.open.*` / `workspace.*`) or a title pattern. Tools, panel tabs and workspace buttons use `tooltips.lua` as before. **Nightly step `tips`** (`tipcheck.lua`): every panel is shown with the click-sweep fixture, every widget of it and of the dialogs it opens is asked for its text, then the
  menus, the dialogs of the menus, the top bar, the start screen and the tour, the tools, the panel tabs and the workspaces: any widget without a text fails the night with its name. A widget whose label changes (a button that cycles through values, the mesh panel's slider) needs an explicit `tip`.

**Stamp brushes** (`stamp.lua`, `brushes.lua`, hooks in `terrain.lua` / `ui.lua` / `overlay.lua`, `gui/panels_stamps.lua`): tools *Stamp* (heights) and *Stamp texture* (the active layer's mask) take the shape chosen in the Stamps panel: a procedural shape or a greyscale picture (PNG / TIF / BMP / DDS) from the brush folders or imported
  (Import... copies the files into `<user data>/brushes`, mounted as `/edbrushes`). Height stamp modes: add, subtract, max, min, replace (base = the ground under each dab, or under the stroke's first dab); height (units for white), strength, edge falloff, rotation (+ random turn per dab), size jitter, position jitter, spacing (percent of the stamp width; a click is one stamp).
  The radius is the Brush panel's. Symmetry: every image of a dab is stamped with the mirrored / turned picture (`Stamp.ToSource`), the random choices are drawn once per dab. One stroke = one undo step (the native command stack for heights, `strata.lua` for the mask). The cursor preview shows the picture.
### 19.28 Batch A: map resize, platoons and orders, mirror of units and decals (2026-10-19; branch ed/resize)

**Map resize** (`resize.lua`, `gui/dialogs_resize.lua`, Map > Resize map...). The engine's terrain, paint masks and terrain-type grid cannot change size in place, so a resize makes a **copy** of the map in a new folder and reloads the session on it:
the original is never touched (that is the undo; the dialog says so, and unsaved changes go through the usual Save / Discard question first). Phase 1 (old session): `Plan` (the report), the native field ops (`resample` of the
height field and of every paint mask, onto the new grid) written as raw float files (`editor_resize/*.r32`), the blank template of the target size (`scripts/ed_make_blank_map.py`: 128, 256, 512, 1024, 2048) as the new `.scmap`, the scenario
with the new size, the save file with every object moved or dropped, the script, the sidecar with the paths moved, the payload (props, decals, world values, texture layers). Phase 2 (`ApplyPending`, called from `Map.Load` of the new session)
writes heights, masks, terrain types, world values, layers, props and decals into the native data and saves the folder a few seconds later (the preview picture needs a running view).
- Two modes: *canvas* (the terrain stays; cut or padded around a 3 x 3 anchor; padding repeats the edge heights or sits at a constant level) and *scale* (the whole map resampled, positions multiplied, resources snapped to the grid again, terrain-type codes by nearest cell, never blended).
- What moves: markers (start positions dropped outside are named in the report), chains (shortened or removed), adjacency lists, areas (cut to the bounds; AREA_1 kept or reset to the whole map), units of every group, props and decals (scale and heading kept), spline paths. The terrain graph and the mission are kept as they are (their outputs refer to the old size). Mesh terrain maps are refused.
- The dialog redraws the report on every change and draws the new bounds in the viewport (grey old map, green new map, white the part that stays).
- Tests: `selftest_resize.lua` (geometry, save transform, field remap in one session, 46 checks) and `scripts/editor_resize_flow.py <tag>` (expand, crop, scale, level: Setup, resize, reload, Verify, then File > Open of the saved copy and Verify again; heights, masks, terrain types, props, decals, units, markers, chains, areas).
- Traps: the new folder is named `<map name>_<size>` and saved next to the user's maps; the delayed save needs a ticking window (`R.Saved` says when it happened); the blank templates are generated files (`python scripts/ed_make_blank_map.py` writes all five, git-ignored).

**Platoons and orders** (`platoons.lua`, `gui/panels_platoons.lua`, `gui/dialogs_platoons.lua`, `missionplat.lua`). Edits the save file's `Platoons` (template rows: unit, min, max, squad, formation; plan), `Orders` (queues of Move / Patrol / Attack / Stop with a marker or a chain), the unit and group fields `platoon` / `orders`, and the platoon builders of every army (`PlatoonBuilders.Builders`: template, priority, instances, time-out, location, type, AI function, build conditions).
- Panel `Platoons` (stacked with Armies in the Mission workspace): three views, list + detail, New / From group / Copy / Rename / Delete / Assign to group; rename and delete follow every reference (units, groups, builders, mission nodes); the builder form is a dialog. Every edit is one undo step (slider drags fold into one).
- Validation (also in Map > Validate): unknown unit types (warning, mods), min above max, orders without a target or with a missing marker / chain, units and groups naming a missing template or queue, builders with a missing template, files that do not exist, a group missing the units its template needs.
- Mission nodes: *Spawn a group as a platoon (template, orders)*, *Give a platoon an order queue*, *Stop a platoon builder*; parameter kinds `platoon`, `orders`, `builder` with pickers and checks. Orders compile to the ScenarioFramework chain calls or the platoon methods.
- Round trip: `scripts/editor_platoons_flow.py <tag>` opens SCCA_Coop_A01 (22 platoons, 7 builders) and SCCA_Coop_E01 (28 builders) from the user's maps, edits (builder priority, platoon rename with references, platoon from a group, a queue, a builder with a condition), saves a copy, reopens it and compares the data character by character. `selftest_platoons.lua` (69 checks) also runs the game's own OpAI data through the save writer unchanged. No map of the user's folder has a non-empty `Platoons` table at scenario level: campaign maps keep platoon builders in the armies.

**Mirror** (`mirror.lua`, `mirrorhalf.lua`, `gui/dialogs_mirror.lua`). Mirror selection now copies selected units and decals too (`Units.PasteExact`, `Decals.PasteExact`), headings mapped. Units keep their army, or go to the army whose start position is the image of their own army's start (Symmetry panel switch, dialog option). *Mirror the whole half* (Edit menu, Symmetry panel): the source region is one half, quarter or triangle of the symmetry mode (drawn in the viewport), objects are markers, areas, props, decals and units; the images are added, or the other regions are emptied first; one undo step. Start positions and the playable area are never mirrored; copies are not in the chains of their originals; a picture cannot be flipped (props and decals keep their picture, only the heading is mapped).
- **Native**: `ed_prop_remove_many` (`EdPropBulk.cpp`, nested engine repo, branch `editor`, private exe `main_x64_la_resize.exe`): `ed_prop_remove(i)` rebuilds the whole prop list per call (17 ms with 40000 props); the mirror of a half of a 1024 map with 40705 props took 162 s and its undo 152 s, now 5.1 s and 2.7 s. `propbulk.lua` falls back to the one by one removal without the native. Props.DeleteSelected and Props.ReplaceBlueprint still remove one by one (same cost on huge selections): a follow-up can switch them to `propbulk.lua`.
- Tests: `selftest_mirror.lua` (55 checks: regions of every mode, add / replace / undo / redo, armies, selection, bulk removal).
- PARITY_AUDIT.md rows this batch closes (not edited in the branch because the environment batch changed the same table; mark them Done when landing): "Map resize / crop" (4.1), "Platoons / platoon builders of the save file" and "Platoons / orders panels" (4.2), "Mirror selection through the symmetry definition" (now with units and decals, plus the whole half; 4.8).
