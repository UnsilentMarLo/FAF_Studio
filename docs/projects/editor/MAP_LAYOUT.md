# Map layout editor and start / resource generator (2026-10-25)

Goal (user): a canvas where the map is drawn in layers, turned into a height map by the generator and into masks for the generator nodes; plus a generator that places mass around start positions by shape and
distance. User help: `editor/help/10_map_layout.md`. Tests: `selftest_layout.lua` (52 checks). Workspace: **Layout**.

## Pieces

| File | What |
|---|---|
| `layout.lua` | The document (layers of `res x res` cells, 0..1), the painting tools with symmetry and undo, the canvas picture, the generator (`Build`, `Generate`, `Preview`, `LayerMask`), the base centres, the sidecar (run length coded) |
| `layoutmarkers.lua` | Starts (existing / drawn bases / pattern), the shapes (ring, arc, cluster, line, pairs), `Plan` (nothing placed), `Place` (one undo step) |
| `gui/panels_layout.lua` | Panels `layoutcanvas`, `layoutlayers`, `layoutmarkers` |
| `graphnodes_layout.lua` | Nodes `layout_height`, `layout_mask`, `layout_bases` |
| `gui/workspace.lua` | The `Layout` workspace |

## The document and the painting

`Layout.Doc = { res, base, water, seed, weather, layers = { { id, name, kind, visible, color, p, data } }, sel, rev, generated }`. `res` is 128 by default (a cell is 4 units on a 10 km map). A stroke is
`BeginStroke(i)` ... `EndStroke(label)`: one entry in the editor history (undo and redo work with Ctrl+Z like everything else). The brush paints the images of the editor's symmetry (`symmetry.lua Points`),
rectangles, ellipses and polygons map every cell through its centre. Fill, clear, smooth and invert are undoable edits (`Layout.Edit`). The canvas picture is written as a thumbnail (`Fields.PreviewPixels`) at
most every 70 ms while dragging (350 ms in the height view) and the previous file is deleted.

## The generator

Every layer is spread over the map (`resample`, bilinear) and softened by its own soft edge (`blur`, at least 0.8 of a cell, so cells do not show as diamonds), then applied from the bottom to the top to a
field that starts at the ground height:

* hills `+= m * (height + rough * noise)`; mountains `+= m^1.4 * (height * (0.3 + ridged noise) + rough * noise)`; plateau: `lerp(H, top, m)` (top = ground + height + a little noise); water: `min(H, lerp(H, waterLevel - depth, m))`;
  valley `-= m * depth`; flat and base: `lerp(H, ground + level, m)`; free masks change nothing.
* optional weathering (droplet erosion, the solver of the Generate presets), then the editor's symmetry (`symmetrize`, copy of the master part with a soft seam: the noise is the only thing that is not symmetric
  already), then a clamp. `Generate` writes the heights (and the water level when a water layer has paint) as one undo step (`History.Merge`).
* `Build(env, like, o)` works in a Fields scope or in a graph evaluation, which is how the nodes use it.

## Starts and resources

`Starts()` gives the positions; `Plan()` fits every marker (`Fit`): inside the playable area (4 units in), above the water (+1), a slope under the limit, outside the spacing of every marker already there and
of the others in the plan; when the ideal spot fails, 30 attempts at other angles and distances around the start. `Place()` removes what the generator made before (`Doc.generated`), replaces the start markers
when they come from a pattern or the bases (`Tools.PlaceMarker`, names `ARMY_<n>` from `armies.NextName`), places the plan and merges all history entries into one. The random numbers are a small generator
whose values stay below 2^24 (the Lua numbers here are 32 bit floats).

## Not done

Non-square layouts (the editor's tools assume a square map); a colour per layer in the panel (the colours are the kind's); importing a picture into a layer (use the Interop panel to bring an image in as a
mask for the graph); props / forest density from a Free mask (use the node Map layout: layer mask with Output: scatter props).
