# WP7: Terrace / Plane brushes, prop symmetry check, Lua syntax check, decal path

Work package 7 of [EDITOR_PORT_ANALYSIS.md](EDITOR_PORT_ANALYSIS.md) (section 14; findings of sections 9 and 10). Engine branch `port/wp7-brushes` (on `port/wp1-logic-lib`), worktree
`C:\Users\Marlo\Documents\GitHub\faf-re-port-wp7`, not pushed. Lua side: this checkout.

## What there is

| Piece | Where |
|---|---|
| Terrace and Plane (3 points) brush modes | native `moho/editor/EdBrush.h` (`Mode::Terrace`, `Mode::Plane`, `TerraceTarget`, `PlaneTarget`), `ed_terrain_brush` arguments 15..18 (step, planeX, planeZ, planeC), `ed_plane_through` (upstream's `faf::editor::PlaneThrough`); Lua `terrain.lua` (modes in the Lua loop too, `PlaneAddPoint`, `PlaneClear`, `PlaneFor(slot)`), `ui.lua` tools `terrace` / `plane` (Ctrl+click picks a point), tool panel rows in `gui/panels_objects.lua`, overlay of the points in `overlay.lua`, tips in `tipdata.lua` / `tooltips.lua` |
| Prop symmetry check | native `ed_up_check_props` (`EdUpChecksLua.cpp` over `CheckPropSymmetry`), `markercheck.lua PropSymmetry`, called from `validate.lua CheckMap` (kind `propsym`): shows in the Validation panel and, through `terrainchecks.lua Compose`, in the Terrain checks panel |
| Lua syntax check of the map scripts | native `ed_up_check_lua` / `ed_up_parse_lua_error` (`ParseLuaError`; the plan calls it `SplitLuaError`), `scriptcheck.lua` (`_scenario.lua`, `_save.lua`, `_script.lua` as they are on disk), `validate.lua CheckMap` (kind `script`, error: also stops the Release) |
| Decal path | native `ed_up_decal_path` (`DecalsAlongPath`), `decalpath.lua`, tool `decalpath` (Objects workspace) |
| Tests | native `moho/editor/tests/EdBrushUpTest.cpp` (`scripts/ed_native_tests.py`), Lua `selftest_wp7.lua` (listed in `selftests.extra`) |

## Behaviour

* **Terrace**: the ground is pulled towards the nearest multiple of the step height (panel slider "Step (units)", default 5 = upstream's 640 words). **Plane**: towards the plane through three
  points picked with Ctrl+click (the plane is height words = planeX x + planeZ z + planeC). The pull per dab is `min(1, strength x 0.2 x weight)` of the distance, like Flatten; Shift (invert) is
  ignored for both ("away from the nearest step" has no meaning). Upstream's blend is `min(1, strength x 8 x seconds) x weight`; the kernels (target heights) are the same, only the rate
  is the editor's own.
* **Plane and symmetry**: each symmetry image of a dab uses the plane through the images of the three points (`PlaneFor(slot)`), so the copies stay equal. Upstream writes one value per
  group of symmetric samples instead.
* **Prop symmetry**: under the editor's symmetry mode (not "off"), a prop with no prop of its blueprint within 2 units of one of its symmetric copies is unmatched. A summary (warning when the
  unmatched props hold reclaim mass, else a note; mass from `mapstats.ReclaimOf`) and the first 20 props, each at its place. A symmetry centre away from the map middle is handled by giving the
  native a field of `2 x centre + 1` samples; the modes that need a square field (diagonals, turns) are skipped when the centre is not on the diagonal.
* **Script check**: the three files are compiled with the engine's own parser (`luaL_loadbuffer`, nothing is run, nothing raises) and the first error is reported with its line:
  `script does not compile: x_script.lua:3: unexpected symbol near '='`. The editor has no code editor (maui has no multi-line edit control): open the script in your own editor, save,
  press Check now.
* **Decal path**: click points (Objects workspace > Decal path), pick the decal in the Decals panel, set size and overlap, Place decals: decals are laid end to end along the Catmull-Rom curve
  through the points, each turned along it (orientation.y = the curve's direction, the field upstream also reads as the yaw), one undo step, with symmetry images and the matching normals decal.

## Decision: a free decal path was needed

The Paths tool cannot do it: (1) every path mode shapes the terrain (`native = 'offset' | 'target'`), there is no terrain-free path; (2) its decals are scattered: `ScatterPlan` gives each
decal a random heading (`rnd() * 2 pi`) at a spacing, not a strip turned along the curve; (3) decals there are square and spaced, not laid end to end with an overlap. So `decalpath.lua` is a
small separate tool over upstream's pure `DecalsAlongPath`. Decals in this editor are square (`decals.lua` keeps one `size`), so length = width; upstream's rectangular strips (length != width)
would need the decal model to keep two sizes first.

## Verified

* `EdBrushUpTest`: 56 849 checks, 0 failures. Upstream's `HeightBrushTests` expectations (terrace 1000 -> 1280, plane 1000 + 20 x + 10 z, three points on a line have no plane) hold for upstream's
  `ApplyHeightBrush` and for our dab; 9 740 random samples at full pull and at partial pulls are identical to upstream's, word for word; a stroke of ten terrace / plane dabs through
  `MapDocument::EditHeights` is one undo step and undo restores every word.
* `selftest_wp7` (live editor, exe `main_ed_wp7_x64`): native dab = Lua loop for both modes (within one word), a strong dab puts the centre on a step / on the plane, `ed_cmd_undo`-style
  checksum compare after undo / redo, symmetric plane images, the syntax error of a script is found with its line (also through the Validation list), a prop without a partner is listed
  through the document, `selftest_terrain` and `selftest_brushshape` still pass.
* `python scripts/editor_lint.py`: 0 errors, 0 warnings.

## Not verified / open

* The orientation of a decal strip was checked by numbers (the decal's stored y rotation equals the footprint yaw, as in upstream's `EdDecals.cpp`) and by a screenshot of a placed strip, not
  against a strongly directional texture at close range.
* The check runs when the Validation panel runs (markers or terrain changed, or Check now); prop edits and symmetry changes alone do not trigger it.
* The pathing check of upstream (`EdPathing`) is not ported (out of scope: ours uses the field ops).
