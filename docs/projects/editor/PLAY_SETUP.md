# Play setup (WP9 of EDITOR_PORT_ANALYSIS.md), 2026-11-11

Play (F5 / "Play test") runs with a **play setup**: per army slot You / AI / empty, the AI type (the game's and the AI mods' `lua/AI/CustomAIs_v2`), the team and the faction
(random or one); fog of war, victory condition, unit cap, the cheating AIs' multiplier, pre-built bases, and the sim mods. Setups are remembered (the last one used; one per
map when "Keep for this map" is on) and saved as named profiles in the user folder (`play_setups.lua`, cleared by "Reset user settings"). Built-in profiles: Solo sandbox,
You vs 1 AI, 2 v 2 with AI, Free for all with AI, Watch 4 AI. Dialog: File > Play setup..., or the Play setup button of the tool panel.

| Piece | Where |
|---|---|
| model, lists, profiles, launch file | `lua/editor/playsetup.lua` |
| dialog | `lua/editor/gui/dialogs_play.lua` (AI types: the game's own, then a submenu per AI mod; more than 8 mods: "Add a mod..." opens the browser) |
| Play decides | `ui.lua` `Play()`: solo as before in the editing session; anything else (`PlaySetup.NeedsReload`) saves the map, writes `editor_play_launch.txt` and opens the saved copy in a new session that starts in play mode (`SessionExtra.skirmish`) |
| session start | `schook/lua/SinglePlayerLaunch.lua` reads the launch file (only for the map it names, emptied when read) and builds the armies as FAF's quick start does |
| the world is a game | `Options.EditorSkirmish`: the editing quiet (no commanders, peace, frozen units, no tarmac / flatten) is switched off in `scenarioutilities.lua`, `structureunit.lua`, `cconstructioneggunit.lua`, `simcallbacks.lua` (EdSetPlay) |
| tests | `selftest_playsetup.lua` (logic, profiles that survive a restart, the launch file, the game's real lists) |

Campaign / coop missions ignore the setup (their own brains).

## Verified (instance `playsetup`, SCMP_009, 2026-11-11)

- 2 AIs from a saved profile (you Aeon, rush as Cybran + adaptive allied against you, fog on): both AIs built (10 and 9 units, 4 engineers each after about 70 s), alliance and factions as set.
- The profile and the last setup survive an editor restart (`--keep-userdata`).
- AI mods: M28AI + RNGAI AIs (mods loaded for the run) built units; "Watch 4 AI" (no You) ran 4 AIs.
- Solo with the default setup still plays at once in the editing session (no reload).
- Stop reloads the autosave as before.

## Not done / open

- **Water level in a running play: it does not reach the sim.** `ed_world_set({water_elev = ...}, true)` changes the render side (water plane, water map; WATER_SHORE.md); in play, `GetSurfaceHeight`
  at the lowest terrain stayed 17.5 after raising the level by 12 (UI side showed 29.5). The sim reads `Sim::mMapData->mWaterElevation` / `mWaterEnabled` (`cfunc_GetSurfaceHeightL`),
  its own copy from the map load, and the pathfinder's layers follow it; no Lua call sets it. A fix is a small native, modelled on `EdLiveTerrain` (write the STIMap water fields,
  mark the pathing dirty): WP1 territory (engine rebuild), not done here.
- Unit warp / enhancement of a play's unit: not checked (needs natives like `EdLiveUnits`; our sim callbacks can already `Warp` and the game's enhancement UI works in a play).
- Watch mode (no You slot): the UI's focus army stays army 1 (an AI), so the player can issue orders to it; upstream's focus -1 is not set.
- RNGAI prints "Check FAILED! Found 0 RNGAI directories" (its own integrity check does not find its mod folder in the editor's VFS) and an intelmanager error after a minute; it still built.
- Quick start (commanders without FAF's warp-in) is not applied to a setup session: its commanders warp in as in a game.
