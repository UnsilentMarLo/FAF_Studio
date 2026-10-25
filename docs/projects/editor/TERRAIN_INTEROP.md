# Terrain interop: Gaea, World Machine, Blender, Photoshop, QGIS

FAF Studio exchanges terrain with other tools through images. **Terrain > Import heightmap...** (and Import masks, Export for external tools, Live link) opens the **Interop** panel (a tab beside the console in the Terrain workspace). Design and engine details: [TERRAIN_GEN_DESIGN.md](TERRAIN_GEN_DESIGN.md) section 13.

## Numbers to know

| Map size | Cells N | Samples N + 1 | Image that matches exactly |
|---|---|---|---|
| 5 km | 256 | 257 x 257 | 257 (corner aligned) or 256 (cell aligned) |
| 10 km | 512 | 513 x 513 | 513 or 512 |
| 20 km | 1024 | 1025 x 1025 | 1025 or 1024 (2048 is filtered down) |

* 1 sample = 1 world unit = 1 / 51.2 km. The README an export writes (`<name>_README_scale.txt`) has the numbers of your map.
* Heights are 16-bit words, 1 / 128 unit steps: 0 to **511.99** units. Decals are not drawn above 250 units (the editor warns). Good gameplay terrain stays below about 100 - 150 units.
* An image of exactly N + 1 pixels has a pixel on every sample ("corner": exact, identity). An image of N pixels (or any other size) covers the N cells, pixel centres on the cell centres ("cell"). Leave **Align: auto** and the editor picks one; force one when you know better.

## Formats

Import: PNG (8 / 16 bit), TIFF (8 / 16 bit, **32-bit float**), BMP, JPEG (lossy: avoid), raw `.r16` / `.raw` (16 bit, little or big endian: set **Big endian**) and `.r32` (float). Raw files are square (size from the file length) or give width and height. **EXR is not supported** (Windows has no EXR codec): export a 32-bit float TIFF instead. A GeoTIFF with no-data cells (QGIS) is fine: those cells become the lowest valid height.
Export: PNG 16, TIFF 16, TIFF 32 float, raw `.r16` / `.r32`; masks PNG / TIFF 8 or 16 bit.

## Mapping an image to heights

* **Normalised 0..1** (what Gaea and World Machine export): the image's 0 becomes *Image 0 = height* (default 0), its 1 becomes *Image 1 = height*. Set the second slider to the height you want the highest possible value to have. *Stretch to image range* first stretches the image's own lowest..highest value to 0..1 (an export that does not use the whole range). *Invert* flips it.
* **Absolute**: 16-bit value / 128 = units (the same as the editor's own heightmap file); a float image holds units directly.
* **Sea level in image**: the image value you name is put on the map's water surface, so the coast of a Gaea island lands on the editor's water level whatever the height range is.
* The panel shows the resulting range (*result heights lo to hi*) and a thumbnail before anything is written, and warns about heights above 250 / above 511.99 / below 0, about 8-bit images (terraces) and float images outside 0..1.

## Placing it

*Region*: the whole map, the playable area, or a rectangle (sliders in samples). *Blend*: replace, add, max, min, or *by mask* (a second image over the same region: white takes the import). *Strength* and *Feather* (units) soften the border of a partial region (the map's own border is never feathered). *Pads*: **keep** protects the terrain around start positions (radius slider) and mass / hydrocarbon points (40 % of it); **flatten** takes the new terrain and levels it there. *Rotate* (0 / 90 / 180 / 270) and *Flip X / Z* turn an image that came out sideways. **Apply** is ONE undo step; **Undo** takes it back.

## Gaea workflow

1. In the editor: **Terrain > Export for external tools**, pick a folder, *Export* (heightmap + json, masks, start positions, README). The README names the sample grid (for example 1025 x 1025).
2. In Gaea: set the build resolution to 1025 (1024 / 2048 work too; 1025 is exact when your version offers it), build your terrain. Use the exported `*_height` file as an Image / Terrain input when you want to start from the map, and `*_starts` / `*_water` as mask inputs to keep bases flat or to shape coasts.
3. Export the **Height** as 16-bit PNG, 16-bit TIFF or 32-bit float TIFF (any normalised range). Export masks you want as separate greyscale files (Gaea "Mask" / splat outputs; a 4-channel splat can be imported by channel).
4. In the editor: **Terrain > Import heightmap...**, choose the file. Mapping *normalised*, *Image 1 = height* = how tall the peak should be (the preview shows the range). Check the thumbnail, **Apply**.
5. **Masks** page: *Add files...* (several at once) or *RGBA splat...*, assign layers (or terrain types / named masks), keep *Layers above take away*, **Apply masks**. Named masks become the generator rule "Imported mask".
6. **Live link** page: *Watch: every image of a folder* (or the files of the import), the folder Gaea exports into, **Start watching**. Rebuild in Gaea, export: when the files stop changing, the editor re-imports with the same settings. All live imports together are one undo step (the previous one is replaced); **Revert last** takes the latest back.
7. Round trip: export from the editor (*normalised*, 16 bit or float), edit in Gaea, import again; choosing the file reads `<name>_height.json` and sets the exact range, so unchanged areas come back exactly.

## World Machine workflow

1. Build size: **1025 x 1025** (or 513 / 2049 to match the map; the README lists it). Terrain extent = the map width in metres (so slopes read the same).
2. Heightfield output: **.r16** (raw 16 bit; set *Raw bits 16*, little endian, the size comes from the file), or 16-bit PNG, or 32-bit TIFF. Normalised output again: set *Image 1 = height* to the peak height you want (World Machine's terrain height setting is this number).
3. Colour / mask outputs (flow, wear, deposition, slope) as 8 / 16-bit greyscale bitmaps: add them on the **Masks** page, layer or terrain-type target.
4. Live link works the same: watch the output folder of the device.
5. Re-import of an editor export: choose the `.r16` or `.png`, the json beside it gives min / max.

## Blender, Photoshop, QGIS

* Blender: render or save the height (Z pass / displacement texture) as a 32-bit float TIFF or 16-bit PNG; use *absolute* (float TIFF in world units) or *normalised*.
* Photoshop: 16-bit greyscale PNG / TIFF (Image > Mode > 16 Bits/Channel, Grayscale). Paint masks as greyscale.
* QGIS: export the raster as Float32 GeoTIFF. Elevations in metres: *absolute* if the numbers already are the height you want, otherwise *normalised + stretch* and set the range. The editor resamples with a proper low-pass, so a larger raster is fine.

## What the editor remembers

The import and export settings, the mask list, named masks and the live link choices are part of the map (`<map>_editor.lua`, key `Interop`), written only when they differ from the defaults. Named masks keep their file path: keep the image next to the map or add it again.

## Tests and tooling

`selftest_interop` (the editor's selftests; `python scripts/editor_inst.py selftests <tag>`), `python scripts/ed_interop_test.py` (native ops, MSVC). Native files: `EdFieldInterop.cpp`, `EdInteropLua.cpp` in the engine repo (see the design doc; they need a build of the editor engine).

## Smoother loop (2026-10-25)

The Interop panel got a first page, **Gaea / WM**, and the import knows more about the maps it is for.

* **Setup page**: the numbers to set in the other tool for this map (grid, extents, formats), how tall your own maps are at this size, the names the editor understands, and **Send and watch**: it exports
  into the export folder (heightmap, json, masks, start positions, README) and watches that folder. A new file written there comes in by itself: a mask by its name (below), otherwise the first file is
  the heightmap. Our own export files (`<name>_height`, `_water`, `_slope`, `_flow`, `_wear`, `_layerN` ...) are never taken back.
* **Typical height**: `scripts/map_texture_presets.py` also writes `Stats` (per map size: total relief, land span, mean slope, share over 30 degrees; 5 / 25 / 50 / 75 / 95 percentile over the maps of
  the user's Maps folder) into `mapsets.lua`. The Heightmap page shows them and has **A calm map / The median map / A tall map**, which set "Image 1 = height" so the import has that relief (the image's own value
  span is taken into account). The preview line compares the import with them (relief, mean slope) and warns when it is taller or steeper than 95 percent of your maps, or nearly flat. A free-running
  Gaea height is easily three times the relief of the tallest map; the graph is built with the same numbers (`GRAPH_TEXTURING.md`, Heights).
* **Symmetry** (Heightmap and Masks pages, `Settings.symmetry` / `MaskSet.symmetry`): off by default (an imported terrain is not symmetric, a symmetric import keeps one part and copies it over the rest).
  Choose the editor's symmetry or a mode; the same `gensym.lua` as the graphs (`GEN_SYMMETRY.md`).
* **Mask names**: `Flow`, `River`, `Stream` -> named mask `flow`; `Wear`, `Erosion` -> `wear`; `Deposit`, `Sediment` -> `deposit`; a kind of ground in the name (`grass`, `rock`, `sand`, `snow` ...) -> the
  paint layer of that kind on this map's shader (`texsets.RoleLayer`, so no layer numbers). Adding files on the Masks page sets targets from the names (and says so); a file that appears in the live-link folder
  is added the same way.
* **Graph nodes** (`graphnodes_ext.lua`): **External terrain** is the Interop panel's heightmap (file, mapping, alignment, orientation, filter) as a height field at the resolution of the graph (the alignment is
  decided on the whole map so the preview and the build agree); **External mask** is a named mask (flow / wear / deposit) as a 0..1 field, empty when there is none. The graph evaluates again when the other tool writes
  the file (after a second without change) or the import settings move (`Interop.GraphSignature`, `graphrun.Refresh`). Sample graph **Gaea / World Machine terrain**: External terrain -> Output: height, Ground kinds
  fed by the terrain and the three erosion masks -> Output: ground kinds; its symmetry is off.
* EXR is still not read (no Windows codec; a reader would be an engine patch). Choosing an `.exr` now says so and what to export instead.
* Not done: reading the tools' project files (`.tmd`, Gaea's project) to check resolution and extents; a Gaea / World Machine plugin (their extension APIs are C# / C++ / Lua and do not document a build or
  export hook).

## A real Gaea export as a test (cracked_basin, Gaea 1.3.2.7, 512 x 512, 10 x 10 km map)

Five 16-bit greyscale PNGs from a project given to the user: `Final Heightmap`, `Flow`, `Flow-Secondary`, `wear`, `deposit`. What the import had to learn from them:

* The heightmap uses 0.0100 to 0.0519 of the 16-bit range (the export was not normalised): imported as it is, it has a relief of 4 units and a mean slope of 1.8 degrees. `SuggestMax` thought the image spanned the
  whole range (a guard against tiny spans); it now says the image needs the stretch, the typical-height buttons switch **Stretch to image range** on, and the preview warns "the image only uses 4.2 percent of its
  range". With the stretch and the median relief of the maps of this size (31 units) the terrain imports as plateaus with craters and cliffs.
* The three masks all peak at exactly 0.52. Imported as they are they would be half strength: erosion masks guessed by name are now **stretched to 0..1** (a toggle per mask, `item.stretch`; named masks keep it).
* `Flow.png` and `Flow-Secondary.png` are two different images and both mean "flow": the second is named `flow2` (`UniqueName`), so neither replaces the other.
* 512 pixels on a 512 cell (513 sample) map: the alignment picked is "cell", which is right.
* The sample graph "Gaea / World Machine terrain" built from these (External terrain, the stretched wear / deposit / flow into Ground kinds, valley textures) paints the cliffs rock, the plateaus tan and the
  basins green with no further setting; `texture_lab.py --pre <lua>` runs the import setup before a graph case.
