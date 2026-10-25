# Texturing in the terrain graph, by the shader of the map (2026-10-25)

What was wrong: the shipped graphs painted three or four layers with hand made masks (`Output: ground kind` per mask), the texture presets did not know the 7 and 8 layer shaders, and nothing in the graph
knew the shader. Also: after one graph had built a terrain, loading another graph (the texture pass) showed the ground from *before* the first graph in its `Map heights` node until the terrain was edited by hand.

## The "Map heights" node after a Build of another graph

`graphrun.lua EnsureBase` keeps the ground as it was when a graph first looked at it, so that a second Build of the *same* graph starts from the same ground (a graph that reads the terrain and writes it
back must not read its own result). It recognised "our own result" by a checksum (`Base.builtSum`, `Base.shownSum`) for ANY graph, so a different graph (`Graph.Current` is a new table after New / LoadPreset /
Load) still saw the old base. Now `Base.owner` is the graph that built or previewed; only that graph treats the checksum as its own, every other graph re-reads the ground that is there.
`selftest_graph` checks it (a graph builds a terrain of 77, the next graph's Map heights reads 77; a second Build of the same graph still starts from the same ground).

## New nodes (`graphnodes_kinds.lua`, tests `selftest_kinds.lua`)

| Node | What |
|---|---|
| **Terrain shader** (source) | the shader as numbers: painted layers (4 / 7 / 8), pbr, splat (2xx), biplanar (B shaders), macro, specular, roughness (layer 8). Re-runs when the shader or the layers change |
| **Ground kinds** (analysis) | heights in, eight masks out: the **selection** of grass, dirt, wet, sand, rock, dark rock, high rock, snow, by the stratum recipe for the map's shader and textures: the kinds that have a layer, the base layer (what the others leave), side-mapped layers (3 and 4 of the B shaders) steep ground only; a kind with no layer comes out empty. A style (the recipe styles) and every knob of the recipe as a slider (a slider left at its default takes the value of the style) |
| **Surface roughness** (analysis) | kind masks in, a roughness mask out (0.5 neutral): rock, dark rock and sand rough, wet ground and snow shiny. Wire it into `Output: roughness mask` |
| **Output: ground kinds** (output) | eight optional kind masks: Build settles overlaps (snow over high rock over dark rock over rock over wet ground over sand over dirt over grass), gives each kind its layer whatever the shader (`recipes.WriteKinds`), writes the masks in the shader's encoding, the terrain types by what shows most and, on the PBR shaders, the roughness multiplier; a kind with a layer but no wire is cleared from its layer |

| **Flatten gentle ground** (shape) | selects the ground gentler than a slope (measured over a distance), softens that selection, replaces the ground there by a blur of itself: flat open ground with crisp ridges and banks. `mask` is the flattened area |
| **Landforms (plains and hills)** (generator) | the layout of a good map: a large noise decides where the hills are (a share of the map), flanks of a chosen width, ridged detail, rounder or sharper tops, nearly flat plains. `out` heights, `mask` the hills |

`recipes.lua` was split to make this possible: `Selections_` (the selection per kind, with the side-mapped gate) / `Resolve` (the priority cascade and the variants of a kind with several layers) /
`WriteTargets` (opacity per layer, terrain types, summary, one undo entry); `StatsOf(S, H)` gives the numbers (percentiles of the land heights) of any height field of the graph instead of the map's;
`Roles(cx, st, knobs, preset)`, `Selections(S, c, o)`, `WriteKinds(S, c, sel, o)` and `KnobsFor(o)` are the public parts. The panel's Apply uses the same path, so the graph paints what the recipe
paints (the test compares rock, sand, dirt and snow of both within 4 percent of the map).

## The shipped graphs

`scripts/graph_preset_upgrade.lua` (run in a test instance) loads every terrain graph, removes the hand made texture outputs and the masks that only fed them, and adds `Ground kinds -> Output: ground kinds`
fed from the heights the graph writes, with the style of the landscape (mountains and highlands alpine, islands and wetlands coast, desert and badlands desert, tundra arctic, canyons, craters and volcanoes
rocky, the rest natural). A graph without any paint got the tail too. `scripts/graph_texture_presets.lua` builds the two texture graphs (`texturing`: Map heights -> Ground kinds -> Output: ground kinds plus
the Terrain shader node; `lib_colour_pass`: the same plus roughness, macrotexture, specular, atlas and a colour map). `scripts/graph_preset_install.py` copies the results into `graphpresets/`.
`make_graph_presets.py` is NOT the source of the shipped files any more (it never knew the library graphs and its output is older than the files).

## What a good map has: Adaptive Archsimkats Valley (made in World Machine) against the shipped graphs

Measured with `scripts/terrain_metrics.lua` (run in a test instance with the map open; the same script ran on the graphs built on a 512 map), photographed with the texture lab
(`scripts/texture_lab.py`, now also `--cases g=<graph id>:<theme>:<recipe>` for a shipped graph; `--no-water` for the ground alone).

| | Archsimkats Valley | old `hills` | old `mountains` | `hills` + Flatten | `valley` (Landforms) |
|---|---|---|---|---|---|
| mean slope | 8.4 deg | 20.9 | 44.0 | 9.9 | 11.1 |
| ground steeper than 5 / 20 / 30 deg | 47 / 11 / 7 % | 94 / 45 / 25 % | 99 / 89 / 79 % | 67 / 12 / 3 % | 59 / 21 / 10 % |
| land heights, 5th / 25th / 50th / 75th / 95th percentile | 18 / 20 / 23 / 25 / 29 | 39 / 42 / 45 / 49 / 53 | 51 / 59 / 71 / 81 / 93 | 39 / 42 / 44 / 47 / 49 | 27 / 28 / 40 / 45 / 47 |
| relief (rms of H - blur) at r = 2 / 8 / 32 / 128 | .21 / .83 / 2.1 / 3.3 | .32 / 1.2 / 3.6 / 5.1 | .77 / 3.3 / 9.5 / 18 | .14 / .55 / 2.0 / 3.1 | .11 / .68 / 2.9 / 6.7 |

What the numbers and the pictures say:

1. **The ground is not noise everywhere.** Half of the reference is nearly flat (under 5 degrees: open, buildable ground) and a small part is steep (7 percent over 30 degrees: cliffs, banks, ridges
   with a definite edge). The shipped graphs were stationary noise: 94 percent of `hills` is over 5 degrees, a mountain preset is over 40 degrees on half of the map. The relief per scale of the reference
   is a smooth fall-off (the same shape as ours): it is not the spectrum that is wrong, it is that the roughness is spread evenly instead of living in separate landforms. Its height distribution is
   two-humped (plains, then hills).
2. **The layout is designed, not rolled.** The World Machine projects (`external_projects/World Machine/saves/*.tmd`, strings of the file) are made of Shape / Layout generators (Shape Frequency, Roughness,
   Breakup), selectors by slope and height, many Blur devices (a hundred blur settings in one project: every mask is softened), Combiners and Overlays, erosion with flow / sediment / wear masks.
   That is the recipe: large shapes first, detail only where the shape says, erosion, then masks made from the result.
3. **Two colour families with a hard contrast, not a mix of similar ones.** Dark green hills and ridges against light tan plains, grey rock only on the steep faces, nothing else in quantity (six of the
   eight layers are under 6 percent). The temperate set the editor used (olive grass `grass001`, brown `Dirt001`) put olive on olive: no contrast, hence the flat look of every result. The paint masks of the
   reference are very soft (the main layers are in transition over half of the map): the contrast comes from the textures and from the landform, not from crisp edges.
4. **The paint follows the landform.** Green is where the ground stands above its surroundings (hills, ridges), tan is the floor and the basins; the boundary is the foot of the hills. The recipes
   decided by noise, slope and height only, so the patches had nothing to do with the terrain.
5. **Props and effects do the rest** (the forests on the green, scorch decals, rocks, the milky ponds): the graphs have a scatter output, the shipped graphs do not use it yet.

What was done about it: the texture set **Open valley** (Evergreen 2 grass, tan gravel, grey rock: the textures of the reference), the recipe style **Open valley** (a new `relief` rule of the mask
generator, height above the surroundings, keeps the tan on the open ground and the green on the hills), the node **Flatten gentle ground** (select the gentle ground by slope, replace it by a blur of
itself: the step the reference maps are full of), the node **Landforms (plains and hills)** (a share of the map is hills with flanks of a width you choose, ridged detail, plains almost flat) and the graph
**Open valley** made from it.

## Result and what is where

* Texture set **Open valley** (`texsets.lua`, now the default of a new map; Temperate stays in the list), recipe style **Open valley** (`Presets`, `relief = true`; the dirt builder uses the new
  `relief` rule of `maskgen.lua`), `Roles(cx, st, knobs, preset)` hands the style to the builders through `cx.style` / `st.style` (they read `State.preset` before: a graph node asking for another
  style than the panel's got the panel's).
* `scripts/graph_preset_upgrade.lua` (tail, style, Flatten for the gentle landscapes), `graph_texture_presets.lua` (texturing, colour pass), `graph_landform_presets.lua` (Open valley: Landforms,
  droplet erosion, kinds, a scatter of pine and oak groups on the hills), `graph_preset_install.py` (copies, updates index.lua). The thumbnails in `graphpresets/thumbs` were not regenerated.
* `selftest_kinds.lua` (26 checks) covers the nodes, the paint against the recipe's, Flatten and Landforms; all 36 shipped graphs load and evaluate without errors.
* Styles after the upgrade: mountains and highlands alpine, canyons desert, craters / rift valley / diagonal ridges Open valley (rocky had snow on plateaus: pale blue patches on the canyon),
  islands and wetlands coast, desert and badlands desert, tundra arctic, the rolling landscapes Open valley.
* Looking at them: `python scripts/texture_lab.py --out DIR --map 512 --no-water --views top,oblique --cases "g=valley:valley:-"` (a graph id, then the texture set, `-` = no recipe on top).
  The texture set must be applied BEFORE the graph builds (applying a set clears the paint): the lab does that.
