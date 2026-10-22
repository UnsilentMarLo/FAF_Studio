# Convert layers between terrain shaders

Code: `editor/runtime/lua/editor/stratumconv.lua` (plan and run), `texconv.lua` (what the shaders read from albedo alpha and the Upper atlas, the staged files), `shaders.lua` (profiles: `Profile`, `Rows`,
`Notes`, `SplatLighting`), `gui/convertdialog.lua`, natives `ed_tex_convert` / `ed_tex_atlas` (engine `moho/editor/EdTexConv.cpp`, maths in `EdTexConv.h`, `EdDdsEncode.h`, test `tests/EdTexConvTest.cpp`),
self test `selftest_strataconv.lua`. Line numbers below are `faf_repo/fa/effects/terrain.fx` of this workspace (FAF game data, read-only).

User report (TTerrainXP map, Evergreen layer textures, conversions tried one after the other): Terrain200 = flat blobs of colour with hard edges (rock on the cliffs fine), Terrain251 = grass fine but the
whole map dark and blurry, Terrain102B = dark, cliffs streaky, Terrain100B = cliff and slope textures smeared, streaky, stretched. The result dialog of an earlier TTerrainXP -> Terrain251B conversion
listed three "Not done" items (albedo alpha ignored, roughness / heights from a neutral atlas, normal maps unchanged).

## What was proved from the shader source, one symptom at a time

### Terrain200 (and every Terrain2xx): flat colours, hard edges  -  cause: the map's SpecularColor is 0 0 0 0

The 2xx shaders take their settings from the map's lighting colour `SpecularColor` (a float4 the engine sets from the .scmap lighting; the legacy shaders use it as the specular highlight, 0 in a map made
for them: `envlib_looks.lua` has spec_r = spec_g = spec_b = spec_a = 0 in every look):

* `Terrain200AlbedoPS` 3025-3026: `rotationMatrix = float2x2(float2(SpecularColor.b, -SpecularColor.a), float2(SpecularColor.a, SpecularColor.b)); rotated_pos = mul(position.xy, rotationMatrix)`.
  With b = a = 0 the rotated position is (0, 0) for every pixel. The strata 0, 2, 4, 6 (= layers 1, 3, 5, 7) are sampled at `rotated_pos` (3042, 3044, 3046, 3048; the same in the normal pass 2987-2993 and in
  the heights 3050-3056): each of them is **one texel of its texture over the whole map**, a flat colour and a flat normal. Layers 2, 4, 6 and the base use `position.xy` and look right ("grass ok, rock on
  the cliffs ok").
* `splatLerp` 1803-1812: `factor = saturate((t2height + opacity - 1 + 0.5 * blurriness) / blurriness)` with `blurriness = SpecularColor.r` (3059-3065). 0 divides by zero: the factor is 0 or 1
  (the posterised blobs with hard edges). `SpecularColor.g` (1806) is the contrast of the heights; 0 is harmless.

So b / a must be a unit vector (cos / sin of the rotation, 30 degrees = 0.866 / 0.5: the comments at 3024, 1842 and 1850), r a softness (the default parameter of splatLerp is 0.06, the comment on g says 0.6 is a good
default). The convert plan never touched the lighting. **Fixed**: `Shaders.SplatLighting` ('enter' on a conversion to a 2xx shader: SpecularColor = (0.2, 0.6, 0.866, 0.5); 'fix' on a plain switch to a 2xx
shader with an unusable colour; 'leave' puts the old colour back when converting away; undo restores it). The Lighting panel has no sliders for spec_r..spec_a (see "Not done").

Evidence for the numbers: a splat with constant heights (the neutral atlas has height 0.5 everywhere) and blurriness b is `saturate((o - 0.5 + 0.5 b) / b)`: b = 1 is plain linear blending, b = 0.06 a threshold
at mask 0.5 (hard edges even with a correct SpecularColor). The editor's old neutral atlas therefore could never look like the original blend; heights from the textures' own detail are needed.

### Terrain251: dark and blurry  -  two causes, one of them certain

1. The same SpecularColor = 0 as above (rotated layers flat; normals of those layers flat too: a constant normal from texel (0, 0) lights a whole layer too dark or too bright).
2. The last digit of a Terrain1xx / 2xx name is the macrotexture variant (2662-2679, `blendMacrotexture` 1939-1948): digit 1 is `lerp(albedo, macro.rgb, macro.a)` and digit 2 `lerp(albedo, 2 * macro.rgb * albedo, macro.a)`
   with `macro = tex2D(LowerAlbedoSampler, position.xy * LowerAlbedoTile.xy)`: **the base layer's own texture, laid over everything by its own alpha**. A TTerrainXP base texture's alpha is a specularity
   (0..1, `albedo.aaa * ...` TerrainAlbedoXP line 971), so the base texture covers the painted layers by a random amount: grass everywhere, blurred (the base tile is large). Terrain250 has no macrotexture.
   Same in Terrain001 / 051 (2475: `albedo = lerp(albedo, lowerAlbedo, lowerAlbedo.w)`, always on). **Fixed**: the base layer's texture is copied with alpha 0 (lossless: only the alpha blocks are rewritten).

Roughness is not the cause of the darkness: `applyPbrShading` 1930-1937 is `saturate(albedo.a * mask1.w * 2 + 0.01)` with `albedo.a` = atlas roughness R / B (`sampleAlbedo` 1865-1874) and `mask1.w` = layer 8's mask
byte / 255 (128 = 0.5, not touched by the half range 2608-2612). The neutral atlas gives roughness 0.65 and the PBR lighting (512-590) is the same sun + ambient + fill model as the legacy
`CalculateLighting` (442-470); it is not darker by itself.

### Terrain102B / Terrain100B: dark, streaky, stretched  -  cause: layers 3 and 4 are side projections, layer 8 must hold map data

`Terrain100BAlbedoPS` 2793-2837 (Terrain200BAlbedoPS 3246-3304 is the same):

* `calculateBlendWeights(position.xy)` (1923-1928) reads `tex2D(Stratum7NormalSampler, position).ag * 2 - 1`: the **map normal map in layer 8's normal slot** (A = normal x, G = normal z; the engine itself reads it
  the same way in `TerrainBasisPSBiCubic` 861-863). `blendWeights = |n|^3 / sum` chooses between the two side projections. In the converted map layer 8's normal map was a ground normal map (tile-size sized
  texture stretched over the whole map): the weights are noise, the streaks.
* Stratum 2 and 3 (layers 3 and 4) are sampled with `position.xz` and `position.yz` **only** (2816-2821, 2819-2821, 3280-3285): the horizontal plane (`position.xy`) is never used. Whatever texture a layer 3 / 4
  carries is projected from the side, also on flat ground: stretched horizontal streaks. (The old table said "also mapped from the side": wrong, it is only.) On a map where layers 3 / 4 hold grass or
  dirt painted on gentle ground this is the "smeared slope textures". Cliff textures belong there, painted on steep ground.
* `float waterDepth = tex2D(Stratum7AlbedoSampler, position).r;` (2833, 3300): **layer 8's albedo R is read unconditionally** (no tile check, unlike the non-B shaders: `ShaderUsesTerrainInfoTexture` 347-358
  gates only `PBR()` 520-524). A ground texture's red channel is a water depth: `ApplyWaterColor` 412-439 tints the terrain with the water ramp wherever R > 0: the dark blue-ish cast.

**Fixed**: the plan reads the mean slope under every painted layer (native slope op, mask-weighted), moves the two steepest layers (>= 20 degrees mean) to layers 3 and 4 (a painted gentle layer there swaps with
an unpainted layer when there is one), warns about what remains, and makes the map normal map and the water depth (no baked shadow) for layer 8 with `maptextures.Generate` (made from the terrain; Generate / Clear
of the Map textures panel give the same files; Stale tracking applies: sculpting later makes the normal map out of date).

### Terrain001 / 051 (not reported, same family)

2441: `terrainShadow = tex2D(Stratum7AlbedoSampler, coordinates.xy).a` always (no size check): a ground texture in layer 8 multiplies the sun by its alpha (dark). The plan gives layer 8 a neutral light texture
(`maptextures.Clear('light')`: R 0, G = B = 255, A 255) and clears the base alpha (2475).

### Suspects refuted by the source

* (a) Normal maps are NOT in a different format. Legacy `TerrainNormalsPS` 804-818 / `TerrainNormalsXP` 826-847 decode `tex2D(...) * 2 - 1` (RGB = x y z); 100 (2578-2585), 200 (2986-2993), the B shaders and
  the 0xx shaders do exactly the same. The normal pass writes only R and G (`AlphaBlend_Disable_Write_RG`, 3078); B / A come from the basis pass (851-906). No repack is needed. (What does differ: the 2xx
  sample the normal map at the **albedo** tile and use the normal tile as the far scale of the heights, 2987-2993, 3001-3007; the 1xx / 0xx use the normal tile.)
* (b) Legacy albedo alpha is not read as roughness: in 1xx / 2xx `sampleAlbedo` overwrites `albedo.a` with the atlas roughness. The alpha matters only for the macrotexture variants, 001 / 051 (above), and in
  the opposite direction (PBR -> 0xx / XP: specularity). TTerrain reads `1 - alpha` (TerrainPS 934), TTerrainXP / 0xx `alpha` (971, 2275): a TTerrain <-> XP conversion inverts shiny and dull ground.
* (c) The mask range recode is right: half -> full `max(0, 2b - 255)`; the 1xx / 2xx do `saturate(mask * 2 - 1)` in the x5x variants (2608-2611) and leave the mask alone in the x0x variants; layer 8's mask
  (mask1.w) is never halved (2610 "Don't touch the roughness mask").
* (d) The Upper layer's tile size is not a scale: `ShaderUsesPbrRendering` is `UpperAlbedoTile.x < 1` (360-364: used by decals / meshes). The atlas is sampled with the layers' own tiles (`atlas2D(position *
  scale, offset)`, 1831-1839), so 1024 was harmless (tile = map size / size: `StratumMaterial.cpp` SetSize).
* (e) Layer tile sizes keep their meaning in the biplanar shaders (world units: `position.xz * tile` is height * tile).
* (f) Layer 8's mask 128 = neutral roughness multiplier (0.5 * 2 = 1) is right.
* (g) The tile sizes are the same kind of number in every shader (repeats = map size / size).

## The roughness / height atlas

`atlas2D` (1831-1839): `uv = frac(uv) / 4 + offset + 0.125`, offset one of (0, 0), (0.5, 0), (0, 0.5), (0.5, 0.5): the shader reads only the middle half of a half-size tile, one period of a 2 x 2 repetition.
The code (not the layout comment at 2119, which has the channels the wrong way round) reads **roughness from R (first four layers: base, 1-3) / B (layers 4-7)** and **height from G / A**
(1856-1860, 1878-1886, 1895-1899). A layer's tile therefore has its picture twice in each direction, shifted by half a period so that a texel of the atlas lines up with the layer's own texel
(`BuildAtlas`, tested by simulating the shader's pixel lookup). The editor writes 1024 x 1024 (each layer's data 256 x 256), DXT5 with mips: roughness from the albedo alpha (`kind` spec / matte; neutral 0.65
otherwise), height from the albedo luminance around its mean (gain 1.3). **This height is a rough guess**: rock does not win over grass by itself; it makes the transitions follow each texture's own detail instead of a
threshold. A real atlas (hand made) is better for a finished map.

## What a conversion does now

Pair rules (`Plan` / `TexPlan`):

| Change | Masks | Textures (new files, option "Also convert textures", on by default) | Lighting |
|---|---|---|---|
| range half <-> full | recode on raw bytes (field engine) | | |
| layer 8 painted -> 1xx / 2xx / 0xx (7 layers) | move / merge / drop (choice) | layer 8 data: only for B shaders and 001 / 051 (below) | |
| to 1xx / 2xx | layer 8 mask = 128 | Upper = atlas from the layers (roughness from alpha, heights from detail) | |
| to a macro variant (last digit 1, 2) or 001 / 051 | | base albedo copied with alpha 0 | |
| TTerrain <-> TTerrainXP / 0xx | | albedo alpha of every textured layer inverted (alpha-only rewrite of DXT5 blocks, colours bit for bit) | |
| 1xx / 2xx / 001 / 051 -> XP / 0xx / TTerrain | | alpha from the old atlas roughness of that layer (neutral atlas: 0.3 specularity) | |
| to a B shader | layers 3 / 4 = steepest painted layers (swap) | layer 8 normal = map normal map, layer 8 albedo = water depth (generated from the terrain, `maptextures`) | |
| to Terrain001 / 051 | | layer 8 albedo = neutral light texture | |
| to a 2xx shader | | | SpecularColor = (0.2, 0.6, 0.866, 0.5) (old colour remembered) |
| from a 2xx shader | | | old SpecularColor back (zeros when unknown) |
| Terrain301 | refused (its atlas is in layer 8's normal map) | | |
| TTerrainGlow <-> others | (4 painted layers like TTerrain) | the alpha of layer 1 is a glow mask there: kept, with a warning | |
| TTerrainXPExt | half range for the colours (as Terrain050), its normals read the mask unhalved like TTerrainXP: nothing to convert | | |

Files: `maptex_conv_<n>.dds` (alpha copies), `maptex_atlas_<n>.dds`, `maptex_normal_<n>.dds`, `maptex_light_<n>.dds` in the map textures staging folder (`maptextures.lua` STAGE, mounted `/edmaptex`). The
layers point at them; **the old textures are never changed**; undo (one history entry) points the layers back; the files stay in the staging folder (conversion files are not in `maptextures`' prune list, so
undo / redo always finds them); saving copies the files the layers use into `<map>/env/layers` and deletes unused `maptex_*.dds` there (`PrepareSave`, which walks all 20 slots).

Natives (`EdTexConv.cpp`): `ed_tex_convert(src, dst, spec)` - channels from r g b a lum const or an atlas tile, with invert / scale / bias / centre / clamp, any size, DXT5 with mips; when the source is DXT5 and only
the alpha changes the colour blocks are copied bit for bit. `ed_tex_atlas(dst, spec)` - eight tiles. 1024 x 1024 takes well under a second (a Lua table would need minutes and 250 MB).

## Not done / left to the user

* Heights are a guess (above). No per-role bias (rock above grass).
* Normal maps are not touched; the 2xx use the albedo tile for them (nsize is the far scale of the heights): a map whose normal tiles differ from its albedo tiles looks a little different there.
* A macrotexture (Upper overlay of TTerrainXP / 0xx) cannot be carried into 1xx / 2xx (their macrotexture is the base layer's own alpha).
* There is no Lighting panel slider for SpecularColor (softness, contrast, rotation of the 2xx splatting): `World.Change{ spec_r = ... }` from the console, or a future slider.
* The preview in the dialog lists the warnings for "textures on"; after Convert the report lists the ones that apply to what was done.
* Not verifiable here (no editor, no GPU): the look of any converted map; the C++ was compiled and its maths tested with g++ only; MSVC build of `EdTexConv.cpp` and the Lua natives binding were only syntax checked
  against stub headers.
