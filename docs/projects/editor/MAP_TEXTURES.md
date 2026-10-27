# Map-wide shader textures (normal map, baked lighting, specular, macrotexture)

Code: `editor/runtime/lua/editor/maptextures.lua` (model), `graphnodes_map.lua` (graph nodes), `gui/panels_maptextures.lua` (panel), native op `normal_map` (`EdFieldFilt.cpp`),
self test `selftest_maptextures.lua`. Background: `docs/projects/editor_research/BAKED_LIGHTING.md`, `effects/terrain.fx` (the layout tables above each shader family).

## What the engine has

The engine has no slot for these textures of its own. The newer FAF terrain shaders read them from texture layers that they do not use as layers (verified in `terrain.fx`):

| Shader | Normal map (x, z) | Lighting texture | Other |
|---|---|---|---|
| TTerrainXPExt, Terrain000, Terrain050 | normal map of layer 8 (A = x, R = G = B = z) | albedo of layer 8 (R water depth, G = B ambient occlusion, A sun 1 / shadow 0) | Upper albedo: macrotexture RGB + opacity A |
| Terrain001, Terrain051 | as above | as above (A is read without a size check) | Upper albedo: specular RGB + sharpness A |
| Terrain1xx, Terrain2xx (incl. B) | as above | as above (the B shaders also read R as water depth) | Upper layer is a tiled roughness / height atlas, not map-wide |
| Terrain301 | in the lighting texture | Upper albedo: R x, G z, B water depth, A shadow | |
| TTerrain, TTerrainXP, TTerrainGlow | not used | not used | |

* The shaders only use the layer 8 normal map / albedo as map-wide data when the layer's tile value is below 1 (`UseMapNormalFromTexture`, `ShaderUsesTerrainInfoTexture`): the tile size
  must be bigger than the map in ogrids. The editor writes map size + 1.
* A map normal map replaces the normals the engine computes from the heights (`CWldTerrainRes::UpdateNormalMap`: `GetNormal = (left - right, 1, top - bottom)` normalised, bytes
  `int((n + 1) * 128)`). After sculpting it is out of date. **Clear** gives the engine's normals back; the panel shows "out of date" for textures made from the terrain.
* The shadow channel A is multiplied into the sun term only; the surface angle (N.L) is applied by the shader from the normal map. So the lighting texture holds cast shadow, not N.L.

Engine access: `ed_stratum_layer(i)` / `ed_stratum_set_layer(i, path, tile)` (EdStrata.cpp), index 0..9 albedo (Base, layers 1-8, Upper), 10..19 normal. Layer 8 albedo = 8, layer 8 normal =
18, Upper albedo = 9. The engine loads the texture from a file by path (and caches by path), so a texture made here is a DXT5 DDS with mip maps and a fresh file name every time.

## What the editor does

* Files: `maptex_<kind>_<n>.dds` in a staging folder (`../maptex`, mounted at `/edmaptex`). **Saving** (`map.lua` `SaveAsCore` -> `maptextures.PrepareSave`) copies the files the layers use into
  `<map folder>/env/layers`, points the layers there and deletes unused `maptex_*` files of that folder. An autosave only borrows the paths for the file it writes.
* Graph: `Height to normal map` (rgba + x, y, z masks), `Environment lighting` (sun direction, multiplier, sun / ambient / fill colours as numbers), `Lighting texture` (shadow with
  soft edges from sampling the sun disc, shaded relief, ambient occlusion), `Output: map normal map`, `Output: map lighting`. Build writes both outputs as part of the one undo step. A shader that does not read the texture (TTerrainXP and the other legacy shaders) is no failure: Build skips that output while its **Use it on the map** is on, builds the other outputs, and reports one warning sentence (`maptextures.lua Unsupported`; status line in the warning colour with a **Switch shader...** button, the Console, the output node's inspector note before building). With Use it on the map off only the DDS file is written, whatever the shader. Failures of Build come back as plain messages (`Fields.CleanError`: no `file(line):` prefixes, no traceback); the traceback of an unexpected error is logged once with SPEW.
  "Use it on the map" off writes only the file (next to the map when it has a folder).
* Panel `Map textures` (Terrain workspace, next to Layers): per texture a picture (click = import), Generate, Import..., Export... (DDS copy, PNG), Clear, the shader's slot and channel layout.

## Oversample: map-wide textures at a multiple of the map's resolution (2026-10-27)

The terrain graph works on one grid, the map's (or a coarser preview of it). The **Oversample** node (`graphnodes_oversample.lua`, category Erosion) puts a height on a grid `factor` times finer
((w - 1) * factor + 1 samples, first and last sample kept; Catmull-Rom, so the slopes are smooth and the normals of the fine grid are not blocky). Everything after it runs at the fine grid.

* **Erosion rerun.** Wired straight after an erosion node (Hydraulic, Droplet, Stream power) with *Run the erosion again* on, it runs that erosion again on the fine grid, from the erosion node's own
  inputs and settings, and outputs `out`, `wear`, `deposit`, `flow`, `accum` at the fine grid. The settings are scaled to the finer cell (`erosion.lua OpParams`, step < 1: hydraulic gets
  `1 / step` times the iterations with the rain, erosion and deposition rates times `step`; droplet lifetime, radius, slide steps, creep times `1 / step`, droplets per cell times `step`) and the
  seed is the erosion node's own. Without the rerun (or after another node) only `out` is made, the masks say why they have no value.
* **Grid handling** (`graphrun.lua Run:Conform`). A node works on the finest grid among its inputs; the others are converted (`upsample` for what is coarser, a tent filter `downsample` for what is
  finer), `E.like` / `E.cell` / `E.step` follow it, so a node placed after the Oversample node (also an erosion node: its settings scale by `E.step`) runs at the fine grid on its own. The outputs
  that write into the map's grids (heights, paint layers, ground kinds, terrain types, scatter, roughness mask) get their inputs averaged down to the run's grid again: that is what makes oversampled
  masks crisp instead of aliased. Only the map-wide textures (`def.fineOk`: Output: map normal map, Output: map lighting) keep the fine grid. Output: map lighting has an optional `height` input
  for the water depth channel (the shoreline then has the fine detail too).
* **Texture size.** `Texture size` of the map textures now offers 4096, 8192 and *As fine as the finest input* (= the fine grid: one pixel per sample, so 4x on a 1025 map is 4096). The DDS is written
  by the native `ed_dds_fields(path, size, span, r, g, b, a[, mips])`: it reads the fields directly at the texel centres, encodes DXT5 with mip maps on all cores, no Lua tables (the old path needed
  about 250 MB for 2048 and was capped there; `MaxTextureSize()` is 8192 with the native writer, 2048 without).
* **Native ops** (EdFieldCore.cpp): `upsample` (a, factor | like, linear), `downsample` (a, like); the cap of a field is now 128 M samples (was 16 M).

Measured on the 1025 map (editor_blank_1024, Terrain202B, graph: simplex + billow -> range -> hydraulic erosion 60 iterations -> Oversample -> normal map, lighting texture with AO, roughness mask
from `wear`, height output; RX 7900 XTX): build 0.5 s at 1x, 2.2 s at 2x (2048 textures), 7.5 s at 4x (4096 textures, 22 MB each; 6.2 s of that is the erosion at 4097 x 4097). Crops of the same
ground side by side (normal x, AO channel of the lighting texture): at 1x the maps are blocky, at 2x the gullies are there, at 4x every ridge and channel the erosion cut is resolved, the AO
follows the channels. `selftest_oversample.lua` (20 checks) covers the ops, the writer, the grid handling and the erosion rerun.

## Not done / open (engine side)

* The uncompressed A8R8G8B8 the community tools use for the info texture (DXT5 smears the RGB channels a little) is not offered by `ed_dds_fields` yet; `EncodeDxt5` is the only encoder.
* The roughness mask of layer 8 and the paint layers stay at their own (coarser) mask grid: oversampling makes them crisper by averaging, it cannot give them more pixels.
* PNG export of RGBA is done in Lua (`png.lua`, slow, limited to 1024 x 1024); a WIC based `ed_png_write(path, w, h, rgba)` in EdImageIO.cpp would do it natively.
* No live (file-less) upload of a texture into a layer slot: every change writes a file. A native `ed_stratum_set_pixels(layer, w, h, rgba)` (a dynamic D3D texture like the masks of EdStrata.cpp) would allow slider-driven previews.
* The shadow does not apply the community's "water rule" (hide terrain shadows seen through water) and ignores props and units.
