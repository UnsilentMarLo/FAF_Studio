# Research: baked lighting (FAF community approach, SC2 light masks) and a single baker for the FAF Studio

Status: research, 2026-10-17. Read-only analysis; nothing was built or run. Feeds `MAP_EDITOR_DESIGN.md` sections 12 and 15
(open decision 6, "light-mask baker in scope, recommended M5b") and `MESH_MAP_EDITOR_NEEDS.md` F7.

Tags: **[V]** read in source / data, **[I]** inferred, **[O]** open. Evidence paths are workspace-relative unless a URL is
given. Upstream sources were read from a partial clone in the session scratchpad (not kept in the workspace):
`github.com/FAForever/FAForeverMapEditor` at `4723aa3` (2026-10-11, tags up to v1.2) and the local
`faf_repo/Neroxis-Map-Generator` (HEAD `10b13083`, 2026-09-12). `FAForever/FAForeverMapEditor` is the maintained fork of
`ozonexo3/FAForeverMapEditor`; the repo page says it was forked from the latter.

## 0. Short answers

1. **There is no "lightmap" in FAF.** The community's baked lighting is the **terrain info texture** ("map info texture"):
   one map-wide RGBA texture, `env/layers/mapInfo.dds`, loaded into the **Stratum 7 albedo slot** of the `.scmap`. The
   terrain shaders read **A = baked sun shadow** and **G = baked ambient occlusion** from it (R is water depth for the
   `Terrain*B` shaders, B unused). It is applied in the shader, so **no binary patch** is needed. [V]
2. **The FAF Map Editor does not contain a baker.** It shells out to `neroxis-toolsuite export-map-info` (Neroxis Map
   Generator) and displays the result with a re-implementation of the game shader. That baker is a **height-field-only
   horizon march for the shadow channel; the AO channel is a constant 255**. No props, no units, no real AO. [V]
3. The older community method (Neroxis "legacy" shader, still in the code) bakes shadows into a full-map **decal**
   (`map_shadows.dds`, type `WATER_ALBEDO`). [V]
4. **SC2 light masks are a different thing**: three RGB radiosity-normal-map (Half-Life 2 basis) light maps over a unique
   **UV2 atlas** per material, with sun occlusion in alpha 0 and the two-layer blend weight in alpha 1. Direct sun, sky
   and bounce are all baked into RGB. [V]
5. **One baker is feasible** if the core is split into three parts: scene rays (height field + props, or triangle BVH),
   sample domain (ground grid, or UV2 texels), and an output encoder (info texture, or RNM masks). Recommended order:
   FA info texture first (about 11-14 days incl. incremental preview), mesh masks second (about 10-14 days). Section 4.

## 1. What "baked lighting" means in FAF and in the FAF Map Editor

### 1.1 Terminology and history

| Date | Event | Evidence |
|---|---|---|
| by 2021-07 | Neroxis map generator writes `map_shadows.dds` (+ `map_normals`) as full-map decals; `TextureGenerator.setCompressedDecals` | `Neroxis-Map-Generator/generator/.../texture/TextureGenerator.java:112-117`, `shared/.../exporter/SCMapExporter.java:287-305` [V]; `compressShadow` first appears in commit `fefe9464` (2021-07-04); `7059ba02` (same day) takes shadow colour and opacity from the lighting settings [V] |
| 2023-06-24 | Game patch 3758 post: "allow map authors to add map-wide normals and map-wide shadows that are part of the rendering pipeline of the terrain, instead of 'plastered' on top" (PRs #4902, #4972) | `faf_repo/fa/docs/_posts/2023-06-24-3758.md:164-168` [V] |
| 2023-09-02 | Patch 3765 announces "advanced map shaders": "shadows, ambient occlusion, normals, and albedo textures directly into the terrain ... rather than applying them on top of the terrain, as decals typically do" | `faf_repo/fa/docs/_posts/2023-09-02-3765.md:49` [V] |
| 2023-11-04 | Neroxis `PbrTextureGenerator` + `MapEnvTextureExporter` (first PBR tooling; `BlackYps`, PR #365) | `git log -S` in `faf_repo/Neroxis-Map-Generator` [V] |
| 2025-02-08 | Map editor v1.0-rc1: "tools to generate new shader textures"; commit `014b1a9` "Integrate neroxis toolsuite (#60)" is the first to contain `GenerateMapInfoTexture`; rc2 adds `TTerrainXPExt`, `Terrain000`, `Terrain050` | GitHub releases page; `git log -S`; commit `7371d23` [V] |
| 2025-05-12 | Neroxis PR #437 "Accomodate to new shader changes": `ImageUtil.getMapInfoTexture`, map normal tool | `git log -S getMapInfoTexture` [V] |
| 2025-05-19 | Game patch 3822: "Rework and improve the newly added terrain shaders (#6683, #6704, #6770)"; mapper docs at `wiki.faforever.com/en/Development/Shaders/terrain-shaders` (403 to WebFetch, not read) | `faf_repo/fa/docs/_posts/2025-05-19-3822.md:223-225` [V] |
| 2025-09-12 | Editor v1.1: View menu with "Ambient Occlusion, for shaders using the Terrain Info Texture" | releases page [V] |
| 2025-11-25 | Editor v1.2: Neroxis toolsuite updated to generate helper textures for advanced shaders | releases page [V] |

The editor repo has no other baking code: `git grep -i "bake|lightmap"` over `*.cs` and `*.shader` finds only unrelated
`Bake()` methods (decals, props, marker chains) [V]. Open issues touching light: #120 "Decal shadow flickering"
(2026-10-07), #36 "Add button to set shadowcolor to 0" (closed, PR #52). No issue asks for a baker. [V]

### 1.2 What is baked, and where it goes

The editor's own button (`Assets/Scripts/UI/Tools/Textures/StratumInfo.cs:1112-1126`, `GenerateMapInfoTexture`) runs
`neroxis-toolsuite.exe export-map-info --map-path=<map folder>` (`NeroxisProcessRunner.cs`, log window with spinner), then
loads `env/layers/mapInfo.dds` into `ScmapEditor.Current.Textures[8]` (= Stratum 7 albedo), sets
`AlbedoScale = map size + 1`, and registers an undo step. [V] "Normals" (`export-map-normals`) does the same into the
Stratum 7 **normal** slot; "height and roughness" (`generate-pbr`) fills the **Upper albedo** slot. v1.0 notes add an
option to hide the map info texture in the upper slot (the "v" button). [V]

Channel layout (game side, `faf_repo/fa/effects/terrain.fx`):

| Channel | Meaning | Where read |
|---|---|---|
| **A** | shadow, 1 = sun, 0 = shadow; **multiplied** onto the dynamic shadow map result | `CalculateLighting` `:448-452`, `PBR` `:520-523`, `Terrain000` pixel path `:2264-2267` |
| **G** | ambient occlusion; multiplies `SunAmbience` only | same three places |
| **R** | water depth (0..1 over water to abyss), used only by the `Terrain200B`/`Terrain250B` family | `:3300` (`tex2D(Stratum7AlbedoSampler, position).r`) |
| **B** | unused by the game; Neroxis writes the AO value into it too | `ImageUtil.java:187-201` |

Header comment of the 3xx family documents the same slot meaning (`terrain.fx:3542-3557`). The decal pass (`DecalsPS`
`:1355-1372`) uses `CalculateLighting`/`PBR`, so **decals share the baked shadow** with the ground. **Units, props and
mesh-shaded objects do not read it** (`mesh.fx` has no `Stratum7`/`TerrainInfo` hit) [V]: a unit standing in a baked
shadow is still lit by the sun term of its own shader.

Formulae the bake must match (`terrain.fx:442-466`, `:558-559`):

```
shadow  = dynamicShadowMap(g) * info.a
light   = SunColor * saturate(N.L) * shadow + SunAmbience * info.g (+ specular)
light   = LightingMultiplier * light + ShadowFillColor * (1 - light)
```

So `a` is a **cast-shadow** term only; the N.L shading comes from the map normal (`mapNormal.dds` in Stratum 7 normal),
and the ground colour in shadow comes from `ShadowFillColor`/`SunAmbience` in the `.scmap` lighting block.

### 1.3 The switch: how the shader knows the slot holds the info texture

`ShaderUsesTerrainInfoTexture()` is `Stratum7AlbedoTile.x < 1.0` (`terrain.fx:347-358`). The engine sets the tile value to
`mapSize / albedoScale` (`engine_decomp/faf-re-upstream/src/sdk/moho/terrain/StratumMaterial.cpp:69-90`:
`mScaleX = maxSize.x * (1 / material.mSize)`), so an albedo scale of map size + 1 (the editor's choice) gives
512/513 < 1. The comment states the rule for mappers: "set the albedo scale to be bigger than the map size in ogrids"
(`terrain.fx:351-356`). Consequences: [V]
- Resolution is **free**: it comes from the scale, not the pixel size. A 2048 texture on a 512 map is legal.
- The Stratum 7 slot is **lost as a paint layer**. In `TTerrainXP` stratum 7 is a normal layer (`TerrainAlbedoXP`), so
  setting the info texture there hijacks it; in the 000/050/100/150/200/250/301 families S7 has other roles
  (`terrain.fx:3542-3557`). The mapper chooses the shader family to match.
- Not used in the flat `UpperAlbedo` tile path of maps with old shaders: the switch is per map and automatic.
- Needs a client >= 3765 (2023-09). Older clients ignore the texture silently and show the map unshadowed [I].
- Other binding facts: `HighFidelityTerrain.cpp:419-420` binds `stratum7AlbedoTexture` / `upperAlbedoTexture` as ordinary
  textures; `LoadTerrainLighting` (`:512-611`) sets `LightingMultiplier`, `SunDirection`, `SunAmbience`, `SunColor`,
  `SpecularColor`, `ShadowFillColor`, `ShadowsEnabled`, `ShadowMatrix`, `ShadowTexture`.

### 1.4 The algorithm (Neroxis, what the editor button runs)

`toolsuite/.../MapInfoTextureExporter.java:37-70` (the PBR/legacy generators repeat it: `PbrTextureGenerator.java:45-58`,
`TextureGenerator.java:74-82`) [V]:

1. Read the `.scmap` heightmap, divide by 128, resample to map size.
2. `shadowsMask = heightMap.copyAsShadowMask(sunDirection).inflate(1)` (`FloatMask.java:449-472`): for every cell, step
   along the light azimuth one cell at a time (nearest-cell `getPrimitive`, no interpolation) and mark cells whose
   height is below `startHeight - dist * tan(elevation)`; stops at the first lit cell; then `inflate(1).deflate(1)`.
   Sun direction and elevation come from `lightingSettings().sunDirection()` of the map.
3. `shadows = mask as float (1 lit, 0 shadow)`.
4. **Water rule:** shadows over water are kept only if the cell is in water and within 6 cells of land: the in-water mask
   is added to its own `inflate(6)` on land, subtracted with a `blur(6)`, then `blur(1)`. This hides hard underwater
   terrain shadows seen through the water.
5. Water depth: `clamp((waterElevation - height) / (waterElevation - abyssElevation), 0, 1)`.
6. Output `getMapInfoTexture` (`ImageUtil.java:187-201`): `R = waterDepth*255`, `G = B = 255` ("ambient occlusion
   channel", **always 255**), `A = shadow*255`. Written by `writeRawDDS`: uncompressed A8R8G8B8, one level, square
   (`ImageUtil.java:158-185`), size = map size (one texel per ogrid; `TextureGenerator.java:74`).

**Limitations [V unless marked]**: terrain height field only (no props, units, bridges); azimuth march by rounding, so
visible stair-steps on diagonal sun; edge softness is a 1-texel blur (no penumbra); no AO at all; no mips (shimmer at far
zoom [I]); R channel carries a coarse depth that duplicates `UtilitySamplerC.g`; the exporter needs a saved `.scmap`
(it re-reads it from disk), so an unsaved editor state is not baked; the tool is a Java GraalVM binary shipped in
`Structure/Neroxis` (separate process, log only); stale after any height or sun edit with no warning [I].

### 1.5 The editor's own rendering of it

`Assets/GFX/Shaders/FaTerrainShader.shader` (`surf`, `:1163-1530`) reads Stratum7Albedo `.a` as `MapShadow` and `.g` as
`AmbientOcclusion` whenever `Stratum7AlbedoTile < 1 && _HideStratum7 == 0`, and `.r` as `WaterDepth` in the `*B`
variants; `Deferred/Internal-DeferredShading.shader:108-253` applies `light = SunColor*saturate(N.L)*shadow +
SunAmbience*ao` and has an AO debug view (`_ShowAO`). The editor therefore **previews exactly what the game does**, but
is a Unity re-implementation that has been out of step with the game before (reworks `1b93462` 2024-11, `44625d5` 2025-08). [V]
The editor never writes `G`; the AO view only shows what a third-party tool put there. [V]

### 1.6 The legacy decal method (still supported by Neroxis)

`exportShadows` (`SCMapExporter.java:287-305`) writes `env/decals/map_shadows.dds` and adds a decal of size =
playable width, `DecalType.WATER_ALBEDO`, cutoff 1000. Pixel (`ImageUtil.compressShadow` `:237-258`):
`rgb = (shadowFill + sunAmbience)/4 * 128`, `a = (1 - shadow) * lightingMultiplier/4 * 255`, DXT5. Works on every client and
on every shader, but darkens on top of the lit result (also over water, and over units' shadows), is limited by decal LOD
and decal budget, and cannot do AO. [V] It is the fallback for maps that must run on the unchanged old `TTerrainXP` path
where Stratum 7 is a real layer [I].

## 2. Relation to FA's own terrain shading, and where a baked map plugs in without a binary patch

| FA mechanism | Detail | Evidence |
|---|---|---|
| Dynamic shadow map | 1024-class render target (`ren_ShadowSize`), orthographic light camera fitted to the view volume; **off when zoom > `ren_ShadowLOD`** (about 250); terrain draws into it via `TTerrainDepth` | `moho/render/Shadow.cpp:228-258`, `:319-330`; `terrain.fx:1031` [V] |
| Shadow fill colour | `.scmap` lighting block: 23 floats = multiplier, sun dir (3), ambience (3), colour (3), shadow fill (3), specular (4), bloom, fog colour (3), start, end | `scripts/meshmaps/scmap.py:10,208`; `CWldMap.h:472,1425` [V] |
| Sun / ambient | `CalculateLighting`, `PBR` | `terrain.fx:442-466`, `:512-570` [V] |
| Info texture | Stratum 7 albedo slot, see 1.2-1.3 | [V] |
| Water | `UtilitySamplerC` (watermap) `.g` = depth, used by `ApplyWaterColor` | `terrain.fx:931` etc. [V] |
| Frame-buffer alpha | glow; a shader writing alpha 1 blooms | `docs/projects/TERRAIN_MESH_MAPS.md` (session 3-4 findings) [V] |

Plug-in points **without** an exe/DLL change, best first:

1. **Terrain info texture (A shadow, G AO)** in Stratum 7 albedo: the community path, native in the shader, shared with
   decals. Free: **B** (and **R** unless `Terrain200B`/`250B`). Cannot carry colour (no coloured bounce, no per-channel
   GI) because `G` only scales the grey-weighted `SunAmbience` term and `A` only the sun term. [V]
2. **Shadow decal** (1.6): any shader; only a darkening layer.
3. **Baking into albedo / stratum paint**: possible but destructive and it fights the PBR splat shaders (the baked shade
   would be lit again) [I]; not recommended.
4. **Replacing `terrain.fx`**: the shader file is part of the game data; a map cannot ship its own [I]. Our dev exe/DLL
   route (like `meshterrain.cpp`) could, but then maps need the DLL (render only); out of scope for FA maps.
5. **Vertex colours**: FA terrain has none. [V by absence in `terrain.fx` vertex format]

Units and props cannot be made to read the info texture without a shader or exe change [V], so for an FA map a baked
shadow is a **terrain-and-decals-only** effect. Double darkening: the dynamic shadow map already contains the terrain
and props within the shadow LOD, and `a` multiplies it, so a bake of exactly the same occluders just yields hard shadows
twice (idempotent for binary shadows, darker penumbra for soft ones). Hence the recommendation in 4.5: bake terrain
shadows (what the community does), do **not** bake prop shadows into `A`, but let props contribute to **AO** (`G`), which
the dynamic map never produces.

### 2.1 What the mesh-terrain DLL does with light masks

`automation/terrainmesh/meshterrain.cpp` replaces the ground draw with its own `vs_3_0/ps_3_0` shader (`:196-288`). Per
patch: nine textures (`diffuse a/b`, `light_mask_0..2`, `normal a/b`, `specular`, `specular_b`, slots `:696-697`, loaded
with `D3DFMT_UNKNOWN`, `:905-918`). Pixel logic (`:246-288`) [V]:
- `blend = lightMask1.a * Material.x` selects/mixes layer a and b (and normals, mask b).
- `n` = blended SC2 RGB tangent normal; `dp = saturate(n . b_i)` with the HL2 basis `(0.8165,0,0.5774)`,
  `(-0.4082,0.7071,0.5774)`, `(-0.4082,-0.7071,0.5774)`; `light = sum dp_i * Linear(mask_i.rgb)` (masks are
  gamma-encoded, `pow 2.2`).
- Dynamic shadow: FA's shadow map `.g` pulls the light towards SC2's shadow colour by
  `(1 - sun) * ShadowColor.a * max(mask0.a, 0.5)`; highlight multiplied by `sun * mask0.a`.
- Output `pow(... , 1/2.2)`, tone roll-off above 0.7, water ramp, haze.
- **Missing masks:** `g_gray` = RGB `0xC7C7C7`, alpha 0 (0.78 gamma = 0.577 linear): each of the three masks carries 0.577, which
  makes `0.577*3*0.577 = 1.0` on a flat surface (neutral full light). Alpha 0 means "first layer only, sun occlusion 0"
  (`:493-495`, `:884-895`). So the DLL already defines the **calibration target** for a baker: unoccluded uniform light of
  radiance 1 on a flat normal must bake to 0.577 per mask. [V]
- The mesh does **not** read the Stratum 7 info texture; on a mesh map the FA strata/info texture only shape the fallback
  look (`MESH_MAP_EDITOR_NEEDS.md:76`). [V]

## 3. The SC2-style light-mask approach in this workspace

### 3.1 Format [V]

| Item | Value | Evidence |
|---|---|---|
| Files | per material (SC2 groups meshes by material and map object group): `maskNN_0/1/2.win.dds` (also `<name>_0/1/2`, e.g. `playsurface_0`, `RNM_MP_204_A_0`) | `maps.scd` listing (this session); `convert.py:348` |
| Texture | 564 files in 46 maps: 388 x 1024^2, 57 x 2048^2, 27 x 512^2; all DXT5, one mip level | header read of `Supreme Commander 2/gamedata/maps.scd` (this session) |
| Coordinates | vertex UV2: two int16/32767 into a **unique, non-overlapping chart atlas** per section; clamp addressing | `docs/projects/TERRAIN_MESH_MAPS.md:~890`; `MESH_MAP_EDITOR_NEEDS.md:126` |
| mask 0 RGB / mask 1 RGB / mask 2 RGB | irradiance (sun + sky + bounce) projected on the three Half-Life 2 basis directions in tangent space; gamma encoded | `terrain.hlsl:52-70` (`ComputeRNM`, extracted from `lua.scd`), `meshterrain.cpp:257-261` |
| mask 0 alpha | **sun occlusion factor** (1 = sun reaches, 0 = baked-shadowed; "or 1.0f"). Dynamic shadow only darkens where this is high: `lerp(rnm, ShadowColor, min((1-shadowScalar)*ShadowColor.a, sunOcclusion))`; also scales the sun highlight | `terrain.hlsl:249,386-399` |
| mask 1 alpha | **blend weight** between the material's layer A and B (`BLENDING` flag). It is *authoring paint*, not lighting | `terrain.hlsl:252`; `TERRAIN_MESH_MAPS.md:647` |
| Sun | **baked into the RGB** (the RNM path has no analytic sun term, only specular) | `terrain.hlsl:378-399` |

Two flags matter: `RNM_LIGHTING || BLENDING` selects the mask reads; without them the shader uses constants
(`terrain.hlsl:240-247`). So a mesh map with a simple material can drop the masks entirely and rely on the neutral fallback.

### 3.2 How SC2 authored them [I/O]

Nothing in the workspace shows a SC2 baker. `docs/SC2_ANALYSIS.md:117` only lists "baked light masks"; names such as
`RNM_MP_204_A` suggest a DCC-tool radiosity bake with a "RNM" output option (Maya/Max lightmapper) [I]. The unique UV2
atlas, the DXT5 storage and the 1024/2048 sizes tell us the **target spec**, not the method. `scripts/meshmaps/` contains
converters only (`convert.py` copies masks, `pad_atlas` fixes seams); there is no baker or analysis script [V by listing].

### 3.3 Can one baker serve both?

Shared: sun model (direction, colour from the map's lighting block or the mesh manifest `sun_x/y/z`, `sun_r/g/b`), sky
and ambient model, hemisphere sampling, ray query, dirty tracking, bake metadata, job system, preview, validators.
Different: **what a sample is** (a ground cell with a heightfield normal vs a UV2 texel with a triangle's TBN) and **what
the encoder writes** (A shadow + G AO vs three RNM projections + sun alpha). Section 4 splits the baker on exactly that
seam.

## 4. Proposal: one baker ("LightBaker") in the editor

### 4.1 Architecture

```
            +-----------------+       +------------------+      +----------------+
 inputs --> |  SceneRays      | <---> |  SampleDomain    | ---> |  Encoder       |
            | (occlusion q.)  |       | (positions,      |      | (writes files, |
            +-----------------+       |  normals, TBN)   |      |  previews)     |
   Height-field + props raster  |     +------------------+      +----------------+
   Triangle BVH (mesh + props)  |      GridDomain (FA)           InfoTextureEncoder
                                       AtlasDomain (UV2)         RnmMaskEncoder
```

- **SceneRays**: `occluded(origin, dir, tmax)`, `hitDistance(...)`. Two implementations behind one interface:
  `HeightfieldScene` (hierarchical max-mip DDA over the `CHeightField` at 1/128 resolution, plus an optional raster of
  prop occluders as a second max-height layer) and `TriangleScene` (Embree 4, Apache-2.0, or a small own BVH; patches,
  props and optionally water plane). The mesh patch loader already knows vertices in world space (`MESH_MAP_EDITOR_NEEDS.md`
  1.4). [I]
- **SampleDomain**: `GridDomain` (texel -> world x,z; height from the field; normal from the same filtering the sim uses,
  bilinear 1-unit grid, `STIMap.h:218-224`) and `AtlasDomain` (rasterise each triangle in UV2 space, conservative; store
  position, interpolated normal/tangent/binormal per texel, chart id; dilate by >= 4 texels because of DXT 4x4 blocks and
  bilinear sampling).
- **Radiance model** (shared, from `Lighting`): sun direction and colour, optional sun disc angle (penumbra), sky as
  hemisphere gradient (zenith colour, horizon colour, default derived from `SunAmbience`), ground albedo for one bounce
  (default 0.25, off for FA maps).
- **Encoders**: see 4.3 and 4.4.
- **Runtime**: a `BakeJob` per (map, target, tile). Runs on worker threads, reads an immutable snapshot of the height
  field / mesh from the commit path (design D4: edits applied between ticks; the snapshot is copy-on-write per tile).
  Output tiles are copied into a D3D9 texture (managed pool, `LockRect` dirty rect) that is **bound into the live
  engine terrain as the Stratum 7 albedo / the mesh DLL's mask slots**, so the preview is the real shader, not a
  re-implementation (the editor's advantage over the Unity editor, design section 13).

CPU, not GPU: the engine device is D3D9 (no compute); the 2.5D FA bake is cheap on CPU, and the mesh bake is well served
by Embree-class BVH traversal (order of 10^8 rays/s on a 16-thread CPU [I, to be measured]). GPU DXR would add a second
device and a dependency for no gain at these sizes.

### 4.2 Inputs

| Input | FA map | Mesh map |
|---|---|---|
| Geometry | `CHeightField` (live), water elevation/abyss, optional prop occluders, optional marked "static big structures" | mesh patches (SCM v5) in world space, props, optional outline of cut-outs |
| Lighting | `.scmap` lighting block (sun direction, colour, ambience, multiplier, shadow fill), same values the game uses | manifest `sun_*`, `shadow_*`, plus sky/bounce settings (new fields in the mesh lighting group, `MESH_MAP_EDITOR_NEEDS.md:200`) |
| Masks | map size, playable rectangle | UV2 charts (editor-generated or imported); per-material blend paint for mask1.alpha |
| Params | quality, resolution (texels per unit), AO radius and strength, sun disc size, include props in AO / shadow | quality, texel density, bounce count, sky model, padding |

### 4.3 Output, target A: FA map (the community format)

- `env/layers/mapInfo.dds`, A8R8G8B8 **uncompressed**, **with full mip chain** (Neroxis writes one level; averaging mips
  for shadow/AO is harmless and removes far-zoom shimmer [I]). Square, power-of-two not required by the engine for
  scale (it uses the albedo scale) but keep it a multiple of 4. Default resolution 2 texels per ogrid, capped at 4096 (64 MB
  + mips); minimum 1 per ogrid (the community default). Written and loaded into `Textures[8]` with `AlbedoScale = size + 1`.
- Channels: **A** = sun visibility (soft: penumbra from sun disc, 1 lit); **G** = AO; **B** = G (as Neroxis, harmless); **R** =
  water depth when the shader family is `Terrain200B/250B`, else the same scaled depth (cheap, keeps community tools
  and the Unity editor happy).
- **Shadow (A)**: for every texel, march toward the sun through the combined surface (terrain + optional static big
  props) with bilinear height lookup (fixes Neroxis stair-steps), min-visibility over a sun-disc kernel for a real
  penumbra, then Neroxis's water rule (fade over water by depth/6 cells) as a **parameter**. Terrain only by default.
- **AO (G)**: horizon-based AO: N directions (8/16/32 by quality) x M steps up to radius R (default 24 units, 96 for
  "broad"), cosine-weighted visible fraction; props add occlusion volumes (mesh footprint height) so trees and ruins
  darken the ground, which the dynamic map never does. Strength curve maps to `[floor, 1]` (default floor 0.35) because
  `G` scales only `SunAmbience`, which is often small in dark maps [I].
- Optional **legacy** output: `env/decals/map_shadows.dds` decal exactly like `compressShadow`, for maps that keep the
  old shader and need Stratum 7. Off by default; costs about 1 day.
- Sidecar `env/layers/mapInfo.bake.json` (not shipped): hash of height field, sun, prop list, params, tool version, time.
  Used for the stale validator (4.7).

### 4.4 Output, target B: mesh map (SC2 style)

- Files `textures/<material>_light_0/1/2.dds`, DXT5, **1024 by default, 2048 per material option, 512 for small**
  (match the SC2 distribution, 3.1), gamma-encoded RGB (`pow(x, 1/2.2)`), one level (the DLL builds mips,
  `meshterrain.cpp:909-912`), referenced as `light_mask_0..2` in the manifest (`convert.py:1065-1067`).
- **RNM projection.** For each texel with tangent frame (T,B,N) and radiance samples `L(w_k)` (sun delta with sun
  disc, sky, bounce) from the hemisphere above the surface, compute the three RGB values so that
  `sum_i saturate(n . b_i) c_i` best approximates the true cosine-weighted irradiance `E(n)/pi` over the hemisphere (the
  shader applies **no normalisation**, `terrain.hlsl:56-70`). Least squares: `c = G^-1 r`, with the 3x3 basis Gram matrix
  `G_ij = integral f_i f_j dn` (constant, precompute once) and `r_i = sum_k L_k h_i(w_k)`, `h_i(w) = integral f_i(n)
  max(0, n.w) dn` tabulated (64x64 table). Clamp negative `c_i` to 0. Calibration: flat surface, uniform sky radiance 1
  gives 0.577 in every mask (matches `g_gray`). [I, verified only by this derivation; the test in 4.8 checks it]
- **Alpha 0**: sun visibility (sun disc fraction, 1 = reaches). **Alpha 1**: copy of the artist's two-layer blend paint
  (from the material assignment tool, F5); the baker must **never overwrite it with light** and must preserve it through
  dilation. 255 for single-layer materials with blending off.
- **UV2**: if the imported mesh has charts, use them; else generate with xatlas (MIT) at a chosen texel density,
  1.5-4 texel gutters, rotate-to-fit; validate V4 (UV2 inside 0..1, no overlap). Seams: dilate, then DXT5-compress with
  a block-aware encoder (no chart colour bleeding; the same 4x4 rule as `pad_atlas`, `convert.py:374-476`).
- Optional **bounce**: 1 diffuse bounce using material average albedo (from `diffuse_a`'s mip 8 colour) and per-material
  override; off by default (SC2 maps clearly have bounce [I]).
- Per-material output so it matches the manifest model (one patch = one material, `MESH_MAP_EDITOR_NEEDS.md:216`).

### 4.5 Defaults that follow from the engine behaviour

- FA map: **terrain-only shadow in A, props contribute to G only**, because the dynamic map already casts props and
  terrain within the shadow LOD and A multiplies it (section 2). Expose "include props in A" for huge static structures.
- FA map: set the lighting block's `ShadowFillColor` to **0 optionally** with the compensating sun/ambient rescale (the
  editor's PR #52 button, issue #36): with a baked A the shadow colour should come from `SunAmbience`, otherwise the
  fill colour doubles the darkening [I; the maths is in issue #36's script].
- Mesh map: bake the **sun into RGB**, since the SC2 shader has no analytic sun for RNM (3.1); the dynamic shadow then
  uses alpha 0 as written.

### 4.6 Incremental re-bake of dirty regions

Dirty sources come from the single commit path (design section 2, each `Command` carries a dirty rectangle):
- Height edit rect R: shadows change within R and downwind by `reach = maxHeightDelta / tan(elevation)` (cap 512);
  AO within R grown by the AO radius. Tiles = 64 x 64 texels; a tile is dirty if its rectangle intersects the grown R.
- Prop add/move/remove: footprint grown by prop height / `tan(elevation)` along the shadow azimuth for A (only if
  "include props in A"), by AO radius for G.
- Lighting edit: sun direction/colour changes mark **everything** (A, mesh sun); ambience/multiplier changes need no
  re-bake (applied in shader) - an explicit rule so the user is not made to wait for nothing.
- Mesh edit (import, material, UV2): charts whose bounding sphere is within `maxRayLength` of the changed AABB (BVH
  refit), re-bake those charts; re-pack of UV2 invalidates the material's three files.

Scheduling: stroke start -> **Draft** quality (4 directions, 12 steps, 1 texel/unit, 1 ray per sun sample) on a
background tile queue, preview texture updated per tile; 300 ms idle -> **Normal**; save / release -> **Final** for
every stale tile (blocking with progress, cancellable, resumable by tile version). Bake results are cached per tile
(`quality, input-hash`) so undo/redo and branch switches restore without recomputation. Tile versions are monotonic;
a result older than the current input version is dropped (no torn textures).

### 4.7 Validation rules (feed the validator framework)

| Id | Rule | Level |
|---|---|---|
| BL1 | A bake exists for a map that uses the info texture and is **not stale** (hash of height field, sun, props, params) | W, error at release |
| BL2 | Shader family compatible: `ShaderUsesTerrainInfoTexture` requires `Stratum7AlbedoTile < 1` (albedo scale > map size) and a shader that reads S7 as info (not a family where S7 is a paint layer in use) | E |
| BL3 | Info texture is square, multiple of 4, <= 4096, A8R8G8B8, B equals G (tool convention) | W |
| BL4 | `A` and `G` not all 255 (bake did something) and not all 0 | W |
| BL5 | Lighting block sane: `SunAmbience` not 0 when `ShadowFillColor` is 0, multiplier > 0 | W |
| BL6 | (decal fallback) shadow decal size equals playable area | W |
| BM1 | UV2 inside 0..1, no chart overlap, gutter >= 2 texels (extends V4) | E |
| BM2 | Mask files exist for every material using `RNM`/`blending`; sizes 512/1024/2048, DXT5, one level or full chain | W |
| BM3 | Mask 1 alpha unchanged by re-bake (compare to material blend paint hash) | E |
| BM4 | No texel with `c_i` > 8 (burn-out) or NaN; tone-roll-off check against the DLL's 0.7 knee | W |
| BM5 | Mesh bake stale (mesh, sun, sky or material changed since bake) | W |
| BM6 | Bounce setting recorded in the manifest, so a re-import reproduces the look | I |

### 4.8 Test criteria

1. **Determinism**: same inputs and seed give bit-identical output on 1 and 16 threads (fixed sample sequences per texel;
   floating accumulation order fixed per texel).
2. **Neroxis parity** (FA target): on the three test maps in `my_maps`, with penumbra and AO off and nearest-cell march,
   `A` matches `export-map-info` output to within 2 levels except the 1-cell blur; this proves format/orientation (flip,
   offset by one, row order).
3. **Analytic scenes** (unit tests): flat plane -> A = 1, G ~ 1; single wall of height h on flat ground, sun elevation e ->
   shadow length `h / tan(e)` within 1 texel; a pit of known depth -> AO monotonic with depth; sun below horizon -> A = 0
   everywhere.
4. **Round trip in the engine**: load the baked `.scmap` + `mapInfo.dds` in game, screenshot at the same camera with
   baked A on and `ShadowsEnabled` off: darkened regions coincide with the editor preview within a pixel; shadow edges
   follow terrain (golden-image test, tolerance table). Unit in a baked shadow stays lit (documented limit).
5. **Incremental == full**: after random sequences of height / prop edits the tiles recomputed incrementally equal a full
   Final bake bit for bit (this is the main safeguard for the dirty-rect maths).
6. **RNM calibration** (mesh target): flat quad, uniform sky L=1 -> all masks 0.577 (+-1%); directional sun at 45 degrees
   -> shaded result of the DLL equals analytic `E(n)` for n in a 5x5 grid of normals within 8%; masks round trip through the
   DLL's `Linear()`.
7. **SC2 reference** (local only, content not committed): bake an SC2 map's mesh with the manifest's sun and a default sky,
   compare against the shipped masks per chart: mean luminance ratio within 25%, shadow-boundary (alpha 0) F1 > 0.9,
   chart-level correlation > 0.85. Report numbers, not files.
8. **Seam test**: no visible chart seam at mip 0-3 (compare gradient across a seam to the in-chart gradient).
9. **Performance budget** (to be measured on the target machine, RX 7900 XTX box): FA 10 km map at 2 texels/unit Final
   in under 15 s; Draft tile (64x64) under 20 ms; mesh 1024 mask Normal under 30 s with 256 samples. [targets, not
   measurements]
10. **Staleness**: change one prop -> BL1 fires; re-bake clears it; sun edit stales everything.

### 4.9 Effort (working days, one developer, including tests)

| Block | Contents | Days |
|---|---|---|
| B0 | Core: `SceneRays`/`SampleDomain`/`Encoder` interfaces, tile job queue, snapshot, bake metadata, preview binding into Stratum 7 slot | 3 |
| B1 | FA shadow (bilinear march, penumbra, water rule), AO horizon bake, info texture writer with mips, Neroxis parity test, analytic tests | 4 |
| B2 | Prop occluders (footprint/height proxies, optional triangles), incremental dirty tiles and cache, quality ladder (Draft/Normal/Final) | 3 |
| B3 | Validators BL1-BL6, UI (bake panel, stale badge, overlay views A/G/combined, "lighting off" compare toggle), optional legacy decal | 2 |
| B4 | Mesh: triangle scene (Embree or own BVH), UV2 atlas domain (xatlas, gutters, dilation), RNM projection + tables, alpha 0/1 handling, DXT5 writer | 7 |
| B5 | Mesh incremental per chart, validators BM1-BM6, SC2 reference comparison, seam and calibration tests | 4 |
| Total | FA only (B0-B3): **12 days**; with mesh (B4-B5): **23 days** | |

The design doc recommends the baker in M5b (after the mesh suite). The shared core (B0) and FA target (B1-B3) cost half
of the total and deliver value to every normal FA map earlier; they could sit in M3 (lighting is already in the M3 scope).
That is a scheduling suggestion for the user, not decided.

### 4.10 Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Wiki page for the shader families was not readable (403); channel use of `R`/`B` inferred from `terrain.fx` | wrong family rules in BL2 | the rules above are from the shader source itself; re-check against the wiki before release |
| Info texture is terrain/decal-only; units and props ignore it | baked shadows look inconsistent for units standing in them | default terrain-only bake, say it in the UI; do not pretend it is global illumination |
| Double darkening of dynamic and baked shadow (soft edges) | too dark penumbra | bake hard-ish penumbra, document, offer A strength slider (lerp to 1) |
| `ShadowFillColor` + `G` interplay depends on map lighting values | AO looks wrong on dark maps | AO floor/strength parameters; preview uses the real shader; PR #52 style rescale tool |
| Mesh UV2 generation quality (xatlas) and seams at DXT5 | visible artefacts | gutters, block-aware padding, seam test; allow imported charts |
| RNM projection differs from SC2's own bake (unknown method) | look mismatch vs SC2 | calibrated by derivation + SC2 reference test; expose exposure and sky parameters |
| Embree dependency (native, AVX) in the editor build | build size/licence | Apache-2.0; fallback own BVH (about 2 days extra) |
| Large maps (20 km at 2 texels/unit = 40 M texels x samples) | long Final bake | tile cache, thread pool, resumable, quality default 1 texel/unit for 20 km |
| Snapshot memory of height field + prop proxies | RAM | per-tile copy-on-write, proxies only |
| Game client older than 3765 ignores the texture | map unshadowed there | BL1 note; legacy decal option |
| Sun in `.scmap` convention (azimuth/elevation, y-up vs z-up, flip of the texture's v axis) | mirrored shadows | Neroxis parity test (4.8 test 2) pins orientation before anything else |
| Unity editor and Neroxis users overwrite our `mapInfo.dds` | stale or lost bake | `.bake.json` sidecar hash detects foreign files; BL1 |

## 5. Open questions for the user

1. FA target: accept the terrain-only default (props only in AO), or bake props into A too (more complete, doubles near-camera shadows)? [O]
2. Where to place the FA-map baker: with M3 (lighting) or with M5b (mesh)? Recommendation: FA target in M3/M4 (after the commit path exists), mesh target in M5b. [O]
3. Keep the legacy shadow-decal export, or only the terrain info texture? [O]
4. For mesh maps: our own UV2 generation (xatlas) in scope now, or only imported charts + validation first? [O]
5. Verify the mapper-facing shader table on the FAF wiki (`terrain-shaders`) once reachable; channel assumptions here are from `terrain.fx`. [O]
6. How the water surface shadow (`waterShadowMap` in Neroxis, a half-resolution mask in the `.scmap` water section) maps to the engine's water shader is not analysed here. [O]

### 5.1 Decisions (user accepted the recommendations, 2026-10-17)

1. **Channels:** terrain-only shadow in A, props in AO (G).
2. **Baker order:** FA target in M3/M4 (after the commit path exists), mesh target in M5b.
3. **Legacy shadow-decal export:** dropped; only the terrain info texture is written.
4. **UV2 for mesh maps:** validate imported charts first, generate UV2 only when missing or invalid.
5. and 6. stay open (wiki shader table check, water shadow mask).

