# Mesh terrain in the editor viewport (M5a/M5b, 2026-10-19)

Status: built on branch `ed/meshview` (Lua) and in the nested engine repository `engine_decomp/faf-re-upstream`, branch `editor` (commit `c3c547b` and the commits after it). Needs the new engine exe (see "Build and deploy"). Research and plan: `docs/projects/editor_research/MESH_MAP_EDITOR_NEEDS.md` section 4 (P1-P16), reference renderer `automation/terrainmesh/meshterrain.cpp`.

## What you get

A map whose scenario says `TerrainSystem = 'mesh'` (converted SC2 maps such as `sc2_mp_304`, `sc2_mp_201`, and any map made with the mesh importer) is drawn in the viewport with its SCM v5 patches instead of the height field: two blended texture layers, SC2 normal maps, the three baked light masks, SC2 sun and shadow colours, FA's shadow map (the mesh receives and casts), the water ramp tint under the water level, water to the horizon (or the void colour of canyon maps) where there is no ground, and SC2's sky pieces. The View panel has a *Ground shows* row: **Mesh** | **Height field** (the fallback look the unpatched game shows) | **Both**.

Measured on this machine (editor window 1280 x 729): `sc2_mp_201` (450,248 vertices, 19 patches) 200 fps in all three modes, CPU time of the mesh draw 0.1 ms; all 37 mesh maps of the maps folders load (`ed_mesh_load` 0.01 - 0.2 s; largest `sc2_ca_u02` with 592,863 vertices, 29 patches).

## Design

* **Where it lives.** New files in `moho/editor/`: `EdMeshData` (CPU side: manifest, SCM, lookup grid, height / ray queries), `EdMeshDraw` (Direct3D 9: shaders, buffers, textures, the draw), `EdMeshLua` (natives `ed_mesh_*`), `EdMeshTerrain.h` (the interface). Hooks in `HighFidelityTerrain.cpp` (the only existing engine file touched):
  * `DrawNormals`: after `LoadShaderVars`, the mesh is drawn instead of `DrawTriangles()` (height field surface); in *Both* mode the height field first, then the mesh pulled slightly towards the camera (depth bias), so the field shows only where it lies above the mesh;
  * `DrawTerrainDepth`: the mesh is the shadow caster (alpha tested like the patch);
  * `DrawTerrainSkirt`: no height field skirt around a mesh;
  * `UpdateRenderContext`: remembers the world camera for picking.
* **Camera and shadow come from the engine objects**, not from shader constants read back (what the retail patch has to do): `clip = ((p * View) * (s,s,s,1)) * Proj` with `s = 1.0005` (terrain.fx `TerrainErrorScale`) from `GeomCamera3`, the shadow matrix and shadow map from `Shadow` (`mCamera.viewProjection`, `GetShadowTexture()` -> `RenderTargetD3D9::GetTexture()`). Matrices are the engine's row-vector ones: `row_major float4x4` and `mul(float4(p, 1), M)` in the shaders.
* **Raw device, state block around every draw.** The gal device's `IDirect3DDevice9` (as EdPopout uses it); `D3DSBT_ALL` captured before and applied after, so the engine's state cache stays valid. Resources are `D3DPOOL_MANAGED` (they survive a device reset) and are rebuilt when the map or the device changes.
* **Files through the virtual file system.** `FindFile` then `DISK_ReadFile` (the engine reader wants the resolved path): maps in folders and in archives work, and textures come from `<manifest folder>/<path>`. The water ramp is the map's own (`CWaterShaderProperties::mWaterRamp`).
* **Shaders** are the patch's, ported with the row-major change; the sampler layout is unchanged (0-1 layers, 2-4 light masks, 5 shadow map, 6 water ramp, 7-8 normal maps, 9-10 specular masks).
* **Lua** (`meshview.lua`): `OnMapLoaded` (hooked into `map.lua` Load) loads `info.TerrainMesh` or unloads the previous map's mesh (the engine keeps it across sessions, this Lua state starts empty: the first call of a session always settles it, the same trap as the marker overlay); `SetMode` / `Mode`; `GroundAt(x, z, fallback)` (the highest mesh surface up to 40 units above the field, else the field); `ScreenRay` / `MouseRay` (ray against the mesh through `ed_mesh_pick`).

## Placement and picking on a mesh map

* Mouse picking (`ui.lua` `ScreenToWorld`, `MouseWorld`) uses the mesh ray when the mesh is shown, so a click lands where the ground is seen.
* **Props** are placed at the mesh height (`props.lua`): the converter does the same (SC2 stands props on the mesh, up to 247 units from the field).
* **Markers** keep the height field's height in the file (the sim's ground, `convert.py`) and are *drawn* on the visible ground (`markercheck.DisplayPos`, overlay icons and 3D marker props).
* Overlay lines and rings (areas, brush ring, selection) hug the visible ground (`overlay.lua` `GroundHeight`).
* The height brushes still edit the **height field** only; the mesh does not move. That is by design (the mesh is imported, never sculpted); divergence tools (F8-F10) are a separate stage.

## Natives

`ed_mesh_load(vfsPath)`, `ed_mesh_unload()`, `ed_mesh_mode([0|1|2])`, `ed_mesh_info()`, `ed_mesh_height(x, z[, ceiling])`, `ed_mesh_ray(ox, oy, oz, dx, dy, dz[, max])`, `ed_mesh_pick(px, py, vw, vh)` (ray under a pixel of the world view), `ed_mesh_range([margin])`. Without them (old exe) `meshview.lua` does nothing and every caller falls back to the height field.

## Status of the plan items (MESH_MAP_EDITOR_NEEDS section 4)

| P | Item | State |
|---|---|---|
| P1 | activation from the scenario, per-map teardown | done (Lua: `OnMapLoaded`; natives load by VFS path) |
| P2 | surface pass (blend, light masks, RNM, SC2 lighting, tone roll-off, water ramp tint, haze, glow in alpha) | done, patch shaders ported |
| P3 | camera incl. `TerrainErrorScale` | done (from `GeomCamera3`) |
| P4 | shadow receive and cast | done (cast: depth pass; receive: FA's map, SC2 shadow colour). Not checked: tall casters outside the shadow camera's fit (research question 7) |
| P5 | no skirt | done for the skirt; the black playable-area band and FAF's world border are untouched (they show the map's own borders, which is what an editor wants) |
| P6 | void fill, sky | done (water / void colour quad at the far plane, sky pieces in manifest order) |
| P7 | water | **partly**: FA's own water over the map and its water pass test against the mesh depth, so shores and wave highlights are right; the manifest's `water_map` (mesh-derived depth) is not bound, so water shading depth still comes from the height field; no `water_beyond` / `water_inside` planes (the far fill replaces them); no playable outline on the water |
| P8 | decals on a mesh map | **not done**: decals drape over the height field's tessellation, so on cliffs and platforms they hide under or float over the mesh (the three fixes of the patch: depth pull, stencil band, cull box 4096) |
| P9 | range ring / vision volumes up to `mesh_high + 30` | done (`ApplyHeightBands` after `ed_mesh_load`: widens `patch_*MapHeight` to the mesh's lowest vertex - 5 .. highest + 30 inside the playable area and re-inits the viewport's range and vision renderers, as `Sim_Create_exxt` does). Built, loads and draws; the rings themselves were not looked at |
| P10 | cut-outs under structures | not done (visual only in the retail patch) |
| P11 | prop light, P12 prop scale | not done (P12 is the editor's own scale-loss bug, MESH_MAP_EDITOR_NEEDS section 0 item 5) |
| P13 / P14 | terrain flattening / structures avoid void | sim side, not part of the view |
| P15 | Mesh Terrain UI mod behaviour | not done |

## Build and deploy

The engine source is the nested repository `engine_decomp/faf-re-upstream` (branch `editor`, not part of the workspace repo): the commits there are the code. The editor needs a new exe: `engine_decomp/_deps_src/build_engine.bat`, then copy `faf-re-upstream/output/main/x64/Release/main_x64_la.exe` to `run_x64/bin/main_x64_la_p2.exe` (stop every instance first). For testing without that: `python scripts/editor_inst.py start <tag> --exe main_x64_la_meshview.exe` (a private copy, built by `scripts/_mv_build.sh` of the worktree, not committed). The Lua side is safe on the old exe.

## Tests

`selftest_meshview.lua` (listed in `selftests.extra`): a fixture made with the mesh importer (a sloped plane and a deck above it) is mounted at `/maps/selftest_meshview` and loaded; counts, `ed_mesh_height` with and without a ceiling, `ed_mesh_ray` hits, normals, patch / material numbers, misses, `ed_mesh_range`, modes, unload; when `sc2_mp_002` is in the maps folders the native `mesh_high` must equal what the Lua SCM reader (`meshscan.lua`) finds and the vertex count must equal the manifest. `Check2()` a few seconds later: the viewport has drawn the mesh (`draw_ms > 0`). Without the natives the test reports PASS (skipped).

Screenshots (this machine, 2026-10-19): `sc2_mp_304` (islands, water to the horizon, cliffs), `sc2_mp_201` (bridge, baked lighting), `sc2_mp_002` (full mesh with scenery around the playable area), mesh / height field / both of the same view.

## Decisions for the user

1. **Marker height**: the file keeps the field height (what the sim and the converter use); the viewport draws markers on the visible ground. Alternative: store the mesh height (then the sim's marker would float or sink by the divergence).
2. **Both mode** shows the field only where it is above the mesh. Alternative: a half transparent field (needs a shader of its own for the field pass).
3. **Decals on mesh maps** (P8) and the mesh-derived water map (P7): worth the work only if the decal tool is used on mesh maps / the water shading depth matters in the editor; say so and they are next.
