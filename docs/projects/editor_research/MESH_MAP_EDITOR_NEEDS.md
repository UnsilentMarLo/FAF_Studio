# What the FAF Studio needs for 3D mesh maps (`TerrainSystem = 'mesh'`)

Research note, 2026-10-17. Read-only study; no code changed. Evidence tags: **[verified]** read in a file named here,
**[inferred]** concluded from names or structure, **[open]** not checked. Paths are relative to the workspace root.
Companion docs: `docs/projects/TERRAIN_MESH_MAPS.md` (called TMM), `MAP_EDITOR.md`, `MAP_EDITOR_DESIGN.md` (ED).

## 0. Findings that change the plan

1. **"The binary patch" is four separate things, and the big one is not in FA-Binary-Patches.** [verified]
   - The **renderer** is a proxy DLL (`faultrep.dll`) built from `automation/terrainmesh/meshterrain.cpp` (3,281 lines).
     It detours the retail x86 exe at fixed addresses and draws with a raw `IDirect3DDevice9`; it runs only from a
     private test bin (`meshterrain.cpp:1-4`) and is render-only.
   - Three small **sim-side exe patches** live in the worktree `faf_repo/FA-Binary-Patches-mesh`, branch
     `marlo/mesh-void-structures-live` (HEAD `5ff28db`): `MeshTerrainFlattening`, `MeshVoidStructures` (committed) and
     `MapPropScale` (**untracked**: `git status` shows `?? hooks/MapPropScale.hook`, `?? section/MapPropScale.cpp`).
     The worktree's `README.md` and `changelog.md` say nothing about mesh terrain; the real documentation is TMM.
   - A **Lua mod** `my_mods/Mesh Terrain` (`ui_only`): sends `Display.TerrainCutout` to the renderer, restores LOD
     cut-offs flagged `Display.KeepLODCutoffs`, suppresses wrecks over the void.
   - A **map-side convention**: scenario flag, manifest, SCM patches, textures (section 1).
2. **The mesh is visual only.** Sim, pathing, picking, projectiles, reclaim, decals, range rings and fog of war keep using
   the `.scmap` height field. The mesh never feeds the sim. [TMM:1011-1012, TMM:865-866]
3. **For converted SC2 maps the sim height field comes from SC2's own `hfield` chunk, not from the mesh**
   (`convert.py:1148`). **No tool bakes a height field from a mesh.** That is the central new editor feature for maps
   that do not come from SC2 data.
4. **The manifest is not parsed as Lua.** The DLL reads it line by line with a tiny `key = value` scanner
   (`meshterrain.cpp:672-758`). The editor writer must emit exactly that dialect (section 1.3).
5. **Props lose their per-prop scale in the retail loader and in the editor's source engine.** The `.scmap` prop record
   has three scale floats; `CWldProps::Load` reads and drops them (`CWldMap.cpp:1235-1250`), `Save` writes 1,1,1
   (`CWldMap.cpp:1287-1289`), `CWldPropEntry` has no scale field (`CWldMap.h:60-67`). Saving a converted mesh map from
   the editor as it is today **destroys the scale of every converted SC2 prop**. [verified]

## 1. Data contract of a mesh map

### 1.1 Files

Map folder `/maps/<folder>/` (VFS path; any mounted folder or archive works, `meshterrain.cpp:11-12`):

| File | Required | Content | Producer today |
|---|---|---|---|
| `<folder>.scmap` | yes | FA map v2, writer minor 56 (reads 53-60). Heights (sim), terrain-type grid (blocking), water elevations, lighting, strata (from a template map), props, decals, preview | `convert.py:1193`, `scmap.py:1-26` |
| `<folder>_scenario.lua` | yes | `TerrainSystem = 'mesh'`, `TerrainMesh = '/maps/<folder>/terrain/terrain.lua'` | `convert.py:254-256` |
| `<folder>_save.lua` | yes | markers (`ARMY_n`, Mass, Hydrocarbon, AI markers) and `AREA_1` = playable rectangle | `convert.py:262-275` |
| `<folder>_script.lua` | yes | `OnPopulate`: `SetStructuresAvoidBlockingTerrain(true)`, `SetTerrainFlattening(false)` (both through `rawget(_G, ...)`), `ScenarioFramework.SetPlayableArea('AREA_1', false)` | `convert.py:276-293` |
| `terrain/terrain.lua` | yes | manifest (1.3) | `convert.py:985-1117` |
| `terrain/*.scm` | yes (>= 1) | SCM v5 patches (1.4) | `scm.py` |
| `terrain/textures/*.dds` | per material | diffuse, normal, specular, 3 light masks (1.5) | `convert.copy_textures` (`convert.py:346`) |
| `terrain/watermap.dds`, `watermap_outer.dds` | with water | A8R8G8B8 water depth/land maps bound to FA's water draw (1.6) | `convert.py:1006-1013` |
| `terrain/waterbeyond.bin`, `waterinside.bin` | with water | triangle lists, 6 floats (x,z for 3 corners) per triangle; file size must equal `triangles * 24` | writer `convert.py:1016-1024`, reader `meshterrain.cpp:933-945` |
| `<folder>_preview.png` | no | 512 x 512 | `convert.py:1188` |

Outside the map folder (a shared "home" mounted at `/`): `env/sc2/props/...` (converted props), `units/`,
`projectiles/sc2/`, `sounds/SC2.xsb`. A map of our own that uses stock FA props needs none of it.

Scenario-line rules (`MeshManifest`, `meshterrain.cpp:1116-1127`; `Field()`, `:672`): each of the two keys on **its own
line**, **single quotes**, the VFS path **absolute**. A double-quoted value yields an empty string and silently disables
the mesh. `TerrainMesh` embeds the folder name: Save As, rename and FAF's `*.v0001` versioning must rewrite it.

The unpatched game ignores both fields and draws the height field with the `.scmap` strata (`convert.py:246-247`). That
is the **fallback look** and must stay presentable.

### 1.2 What the `.scmap` must still carry, and why

The retail engine builds its terrain from the height field alone: `IRenTerrain::Create` picks Low/Medium/High by
`graphics_Fidelity` (`TerrainFactory.cpp:44-64`); `HighFidelityTerrain::Init` builds `CTesselator(heightField)`
(`HighFidelityTerrain.cpp:331-338`); `DrawNormals` (`:1270`) sets lighting, picks the stratum technique, sets the water
constants, calls `DrawTriangles()` (the surface), then the decal passes `TDecalGlowMask`, `TDecals`, `TDecalsXP`, splats,
glowing decals and overdraw. Decals are index/vertex ranges of the terrain's own sheets (`:1380-1415`), so **decals sit on
the height-field tessellation, not on the mesh**. [verified]

| `.scmap` content | Why a mesh map still needs it |
|---|---|
| Height field (u16 / 128, `STIMap::mHeightField`, `STIMap.h:872`) | Sim pathing, unit/prop height, projectile terrain hits, mouse picking (`CHeightField` line intersection, `STIMap.h:425`), decals, tessellator, range-ring/vision volume bounds, shadow-map fit |
| Terrain-type grid + blocking table (`STIMap.h:874-876`) | Void/blocked cells: no occupancy for land/hover/naval, nothing built there (`STIMap.cpp:2584`) |
| Water: enabled, elevation, deep, abyss (`STIMap.h:877-880`), water ramp and shader properties | FA's water pass and sheet; the manifest's `water`/`water_abyss` must equal them |
| Lighting (sun, ambient, shadow fill, bloom) | Units, FA props, decals and shadows keep FA lighting; the mesh uses the **manifest's** sun/shadow values (SC2 values) |
| Strata, normal map, masks | Unused by the mesh; used by the fallback look and by `ren_ShowNormals`. The converter copies a template map's |
| Props (+ scale), decals | Gameplay and look. Prop scale: section 0, item 5 |
| Preview chunk (256 x 256) | Lobby and FAF client; the converter writes SC2's minimap (`convert.py:1180-1188`) |
| Playable area | Not in the `.scmap`: set by the script (`SetPlayableArea`, `STIMap.h:873` `mPlayableRect`) and repeated in the manifest for drawing |

### 1.3 Manifest `terrain/terrain.lua`: the exact dialect

`LoadManifest` (`meshterrain.cpp:695-758`) walks lines. Per line, in this order: contains `mesh = ` -> patch; else
`water_map`, `water_map_outer`, `water_beyond`, `water_inside` -> file names; else `name = ` -> material; else any of the
numeric keys. Consequences the writer must respect:

- one entry per line; a settings line must never contain `mesh = ` or `name = `;
- keys match on a word boundary followed by ` = `; numbers are scanned as `[0-9.-]` only: **no exponent, no `+`**;
- strings are single-quoted; paths are relative to the manifest's folder (`g_dir + "/" + file`, `:908`);
- `version`, and per patch `vertices`, `triangles`, `min`, `max` are **not read** (`max` only as fallback for `mesh_high`,
  `:1141-1158`); keep them, the editor's own checks can use them;
- the manifest fails (FA's terrain stays) when it names no patches (`:757`, `:1213`).

| Key | Meaning | Reader |
|---|---|---|
| `size` | map side in world units | `:732` |
| `playable_x0/z0/x1/z1` | playable rectangle (outline on water); default whole map | `:731-732`, `:749-752` |
| `water`, `water_abyss`, `water_tint` | level; abyss (forced <= level - 1); 0 = no ramp tint on the ground (SC2's water colours it) | `:728`, `:746` |
| `water_map`, `water_map_outer`, `water_outer_min`, `water_outer_span` | depth/land textures bound for FA's water draw; the outer one covers the whole scenery square | `:706-709`, `:728-729` |
| `water_beyond`, `water_beyond_triangles`, `water_inside`, `water_inside_triangles` | water-plane triangles outside / inside the map square | `:710-713`, `:729-730` |
| `haze`, `haze_span`, `void_r/g/b` | canyon maps without water: the ground fades into the void colour below `haze`; also the void-fill colour | `:732-733` |
| `ground_low`, `ground_high` | lowest/highest ground units can stand on; range-ring/vision volumes start at `ground_low - 5`; reference for the decal pull | `:731`, `:2013-2036` |
| `mesh_high` | highest mesh vertex in the playable area plus a 32-unit margin; the ring/vision volumes reach `mesh_high + 30` | `manifest_heights.py:46-60`, `meshterrain.cpp:1144-1158` |
| `shadow_r/g/b/a`, `sun_x/y/z` (unit vector towards the sun), `sun_r/g/b` | SC2 lighting inputs of the mesh shader | `:734-737` |
| `materials = { ... }` entries | `name`; flags `blending`, `glow`, `highlight`, `additive`, `alpha_test = <0..255>`; slots `diffuse_a`, `diffuse_b`, `normal_a`, `normal_b`, `specular`, `specular_b`, `light_mask_0/1/2` | `:714-725` |
| `patches = { ... }` entries | `mesh = 'x.scm'`, `material = <1-based index>`, optional `sky = 1`, then informative fields | `:700-705` |

Material order is the patch `material` index (1-based). Sky patches (`sky = 1`) are drawn after everything, in manifest
order, without depth (`convert.py:1074-1092` orders them; `meshterrain.cpp:1334-1363` draws them).

### 1.4 SCM version 5 patch limits

Format (`scm.py:1-19`, `SScmFile.h`): `MODL`, version **exactly 5** (the renderer rejects anything else,
`meshterrain.cpp:961`), 68-byte vertices (`pos3 normal3 tangent3 binormal3 uv1(2) uv2(2) bone(4 x u8)`), **16-bit
indices**, 32-byte-aligned blocks each preceded by a 4-byte tag (`NAME SKEL VTXL TRIS INFO`, pad byte `0xC5`), one root
bone (identity matrix, every vertex bone 0), triangle list.

| Limit | Value | Evidence |
|---|---|---|
| Vertices per file | **65,535** | `scm.py:21`; check at `meshterrain.cpp:961`; real limit: the engine copies the file's 16-bit indices into a 16-bit GPU buffer (`HardwareMeshBatch.cpp:655-668`) |
| Index count | multiple of 3, each index < vertex count | writer; the renderer only range-checks offsets (`:961-962`) |
| Patch count | unbounded; **no frustum culling and no LOD**: every non-sky patch is drawn every frame (`:1299-1320`) | 0.3 ms per frame for 450k vertices (TMM:792) |
| Patch cut | by 256-unit map tile, sorted by (tile z, tile x) (`scm.py:36-62`), so a patch stays local | |
| Coordinates | **world space**; vertex y is real height, same 1/128 scale as the height field | TMM:946 |
| UV1 | tiling texture coordinate, any range, wrap addressing (s0, s1, s7-s10) | `:1286-1287` |
| UV2 | light-mask coordinate 0..1, clamp addressing (s2-s4) | `:1286-1287` |
| Tangent frame | needed for the normal maps. `scm.write` takes SC2's packed 10-bit words and **falls back to a flat frame (1,0,0)/(0,0,1)** without them (`scm.py:88-92`): a mesh of our own needs real tangents | |
| Bounds | unbounded; SC2 maps carry scenery from y -1,600 to 2,400 and x/z beyond +-4,000 (`sc2_mp_002` manifest) | |
| Size of real maps | 12,832 to 592,360 vertices per map, 20 patches for the largest | TMM:861, 939 |

### 1.5 Textures, materials, shader

The mesh shader is **our own inline HLSL**, compiled with `D3DXCompileShader` at start-up (`meshterrain.cpp:196-288`,
`821-874`; vs_3_0 / ps_3_0). It does **not** use a named `terrain.fx` technique. It copies FA's per-frame state **by
name** from FA's bound terrain effect: `ViewMatrix`, `ProjMatrix`, `TerrainErrorScale`, `ShadowMatrix` (vertex shader),
`ShadowSampler`, `WaterRampSampler`, `UtilitySamplerC` (pixel shader), through `D3DXGetShaderConstantTable`
(`:1001-1019`). FA technique names that matter for decals: `TDecals`, `TDecalsXP`, `TDecalGlowMask`,
`TDecalsWaterAlbedo`, `TDecalOverDraw` (`HighFidelityTerrain.cpp:1306-1310`, `:1330`).

Sampler map of the mesh pass (`:233-243`, `:1283-1312`):

| Sampler | Content | Addressing | If missing |
|---|---|---|---|
| s0 / s1 | `diffuse_a` / `diffuse_b` (sRGB content, converted with pow 2.2 in the shader) | wrap | white; b falls back to a |
| s2 / s3 / s4 | `light_mask_0/1/2`: baked light from three directions (Half-Life 2 basis) over UV2; **alpha of mask 0 = sun occlusion, alpha of mask 1 = blend weight between layer a and b** | clamp | grey, alpha 0 (first layer only, neutral light) |
| s5 | FA's shadow map (1024 x 1024 colour target, green = sun) | border | white |
| s6 | FA's water ramp | clamp | white |
| s7 / s8 | `normal_a` / `normal_b`: **SC2-style RGB tangent-space** normals (x,y,z in r,g,b, DXT1), unlike FA unit normal maps (x in green, y in alpha) | wrap | flat normal |
| s9 / s10 | `specular` / `specular_b` mask: r environment (unused), **g glow, b sun highlight** | wrap | white |

Loading: `D3DXCreateTextureFromFileInMemoryEx`, `D3DFMT_UNKNOWN` (keeps the file's format), mip levels 0 = full chain made
from the top level when the file has one (`:911-915`), `D3DPOOL_MANAGED`. Water maps: one level, `D3DX_FILTER_NONE`
(`:919-931`). Shader material constant `c4 = (blending, glow, highlight strength, alpha_test + 1)`; the global highlight
factor defaults to one half of SC2's (TMM:506). Material flags map to SC2's: `BLENDING`, `GLOW`, `ALPHA_TEST`,
`SPECULAR_LIGHTING`, `TerrainAdditiveState` (`convert.py:1046-1060`).

Texture rules learned the hard way (TMM:41-46, `pad_atlases`):
- a texture whose UVs stay inside 0..1 is an **atlas**; unused texels must be filled from the nearest used ones, per DXT
  4 x 4 block, without recompression, and the file keeps only its top level; otherwise a white line shows along every
  seam from mip 2-3 on (`convert.py:374-476`);
- tiled textures (UV outside 0..1) are left alone;
- DXT1 / DXT3 / DXT5 / A8R8G8B8 occur; the atlas pad code needs width and height multiples of 4 (`convert.py:454-457`).

### 1.6 Where the sim height field, water map and block grid come from

For SC2 conversions (`convert.py:1120-1193`):

| Output | Derived from | Step |
|---|---|---|
| Heights | SC2 `hfield` u16/128 | `ground_range` (`:511`): lowest/highest ground any movement layer can use; `tame_heights` (`:647`) clamps to that +-30; `height_shift` / `lower_map` (`:659-684`) lowers the whole map (field, mesh, markers, props, water, fog) so the field stays below **250**: FA's terrain vertices wrap at 256 and decals vanish above (TMM:439-441) |
| Terrain type (blocking = type 9, `Dirt09`) | SC2 cost grids, region != 255 in any layer = open | `terrain_types` (`:624`); `level_ground` (`:548`) also opens level mesh floor that SC2 blocked |
| Marker y | height field at x,z; resource markers snapped to x.5, z.5 (`snap_resource`, `:159`) | |
| Prop y | **mesh height**, not field (SC2 stands props on the mesh); a blocking prop more than 3 units from the field uses a "scenery twin" blueprint (`SCENERY_HEIGHT`, `:96`), because FA blocks the cell of a prop at any height | TMM:116, 133 |
| Water level | height of the water plane in the mesh, not the `info` chunk value | `water_setup` (`:479`), TMM:23-30 |
| Water map | mesh depth under the level, capped by horizontal distance to land, SC2 depth scale | `sea_floor` (`:810`), writes `watermap.dds`. **FA rebuilds its own water map from the height field at load and ignores the `.scmap`'s** (TMM:610-617), so the manifest map is bound over it |
| Preview | SC2 minimap | `:1180-1188` |

Fit between mesh and field on real maps: mesh y equals field / 128 at the median; 9,358 of 11,190 ground vertices of
`SC2_MP_002` within 1.0; on platform maps only 5-12 % of vertices lie on the field (TMM:908-909, 947-949); the field lies
up to one unit below the mesh (TMM:445). **No existing code derives a field from a mesh**: the editor must add it (F8).

## 2. What breaks or changes under mesh terrain

| Editor feature | Effect | Needed change |
|---|---|---|
| **Height brushes** | Edit the sim field only; the mesh does not move, so visible and walkable ground diverge silently | Mode switch "sim field / mesh". Brushes stay (to patch the proxy field) but show the divergence overlay (F10). Mesh edits are import/replace operations, not brushes |
| **Strata / masks / normal map** | Not drawn on a mesh map; they only shape the fallback look | Keep the layer UI; add a "fallback preview" toggle (height field + strata) to judge the unpatched look; hide the layer brush in mesh view |
| **Terrain-type brush** | Authoritative: blocking cells define the void | Keep; add "derive blocking from mesh" (F9). The overlay must draw against the mesh (depth-biased, see Decals) |
| **Decals** | Draped over the height-field tessellation; on cliffs, platforms and the void they streak down walls or show through ground. The patch needs three fixes: depth pull by a real distance (`DrawDecalNearer`, `meshterrain.cpp:2420`), a stencil band so a decal only lands where the mesh is within 1.5 units (TMM:454-461), the decal cull box raised from y 128 to 4096 (instruction `0x0089DF1B`, `:130-135`) | Port all three (P8). The decal tool previews with them on |
| **Water** | Level lives in the `.scmap`; the manifest repeats it and adds the mesh-derived depth map, outside/inside plane triangles and a playable outline on the water. FA draws water wherever ground is below the level, also over land | One water panel edits level/abyss and regenerates `watermap*.dds`, `waterbeyond/inside.bin` and the manifest keys together. A level mismatch between `.scmap` and manifest is a hard error (V12) |
| **Props** | Placement must follow the **mesh surface**, not the field (SC2 trees stand on cliffs 247 above it). Per-prop scale must survive (section 0, item 5). Blocking props away from the field need the scenery twin | Snap to mesh by ray; show field/mesh delta; offer the scenery twin automatically; scale in the inspector |
| **Pathing / buildability preview** | Computed from field + terrain type + occupancy, so correct for gameplay but not where the player sees the ground. Debug overlays place decal corners with `CHeightField::GetClampedSamplePoint` (`STIMap.h`, doc above the declaration; used by `RDebugGrid`) | Overlays need the same pull/band treatment or a mesh-aware projection; a "sim surface" ghost of the field helps |
| **Minimap / lobby preview / strategic view** | The preview chunk is a static 256 x 256 image. The strategic/cartographic terrain stays field-based [inferred from `Cartographic.h` reading the field] | New preview renderer: top-down ortho of the mesh limited to the playable area (F17). Tell the user the strategic view shows the field |
| **Symmetry** | Tools that mirror/rotate field and markers work; the mesh does not follow | Either symmetric by construction at import ("mirror patches" op with winding and tangent flip, light masks mirrored) or a validation note "mesh not symmetric" |
| **Camera / picking** | Picking and `GetMouseWorldPos` hit the field; on a mesh map the point under the cursor can be far from the visible surface | Pick against the mesh in the editor (ray vs. patch triangles, BVH built at import); keep a field pick for sim-style placement |
| **Shadows** | The mesh must cast and receive. The patch replaces the height field in the shadow depth pass (`DrawMeshDepth`, `HookDrawTerrainDepth`, `meshterrain.cpp:2179-2240`) | Port (P4). The light camera is fitted to the field in view + 8 (`Shadow::PrepareLightCamera`), so tall mesh casters may lose shadows [open, TMM:352-353] |
| **Range rings, fog of war** | Stencil volumes between the lowest field height - 5 and its highest; anything above the top gets a ghost copy. Fixed by raising the top to `mesh_high + 30` (`RaiseBand`, `:2013`) | Port; the two globals become members of the renderers |
| **Terrain flattening / craters** | The sim flattens the field under structures; invisible on a mesh | Honour `SetTerrainFlattening(false)` in the editor sim (P13) |
| **Fidelity** | Only the **high** fidelity class is hooked (TMM:877) | The editor forces high fidelity |
| **Lighting panel** | FA lighting does not light the mesh ground; the manifest's sun/shadow colours do | Add a "mesh lighting" group (`sun_*`, `shadow_*`) and a "copy from FA lighting" button |
| **Stencil budget** | Rings use bits 0..6, the decal band bit 6, cut-outs 4 bits, the water line marks use the frame alpha | Editor overlays (selection, brush ring) must not use stencil, or reserve a bit first (R5) |

## 3. Editor feature list for mesh maps (milestone M5, with M4/M7 parts)

**A. Project and manifest**
- F1 New mesh map / convert an existing map to mesh: creates the folder, the `TerrainSystem` / `TerrainMesh` lines
  (single quotes, own lines), a `terrain/` skeleton, and the script lines (`SetStructuresAvoidBlockingTerrain`,
  `SetTerrainFlattening`, `SetPlayableArea`, `rawget`-guarded).
- F2 Manifest editor (typed form over section 1.3) whose writer reproduces `convert.py` output byte for byte (`%.2f`,
  key order, one entry per line); the reader accepts the same dialect and **warns** about anything else. Folder rename
  rewrites the absolute `TerrainMesh` path.

**B. Mesh import and patching**
- F3 Import mesh (OBJ / glTF / FBX through the M7 converters; our SCM v5 reader/writer in C++, golden-tested against
  `scm.py`): units, y-up, handedness, winding; drop or flag degenerate triangles; recompute normals and **tangents**
  (never the flat frame); optional second UV set for light masks.
- F4 **Split by tile** into patches of <= 65,535 vertices (reproduces `scm.split`; tile size and budget are parameters;
  show the patch map and vertex count per patch). One patch has exactly one material, so split by material first.
- F5 Material assignment: per sub-mesh choose a material; material editor for the flags (`blending`, `glow`,
  `highlight`, `additive`, `alpha_test`) and the nine texture slots with thumbnails; presets "single layer" and "two
  layers + masks (SC2)"; assign by triangle selection or UV island.
- F6 Texture tools: DXT1/3/5 and A8R8G8B8 conversion, **mip generation**, **atlas padding** (port of `pad_atlas`),
  normal-map re-encoding between the FA and SC2 conventions, resize to powers of two.
- F7 Light-mask baker (later): three directional masks over UV2, sun occlusion in alpha 0, layer blend in alpha 1.
  Without it the shader runs neutral light (grey masks with alpha 0, `meshterrain.cpp:889-895`).

**C. Sim field, walkability, water**
- F8 **Bake the sim height field from the mesh.** Top-down ray cast per field sample (the field is sampled bilinearly on
  a 1-unit grid, `CHeightField`, `STIMap.h:218-224`) against the walkable layer of the mesh:
  - choose the layer by material tag "walkable", by slope limit (default about 45 degrees, normal.y > 0), or by "highest
    triangle below a ceiling"; samples without a walkable hit get `ground_low - margin`;
  - platform/bridge/overhang maps: the field keeps one height per cell (BRIDGES.md:5-12), so the upper deck wins unless
    tagged otherwise and the rest is marked blocked;
  - converter rules as options: clamp to ground +-30 (`tame_heights`), lower below 250 (`height_shift`), `level_ground`;
  - writes the field, `ground_low`, `ground_high`, `mesh_high`, and a **divergence map** (mesh minus field).
- F9 Derive terrain-type blocking from the mesh: no walkable surface, too steep, or a "void" material -> blocking type 9;
  manual brush overrides stay; overlay preview.
- F10 Divergence overlay and report: where field and mesh differ by more than a threshold (default 1.0 unit, what SC2
  maps show), statistics per material, worst cells, "sink/float" check of markers and structure footprints.
- F11 Water setup: level from a chosen horizontal mesh plane or numeric; abyss; generate `watermap.dds` (depth under the
  level, capped by horizontal distance to land, colour lerp 0..0.8, scale parameter like SC2's `WaterScales.z`),
  `watermap_outer.dds`, `waterbeyond.bin`, `waterinside.bin` (clip the water plane against the map square,
  Sutherland-Hodgman as `clip_water_plane`, `convert.py:896`), `water_tint`; preview of the playable outline on water
  (`DrawBorderOnWater`, `meshterrain.cpp:2059`).
- F12 Playable rectangle: one control writes `AREA_1`, `playable_*` and the script line, draws the rectangle in the
  world, warns when it exceeds the map or the mesh does not cover it.

**D. Cut-outs, props, markers**
- F13 Cut-out preview: list the blueprints with `Display.TerrainCutout` (single table or list of `{SizeX, SizeZ, OffsetX,
  OffsetZ, Depth}`), draw the rectangles, show the pit when a structure is placed; helper "derive from portal bones" for
  unit meshes (port of `sc2units.portal_cutouts`). The cut-out is visual only, no sim effect (TMM:1012-1013).
- F14 Prop snapping to the mesh with the scenery-twin rule; keep per-prop scale (needs P12); show `KeepLODCutoffs`.
- F15 Markers: y = field height at x,z; resource markers snapped to x.5, z.5; check they stand within tolerance of the mesh.

**E. Views, render, export**
- F16 View switch: mesh | field (fallback look with strata) | both overlaid | divergence heat map | patch colour |
  material colour | UV2 / light-mask view | vertex-budget bars.
- F17 Preview render: top-down ortho of the mesh inside the playable rectangle, 256 x 256 into the `.scmap` preview and
  512 x 512 PNG.
- F18 Validation panel (below) and **Export for the patched retail exe**, with an optional round trip (re-import the
  written folder and compare).
- F19 "Run in game" through the existing harness (`scripts/meshmaps/play.py`) for a side-by-side screenshot of editor and
  retail renderer.

### Validation rules (E = hard error, W = warning)

| # | Rule | Sev | Source of the rule |
|---|---|---|---|
| V1 | SCM header `MODL`, version 5, offsets inside the file, `vertexCount <= 65,535`, `indexCount % 3 == 0`, every index < vertexCount | E | `meshterrain.cpp:955-965` |
| V2 | One material per patch; `material` in 1..#materials; every listed material is used | E/W | `:703` |
| V3 | Normals unit length; tangent/binormal unit and orthogonal to the normal; no NaN/inf; no degenerate triangles | W | normal-map shading |
| V4 | UV2 inside 0..1 when light masks are used (clamp sampler); an "atlas" texture has UV1 inside 0..1 | W | `:1286-1287`, `convert.py:422` |
| V5 | Referenced textures exist; format DXT1/3/5 or A8R8G8B8; width/height multiples of 4; powers of two recommended; mip chain present or a note that D3DX generates it | E/W | `:911-916` |
| V6 | Atlas padding: unused cells (by UV coverage) differ from the nearest used cells -> fail with a fix button | W | `convert.py:422-476` |
| V7 | `alpha_test` material: the diffuse alpha has both transparent and opaque texels; a texture with transparent alpha but no flag draws solid (known list `ALPHA_TEST_FIXES`, `convert.py:542`) | W | TMM:508-520 |
| V8 | Normal-map convention matches the shader (RGB tangent space); detect FA-style x-in-green/alpha maps | W | `:256` |
| V9 | `playable` inside `[0,size]`, `x1 > x0`, equals `AREA_1` and the script's `SetPlayableArea` | E | `:749-752`, `convert.py:289-293` |
| V10 | The mesh covers the playable rectangle (ray hit on >= 99.9 % of cells) | W | |
| V11 | `size` equals the `.scmap` size (heights are size + 1 samples) | E | |
| V12 | `water` / `water_abyss` equal the `.scmap` water elevations; abyss < level; no water -> no water keys and no water files | E | `convert.py:1150`, `water_setup` |
| V13 | `water_map` has the grid size the loader expects (half resolution [inferred, TMM:618]); `water_*_triangles` match file sizes | E | `:933-945` |
| V14 | Height field maximum <= about 250 (decals vanish beyond the 16-bit wrap at 256) | W | TMM:439-441 |
| V15 | `ground_low` / `ground_high` equal min/max of the walkable field cells; `mesh_high` equals the highest mesh vertex in playable + 32 | W | `manifest_heights.py:46-60` |
| V16 | Mesh vs. field divergence above threshold on a walkable cell; markers or footprints off the mesh; props more than 3 units from the field without a scenery twin | W | F10, `convert.py:96` |
| V17 | Blocking cells vs. mesh floor: a walkable mesh floor over a blocking cell, or a void over an open cell | W | `level_ground` |
| V18 | Manifest dialect: no exponents, no double quotes, no `mesh = ` / `name = ` on settings lines | E | `Field()` `:672` |
| V19 | Scenario lines single-quoted on their own lines; `TerrainMesh` path matches the folder | E | `:1116-1127` |
| V20 | Texture memory and patch count budget (informative; the patch draws everything) | W | `:1299` |

## 4. Engine-in-editor: what to port from the patch, and how to stay compatible

The editor links the recovered engine (`engine_decomp/faf-re-upstream/src/sdk`), so no detours are needed. A
`MeshTerrain` object plugs in where the retail patch hooks: preferably a fourth `TerrainCommon` implementation, or a
decorator around `HighFidelityTerrain`, chosen in `IRenTerrain::Create` (`TerrainFactory.cpp:44`) when the loaded map
carries the flag (TMM:995-999). The 15 vtable slots are documented in the class comment of `TerrainCommon.h`.

| P | Behaviour | Patch source | Where it lands in the engine tree |
|---|---|---|---|
| P1 | Activation: scenario `TerrainSystem == 'mesh'` + `TerrainMesh`, read at map load through the VFS; per-map teardown | `meshterrain.cpp:1116-1127`, `:1162-1217`, `HookMapLoad :2710` | `CWldMap::MapLoad` / scenario info. The editor needs no line parser for its own state but **must write the same dialect** |
| P2 | Surface: replace the heightfield draw by the patches; two-layer blend, three light masks, RNM, SC2 lighting in linear space, tone roll-off, water-ramp tint, haze, FA shadow map, glow in frame alpha (0.4 x glow) | `:196-288`, `:1224-1389` (`DrawMesh`) | `HighFidelityTerrain::DrawTriangles` (`HighFidelityTerrain.cpp:1558`), called by `DrawNormals` |
| P3 | Camera: exactly the terrain camera including `TerrainErrorScale` (1.0005) | `:1038-1094` (read back from shader constants) | `mCamera` of `HighFidelityTerrain`; no read-back needed |
| P4 | Shadow receive (FA map, `ShadowMatrix`, green channel) and cast (mesh into the light-camera pass with the diffuse alpha test) | `:1097-1113`, `:2179-2240` | `HighFidelityTerrain::DrawTerrainDepth` (`:1478`) |
| P5 | Skip the heightfield skirt, the black band outside the playable area (`func_RenBoundary`), FAF's world border (`MapImager::AddBorder`) and FA distance fog on mesh maps | `:2935`, `:2762`, `:2919`, `:2768` | `DrawTerrainSkirt` (`:1510`), `BoundaryRenderer.cpp:165`, `MapImager.h:66`, `WRenViewport::FogOn` (`WRenViewport.h:434`) |
| P6 | Void fill (water to the horizon / haze colour at the far plane); SC2 sky pieces | `:1321-1363` | after the surface draw |
| P7 | Water: swallow FA's sheet on maps without water; bind `watermap.dds` to the water shader's `UtilitySamplerC`; draw outside/inside water planes with the same shaders (`DrawWaterBeyondMap`); only the alpha-mask half of `DrawWaterLine`; `MarkAboveWater`; ring marks before/after the range-ring pass; playable outline on water | `:2163-2175`, `:2252-2317`, `:2319-2360`, `:2370-2400`, `:3031-3110`, `:2059-2095` | `HighFidelityTerrain::DrawWaterTerrain` (`:1419`), `DrawWaterLine` (`:1460`), `moho/terrain/water/` |
| P8 | Decals on a mesh map: view-space pull by a real distance (`g_groundDistance`), stencil band, cull box 4096 instead of 128 | `:2420-2548`, `:130-135`, TMM:438-461 | `DrawDecalPass` (`:1101`), `CWldTerrainDecal::Update` (`CWldTerrainDecal.cpp:874`) |
| P9 | Range-ring and vision volumes from `ground_low - 5` to `mesh_high + 30` | `:2013-2036`, `:2402-2410` | `RangeRenderer::Init` (`RangeRenderer.h:121`) and `VisionRenderer::Init` |
| P10 | Cut-outs: `Display.TerrainCutout` list; stencil mark by drawing the mesh again clipped to the rectangles (16 per bit, 4 bits); pit drawn after the decal passes with depth left at far; hidden with the entity's mesh instance (fog of war) | `:1391-2010`, console channel `HookConExecute :2927`, `my_mods/Mesh Terrain/hook/lua/ui/game/gamemain.lua` | blueprint scan at game start, entity list from the session; in source read `RUnitBlueprint` directly and drop the console channel |
| P11 | Prop light: props drawn in SC2's light when the specular sampler holds the marker texture `/env/sc2/props/black.dds` | `:2549-2602`, `sc2props.PROP_MARKER` | mesh batch constants (`Mesh.cpp`, `MeshBatch.cpp`); only for SC2 props, optional for our maps |
| P12 | **Prop scale from the map record** | `FA-Binary-Patches-mesh/section/MapPropScale.cpp:1-117`, `hooks/MapPropScale.hook` (`0x00891B21`, `0x007447CC`) | add scale to `CWldPropEntry` (`CWldMap.h:60`), read it in `CWldProps::Load` (`CWldMap.cpp:1235-1250`), write it in `Save` (`:1287-1289`), apply in `Sim::Setup` (`Sim.cpp:7066`) through the entity draw-scale setter. Same bounds as the patch (> 0, < 1000, 1,1,1 = no change) |
| P13 | Terrain flattening switch: `SetTerrainFlattening(false)` makes `Sim::FlattenMapRect` return; every sim starts with it on | `section/MeshTerrainFlattening.cpp:12-40`, hook `0x0074B120`; reset `section/RangeRings2.cpp:9-10` | `Sim::FlattenMapRect` (`Sim.cpp:23701`); register the Lua function; reset at sim creation |
| P14 | Structures refuse blocking terrain: `SetStructuresAvoidBlockingTerrain(true)`; mobile units already refuse via `OCCUPY_MobileCheck` | `section/MeshVoidStructures.cpp:13-90`, hook `0x005652E0` | `OCCUPY_Check` (`STIMap.cpp:3553`). Fields the patch reads: terrain-type grid `STIMap+0x1428`, blocking `+0x1434`, footprint `blueprint+0xD8/+0xD9`, `MotionType +0x290` |
| P15 | Lua mod behaviour: LOD cut-off restore (`KeepLODCutoffs`), no wreckage over blocking terrain | `my_mods/Mesh Terrain/hook/lua/system/Blueprints.lua`, `hook/lua/sim/Unit.lua:1-14` | load the mod in the editor project (editor mod list, ED rule 8) |
| P16 | Free cinematic camera (SC2 campaign) | `:2779-2916` | **skip** (campaign only) |

**Keeping the export compatible with the patched retail exe**

1. The format **is** the contract (section 1). Pin it with golden files: `convert.py SC2_MP_002` output (manifest,
   `section*.scm`, scenario lines) must be reproducible byte for byte by the editor writer from the same data, and the
   editor must open every converted map in `SupCom_MeshMaps/maps/`. Reuse `scripts/tests/test_meshmaps.py` and
   `test_manifest_heights.py` as the oracle (ED rule 9).
2. Export only what section 1 lists. Editor-only data goes into a sidecar (`<folder>_editor.lua` already exists for the
   mod list) or Lua comments; unknown keys must round-trip untouched (the DLL ignores them).
3. The sim patches change the sim (`FlattenMapRect`, `OCCUPY_Check`) or entity state (prop draw scale). A map should
   state its **patch level**; otherwise players on an unpatched exe diverge (flattening on vs. off, void structures
   allowed). Validation should say so. [open: whether FAF's lobby could refuse a mismatch; unknown scenario fields are
   ignored, TMM:1014-1016]
4. The patch is high-fidelity only; test every export on the **patched retail test bin** (`binpatch.py meshterrain`,
   `play.py`) with screenshots from both renderers.
5. Keep the shader maths identical (linear-space lighting, `Params` / `Material` constants). Treat `meshterrain.cpp:196-288`
   as the reference implementation; compare screenshots at fixed cameras.
6. Never rewrite what the editor does not understand: a converted SC2 map's props (scale), water maps and unknown
   manifest keys stay as they are.

## 5. Risks and open questions

**Risks**
- R1 **Prop scale loss** (section 0, item 5; P12): fix before any mesh map is saved from the editor; add a "scales
  preserved" round-trip test next to `map_editor/tests/test_scmap_roundtrip.py`.
- R2 **No height-field bake exists, and the problem is under-determined** on platform, bridge and overhang maps (one
  height per cell). It needs a user decision on the default rule and the divergence report (F8, F10). The 1-unit gap seen
  on SC2 maps shows the error the decal pull hides.
- R3 **Decals and overlays depend on a chain of workarounds** (pull, band, cull box, stencil bits), each found through user
  bug reports (TMM:438-461). Porting them without the same test scenes (Shiva Prime, Clarke Training Center
  `--void-test`, Tourney Dome) reintroduces those bugs.
- R4 **Device access**: the DLL talks to a raw `IDirect3DDevice9`, saves and restores a full state block around its draw
  (`meshterrain.cpp:1240`, `:1364`) and reads FA's state back from shader constants. The editor wraps the device in `gal`
  classes; decide between the native device (fastest port) and `gal` calls (cleaner). D3DX is the June 2010 SDK for x64.
- R5 **Stencil and alpha budget**: rings (bits 0..6), decal band (bit 6), cut-outs (4 bits), frame alpha as FA's bloom input
  and water mask. Editor overlays that touch them corrupt the picture. Allocate bits before M2.
- R6 **Hand-written manifest dialect** breaks the first time an editor writes `1e-05` or a double quote: a dialect-locked
  writer and V18 are mandatory.
- R7 **Performance**: no culling or LOD (all patches every frame, 0.3 ms at 450k vertices). Live mesh editing can grow the
  budget; per-patch culling with the stored `min/max` is cheap to add.
- R8 **Mixed-exe multiplayer**: the sim patches are not render-only, see item 3 of the compatibility list.
- R9 **Content**: converted SC2 maps and props must never enter the repo or an upload (TMM:1074-1075; `convert.py:1245`
  refuses an output root inside the repo). The editor's import/export dialogs need the same guard.
- R10 **SC2-only shader features** (sun highlight, `additive`, `INFINITE_DISTANCE` sky, glow) exist for SC2 fidelity; our
  own maps may not need them. Keep them readable and writable, hide them in the UI by default.
- R11 **Strategic view and minimap** of mesh maps stay field-based [inferred]; they will disagree with the 3D view.

**Open questions**
1. Default rule for the field bake: top surface, walkable material tag, or slope limit; is a manual field brush enough for
   corrections? (F8)
2. Do maps of our own use SC2-style materials (two layers, three baked light masks, SC2 normal maps) or do we add a simpler
   "albedo + normal + AO" material to the renderer? This changes manifest and shader. [open]
3. Is the light-mask baker (F7) in scope, or are neutral masks accepted for maps of our own?
4. Should the manifest become real Lua in a later renderer version (`version = 2`, dual reader in the DLL) or stay
   line-oriented?
5. Commit the untracked `MapPropScale` patch and upstream the three exe patches (PR text:
   `automation/terrainmesh/PR_FA-Binary-Patches.md`)? The editor's compatibility story depends on it.
6. How does a mesh map enable the **Mesh Terrain UI mod** in the lobby (open at TMM:1049)? The map folder cannot carry
   hook files; export may need a "requires mod" entry and an install note.
7. Does the shadow-map fit clip tall mesh casters (`Shadow::PrepareLightCamera`, TMM:352-353)? [open]
8. Should the nav/pathing overlay project onto the mesh in screen space instead of through decal geometry? [open]
9. Confirm the editor forces high fidelity and that its fallback-look preview uses the same class.
10. Per-vertex mesh editing (sculpt) or strictly import / bake / validate? `MAP_EDITOR.md:22-24` says "not editing the mesh
    itself"; this note assumes that and lists only import-side operations.

## 6. Suggested order of work (fits ED section 3)

1. Groundwork: stencil bit allocation (R5); prop scale in `CWldPropEntry` with round-trip test (P12, R1).
2. M5a (read-only): open a converted mesh map; manifest reader, C++ SCM reader, `MeshTerrain` surface pass (P2-P6),
   field/mesh toggle; golden test: editor render vs. patched-retail screenshot at fixed cameras.
3. M5b: water (P7), decals (P8), range rings (P9), shadows (P4).
4. M5c: authoring: import, split, materials, textures (F3-F6), manifest writer (F2), validation panel (V1-V20).
5. M5d: field bake and divergence tooling (F8-F10), preview render (F17), cut-out preview (F13).
6. M5e: light-mask baker (F7), sky/haze/void options, remaining SC2 look-alike features.

Files consulted: `docs/projects/TERRAIN_MESH_MAPS.md`, `BRIDGES.md`, `MAP_EDITOR.md`, `MAP_EDITOR_DESIGN.md`;
`scripts/meshmaps/{scm,convert,scmap,sc2map,manifest_heights}.py`; `automation/terrainmesh/meshterrain.cpp`;
`faf_repo/FA-Binary-Patches-mesh/{hooks,section}/{MapPropScale,MeshTerrainFlattening,MeshVoidStructures}*`;
`my_mods/Mesh Terrain/`; `engine_decomp/faf-re-upstream/src/sdk/moho/{terrain,sim,mesh,resource,render}`; a real manifest
in `~/Documents/SupCom_MeshMaps/maps/sc2_mp_002/terrain/terrain.lua`. `FLOWFIELD.md` has no mesh content (path planning
reads the sim field and occupancy only). No mesh map exists in `my_maps/`.
