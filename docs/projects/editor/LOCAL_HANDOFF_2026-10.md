# Handoff to the local session (2026-10)

Written by the cloud session that did the work below. **Nothing in it has been built or run.** The cloud sandbox has Linux, g++ and Python only: no MSVC, no Windows, no GPU, no editor. Every engine change was checked with `g++ -fsyntax-only` against hand written stub headers or with g++ unit tests, every Lua file with the Moho parser, and the repository with `python scripts/studio.py check`. The first MSVC build is the real compile check, and the first run on a real GPU is the real shader check. Expect typos.

## Where things are

| What | Where |
|---|---|
| Editor repo (this one) | `UnsilentMarLo/FAF_Studio`, branch `claude/grayscale-text-and-ui-fixes` (no PR open; none was asked for) |
| Engine reconstruction (not in git here) | the cloud container's `/home/user/engine_work/faf-re`, branch `editor`. Its content reaches you only as `engine/patches/*.patch` (0035 to the newest, see `ls engine/patches`). `studio.py build` applies new patches to your `engine/faf-re` checkout |
| Workspace (reference only) | `SupCom_Dev_Workspace`, game code in `faf_repo/fa` |

First steps after `git pull`:

1. `python scripts/studio.py build` (applies the new patches, compiles, stages, bumps the version patch number).
2. `python scripts/studio.py check` once. `gen_primbatcher_fx.py --check` could not run in the cloud.
3. `python scripts/ed_native_tests.py` with MSVC. The goldens of `EdFieldTest` / `EdT7Test` were regenerated under g++ and may differ by libm; regenerate them on MSVC if only last-digit differences show.
4. If the engine does not compile or a kernel does not compile, the error is almost certainly a typo in a never-compiled file. Fix it in `engine/faf-re`, commit on branch `editor`, `studio.py engine export`, commit the patch files here.

## Work done in the cloud session (all unverified in the editor)

Grouped by area; details are in the named docs.

- **Texture scale** (`texscale.lua`, `TEXTURE_SCALE.md`): stratum tile size derived from the texture's pixel size, floor `REPEAT_MIN = 20` (below that the repeat showed as a checkerboard on 512 px textures).
- **Brushes and overlays** (`EdOverlay*.cpp/.h`): overlays (brush, grid, slope, mask/field) are depth tested against the terrain with a distance adaptive quadtree (refine 16 px, merge 11 px for the slope; grid 20/14 px; field 8/5.5 px). Console switch `ed_overlay_depth`. Polylines, decals and icons are still drawn without depth (x-ray); decals should be depth tested later.
- **Slope view** (`slope.lua`, `panels_view.lua`, `SLOPE_VIEW.md`, `scripts/skirt_stats.py`): Mobile units / Structures, structure Rule (`Buildings (ring)` or `Not levelled (radar, defence)`), Skirt/Footprint/Limit discrete sliders, the 24 step gradient kept on purpose (it tells the user about the terrain). Engine facts used are in `SLOPE_VIEW.md`. The `unspecified MaxGroundVariation = 1.0` default is read from the constructor, not confirmed in the exe.
- **Generators** (`fieldgen.lua`, `graphnodes*.lua`, `panels_fields.lua`): Generate section, `Terrain noise` node, fractal `style` (`classic` / `erosive`) and `erosion` strength. The Hills, Mountains and Plains presets now use the erosive style (hills 1.5, mountains ridged 1 and massif 1.5, plains 1); Badlands, Dunes and Rocks stay classic. This is a look change nobody has seen: compare in the editor and set the numbers back if slopes look too plain.
- **Erosion** (`erosion.lua`, `erosionquality.lua`, `EdErosion.cpp`): feedback rounds, stream power, creep; new defaults (hydraulic iterations 60, droplet rounds 32, creep 2).
- **Stratum recipes** (`recipes.lua`, `roledetect.lua`, `maskgen.lua`): 8 roles, role detection from texture names and colours, soft ramp rules, base layer handling. The colour heuristics have never seen real textures.
- **Layer converter / shader browser / convert dialog** fixes (`gui/convertdialog.lua`, `panels_assets.lua`, `LAYER_CONVERSION.md`, `MAP_TEXTURES.md`).
- **Markers, chains, camera, graph UI, console, Map heights refresh, symmetrize "Turn by X"**: see git log of the branch. Open: the cause of the Map heights bug (stroke merge) was never proven; a revision stamp (`TerrainEpoch.Stamp()`) re-evaluates the graph now.
- **Unit viewer / mod icons**: fixed in Lua, never seen.
- **Version**: `editor/VERSION` (0.5.x), bumped by `studio.py build`.
- **CPU / render performance** (`PERFORMANCE.md`): Present busy wait replaced by a sleep, frame limiter, forced Lua GC reduced, frame-count Lua timers made time based, shadow cache, water skip, off-screen UI culling. All behind console variables (`ed_present_wait`, `ed_fps_limit` ..., `ren_ShadowCache`, `ren_WaterSkipDisabled`, `ui_CullOffscreen` ...) so each can be switched off when the picture differs.
- **GPU compute** (`GPU_COMPUTE.md` is the manual, read it first): Direct3D 11 compute device loaded at run time next to the D3D9 renderer. Kernels in `gpu/*.hlsl` (also compiled as C++ by the tests via `gpu/hlsl_cpp_shim.h`), `EdGpuShaders.generated.h` made by `scripts/gen_gpu_shaders.py` (checked by `studio.py check`). Ported and registered ops: `blur`, `box`, all noise generators (`perlin simplex ridged billow fractal musgrave fbm_damped voronoi cells cracks craters dunes island`), `occlusion bilateral diffuse blur_dir dwarp slope curvature aspect hillshade normal_map`, `erode_hydraulic`, `erode_droplet`, and (GP4) `settle thermal thermal_map erode_rocksoil erode_snow erode_wind erode_glacier morph convolve unsharp edge blur_slope slope_limit rockiness stratify wetness flow`. Every GPU op falls back to the CPU on any failure.
- **GP4 ports** (section "More field ops (GP4)" in `GPU_COMPUTE.md`, with the decision table and CPU timings from `tests/EdFieldBench.cpp`): 17 more ops, most bit equal to the CPU op in the emulator. `wetness` / `flow` use a tiled sweep (32 x 32 tiles, borders exchanged until nothing changes; 54 to 66 sweeps on fractal terrain, about 420 on a worst case serpentine channel at 200 x 200). A work gate (`WorthIt` in `EdGpuFieldCommon.h`) keeps cheap filters on the CPU: at least 8 taps per sample and samples x taps >= 380 x `ed_gpu_min_cells`; iterated ops need 16384 samples; `ed_gpu_min_cells 0` turns every gate off (use it to force the GPU when testing small fields). Kernels are named `field_*.hlsl`. Emulator tests: `EdGpuFieldTest` (2211 checks).

## What to verify first, in this order

1. **Build** (see "First steps"). Report/fix compile errors.
2. **GPU**: command palette (Ctrl+Shift+P) `dev.gpu`: adapter, self test, op list. If a kernel does not compile the `EDITOR GPU compute:` log lines say which. First suspects (GP4): the 4 KB private array `float acc[1024]` with `break` in `field_wetsweep` / `field_flowsweep` (fallback: 16 x 16 tiles), the 1024 thread group with a 1024 step loop in `field_wetrank`, `PHASES_BEGIN` plus `InterlockedMax(asuint)` in `field_glacier_a`, `int %` in `field_convolve`, `unroll` loops with `continue`, uint views of float buffers. First suspects (GP2): `static const int kDirX[8]` tables in `erosion_common.hlsli`, `InterlockedAdd` on `RWStructuredBuffer<int>`, 8 UAVs in `erosion_drop_resolve`, HLSL intrinsic names used as identifiers (`dst`, `noise`, `frac`, `lit` were already renamed).
3. **GPU A/B** (GPU_COMPUTE.md "Verify on your machine" and the GP2 checklist): Hills preset on 512 x 512 or larger, once normally, once with the solver's `CPU only = 1`; compare times in `/perf` (`field ops: gpu ...`) and hillshades lit from two sides; `ed_gpu_info().lastOpError` empty; stress 2048 and 4096 hydraulic at 300 iterations (watch for a driver reset: the loop submits in about 100 ms slices); on a card under 4 GB the 4096 run must fall back quietly. Switch off with `ed_gpu_compute 0` to compare.
4. **CPU use**: `ed_perf_loop`, `ed_perf_threads`, `ed_render_stats`, the perf report; the editor at idle should no longer sit at 100 % of one core. If the picture changes, switch the variable named in `PERFORMANCE.md` off.
5. **Overlays**: brush, grid, slope, mask overlay on a hill from several camera distances; they should lie on the terrain, not show through it, and refine smoothly with distance. Check the depth buffer is valid at the overlay stage (assumed, not seen), `ed_overlay_depth 0` is the old x-ray.
6. **Self tests**: `return import('/lua/editor/selftest_X.lua').Run()` for texscale, parity, graphbase, fieldgen, fields.
7. **UI layouts** changed without ever being seen: Slope panel (rule buttons use `W.Flow`; the renamed button is 190 wide), Fields tab, erosion panel sliders (GPU tips), shader browser layers table, convert dialog, Generate graph marquee, Chains tab.
8. **Recipes** on real textures (roles: sand vs grass confusion was reported before).

## Known weaknesses and open decisions

- **GPU hydraulic erosion is a different solver** than the CPU one (8 pipes, friction, depth dependent capacity, slope cap 0.4, 3 x 3 spread). Seen only in emulated hillshades: 300 iteration runs lay a scalloped sediment apron around an isolated mountain; a one-cell cliff keeps a light scalloped lip at 100 steps; it does not raise the lowest ground like the CPU solver (bottom 5 % change -0.2 against +0.47 on the mounds test terrain; partly open edge loss, not investigated). The erosion panel's coarse preview scales the CPU solver's rates and does not suit the GPU solver. Tunables: `flux_damp`, `depth_gain`, `erode_spread`, `slope_cap`, `rain_noise` (panel sliders marked "(GPU)"), `speed_pow`, `speed_floor`, `shear_floor` and `steer_every` (graph parameters only).
- **Droplet pit filling** (`drain_pits`) still runs on the CPU every 8th round (`steer_every`); at 4096 x 4096 this could stall.
- **Not ported to the GPU** (reasons in the GP4 table): `erode_stream` (29.6 s at 2049 x 2049 for 10 iterations; the pit breaching is a priority flood whose result depends on the CPU's bucket order, so it needs a different breach algorithm; the doc gives the order of work), `slope_area`, `basin_depth` (same pit fill), `reach` (Dijkstra), `regions`, `path_dist` and the path ops, `symmetrize` (double precision `atan2` and 1e-9 snapping). Plain point filters (amplitude, terrain_mix, levels, remap, terrace, color_ramp, rect_mask ...) stay on the CPU on purpose: upload and download cost more than the op.
- **Fallbacks to the CPU** (quiet): `cpu_only = 1`, a mask of another size, unknown output, a field under 4 x 4 or beyond the memory budget (about 25 floats per sample for hydraulic, 26 for droplets).
- **Decals, polylines, icons** are still not depth tested.
- **Pre-existing and not touched**: `scripts/make_graph_presets.py` fails (missing `make_graph_library.py`).

## Rules the cloud session worked under (keep them)

CLAUDE.md of this repo: Moho LuaPlus 5.0 (no `^ # %` operators, no `string.match`, at most 32 upvalues per function; check every changed Lua file with the parser in `SupCom_Dev_Workspace/scripts/mohlua`), `studio.py check` after every change, Maui does not clip (lay rows out with `W.Flow`), every number setting is a `W.Slider`, every widget has a tooltip in `tipdata.lua`, plain natural English UI wording. Never commit or upload an exe, never overwrite `ForgedAlliance.exe`. Do not stop processes by name. The editor needs no determinism: the cloud session made the sim, the editor loop and the GPU paths non-deterministic on purpose.

## Useful commands

```
python scripts/studio.py build [--no-bump]
python scripts/studio.py check [--full]
python scripts/studio.py engine export          # after committing in engine/faf-re
python scripts/studio.py version [--bump minor|--set X.Y.Z]
python scripts/gen_gpu_shaders.py [--check|--lint]
python scripts/ed_native_tests.py               # MSVC; EdGpuTest, EdGpuErosionTest, EdGpuGenTest ...
```

Console: `dev.gpu`, `/perf`, `ed_gpu_compute 0|1`, `ed_gpu_min_cells N`, `ed_overlay_depth 0|1`, `ed_present_wait`, `ed_fps_limit`.
