# Symmetric terrain generation (2026-10-25)

## What was wrong

A competitive map has to be symmetric: heights, paint, terrain types, props. The shipped symmetric graphs put a **Symmetrize** node in the middle and
trusted everything after it. Measured with `scripts/symmetry_audit.lua` (difference between the built map and the average of its images under the
symmetry; heights in units, paint masks 0..1; 257 map):

| graph | symmetry | height rms / worst | paint rms / worst |
|---|---|---|---|
| lib_duel_turn | turn 180 | 0 / 0 | 0.015 / 0.19 |
| lib_ffa4_corners | turn 90 | 0 / 0 | 0.025 / 0.61 |
| lib_ffa4_diag | mirror x and z | 0.22 / 2.1 (droplet erosion after the node) | 0.066 / 0.62 |
| lib_two_islands | mirror x | 2.6 / 10.7 (erosion after the node) | 0.072 / 0.50 |
| lib_hex6 | 6-fold turn | 0.22 / 1.0 | 0.018 / 0.29 |

* **Heights** break wherever a node after the Symmetrize node is not symmetric itself: droplet erosion (random droplets), noise, a second blur at the map edge.
* **The paint** was never symmetric: the ground-kind rules read noise (`NoiseAt`, the patch and grain rules) that has nothing to do with the symmetric heights.
* **Scatter** threw its dice over the whole map (it was only symmetric when the editor's symmetry happened to be on).

## The rule

*What a generator writes is made symmetric where it leaves the generator*, not somewhere in the middle: the master part of the final field is copied over the rest (the
`symmetrize` field op, `combine = copy`, a soft seam across the part borders, 12 units for heights, 8 for masks). Nodes before the output may do what they like; the result is exact.

`gensym.lua` holds it:

| | |
|---|---|
| setting | `nil` / `'map'` follows the editor's symmetry (Symmetry panel; found from the start positions on load) and does nothing when that is off; `'off'`; a mode (`mirror_x`, `mirror_z`, `mirror_xz`, `diag`, `adiag`, `diag_both`, `rot2`, `rot4`) about the middle of the map; `{ mode = 'rotn', n = 6 }` |
| `Spec(setting)` | `{ mode, n, cx, cz }` in world units, or `false` |
| `Field(S, f, spec, { seam })` | `f` made symmetric (the field op) |
| `Points(spec, x, z)` | the images of a point (props), with `symmetry.lua Heading` for the heading of each image (`PointsFor` learned `adiag` and `rotn`) |

Where it is applied:

* **Terrain graphs** (`graphrun.lua`): `graph.symmetry` is a graph setting (saved in the graph file, undoable, `Graph.SetSymmetry`; the **Symmetry:** button of the graph toolbar). Each height output
  (and its mask) is symmetrized in `FinalHeight`, so the live preview shows what the build writes. Paint and terrain types: `MaskGen.NewContext(S, { symmetry = spec })`, and the writers
  (`MaskGen.WriteLayer`, `WriteTypes`, `Recipes.WriteTargets` for the ground kinds) symmetrize the masks before the cascade and the terrain types are made of the symmetric weights. Props: the
  density is symmetrized and `Scatter.Plan{ symmetry = spec }` places every prop with its images.
* **A graph without the setting follows the map**. The shipped graphs that have a Symmetrize (or Mirror) node carry that node's symmetry (`scripts/graph_symmetry_presets.lua`; 12 graphs).
* **Generate presets** (`fieldgen.lua`): the generated relief and its mask follow the editor's symmetry (`p.symmetric = false` turns it off). **Mask generator / ground kinds panels**: the contexts follow the
  editor's symmetry. **Scatter panel**: it already did.

Result with the same audit after the change (512 map, all 12 symmetric graphs): heights 0.000 rms (6-fold turn 0.012: interpolation of the rotated copies), paint 0.000, props paired.

## Checks

`selftest_gensym.lua` (in `selftests.extra`): the setting and its points (3-fold turn, anti-diagonal), a noise graph is symmetric under turn 180 / mirror x / mirror x and z / turn 90 / 3-fold turn,
the same graph with the symmetry off is not (so the test can tell), following the map with and without a symmetry, the setting in the graph file and its undo, a paint layer and a scatter output
(every prop has its image). `scripts/symmetry_audit.lua` measures the shipped graphs.

## Not done

* A Symmetrize node in the middle still copies only the heights; the new setting makes it redundant for the result but it is kept (it shapes what the erosion sees).
* Water, foam and the decals of a graph are not symmetrized (the graph outputs for them do not exist yet).
* The N-fold turns are exact only on a grid that has the centre of the turn on a sample or the map is square; the audit shows the rounding (0.012 rms for six).
