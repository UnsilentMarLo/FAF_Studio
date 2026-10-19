# Release map and recent maps (M4)

- **File > Release map...** (`release.lua`, `gui/feature_release.lua`): checks the open map (scenario name / description / type / size, `ARMY_1..n` start positions without gaps, at least 2, the script compiles,
  the live map validators, army setup and mission checks, mesh terrain errors, mods that were loaded for the map) and lists them; errors block the release, warnings do not. **Release** writes a complete copy
  of the map into the next free `<stem>.v<N>` folder next to the working map (N = one above every version the game knows and the disk has) with `map_version = N` in the scenario file and the lobby preview;
  the working map stays open and unchanged. `python scripts/pack_map.py <folder> [out.zip]` zips a released folder for the vault (folder as the zip root, without `_editor.lua`).
- **File > Open recent** (`recent.lua`): the last 12 opened or saved maps (`editor_recent.txt` next to the exe), autosave / play test / mod reload folders excluded.
- `gui/feature_*.lua` are imported automatically by the shell: a feature that is not a panel registers its own commands (`Commands.Register`) and menu items (`Menu.Extend`).
- Checked in the engine (instance `release`): findings on the blank map (one start position = error), after adding a second start the release produced `reltest.v0002` with `map_version = 2`, the next target was
  `v0003`; `pack_map.py` wrote a 4 file zip rooted at `reltest.v0002/`.
