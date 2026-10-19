# FAF Studio: feature parity and completeness audit (2026-10-19)

Goal (user, 2026-10-15): the most feature complete map and mission editor, not worse than the **FAF Unity map editor** or the original **GPG editor**, plus terrain tools of the Gaea / World Machine class.

Sources read: [MAP_EDITOR.md](../MAP_EDITOR.md) (parity matrix), [MAP_EDITOR_DESIGN.md](../MAP_EDITOR_DESIGN.md) sections 4, 13, 14 and 19.x, [GPG_EDITOR_FEATURES.md](../editor_research/GPG_EDITOR_FEATURES.md) (comparison table, sections 5-6),
[MISSION_SCRIPT_ANALYSIS.md](../editor_research/MISSION_SCRIPT_ANALYSIS.md), the other documents of this folder, and the code of the running editor (panel registry, commands, tools, menus: `lua/editor/gui/panels_*.lua`, `ui.lua` `Tools`, `gui/menus.lua`, `gui/commands.lua`).

Method: every panel, tool, command and menu of the build was listed (45 panels, 28 tools, 7 workspaces, 60+ commands) and compared with what map and mission makers do in practice and with the feature lists of both reference editors.
Final status of every open row: [PARITY_FINAL.md](PARITY_FINAL.md).

Status: **have** = works and is covered by a self test or was driven with real input; **partial** = exists but cannot do what the reference editors do; **missing**. Priority: P1 = a map or mission maker hits it in every project, P2 = common, P3 = rare / luxury.
Effort: S = under a day of one session, M = a few days, L = a feature of its own. Column "Done" says what this audit's branch (`ed/parity`) closed.

## 1. Result in one paragraph

Terrain, strata, terrain types, water, lighting, props, decals, units, clipboard, symmetry, validation, mission stages / bases / triggers, mod / unit lab and the Gaea-class terrain suite are in place and mostly ahead of both reference editors.
The holes are in **the data of the objects around the terrain**: marker properties other than position (the Properties panel edited only name, position, rotation and resource amount / size, although `MarkerTemplates.lua` gives
every type its own fields: camera zoom, path graph, adjacency, weather, effect template ...), **chains** (the save file's `Chains` are what patrol orders and mission nodes use, but nothing could create or edit one), the
scenario / lobby data (norush radius, map version, starts), statistics, history, find / replace, align / distribute, and a few browser conveniences. P1 and the small / medium P2 items were built in this branch (column "Done").

## 2. Table

### 2.1 Map life cycle and files

| Feature | Unity | GPG | Studio status | Pri | Eff | Done / notes |
|---|---|---|---|---|---|---|
| New map from templates (5 / 10 / 20 km), open from maps folder, save, save as, recent, recover autosave | Y | Y | have | | | |
| Backup before overwrite, journal, release package | Y (versions) | N | have | | | `feature_release.lua` |
| Map info: name, author, description, type | Y | Y | have | | | type button added 2026-10-18 |
| **Scenario info: map version, norush radius, extra scenario fields (starts, preview)** | Y | Y (game configuration) | **missing** | P1 | S | **Done**: Map info dialog edits version, norush radius, `starts` flag, shows players and size |
| Lobby options / game configuration editor (players per team, team layout) | Y (Armies window) | Y | partial (Armies panel for mission maps) | P2 | M | team layout of `Configurations.standard.teams` stays generated from start markers; documented in 4 |
| Map resize / crop | Y | N | have | P2 | L | Map > Resize map...: crop, expand or scale (128 .. 2048) into a resized copy, report, bounds preview; MAP_EDITOR_DESIGN 19.28 |
| Preview image in the `.scmap` | Y (render map) | N | have | | | `preview.lua` |
| **Export preview / minimap as PNG** | Y | N | **missing** | P2 | S | **Done**: File > Export > Preview image (PNG), size 256 / 512 |
| Map statistics (counts, mass / energy / hydro totals, reclaim totals) | P | Y | **missing** | P1 | S | **Done**: Statistics panel, per start position resource share |
| Version control popup / upload to FAF | Y | N | out of scope | | | release package instead |

### 2.2 Terrain (Gaea / World Machine class)

| Feature | Studio status | Pri | Eff | Notes |
|---|---|---|---|---|
| Raise / lower / flatten / smooth / noise / plateau / ramp / erode / rain / deposit brushes, falloff, spacing, rotation, signed strength, symmetry | have | | | `terrain.lua`, 19.4-19.14 |
| Height import / export (RAW, PNG 16, TIFF), Gaea / World Machine interop, live link | have | | | `interop.lua`, `heightio.lua` |
| Fields engine (45 ops), mask generator, erosion suite, node graph canvas, recipes, SC terrain tools (pads, symmetrize, slope limit, reach) | have | | | sessions T1-T6 |
| Terrain checks (slope, reach, buildability) | have | | | `terrainchecks.lua` |
| Brush thumbnails / user brush folder / brush library | partial | P3 | M | **Done** (branch ed/assets): Stamps panel with previews, Import... into the user's library, PNG / TIF / BMP / DDS pictures, height and texture stamp tools |
| Undo for terrain | have | | | native command stack |

### 2.3 Strata, terrain types, water, lighting

| Feature | Unity | GPG | Studio status | Pri | Eff | Notes |
|---|---|---|---|---|---|---|
| 10 strata layers: textures, scale, paint / erase brushes, mask preview, order | Y | Y | have | | | Layers panel |
| Layer reorder, add / remove textures | Y | Y | have | | | |
| Terrain type brush, overlay, link to layers | Y | Y | have | | | |
| Lighting (sun, ambient, bloom, fog), water (elevations, colours, waves) | Y | Y | have | | | |
| Skybox / cube map / background texture choice | Y | Y | **Done** | P2 | M | Sky, Sky textures and Sky objects panels (sky dome colours and shape, cirrus layers, sun / moon / planet billboards, sky cube, background, environment cubes), see 4.6 |
| Water masks (foam, flatness, depth bias) brush | P | Y | **partial** | P3 | M | **Done** as a mask output: the Mask generator writes any rule list (shore band, depth, noise, slope ...) into the foam / flatness / depth bias mask (replace / add / subtract, strength, one undo step); a freehand brush is still open, see 4.6 |
| Wave generator | Y | Y | partial | P3 | M | the four wave normal maps, their scale and motion, the ramp and the cube map are editable (Water motion panel, wave patterns); the `.scmap` wave generators (foam particle emitters along shores) are not: see 4.6 |
| Lighting presets / export-import of lighting, water, strata themes | Y (presets) | Y | **have** | P2 | M | **Done**: Lighting presets (78 looks with thumbnails, blend, try / apply / revert, own looks, import from any map file) and Strata themes (70 themes, try / apply, clear unused layers, own themes, import from a map), see 4.7. Map > Save / Load the environment style stays |

### 2.4 Props, decals, units and the asset browsers

| Feature | Unity | GPG | Studio status | Pri | Eff | Notes |
|---|---|---|---|---|---|---|
| Prop brush, eraser, select, move / rotate / scale, scatter panel, reclaim values | Y | Y | have | | | |
| Decal brush, eraser, select, groups panel, cut-off LOD | Y | Y | have | | | |
| Unit tool, select, groups, army, clipboard, gizmo | Y | Y | have | | | |
| Browser filter field (props, decals, units) | Y | partial | have | | | |
| Decal thumbnails | Y | Y | have | | | Decals panel |
| Unit icons in the Units browser | Y | Y | **Done** | P2 | S | the game's `/textures/ui/common/icons/units/<id>_icon.dds` as row thumbnails |
| Prop thumbnails in the Props browser | Y | Y | **Done** | P2 | M | rendered offscreen in the background and cached on disk (assetthumbs.lua), shown in the Assets panel |
| **Favourites / recent in the browsers** | N | N | **missing** | P2 | S | **Done**: star per entry, favourites first, stored in `editor_favourites.lua` (props, decals, units) |
| Asset browser across everything (textures, props, decals, units, mods) | Y | Y | **Done** | P2 | L | Assets panel (Window > Asset browser, Ctrl+Alt+A): grid / list, search, facets, favourites, recent, drag into the viewport |
| Weapon range / vision rings for placed units | Y | Y | missing | P2 | M | **Done** (see 2.6) |
| Unit orders (patrol / attack as save file `orders`) | N | Y | **Done** | P2 | M | batch A: Platoons panel, orders queues, mission nodes (19.28) |
| Platoons / platoon builders of the save file | N | Y | have | P3 | L | Platoons panel (Builders view, builder dialog), validation, mission nodes; MAP_EDITOR_DESIGN 19.28 |

### 2.5 Markers, chains, areas, armies

| Feature | Unity | GPG | Studio status | Pri | Eff | Notes |
|---|---|---|---|---|---|---|
| All marker types from `MarkerTemplates.lua`, placing, selecting, moving, rotating, snapping resource markers | Y | Y | have | | | |
| Marker rename, delete, multi-select, box select, symmetry | Y | Y | have | | | |
| **Marker properties of every type: type change, camera zoom / flags, path graph and adjacency, weather, effect template, cloud settings, expansion / naval hints** | Y | Y (data driven) | **partial** (name, position, rotation, resource amount / size only) | P1 | M | **Done**: the Properties panel builds a field per template key (numbers as stepper, text, toggles, vectors), change of type, undo for every edit |
| **Camera / NIS markers: "view through camera", set from the current camera** | P | N | **missing** | P1 | S | **Done**: Camera Info marker buttons *Look through* / *Set from camera* |
| **Chains: create from markers, rename, delete, reorder, add / remove markers, lines in the world** | Y | Y | **missing** (the mission nodes pick from `Chains` nothing could create) | P1 | M | **Done**: Chains panel, overlay lines, undo, validation of dead members |
| Areas: rectangles, names, handles, rename, resize with numbers | Y | Y | have | | | |
| Area polygon / rotated areas | N | N | missing | P3 | M | the save format has rectangles only |
| Path node graphs (land / water / air / amphibious), adjacency drawing | Y | Y | have | | | Paths panel / tool |
| Start positions, army list, teams, alliances, colours, economy | Y | Y | have | | | Armies panel |
| Marker layers / visibility filters (hide path nodes, hide hints) | Y | N | missing | P2 | S | **Done**: View panel *Show markers* toggles per category (Resources, Areas and points, Paths, Other); icons, labels and marker props follow; display only |

### 2.6 Selection, transforms and editing helpers

| Feature | Unity | GPG | Studio status | Pri | Eff | Notes |
|---|---|---|---|---|---|---|
| Multi selection, box select, shift add, move gizmo, rotate, copy / cut / paste / duplicate | Y | Y | have | | | |
| Mirror selection through the symmetry definition | Y | N | have | P2 | M | Edit > Mirror selection (markers, areas, props, units, decals; army mapping) and Edit > Mirror the whole half...; MAP_EDITOR_DESIGN 19.28 |
| **Align / distribute selection** (left / centre / right, top / middle / bottom, even spacing, circle) | N | N | **missing** | P2 | S | **Done**: Edit > Align and distribute (markers, areas, props, decals, units) |
| **Snap selection to the build grid** (not only resource markers) | partial | N | **partial** | P2 | S | **Done**: Edit > Snap selection to grid for markers, units, props, decals; grid size from `grid.lua` |
| **Find / replace objects** (marker type, prop blueprint, unit blueprint, decal texture) | N | N | **missing** | P2 | M | **Done**: Find and replace dialog (Edit menu), one undo step |
| Select by type / by group / same blueprint | N | N | missing | P3 | S | **Done** (sweep): Edit > Select the same / same group / all of a kind, see PARITY_FINAL.md |
| Measure tools, ruler | Y | N | have | | | |
| Range rings of selected unit | Y | Y | missing | P2 | M | **Done**: weapon max / min range, vision, radar, sonar rings for up to 8 selected units, from the blueprint |

### 2.7 Outliner, history, UI shell

| Feature | Unity | GPG | Studio status | Pri | Eff | Notes |
|---|---|---|---|---|---|---|
| Outliner of markers and areas | Y | Y | have | | | |
| **Outliner filter / search, show chains, units, props counts** | P | N | **partial** (a plain list) | P1 | S | **Done**: search field, kind toggles, chain rows |
| **Undo history panel** (list of actions, click to go back or forward) | Y (depth setting) | N | **missing** (Undo / Redo with the last label only) | P1 | S | **Done**: History panel, jump to any entry |
| Docking, pop-out windows, workspaces, saved layouts, command palette | N | N | have | | | beyond both |
| Rebindable hotkeys with search | N | Y | have | | | Hotkeys panel |
| UI scale | N | N | have | | | |
| Console / log, Lua REPL | Y | Y | have | | | |
| Panel scrolling for tall panels | | | have | | | session "editor-scrolling-panels" |
| Camera bookmarks, focus selection | Y | Y | have | | | |
| Tooltips on tools and properties | Y | partial | **Done** | P3 | M | every button, slider, text field, tool, panel tab, workspace and menu item has a text; the nightly step `tips` keeps it so (4.10) |
| In-editor help / tutorial map | N | N | missing | P3 | M | |

### 2.8 Mission suite

| Feature | Unity | GPG | Studio status | Pri | Eff | Notes |
|---|---|---|---|---|---|---|
| Armies, alliances, unit groups, stages, 30+ node types, triggers, objectives, difficulty, cutscene, bases, OpAI, strings, coop, run panel | N (files) | partial | have | | | 19.19-19.24, beyond both |
| **Chains for patrol nodes** | Y | Y | partial -> have | P1 | | via the Chains panel above |
| Platoons / orders panels as the save file's `Platoons` / `Orders` | N | Y | have | P3 | L | Platoons panel (Platoons and Orders views), round trip checked on SCCA_Coop_A01 / E01; MAP_EDITOR_DESIGN 19.28 |
| Marker cameras in cutscene nodes (Camera Info) | N | N | missing | P2 | S | **Done**: node *Cutscene camera: move to a camera marker* (picker lists Camera Info markers only, check refuses other types) |
| Taunts / voice-over per dialogue line, drop reinforcements, nuke barrage compounds | N | N | missing | P3 | M | **Done** (sweep): nodes taunt, transport drop, nuke barrage; voice-over fields on dialogue lines, see PARITY_FINAL.md |
| Mission validators (dead stage, undefined variable, ...) | N | N | have | | | `mission.Check` |

### 2.9 Mod / unit editor, converters

| Feature | Status | Notes |
|---|---|---|
| Unit lab (blueprint edits, merge blueprints), viewer, effects, icon generator, new unit wizard | have | M8 sessions |
| Prop creator, texture / format converters | missing | M7, separate design |
| Mesh map suite (manifest, import, checks) | have | M5 |

## 3. What was built in this branch

See the "Done" column; details, self tests and screenshots in MAP_EDITOR_DESIGN.md 19.27. Files: `markerprops.lua` (+ Properties panel section), `chains.lua` + `gui/panels_chains.lua`, `mapstats.lua` + `gui/panels_stats.lua`,
`gui/panels_history.lua` (+ `History.Entries / JumpTo`), `arrange.lua` (align / distribute / circle / snap), `findreplace.lua` + dialog, `favourites.lua`, `mirror.lua`, `styles.lua`, `unitrings.lua`, `markerfilter.lua`, `png.lua`,
`gui/feature_parity.lua` (menus and commands), the Outliner filter row, Map info fields, preview PNG export, the `cam_marker` mission node. Self test: `selftest_parity.lua` (73 checks, registered in `selftests.extra`).

## 4. Follow-up tasks that did not fit (design sketches)

4.1 **Map resize / crop** (P2, L). **Done** (batch A). Needs a native `ed_terrain_resize(newSize, anchorX, anchorZ)` for the height field, strata masks, terrain types, props, decals and water; Lua side shifts markers, areas, units; a dialog with anchor
    and preview rectangle. Risk: the sim field and path tables are created at load, so resize = autosave, rewrite files, reopen (the map-load path already exists).
4.2 **Platoons and orders** (P3, L). **Done** (batch A). Read the OpAI `_EditorFunctions.lua` specs into a function-spec table, panel with a platoon list (template rows, plan function, data), orders per unit group (move / patrol along chain /
    attack-move), writes `Orders` / `Platoons` / unit `orders`. Mission nodes keep working: they only emit script calls.
4.3 **Unified asset browser with thumbnails** (P2, L) - **done**, MAP_EDITOR_DESIGN section on the asset browser. One panel with tabs (props, decals, units, textures, mods), thumbnail cache rendered offscreen (the icon generator's offscreen path), favourites and recent from `favourites.lua`.
4.4 **Range rings and vision for selected units**: done (`unitrings.lua`).
4.5 **Image brushes and brush registry** (P3, M) - **done**: stamp tools, Stamps panel. Folder scan of PNG / RAW stamps, thumbnails, `.brush` import from `editor.scd`.
4.6 **Sky and water extras** (P2, M): **done** (batch C, branch `ed/env`), see 4.11. Open from it: a freehand brush for the water masks, the `.scmap` wave generators (shore foam emitters), cumulus clouds (the engine reads them from the map only).
4.7 **Styles library, second step** (P2, M): **done** (batch C, branch `ed/env`), see 4.11.
4.8 **Mirror units and decals** (P2, S). **Done** (batch A). `mirror.lua` covers markers, areas and props; units and decals need an exact-paste function (`PasteExact(list)`, like `props.lua`) that takes final positions and headings.
4.9 **Cutscene camera preview** (P3, S). **Done** (sweep: Mission panel *Play here*). A play-test of a single cutscene node from the Run panel (jump to the node's stage) instead of the whole mission.
4.10 **Tooltips** (P3, M) - **done**. Widget kit: hover delay, text from a `tip` option; fill from the command titles and property labels.

4.11 **Environment batch (batch C): sky, water, libraries** (built 2026-10-19, branch `ed/env`).

*Engine* (new files, `engine_decomp/faf-re-upstream/src/sdk/moho/editor`): `EdEnv.cpp` / `EdEnv.h`: `ed_env_get` / `ed_env_set` (sky dome origin, height, radius, start angle, tessellation, horizon and sky colours, billboard glow, cirrus strength / colour and the four cirrus layers: frequency, speed, direction; wave motion of the four normal maps; strategic view contour count, offset and five colours), `ed_env_texts` / `ed_env_set_texts` (sky billboard atlas and glow atlas, cumulus 1-3, cirrus, water ramp, water cube map, four wave maps, sky cube, background: the owners reload their textures), `ed_env_sky_decals` / `ed_env_set_sky_decals` (sun / moon / planet billboards, at most 1024, 10 numbers each: position, rotation, size, atlas cell), `ed_env_lookups` / `ed_env_set_lookups` (environment cube map per faction), water masks as fields (`ed_field_wmask`, `ed_field_commit_wmask` in `EdField.cpp`, foam / flatness / depth bias, half the map resolution); `EdScmapEnv.cpp`: `ed_scmap_env(path)` reads the lighting, water, strata and sky blocks of any `.scmap` file on disk without opening it (minor 53 - 60; same result as the Python reader on the retail maps). The engine's own saver already writes all of it: a saved map carries every setting (checked: sky, cirrus layers, billboards, wave motion and maps, ramp, cube maps, strategic colours, read back with the Python reader).

*Lua*: `environment.lua` (one model of lighting + sky + water numbers, texts, billboards and cube lookups; one undo entry per change, a slider drag is one; capture / apply / blend / from a map with the sky scaled to this map), `envlib.lua` (looks and themes: shipped, own, imported; previews that a save never carries: `Map.SaveAs` takes them off while it writes), panels `gui/panels_sky.lua` (Sky, Sky textures), `gui/panels_skyobjects.lua` (Sky objects), `gui/panels_waterx.lua` (Water motion, Strategic view), `gui/panels_looks.lua` (Lighting presets), `gui/panels_themes.lua` (Strata themes), `gui/envrows.lua` (row builder), `gui/texpicker.lua` (a texture browser for any folder), `gui/envdialogs.lua` (name and map pickers); all in the Environment workspace next to Lighting. `selftest_env.lua` (84 checks, in `selftests.extra`).

*Sky*: **Sky** = horizon and sky colours, horizon band size, billboard glow, dome height / radius / start angle / segments, cirrus strength and colour, per layer frequency, speed and direction. **Sky objects** = the billboard list (add, duplicate, delete, "Sun direction"), azimuth / elevation / distance from the dome centre (the engine stores absolute positions on a sphere around the dome origin), rotation, size, atlas cell; a picture of the atlas. **Sky textures** = the file slots, picked in a browser with thumbnails (cube maps by name). **Water motion** = ramp, cube map and four wave maps, scale and movement of each wave, four starting points (engine default, calm lake, choppy, ocean swell). **Strategic view** = the imager contour count and the colours of deep water, contours, shore and land.

*Lighting presets* (`editor/tools/gen_env_library.py` makes `data/envlib_looks.lua` from the 60 retail campaign maps and 18 hand made moods and biomes: dawn, morning, clear noon, afternoon, sunset, overcast, storm, night, foggy morning, desert noon and dusk, tropical day, arctic day, polar night, volcanic, alien crystal, two SC2 style looks): each look carries lighting, ambient, shadow fill, fog, bloom, water colour and shading, waves, sky colours, clouds, billboards and cube maps. Thumbnails (`editor/tools/gen_env_thumbs.py`): the same test scene (hills, a lake, a temperate stratum recipe, camera towards the sun) rendered with every look by the engine, stored as DXT1 in `override/textures/editor/envthumbs`. Click = TRY on the open map (no undo entry, "Revert" or another click takes it off), Apply = ONE undo step; the groups of settings (lighting, water, waves, sky, dome shape, cube maps) are switches, "Blend" moves only part of the way from what the map has; own looks are saved next to the exe (`editor_envlooks.lua`); "Import from map" reads any map on disk and keeps it as a look.

*Strata themes* (`data/envlib_themes.lua`): 13 hand picked sets (grassland, alpine, snow field, desert dunes, tropical beach, jungle, volcanic, red barrens, swamp, crystal plains, geothermal, industrial wasteland, farmland; every texture name is checked against the asset index) plus the texture sets of the campaign maps; albedo, normal map and tile size of Base, layers 1-8 and Upper; try / apply / revert, the paint masks stay (a theme changes the look of the layers, not where they are), "Clear unused layers" removes the texture and paint of layers the theme leaves empty; own themes (`editor_envthemes.lua`), import from a map.

*Water masks*: the Mask generator's output has a water mask row: foam, flatness or depth bias, replace / add to / subtract from, strength, one undo step; presets "Shore foam" and "Deep water". Rendering was checked with foam 1 against 0 (different pixels along the shore).

*Verified with real input* (posted mouse messages, `scripts/ed_input.py`): click a look = the viewport changes (Sunset: orange sky, warm light), Apply = one undo entry and the try is gone, the Undo button restores the day; click a theme (Alpine: snow); Add in Sky objects and a click on the elevation slider move the billboard (list and sliders follow); Import from map... with a typed filter reads a map of the user's maps folder and tries its look; Save current... with a typed name adds it to "My looks". Posted Ctrl+Z does not reach the hotkey handler (the async key state is not set by posted messages): the Undo button was used.

*Traps found*: sky billboards are absolute positions on the dome sphere (a position near the origin never shows); the engine needs the sky GPU resources rebuilt (`SkyDome::Reset`) after a dome shape or texture change, colours are read every frame; a running engine instance holds the PDB, the engine link fails (LNK1201) until it is stopped (also the one the build was started from); a cleared texture slot (`ed_stratum_set_layer` with an empty path) cannot be reproduced, a layer that had no texture gets the transparent one back after a revert (looks the same).
