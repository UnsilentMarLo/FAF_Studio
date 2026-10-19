# Tutorial: a map from nothing with the terrain graph

This walks through building a competitive 1v1 map in FAF Studio, from an empty map to a textured, symmetric, pathable terrain, with the pieces of the terrain stack: the node graph,
masks, erosion, splines (paths), base pads, symmetry and the interop with Gaea / World Machine. The pictures were taken from the running editor by `scripts/make_tutorial_shots.py`.
The ready graphs used as starting points are listed with pictures in [TERRAIN_GRAPH_LIBRARY.md](TERRAIN_GRAPH_LIBRARY.md); the engine side is in [TERRAIN_GEN_DESIGN.md](TERRAIN_GEN_DESIGN.md).

## 0. Start

File > New map > 1024 (20 km) gives a flat map with one start marker. Switch to the **Generate** workspace. Left: the palette (tab *Nodes* lists every node by category with a search
field; tab *Graphs* lists the library). Middle: the graph canvas over the viewport. Right: the inspector and the variations. A graph is evaluated live at 1/4 resolution (257 x 257 samples
on a 1025 map, tens of milliseconds); **Build** runs it at full resolution and writes the result as ONE undo step.

## 1. Take a starting graph

Tab *Graphs* > *Library*. A click loads a graph (Undo brings the old one back); the picture and the README line of the graph appear above the list.

![the library](tutorial/library.png)

For this tutorial load **Duel: two bases, turned 180 degrees**. Every node shows a thumbnail of its own result; wires carry heights, masks, paths, numbers and colours (the port colours tell which).

![a graph on the canvas](tutorial/canvas.png)

## 2. Shape the ground: generators, filters, erosion

Click a node to see its parameters in the inspector: every number is a field with a slider and minus / plus buttons, choices are lists, presets are buttons.

![the inspector](tutorial/inspector.png)

- **Generators** (category *Generators*): Perlin, simplex, billow, ridged, Voronoi, and from stage T7 *Multifractal (Musgrave)*, *Eroded noise*, *Cells* (ten modes and four metrics), *Craters*, *Dunes*,
  *Cracks*, *Island shape* and the presets *Hills*, *Mountains*, *Mesas*. Sizes are lengths in units; wire a **Map share** node into a size to make it a share of the map width, so the graph
  looks the same on a 256 or a 1024 map.
- **Shape**: blur, curve, terrace, warp, and *Domain warp* (noise, curl flow, swirl, ripples, pinch), *Smooth (keep edges)* and *Smooth (diffusion)* (bilateral and Perona-Malik: noise goes, cliffs stay),
  *Sharpen*, *Edge detect*, *Morphology*, *Convolution*, *Directional blur*, *Slope blur* and *Rock layers (stratify)*.
- **Erosion**: thermal, hydraulic, droplet, stream power (T3) and the variants *Thermal (talus map)*, *Rock and soil*, *Snow and slumping*, *Wind erosion*, *Glacier*, *Sediment settling*; each gives the
  height and masks (scree, soil, rock exposure, snow cover, sand, ice, carved depth, deposit) as extra outputs for texturing.

Use **Range** (*To height range*) to turn a 0..1 field into heights. Use **Variations** to see six seeds of the whole graph and click one.

## 3. Masks and textures

Analysis nodes make masks: slope, curvature, *Cavity / occlusion*, *Hillshade / lit sides*, *Wetness (topographic)*, *Rockiness*, *Mask preset* (cliffs, beach, snow ...), *Pathable ground*.
Wire a mask into **Output: texture layer** (layer 1..8, replace / add / subtract, optionally "layers above take away"). Library convention: 2 cliff / rock, 3 sand, 4 snow, 5 lush, 6 rock outcrops,
7 dark. The **Colour ramp** node turns a mask or heights into colours (thumbnail shows them); **Output: colour image** writes them to a DDS file on Build.

![the colour ramp](tutorial/colour.png)

## 4. Fair maps: pads, symmetry, pathing

These are the Supreme Commander specific nodes (category *SC terrain*):

1. **Symmetrize** copies a master part over the rest: mirrors, diagonals, 2 / 4 / N-fold turns. A mirror (copy) is exact. A turn made from arbitrary noise has a seam at the wedge border, so use
   *Where images meet: Average* (continuous and exactly symmetric) and put the pads **after** the symmetry step, one pad per player.
2. **Base pads** flatten a square to the build grid with a smooth skirt. Mode *One pad* takes a position (share of the map); mode *The map's markers* flattens under the start positions and the mass /
   hydrocarbon markers by the rules of the SC terrain panel (resource rings share one height).
3. **Slope limit (pathable)** guarantees the engine's 0.75 rule for every unit class (exact, not iterative).
4. **Pathable ground**, **Connected regions** and **Travel distance** check the result: wire the heights into *Pathable ground* (blocked or passable) and its mask into *Connected regions*; both bases
   must lie in one region. The Terrain checks panel does the same on the built map.

Paths (splines): *Path: line / ring* make curves from numbers, *Path: from the Paths tool* reads what you drew with the Paths tool. *Path shape* carves, raises, levels, ramps or makes a river along
the path with a cross-section profile; *Path mask* gives the corridor as a mask (sand along a river).

## 5. See it, build it

**On terrain** writes the coarse result into the real terrain (revert with **Revert**); **Build** runs full resolution as one undo step. The Build keeps its full-resolution results in memory
(up to about 640 MB), so after a change near the end of the graph the next Build re-runs only that node and what follows (a 27 node graph on 1025: 3.1 s cold, 0.26 s after changing the last node).

![the result on the terrain](tutorial/on_terrain.png)

## 6. The panels behind the graph

The same engine runs the panels of the Terrain workspace: *SC terrain* (pads, symmetry, slope limit, skeleton generator, water masks), *Paths*, *Erosion*, *Mask generator*, *Interop*.

![SC terrain panel](tutorial/sc_panel.png)
![Paths panel](tutorial/paths_panel.png)

## 7. Gaea / World Machine

Export a height map from the editor (Interop panel > Export: 16 bit PNG / TIFF / raw, with the scale file), shape it in Gaea or World Machine, then import it again: the panel maps the image range
to world units (normalised, absolute, or "sea level in image"), fits it with a proper filter, keeps pads under the start positions and writes masks (flow, wear ...) into texture layers. The **Live
link** re-imports whenever the file changes. In a graph the node *Fit image to the map* (with *Image*) brings an external field into the node graph, where it can be eroded, symmetrised and
textured like any other. Details: [TERRAIN_INTEROP.md](TERRAIN_INTEROP.md).

![Interop panel](tutorial/interop_panel.png)

## 8. A checklist for a competitive map

1. Heights from a library graph or your own; one symmetry node; pads after it for every player.
2. Slope limit; *Pathable ground* > *Regions*: one region for all bases and resources.
3. Build; run **Terrain checks**; move markers with the marker symmetry.
4. Texture by masks (cliffs, wetness, rockiness, cavity); scatter props with *Output: scatter props*.
5. Save the map: the graph is stored in the map's `_editor.lua` sidecar and opens with it.
