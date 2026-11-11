# WP10: Material editor, a colour texture graph for stratum albedo and normal maps (2026-11-11)

Work package 10 (optional) of `EDITOR_PORT_ANALYSIS.md` (section 14). Engine: branch `port/wp10-material` of faf-re (worktree `C:\Users\Marlo\Documents\GitHub\faf-re-port-wp10`, on top of `port/wp8-particles`). Lua, selftest and this file: the FAF_Studio repository (`material.lua`, `gui/panels_material.lua`, `selftest_material.lua`, one function in `strata.lua`). Nothing is pushed.

## What it does

A **texture graph** makes the pictures of a terrain layer: nodes that make images (noise, cells, gradients, a texture of the game, the open map's height, steepness and painted layers), combine them (maths, lerp, blends, height blend), adjust them (levels, gradient map, blur, transform, warp), make normal maps (height to normal, normal blend) and split or merge channels, all into one **Output** node with three inputs: `Albedo`, `Normal`, `Mask`. Everything a pattern makes tiles (noise and cells wrap at the picture's edge, blurs and normals read across it), because a layer's texture repeats over the ground. Spatial parameters are in the picture's own units, so a 64 preview and a 4096 bake look alike.

Three panels (the Window menu lists them under More, and they sit as tabs in the Generate workspace):

* **Material graph** (`material`): the canvas. Nodes show a thumbnail of their output, pin dots show the type (grey picture, colour picture). Drag a node to move it; drag from a pin to another pin to link (a linked input dragged away is taken off; a link that would close a loop is refused); right click a node or pin for its menu; **Add node** (or a right click on the background) lists the palette by category and puts the node right of the selected one, linked to it when it can take its output. Pan with the middle or right button or by dragging the background. New, Open (the saved graphs), Save (name field), Undo, Redo, Delete, Fit.
* **Material node** (`materialnode`): the selected node: what it does (upstream's help text), its warning ("No map open", a texture that did not load), its parameters as sliders (field, slider, minus / plus), switches, choice menus, colours (swatch and four sliders), texture paths (field plus a menu of the open map's layer textures).
* **Material output** (`materialout`): the result as Albedo, Normal, Mask, a lit sphere, a lit 2 x 2 plane (a seam shows at the middle lines), or the selected node; the preview size (64 to 512); and **Apply to layer**: the layer (0 base, 1 to 8), the bake size (256 to 4096), the tile size (0 keeps the layer's own, 10 when it has none), whether to paint the layer's mask from `Mask`, and a **Refresh map data** button.

## Logic: upstream's, bound as natives

Upstream's `TextureGraph` (`src/editor/graph/EdTextureGraph`, `EdNodeGraph`, in `faf_editor_logic` since WP1; nothing of it is edited) and its DDS encoder `EdTextureBake.cpp` (DirectXTex and the engine's image codec, so it cannot be in the library: it is compiled into the executable, listed in `editor_sources.cmake`). The binding is one unit over the WP1 scaffold, `src/moho/editor/EdUpTexGraphLua.cpp`:

| native | does |
|---|---|
| `ed_tex_types()` | the 35 node types: pins (grey / colour), parameters (float, int, bool, colour, choice, text) with ranges, help |
| `ed_tex_new / _free / _graph / _add / _remove / _move / _set_param / _link / _unlink` | a graph as a handle (the `NodeGraph` and its caching `TextureGraphEvaluator` live in the engine, Lua holds the snapshot `ed_tex_graph` returns); links answer `ok / bad pin / same node / cycle / wrong type` |
| `ed_tex_save / _load` | the graph file (JSON, upstream's format); a refused file leaves the graph as it was |
| `ed_tex_size / _terrain / _eval / _info` | the preview size (8 to 4096), the open map's heights and stratum masks for the Map nodes, evaluation (only what changed: a slider re-runs the nodes downstream of it), a node's warning and time |
| `ed_tex_image / _result / _lit` | a node's output, the Output's pin, or the lit sphere / plane, as an uncompressed DDS the panels show in a Maui Bitmap |
| `ed_tex_bake_start / _poll / _cancel / _free / _mask` | the bake as a polled job (below) |
| `ed_tex_dds_info(path)` | what a written file is, decoded by the engine's own codec (the tests read files back with it) |

### The bake is a job

`ed_tex_bake_start(id, { size, albedo = path, normal = path })` copies the graph, reads the textures the graph names on the Lua thread (the worker never touches the game's files), and runs on a `JobSet` worker (`EdUpCommon.h`): evaluates at the bake size, writes Albedo as BC3 and Normal as BC1 with a full mip chain (upstream's `EncodeDds`) and keeps the Mask. `ed_tex_bake_poll` says progress and result; Lua applies the files when the job is done. Measured: the start graph (4 nodes) bakes at 1024 in 236 ms including both DDS files; the UI never waits for it. Larger sizes and bigger graphs were not timed.

### The lit preview

`ed_tex_lit` is upstream's `RenderMaterialPreview` (its source is in the ImGui `EdMaterialEditor.cpp`, which the Studio executable does not compile): the function is copied into the binding with a note, the maths unchanged.

## Connecting it to the strata flow

`material.lua` `Apply`:

1. the files are named `maptex_mata_<n>.dds` (albedo) and `maptex_matn_<n>.dds` (normal) in the Map textures staging folder (`../maptex`, mounted at `/edmaptex`, `maptextures.lua`). That is the naming `maptextures.Managed` recognises, so **a map save copies them into `<map>/env/layers` and points the layer there** (`PrepareSave`, unchanged) and removes unused ones. A fresh name every time, because the engine keeps textures by path. `maptextures.Prune` only deletes files `maptextures` made itself, so it never touches these;
2. the bake runs as a job; when it is done `Strata.SetTexture(layer, albedo, normal, tile)` sets them (the engine loads the DDS from the mounted folder, same as for a texture picked in the browser). A graph without a linked Normal gives the layer the neutral normal map;
3. with **Paint the layer's mask** the `Mask` output is resampled to the **map's mask grid** (`ed_stratum_info`: the mask follows the map, whatever its size, see `MAP_TEXTURES.md`; the bake size has nothing to do with it) and written tile by tile through `Strata.EditMask`, which is the existing `MaskEdit` (deferred upload, the packed undo delta) behind a new exported name. One function added to `strata.lua`;
4. one undo entry (`History`) undoes textures and paint together. A layer that had no texture gets the transparent one back (`Strata.Restore` alone would leave the new texture: found by the selftest).

## Results

* **Upstream's tests, against the same sources the executable links** (`faf_editor_brush_tests` links `faf_editor_logic`, the library the binding calls; `faf_editor_bake_tests` links `faf_engine`, which now holds `EdTextureBake.cpp` and the binding unit): `--gtest_filter='TextureGraph*:NodeGraph*'` **13 passed** (tiling across the seam, only what changed is computed again, the result at the graph's size in the pin's type, a preview and a bake look the same, a flat height gives a flat normal, the texture loader and a missing texture's warning, Map Height / Slope / Mask read the terrain, every node type computes) and `faf_editor_bake_tests` **4 passed** (uncompressed reads back exactly with its mips, BC3 and BC1 stay close, grey is written as grey RGB). One change to a shared build file: the bake test target no longer compiles `EdTextureBake.cpp` itself when `FAF_EDITOR` is on (the executable's library holds it: a duplicate `EncodeDds` at link time).
* **`selftest_material.Run()`: PASS, 60 checks**, run twice in one session and after a restart (registered in `selftests.extra`). It covers: the natives and the palette (35 types in 10 categories); a new graph is upstream's start graph and evaluates its 4 nodes, then 0 (cache); edits and undo (the graph file is the same after an undo; three slider edits are one step); a loop is refused; pictures are DDS files the engine's own decoder reads (32 x 32, 6 mips), cached while the node does not change and new when it does; the lit sphere; Save, the list of saved graphs, Open (the same graph file); a broken file is refused and leaves the graph; the Map nodes see the open map (no warning) and make new pictures after a new read of the map; a bake job at 128 writes a BC3 albedo (128 x 128, 8 mips, size of a BC3 file) and a BC1 normal map, which the engine decodes; a started job can be cancelled; **Apply** sets layer 7's albedo and normal map to the staged files with the tile size asked for, the file is managed, the engine reads the 256 x 256 file the layer points to, the mask is painted over the map's grid (128 x 128 cells, values spread over the range), **one Undo** brings back texture, tile size and mask, Redo applies again; a map save copies the files into the map folder and the layer points there; the mask grid changed to 256 x 256 is painted over all its cells and the old size comes back; a graph with no Albedo is refused with a message.
* **In the running editor** (`python scripts/editor_inst.py new / start wp10 --exe main_ed_wp10_x64.exe`, real mouse input with `scripts/ed_input.py`): the graph panel draws the start graph with thumbnails; a click selects a node and the node panel shows its parameters; a drag from the noise's output to `Mask` links; the Scale slider changes the thumbnails and the preview at once; Add node lists the categories and their types; **Apply to layer 1 at 1024 with a mask**: the layer's albedo and normal map are `maptex_mata_13.dds` / `maptex_matn_14.dds`, the Layers panel shows both pictures, and the terrain shows the texture painted in blotches over the olive base. Screenshots in `img/`: `wp10_graph_panels.png` (graph, node panel and the mask preview after the link and the slider), `wp10_sphere_preview.png` (the lit sphere), `wp10_map_nodes.png` (a Map Height node showing a hill raised on the flat test map), `wp10_applied_layer.png` (the terrain after Apply).
* `python scripts/editor_lint.py`: 0 names missing, 0 dialect errors or warnings. Tooltips: all 42 widgets of the panels as they are built have one (tipcheck; the node panel builds its controls for the selected node, so it was checked with none selected). Layout check: 0 problems in all three panels (`layoutcheck.Panel`; the same caveat for the node panel). `selftest_uilayout` passes.

## Decisions, and what was not reused

* **The canvas is its own, not the terrain graph's.** `panels_graph.lua` is built around the terrain graph's singletons (`Graph`, `Nodes`, `GRun`, its model with field ports, zoom, frames, symmetry, a seed, a mask view on the terrain); to take another model it would have to be refactored in a file other sessions edit, with a nightly that depends on it. `panels_material.lua` copies what is proven there (the wire pool and its elbow routes, the drag helpers, the Dragger usage, the context menu pattern) and leaves out what a texture graph does not need (zoom, frames, box select). It clips with `Control:SetClipChildren` (as the dock does), so it needs no manual cutting of nodes at the edge. A later merge of the two canvases would be a refactor of `panels_graph.lua`, not part of this work package.
* **The graph lives in the engine, Lua holds snapshots.** Upstream's evaluator caches per node by revision; keeping the `NodeGraph` there makes every edit one native call, and the snapshot is asked once per tick or after an edit (`material.lua` `Snap`). Undo is the graph file as text (`ed_tex_save` / `_load`): small, exact, and the evaluator recomputes what the load changed.
* **No separate `graphnodes_tex.lua`.** The node definitions are upstream's, read from the natives (`ed_tex_types`), so a node type upstream adds appears without a Lua edit.
* **Files:** graphs are `materials/<name>.fafgraph.json` in the editor's working folder (upstream's own extension and format, so a graph saved in the upstream editor opens here). The list of them is read by mounting the folder (the same idiom as `graph.lua`).

## Limits (stated plainly)

* **No live update on the terrain while editing.** Upstream's material editor pushes the preview into the slot continuously ("Live Update"); here the pictures show in the panels and the terrain changes on **Apply** only (a bake at the bake size; 236 ms at 1024 for the start graph). Not built because every live update would need a fresh DDS file and a new layer texture per change (the engine keeps textures by path) and a way to put the layer back; Apply is the same path without the churn.
* **The upper layer (9) is not offered.** Albedo of the upper layer carries a macrotexture / specular (shader dependent, `MAP_TEXTURES.md`) and has no mask; the graph's albedo would have to be made for that meaning. Layers 0 to 8 are offered. Layer 0 has no mask, so `Paint the mask` is ignored for it with a message (the textures are applied).
* **Map nodes read the map as it was when the graph last read it.** The heights are read again when the terrain document's revision moves (a brush stroke, undo, import); a layer mask painted since is not noticed: press **Refresh map data**. `ed_terrain_raise` (a test helper that writes the height field without a document revision) does not move the revision either; real brushes do.
* **One selected node, no multi-select, no copy / paste, no duplicate, no zoom, no frames.** Delete removes the selected node (the Output stays); Undo undoes the last edit. Nodes cannot be renamed.
* **Texture nodes read at most 1024 pixels across** (upstream's loader: a graph's input needs no more); a texture that does not load gives a warning on the node and a grey. A bake at 4096 with a 1024 texture node resamples it.
* **The preview is a CPU evaluation** (upstream's design: one image per node, the cores of the machine). At 512 a graph with many noise nodes takes tens of milliseconds per change; the preview size slider is the answer.
* **Thumbnails and previews are files** (`../mattmp`, a new one per version, the old one deleted), shown through the mounted folder: the same way the terrain graph shows its thumbnails. They are not a live texture of the engine (WP8's `/ed_dyn/` route would need a native Bitmap per picture and was not needed).
* **Bake sizes:** 256 to 4096, square only (the graph's images are square). A map-sized layer that is not square is not a case here (layers repeat).
* **Not run:** a Play test of a map saved with a baked layer (the files are copied into the map folder and the layer points there, checked in the selftest by decoding the copy; the lobby's loading of that folder was not exercised); the whole nightly (`editor_nightly.py`: only this package's checks were run); the Studio's other graphs and panels are untouched (`panels_graph.lua` is not edited). `FAF_EDITOR=OFF` still does not link (the pre-existing issue of WP1's hand-over: the new unit is under `FAF_EDITOR` like the other binding units).
* **Test exe:** `engine/run/bin/main_ed_wp10_x64.exe` (instance tag `wp10`; built from `port/wp10-material`, which has no WP5 natives, so `Map.SaveAs` in the shared Lua would need `ed_adaptive_tables_path` stubs as the WP8 note says; the selftest does not call it).

## Traps found

* **`Strata.Restore` ignores a layer that had no texture** (`if snap.albedo == '' then return end`): undo of an Apply on an empty layer left the new texture while the mask went back. `material.lua` puts the transparent texture back (`Strata.Clear`) in that case; the plain `Restore` is unchanged.
* **A picture cache keyed by the node's revision is stale for the Map nodes**: their data (the terrain) is not part of the revision. The pictures carry an epoch that moves with every new read of the map.
* **`ed_tex_load` checks the file before it clears the graph**, so a broken file cannot destroy the open graph: the tests pin that.
* **A module changed on disk is not reloaded by the running editor** (`import` is cached): restart the instance (`editor_inst.py stop / start`) before re-running a changed selftest. The command channel (`editor_inst.py cmd`) cut one long answer in the middle of a line; the answer is complete in `.runs/<tag>/edcmd.lua.out`.
* **A baked file is written by the worker thread with `std::ofstream`**, so the folder above it must exist (`EnsureStage`, and the binding creates parent folders like `ed_write_file`).

## Commands

```
python scripts/editor_inst.py new wp10 ; python scripts/editor_inst.py start wp10 --exe main_ed_wp10_x64.exe
python scripts/editor_inst.py cmd wp10 f.lua      # f.lua:  return import('/lua/editor/selftest_material.lua').Run()
python scripts/editor_lint.py
build/ed-on/tests/faf_editor_brush_tests.exe --gtest_filter='TextureGraph*:NodeGraph*'      # in the engine worktree
build/ed-on/tests/faf_editor_bake_tests.exe
```

Engine commits on `port/wp10-material` (ff726e2d4, b2e1b1b03, 67208788d): the binding, the folder fix and the bake-test link, the mask read. Lua commits in the FAF_Studio repository: ddac082, 2472ead, 913f283, f762072, ba93bcd and the one that adds this file.
