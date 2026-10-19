# FAF Studio: QA pass 3 (Mission, Mod, lifecycle, menus), 2026-10-19

Branch `ed/qa4`, instance tag `qa4`. Follows `QA_2026-10.md` (pass 1: terrain / objects / the first mission and mod panels) and the terrain QA of the terrain sessions.
Method: real input (posted mouse messages, real key presses) with Lua reads of the document after each step and screenshots, plus four new repeatable
tools (below). Everything found was fixed in a small commit; logic bugs have a check in `selftest_qa.lua`.

## Repeatable QA: `python scripts/editor_nightly.py`

One command, one report (`engine_decomp/runs/<tag>/nightly/<stamp>/report.md` + `report.json` + `shots/`), exit code 0 only when everything passes. Steps:

| step | what it does | would have found |
|---|---|---|
| `lint` | `scripts/editor_lint.py`: every `Mod.Name` used on an imported editor module must be defined by it (7500 uses checked, no engine) | ui.lua's `Say` was a local: 40 callers dropped their status message or raised |
| `selftests` | every selftest the tree lists (`selftest_*`, `selftests.extra`), with the FAIL lines | |
| `panels` | opens each of the 48 panels in each of the 7 workspaces, watches the log | panel create / resize failures |
| `menus` | builds every menu-bar and context menu, each item needs an existing command, an action or a submenu, and a title | dead menu items |
| `clicks` | `clicksweep.lua`: presses every button of every panel and of the dialogs they open (a fixture gives the lists content: second army, markers, area, unit, mission with a trigger, base, dialogue) and reports handler errors | the closure-over-loop-variable bug of the node form (every picker dead), `Say` in Auto paint |
| `workspaces` | shows each workspace at UI 100 % and 150 %, checks the selected tool belongs to it, screenshots, judges them (not blank, dark chrome, viewport has content) | the black editor (below) |
| `log` | scans the log for LazyVar warnings, GUI / menu errors, Lua errors, missing textures, **D3D device errors** | |
| `maps` | `scripts/editor_maps_qa.py`: a big and a small real map: open, brush stroke, undo / redo exact by checksum, save as, reopen the copy, compare size / counts / checksum | |
| `stress` | `scripts/ed_stress_load.py` (map after map: plain, dirty, rapid) | the load crash of 2026-10-18 |

`--skip a,b` leaves steps out, `--loads N` / `--maps N` size the last two, `--keep` leaves the instance running. First full run: see the end of this file.

## Fixed

| # | Finding | Fix |
|---|---|---|
| 1 | **The editor went black for good** (every frame logged `DeviceD3D9.cpp Invalid call`) when the Console tab next to the viewport in the Generate workspace was clicked: the hidden viewport tab's holder is parked at -20000 and the world view followed it, so its viewport left the back buffer. | The world view keeps its last position while the holder is parked (`panels_builtin.lua`); check in selftest_qa; the nightly watches for D3D errors. |
| 2 | **Every picker and choice button of the mission node form did nothing** and logged errors (Army / Group / Chain / Formation / ... of every node, also Edit... on any node): closures made inside `for _, p in o.params` saw `p == nil` after the loop. | The form copies the parameter per row (`dialogs_mission.lua`). A scan for the same pattern found no other real case. |
| 3 | The mission compiler could produce a script that does not load (an unset variable gave `V.`, a broken category expression gave broken Lua); a Raw Lua syntax error emptied the map script and the map would not start. | `Var()` falls back to `V.UNSET`, category expressions that do not compile fall back to ALLUNITS (Check says so), `SafeCompile` writes a warning stub instead of a script that does not load. A sweep over all 40 node types x every choice / number / quoted text compiles and loads. |
| 4 | `ui.lua`'s `Say` was a local while 40 call sites in other modules used it (save messages, undo notices, tool errors): swallowed under `pcall`, raised in Auto paint / Auto erase. | `function Say` is a module function. `editor_lint.py` now guards this class. |
| 5 | A session restart (Test in the unit lab, Apply mods, Open map) dropped the mod project and the workspace: the user came back to Terrain with no project. | `control.SaveSessionUI` / shell start keep workspace and project across the restart. |
| 6 | Interop panel destroyed an Edit control twice (frame first, then the edit): `Error running OnDestroy`. | Edit first, then its frame. |
| 7 | Dialog text fields: no Enter, no Escape; the army Add dialog did not take focus at all (typing went nowhere). | `d:Field`: Enter presses the first non-Cancel button, Escape closes; army Add takes focus. |
| 8 | Dock tab bars with more tabs than width (the Console stack has 13) drew the tabs past the stack edge, over the next panel and off screen. | A window of tabs around the active one plus a `>>` button that opens a menu of all tabs. |
| 9 | Mission `Strings`, `Run`, `Mesh`, `Mesh import`, `Mods`, `Unit viewer`, `Release` dialog: long status lines ran off the panel / dialog. | Fitted to the width. |
| 10 | UI 150 %: the scale readout drew over the Slope button; the stage name field and the Mode button ran out of a narrow Stages panel. | Readout only where there is room; the name field gives way. |
| 11 | Open map listed the editor's own `_autosave` / `_modreload` folders. | Hidden (File > Recover autosave has the first). |
| 12 | Unit viewer panel: strict-global error on `View.LODInfo` at the first resize. | Declared in `unitview.lua`. |
| 13 | `editor_nightly.py` itself: a report folder created before the instance made the script believe the instance existed (no `bin`). | The instance check looks for `bin`. |

## Checked and fine

Mission: stages add / remove / reorder, name, mode, failsafe slider (field + - / +), node palette (all 40 types), node form (every parameter kind), nested trigger nodes, army setup (faction, colour,
economy, alliances, add / remove / reorder) with exact undo / redo and the panel in sync, bases (new, groups with priority, attacks, details), strings, run panel layout. Checks and compile of every node type.
Mod: project create / open, unit lab slider + field + - / + with exact undo / redo, Write (blueprint file), Test (session reload with the mod: the changed value is in the running blueprints), icon render / write / batch.
Lifecycle on real maps (`adaptive_acid_lakes` 513, `20x20_white_fire_8v8` 1025 with 249 units, `trolladyngja_iceland_x20` 1025, `sc2_mp_304` 2049): open 11 - 17 s, stroke + undo / redo / undo exact, save as under 2 s, the saved copy
reopens with identical checksum and counts. Autosave and Recover autosave. Release dialog (errors block, folder path), `Maps.Open` refusing a missing scenario. Default hotkeys: all parse, none twice (139 commands).
Workspaces: save / load / reset layout, switching keeps layouts. Reorganised menus: every item has an action, disabled items say why.

## Open

- **Window title / icon**: not changed in this pass (BRANDING.md covers it); nothing found missing.
- **Pop-out panels on a second monitor**: only one display was available; the pop-out API (`Detach`, close docks back) was exercised through Lua and the popouts follow workspace switches.
- Panels still do not scroll horizontally; at UI 150 % the sliders' number field sits partly under the scrollbar.
- Dialog list pickers (`PickName`) have no Cancel button: a click outside or Escape in the filter closes them.
- The unit lab folds the slider's `-` / `+` clicks into the preceding typed edit (one undo step for both); intended by `History.Merge` but surprising.
- Clicksweep skips buttons that leave the process or change the mode (play test, file dialogs, Test / Write / Build ...): those are covered by the checks above, not by the sweep.

## First full nightly run (instance `nightly`, exe `main_x64_la_p2.exe`, 402 s)

lint, panels (48 x 7), menus (148 items), clicks (633 buttons), workspaces (7 x 2 scales), log, maps (3 real maps), stress (6 loads: plain, dirty, rapid) all pass.
One failure that is not from this branch: `selftest_graph` -- "every node type evaluates with default parameters ... raw_color_ramp: color_ramp: 'stops' needs at least two stops of 5 numbers"
(a node of the terrain-graph work that landed meanwhile has no valid default stops). Left to the graph session.
