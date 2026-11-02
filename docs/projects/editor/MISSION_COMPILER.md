# Mission compiler: what it writes, what is tested, what is not

Code: `lua/editor/mission.lua` (model, catalogue, compiler, sidecar), `missionplat.lua` (platoon nodes), `mbase.lua` (bases), `missionimport.lua` (outline of a hand-written script),
`lua/editorsim/mission.lua` (sim side of the run panel). Tests: see the end. Stabilization round of 2026-11 (group E).

## Two kinds of script

`Compile(withEntry, opts)` writes the mission region of the map script in one of two flavors:

| | saved / released map (`opts` empty, the default) | test run (`{ test = true }`, set while `ui.Play` writes `_playtest`) |
|---|---|---|
| waits and timers | `WaitSeconds(s)` (game time, one sleep) | the editor's shim: polls `WaitTicks(1)`, honours `ScenarioInfo.EditorSkip` / `EditorTimeScale` (run panel Skip and speed) |
| state for the run panel | none | `ScenarioInfo.EditorMission = { Stage, V, Objectives, Trace }` |
| trace | none | `EdTrace('<stage>.<section>.<path>')` before every node, `...!` when a trigger body runs, `...~` when its stage guard dropped it; each goes to the log (`EDMISSION trace ...`) and the dump |
| coop | nothing (the lobby loads the coop mod) | `coopshim.lua` installed |
| start stage | `Stage[1]()` | `Stage[ScenarioInfo.EditorStartStage or 1]()` |
| operation end | the game's `EndOperation` | `editorsim/mission.lua Attach()` records the result (`EndOperation` of the campaign launcher needs `Options.ScenarioFile`, which an editor session does not have), `HumanPlayers` is filled (`cinematics.lua` loops over it) |

The only editor-aware lines of a saved script are the three of `EditorMissionStart` that keep an editing session from running the mission before Play
(`ScenarioInfo.Options.EditorMode` is never set in a game). A map opened from a saved copy therefore reloads once on the first Play (the running sim has no test hooks):
`Mission.NeedsReload()`.

Area triggers (`trg_area`) share ONE poller thread (`WatchArea`) and one `GetUnitsInRect` per area per tick (`UnitsInArea`), however many triggers look at an area.

## Trigger stage guard

A trigger node (`trg_*`) has "Only while this stage runs" (default on): when the mission has moved on to another stage the callback returns without doing anything.
That is silent in a game; Check lists every such trigger of a stage that has a next stage as an `I` finding, and a test run traces the drop (`...~`).
The group of a stage starts the next stage ONE TICK after its last objective completed, so the result triggers of those objectives ("when an objective is decided") still find their stage
(found by the sim test: they used to be dropped by the guard of the stage their own objective had just ended).

## Nothing a user types becomes code

* `Q(s)` quotes any value: backslash, quote and every control character (newline, NUL ...) are escaped; a non-string becomes text.
* `N(v)` writes finite numbers only (nan / inf / text give the default); `Var` / `IsName` accept identifiers that are not Lua keywords; `Comment(text)` makes a one-line comment text.
* Category expressions (`categories.TECH3 * categories.LAND`) must be ONE expression of the alphabet `[%w_.() + - * / , ' "]`, no `--`, and must compile as `return (<text>)`; else the default is used and Check says so. They are written in parentheses.
* `Clean(node, type)` runs before an emitter: a choice that is not one of its choices, a number that is not finite, a non-boolean, a non-text value of a text parameter and non-list children are replaced by the default.
  Check reports every such node.
* Region markers are only recognised at the start of a line; a hand-edited region (hash) is left alone.
* A node whose emitter raises, a Raw Lua node that does not compile, a stage whose text does not load: that node / stage is left out with a comment and a `WARN` in the script; the others stay
  (`Mission.Problems`, listed by Check). Only if the whole text still does not load the old stub is written. A base that cannot be generated costs that base only.
* A Raw Lua node that ends its block (`return`) is wrapped in `do ... end`.

`selftest_missionfuzz.lua` throws ~40 hostile values (quotes, newlines, `]]`, backslashes, NUL, unicode, 5000 characters, nan, inf, tables, booleans, absent) at every parameter of every node type
and at stage names, dialogue lines and base fields: the code of the script (strings, comments, numbers and variable names taken out) must equal that of an ordinary value.

## The sidecar (`<map>_editor.lua`, section `Mission`)

`Mission = { schema = 2, mode, stages, bases, dialogues }`. `schema` 1 = files from before the field (same layout). A newer number is read as far as understood and saved with its own number.
Loading (`LoadSidecar`) never raises: the file goes through `Mods.SidecarEnv` (ed/robust: sandbox, size cap, per-section salvage, `.bad` backup) when the tree has it, else through
`ReadSidecar` (the `Mission = ...` assignment only, data-only check, empty environment). Then `ValidModel` checks every stage, node (against the catalogue), base and dialogue: what is not usable is
dropped, invalid values are replaced by defaults, nodes of an unknown type are KEPT (a newer editor may know them; Check reports them). What was dropped is in `Mission.LoadReport`
(Check, the log and the status line show it). `SetParam` / `SetStage` refuse nan and inf.

`Mission.Do` (every edit) copies the model before and after (undo needs both). A raising edit function is caught: the model is restored and the error is reported (log, status line, console).
Measured: 1.6 ms per edit on a model of 1000 nodes, so no copy-on-write was added.

Caught errors: `Mission.Report(where, err)` / `Mission.Safe(where, fn, args)` log once per distinct message and say it in the status line; the mission, run and platoon panels use them instead of bare `pcall`.

## What import supports (`missionimport.lua`)

A hand-written script (`_script.lua` with `ScenarioInfo.MissionNumber = N`) is shown as an OUTLINE: stages (by their `MissionNumber` assignment and entry function), objectives (title where the call
spells it out), triggers, AI helper calls, line numbers; the strings file as dialogue tables. It is read-only: imported stages are never compiled, never written to the script (byte for byte unchanged),
never saved to the sidecar (the next load imports again), and editor stages can be added behind them. It does NOT turn script code into editable nodes and does not claim to round-trip it.
Tested on the real campaign scripts SCCA_Coop_A01 and E01 (7 stages each, found and checked against the text) when the game's maps are installed.

## Tests

| What | How | Executes |
|---|---|---|
| `selftest_mission`, `selftest_platoons`, `selftest_mission_import` | `editor_inst.py selftests <tag>` | compile, model, import; text assertions |
| `selftest_missionfuzz` | same | hostile values, sidecar files, raising edits |
| `selftest_missiondry` | same | the compiled scripts of the 8 sim cases RUN in a fake game (coroutines, virtual clock); every call checked against the game's function list (name and argument count) |
| `selftest_missionsim` | same | the cases build, are clean, compile in both flavors, round-trip through the sidecar, and use every node type of the catalogue |
| `scripts/editor_mission_sim.py <tag>` | nightly step `missionsim` | the 8 cases PLAYED in the real sim: every node traced, trigger bodies, flags, units per army, relations, economy, playable area, how the operation ended, the log |
| `scripts/editor_mission_api.py --check` | `studio.py check` | every `ScenarioFramework.` / `Objectives.` / `ScenarioUtils.` / `Cinematics.` function the compiler names exists in the game's `lua.nx2` (list generated into `data/faf_mission_api.lua`) |
| `scripts/editor_sim_stress.py` | nightly step `simstress` | play tests left five ways (crash hunting); its mission now uses real node ids and a node that cannot be added is an error |

Not run in the sim (compile / dry run only): the effect of `taunt` (sound), `vision` on a map, `playable` voice-over, `base_*` with a real campaign AI brain (a test session of a skirmish map has none:
the base start warns and returns), `pbm_remove` (needs a campaign brain), `transport_drop` (reached, effect on the cargo not asserted), `coop_*` beyond "does not raise" (the coop mod is replaced by
`coopshim.lua`), anything that needs a second human.

Initial units: the game's own army setup creates the INITIAL group of an army and registers every unit's name in `ScenarioInfo.UnitNames` (the sim case `triggers` kills `UNIT_A1` of ARMY_1 and a
"When a unit is killed" trigger on it fires); units of a spawned group are registered by the spawn. Not understood yet: an INITIAL group added to the army `Enemy` of the test world is not created
in the test run at all (the mission's own spawn nodes create that army's units), see the open items.

Screenshots of the sim test's `objectives` case: [edited in the Mission workspace](img/mission_sim_edit.png), [after the test run: the Run panel](img/mission_sim_run.png).
