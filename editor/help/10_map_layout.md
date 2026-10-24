# Map layout and starts
summary: Draw the map in layers, turn it into terrain, and place start positions and resources by shape and distance.
keywords: layout, canvas, draw, layers, hills, mountains, plateau, water, valley, flat, base, mask, generate, terrain, heightmap, start positions, mass, hydrocarbon, resources, ring, arc, cluster, symmetry, graph nodes

The Layout workspace is the fastest way from an idea to a map with a shape: you draw where the hills, mountains, lakes and bases go, press one button, and the terrain is made. The same drawing feeds the generator nodes as masks, and the start positions and resources are placed from it.

## Draw

1. Open the **Layout** workspace. The canvas in the middle is the whole map (a cell is a few units; the size is in the line above it).
2. Pick a layer in **Layout layers** and draw on the canvas: Brush (size, hardness and strength under the tool buttons; right button erases), Eraser, Line (rivers, ridges), Rectangle, Ellipse and Lasso (draw an outline, the inside is filled). A weak brush paints partial values, which make lower hills.
3. The kinds of layer: **Hills** (rolling ground), **Mountains** (high ridged ground), **Plateau** (a flat top with a steep edge), **Water** (dug below the water level), **Valley** (a channel or basin), **Flat ground** (levels to a height you set), **Base** (levels to the ground height; every blob is a start position), **Free mask** (changes no heights: a mask for the graph). Add more layers with the + buttons, hide, move and delete them in the list. Each kind has its own settings (height, soft edge, roughness, feature size) under the list. Layers are applied from the bottom to the top.
4. **Symmetry** at the top of the canvas is the symmetry of the editor: every stroke is drawn on its images too, so a 1v1 or 4 player map is fair by construction.
5. **Show: heights** shows the heights the generator would make (a coloured picture) while you draw; nothing is written.

## Generate

Set the ground height, the water level, the seed and the weathering (gullies) under the layer settings, then press **Generate terrain**: the heights and the water level of the map are written as one undo step. **Paint the ground too** also applies the Stratum recipe. Draw some more and press it again: the drawing is kept with the map.

## Starts and resources

The panel **Start positions and resources** places the starts and what lies around them:

* Starts come from the start markers the map has, from the **bases drawn** on Base layers (the centre of each blob), or from a **pattern** (a ring, the corners, two sides, a line; players, distance from the middle, rotation).
* **Mass per start** with a nearest and farthest distance and a **shape**: ring (evenly around), arc (a fan of the width you set, facing the middle of the map or away), cluster (a blob), line (a row) or pairs. Every start gets the same shape turned to face the middle, so symmetric starts get symmetric resources.
* **Hydrocarbon**, **extra mass** further out (expansions) and **mass in the middle** use the same shapes. The spacing between markers and the steepest ground are rules: a spot on water, on a steep slope, outside the playable area or too close to another marker is searched around and skipped when nothing fits.
* **Preview** shows the plan on the canvas (white: starts, orange: mass, green: hydrocarbon), **Place markers** writes it as one undo step. The markers made by the generator are replaced the next time (switch off *Remove the old ones* to keep them).

## For the node graph

In the Generate workspace the nodes **Map layout: heights**, **Map layout: layer mask** (a layer by its number in the list) and **Map layout: bases** (a mask with a disc around every base, and the number of bases) turn the drawing into fields, so erosion, texturing and scatter can use exactly the regions you drew. They follow the drawing: change the canvas and the graph evaluates again.
