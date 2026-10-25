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

## Aleasa.tmd (screenshots of the World Machine project) and what was taken from it

The project is built in blocks: **First generation** (a Contrast mask, Blurs and Basic Noise into an Erosion; a *File Input* heightmap, hand made, through Blur and **Terrace**, a Combiner with a
Select Slope times Basic Noise, an Erosion), **Combine** ("combine all that terrain, slightly blur it to take the edges off and add some constant to allow us to play with the gradient of the water"),
more Erosion at 4097 px, Select Roughness and Normal Map Maker, **Ramps** (Shapes through Erosion, Expander and Blur: erosion builds ramps units can climb), and a **Stratum Output** block: one
chain per layer, `Select Convexity / Slope / Wetness / Height -> Bias/Gain -> Blur -> Combiner with a Basic Noise -> output`, the wetness from the erosion. What follows from it:

* The layout is a drawn heightmap (our Layout workspace), shaped by Blur and Terrace, with detail noise only where the slope is steep, then eroded three times (coarse, then fine at high resolution).
  New graph **Layout to terrain** (`layout_terrain.lua`): Map layout heights -> Blur -> Terrace (half mixed in) -> Add a ridged noise that only lives on the slopes -> droplet erosion -> Blur ->
  hydraulic erosion -> out; the layout has to be drawn first.
* Every paint mask is a selector, a contrast curve, a blur and a noise: the recipes' rules (ramp, `crisp`, `blur`, `grain`) are the same chain. What was missing is the **erosion as a source of paint**:
  Ground kinds got the inputs `wear`, `deposit` and `flow` (the masks of an erosion node): wear bares rock, deposit lays the sediment (dirt) on the flats, flow is wet ground; `Erosion masks decide`
  is how much. The upgrade script wires the last erosion before the height output of every graph that has one; the Open valley graph now has two erosions (droplet, hydraulic) like the reference.
* The map-wide pictures (normal map, roughness) are outputs of the project: `Texture, roughness and colour pass` has Output: map normal map and Output: map lighting now.
* Ramps by erosion are not made; the Base pads and Slope limit nodes do the playability part.

## Heights of the shipped graphs (2026-10-25)

Measured with `scripts/graph_height_audit.py` (builds every graph on a 512 map: min / max, land percentiles, mean slope, share over 5 and 30 degrees). The reference are the maps of the
user's Maps folder (`scripts/map_texture_stats.py`, 143 maps of 512 and 161 of 1024): mean slope 4 to 18 degrees (median 10), 3 to 22 percent of the ground over 30 degrees (median 11), land
heights from the 5th to the 95th percentile spanning 6 to 33 units (median 18), highest minus lowest point 15 to 89 (median 38).

* **Too tall and too steep**: `mountains` (mean slope 44, 78 percent over 30 degrees), `badlands` (44 / 90), `pathing` (41 / 93), `lib_alpine` (54, 141 units high), `lib_highlands`, `lib_volcano` (133 units),
  `archipelago`, `lib_archipelago_fair`, `lib_desert_dunes`, `lib_badlands`, `lib_ffa4_diag`, `pathable`. Their `Height range` node spans 50 to 130 units over features a few hundred units wide.
* **Flat**: `lib_hex6`, `lib_tundra`, `lib_wetlands`, `plains`, `lib_ffa4_corners` came out at 2 degrees and 3 units of relief: the Flatten node that the upgrade script put into the gentle
  graphs (below 8 to 12 degrees, radius 40 to 60, strength 0.9) blurred nearly all of the ground, since nearly all of it is under 12 degrees. They now flatten under 5 degrees at radius 20, strength 0.7.
  `layout_terrain` is flat while the Layout workspace is empty: the build now warns (Map layout: heights has nothing to read).
* `scripts/graph_height_tune.py` (with `graph_height_tune.lua`) scales the span of the `Height range` node of a graph until the mean slope of the built result is the target (secant on the
  log of the span, 12 percent tolerance; `maxspan` caps a landscape with one tall feature, the volcano) and writes the graph; `graph_preset_install.py` copies it. Targets: mountains 22, alpine 26,
  highlands 22, badlands 22, volcano 22 (span at most 70), dunes 18, islands 15 to 18, symmetric mountains (ffa4 diag) 18, pathable ones 14, gentle ones 5 to 8.
  Result on the 512 map: mean slope 15 to 29 for the rough graphs (alpine 29, mountains 25), 4.5 to 8 for the gentle ones, no graph over 70 units of total relief except `lib_tropics` /
  `lib_two_islands` (islands, 75 units from the sea floor).

## Texture sets and recipe styles measured on the maps (2026-10-25)

* `scripts/map_texture_stats.py` parses every `.scmap` of a maps folder with `scripts/pylib/scmap.py` (pure Python, 345 of 352 maps; 7 are campaign stubs) and writes `.runs/maptex/maps.json`: per map the
  strata textures and tile sizes, per layer how much it covers and where (mean slope, height percentile, height over the surroundings, share of the cells in transition, weight per slope bin and per height decile).
* `scripts/map_texture_presets.py` turns it into `editor/runtime/lua/editor/mapsets.lua` (generated; `texsets.lua` and `recipes.lua` read it):
  1. every painted layer gets a kind of ground from the words of its texture name and from where it lies (a "grass" that lies on 30 degree slopes is rock; a dark sand that covers the flats is dirt);
  2. a map is a palette (kind -> texture); palettes whose textures are not in the game data are dropped (191 of 345 maps give a usable palette, the rest paint with their own files or fewer than four kinds);
     similar palettes are one cluster;
  3. the families (the environment of the main ground texture: Evergreen 2, Desert, Paradise, Red barrens, Tropical, Ancient earth, Evergreen, Swamp, Lava, Geothermal, Crystalline, Tundra) give 35 texture
     sets, the most used, most different palettes of each ("Evergreen 2: Operation Thor (7 maps)" ...);
  4. one **recipe style per family**, measured: the slope where the rock layers reach half and nine tenths of their weight (rock and cliff slope: 12 to 22 and 18 to 43 degrees; the defaults 34 / 52 were
     far too steep for what authors paint), snow share, the dirt share of flat ground, beach and wet strip from the sand and wet layers, dark rock, crispness of the masks (from 0.33 for Paradise to 0.5 for Evergreen 2).
* In the editor: Textures panel, **Texture set** menu: the built-in sets, then "Measured on your maps" with a submenu per family. Choosing a set also selects the recipe style of its family (the message says so).
  The Stratum recipes **Style** button is now a menu of all styles (the built-in ones, then `<Family> (from N maps)`). The sets of the maps are not used to guess the kind of ground of a texture (`RoleOfTexture` skips
  them: the same texture is another kind of ground on another map). `selftest_recipes` checks that every texture of every set exists, every style names a recipe knob inside its slider range.
* Open: the maps' tile sizes (`scale`) are collected but sets still use the Optimal tile size of `texscale.lua`; layer masks' noise scale (patch size) is not measured.
