# Stabilization plan (2026-11-02)

Origin: an audit of the repository, the earlier sessions' history and a measured run of the editor. Goal: stop shipping UI that is cut off, slow interaction, and an unreliable mission / mod side.
No new features until this plan is done (terrain graph, interop and texture work wait).

## Root causes this plan addresses

1. Earlier sessions changed performance and layout code without running the editor ("nothing was measured"), so fixes were never verified.
2. The checks are blind: `studio.py check` is a name lint; `layoutcheck.lua` sees only buttons, fields and sliders at 100 % / 150 % in one window size; nothing gates frame time, Lua cost or heap;
   mission tests only `loadstring` the output and the one sim stress script uses node ids that do not exist.
3. Layout has no single primitive: `W.Flow` in 22 of 75 panel files, ~2800 hand computed `Skin.S` offsets, buttons and labels do not fit their text, minimum widths beat the real width,
   panels never scroll sideways, dialogs use fixed coordinates with no clamp.
4. Known per-frame costs were listed and never fixed (label loop over every marker, 11 closures and imports per frame in `DrawLayers`, brush ring rebuilt per frame, native overlay re-projects every
   line twice per frame); paint undo lives in Lua tables; autosave and map open block.
5. Mission output is compile-tested only, sidecar files have no schema version and are loaded unprotected, errors are swallowed in bulk (~300 bare `pcall`), the extension API is informal.

## Groups (each has its own worktree, files it owns, tests it must run)

| Group | Branch | Owns | Items |
|---|---|---|---|
| A Layout | `ed/layout` | `gui/widgets.lua`, `gui/dock.lua`, `gui/dialog.lua`, `gui/dialogs_*.lua`, `layoutcheck.lua`, the `layout` step of `scripts/editor_nightly.py` | Buttons and labels fit their text; `Center()` never negative; horizontal clamp / scroll in `ScrollContent`; dock minimum width derived from content; dialogs clamped to the window, scrollable, built on `W.Flow`; checker extended to labels, lists, dialogs, culled controls, several scales and window sizes, window resize |
| B Lua frame cost | `ed/perf` | `overlay.lua`, `markervis.lua`, `validate.lua`, `units.lua` (cache), `gui/panels_editor.lua` (brush preview), `gui/shell.lua`, `perf.lua`, a new `perf` nightly step + `selftest_perfbudget.lua` | Key `UpdateLabels`; cache modules in `DrawLayers` / `View` / `PixelSize`; brush ring cached; units cache net; frame-time / Lua ms / heap budgets that fail the nightly on a big map |
| C Paint, history, save | `ed/paint` | `strata.lua`, `history.lua`, `maps.lua`, `map.lua` (save path), `luaser.lua` | Paint undo as compact byte buffers or deltas instead of Lua tables; history capped by bytes; autosave hitch reduced (changed-only, chunked or deferred to idle); measured before / after |
| D Native engine | `editor` (submodule, local commits only, not pushed) | `engine/faf-re/src/moho/editor/*` | Unchanged-skip and retained geometry in `EdOverlay` (no re-projecting every line twice per frame, no per-line vectors); native batch calls (`ed_terrain_get_many`, units snapshot) for later Lua adoption; map launch failure shows an error instead of freezing; tests via the instance with `--exe`, no staging over `engine/run` |
| E Mission | `ed/mission` | `mission.lua`, `missionplat.lua`, `missionimport.lua`, `platoons.lua`, `gui/panels_mission*.lua`, `selftest_mission*.lua`, `scripts/editor_sim_stress.py` | Execute generated missions in the real sim; fix the stress script node ids; escape every value the emitters concatenate; sidecar load protected and validated in `mission.lua`; Wait shim and test hooks out of release output; real-script import test works on Windows; `Do` is safe against a raising function |
| F Mod API and robustness | `ed/robust` | `mods.lua`, `bpedit.lua`, `unitwiz.lua`, `schook/**`, `docs/EDITOR_MODDING.md`, `scripts/editor_lint.py`, every other `doscript` load site | Schema version + migration + protected load for sidecars; `bpedit` backup, atomic write, undoable add / remove, history cleared on project switch; documented and versioned extension API (`Editor.ApiVersion`); error isolation for mod code; a `Safe` helper that logs and the conversion of bare `pcall`s in mission / mod / ui modules (not in files owned by A to E: those groups convert their own); lint for the Lua 5.0 dialect and the hook rules; FAF version check for hooks; contain the fatal `index expected but got boolean` path |

Native adoption of D's new calls in `markervis.lua`, `validate.lua`, `units.lua` is a second step after D and B are merged.

## Not in this round

* The hybrid laptop freeze (cannot be tested here). The documented hypotheses stay in `LAPTOP_FREEZE.md`.
* Lazy HUD creation and keeping blueprints across map opens (a deeper engine / session change); `DrawLine` retained vertex buffers beyond what group D can verify on the desktop GPU.
* Pushing the engine submodule and the new pin: the owner decides.

## Verification, for every group

1. Start an own instance (`editor_inst.py new <tag> --editor <worktree>/editor/runtime`, never touch another tag or stop a process by name); look at the result with `editor_inst.py shot`.
2. `python scripts/studio.py check`, the selftests of the touched area, a new selftest or check that fails without the change.
3. Measured before / after numbers (`dev.perf`, `/perf`) on a blank map and on `20x20Winter_Fire8v8` (mission map); UI work at UI scales 100 / 150 / 200 % and windows 1280x720 and 1920x1080.
4. Commit small on the group's branch; report what was verified and what was not.

Integration (after the groups): `editor_merge.py try ... --test`, `studio.py check --full`, a second perf measurement against the numbers of the audit (idle: ~7 ms/s Lua, 51-58 fps on the 20x20 map).

## Second round (2026-11-02): what the first round left open

Fixed, each one run in an instance:

* 22 loop-closure warnings of `editor_lint.py`: 16 were real bugs (every Snap command snapped by 8, every Align command named the last mode, the mission sidecar's `VECTOR3` / `VECTOR2` /
  `RECTANGLE` all got the type `RECTANGLE`, the lobby slot buttons and the difficulty sliders all edited the last row, filter chips lifted the last filter ...). Lint: 0 warnings.
* `selftest_t7` (the engine op `height_from_gradient` had no node: it has one now), `selftest_unitview2` (fake clock behind the module's real clocks), `selftest_resize` (the blending check read
  the whole field), `selftest_texscale` (assumed the 8 layer layout, the default shader has four), `selftest_fieldgen` / `selftest_maskgen` (a leak check that failed when a field was freed
  meanwhile; the same relaxation in the other 11 leak checks), `selftest_savejob` (the two saved maps name their own folder inside the .scmap), `selftest_perfbudget` (`markersig` cache believed a clock that had gone back). The shuffled loop runs 3 x all selftests without a failure.
* The 69 layout problems of the mission and mod panels (Stages, Bases, Platoons, Run, Strings, Mods): too little height made them stack their controls, now they grow and the dock scrolls;
  list rows no longer let the right text run into the left one; the Plan field and the Mode button wrap in a narrow panel. `layoutcheck.Known` is empty: the nightly fails on any panel.
* `tips`: the four buttons of the New unit dialog. `editor/textlab/shot.py` is DPI aware (on a scaled display the screenshots lost the right and bottom 20 %).
* The mission INITIAL unit claim was wrong: the game's own army setup creates the INITIAL group and registers the unit names (`triggers` sim case kills `UNIT_A1` and its trigger fires).

Still open: an INITIAL group added to the army `Enemy` of the test world is not created in the test run (unexplained); a control that is only partly inside a panel is hidden (Maui has no
clipping); ~361 bare `pcall`s (BARE_PCALLS.md); `markervis` / `validate` / `units` still walk in Lua (native batch calls exist); map open takes 13-24 s; the hybrid laptop freeze;
the engine submodule commits are not pushed.
