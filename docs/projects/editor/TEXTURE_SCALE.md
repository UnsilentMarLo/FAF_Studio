# Tile size of terrain texture layers

Code: `editor/runtime/lua/editor/texscale.lua` (the maths), `texsets.lua` (texture sets and roles), `strata.lua SetTexture`, `gui/panels_strata.lua` (Optimal button, density line),
`scripts/ed_make_blank_map.py` (template), self test `selftest_texscale.lua`.

## Where the old defaults came from

A layer's tile size is the engine's `CStratumMaterial::mSize` (world units one texture repeat covers). There was no single "8"; the defaults were scattered:

| Where | Value | Effect |
|---|---|---|
| Engine slot defaults (`StratumMaterial.cpp`) and the blank map templates (`ed_make_blank_map.py`, `scmap.py`: `("", 4.0)`) | 4 (Upper 128) | an empty layer reports size 4 |
| `Strata.Clear`, `Strata.Info` fallback, `envlib.lua` (`l.size or 4`) | 4 | a cleared layer / look without size |
| Layers panel picker (`P:Change`), asset browser "use texture" (`assetcat.lua`) | the old layer's size | a texture given to an EMPTY layer got its leftover 4 |
| `texsets.lua` Apply / ApplyRole | theme `size` 12 or 14, base twice that, Upper 128 | the same size for textures of any resolution |

Mapmakers use 18 - 24 for 1024 px textures; 4 repeats a texture every 4 units (visible mosaic), 12 - 14 is right only for about 512 px.

## The maths

A tile of `T` world units shows a texture `R` pixels wide at `R / T` texels per world unit. On screen the closest normal view shows `p` pixels per world unit, so the texture stays sharp
while `R / T >= p`. A larger `T` repeats less (less visible tiling), so the best tile is the largest sharp one:

    T = R / p        p = H / (2 D tan(f / 2))

Reference view (stated assumption, constants in `texscale.lua`): `H` = 1080 px screen height, vertical field of view `f` = 45 degrees, eye distance `D` = 27 world units (near end of the
game camera's zoom range; a pitched camera is farther from most of the ground, so this is the sharpest case). `p` = 1080 / (2 * 27 * 0.4142) = **48.3 texels per unit**.
Rounded to steps of 0.5 and clamped to [4, 64]:

| Texture width | 128 | 256 | 512 | 1024 | 2048 | 4096 |
|---|---|---|---|---|---|---|
| Tile size | 20 (density asks 2.7) | 20 (5.5) | 20 (10.5) | 21 | 42.5 | 64 (clamped from 85) |

**Update:** the density alone gave 512 px textures 10.5, and the user saw the texture pattern repeat as a regular grain over the recipe-painted map. A repetition floor `REPEAT_MIN` = 20 world units now lifts every smaller result (a bit blurrier at the closest zoom is better than a visible grid). Old note, kept for the numbers: most Evergreen layer albedos are 512 px (count by file size in `_asset_index/scd/env.scd.tsv`), so they get about 10.5, not 18 - 24. If the wanted look is "texels a bit blurry at the
closest zoom", raise `REF_DISTANCE` (54 gives 24 texels per unit, 512 px -> 21): only that constant changes.

* The width is read with `ed_dds_thumb(src, scratch, 4)` (decodes the DDS from a file or a game archive and returns its size; ed_img_info goes through WIC, which reads neither DDS nor archives),
  cached per path. A texture that cannot be read gets the caller's fallback (the theme's `size`), else a 1024 px texture is assumed.
* The normal map gets the same tile size as its albedo (the two use the same UVs; different sizes make the bumps drift off their colours).

## Repetition and the Upper layer

Two overlays whose tile sizes have a simple ratio line their patterns up every few tiles. The golden ratio phi is the number worst approximated by fractions, so `phi^k` ratios (k = 2 .. 5:
2.618, 4.236, 6.854, 11.09) stay at least 0.09 away from a whole number (`phi^6` = 17.94 and `phi^7` = 29.03 do not: they approach the Lucas numbers). `texscale.Decorrelate(size, k)` gives
`size * phi^k`; `MacroTile(base)` picks k in 2 .. 5 so that the Upper layer's tile is nearest 128 (the engine default for that slot), 32 .. 256, and not a whole multiple of the base tile
(base 21 -> 144, base 24 -> 101.5, base 42.5 -> 111.5). The Upper layer (macrotexture) is the only place it is used: a low frequency colour overlay that has no matching normal map and
needs no alignment; albedo / normal pairs are never decorrelated. The old fixed 128 was 5.33 times a 24 base (16 : 3, repeats every 3 macro tiles). `Strata.Normalize` recognises the template's opaque
Upper layer by the size 40 and a dirt texture; the template keeps that, and `ApplyIfNew` replaces the layer with the macrotexture afterwards.

## Where Optimal is used

* `texsets.Apply` / `ApplyRole` (and so the mask generator, the graph outputs and a new map via `ApplyIfNew`): per texture; theme `size` only as fallback; base layer = Optimal (the old
  "twice the painted size" halved its sharpness); Upper = `MacroTile(base tile)` (only where the shader treats the Upper layer as an overlay, as before).
* `Strata.SetTexture(i, albedo, normal, nil, nil)` takes Optimal of the albedo; `envlib.ApplyTheme` for a look layer without a size.
* Layers panel: `P:Change` and the asset browser use `texscale.Carry`: an empty layer or a size that is still a default (4, 1 or the Optimal size of the old texture) takes Optimal of the
  new texture; a size the user tuned is kept. The **Optimal** button sets albedo and normal tile size in one undo step. The line under the sliders shows `texels per unit (px), optimal T`.
  The sliders already span 1 .. 256.
* `ed_make_blank_map.py` writes the template's base layer with the same formula (`optimal_tile(512)` = 10.5). The shipped templates are generated files: run `studio.py generate` to refresh
  them; until then a new map gets its sizes from `ApplyIfNew` (the base layer is replaced by `Apply`).
* Not changed: restoring existing sizes (undo, Move, Convert layers, resize), map-wide data layers 8 / Upper (tile size above the map size), `Strata.Clear` and the `Info` fallback (4 stays the
  value of "no texture yet", which `IsDefault` recognises).
