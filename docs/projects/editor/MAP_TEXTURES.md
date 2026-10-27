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

## Pipeline lab: every terrain shader from rough terrain to finished textures (2026-10-27)

`python scripts/pipeline_lab.py --out DIR [--k 2] [--shaders ...] [--shots ...]` (Lua: `editor/textlab/pipeline_run.lua`). For each of the 32 shaders the editor supports (Terrain301 and TerrainPBR are
refused by the profile) it switches the shader, applies a texture set, builds one graph (simplex + billow -> range -> hydraulic erosion -> Oversample k -> Ground kinds in the erosion paint style ->
Output: heights, ground kinds, map normal map, map lighting, roughness / height atlas, macrotexture, specular texture) and decodes what was written: normal map (A = x, R = G = B = z), lighting /
"info" texture (R water depth, G = B occlusion, A shadow), atlas, macro, specular, the paint of the layers. A picture is taken of the listed shaders. The textures a shader does not read come back as a
warning ("not applied") and nothing is written for them.

Result (1025 map, k = 2, 2048 pixel normal and lighting textures): all 32 shaders build in 1.1 - 6 s (the first erosion of a session is the slow one) and write exactly the pictures their class reads:
legacy (TTerrain, TTerrainGlow, TTerrainXP) the macrotexture; ext (TTerrainXPExt, Terrain000, 050) normal, lighting, macrotexture; spec (Terrain001, 051) normal, lighting, specular; pbr and splat (1xx, 2xx, B
included) normal, lighting, atlas. Normal maps have the right channels (R = G = B, A = x spread over 5 .. 250), lighting has water depth, G = B occlusion and a shadow, atlases have heights spread over
44 .. 243. At k = 4 (4096 pixel textures, hydraulic erosion on 4097 x 4097) Terrain202B and Terrain102B build in 15 - 19 s and pass the same checks.

**Found by looking at the pictures:** the macrotexture variants (Terrain1xx / 2xx ending in 1 or 2, Terrain001 / 051) lay the base layer's own texture over the whole map by its alpha; a texture set's
base texture has a specularity in its alpha, so Terrain102B / 202 were one dark olive grass everywhere (rock painted on 56 percent of the map did not show) and Terrain001 washed out. Terrain200, which
has no macrotexture, was fine. `alphagen.FitBase` (below) fixes it and runs when the shader is set, a texture set is applied and the graph writes the map textures.

## Alpha generation (alphagen.lua)

What the shaders read as alpha: Terrain1xx / 2xx do not read the albedo alpha at all (roughness and the heights the 2xx splatting compares come from the Upper atlas; `splatLerp`: the layer with the
higher height wins where two overlap), the x1 / x2 variants and Terrain001 / 051 read the **base layer's alpha as the opacity of a macrotexture**, TTerrainXP and the 0xx read it as specularity, TTerrain as
1 - specularity.

* **Atlas** (`alphagen.Atlas`, used by `maptextures.GenerateAtlas`, falls back to the old luminance atlas without `ed_dds_fields`): per layer a 256 x 256 picture of the texture's detail (luminance) and
  relief (divergence of its normal map: pits low), each normalised to the same contrast (standard deviation 0.16), plus a bias by the kind of ground (rock +0.2 .. wet -0.2, `ROLE_HEIGHT`); the roughness is
  the kind's own (`ROLE_ROUGH`: wet 0.48, snow 0.55, grass 0.74, rock 0.88 ...) moved by the detail. It was one constant roughness (0.65) for every layer before, the heights only the luminance. Written to
  a proxy picture (R height, G roughness, `ed_dds_fields`) per layer and packed into the atlas by `ed_tex_atlas`. 1.7 s for the eight layers. On Terrain202B the difference in the render is subtle
  (the masks are crisp, so few pixels are in a transition); the numbers are the point: rock 0.69, high rock 0.73, snow 0.60, sand 0.50, dirt 0.45, grass 0.38, wet 0.30; roughness 0.50 wet .. 0.86 rock.
* **Base alpha** (`alphagen.FitBase`): a shader with `profile.baseAlpha == 'opacity'` gets a copy of the base albedo with alpha 0 (colours bit for bit, `texconv.Alpha`); a shader without it gets the original
  back. `BaseAlpha(src, opacity)` writes any opacity for a deliberate macrotexture.
* **Specularity alpha** (`alphagen.SpecAlpha(src, role, matte, o)`, `ApplyLayerAlpha(o)`): the alpha of the albedo layers for TTerrainXP / 0xx / TTerrain from the kind of ground (wet 0.85 .. grass 0.18) and the detail. `mode` generate (new alpha), adjust (the texture's own alpha pulled towards the kind of ground by `amount`), off (originals back, `RestoreLayerAlpha`); always from the originals, one undo entry, colours bit for bit. Shaders that ignore the alpha get a message and nothing changes.
* **Graph nodes** (2026-10-27): `Output: texture alpha` (`out_texalpha`: mode, detail, amount, base opacity for the x1 / x2 shaders and Terrain001 / 051) and four settings on `Output: roughness / height atlas` (height contrast, height step between the kinds of ground, relief of the normal map, roughness from the detail). Both run in `graphrun.BuildPaintTextures`. The atlas holds one tile per layer, so it cannot follow the map-wide masks: the transitions are shaped by these settings and the SpecularColor softness / contrast of the shader.
* **Height from the normal map** (2026-10-27): native op `height_from_gradient` (`EdFieldCore.cpp`): the Poisson equation laplace(h) = div(slopes) solved by FFT with the discrete Laplacian's own eigenvalues (any size: radix-2 or Bluestein chirp-z), periodic for tiling textures, else the field is mirrored about its edges. Native test: a smooth height is recovered with 0.27 percent (periodic) / 0.11 percent (mirrored) relative error on 100 x 80 samples. `alphagen` integrates the slopes of each layer's normal map (n = -grad h, the convention of the divergence it used before) and uses that height for the relief in the atlas heights instead of the divergence (which was high-frequency noise: the picture of the G channel now shows the real bumps). The sign is confirmed independently: the integrated height correlates with the texture's luminance (+0.84 RockMed, +0.80 snow, +0.61 RockLight). Falls back to the divergence when the op is missing. `AG.Relief(albedo, normal)` gives lum, divergence and the integrated height for tools.
* Not done: per-pixel alpha (the shaders have no use for it).

Tests: `selftest_alphagen.lua` (26 checks), `selftest_oversample.lua` (20); the pipeline lab runs `out_texalpha` for every shader (`--from-map` starts from the open map's heights, e.g. Operation Citadel).

## Why the selftests failed (2026-10-27)

* `selftest_erosion`, golden checksums: the fixtures are 65 x 65 = 4225 samples, above the 4000 samples from which the editor runs the **GPU** solver; the goldens are CPU checksums (and shared with the native
  test). The cases now pass `cpu_only = 1`; the GPU result is not bit identical by design.
* `selftest_recipes`, `selftest_kinds` ("the graph paints what the recipe paints"): on a 1025 map `Recipes.Stats()` read 257 x 257 = 66049 height samples in one `ed_field_read`, which gives 65536 at
  most, failed silently and fell back to a made up range 0 .. 100: **the recipes of every 20 km map worked from wrong height percentiles** (snow 0.5 percent of the map instead of 10). Stats() now takes at most 255
  samples a side. Fixed in `recipes.lua`.
* `selftest_kinds`, "Landforms: about the share of hills": the `landform` node used `0.5 - 0.16 * Z(coverage)` where Z is the distance above the middle that a share lies above, so the hills covered
  `1 - coverage` (0.58 for 0.4; the shipped Valley graph asked for 0.35 and got 65 percent). Sign fixed.
* All three passed on the default 256 map by luck of the seed; the earlier claim that they "fail the same way on the previous exe" was wrong: that run used the same exe (`--exe main_x64_la_p2.exe` is
  the current build) and only the Lua differed.

## Not done / open (engine side)

* The uncompressed A8R8G8B8 the community tools use for the info texture (DXT5 smears the RGB channels a little) is not offered by `ed_dds_fields` yet; `EncodeDxt5` is the only encoder.
* The roughness mask of layer 8 and the paint layers stay at their own (coarser) mask grid: oversampling makes them crisper by averaging, it cannot give them more pixels.
* PNG export of RGBA is done in Lua (`png.lua`, slow, limited to 1024 x 1024); a WIC based `ed_png_write(path, w, h, rgba)` in EdImageIO.cpp would do it natively.
* No live (file-less) upload of a texture into a layer slot: every change writes a file. A native `ed_stratum_set_pixels(layer, w, h, rgba)` (a dynamic D3D texture like the masks of EdStrata.cpp) would allow slider-driven previews.
* The shadow does not apply the community's "water rule" (hide terrain shadows seen through water) and ignores props and units.
