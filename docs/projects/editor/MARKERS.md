# Markers outside the map and in the air (2026-10-18)

Bug report (hands-on): after loading a real map, thousands of markers (all kinds) were drawn in the black void around the terrain and a cloud of icons and labels floated high above it (side view).

## Cause: overlay objects of the previous map stayed alive

* Marker icons, area lines, selection rings and ground splats are objects of the engine's retained overlay (`EdOverlay.cpp`, `ed_overlay_*`). They live in **static tables of the engine process** (`static std::map` of lines, icons, decals, node grids), not in the Lua state.
* Opening a map is `Maps.Open` -> `control.LoadMap` -> `ExitGame()` -> front end -> `uimain` hook -> new session. The UI Lua state is rebuilt, so `overlay.lua`'s id lists (`markerIds`, `areaIds`, ...) are lost, but the engine still holds every `mi:<name>` icon of the old map. The new map overwrote the ids it shares (`ARMY_1`, `Mass 01`, ...); every other icon of the old map stayed, at the old positions and heights: outside a smaller new terrain (the void), above a lower one (the air). `ed_overlay_clear()` was only called when play mode started or the editor shut down.
* Reproduced: `adaptive_hutts_clutch` (1,024 units, 3,631 markers) then another map: 4,361 overlay objects before the new map had drawn anything; after the fix the second map (`twin_lands`, 1,502 markers) shows 1,838 (its own icons + lines), and a screenshot of the second session no longer shows icons over the void.

### Fix (Lua only)

* `control.ClearOverlays()` (`ed_overlay_clear`) runs in `LoadMap` (before leaving), in `control.Start` (every new session) and in the `uimain` hook (front end of an editor run).
* `overlay.Update` clears once per Lua state (first frame) and whenever `Map.Doc` is a different document, then rebuilds.
* A cleaner root fix would be in the engine: empty the overlay tables when the session is destroyed (`EdOverlay.cpp`). Not done here: an engine build stops every instance. Suggested for the next engine build.

## Survey of the 411 maps in the user's maps folders (save files only)

`markercheck.SurveyAll(outPath)` writes one line per map; `selftest_markers` pins two numbers of it.

* 407 maps have markers; the largest sets are `adaptive_hutts_clutch` (3,631), `valley_of_perfume` (1,828), `adaptive_dark_liver` (1,765), `twin_lands` (1,502), `adaptive_skadi` (1,410).
* **22 maps have markers outside the map** (at most 18 each: `sc2_ca_c06` 18, `adaptive_theta_passage` 11, `sc2_ca_c03` 7, `sc2_ca_u05` 6, `sc2_ca_u06` 5, `twin_lands` 5 ...), **30 maps have markers outside their playable area (AREA_1)** (`sc2_ca_u03` 188, `sc2_ca_u05` 130, `sc2_ca_c03` 68 ...). Converted SC2 campaign maps dominate both lists.
* Stored marker heights are wild on converted SC2 maps (`sc2_ca_u04` -2,342, `sc2_ca_c06` -785 .. 1,814, `sc2_ca_i04` -707 .. 923): their markers stand on the mesh scenery, not on the height field. The other maps stay within 0 .. 123 (no non-SC2 map has a marker above 200).
* So the real data has tens of outside markers, not thousands: the thousands came from the stale overlay.

## What the editor does now (decisions)

| Case | Behaviour |
|---|---|
| Inside the terrain | unchanged: the stored height follows the terrain field every few frames (`markervis.lua`), icons and meshes stand on the ground |
| Outside the map | data is kept; icon, mesh and label are drawn on the terrain at the **nearest map edge point** (`markercheck.DisplayPos`), greyed (`A0909098`); Validation shows **one entry** ("N markers are outside the map ..."), selecting it selects them; **Pull inside** (button + command `validate.pullmarkers`) moves them onto the map edge, one undo step (`Tools.ClampMarkersToMap`) |
| Outside AREA_1, inside the map | drawn normally but greyed; one Validation entry with the names |
| NaN / huge coordinates | drawn at the map corner, greyed; one Validation entry |
| Mesh maps (height field below the scenery) | markers follow the field (the sim's reference); no change |

## Files

`markercheck.lua` (Analyse, DisplayPos, SnapY, Survey, SurveyAll), `overlay.lua` (reset, grey icons, display positions), `markervis.lua`, `validate.lua` (aggregated entries, `PullMarkersInside`), `tools.lua` (`ClampMarkersToMap`), `gui/panels_objects.lua` (button, command), `control.lua`, `schook/lua/ui/uimain.lua`, `selftest_markers.lua` (registered in `selftests.extra`).

## Look by type, camera frame

`markervis.Style(type, storedProp, storedColor, name)` picks the 3D object of a marker by **type** (table `STYLES`: game mesh, size factor; tint = the type's colour from `MarkerTemplates`, brightened x1.5), because saved markers mostly carry the blank prop whatever their type. Unknown (mod) types take the stored prop, then the template's, then the blank marker. Start positions (`ARMY_<n>`) are bigger and gold. Display only: nothing is written to the save data. Game data has meshes for Blank, Camera, Combatzone, Defensive, Expansion, Mass, Hydrocarbon only; the other types share one and differ by size and tint.
`camframe.lua` draws the field of view of a **selected Camera Info marker** (eye from focus, zoom, heading, pitch; four edges to the ground, the outline draped on the terrain, a line of sight); model and assumptions in its header. Self test: `selftest_camframe.lua`.

## Side finding (not fixed)

Opening `sc2_ca_c06` or `adaptive_theta_passage` from a running editor started a normal game session (HUD, AI armies, sim running), not the editor (`control module started` never logged), so the editor stops answering its command channel. Probably the campaign / adaptive map script path; unchecked on a clean base.
