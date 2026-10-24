# Map layout editor and start / resource generator (2026-10-25)

Goal (user): a canvas where the map is drawn in layers, turned into a height map by the generator and into masks for the generator nodes; plus a generator that places mass around start positions by shape and
distance. User help: `editor/help/10_map_layout.md`. Tests: `selftest_layout.lua` (98 checks). Workspace: **Layout**.

## Pieces

| File | What |
|---|---|
| `layout.lua` | The document (layers of `res x res` cells, 0..1), the painting tools with symmetry and undo, the canvas picture, the generator (`Build`, `Generate`, `Preview`, `LayerMask`), the base centres, the sidecar (run length coded) |
| `layoutmarkers.lua` | Starts (existing / drawn bases / pattern), the shapes (ring, arc, cluster, line, pairs), `Plan` (nothing placed), `Place` (one undo step) |
| `gui/panels_layout.lua` | Panels `layoutcanvas`, `layoutlayers`, `layoutmarkers` |
| `graphnodes_layout.lua` | Nodes `layout_height`, `layout_mask`, `layout_bases` |
| `gui/workspace.lua` | The `Layout` workspace |

## The document and the painting

`Layout.Doc = { res, rw, rh, cell, ox, oz, base, water, seed, weather, layers = { { id, name, kind, visible, color, p, data } }, sel, rev, generated }`. The drawing covers the **playable area**
(`playable.lua Get`, the whole terrain when there is none): `res` cells (128 by default) on the long side, square cells of `cell` world units, `rw x rh` cells in all (a 2 : 1 area gives 128 x 64),
the drawing centred on the area (`ox, oz` = the world position of its corner). `ToWorld` / `ToCell` convert. Outside the drawing the generator continues the edge cells. The grid is saved with
the drawing (files from before have no grid: they load as the whole map, square). `Stale()` says the area changed under a drawing; `Sync()` refits an empty drawing silently, `Refit()` ("Fit to the
area") resamples a drawn one by world position (what was drawn stays at its place on the map, one undo step). `CentreSymmetry()` puts the editor symmetry centre in the middle of the drawing (templates
do it): the symmetry module's default centre is the middle of the terrain, which is not the middle of the area on every map; `Symmetry.Centre` now uses the real height of a non-square terrain. A stroke is
`BeginStroke(i)` ... `EndStroke(label)`: one entry in the editor history (undo and redo work with Ctrl+Z like everything else). The brush paints the images of the editor's symmetry (`symmetry.lua Points`),
rectangles, ellipses and polygons map every cell through its centre. Fill, clear, smooth and invert are undoable edits (`Layout.Edit`). The canvas picture is written as a thumbnail (`Fields.PreviewPixels`) at
most every 70 ms while dragging (350 ms in the height view) and the previous file is deleted.

## The generator

Every layer is spread over the map (`resample`, bilinear) and softened by its own soft edge (`blur`, at least 0.8 of a cell, so cells do not show as diamonds), then applied from the bottom to the top to a
field that starts at the ground height:

* hills `+= m * (height + rough * noise)`; mountains `+= m^1.4 * (height * (0.3 + ridged noise) + rough * noise)`; plateau: `lerp(H, top, m)` (top = ground + height + a little noise); water: `min(H, lerp(H, waterLevel - depth, m))`;
  valley `-= m * depth`; flat and base: `lerp(H, ground + level, m)`; free masks change nothing.
* optional weathering (droplet erosion, the solver of the Generate presets), then the editor's symmetry (`symmetrize` about the symmetry centre **in world units**, copy of the master part with a soft
  seam: the noise is the only thing that is not symmetric already; the result is exactly symmetric, `selftest_layout` compares mirrored samples), then a clamp. `Generate` writes the heights (and the water level when a water layer has paint) as one undo step (`History.Merge`).
* `Build(env, like, o)` works in a Fields scope or in a graph evaluation, which is how the nodes use it.

## Starts and resources

`Starts()` gives the positions (a pattern is drawn on the unit circle / square and stretched over the playable area, so a long map gets starts along it; the middle and the facing are the middle of the
area); `Plan()` fits every marker (`Fit`): inside the playable area (4 units in), above the water (+1), a slope under the limit, outside the spacing of every marker already there and
of the others in the plan; when the ideal spot fails, 30 attempts at other angles and distances around the start. `Place()` removes what the generator made before (`Doc.generated`), replaces the start markers
when they come from a pattern or the bases (`Tools.PlaceMarker`, names `ARMY_<n>` from `armies.NextName`), places the plan and merges all history entries into one. The random numbers are a small generator
whose values stay below 2^24 (the Lua numbers here are 32 bit floats).

## Colour and pictures

`SetColor(i, r, g, b)` (the panel: a palette and three sliders) changes the colour of a layer on the canvas only; it is saved with the layer. `ImportImage(i, path, o)` reads a picture with the interop
reader (`ed_img_read`: PNG, TIFF, BMP, JPEG, raw heightmaps), fits it over the drawing with `img_resample` (bilinear; `fit = 'contain'` keeps its aspect, the rest of the canvas gets 0), and writes the
cells of the layer (white = 1): options `channel`, `invert`, `stretch` (darkest value 0, brightest 1), `hard` (threshold 0.5), `add` (the larger value wins), `flipX`, `flipZ`. One undo step.

## Not done

Layouts only cover one rectangle (the playable area); the diagonal and 4 fold symmetries need a square area (the canvas says so); the Interop panel remains the way to bring a picture in as a mask for
the graph without a layer; props / forest density from a Free mask (use the node Map layout: layer mask with Output: scatter props).
