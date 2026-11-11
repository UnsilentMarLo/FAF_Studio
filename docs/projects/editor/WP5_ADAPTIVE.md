# WP5: adaptive maps (`_tables.lua`, `_options.lua`, what becomes of a unit), 2026-11-11

Work package 5 of `EDITOR_PORT_ANALYSIS.md`. Engine branch `port/wp5-adaptive` of faf-re (worktree `C:\Users\Marlo\Documents\GitHub\faf-re-port-wp5`, on `port/wp1-logic-lib`, two commits), Lua side in this repository.

## What is bound

`src/moho/editor/EdUpAdaptiveLua.cpp` over upstream's logic, unchanged (`EdAdaptiveTables`, `EdAdaptiveModel`, `EdGroupOptions`, `EdUnitFate`, all in `faf_editor_logic`). Text in, text out, plain Lua tables; indices that cross the boundary are 1-based, 0 = none / not offered (upstream: 0-based and -1). The header of the file lists every native with its table shapes.

| area | natives |
|---|---|
| `_tables.lua` | `ed_adaptive_known_tables`, `_tables_parse(text)`, `_tables_write(text, tables)`, `_tables_path(script)`, `_scenario(text)` (`AdaptiveMap = true`), `_entry`, `_marker`, `_option_key` |
| `_options.lua` | `ed_adaptive_options_parse`, `_option_find`, `_option_put`, `_option_for`, `_option_values`, `_option_write`, `_option_remove`, `_next_level` |
| setup by what the player picks | `ed_adaptive_options_of(script, optionsText, tables)`, `_table_group`, `_level_group`, `_groups_made`, `_loops`, `_creations` |
| a unit | `ed_adaptive_fate(path, civilian, script)`, `_rule(script, optionsText, group)` (lines for the panel, the first setting that makes it), `_spawn_targets(script, optionsText, army, groupPaths)` |
| wreck | `ed_wreck_value(bpId, underwater)` (the rules' blueprint when kept, else the Lua state's `__blueprints`: costs and the source `.bp`, which goes through upstream's `WreckOfUnit`), `ed_wreck_value_of(bpText, buildMass, buildEnergy, underwater)` |

`EdUnitWrecks` (needs the `EdDocument`) is not used. The editor session has no kept rules (`RULE_PeekKept` is null there), which is why the blueprint comes from `__blueprints`.

## Lua

* `adaptive.lua`: the model. Holds the texts of `<base>_tables.lua` / `<base>_options.lua` of the open map (read with `ed_game_file_read` when the exe has it, else from the mounted folder), edits them through the natives, every change one `History` step (undo / redo restore both texts and `info.AdaptiveMap`). `WriteFiles(dir, stem)` is called by `map.lua` `SaveAsCore` (also for a Save As into a new folder, which lost these files before); `PatchScript` points an adaptive script's `import` at the new `<stem>_tables.lua`.
  * A group change rewrites the table line only; the table's lobby option is touched only when the number of values must change (values are added or dropped at the end, label / help / wording of the others kept; an option the file lacks is written whole with the resource counts). The first version used upstream's `WithLobbyOption` always and replaced the mapper's wording ("Additional plateau mex" became "Side mexes"): found on DualGap, changed.
* `units.lua`: `SplitGroup`, `GroupPathOf(army, name)`, `GroupPaths(army)`, `MoveToGroup(list, path)` (one undo step).
* `gui/panels_adaptive.lua`: two panels. **Adaptive map**: the selected unit's group, fate, lobby rule lines and wreck value first, then files, max players, resources per army, the option tables with their groups, crazyrush lists; buttons act on the chosen row and on the selected markers (Add selected, Select, New group from selected, Remove group / table, Spawn always, Move to...). **Lobby options** (its own window: Map > Lobby options window): each option of the lobby with its choices and what each puts on the map ("+ 54 wrecks, 15394 mass", "+ 2 mexes (5 in all)", the groups the script makes), Add choice, Make default, Rename, Select, Remove choice, Delete option, Add to the lobby (an option the script reads and the lobby lacks).
* `gui/feature_adaptive.lua`: commands `adaptive.panel`, `adaptive.window`, Map menu entries. Tips in `tipdata.lua`, panel tips in `tooltips.lua`.
* `selftest_adaptive.lua`: `Run()` = the natives against the expectations of upstream's tests (AdaptiveModelTests, AdaptiveTablesTests, UnitFateTests, the DualGap fate sample) and the model on a made-up map (edits change only their lines, undo / redo, files written, script retargeted); `Retail()` = on the open adaptive map. `scripts/ed_adaptive_check.py <tag> [--only NAME ...]` opens maps of the custom vault folder and runs `Retail()` on each.

## Results (2026-11-11, exe `main_ed_wp5_x64`)

* **DualGap Adaptive (`dualgap_adaptive.v0014`)**: moving one marker between two groups of `sideMexes` changes line 63 of `_tables.lua` and nothing of `_options.lua`; a new group changes the same table line and turns 2 value lines of the option into 3 (its values block); the written files equal the edited text; undo gives the file back byte for byte. Wreckage: "T3 wreckage" reads "+ 54 wrecks, 15394 mass", the number upstream's doc gives; a UEF unit in `Optional_Wreckage_2` reads "wreck: 143 mass, 0 energy" and the lobby rule lines name `optional_wreckage`.
* Other adaptive maps of the vault folder (`ed_adaptive_check.py`): theta passage, tabula rasa, pandemonium pass, mechanoclastic rush (no option table with two groups: one mex moved between armies, exactly the two army rows differ, options untouched) pass; canis river is an older template whose tables do not read (`expected a name`: no `maxPlayerOnMap`, trailing `;`), skellige has no army mex lists: skipped. The panel shows the parse error for the first.
* Fate text for 5 sampled units equals upstream's test expectations (INITIAL unit, WRECKAGE, `Optional_Wreckage_2/Middle` as wrecks, `Optional_Civilian_Base_2` as either, `Outpost` as a unit, a group nothing creates: never); wreck values 1620 (dry) / 972 (under water) for the Salem destroyer, 226.8 for a frigate with the naval default, and 1620 from the live blueprint `urs0201`.
* `selftest_adaptive` 132 checks pass; `selftest_savejob` 11 pass (Save As path); Save As of DualGap into a new folder writes `_tables.lua` / `_options.lua`, retargets the script's import and keeps `AdaptiveMap = true`. `editor_lint.py`: 0 missing names, 0 dialect errors.
* Upstream GoogleTests (`faf_editor_brush_tests`, `FAF_RETAIL_MAPS` and `FAF_DUALGAP_DIR` set): 221 passed, 4 skipped (emitter, effect graph, real vault archive: data of other packages). The two DualGap tests (`GroupOptions.DualGapAdaptive`, `AdaptiveTables.DualGapsGeneratedFileChangesOneLine`) run and pass with `FAF_DUALGAP_DIR` pointing at the vault folder's `dualgap_adaptive.v0014`.
* Screenshots: `img/wp5_adaptive_panel.png`, `img/wp5_lobby_options_window.png` (both are pop-out windows of the panels, on DualGap).

## Not done / limits

* The scenario flag goes through `Doc.info.AdaptiveMap` and the existing save (text-preserving `textsave.lua` when the exe has the WP3 natives, else `luaser`); this branch does not contain WP3, so the text-preserving path of `_scenario.lua` was not exercised here.
* Upstream's "Preview a game" (hide the markers / units a lobby pick would not create in the view) is not ported. The fate panel lists the settings (rule lines) instead.
* No Properties-panel row for the unit: the fate sits in the Adaptive map panel (shown when units are selected).
* The panels are narrow when docked (the Objects workspace tab stack is about 210 px wide at 100 % UI): long file paths are cut; the list scrolls. They are meant to be popped out (drag the tab) or opened by the Map menu command.
* `ed_adaptive_tables_path` follows the import in the script; a save under another name retargets that line only when the old path appears literally in the script.
* Older tables templates (no `maxPlayerOnMap`, `;` after tables) are refused by upstream's parser: the panel says so and offers nothing to edit.

## Integration with WP3 (2026-11-11, throwaway branch `port/wp5-int`, worktree `faf-re-port-wp5-int`, exe `main_ed_wp5int_x64`; not pushed)

`git merge port/wp3-exact-save` into `port/wp5-adaptive`: one conflict, `src/moho/editor/editor_sources.cmake` (both added their binding unit at the same place); resolved by keeping both (`EdUpAdaptiveLua.cpp`, `EdUpMapFileLua.cpp`, `editor/doc/EdMapFile.cpp`). Built without errors.
* `selftest_roundtrip` PASS, `selftest_adaptive` PASS (132 checks) on that exe.
* DualGap loaded, one mex moved between two armies, Save As into a new folder: `_scenario.lua` 29 of 29 lines, only the three path lines (map / save / script) differ (text preserved by `textsave.lua`); `_tables.lua` 83 lines, the two army rows differ; `_options.lua` identical.

## Final pass

* Layout check (`layoutcheck.PanelOnly`, both panels, UI 100 / 150 / 200 %): one overlap in the "not adaptive" row found and fixed, now 66 controls, 0 problems.
* Full `selftests` on the WP5 exe: all pass except those of other packages (natives not in this exe: import, roundtrip, vault, waterbodies), `alphagen` (out of memory after the full run, a known caveat), `perfbudget` (timing while a build ran) and one `assets` finding (`file.vault` has no menu tip, WP4).
* Properties panel: a selected unit shows Group, Appears (the fate sentence) and Wreck rows (`gui/panels_objects.lua`); the full text and the lobby rules stay in the Adaptive map panel.
