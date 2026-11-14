# Map editor comparison: upstream editor vs FAF Studio (ours)

Read-only comparison, 2026-11-11. Nothing was built or run; "stronger" is judged from the documents, the file lists and the code
headers, not from using either editor. Tree used: `C:/Users/Marlo/Documents/GitHub/faf-re-editor-merge` (branch
`editor-upstream-merge`, a merge of `upstream/master` into our `editor-d3d11`, conflicts resolved and staged, not committed).

## 0. What each side is

| | Upstream editor (Draiget / Vladislav Smetannikov) | FAF Studio (ours) |
|---|---|---|
| Age | first editor commit 2026-11-08; 151 commits touching `src/editor` in 4 days (2, 35, 72, 39 per day) | first commit of the Studio repo 2026-10-19 (236 commits there), plus the engine-side work on branch `editor` since about 2026-10-15 |
| Where | `src/editor/` (83 .cpp files, about 51.8 k lines with headers), `tests/editor/` (42 files, about 5.9 k lines, 195 GoogleTest cases), `docs/MAP_EDITOR.md` (one 95 KB document, 3 sections: build, Play, how it is built) | native `src/moho/editor/` (about 100 .cpp/.h, 35.7 k lines without the generated shader header, plus 106 HLSL / .hlsli kernels, native tests 14.9 k lines) and the Lua tree `FAF_Studio/editor/runtime` (about 133 k lines of Lua, 19 k of them selftests; 55 `panels_*.lua`, 83 `selftest_*.lua`, about 200 `ed_*` natives) |
| Program | its own exe `FafEditor_x64.exe` (target `faf_editor`, entry `main()`), runs the game's `CScApp` loop inside; two render heads: game view (head 0) + ImGui panels (head 1) | the game's own exe built with `-DFAF_EDITOR` (`FAFStudio.exe`); the editor is an "editor mode" of the game session, UI is the game's own maui toolkit driven by Lua |
| Model | native `EdDocument` loaded on a worker thread, separate from any play; Play starts a second `CWldSession` | native `MapDocument` + the live session; edit mode and play mode are two states of one process, edits go through one commit path between beats (`MAP_EDITOR_DESIGN.md` rules 1-4) |
| Renderer | Direct3D 12 or Vulkan only (D3D9 delay-loaded, never used; D3D11 only as a WARP texture decoder) | Direct3D 11 only (decision 2026-11-05, `D3D11_ONLY.md`); natives draw on the raw D3D11 device (`EdD3D11Device.h`) |
| Docs style | one dense feature log with test-run switches (`/brush`, `/layer`, ...) and measured results per feature | many design / QA / perf documents (`docs/projects/editor/*.md`, about 640 KB), parity audit against the FAF Unity editor and the GPG editor |

## 1. Feature table by area

Legend: O = overlap (same job), C = complementary, X = conflict (cannot both stand as is), - = only one side.

| Area | Upstream has | Ours has | Relation | Stronger today |
|---|---|---|---|---|
| Height sculpting | `tools/EdHeightBrush.cpp`: Raise, Lower, Smooth, Flatten, Set height, Noise, Terrace, Plane (3 points), Stamp; limits by height range and slope; exact symmetry (1-N mirror/turn groups, GoogleTest); undo by 32x32 tiles, 256 MB (`undo/EdHeightHistory.cpp`); height import/export PNG/BMP/TIF/RAW/R16 (`EdHeightFile.cpp`); symmetry auto-detect on open (`DetectSymmetry`) and symmetry check with red blocks (`EdSymmetryCheck.cpp`) | `brushes.lua`, `stamp.lua`, `symmetry.lua`, `mirror*.lua`, `gensym.lua`, `EdBrush.cpp`; shape/spline tool (`panels_shapes.lua`); symmetry detect (`selftest_symdetect`); heightmap import/export (`heightio.lua`); Map > Resize | O | roughly even on brushes and symmetry; ours has splines, upstream has the stamp/plane/terrace modes and byte-exact tile undo |
| Erosion | not found (grep for erosion/erode in `src/editor` and MAP_EDITOR.md: no hit) | CPU + GPU erosion: `EdErosion.cpp` (105 KB), hydraulic, droplet, stream power, thermal, rock/soil, snow, wind, glacier (`EdFieldEro2.cpp`), GPU kernels `gpu/erosion_*.hlsl`, Erosion panel, Erode / Rain / Deposit brushes (`erosionbrush.lua`, `erosionpaint.lua`) | - | ours |
| Procedural terrain / graph | not found for heights (the Material Editor graph makes textures only, see Particles and materials) | native field engine `EdField*.cpp` (53 externally registered ops + core ops; README says 100+), GPU versions of dozens of them (`EdGpuOps.cpp`, 106 files in `gpu/`; the exact count was not tallied), node graph canvas with about 190 node definitions (`graphnodes*.lua`, `graphrun.lua`, `gui/panels_graph*.lua`), about 40 shipped graph presets (`graphpresets/`) + library (`TERRAIN_GRAPH_LIBRARY.md`), Generate panel, Oversample node, Gaea / World Machine import and live link (`EdInteropLua.cpp`, `interop.lua`), SC-specific tools (pads, rings, reach/regions, skeleton; `sctools.lua`), layout generator (`layout.lua`, `MAP_LAYOUT.md`) | - | ours |
| Texture layers (10 slots) | Layers tab with texture browser over `/env/*/layers`, size drag, shader picker with the slot meaning per shader (`EdTextureLibrary.cpp`, `EdShaderSlots.cpp`); layer files `.scmsl/.scmst` (FAFME) | `strata.lua`, `panels_strata.lua`, `texsets.lua` (theme sets by role), `texscale.lua`, `shaders.lua` (all terrain shaders with profiles), `LAYER_CONVERSION.md` / `stratumconv.lua` (convert between shaders) | O | ours for shader coverage and conversion; upstream's slot-meaning panel is more direct |
| Texture painting | mask brush Paint/Erase/Smooth with symmetry, limits, rules by height/slope, mask import/export, layer weight overlay, terrain-type brush (`EdMaskBrush.cpp`, `EdTerrainTypes.cpp`) | paint brushes (`brushes.lua`, `scatter.lua`), recipes (`recipes.lua`, `roledetect.lua`), `maskgen.lua` mask generator, erosion-driven paint, ground-kind graph nodes, terrain-type paint (`terraintype.lua`, `EdTerrainType.cpp`), Paint mask size setting (`Strata.SetMaskSize`, up to 8192) | O | ours for generated/rule-driven paint; upstream simpler and tested per texel |
| Map-wide shader textures | shows which slot is map-wide per shader; says the textures are baked "by FAF's map tools, not here" | `maptextures.lua`: normal map, lighting/AO/shadow texture, roughness-height atlas, macrotexture, specular, from the graph, native DXT5 writer `ed_dds_fields`, Oversample up to 8192, pipeline lab over 32 shaders (`MAP_TEXTURES.md`) | C | ours |
| Water | `EdWater.h` panel (levels, colours, 4 wave maps, textures), water bodies (`EdWaterBodies.cpp`, engine `WaterBodies.cpp`, own levels per lake, `sim_FixWaterBodies`), shore wave generators (`EdWaves.cpp`, `.scmwaves`), `.scmwtr` import/export | `panels_world.lua` (water look), `panels_waterx.lua` (ramp, cube map, wave maps, movement presets), high-resolution water map for clean shores (`ed_water_hires`, `WATER_SHORE.md`) | C | upstream (bodies and wave generators have no ours equivalent: not found); ours has the shore-quality fix |
| Lighting / sky / fog | `EdLighting`, `EdSkybox` (dome, planets, cirrus), "lighting from another map", `.scmlighting` / `.scmskybox` import/export | `environment.lua`, `envlib.lua` (presets), `panels_sky.lua`, `panels_skyobjects.lua` (billboards), strategic-view colours, `EdEnv.cpp`, `EdScmapEnv.cpp` | O | even |
| Props | prop tool Single/Scatter/Erase, Select with box select, paint list with chance/turn/scale, map-reclaim totals, `.proppaintset` | `props.lua`, `propbulk.lua` (`EdPropBulk.cpp`), `scatter.lua`, `panels_props.lua`, `panels_scatter.lua`, find/replace, select same | O | even; ours scatter is generator-driven, upstream's reclaim summary and symmetry check of props are nicer |
| Decals | place/select/path (Catmull-Rom) modes, texture browser by type, spec pairing (`EdDecals.cpp`, `EdDecalShape.cpp`) | `decals.lua`, `panels_decals.lua`, `gizmo.lua` | O | upstream (path mode); ours not verified in detail |
| Markers, chains, armies | 20 marker types, connect path nodes under symmetry, chains, army settings and alliances, FFA team check, playable area, marker import/export `.fafmapmarkers` (`EdMarkers.cpp`, `EdSaveFile.cpp`, `EdArmiesPanel.cpp`) | `markerprops.lua` (all template fields), `chains.lua`, `armies.lua`, `armysetup.lua`, `playable.lua`, `pathtool.lua`, `markercheck.lua`, `MARKERS.md` | O | roughly even; upstream edits `_save.lua` text in place with byte-exact retail round trip (63 maps) |
| Units on the map | Units tool, groups tree, "what becomes of a unit" (Appears / lobby option / wreck value), `.scunits` import/export, units' blueprint icons | `units.lua`, `panels_units.lua`, `platoons.lua`, `panels_platoons.lua`, unit icons (`icongen.lua`, IoU 0.67 recipe) | O | upstream for save-file fidelity and wreck/lobby logic; ours for platoons |
| Mission / script | `_script.lua` text editor with Lua colouring and Check (`EdCodeEditor.cpp`, `EdLuaSyntax.cpp`), scenario syntax check | stage/trigger node mission editor with compiler (`mission.lua`, `missionplat.lua`, `mbase.lua`, `MISSION_COMPILER.md`), bases, dialogues, objectives, platoon nodes, run panel with trace/skip/speed, "Play here" at a stage, hand-written script import outline (`missionimport.lua`), sim self tests (`selftest_mission*.lua`, `editor_mission_sim.py`) | C | ours |
| Adaptive maps | Adaptive Map window and panel (`EdAdaptiveWindow.cpp` 46 KB, `EdAdaptiveTables.cpp`, `EdGroupOptions.cpp` 50 KB, `EdUnitFate`): `_tables.lua`, `_options.lua`, lobby preview | not found (no `_options.lua` / `_tables.lua` handling in the Lua tree) | - | upstream |
| Map formats and save | `.scmap` v60 writer, byte-exact round trip of all 63 retail maps (`EdMapFile.cpp`, `EdImageChunks.cpp`, `EdRoundTrip.cpp`), `_scenario/_save/_script` text kept, Save as new folder, backups, package zip for the vault (`EdPackage.cpp`), New map (5-81 km) | `.scmap` save by the engine, autosave, backups, Release map (next `.vN` folder + checks, `release.lua`), `scripts/pack_map.py`; container 3 "Extended" / 4 "Full3D" map formats on branch `editor-mapformat` (524 files, 79 k lines, `docs/mapformat/`; NOT in the merge tree); SC2-style mesh terrain (`EdMeshData/Draw`, `MESH_VIEW.md`), mesh importer (`meshimport.lua`) | C | upstream for classic-format fidelity; ours for new formats and mesh terrain |
| Play in editor | Play (F5) inside the editor window; setup profiles, AI slots, teams, fog, observer; quick start; F6 editor/game view switch; live edits reach the running play: heights via `gSimBeforeBeat`, lighting, water, masks, layers, decals (WPE.39-49); game unit picking/warp/enhancements (`EdLiveUnits.cpp`); Test run in Check | play test by session reload (`ui.Play`, `control.lua`), Play-from-stage, mission run panel, unit lab "Test in game", `lua/editorsim/` sim callbacks, peace sweep, sim stress script | O | upstream for terrain/setup live loop; ours for mission-oriented testing |
| Check / validation | `EdChecks.cpp`: starts/resources off map, symmetry of markers and props, land and ship pathing, Lua syntax of the three scripts, Test run | `terrainchecks.lua`, `markercheck.lua`, `layoutcheck.lua`, `unitcheck.lua`, `modcheck.lua`, release findings, terrain QA reports | O | even |
| Mod / unit / blueprint tooling | not found | mod project browser, blueprint editor (`bpedit.lua`), unit wizard from templates with validators (`unitwiz.lua`), unit viewer with animations/bones/LODs, asset browser, icon generator | - | ours |
| Particles and materials | Particle Editor (Cascade-like curve stack, 21 curves, beams, trails, `EdEmitter.cpp`, byte-exact round trip of 2,437 retail emitters), effects as node graphs (`graph/EdEffectGraph.cpp`), Particle Browser (3,045 effects), live preview viewport (`EdParticleViewport.cpp`), Effect markers saved as `MapEditorEffects`; Material Editor: CPU node graph making stratum albedo/normal/mask DDS with Live Update (`graph/EdTextureGraph.cpp`, `EdTextureBake.cpp`, `ui/EdMaterialEditor.cpp`) | effect viewer (`effectview.lua`: play a template at the lab spot) and numeric field editing of emitter/beam/trail blueprints as merge blueprints (`fxedit.lua`); no curve or node editor; no per-layer procedural albedo (texture sets pick existing textures) | C | upstream |
| Online vault | FAF vault search with all client filters, sign in (Hydra device flow, DPAPI token), download + open (`EdFafApi.cpp`, `EdVault.cpp`, `EdMapBrowser.cpp`) | local map list, start screen with recent maps and previews (`maps.lua`, `gui/startscreen.lua`); online vault: not found | - | upstream |
| UI toolkit | Dear ImGui 1.92.4 docking, drawn by `EdImGuiRenderer.cpp` on gal GPU programs; panel layout in `layout.ini`; UI scale 75-200 %; `/uiclicks` test input | maui (the game's UI) driven from Lua: dock/pop-out windows with their own swap chains (`EdPopout.cpp`), workspaces, hotkeys, tooltips for every control (`tipdata.lua`), tour, help topics, layout checker; DirectWrite text (`edtext.dll`, `EdTextBackend.cpp`, `TEXT_RASTER.md`), `Control:SetClipChildren` | X (different stacks) | ours more complete as a product; upstream's is simpler to extend in C++ |
| Platform | D3D12 / Vulkan; x64 and x86 targets (`FafEditor.exe`) | D3D11, x64 | X | upstream (tracks the project's chosen renderers) |
| Packaging / installer | `build.ps1 -Editor` copies `FafEditor_x64.exe` into the FAF `bin_x64`; map zip for the vault; installer or editor release package: not found | `scripts/package_editor.py` -> `dist/FAFStudio/` + zip (MANIFEST sha256, README, help), `EdBootstrap.cpp` (finds `%ProgramData%\FAForever`, junction-links gamedata, DPI, first-run args), user folder `%APPDATA%\FAFStudio`, crash handling, branding, version stamping (`PACKAGING.md`, `RELEASE.md`, `BRANDING.md`) | C | ours (no installer exe either; a zip) |
| Performance work | Play start 1-2.7 s via kept rules and 4-thread normal map (documented); heap/memtrace tooling (`EdMemTrace.cpp`, `/memtrace`); known issue list | Lua frame budgets measured and gated (`PERFORMANCE.md`, 89 KB), frame cap by refresh rate, idle cap, retained overlay (`EdOverlay.cpp`, 105 KB), render-stat switches (`ui_CullOffscreen`, `ui_SkipTransparent`), shadow cache (`EdShadowCache.h`), GPU compute for field ops (RX 7900 XTX verified, `GPU_COMPUTE.md`), parallel bit-identical field ops | O | ours on editor frame/UI cost; upstream on play start and engine perf (its engine-wide perf commits are not editor-specific) |
| Tests | 195 GoogleTest cases in `tests/editor/` (retail round trips under `FAF_RETAIL_MAPS`: 63 maps, 380 armies, 2,437 emitters, 36 maps of waves), target `faf_editor_brush_tests`, CTest; engine CI (`asan.yml`) | 83 Lua selftests run in a live instance (`editor_inst.py selftests`), native engine-independent tests with their own harness (`scripts/ed_native_tests.py`, 38 files), nightly (`editor_nightly.py`: lint, selftests, panels, clicks, tooltips, layout at 3 UI scales, workspaces, menus, stress, perf, mission sim), golden checksums for field ops, pipeline lab | O | ours wider (UI + layout + perf gates); upstream tighter on file-format byte exactness |

## 2. Places where both touch the same engine files or the same concept

Engine files edited by both (our diff vs merge base `cc8335d1c`: 47 non-editor files; 41 of them also changed upstream; the merge list had 21
conflicted files). How each side handles the concept:

1. **Texture-atlas lookup cache** (`render/d3d/CD3DTextureBatcher.cpp`). Ours: `ren_AtlasFastLookup` (pointer hash before the ordered set), counted in
   `EdRenderStats`. Upstream: engine `ren_TextureAtlasCache`. The merge already deleted ours and points `EdRenderStats.h` at the upstream switch.
2. **Sim hook per beat.** Upstream: `moho::gSimBeforeBeat` (`sim/SimEditorHook.h`, called first in `Sim::AdvanceBeat`, now in `SimTick.cpp`), set by
   `EdLiveTerrain.cpp` for the play's height edits. Ours: a direct call `editor::ApplyPendingHeightEdits(this)` inside `Sim.cpp` (the file was split
   upstream). The merge added `InstallSimBeatHook()` in `EditorDocument.cpp` called from `EdBootstrap.cpp`. Same idea, two queues: ours
   `EditorDocument` (sim field + path caches dirtied), theirs `EdLiveTerrain` queue plus `PathTables::DirtyClusters` and unit re-seat. If both run in one
   process the second install overwrites the first pointer: one of the two queues has to own the hook.
3. **Stratum masks.** Ours: `EdStrata.cpp` writes the engine's dynamic sheet directly (its own lock/DISCARD workaround because partial
   `UpdateStratumMask` left stripes), `Strata.SetMaskSize`, and `terrain/StratumMaskSize.h` (masks keep the saved resolution, up to 8192). Upstream: calls
   `EnterEditMode` / `GetStratumMask` / `UpdateStratumMask` of `CWldTerrainRes` (`EdMapScene.cpp`) and fixed `GetStratumMask` reading the wrong channel
   (commit 7237e58a8, 2026-11-09). `CWldTerrainRes.cpp` now exists upstream as a new file; the merged `Finalize` still sets `mStratumMaskWidth = halfWidth`
   at line 1897 and uses `StratumMaskSize.h` only at the second place (line 4003): worth a check.
4. **Normal-map update after terrain edits.** Upstream: one update per tile per beat (`16e36bfd3`, `IWldTerrainRes::NotifyMapChanges`, 4-thread rebuild).
   Ours: `ed_terrain_*` height commit with a native normal-map path on the worker pool (`EdNormalMapParTest`, 267 ms for 2049 x 2049).
5. **Text and UI drawing.** Upstream: MSDF atlas text on every renderer, interface as one instanced draw, mod fonts (`CD3DFont.cpp`, `CD3DPrimBatcher.cpp`,
   `render/font/Msdf*`). Ours: `ed:` fonts through `edtext.dll` (DirectWrite outline rasteriser, LCD glyph quads, second A8R8G8B8 atlas in the prim
   batcher), `EdUiClip` / `SetClipChildren` CPU clip of prim quads, `EdUiCull.h`. Both rewrote the same draw path; both are in `CD3DPrimBatcher.cpp` and
   `CD3DFont.cpp`.
6. **Game-viewport redirection.** Upstream: two heads, `moho::gViewportOnlyView`, `gViewportBeforeFrame`, `IEdRenderHook` via `ED_SetHook`, `gAppRenderers`,
   `gAppWindowed`, `gUIBeforeStartGameUI`, `gAppIdleClock`. Ours: the world view lives in the game's maui tree, extra windows are DXGI swap chains
   (`EdPopout.cpp`), `gAppRenderers` reused by `CScApp.cpp`. `CScApp.cpp`/`WinApp.cpp`/`WinMain.cpp` carry both, selected by `FAF_STUDIO_EDITOR`
   vs `faf_editor`.
7. **Renderer policy.** Upstream editor: D3D12 or Vulkan only. Ours: D3D11 only (the natives `EdMeshDraw`, `EdFxaa`, `EdPopout`, `EdOverlay` use the raw D3D11
   device). The same `gAppRenderers` list is the switch; the two editors want opposite values. The GPU compute backend is a separate D3D11 device on the same
   adapter, so it does not depend on this choice.
8. **Water.** Upstream: water bodies (engine `WaterBodies.cpp`, `HighFidelityTerrain`, `WaterBodySurfaces`) and the water map rebuilt through edit mode. Ours:
   a second high-resolution water map in the terrain resource (`GetWaterMap()` hands out the finer texture). Both change `RebuildWaterMapRect` consumers.
9. **Prop scale lanes** (`sim/CWldMap.cpp`). Upstream doc: the retail loader reads and drops the three scale floats, so the editor writes scale 1. Ours:
   "EDITOR DIVERGENCE: kept" (`CWldPropEntry::mScale`, scale applied), a compat layer for the patched exe. Different semantics for the same bytes.
10. **Symmetry detection, resource/path checks, `.scmap` read/write, `_save.lua` parsing.** Both wrote their own (upstream in C++, byte-exact; ours Lua
    plus `editor/core` `scmap.cpp` / `scm.cpp` / `dds.cpp`, `EdScmapEnv.cpp`). No shared code.
11. **Shadows.** Upstream: ray-traced shadows, cascade fits (`Shadow.cpp` +760 lines). Ours: `EdShadowCache` (shadow-map cache per `Shadow`). Same function,
    different goal.
12. **Mesh / LOD.** Ours `MeshLodDepth.h`, `HardwareMeshBatch.cpp`, `Mesh.cpp` edits; upstream edits the same files for perf; low conflict risk.
13. **Build.** `src/CMakeLists.txt`: ours `-DFAF_EDITOR` option and `editor_sources.cmake` (renamed `FAF_STUDIO_SOURCES` in the merge); upstream
    `src/editor/CMakeLists.txt` target `faf_editor`, `tests/CMakeLists.txt` target `faf_editor_brush_tests`.
14. **Contribution rule that applies to both.** `CONTRIBUTING.md`: sim code must keep retail checksums; editor hooks in sim files must be null in the game.
    Our prop-scale divergence in `CWldMap.cpp` and the pre-merge `Sim.cpp` height-edit call are the parts a reviewer would question.

## 3. What in ours has no equivalent upstream, and could be contributed on its own

Sizes are source bytes in `src/moho/editor` (excluding generated shaders) or lines of Lua. "Self-contained" = what it needs to build outside the Studio.

| Module | Size | Depends on maui/Lua UI? | What it needs to be self-contained |
|---|---|---|---|
| Field engine core, `EdFieldCore.h/.cpp`, `EdField{Filt,Gen,Land,Sc,Path,Ero2}.cpp`, `EdFieldUtil.h` | about 490 KB with erosion CPU (`EdErosion.cpp` 105 KB) | no for the maths (header says "engine independent, no moho types", tested alone in `tests/EdField*`, `EdLandTest`, `EdScTest`); `EdField.cpp` binds it to Lua (`ed_field_*`) | an upstream panel/tool calling `field::RunOp`; goldens (`EdFieldTest`) port as GoogleTest; bit-identical across thread counts is already a property |
| GPU compute backend, `EdGpu*.cpp`, `gpu/*.hlsl` (106 files) | about 260 KB C++ + 180 KB HLSL | no; separate D3D11 compute device on the game's adapter, so it works next to a D3D12/Vulkan renderer | the field engine above; `EdGpuShaders.generated.h` made by `scripts/gen_gpu_shaders.py`; `scripts/gpu_fxc_check.py`; erosion not bit-identical by design (droplet solver) |
| Erosion suite (`EdErosion.cpp`, `EdGpuErosion.cpp`, `erosion.lua` settings, brushes) | CPU 105 KB, GPU 29 KB | maths no; Erosion panel and brushes yes (maui) | upstream brush hook (`EdHeightBrush`-style) to call `Erode/Rain/Deposit`; a panel |
| Gaea / World Machine interop (`EdInteropLua.cpp`, `interop.lua`, `interopexport.lua`) | 38 KB native + Lua | Lua-bound, panel in maui | file watcher + import code is plain C++/Lua; needs a panel; docs in `TERRAIN_INTEROP.md` |
| Node-graph terrain generator (`graph*.lua`, `graphnodes*.lua`, 42 presets) | about 190 node defs; Lua | model/runner mostly UI-free Lua (`graphrun.lua`), canvas and panels in maui | upstream already has an ImGui node canvas (`ui/EdNodeCanvas.cpp`) that could host these nodes; the runner needs the field engine |
| Map-wide texture generation (`maptextures.lua`, `alphagen.lua`, native `ed_dds_fields`, `ed_tex_atlas`) | Lua + native writer | model UI-free; panel maui | field engine + a DDS DXT5 writer (`EdDdsEncode.h`, header-only) |
| Mission compiler (`mission.lua`, `missionplat.lua`, `mbase.lua`, `lua/editorsim/mission.lua`) | two compile flavours (saved script, test-run script), node catalogue | model + compiler are plain Lua 5.0 (the editor has its own Lua state upstream too); panels maui | a node-canvas UI (upstream's `EdNodeCanvas` could be reused); sim run panel needs `editorsim` callbacks |
| Unit wizard, blueprint editor, mod project, unit viewer, icon generator | Lua (sizes not tallied) | yes (maui panels) | most of it is data and checks (`unitwizdata.lua`, validators) but it needs a UI port |
| Mesh terrain (`EdMeshData/Draw/Lua`) + map formats 3/4 (branch `editor-mapformat`) | 85 KB native; branch 79 k lines | engine side | `EdMeshDraw` is raw D3D11, would need D3D12/Vulkan ports; map format work is separate and engine side (`docs/mapformat/`) |
| `EdBootstrap.cpp` (FAF data folder discovery, junctions, DPI, first-run args) + `package_editor.py` | 21 KB + script | no | upstream editor reads `init_faf.lua` from `bin_x64` instead; useful only if upstream wants a stand-alone package |
| Stratum mask resolution (`StratumMaskSize.h`) | 37 lines | no | already merged; affects the game too (masks no longer cut to half), so it needs the sim-parity review of CONTRIBUTING |
| Layout / start-position generator (`layout.lua`, `layoutcheck.lua`, `layoutmarkers.lua`) | Lua | model yes, panel maui | needs field engine for the buildability map |
| QA harness (`editor_nightly.py`, `editor_inst.py` instances, layout checker) | scripts | tied to maui and the command channel | not portable as is |

Most self-contained to offer first: the field engine plus GPU backend plus erosion (engine side, no UI, with tests and goldens), then the
Gaea/World Machine interop and the mission compiler model.

## 4. What in upstream we would waste effort duplicating

- Classic `.scmap` v60 writer with byte-exact round trip, `_save.lua` / `_scenario.lua` text-preserving editing, vault packaging
  (`EdMapFile`, `EdImageChunks`, `EdSaveFile`, `EdPackage`): 63 retail maps and 380 armies verified; ours relies on the engine's own writer.
- FAF vault search / sign-in / download (`EdFafApi`, `EdVault`, `EdMapBrowser`).
- Adaptive map editing (`_tables.lua`, `_options.lua`, lobby option preview, unit fate / wreck values): we have none.
- Particle Editor, effect graphs, Particle Browser and the particle viewport, plus the CPU texture Material Editor.
- Water bodies, shore wave generators, `.scmwtr` import/export; FAFME file importers (`.scmsl`, `.scmst`, `.fafmapmarkers`, `.scunits`, `.proppaintset`,
  `.scmlighting`, `.scmskybox`, `.scmwaves`).
- Live editing of a running play (heights, water, layers, masks, decals) and the F6 editor/game switch, the play setup profiles with AI slots.
- MSDF text and instanced UI draw in the engine: our DirectWrite backend (`edtext.dll`) overlaps with it for any UI drawn by upstream's engine path; the
  maui text path is the only place it still pays.
- Script editor with Lua colouring and Check; path / resource / symmetry checks (`EdChecks`, `EdPathing`).
- ImGui shell, docking layout, UI scale: only worth keeping alongside maui if the two programs are merged into one.

## 5. Open questions the comparison cannot answer

- Which exe is the product after the merge (`FafEditor_x64` vs `FAFStudio.exe`), and whether D3D11 or D3D12/Vulkan is the editor renderer: items 6-7
  in section 2 are the same switch with opposite settings.
- Whether the maui toolkit stays: all of our mission, mod, graph and layout UI is maui/Lua; upstream's panels are ImGui/C++.
- I did not compile or run either tree here; "works" statements are the documents' own (upstream gives test-run numbers per feature; ours gives selftest
  counts and nightly reports, with GPU kernels first verified on a real card 2026-10-24).
