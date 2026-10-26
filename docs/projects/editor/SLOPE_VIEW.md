# Slope view: structures (skirt size, ring rule)

Status 2026-10-23. The View panel's slope view (`slope.lua`, `gui/panels_view.lua`, native `EdOverlaySlope.h` / `EdOverlay.cpp`) rates the ground the way the sim
checks it. This page covers the structure side; mobile units are in `MAP_EDITOR_DESIGN.md` 19.2.

User request: "For structures add a slider for the most common skirt sizes, don't do it per blueprint."

## What the engine checks (read from the reconstructed engine, `src/moho/sim/STIMap.cpp`, `RUnitBlueprint.cpp`)

`OCCUPY_Check` (0x005652E0) for a structure takes the skirt rect from `RUnitBlueprint::GetSkirtRect(pos)`:

    xLower = lrint(pos.x - footprintSizeX / 2)            (same for z)
    x0 = SkirtOffsetX + xLower          x1 = x0 + SkirtSizeX      (a size of 0 means the footprint size)

and runs one of two checks on it, both with the **inclusive integer rect** `[int(x0) .. int(x1)] x [int(z0) .. int(z1)]` of height **samples** (so a skirt of N cells has
N + 1 samples per side):

| `Physics.FlattenSkirt` | check | rule |
|---|---|---|
| `true` (nearly every building) | `OCCUPY_CheckEdgeFlatness` (0x00564F80) | only the ring of samples one cell outside the rect: rows `z0-1` and `z1+1` over `x0-1 .. x1+1` (walked left to right), then columns `x0-1` and `x1+1` over `z0 .. z1`. `min` / `max` over the ring; `pivot = ceil(lastSample)`, where `lastSample` is the sample read last: `(x1+1, z1)` (the final iteration of the column walk). Deviation `max(max - pivot, pivot - min)`. The structure fits when `MaxGroundVariation >= deviation`. The ground inside the skirt is not looked at: it is levelled when the structure is built. |
| `false` / missing (default) | `OCCUPY_CheckAreaFlatness` (0x005651F0) | highest minus lowest sample over the whole rect, against `MaxGroundVariation`. |

The loader (`RUnitBlueprint.cpp` ~634) raises `SkirtSize` to at least the footprint size and clamps positive skirt offsets to 0. `RUnitBlueprintPhysics()` defaults
(constructor, line ~351): `FlattenSkirt = false`, `MaxGroundVariation = 1.0f`, skirt sizes 0. The 1.0 default is the reconstructed constructor; nothing in FAF's Lua sets it
(the 2024-07-07 FAF changelog lists blueprints going "1.0 -> 1.1 / 1.2", consistent with 1.0 as the base). **Not checked against the exe's disassembly.**
Samples outside the field are clamped (`SampleClampedElevation`); `OCCUPY_Check` also refuses skirts that leave `[0, width-1]`.

Colour value in the view for a cell `(cx, cz)` and a skirt of N cells: the rect is `x0 = cx, x1 = cx + N, z0 = cz, z1 = cz + N` (the cell is the skirt's top-left cell).

### Quantisation (native kind 2, `ring`)

Heights are 16 bit words, 128 per world unit; `SampleClampedElevation` is `word * (1/128.0f)`, exact in a float, and so are the differences and `ceil` for values below
512 units. So the engine's float result is exactly an integer number of words, and the native rating is that number with **no rounding**:
`pivotWords = ceil(lastWords / 128) * 128`, `rating = max(maxWords - pivotWords, pivotWords - minWords)`. The tile store, block levels (max reduction) and colour steps are
unchanged (a rating is words, the colour step divides by the limit in world units). The fits test is `rating / 128 <= limit`, the engine's own test.

## Blueprint data (`python3 -I scripts/skirt_stats.py`)

All 606 `*_unit.bp` of `faf_repo/fa/units` run as Lua; structures = category `STRUCTURE` or `MotionType RULEUMT_None`: 402 blueprints, of which 157 are campaign
decoration (`CIVILIAN`, mostly 3 x 3 area rule and 6 x 6 ring rule). Skirt = after the loader rule above.

`MaxGroundVariation` x `FlattenSkirt` (all 402): ring + 1.0 (no field) 148; ring + 1.1: 63; ring + 1.2: 5; area + 1.0 (no field) 155; area + 50: 15 (walls); area + 512: 16
(extractors, hydrocarbon). So the rule that matters for slope covers 371 blueprints (225 not campaign decoration).

Skirt size of structures with `MaxGroundVariation <= 2` (371 blueprints; the 225 playable ones in brackets):

| skirt (cells) | ring rule | area rule | typical structures |
|---|---|---|---|
| 1 x 1 | 3 (3) | 34 (34) | tech 1 point defence, anti-air, torpedo launchers, radar, sonar |
| 2 x 2 | 58 (58) | 0 | power generators, mass storage / fabricators, tech 2 point defence, anti-air, artillery, TML, radars, engineering stations |
| 3 x 3 | 10 (10) | 82 (0) | tech 2 torpedo launchers, strategic missile defence, counter-intelligence (area: campaign decoration) |
| 5 x 5 | 0 | 3 (3) | campaign structures |
| 6 x 6 | 76 (33) | 0 | shields, nuclear launchers, air staging, tech 2 power, tech 3 mass fabricators (ring: 43 more are campaign decoration) |
| 8 x 8 | 59 (50) | 0 | land and air factories (all tech levels), tech 3 power, tech 3 / experimental artillery, nuclear experimentals |
| 9 x 9 | 2 (1) | 0 | Novax Center (experimental) |
| 10 x 10 | 6 (6) | 0 | quantum gateways, Paragon, Aeon experimental artillery |
| 12 x 15 | 0 | 20 (20) | naval factories (all of them: area rule, 12 x 15, not square) |
| 20 x 20 | 2 | 0 | campaign decoration |
| other | 0 | 16 (7) | 0 x 0 (no footprint data), 1.1 x 1, 1.5, 3.9, 5.5 x 2, 0.7 x 0.55, 2 x 4, 2 x 6, 4 x 6: campaign and test units |

Ring-rule limits by size (playable buildings): 1, 2, 3: 1.0; 6: 1.0 (18) or 1.1 (15); 8: 1.1 (48) or 1.2 (2); 10: 1.0 (4) or 1.2 (2).

Cumulative coverage of the 225 playable structures by frequency: 2 (25.8 %), 8 (48.0 %), 1 (64.4 %), 6 (79.1 %), 12 x 15 (88.0 %), 3 (92.4 %), 10 (95.1 %), 5 (96.4 %).
By tech level (the larger side of the skirt, `MaxGroundVariation <= 2`): tech 1: 1, 2, 6, 8, 15; tech 2: 1, 2, 3, 6, 8, 15; tech 3: 1, 2, 3, 6, 8, 10, 15 (and one with no data);
experimental: 8, 9, 10. Walls (50) are 1 x 1 or 3 x 3 and ignore slope.

### Choice

**Structures (skirt size slider): 1, 2, 3, 5, 6, 8, 10, 12, 15** (nine stops; 217 of the 225 playable structures, 96.4 %, have exactly one of these as their skirt, the other 8 are the Novax Center at 9 and
7 campaign / test oddities). 4 and 7 never occur and are left out; 9 and 20 are one or two blueprints; 12 and 15 are the two sides of the naval factory
(12 x 15 is not square: a square window cannot show it, so both sides are offered). The maximum, 15, is below the native `kMaxWindow = 16`. Default 2 (the most common).
Limit slider stops (`MaxGroundVariation`): 1.0, 1.1, 1.2; default 1.0 under both rules. Walls (50) and extractors (512) are not offered ("ignore slope" note).

**Mobile units (footprint slider): 1, 2, 3, 4, 5, 6.** From `lua/footprints.lua`: the footprints with a `MaxSlope` are Vehicle 1x1, 2x2, 5x5, Amphibious 1x1, 3x3, 6x6 and
WaterLand 1x1 .. 4x4; the bigger ones (Water 8x8, 11x11, SurfacingSub 12x12) are water-only and have no slope rule, so 8 and 12 are not offered.

## What the panel does (View panel, "Slope shows")

- Mobile units / Structures buttons. Structures: **Rule** toggles `Buildings (ring)` (default; native kind `ring`) and `Not levelled (radar, defence)` (renamed from "Area (extractors, walls)": extractors and walls ignore slope) (native kind `build`), a
  **Skirt size (cells)** slider (a W.Slider over the stops: bar, - / + step to the neighbouring stop, a typed number goes to the nearest), a **Limit** slider, and under the
  legend a line with the structures that have this skirt size, the explanation of the selected rule and the note "Walls (50) and extractors (512) ignore slope."
- Mobile units: the **Footprint (cells)** slider. The choices (skirt, footprint, rule, limits) are remembered in the user settings (`slope.*`, `userdata.lua`).
- The status line readout of the cell under the pointer uses the same kind and window (`ring deviation 0.42 / 1.00 (6x6)`).
- Engine compatibility: `ed_overlay_slope_caps()` lists the kinds the engine knows (`path`, `build`, `ring`). Lua falls back to `build` (the area rule, with a note in the
  explanation) when the function or the `ring` entry is missing, so a new Lua with an old exe still works; an old Lua with a new exe only uses `path` / `build`.
- `unitfit.lua` `EdgeFlat` (the placement ghost) is the same walk in Lua; `selftest_slope.lua` compares the native ratings with a Lua port of both engine checks on a made-up
  terrain.

## Tests and verification

- `EdOverlaySlopeTest.cpp` (g++, no engine): the ring rating equals a float transliteration of `OCCUPY_CheckEdgeFlatness` (`std::ceil` on the last sample, `std::min` /
  `std::max` over the ring) on 3 random terrains (rough with cliffs, gentle, nearly flat) for every skirt 1 .. 16 at 120 random cells each, including cells hanging over the
  field edge, and the fits verdicts for limits 1.0 / 1.1 / 1.2 agree (both outcomes occur); the tiled sliding-extreme `RateTile` equals the reference `CellRating` for
  windows 1, 2, 3, 5, 8, 12, 15, 16 at tile origins 0, 64, 192, 256; hand cases (ceil pivot, the pivot is the sample `(x1+1, z1)` and not the corner `(x1+1, z1+1)`, skirt
  interior ignored); store invalidation for the ring (the cell after a changed sample). A mutation (pivot row off by one) makes the tests fail.
- Not verified here: the editor and the MSVC build were not run; the Lua part was only parsed (and `slope.lua` / the logic half of `selftest_slope.lua` exercised under a Lua 5.4
  shim); the native half of `selftest_slope.lua` needs an editor session.
