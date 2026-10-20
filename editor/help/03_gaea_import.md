# Import terrain from Gaea or World Machine
summary: Bring a heightmap and masks from an external terrain tool into the map, and round-trip them.
keywords: gaea, world machine, heightmap, import, export, interop, png, tiff, r16, raw, mask, splat, live link, blender, photoshop, qgis

The Interop panel moves terrain between the editor and other tools as image files. File > Import > Heightmap from an external tool... opens it (a tab beside the console in the Terrain workspace). File > Export > For external tools... exports the map.

## Numbers to know

- A 5 km map has 256 cells and 257 samples per side, 10 km has 513 samples, 20 km has 1025. An image of exactly that many pixels (257, 513, 1025) matches sample for sample; other sizes are resampled.
- Heights are 16 bit with a 1/128 unit step: 0 to 511.99 units. Good gameplay terrain stays below about 100 to 150 units; decals are not drawn above 250.

## From Gaea

1. In the editor: File > Export > For external tools..., pick a folder, Export. You get the heightmap, masks, start positions and a README that names the grid size of your map.
2. In Gaea: build at 1025 (or 1024 / 2048) and export the Height as 16-bit PNG, 16-bit TIFF or 32-bit float TIFF. Export any masks you want as separate greyscale files.
3. In the editor: File > Import > Heightmap from an external tool..., choose the file. Use the mapping "Normalised 0..1" and set "Image 1 = height" to the height of the highest point. The panel shows the resulting range and a thumbnail before anything is written.
4. Click Apply. It is one undo step.
5. Masks page: Add files... (several at once) or RGBA splat..., assign each to a texture layer, a terrain type or a named mask, Apply masks.
6. Live link page (Terrain > Live link to Gaea / World Machine...): pick the folder Gaea exports into and Start watching. When the files stop changing, the editor re-imports them with the same settings.

## From World Machine

1. Build size 1025 x 1025 (or 513 / 2049), terrain extent equal to the map width in metres.
2. Heightfield output as .r16 (raw 16 bit), 16-bit PNG or 32-bit TIFF; set "Image 1 = height" to the peak height you want.
3. Import flow, wear, deposition and slope outputs on the Masks page.

## Other tools

- Blender: save the height as a 32-bit float TIFF or a 16-bit PNG.
- Photoshop: 16-bit greyscale PNG or TIFF.
- QGIS: Float32 GeoTIFF; use "absolute" when the numbers are already the height you want.
- EXR is not supported: export a 32-bit float TIFF instead.

## Placing it

Region (whole map, playable area, rectangle), Blend (replace, add, max, min, by mask), Strength and Feather for partial regions, and Pads: "keep" protects the ground around start positions and resource points, "flatten" levels the new terrain there. Rotate and Flip correct an image that came out sideways.

## Round trip

Export from the editor, edit in Gaea, import again: selecting the file also reads the .json saved next to it, so unchanged areas come back exactly.
