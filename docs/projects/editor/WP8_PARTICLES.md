# WP8: Particle editor, preview, browser and effect decorations (2026-11-11)

Work package 8 of `EDITOR_PORT_ANALYSIS.md` (section 4 and section 14). Engine: branch `port/wp8-particles` of faf-re (worktree `C:\Users\Marlo\Documents\GitHub\faf-re-port-wp8`, on top of `port/wp3-exact-save`). Lua, scripts and this file: the FAF_Studio repository (`fxparticle.lua`, `fxdeco.lua`, `gui/panels_particles.lua`, `gui/panels_particleview.lua`, `gui/panels_particlebrowser.lua`, `selftest_particles.lua`, `scripts/ed_fx_audit.py`). Nothing is pushed.

## What it does

* **Particle editor** panel: opens an emitter, beam or trail file of the game (or starts a new one) and edits it: the 21 curves of an emitter with the curve plot (drag a key, click empty plot to add one, right click or Ctrl+click to delete, the spread of a key drawn as a band, key time / value / spread as sliders), the settings (lifetime, repeat time, frames, strips, LOD, sort order, blend mode, the 13 switches, the 3 fidelity levels, textures), the key catalogue of a beam or trail. Own undo / redo. `Write file` puts the file into `effects/emitters/` of the open mod project or of the map's folder.
* **Particle preview** panel: the open file played alone on a ground and grid from an orbit camera (drag turns, wheel zooms, front / side / top, background, height, scale, loop). An edit of any value reaches the picture in the next frame (checked, below). It works docked and in a pop-out window; the browser opens it in a pop-out.
* **Particle browser** panel: all 3,045 effect files of the game (`/effects/**/*.bp`, plus the `effects` folders of the open mod project and map) with upstream's faction / kind grouping, a type filter (emitters, beams, trails) and a text filter, and the effect templates of `EffectTemplates.lua` (a template lists its emitter files). A click opens the file in the editor and plays it; the swatch shows its texture; `Place on map` makes it a decoration.
* **Effect decorations**: an `Effect` marker (`effect` = emitter paths joined by `;`, `scale`, `height`) in the map's `_save.lua`, played live in the map view while editing, and a `MapEditorEffects` function in the map's `_script.lua`, called from `OnPopulate`, that plays them in the game.

## Logic: upstream's, bound as natives

`src/moho/editor/EdUpFxLua.cpp` (over the WP1 scaffold `EdUpCommon.h`, library `faf_editor_logic`; nothing of upstream's files is edited):

| native | upstream | does |
|---|---|---|
| `ed_fx_info()` | `CurveInfo`, `FlagName`, tables | the 21 curves (name, group, caption, view range, start value), 13 flags, blend modes, browser factions / kinds |
| `ed_fx_emitter_new / _parse / _write / _roundtrip / _type_tag` | `NewEmitter`, `ParseEmitter`, `WriteEmitter`, `EmitterTypeTag` | emitter file <-> Lua table |
| `ed_fx_curve_samples(keys, xRange, n)` | `EmitterCurveValue` (= `SEfxCurve::GetValue`) | the curve at n points, plus the edges of the spread |
| `ed_fx_flat_info / _parse / _write / _roundtrip` | `FlatFields`, `ParseFlatBlueprint`, `WriteFlatBlueprint` | beam and trail files |
| `ed_fx_effect_class(path)`, `ed_fx_list_files([roots])` | `EffectFaction`, `EffectKind` | the browser's grouping; the game's effect files from the virtual file system (plus extra roots) |
| `ed_fx_templates(text)` | `ParseEffectTemplates` | templates of an `EffectTemplates.lua` that are plain lists of emitter paths |
| `ed_fx_graph_node_types / _build / _emitters` | `EffectNodeTypes`, `BuildEffectGraph`, `GraphEmitters` | an effect as a node graph (Effect output, Emitter, Curve, Constant, Texture nodes) and back |
| `ed_fx_script_effects(script, on)` | `WithScriptEffects` | the map script with `MapEditorEffects` and its call in `OnPopulate`, or without |

### The writer: the file's own text, not a rewrite (a finding)

Upstream's claim "byte-exact round trip of 2,437 retail emitters" is true of the **read**: `EmitterTests` asserts that a file read, written and read again gives the same emitter within the file's precision (two decimals, keys three). Its **text** is the layout of retail's own editor, and only 1,887 of the 2,437 retail emitters (77.4 %) are written back byte for byte by it; the other 550 were made by older versions of that editor or by hand (a key missing, another key order, `'x'` quotes, `1.0` instead of `1.00`). Beams and trails are hand-written (`#` comments, aligned columns): the plain writer reproduces none of them. FAF's own emitters (`effects.nx2`, what the editor sees in the game's file system) are reformatted: 10 of 2,623 are identical.

A plain write would turn a file that was only opened into a different file, so `ed_fx_emitter_write(emitter, original)` and `ed_fx_flat_write(flat, original)` edit the file's text instead (`PatchBlueprintText` in `EdUpFxLua.cpp`): the model read from the text is written (W0) and so is the edited model (W1); each key whose value text differs between W0 and W1 is replaced in the original, at the position `EdLuaText` read for it (`#` comments are blanked first: the game's Lua takes them, `EdLuaText` only knows `--`); a key the file lacks is added before the closing brace; comments, layout and CRLF stay. The result is read back and must equal the edited model, else the plain write is used (`patched = false`). A new file has no original and gets retail's layout.

Result (`python scripts/ed_fx_audit.py wp8`, the install's retail `effects.scd`, extracted, CRLF as shipped): **2,437 emitters: read back as the same emitter 2,437, plain writer byte-identical 1,887, written back through the file's own text byte-identical 2,437; 287 beams and trails: 287 / 287 byte-identical.** The same over the game's file system (FAF's files): 2,623 emitters and 300 beams / trails, all byte-identical through the own-text writer. `selftest_particles` also checks that an edit changes only the keys it touched and that undo writes the original bytes again.

## Split with `fxedit.lua`

* **Particle editor (`fxparticle.lua`)** owns **files**: a new emitter / beam / trail, or a whole existing file, written as a file into a mod project or the map's folder (`effects/emitters/<name>`). The game's blueprint loader (`LoadBlueprints`) reads every `*.bp` of an active mod (`mod.location`) and of the map's folder, so such a file adds an effect, or replaces the game's file when it has the same path.
* **`fxedit.lua` / the Effects panel (Fields tab)** keeps the **delta** route: numbers of the game's existing blueprints as merge blueprints (`Merge = true`, only the changed fields), which leave the rest of the game's file to the game. Use it for a tweak of a game effect; use the Particle editor for a new effect or when curve keys have to be added or removed (merge files address array entries by index).
* The Effects panel's Fields tab got an **Edit file** button: it opens the selected emitter / beam / trail in the Particle editor and shows the preview. The two routes share nothing else.

## The preview (`src/moho/editor/EdFxView.cpp`)

Upstream's `EdParticlePreview` is compiled as it is (it emits a blueprint into the game's `CWorldParticles`, no sim, no ImGui). The viewport is after upstream's `EdParticleViewport` without `EdImGuiRenderer`: its own orbit camera and render target, the effect far off the map (one of eight spots 3,000 apart, so a restart leaves the old particles to live out), drawn through `moho::gViewportBeforeFrame` (the hook that already exists in `WRenViewport::Render`; ours chains the previous one). The picture is shown in Maui:

1. the render target is copied to a staging texture and read back (`ReadBack`);
2. a `CD3DBatchTexture` subclass (`CPictureTexture`, A8R8G8B8) holds the pixels and writes them into its dynamic sheet in place;
3. `CD3DBatchTexture::FromFile` asks `sDynamicBatchTextureLookup` first (a pointer defined in `CD3DFileBatchTexture.cpp`, null in the game, marked `// EDITOR:`); for `/ed_dyn/fxview` it returns that texture. Any Maui `Bitmap` shows it with `bitmap:SetTexture('/ed_dyn/fxview')`, in a docked panel and in a pop-out alike. Direct3D 11 only, as the rest of the editor.

The view renders only while a panel shows it (the panel's 4 Hz refresh calls `ed_fxv_touch`; the engine stops one second after the last touch). Decorations and a placement test (`ed_fxv_world_set`, `ed_fxv_world_test`) play in the map's view through the same previews.

**Trap (found the hard way): a Maui texture narrower than 1024 never updates.** `CD3DPrimBatcher::SetTexture` packs a texture smaller than half the UI atlas (2048, so 1024) into the atlas once, by address, and never looks at it again; the first picture stayed on screen for ever (`ed_fxv_stats().sheet` was false). A texture of 1024 or more in either direction is drawn from its own sheet every frame, so the picture is 1024 x 640. The texture object is made once and kept (Maui bitmaps hold it), and no static that holds an engine object is destroyed at exit (they are allocated and left).

## Effect decorations

The task text says `MapEditorEffects` is saved in `_save.lua`; upstream does it in two files: the **markers** are in `_save.lua` (type `Effect`, with `effect`, `scale`, `height`; they go through WP3's text-preserving save like every marker), the **function** is in `_script.lua` (`WithScriptEffects`; `map.lua` `SaveAsCore` calls `fxdeco.PatchScript`, one line). With no Effect marker the function and its call are taken out again (byte for byte).

Checked: a map with a decoration saved to a folder (`_save.lua` has the marker, parsed by upstream's `SaveFile`; `_script.lua` has the function and the call), reopened in a new session (`control.LoadMap`; the marker, effect, scale, height and the script are back and the decoration plays again), and a **Play test** of that map: the game log has `map editor: 1 effect decorations` (the function ran in the sim). `selftest_particles.Build` / `Verify` are the two steps.

## Checks

* Upstream's GoogleTests: `faf_editor_brush_tests --gtest_filter='Emitter*:EffectGraph*:NodeGraph*'` with `FAF_RETAIL_EMITTERS` = the extracted retail `effects/emitters`: **18 passed** (2,437 emitters, 103 beams, 184 trails read back; 2,437 emitters through a graph and back).
* `selftest_particles.Run()` (registered in `selftests.extra`): natives, new emitter, every file of the game's file system, own-text writes (flag edit changes one value, curve edit one block, undo restores the bytes), curve key operations and the plot's edit callback (key spread kept through drag / add / delete), beam edit with comments kept, the preview natives, effect templates and the graph round trip, a file written into a mounted folder (read through the game's file system, run as the game's loader runs a blueprint file, found by the browser's list), the script patch, decorations. **PASS**, 68 checks. `selftest_paths` and `selftest_graph` (the other users of `curvewidget.lua`) still pass.
* `python scripts/editor_lint.py`: 0 names missing, 0 dialect errors or warnings.
* An edited curve changes the preview within a frame: `ed_fxv_emitter` is called by every edit (`fxparticle.Apply`); the engine reads the emitter at the next frame's `Frame()`. Screenshots in `img/`: `wp8_preview_before.png` (the nuke blanket smoke playing in the pop-out), `wp8_preview_after_edit.png` (its start-size key set to 15 %: the smoke is gone), `wp8_particle_editor.png` (the editor panel, curves tab), `wp8_particle_preview.png` (the preview window with the latest state).

## Limits and open points

* **No node canvas for effect graphs.** The graph model is bound and tested (`ed_fx_graph_*`: an effect becomes an Effect output fed by Emitter nodes, 21 Curve / Constant pins each, and back, lossless), but there is no canvas panel for it: our `graph.lua` canvas is built for the terrain graph's definitions and was not adapted. The analysis said to ship without it first.
* The browser is a list with a texture swatch, not a grid of tiles with a live thumbnail each; a click plays the effect in the preview.
* The preview plays **one emitter file** (a template of several emitters is opened emitter by emitter; the Effects panel plays a whole template on the map). Beams and trails use upstream's simplified preview (a beam at an angle, a trail behind a point circling).
* Decorations are emitters only (`CreateEmitterAtEntity`); a beam or trail path in the marker is ignored. An effect file inside the map's own folder plays only in games started from FAF's lobby (the blueprint loader reads the map folder from the lobby's pre-game data), as upstream notes.
* **Not run: a game session with a mod project that holds a new emitter file active.** What was checked is that the file is read through the game's file system and evaluates, run as `Blueprints.lua`'s `EmitterBlueprint(bp)` protocol evaluates it, to the written values; the loader's registration was not exercised.
* The exe of this branch has no WP5 natives, so `Map.SaveAs` in the shared checkout's Lua (which calls `ed_adaptive_tables_path`) needed stubs in the test (`selftest_particles.Build` is run with `ed_adaptive_tables_path` defined as a stub; they are not needed once WP5 is merged).
* `ed_fxv_stats().lit` (pixels that differ from the background) counts the ground and the grid too and is not a measure of the effect.
* Direct3D 11 only (the preview reads the target back through the D3D11 immediate context); no other renderer was added.
* The read-back costs a copy and a map of 1024 x 640 x 4 bytes per frame while a panel shows the preview.

## Commands

```
python scripts/ed_fx_audit.py <tag>          # the retail audit (extracts the install's effects.scd, runs selftest_particles.Audit in instance <tag>)
python scripts/editor_inst.py cmd <tag> f.lua  # f.lua:  return import('/lua/editor/selftest_particles.lua').Run()
```

Engine commits on `port/wp8-particles` (c821cac0f, 04cf78e35, 8525ee3b1, 2ca6aecdb): natives and preview glue; the file-preserving writer; the picture from its own sheet; statics that are never freed. Lua commits in the FAF_Studio repository: 1adff4f, e24f74d and the one that adds this file.
