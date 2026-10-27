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

## Operation Citadel (coop mission, World Machine workflow) measured as a reference (2026-10-26)

Map folder `Documents/My Games/.../Maps/Operation_Citadel.v0001`, read with `scripts/pylib/scmap.py`, opened in the editor (`cit` instance) and measured with `scripts/terrain_metrics.lua`.

* **Format**: 1025 x 1025 samples (20 km), height range 74 units (4.1 .. 78.3), water at 4.3. Shader **Terrain251**. Map-wide textures are files in `env/layers`: `mapInfo.dds` (lighting texture, 2048 x 2048 DXT5),
  `mapNormal.dds` (2048 x 2048 DXT5), `roughnessAndHeight.dds` (2048 x 2048, 8 bit). The two stratum mask textures are 1024 x 1024 DXT5. 8 strata (Crystalline textures, Red Barrens cracked normals), 12,625 props,
  971 decals, lighting multiplier 1.5. The editor's Map textures panel (cap 2048) covers every map-wide texture size this map has.
* **Terrain**: mean slope 8.7 degrees; ground steeper than 5 / 10 / 20 / 30 / 40 / 50 degrees: 53 / 27 / 11 / 4.7 / 2.0 / 0.8 percent. Relief (rms of H - blur(H, r)) r = 2 / 8 / 32 / 128: 0.12 / 0.65 / 2.4 / 5.8 units,
  i.e. **very smooth small scales** (the shipped `badlands` has 0.45 at r = 2, `canyon` 0.49, the Gaea terrain imported from cracked_basin 0.32, `hills` 0.14) and relief living in large shapes. Heights are not two-humped here
  (5/25/50/75/95 percentiles 6.9 / 18.8 / 23.5 / 28.7 / 44.6).
* **Paint**: very soft masks. Layer 3 (wet sand) covers 35 percent of the map with 44 percent of the map in transition, layer 2 (rock) 37 percent with 48 percent in transition; only layer 1 has hard areas (17 percent
  fully covered). The base layer is what is seen on 46 percent of the ground.
* **The map normal is the height normal at twice the resolution**: the one channel our image reader returns correlates -0.92 with the normal computed from the heights (per cell, 62,000 samples); what is finer than
  one cell is 1.5 percent of its variance. (Caveat: the reader returns one gray channel for DDS files; the x channel in alpha could not be read separately.) So the richness of this map is not baked micro relief: it is
  the strata normals of eight textures, soft masks, the lighting texture, props and decals.
* **Props by slope** (mean slope under the prop; the terrain's mean is 8.6 degrees): small rocks (CrysSmRock01..05, CrystalRock01..02, 8,300 props) 4.2 degrees, crystals (cryscrystal01..08, 2,000 props) 3.8 to 4.2,
  with the large ones (06 .. 08) on the flattest ground, the big cliff rocks (georock02 / 03, 1,850 props) 16 degrees with 27 to 31 percent of them on ground steeper than 20 degrees. One scatter class per size, driven by
  slope: small things on gentle ground, big rocks on the cliffs.

### Layered textures and the detail pass (2026-10-27)

Built from the Citadel numbers above; the terrain shape stays the Gaea one (the reference for playability), Citadel is the reference for the paint and the small things on top.

* **Layered textures** (`texsets.lua` `Variants`, `LayeredLayout`, `ApplyLayered`; button **Layered textures** in the Stratum recipes panel): the painted layers get several textures of one kind of ground. 8 painted layers: grass 2, rock 1, dirt 1,
  rock 2, wet 1, dirt 2, rock 3, wet 2 (7 layers without rock 3; the side-mapped layers 3 and 4 of the B shaders are rock; four painted layers: refused). `Variants[theme][role]` lists the other textures of a kind (Evergreen, Evergreen 2,
  Desert, Tropical); the recipe knows the kind of every layer from `Recipes.State.layerRoles` (written by `AssignLayered`, dropped when a layer's texture changes), because the colour detection can take a rock variant for dirt.
* **Recipe style Layered** and two new knobs: `mix` (how much of a kind a second texture of it takes, 0.55 = as before) and `soft` (blend width between kinds: every visible weight is blurred, the weights still add up to 1, more layers
  show at one texel). Style values: mix 0.8, soft 4, patch 36, rock from 20 / cliff 40 degrees, dirt 0.4.
* **Result on the imported Gaea terrain** (`scripts/mask_analysis.lua`; Terrain shader TTerrainXP, valley set): mean 2.46 to 2.75 layers blended per texel (Citadel 2.68; the natural style 1.51), 3 or more layers on 44 to 56 percent of the map
  (Citadel 54), masks softer than Citadel's (detail at one cell 0.00 to 0.01 against 0.05 to 0.09), rock follows the slope (0.8 to 0.9 correlation).
* **Detail pass** (`detail.lua`, button **Detail pass** in the Props scatter panel, `selftest_detail.lua`): five classes through the props scatter, each one undo step, each with the clustering noise of its own: small rocks (slope 0 to 14, 9.8 per 1,000 square
  units, minimum distance 6), big rocks (slope 6 to 55, 1.8), crevice and patch decals (slope 0 to 12, 0.7, 25 units), rock ground decals (slope 8 to 35, 0.17, 36 units), cliff face decals (slope 30 to 85, 0.25). Entries per environment: props are found in the
  props catalog by environment and name (they lie in subfolders such as /env/evergreen/props/rocks: `DiskGetFileInfo` does not see blueprints), decals are files. Density multiplier 0.5 / 1 / 2 (`Detail.Scale`, button). On the Gaea terrain
  (1025 map): 10,769 things in 3 s; the small rocks stand on 4.4 degrees of slope under them (Citadel 4.2, the terrain 8.6), the big ones on 32 to 36 degrees (the terrain is bimodal: flat or vertical; Citadel 16).
* **Not done**: the detail pass is not a graph node yet (the graph's own `Output: scatter props` still does one class); the flow, wear and deposit masks of Gaea are not mixed into the layered recipe; the Terrain2xx shaders (Citadel's family) show the
  recipe wrongly in the texture lab (a flat green picture: the lab does not make the roughness / height atlas they blend with), so the check was made with TTerrainXP.

### Erosion paint: texture masks made from the water (2026-10-27)

The user's World Machine / Gaea projects build the paint from erosion masks at high resolution; random noise patches and soft blurred transitions look wrong next to them. `erosionpaint.lua` does the same with the editor's own tools:

* **Masks**: `wear` (where the flow stripped the ground), `deposit` (where sediment settled: flat, downstream), `flow` (the drainage network). Imported ones (Interop panel, named masks) or the outputs of an erosion node (`erode_hydraulic` / `droplet` / `stream`: ports wear, deposit, flow, accum) are used as they are;
  without them they are made from the heights: `rockiness` (wear), topographic `wetness` times flat ground (deposit), D8 `flow`. A solver free stand-in, not the real thing.
* **Bands, not noise**: every mask is a threshold at a SHARE of the ground (`wear` 12 percent, `sed` 22, `chan` 7 by default; knobs), found by bisection on the field (`Above`), so it means the same on any map. The kinds with several layers are split by BANDS of the masks: the second rock is
  the strongest wear, the third rock the concave cavities on slopes, the second dirt the thickest sediment, the second wet ground the channel core, the second grass the ridge tops. (`recipes.lua` `Resolve` takes the variant fields `sel['rock#1']` ... before it falls back to noise patches.)
* **Crisp**: `edge` (a share of the mask's range, 0.012) plus two squeeze passes (`sharpen`): a threshold of a smooth gradient keeps a wide transition, the squeeze makes the edge the place where the mask crosses the threshold. An imported mask of lower resolution than the map stays soft at its own resolution.
* **Where**: recipe style **Erosion paint** (Stratum recipes panel, graph node `Ground kinds` style); the `Ground kinds` node has five new optional outputs (rock2, rock3, dirt2, wet2, grass2) and `Output: ground kinds` the matching inputs; graphs `Gaea / World Machine terrain, painted by the erosion masks`
  (`external_erosion`: imported masks) and `Eroded hills painted by the water` (`eroded_hills`: the hydraulic erosion node's own masks). Use **Layered textures** first so every kind has several textures to split between.
* **Cost** (1025 map, this PC): Apply of the Erosion paint style 0.8 s, Layered 0.5 s, Natural 0.5 s. Detail pass on 1025: 3.0 s for 10,700 props and decals.
* **Test**: `selftest_erosionpaint.lua` (thresholds find their share, variants and selections exist, edges narrow, the node ports). Visual check on the imported Gaea terrain: worn rock along the cliff tops, sediment streaks and the dendritic channel network as the wet layer.

### Oversample (2026-10-27)

The **Oversample** node gives the graph a finer grid (factor 1 to 8 times the map's) so the normal map, the lighting texture and the erosion masks can be made at a multiple of the map's resolution;
after an erosion node it runs the erosion again at the fine grid. Details, measurements and tests: MAP_TEXTURES.md ("Oversample"). For the erosion paint style the fine `wear` / `deposit` /
`flow` masks go through the Output nodes averaged down to the paint grid, so the bands are crisp.
