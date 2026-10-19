# Parity audit: final status (sweep batch, 2026-10-19)

Every row of [PARITY_AUDIT.md](PARITY_AUDIT.md) that was not `have` / `Done` when the sweep started, with its final state. **done** = implemented with a self test
(`selftest_sweep.lua` unless noted), **other session** = covered by a parallel branch of the same follow-up round (resize / platoons / mirror, assets / tooltips / image brushes,
environment presets, sky / water), **partial** = works for the common case, the rest is named, **needs user decision** = the next step depends on a choice only the user can make.

| Audit row | Priority | Final state | Reason / what is left |
|---|---|---|---|
| Select by type / by group / same blueprint | P3 | **done** | Edit > Select the same (marker type, prop / unit blueprint, decal texture), Select units of the same group, Select all markers / props / units / decals / areas (`selectsame.lua`, `gui/feature_sweep.lua`) |
| Taunts per dialogue / voice-over per line | P3 | **done** | node *Play a multiplayer taunt* (head 1-8, taunt 1-48, `ScenarioFramework.PlayTaunt`); dialogue lines carry optional `bank`, `cue`, `vid`, `faction` (fields in the line dialog) |
| Drop reinforcements | P3 | **done** | node *Drop reinforcements by transport* (army, group of transports with cargo, landing chain, patrol chain after the drop, instant attach, formation) -> `PlatoonAttackWithTransports`; the checker reports a chain that does not exist |
| Nuke barrage compounds | P3 | **done** (simple form) | node *Nuke barrage*: the launchers of a group variable fire N missiles each at a marker, optional scatter radius, optional silo fill (`GiveNukeSiloAmmo` + `IssueNuke`). A barrage with timed waves is the node repeated with *Wait* nodes. The campaign's own barrage compounds (a launcher that builds missiles over time, target lists) are not modelled |
| Cutscene camera preview (follow-up 4.9) | P3 | **done** | Mission panel > stage row > *Play here* starts a play test at the selected stage (`ui.PlayFromStage`, sim callback `EdMissionStartAt`, `Stage[ScenarioInfo.EditorStartStage or 1]()` in the compiled script) |
| Play test runs the edited mission (found by the sweep) | P1 | **done** | the sim runs the script it was loaded with, so a mission edited in the session did not play: `Play` now saves `_playtest`, reloads it and starts in play mode when the mission changed since the session loaded (`ui.MissionChanged`, `control.SessionExtra`, `gui/shell.lua Start`); Stop returns to the map |
| Lobby options / team layout | P2 | **partial -> done for what the lobby reads** | verified in `faf_repo/fa/lua/ui/lobby/lobby.lua`: the lobby reads `teams[1].armies` only for the slot count and `Configurations.standard.factions[slot]` for the factions each slot offers; `teams` beyond the FFA entry are ignored by FAF. So: *File > Lobby slots* edits the allowed factions per start position (`lobbyslots.lua`, dense table, undo). A fixed team layout (several `teams`) is not read by FAF: nothing to build |
| In-editor help / tutorial map | P3 | **partial** | start screen, help and tour: ed/package. A tutorial map is not made: the tour covers the UI; a map is only worth it if the user wants a teaching scenario (**needs user decision**, low value) |
| Area polygon / rotated areas | P3 | **needs user decision** | the save format (`Areas`) and every consumer (`ScenarioUtils.AreaToRect`, `InRect`, the playable area) are rectangles. A polygon would be editor-only data that compiles to a rectangle list or a check function in the mission script. Choice: (a) editor-only polygon -> several rects (cheap, lossy), (b) polygon helper in the mission script (`InPolygon`) used only by mission nodes (clean, mission maps only), (c) do not support |
| Prop creator, texture / format converters | missing | **needs user decision** | M7, separate design (a prop creator is a unit-wizard sized project: mesh, LODs, shaders, blueprint). The unit wizard's mesh / texture path can be reused; scope and format list to be agreed |
| Water masks (foam, flatness, depth) brush | P3 | **done as a mask output** (batch C, landed) | Mask generator writes foam / flatness / depth bias (replace / add / subtract). A freehand brush for the three masks is open: a small follow-up, the generator covers the rule-based use |
| Wave generator | P3 | **partial** (batch C, landed) | wave normal maps, scale, motion, ramp and cube map are editable (Water motion panel); the `.scmap` shore-foam emitters (wave generators proper) are not |
| Skybox / cube map | P2 | **done** (batch C, landed) | Sky, Sky textures, Sky objects panels |
| Lighting presets, strata themes | P2 | **done** (batch C, landed) | 78 looks, 70 themes with thumbnails, blend / try / apply / revert, import from any map |
| Map resize / crop | P2 | **done** (batch A, landed) | canvas and scale modes into a resized copy of the map |
| Unit orders, platoons / platoon builders, platoons and orders panels | P2 / P3 | **done** (batch A, landed) | Platoons panel, order queues, builders, mission nodes, validation |
| Mirror units and decals | P2 | **done** (batch A, landed) | plus mirror the whole half |
| Asset browser across everything, prop thumbnails | P2 | **other session** (batch B, assets: not landed yet) | |
| Brush thumbnails, user brush folder, brush library | P3 | **other session** (batch B, not landed yet) | |
| Tooltips on tools and properties | P3 | **other session** (batch B, not landed yet) | |

## Tests and tools added by the sweep

| What | Where |
|---|---|
| lint that follows names defined in `do` blocks, functions and assignments inside functions (explicit `ALLOW` with reasons, empty) | `scripts/editor_lint.py` |
| the whole self test set N times in one process, in random order, and across fresh restarts, per-test failure statistics | `scripts/editor_selftest_loop.py` |
| sim thread / play test lifecycle stress (missions with timers, waits and spawns, sim callbacks, five ways to leave play mode, crash file check) | `scripts/editor_sim_stress.py` |
| load stress with all workspaces, graph canvas, live link, pop-outs, play tests, dirty maps; memory growth (working set, private bytes, Lua heap) and a leak verdict | `scripts/ed_stress_load.py` (`--mode full`, `--maps <one path>` repeats one map) |

Flaky self tests found and fixed: see [LOAD_CRASH.md](LOAD_CRASH.md) section "Sweep findings".

## Nightly failures of 2026-10-19 and where they came from

**The cause of most of them: the shared `nightly` instance runs whatever Lua tree it was created with.** `editor_nightly.py --editor <tree>` only applied the tree when the instance did not exist yet; the existing `nightly` instance was linked to the main
checkout (`editor/runtime`), so three "ed/sweep" nightlies actually tested sentient2 and their failures were sentient2's. Fixed: an existing instance is re-linked to `--editor`; the sweep ran with its own tag (`sweepnight`).

| Failure (on the main checkout's tree) | Cause | State |
|---|---|---|
| `selftest_t7` "no field leaks -1" | the check demanded an equal grid count; a cache another module held at the start (graph base heights) was released meanwhile | check is `<=` now |
| simstress "no session" | `score.lua` / `uiutil.lua` raise inside the game's `OnFirstUpdate` on maps whose armies the score UI cannot draw, the editor never started (plain sentient2 fails at cycle 7 of the same seed) | fixed in `gamemain.lua` (ed/sweep) |
| stress "timeout" (`pentagon.v0001`, `adaptive_wonder.v0001`) | the same `OnFirstUpdate` failure (these maps have 17 armies), no editor session after the load | fixed in `gamemain.lua`; both load in 14-22 s on ed/sweep |
| stress "memory grew" | the verdict extrapolated 12-14 loads of mixed big and small maps | a verdict needs 30 loads after the warm-up |
| tips "no answer within 120 s" | the same stuck sessions | gone |
| tips "16 without a tooltip" | real: new buttons of interop, maskgen, sctools, paths and the Mission panel's *Play here* had no text | texts added to `tipdata.lua` |
| selfloop `selftest_unitwiz`, `selftest_paths` | the main checkout lacks the sweep's test fixes | fixed in ed/sweep |

Order dependence found by the shuffled loop on ed/sweep and fixed in the tests: `selftest_assets` (height stamps assumed a ground of at least 10 units at (100,100): it now levels a known ground first), `selftest_parity` (mirror also copies selected props /
units / decals that `selftest_mission` leaves selected: the selection is cleared first), `selftest_cmd` (set-rect height), `selftest_t7` (grid count). Last result: 14 shuffled runs + 1 fresh start without a failure.
