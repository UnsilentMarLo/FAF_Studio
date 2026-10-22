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
  soft edges from sampling the sun disc, shaded relief, ambient occlusion), `Output: map normal map`, `Output: map lighting`. Build writes both outputs as part of the one undo step.
  "Use it on the map" off writes only the file (next to the map when it has a folder).
* Panel `Map textures` (Terrain workspace, next to Layers): per texture a picture (click = import), Generate, Import..., Export... (DDS copy, PNG), Clear, the shader's slot and channel layout.

## Not done / open (engine side)

* Memory and speed: the DDS is written from a Lua table of 4 numbers per texel (`ed_dds_write`), so 2048 x 2048 needs about 250 MB while it is written. A native `ed_field_dds(path, w, h, r, g, b, a, mips)` that reads the fields
  directly (EdField.cpp + an exported encoder from EdIcon.cpp) would remove that, and could write the uncompressed A8R8G8B8 the community tools use for the info texture (DXT5 smears the RGB channels a little).
* PNG export of RGBA is done in Lua (`png.lua`, slow, limited to 1024 x 1024); a WIC based `ed_png_write(path, w, h, rgba)` in EdImageIO.cpp would do it natively.
* No live (file-less) upload of a texture into a layer slot: every change writes a file. A native `ed_stratum_set_pixels(layer, w, h, rgba)` (a dynamic D3D texture like the masks of EdStrata.cpp) would allow slider-driven previews.
* The shadow does not apply the community's "water rule" (hide terrain shadows seen through water) and ignores props and units.
