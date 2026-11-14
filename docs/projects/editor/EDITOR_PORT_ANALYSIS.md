# Port analysis: upstream editor features into FAF Studio (read-only, 2026-11-11)

Tree: `C:/Users/Marlo/Documents/GitHub/faf-re-editor-merge` (branch `editor-upstream-merge`). U = upstream (`src/editor/`, ns `faf::editor`), S = ours
(`src/moho/editor/`, ns `moho::editor`, Lua/maui UI in `FAF_Studio/editor/runtime/lua/editor/`). Line counts are `wc -l` (.cpp + .h). I read headers, the
include lists of every file, the CMake wiring and the test list; I did NOT read function bodies, compile, or run anything. "Not verified" marks guesses.
Effort: S < 1 session, M = 1-3, L > 3.

## 0. Structure that decides everything

U totals 52.2 k lines: `doc/` 14.0 k, `tools/` 4.9 k, `graph/` 2.6 k, `undo/` 0.26 k, `ui/` 10.3 k (ImGui), `view/` 9.0 k (6.6 k is `EdMapScene.cpp`), top level 11.1 k
(`EdApp` 3.8 k, `EdTools` 3.2 k with `.h`, `EdShell` 1.6 k, `EdPlay` 1.7 k).

* **Pure logic is large and clean.** `doc/ + tools/ + graph/ + undo/` = 21.8 k lines; of that only 3.9 k touches the engine (`EdDocument`, `EdRoundTrip`,
  `EdUnitWrecks`, `EdMapFile`, `EdDecals`, `EdTextureLibrary`, `EdTextureBake`). About 17.9 k lines include nothing from `moho/`, `gpg/`, `lua/`, ImGui or
  `EdDocument`: they take strings / vectors and return strings / vectors. Proof: GoogleTest target `faf_editor_brush_tests` (tests/CMakeLists.txt l.343-396)
  compiles each test with just its one logic `.cpp` and links only gtest + ole32/windowscodecs/zlib/winhttp/crypt32/shell32.
* **The document model is the non-portable part**: `EdDocument` (2.4 k) + `EdMapScene` (7.3 k, applies every tool, undo kinds, drawing) + `EdTools` + `EdShell` +
  `EdApp` (two render heads, own `main()`) + `EdPlay`. This is about 20 k lines that assume "one `EdDocument` loaded on a worker thread, in its own Lua state,
  separate from play". Ours edits the live session's `CWldMap` (`ed_*` natives, `Map.Doc` Lua tables, native `MapDocument` command stack for heights). Do not port
  these; port the pure modules and call them from Lua.
* **ImGui** is only in `ui/` (10.3 k, 1,500 `ImGui::` calls), `EdShell`, `EdTools`, `EdApp`. Everything in `view/` except `EdParticleViewport` (uses the ImGui
  renderer texture) is ImGui-free engine glue.
* **Integration pattern that fits ours**: one static lib of U's pure `.cpp` files (compiled unchanged, so rebasing on upstream stays cheap) + one new binding unit
  per area in `src/moho/editor/` (self-registering `static Bootstrap` object like `EdFieldLuaBootstrap`, `BindGlobal("ed_xxx", ...)` as in `EditorLua.cpp` l.990)
  + Lua modules. Natives take/return plain Lua tables and strings; long jobs (HTTP, zip) are threads polled from Lua.
* **Build facts**: with `-DFAF_EDITOR=ON` the Studio sources go into `faf_engine` (src/CMakeLists.txt l.25-33) and `FAF_STUDIO_EDITOR` is a PUBLIC define of
  `faf_engine`; `CScApp.cpp` l.1677 then returns D3D11 only and ignores `gAppRenderers`. So U's `faf_editor` (own `main()`, wants D3D12/Vulkan) cannot be built or
  run in the same configuration as Studio. Details in section 11.
* **Platform**: U's logic uses WinHTTP, DPAPI, WIC, `shell32`; fine for us (Windows only). Our engine already links zlib (`EdImageIO.cpp`).

## 1. Classic .scmap v60 writer, byte-exact round trip, text-preserving save files, package zip

Files (lines): `doc/EdMapFile` 364+104, `EdImageChunks` 56+29, `EdSaveFile` 861+194, `EdLuaText` 285+41, `EdPackage` 239+53, `EdRoundTrip` 173+30, `EdNewMap`
287+62, `EdRecentMaps` 56+19. Glue in `EdDocument.cpp` (Save l.1686/1815, `MarkKeptImages` l.969, `SaveAsNewFolder`, backups to `.editor_backup/<time>/`).
Total 2.85 k lines logic; ~90% pure. Engine-bound: `EdMapFile` (wraps `CWldMap::Save` through `BinaryWriter`, `CWldMap` + VFS) and `EdRoundTrip` (needs `EdDocument`).
What it does: keeps the file's preview chunk, the props' 15-float records and the DDS image chunks (normal maps, two masks, water map) and writes them back verbatim
while their sources are unchanged (`keepImages`), so 63 retail maps save to identical bytes. `_save.lua` is edited as text: unchanged entries keep their bytes, changed
entries get only the changed values replaced.
Ours: `ed_map_save` -> `CWldMap::MapSaveToDiskPath` (engine writer, re-encodes preview/normal/water map, rewrites prop matrices); `map.lua` + `luaser.lua` re-serialise
`_scenario.lua` / `_save.lua` whole from Lua tables (sorted keys, comments and layout lost); `maps.lua` autosave/SaveAs; `release.lua` + `scripts/pack_map.py` zip.
Overlaps: `maps.lua`, `map.lua`, `luaser.lua`, `release.lua`, `recent.lua`, `EdScmapEnv.cpp`, `editor/core/scmap.cpp`.
Depends on (engine): `CWldMap`, which ours has (same engine). Not on `EdDocument` except `EdRoundTrip`.
Adaptations needed (the real work):
* props: ours keeps the scale lanes (`CWldPropEntry::mScale`, EDITOR DIVERGENCE) and edits props via `ed_prop_*`; U's `PropRecord` writes the stored 15 floats while the
  transform equals `loaded`, scale 1 for new props. Must also compare scale, or the record silently reverts a scale edit. Small edit to U's file (keep it a marked patch).
* `keepImages` needs "sources unchanged" per image: heights (our `MapDocument` checksum / dirty), masks (our `EdStrata` + `maskdelta`), water levels. U hashes at load (`MasksRead`).
* map formats 3/4 (mesh terrain, `editor-mapformat`): U's writer is v60 only. Branch: mesh-terrain maps keep the engine writer.
* `_save.lua`: U's model is `SaveEntry{name, vector<(key, valueText)>}`; ours is Lua tables. Adapter: Lua builds entry strings with `luaser.Dump`, native returns patched text.
  Alternative cheaper first step: keep luaser but run U's `SaveFile` only for the markers/areas/armies/chains blocks.
* `EdNewMap` (5-81 km via `CWldMap::MapNew`) overlaps `maps.lua` blank templates (5-80 km, built by `scripts/ed_make_blank_map.py`): optional, M-priority low.
Effort: logic M-L (writer + records + keepImages M; SaveFile/LuaText binding + adapter M; `EdPackage` S: `WriteZip`/`PlanPackage`/`WithMapVersion` replace `pack_map.py`
inside the editor); UI S (Release dialog gets "package", save messages, "open backups"). Risk: medium. Byte-exactness only holds if every edit path of ours marks its
source changed; one missed path gives a stale image in the file. Needs the retail round trip as a regression gate (section 12).

## 2. FAF vault search, sign-in, download

Files: `doc/EdFafApi` 982+215 (JSON parser, `VaultQuery` -> filter URL, search parse, `EdFafSession`: Hydra device-flow login on worker threads, token in DPAPI file,
preview cache shared with the FAF client), `EdVault` 317+87 (`ReadZip`, `InstallMapZip`, `EdVaultDownload` thread), `EdHttp` 129+28 (WinHTTP), `EdJson` 190+35.
UI: `ui/EdMapBrowser` 1274+140 (324 ImGui calls). Logic 1.98 k, all pure (own tests: `VaultTests`, `FafApiTests`); UI 1.4 k.
Ours: nothing (local list `maps.lua`, `gui/startscreen.lua`).
Depends on: nothing from the engine; `EdPath.h` (13 lines); a token file location (ours: `%APPDATA%\FAFStudio`); after download the folder must be mounted
(`ed_vfs_mount` exists) and opened (`maps.Open`, a session restart).
Needs new natives: `ed_vault_search(query)`, `ed_vault_poll()`, `ed_vault_login/logout/status`, `ed_vault_download(id)`, `ed_open_url(url)` (the device flow opens a
browser; U calls ShellExecute on the UI thread, line ~780), image bytes for thumbnails (ours `thumbs.lua` loads from disk files: save the previews to the cache folder).
Effort: logic M (thin binding over a self-contained lib; tests exist). UI L (query form with all client filters, sort, paging, result cards with previews, sign-in dialog,
progress, "open after download": ~1.5 k lines of Lua/maui; the maui list/scroll widgets of `gui/browser.lua` are the base). Risk: low technically; two policy points:
the OAuth `kFafClientId` is upstream's registered client (name "FAF-RE map editor"): FAF Studio should register its own or ask upstream before shipping; the editor then holds a
user token (DPAPI, per-user file) - keep it out of logs, selftests and `dist/`.

## 3. Adaptive maps

Files: `doc/EdAdaptiveModel` 187+74, `EdAdaptiveTables` 767+105 (`_tables.lua`, `_options.lua` text read/write, `AdaptiveMap = true` in the scenario), `EdGroupOptions`
1404+113 (reads the map script to find which lobby settings create which unit groups), `EdUnitFate` 263+70 (what becomes of a unit: initial / wreck / lobby option / never),
`EdUnitWrecks` 126+39 (needs `EdDocument`, the kept rules and `RUnitBlueprint` for wreck mass). Logic 3.15 k, pure except `EdUnitWrecks`. UI: `ui/EdAdaptiveWindow` 962,
`EdAdaptivePanel` 316, `EdUnitFatePanel` 270 (1.55 k, 304 ImGui calls). Tests: `AdaptiveModelTests`, `AdaptiveTablesTests`, `GroupOptionsTests`, `UnitFateTests` (pure; some
use retail maps via `FAF_RETAIL_MAPS`).
Ours: no adaptive handling at all. Touches: `units.lua` (group tree), `armies.lua`, `markerprops.lua` (Mass/Hydrocarbon markers), `lobbyslots.lua`, `missionimport.lua`
(hand-written script outline). Everything works on text in / text out, so no document-model conflict.
Needs: units' group paths (`Units` tree in our save table) passed as arrays; the script text (`ed_read_file`); `EdUnitWrecks` replaced by a small native `ed_wreck_value(bp, underwater)`.
Effort: logic M (4 modules bound as `ed_adaptive_*`; heavy in tests, light in glue). UI L (a window with per-army mex/hydro group tables, option-table editor, lobby preview,
unit-fate panel; these are dense tables and a preview matrix: 1.5 k lines of maui). Risk: low-medium; it is only as good as the pattern match on the "Ultimate maps" script.

## 4. Particle Editor, effect graphs, Particle Browser, viewport

Files: `doc/EdEmitter` 849+222 (parse/write emitter, beam, trail `.bp` byte-exact for 2,437 retail emitters, curve sampling = `SEfxCurve::GetValue`, tick model of
`CEfxEmitter::Tick`), `graph/EdEffectGraph` 463+60, `graph/EdNodeGraph` 426+174 (generic node model + JSON, shared with area 5). View: `EdParticlePreview` 264+83 (feeds the
game's `CWorldParticles` without a sim), `EdParticleViewport` 174+70 (own camera and render target; uses the ImGui renderer to show it). UI: `EdParticleEditor` 670+190,
`EdParticleGraph` 564, `EdParticleBrowser` 240, `EdNodeCanvas` 568+100 (2.3 k). Logic 2.2 k pure; engine glue 0.6 k; UI 2.3 k.
Ours: `effectview.lua` (plays an EffectTemplates entry in the world at the unit-lab spot), `fxedit.lua` (field list of emitter/beam/trail/projectile bps, written as merge
files via `bpedit.lua`), `gui/panels_effects.lua` (243), `gui/curvewidget.lua` (reusable curve control). No curve-stack editor, no emitter simulation in the editor.
Depends on: `CWorldParticles`, `CD3DDevice` (gal, any backend), render target; no `EdDocument` (effect markers go through `_save.lua`, i.e. area 1).
Conflict to decide: U writes whole emitter `.bp` files; ours writes merge blueprints. Define the split: Particle Editor owns new / full emitter files in a map or mod folder,
`fxedit` keeps the delta route for existing game bps.
Effort: logic M (emitter + curve natives; effect graph optional - first ship without node view). Engine glue M (preview + a way to show the viewport: our `EdPopout` window
or the world view at a far-out spot like U's 3000-unit slots; show-in-maui texture path is not verified). UI L+ (curve stack with 21 curves via `curvewidget`, browser of 3,045
effects, emitter/beam/trail pages; effect-graph canvas can reuse our Lua graph canvas `graph.lua` if node Defs are data driven - not verified).

## 5. Material Editor / texture graph / bake

Files: `graph/EdTextureGraph` 1255+105 (25 CPU node types: Noise, Cells, Gradient, Texture, TerrainHeight/Mask/Slope, Levels, HSV, GradientMap, Blur, Blend, HeightBlend, Warp,
HeightToNormal, NormalBlend, Split/Merge, Output), `EdTextureBake` 122+25 (writes DDS through the engine `ImageCodec`), `EdNodeGraph` (shared). UI: `ui/EdMaterialEditor` 1016+184,
`EdTexturePicker` 197+34. Logic 1.5 k (bake is engine-bound: `ImageCodec`), UI 1.4 k. Tests: `TextureGraphTests`, `NodeGraphTests` (pure), `TextureBakeTests` (links `faf_engine`).
Ours: field engine (grey float grids, 100+ ops, GPU), graph runner `graphrun.lua` + `graphnodes*.lua` (about 100 Defs) and canvas, `maptextures.lua`, `alphagen.lua`,
`ed_dds_fields` (DXT5 writer) + `EdDdsEncode.h`, `texsets.lua`, `strata.lua`. What ours lacks is **colour** (RGBA) authoring: Color, Texture load, HSV, GradientMap, Blend,
NormalBlend, stratum albedo/normal output. Bake is covered by `EdDdsEncode.h`.
Effort: logic S-M (bind evaluate/thumbnail; replace `EdTextureBake` by our DDS writer). UI M-L (Defs for our canvas, preview, output-to-stratum slot; or the cheaper path: re-implement
the missing RGBA nodes as field-engine ops, not verified). Priority low; do after 1-3. Risk: duplicate graph systems (ours Lua vs theirs C++) - choose one canvas (ours).

## 6. Water bodies, shore wave generators, .scmwtr

Files: `doc/EdWaterBodies` 298+79 (`ScenarioInfo.WaterBodies` text, fill preview as `STIMap::InstallWaterBodies`), `tools/EdWaves` 551+88 (generators from shore points, `.scmwaves`,
`wavepatterns.lua`), `doc/EdWaterPreset` 103+20 (`.scmwtr`), `EdWater.h` 56 (struct), `view/EdWaterBodyView` 349 (draws outlines/guides, no ImGui). Press/drag handling sits inside
`EdMapScene` (not portable). UI inside `EdInfoPanels` (1.27 k, mixed). Logic 1.5 k pure except the engine file `moho/sim/WaterBodies.cpp` (already in the merged tree, linked into tests).
Ours: `panels_world.lua`, `panels_waterx.lua` (ramp, cube map, 4 wave maps), hi-res water map (patch 0104, `WATER_SHORE.md`). No bodies, no wave generators.
Simplification: our scenario is a Lua table (`Doc.info`), so `WaterBodies` can be edited as a table and written by `luaser`; `EdWaterBodies` text editing is not needed - only the fill
preview (native over the heights, `STIMap` code) and the field semantics. Wave generators live in the `.scmap` (`WaveSystem`): natives over `CWldMap`'s wave system plus
`EdWaves` generation.
Effort: logic M (preview native, wave generate/import/export, `.scmwtr`). UI M-L (body list, seed pick on map, outline polygon by clicks via `ed_overlay_*` lines, wave panel).
Risk: medium - **both editors changed the water map path** (`RebuildWaterMapRect`, our hi-res second water map vs U's water body surfaces / `HighFidelityTerrain`, comparison
section 2 item 8); bodies change sim (`sim_FixWaterBodies`), so a determinism check against retail is required.

## 7. FAFME importers / exporters

Files (all pure, JSON via `EdJson` 190): `EdMarkerPreset` 219 (`.fafmapmarkers`), `EdUnitPreset` 98 (`.scunits`), `EdPropPaint` 79 (`.proppaintset`), `EdLayerPreset` 81
(`.scmsl`/`.scmst`), `EdLighting` 130 (`.scmlighting`), `EdSkybox` 164 (`.scmskybox`), waves/water (area 6). About 1.0 k lines. Each has a test file.
Ours: no importer for any of these. Targets: `markerprops.lua`/`map.lua` (markers), `units.lua` (units), `scatter.lua`/`props.lua` (paint sets), `strata.lua`/`texsets.lua` (layers),
`environment.lua`/`envlib.lua`/`panels_sky.lua` (lighting, sky).
Effort: logic S-M (one binding unit `ed_import_*` returning Lua tables; glue in the target modules is the work), UI S (file menu entries). Risk: low. Good early wins; each is
independent. Check our model can hold every field (e.g. skybox planets/cirrus in `panels_skyobjects.lua`) - not verified.

## 8. Live editing of a running play, F6 switch, play setup profiles

Files: `EdPlay` 1397+283 (setup: AI slots, teams, factions, fog, victory, mods, profiles in `play_setups.ini`, quick start), `view/EdLiveTerrain` 220+38 (heights via
`gSimBeforeBeat`, water levels), `view/EdLiveUnits` 215+66 (pick/warp/enhancements of game units), `ui/EdLiveUnitPanel` 169; F6 and the second `CWldSession` are in `EdApp`/`EdMapScene`.
Ours: Play is a mode of the same session (`ui.Play`, `EdSetPlay` SimCallback, autosave to restore on Stop; `PlayFromStage`), heights already reach the sim through
`ApplyPendingHeightEdits` (merge installs the single `gSimBeforeBeat` owner in `EditorDocument.cpp`). Whether live masks / layers / decals / water reach the play in ours:
not verified.
Not portable as code: a second session and two heads contradict our "one process, edit and play are states of one session" rule (`MAP_EDITOR_DESIGN.md`). Portable as
*features*: the setup profile model (AI type per slot, team, faction, fog, victory, mods, saved profiles) - in Lua it is a read of `/lua/ui/lobby/aitypes.lua` + `factions.lua` and
a settings file, far smaller than the C++; live water level and unit warp/enhance as small natives modelled on `EdLiveTerrain`/`EdLiveUnits` (they only use `Sim`, `PathTables`, `Unit`).
Effort: setup profiles S-M (Lua, no native); live extras M; F6 / second session L and **not recommended**. Risk: high for the last one.

## 9. Script editor, Lua syntax check, checks, pathing

Files: `doc/EdLuaSyntax` 146+32 (tokenizer for colouring), `tools/EdChecks` 237+83 (marker/start/resource checks, prop symmetry, Lua error splitting), `tools/EdPathing` 116+33
(footprint passability + areas), `tools/EdSymmetryCheck` 188+58, UI `ui/EdCodeEditor` 184. Pure.
Ours: `terrainchecks.lua` (ground, connectivity with native `regions`/`reach`, paths), `markercheck.lua`, `layoutcheck.lua`, `validate.lua`, `symmetry.lua` (+AutoDetect), `mission.lua`
compiler with a "Raw Lua" node and syntax guard via `loadstring`. Missing in ours: a script editor, colouring, "Check" of `_scenario/_save/_script`; prop symmetry check.
Do not port pathing/symmetry (overlap, ours uses field ops). Port: `EdChecks` prop-symmetry + `SplitLuaError` (S) and `LuaSyntax` tokenizer if a viewer is built.
The real obstacle is UI: maui has no editable multi-line code control (cursor, selection; the project notes say no clipboard native). A full editor = L and risky. Cheaper: "Open script
in the system editor" + file-stamp reload + our Check (S-M).

## 10. Decal path mode, stamp / plane / terrace brushes, undo by tiles, symmetry check

* Height brush: `tools/EdHeightBrush` 704+158, modes Raise, Lower, Smooth, Flatten, Set, Noise, Terrace, Plane (3 points), Stamp, thermal, hydraulic; limits by height and slope; N-way
  symmetry. Ours: `EdBrush.cpp` 176 + `brushes.lua`, `stamp.lua` (242), `symmetry.lua`, erosion brushes (stronger), `fields.lua` ops (terrace exists as a graph op). Missing as brushes:
  **Terrace** and **Plane** (no hit in `brushes.lua`/`tools.lua`/`stamp.lua`). Effort S each as new modes in `EdBrush.cpp` (take the kernels from `EdHeightBrush.cpp`, which is pure).
* Undo by 32x32 tiles, 256 MB (`undo/EdHeightHistory`): our `MapDocument` already has sparse per-tile deltas, zigzag-varint packing, checksums, 256 MB cap. Nothing to port.
* Decal path: `tools/EdDecalShape` 177+56 (Catmull-Rom strip of decals) pure; `EdDecals` 257+91 engine glue. Ours: `decals.lua` (557) and `paths.lua` already places decals along
  drawn paths (spacing, jitter, side). Port only if the Paths tool cannot do "free decal path"; effort S. Mask brush/terrain types: overlap with `strata.lua`/`terraintype.lua`; skip.
* Symmetry check/repair/detect: overlaps `symmetry.lua` + `EdSymTest`; skip.

## 11. Build: `faf_editor` / `FafEditor_x64` beside ours?

* Target `faf_editor` (`src/editor/CMakeLists.txt`) returns early without `faf_imgui` and links `faf_engine`. In a `-DFAF_EDITOR=ON` tree, `faf_engine` carries `FAF_STUDIO_EDITOR`
  (PUBLIC): `RendererAttemptOrder` is hard-wired to D3D11, `WinMain`/`CScApp` take Studio branches, and `faf_editor` brings its own `main()`: it would build and then not run as designed.
* So it can stay only in a **separate build configuration** (`FAF_EDITOR=OFF`) as a frozen reference/oracle (keeps upstream CI and A/B comparisons of features). In the ON tree add
  `if(FAF_EDITOR) return()` at the top of `src/editor/CMakeLists.txt` target creation (the pure sources stay compiled as a library). No need to delete anything now.
* When parity is reached: delete `FafEditor_x64`, `faf_imgui`, `ui/`, `view/` (except engine glue we reuse), `EdApp/EdShell/EdTools/EdPlay/EdMain` (about 35 k of 52 k lines); keep
  `doc/ tools/ graph/ undo/` as `src/editor/` library and the tests. Cost: later upstream changes to deleted files become merge noise; keep pure files unmodified (patch via wrappers, mark every
  edit `// STUDIO:`) so `git merge upstream` stays mostly clean for the library part.
* Link additions for Studio: `winhttp crypt32 windowscodecs ole32 comdlg32 shell32`, plus `dbghelp` only if `EdMemTrace` is ever used (not needed).

## 12. Tests (U: 41 files in `tests/editor/`, 195 GoogleTest cases by U's count; my grep of `TEST` hits is 219 because it counts GTEST_SKIP lines)

* **Survive unchanged** (pure, only need their `.cpp`): AdaptiveModel, AdaptiveTables, GroupOptions, UnitFate, ArmySlot, Check, DecalShape, Emitter, EffectGraph, FafApi, HeightBrush,
  HeightFile, HeightHistory, ImageChunk, LayerPreset, Lighting, LuaSyntax, MarkerPreset, Marker, MaskBrush, NewMap, NodeGraph, Package, Pathing, PropPaint, RecentMaps, SaveFile, ShaderSlot,
  Skybox, SymmetryCheck, TerrainType, TextureGraph, UnitPreset, Units, Vault, ViewAid, ViewState, WaterPreset, Wave (about 39 files). Tests of modules we do not bind (HeightBrush, HeightHistory,
  SymmetryCheck, MaskBrush, Pathing, TerrainType, ShaderSlot, ViewAid, ViewState, RecentMaps) still pass but do not test anything of ours: keep them in the tracking target, do not count them as our coverage.
* **Need adaptation**: `WaterBodiesEditTests` (links `moho/sim/WaterBodies.cpp`; fine, but add the include dirs), `TextureBakeTests` (own target, links `faf_engine`; if `EdTextureBake` is replaced by
  our DDS writer, rewrite against `ed_dds_fields`), and every test that skips without `FAF_RETAIL_MAPS` (Adaptive tables, EffectGraph, Emitter, GroupOptions, Lighting, Units, Vault, WaterBodies, Wave):
  set the env var in the CI/nightly script, otherwise they are silently skipped. `SaveFileTests`/`PackageTests` must keep zlib 1.2.3 (`zlib123`) as in tests/CMakeLists.txt l.385-392.
* **Do not exist as GoogleTest**: the retail round trip of 63 maps is `EdRoundTrip` driven from `EdApp` command line; it needs a new driver: `ed_roundtrip_check(scenario)` native + a Lua selftest
  (pattern: `scripts/ed_prop_roundtrip.py`).
* **To write**: one Lua selftest per binding unit (thin: table in/out, `selftest_*.lua`, run by `editor_inst.py selftests`); the logic is already covered by U's GoogleTest.
* Harness mismatch: our native tests are stand-alone MSVC programs (`scripts/ed_native_tests.py`, 38 files); U's use gtest in the repo's CTest. Keep gtest for imported logic.

## 13. Order and blockers

0. Infrastructure (lib + registration + test target) blocks everything.
1. Importers (7), `EdChecks` prop symmetry (9), Terrace/Plane brushes (10): independent, small, fast wins.
2. Map file + save text + package (1): unblocks 4 (effect markers in `_save.lua`), release flow, retail round-trip gate.
3. Vault (2): independent; most visible to users; UI is the cost.
4. Adaptive (3): needs only text natives; needs `units.lua` group tree access.
5. Water bodies/waves (6): after a check that hi-res water map and bodies coexist.
6. Particle Editor (4): after 1 (markers) and a decision on viewport display.
7. Material editor (5): last, optional. 8 (play setup) any time, Lua only. Script editor (9): deferred.
Risk summary: highest = 8 (second session), 6 (water map conflict, sim effect), 1 (byte-exactness vs our edit paths and formats 3/4); lowest = 7, 2 logic, 3 logic.

## 14. Recommended work packages (independent workers)

**WP1 Library and binding scaffold.** Goal: U's pure sources build in the Studio exe and in the GoogleTest target. Files: new `src/editor/logic.cmake` (static lib `faf_editor_logic` from the
17.9 k pure `.cpp`), `src/moho/editor/editor_sources.cmake` (+ binding units), `src/editor/CMakeLists.txt` (`if(FAF_EDITOR)` guard for `faf_editor`), `tests/CMakeLists.txt` (tests link the lib),
`src/moho/editor/EdUpCommon.h` (Lua table <-> struct helpers, job polling pattern). Done: ON tree builds Studio, OFF tree builds `faf_editor`, `faf_editor_brush_tests` + `faf_editor_bake_tests` pass,
`ed_up_version()` native answers. Depends on: nothing.

**WP2 Importers/exporters.** Goal: `.fafmapmarkers .scunits .proppaintset .scmsl .scmst .scmlighting .scmskybox` read/write from menus. Files: `EdUpImportLua.cpp` (natives over `EdMarkerPreset`,
`EdUnitPreset`, `EdPropPaint`, `EdLayerPreset`, `EdLighting`, `EdSkybox`, `EdJson`), Lua glue in `map.lua`, `units.lua`, `scatter.lua`, `strata.lua`, `environment.lua`, menu entries in
`gui/menus.lua`, `selftest_import.lua`. Done: each format round-trips on a sample file; upstream tests pass; selftest passes. Depends on: WP1.

**WP3 Exact save: map file, save-file text, package.** Goal: saving an untouched map reproduces the original bytes; saving an edited map changes only what was edited; `_save.lua` blocks keep comments;
release makes a vault zip. Files: `EdUpMapFileLua.cpp` (natives over `EdMapFile`, `EdImageChunks`, `EdSaveFile`, `EdLuaText`, `EdPackage`, `EdRoundTrip` rewritten without `EdDocument`), patched `PropRecord` (scale),
`keepImages` from `MapDocument`/`EdStrata`, `map.lua`/`maps.lua`/`release.lua`/`luaser.lua` glue (entry adapter), mesh-terrain fallback to the engine writer, `scripts/ed_roundtrip.py` +
`selftest_roundtrip.lua`. Done: 63 retail maps identical (script run with `FAF_RETAIL_MAPS`), edited-prop-scale test, marker edit leaves other text unchanged, mesh-terrain map still saves, upstream
SaveFile/Package/ImageChunk tests pass. Depends on: WP1.

**WP4 Vault client.** Goal: search, sign in, download and open a vault map from the start screen. Files: `EdUpVaultLua.cpp` (`ed_vault_*`, `ed_open_url`, threads polled from Lua), `vault.lua` (model),
`gui/panels_vault.lua` + dialog, hook in `gui/feature_start.lua`, preview cache folder, FAF client id decision. Done: search with every client filter returns pages, thumbnails show, a download installs
into the user maps folder and opens (`maps.Open`), token survives restart in DPAPI file, `VaultTests`/`FafApiTests` pass, no token in logs. Depends on: WP1.

**WP5 Adaptive maps.** Goal: author `_tables.lua` / `_options.lua` and see unit fate per lobby setting. Files: `EdUpAdaptiveLua.cpp` (`ed_adaptive_*` over Model/Tables/GroupOptions/UnitFate, `ed_wreck_value`),
`adaptive.lua`, `gui/panels_adaptive.lua` + window, `units.lua` group-path accessor. Done: open one retail adaptive map, edit mex group counts for one option, the written `_tables.lua`/`_options.lua`
differ only in those lines; fate text matches U's for 5 sampled units. Depends on: WP1 (WP3 for writing the scenario flag with text preserved, optional).

**WP6 Water bodies, shore waves, .scmwtr.** Goal: edit `WaterBodies` with a fill preview, generate and edit shore wave generators, import/export `.scmwtr`/`.scmwaves`. Files: `EdUpWaterLua.cpp`, `water.lua`,
`gui/panels_waterbodies.lua`, overlay draw via `ed_overlay_*`, `selftest_waterbodies.lua`. Done: fill preview equals `STIMap::InstallWaterBodies` result on 3 retail maps; a map with one body saves and loads;
shore line stays clean with the hi-res water map on and off; sim checksum of an unedited retail map unchanged. Depends on: WP1, WP3 (waves go through the `.scmap` writer).

**WP7 Brushes and checks.** Goal: Terrace and Plane brush modes, prop symmetry check, free decal path if Paths cannot. Files: `EdBrush.cpp`/`brushes.lua` (+ tool panel rows, tips in `tipdata.lua`), `EdUpChecksLua.cpp`
(`EdChecks` prop symmetry, `SplitLuaError`), `terrainchecks.lua`/`markercheck.lua`. Done: brush kernels equal U's `HeightBrushTests` expectations in a native test; undo restores bytes (`ed_cmd_undo` checksum);
prop symmetry finding shows in the checks panel. Depends on: WP1.

**WP8 Particle Editor.** Goal: edit emitter/beam/trail files with a curve stack, preview live, browse effects. Files: `EdUpFxLua.cpp` (`EdEmitter`, curve sampling, `EdEffectGraph` templates), engine glue from
`EdParticlePreview`/`EdParticleViewport` (without ImGui renderer; display in `EdPopout` or world slot), `fxparticle.lua`, `gui/panels_particles.lua` (using `curvewidget`), browser; decide split with `fxedit.lua`.
Done: round trip of all retail emitters (U's EmitterTests with `FAF_RETAIL_MAPS` equivalent), an edited curve changes the preview within one frame, file written into a mod/map folder loads in game. Depends on: WP1, WP3
(for `MapEditorEffects` markers).

**WP9 Play setup profiles and live extras.** Goal: Play with AI slots, teams, fog, victory, mods; saved profiles; live water level and unit warp/enhance. Files: `playsetup.lua` (reads `aitypes.lua`, `factions.lua`),
`ui.lua` Play section, small natives modelled on `EdLiveTerrain.cpp` / `EdLiveUnits.cpp` only if the live check shows a gap. Done: a 2-AI play starts from a saved profile; a water-level edit shows in the running play.
Depends on: nothing hard (WP1 only for the natives).

**WP10 (optional) Material Editor.** Goal: colour texture graph for stratum albedo/normal. Files: `EdUpTexGraphLua.cpp`, Defs in `graphnodes_tex.lua` or a separate canvas, `gui/panels_material.lua`. Done: U's TextureGraph
tests pass, a graph writes a DDS the engine loads as a stratum. Depends on: WP1; start only after WP2-WP6.

Not recommended: porting `EdMapScene`/`EdTools`/`EdShell`/`EdApp`, the F6 second-session play, the in-editor code editor (use an external editor + Check instead).
