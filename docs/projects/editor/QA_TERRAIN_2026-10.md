# FAF Studio: QA pass 2 on the terrain features, 2026-10-19

Branch `ed/qa3` (worktree `.claude/worktrees/ed-qa3`, instance `qa3`). Method: **real** mouse and keyboard (SetCursorPos / mouse_event, keybd_event) on a blank map and on
Seton's Clutch (1025 x 1025, 5200 props); state read back with Lua (doc checksums, history depth, graph / path / selection tables) and screenshots.
Findings: posted mouse messages do not drive the engine's Dragger (drags need the real cursor); the editor window must be the foreground window (an idle window
answers nothing), and `editor_inst cmd` clicks the title bar after 6 s of silence, which can race with a test click.

## Fixed (small commits, checks in `selftest_terrainqa.lua`, registered in `selftests.extra`)

| # | Finding | Fix |
|---|---|---|
| 1 | Graph keys (Ctrl+C / V / D / Z / Y, Delete) never acted on the graph: `GetMouseScreenPos()` is `{0, nan}` over panels, so "pointer over the canvas" was always false (Ctrl+Z undid the map instead). Paste position had the same problem. | Hover set built from enter / exit events of the canvas controls; last pointer position kept for Paste. |
| 2 | A new node was placed on top of an existing one (hit test then picks the lower one) and could land off screen. | `FreeSpot` (nearest free place), `Reveal` (pan into view). |
| 3 | Loading a preset / file reused node ids with other types: stale header colour, ports and title. | View is rebuilt when the type of an id changes. |
| 4 | Mask view of the graph did not follow the selection (only re-evaluated when the layout changed). | Checked on every tick. |
| 5 | **Mask and terrain type overlays were wrong in any world view that does not start at the window corner (Generate workspace: mask view showed nothing).** `UnProject` takes window coordinates; `overlaywin.Window` passed view coordinates. | Add view Left / Top. |
| 6 | Flaky `selftest_graph` "no field leaks": fields counted while the live canvas still held its evaluation cache and mask preview (10 fields). | Count after releasing the live holders. |
| 7 | Interop panel: typed folder / file names counted only after Enter (Export without a folder). Also a double `OnDestroy` of an Edit logged 8 errors. | `Flush` before every button; destroy order. |
| 8 | **A scrolled panel swallowed every click on its own tab strip** (the shifted content group overlapped the dock's tabs; Interop, Mask generator, Paths ...). | Content group not hit tested, clear catcher bitmap keeps the wheel on the panel rectangle. |
| 9 | Scatter: "placed 0 props (one undo step)" when nothing passes the filters (flat map at water level). | Says why (limits, water level). |
| 10 | `History.Merge` refused entries with terrain parts: "Apply skeleton ... (one undo entry)" took two Ctrl+Z. | Merge accepts terrain entries; check with two strokes + an object entry. |
| 11 | Graph name field text ran over the Save button after the panel was recreated (Edit clips to the width it had when the text was set). | Text set again at the final width. Preview status text cleared when the panel goes. |

## Checked and fine (real input)

- Graph canvas: add nodes from the palette, wire drag (replaces a wire), detach by dragging off an input, wire click + Delete + undo, node drag (live, one undo), box select (Shift / Ctrl add), pan (middle / right, also over nodes), wheel zoom about the pointer with clamps, Fit, copy / paste at pointer / duplicate / delete / undo / redo, inspector sliders (live, one undo, - / + merge), thumbnails, On terrain + Revert (exact), workspace switch reverts the preview, Build = one undo step with exact undo / redo, save / load, presets, variation gallery. Build on 1025: 1.5 - 3 s; preview on terrain ~0.2 s; revert 0.09 s; undo exact after five presets.
- Interop: export then import round trip gives the identical checksum; min / max mapping; live link re-import within 4 s and Revert exact; mask import to a layer, Apply + Undo exact.
- Mask generator: rules, preview, red overlay, Apply to layer (undo / redo exact), Apply to terrain type. Props scatter: count, scatter, undo / redo exact, mirror symmetry exact.
- Erosion panel (Preview, On terrain = Apply checksum, Revert, Apply, undo / redo exact); Erode / Rain / Deposit brushes: live while painting, one undo per stroke, exact, symmetric.
- Paths: draw, edit, point drag (live, one undo), marquee (live box, selects on release), profile curve editor (live, one undo), modes carve / ramp / raise / level / river / road: preview = apply, revert exact, undo / redo exact; Bake.
- SC tools: pads, symmetry (mirror mismatch 0), slope limit, skeleton, Terrain checks (+ Validation panel). All number settings seen have field + slider + - / +.

## Open / not done

- UI 150 % clipping pass of the terrain panels, tool state across workspace switches (the Raise tool is the default after a start; a click in the viewport edits), `scripts/ed_stress_load.py` after using the features (extend `DIRTY_LUA` with a graph build, erosion, path apply, import), the "Stratum recipes" apply with real textures, region import (rect), water page of SC tools, rubber band of the graph box select is faint, panel status line of the SC tools page is shared between pages (stale text), Paths name field commits on Enter only, "Most props" can be exceeded by one with symmetry, VirtualList rows sit 8 px above their box in the Mask generator panel.
- (UI 150 %, tool state, stress load, region import and the rest above were not reached; usage limit.)

## Merge check

`python scripts/editor_merge.py try qa3 --test` (2026-10-19, against the moved sentient2): merges clean, all 17 selftests PASS including `selftest_terrainqa`. The canvas / overlay checks of that test only run when the graph canvas is alive and laid out (a destroyed canvas stays in `live.canvas` after a workspace switch).

## After merging sentient2 (qa3 + qa4 + t7 + meshview ...)

Conflict only in `panels_interop.lua` (both branches fixed the Edit double destroy; sentient2's version kept). `editor_inst.py selftests qa3`: all 21 pass; `editor_merge.py try qa3 --test`: ok.
`scripts/editor_nightly.py` on the merged tree: selftests, menus, workspaces (100 % and 150 %), maps and stress (6 of 6 loads) pass. It flags, none of them in the terrain areas and all
also present on a plain sentient2 tree (checked with the panels / log steps on the main checkout): `panels_objects.lua:156` Find field `onChange` calls `P:Refresh` before it exists
(12 x), `markerfilter.lua:33` table index is nil (View panel buttons), 20 - 30 LazyVar circular-dependency warnings during the panel sweep, lint: `unitcheck`, `bpedit.Report`,
`graphnodes_t7.RampStops` (defined inside a block; the t7 selftest calls it and passes, so probably a lint false positive).
