# Texturing for any shader, recipes, generators and map sizes (2026-10-24)

What changed in one pass, why, and how it was checked. The code is in `editor/runtime/lua/editor/` (recipes.lua, roledetect.lua, texsets.lua, maskgen.lua, maptextures.lua, texconv.lua, stratumconv.lua,
graphnodes*.lua, graphrun.lua, maps.lua, gui/dialogs_map.lua, gui/startscreen.lua); the checks are `selftest_shaders.lua` (82 checks) plus the existing recipe / maskgen / maptextures / strataconv / graph tests;
the pictures were made with `python scripts/texture_lab.py` (below).

## 1. Maps of any size (start screen, File > New map)

The terrain is 128 ... 4096 samples a side (powers of two). A map of any other size is a blank terrain of the next power of two with the **playable area** (AREA_1, `playable.lua`) cut to the size asked for,
in the middle of the terrain, and the start position in the middle of the area. `maps.lua CustomPlan(widthKm, heightKm)` makes the plan (terrain, template, area in units, share of the terrain used),
`NewCustom` creates the map (the plan goes through the pending file: `name=` and `playable=x0,z0,x1,z1`, applied by `ApplyPending`). 1 km = 51.2 units. The start screen has an **Any size...** tile and File > New
map an **Any size...** button: `dialogs_map.lua NewCustomMap` (width and height 1 ... 80 km as sliders with preset buttons, a picture of terrain and playable area, the numbers, a note when most of the terrain
stays unused). A size that is a terrain needs no playable area. `Maps.NewKm` is `NewCustom(km, km)`. Not done: non-square terrain (the editor's tools assume a square), so 7.5 x 12 km uses a 1024 terrain.

## 2. Stratum recipes

Problems found by looking at the pictures (mountains, hills, badlands, dunes, plains; temperate, desert, tundra, tropical sets):

* **Rock and dark rock were swapped** (the file names `SandRock_albedo` and `RockMed_albedo` fool the name rules), and sets such as the desert one were only half recognised. Textures of the editor's own sets are now
  known exactly (`texsets.RoleOfTexture`, used first by `roledetect.Layers`); the name and colour rules are only for other textures.
* **Wet ground and sand covered whole plains** (height bands next to the water level). Sand and the wet strip now use a band **along the ground** (`maskgen` rule `shoredist`, width in units, shallow water in front of it);
  wet ground needs a drainage channel (strong flow in a concave channel on flat ground) or the waterline strip.
* **Snow and high rock on flat country.** Altitude counts by the absolute relief (`recipes.AltFactor`: nothing under 18 units, full from 60); the Alpine and Arctic styles ignore it.
* **Blobs.** Edges follow a noise (`maskgen` modifiers `crisp` = ragged edge, `grain` = variation at texture size); knobs *Edge crispness* and *Fine grain*.
* **A run left the old snow behind.** Kinds the style or the map does not have are cleared from their layers.
* Defaults: rock slope 34 degrees, cliff 52 (was 28 / 45: everything of a mountain was rock).

## 3. The layout of the kinds of ground per shader

`texsets.Layout(profile)`: 8 painted layers (TTerrainXP): grass 1, rock 2, sand 3, dirt 4, wet 5, high rock 6, dark rock 7, snow 8. 7 layers (Terrain0xx / 1xx / 2xx): no dark rock, snow 7. 4 layers (TTerrain,
TTerrainGlow): rock 1, sand 2, dirt 3, snow 4 (grass is the base). **Biplanar** (the B shaders draw layers 3 and 4 from the side only): rock 3, high rock 4, sand 2, dirt 6. `TS.Apply` (new map, texture set),
`recipes.AutoLayers`, `RoleOfTexture` and the graph's ground kind output use it. A kind on a side-mapped layer only gets steep ground (slope gate in `recipes.Weights`; high rock has no flat floor there).

## 4. Generators for what a shader needs (`maptextures.lua`, Map textures panel, graph output nodes)

| Picture | Shaders | Made from | Node |
|---|---|---|---|
| macrotexture (Upper layer RGB + opacity, one repeat over the map) | TTerrain, TTerrainXP, TTerrainXPExt, Terrain000 / 050 | the colour the paint shows (average colour of each layer weighted by what it shows), broad light and dark patches, darker cavities | Output: macrotexture |
| specular (Upper layer RGB colour + A sharpness) | Terrain001 / 051 | wet ground, snow and the waterline shine, rock and sand do not | Output: specular texture |
| roughness / height atlas (Upper layer) | Terrain1xx / 2xx | the layer textures and the kind of ground of each: heights biased rock > grass > wet (`texconv.ROLE_HEIGHT`) | Output: roughness / height atlas |
| roughness multiplier (mask of layer 8, 128 = neutral) | Terrain1xx / 2xx | rock, sand, dirt rougher; wet ground and snow shinier; or a wired mask | Output: roughness mask |
| Splat settings (map SpecularColor) | Terrain2xx | Lighting panel: Splat softness, height contrast, rotation | |

`Recipes.Apply` also sets the roughness mask on the PBR shaders (button *Roughness too*), in the same undo step. The graph outputs run after the layer outputs, so they see the paint of the same Build.
**Output: ground kind** (`out_role`) writes a mask to the layer that holds that kind of ground (found by `recipes.Plan`, else the layout of the shader), gives an empty layer its texture, and skips (with a note)
a kind that is the base layer or has no layer in the shader. The shipped graphs are loaded with their `Output: texture layer` nodes turned into ground kind nodes (`graph.lua LoadPreset`).

## 5. Layer conversion between shaders (`stratumconv.lua`, `texconv.lua`)

Fixed: the roughness / height atlas was always made of neutral tiles (the native reader was given VFS paths, `texconv.Disk`), and the TTerrain alpha conversion never wrote a file. New: atlas heights follow the kind of
ground; the cliff layers of a biplanar target are chosen with the kind of ground of the layers (rock first); normal tile sizes of a 2xx target are set to the albedo tile; the Splat settings have sliders.
Refused: Terrain301 (retired first version of the splatting; the message says to choose Terrain200 / 250). Not carried: the Upper overlay (macrotexture) of the old shaders into the 1xx / 2xx (their macrotexture is
the base layer's own alpha): make a new one with the generators.

## The texture lab

`python scripts/texture_lab.py --out DIR --cases mountains:temperate:1,hills:desert:3 --views top,oblique,low,close [--shader Terrain250] [--post "<lua>"] [--no-water] [--map 512]` generates a terrain,
applies a texture set and a recipe style, and photographs the real engine view with the editor UI hidden; it also prints the share of each kind and the mean of every kind's selection. `scripts/contact_sheet.py`
puts pictures side by side. Use `MSYS_NO_PATHCONV=1` when passing a `/maps/...` path from Git Bash. A Lua syntax error in a command sent to an instance (for example a `[==[` long string, which Lua 5.0 does not
have) makes the command channel hang until its timeout.
