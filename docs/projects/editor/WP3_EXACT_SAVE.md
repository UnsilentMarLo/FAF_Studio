# WP3: exact save (map file, save-file text, package), 2026-11-11

Work package 3 of `EDITOR_PORT_ANALYSIS.md`. Engine branch `port/wp3-exact-save` of faf-re (worktree `C:\Users\Marlo\Documents\GitHub\faf-re-port-wp3`, on top of `port/wp1-logic-lib`), Lua side in this repository.

## What is bound

`src/moho/editor/EdUpMapFileLua.cpp` over upstream's logic (unchanged but `EdMapFile.cpp`, see below):

| native | upstream | does |
|---|---|---|
| `ed_mapfile_capture(vfsMap)` | `EdMapFile` (`ReadPreviewRecord`, `ReadImageRecords`, `ReadPropRecords`) | at session start: the file's preview chunk, DDS image chunks and the props' 15 floats, plus a hash of the heights and of the water levels / planes and the strata mask revision |
| `ed_mapfile_save(path[, {engine=true}])` | `WriteMapFile`, `EdImageChunks` | the exact writer; `engine = true`, no capture, or a file that is not a classic v2 `.scmap` (containers 3 / 4) use `CWldMap::MapSaveToDiskPath` |
| `ed_mapfile_state()` | | which sources are still as captured |
| `ed_mapfile_roundtrip(folder[, deep])` | `EdRoundTrip` without `EdDocument` | save twice, compare the two files and the original; `deep` reads the file back into a second map and compares heights, water, props (with scale) |
| `ed_savefile_entries(text)` / `ed_savefile_write(text, entries)` | `EdSaveFile` (`SaveFile::Parse`, `Text`) | the markers / areas / armies / chains blocks of `_save.lua` |
| `ed_luatext_fields(text, name)` | `EdLuaText` | the top-level fields of `ScenarioInfo = { ... }` with their text positions |
| `ed_package_plan / _start / _poll / _cancel / _free` | `EdPackage` | vault checks (`name.vNNNN`, `map_version`, files named by the scenario) and the zip, as a polled job; `*_editor.lua` (our sidecar) is left out as `pack_map.py` did |
| `ed_game_file_read(vfsPath)` | `ReadGameFile` | a game file from a folder or an archive |

## How "unchanged" is decided

Upstream hashes the document's own copies. Ours has no `EdDocument`, so the evidence is read from the live session at save time:

* normal maps: hash of the height field == hash at session start (`ed_mapfile_capture` is called from `control.lua` `Start`, right after `ed_doc_attach`, before anything can be edited);
* water map: heights unchanged and the water levels (`mWaterEnabled`, the three elevations) and the three water byte planes (foam, flatness, depth bias: `WaterMaskWrite`) unchanged;
* the two stratum masks: `moho::editor::StratumMaskRevision()` (EdStrata.cpp) equals the value at capture. Every mask write (`ed_stratum_write`, `StratumMaskWrite`, a resize of the masks) bumps it, so a missed edit path cannot happen: all mask changes go through those three places. Conservative: a write of the same bytes counts as a change, an undo back to the original does not restore "unchanged";
* props: upstream's own rule (transform equal to the loaded one -> the stored 15 floats). **Patched** (`// STUDIO:` in `EdMapFile.cpp`): the three scale lanes are written from `CWldPropEntry::mScale` (our engine keeps them per prop), never from the stored record and never as 1. An unedited scale equals the stored bits (the entry read them).

Hashing the heights costs a pass over the field at save (about 2 MB on a 1024 map).

## Text-preserving `_save.lua` / `_scenario.lua` (`textsave.lua`)

The document stays Lua tables. At save, `map.lua` `PreservedSaveText` / `PreservedScenario` read the file the map was loaded from (`ed_game_file_read`, folders and archives) and build the new text from it:

* `_save.lua`: for each marker / area / army entry still in the document: the original value texts are kept where their evaluated value equals the document's (the text is run with FAF's `dataInit`), changed values are rewritten in the same wrapper (`STRING( )`, `FLOAT( )`, ...), new entries come after, by name; `SaveFile::Text` rewrites only the blocks that changed. Chains are passed only when they changed.
* `_scenario.lua`: the fields of `ScenarioInfo` are located by `ed_luatext_fields`; changed values are replaced in place, new keys appended (a map without no-rush offsets does not get them added).
* **Proof, then fallback:** the new text is run and its table must equal the document's. Otherwise the result is nil and the caller writes the whole file as before (`luaser`). So the text path can only give the same data, never other data.
* `luaser.Chunk(..., bare)`: `SaveText` now writes identifier keys bare (`Markers = {`), as the game's own files do. Upstream's parser finds its blocks by those names, so files written by older Studio versions (`['Markers'] = {`) fall back to the full write once and are text-preserving from then on. Autosave (`opts.saveText`) keeps writing the full text.

## Release

`release.lua` `Package(folder, done)` starts `ed_package_start` after `Release()` and polls; `gui/feature_release.lua` reports `vault zip: <path> (N files, X MB)` or why there is none (folder not `name.vNNNN` in lower case, ...). `scripts/pack_map.py` stays for use outside the editor.

## Checks

* `selftest_roundtrip.lua` (`Run`, registered in `selftests.extra`): fresh-session state, round trip with deep read-back, prop scale edit (1.5 / 0.5 / 2.25 and an edit after a save), height edit marks the normal maps and water map, mesh-terrain writer, comments kept, marker add / move / remove, scenario rename.
* `scripts/ed_roundtrip.py <tag>`: opens every map of the retail maps folder (default: the Forged Alliance install's `maps`, or `$FAF_RETAIL_MAPS`), saves it untouched and compares the bytes with the file; also checks that `_save.lua` and `_scenario.lua` come back unchanged from the document (`TextLine`).
* upstream GoogleTests: `faf_editor_brush_tests` (SaveFile, Package, ImageChunk and the rest of the logic library) with `FAF_RETAIL_MAPS` set.

## Results (2026-11-11, exe `main_ed_wp3`, branch `port/wp3-exact-save`)

* Retail round trip (`python scripts/ed_roundtrip.py wp3`): the Forged Alliance install's `maps` folder has **61** maps (SCMP_001-040, X1CA_001-006 + TUT, X1MP_001-012, 014, 017), not 63. **60 of 61 write the bytes of their file; the second save is always the same as the first, and the file reads back as the open map.** The one difference, X1MP_007, is 34 bytes: the editor's own load-time `strata.Normalize` (gui/shell.lua) gives a texture layer that has an albedo but an empty normal path the neutral `/env/common/layers/none_normal.dds`; with those 34 bytes cut out the file is byte-identical to the original (checked). Options if byte identity must hold there too: skip `Normalize` for a loaded file (the layer then renders through the engine's missing-texture fallback), or write the file's empty path back for a layer that still holds the neutral normal. Not done: it is a choice about editor behaviour.
* `_save.lua` of the same 61 maps: the document comes back as a text patch in every map (no fallback); 4-551 lines of 766-35,021 differ, all `position` lines of markers whose height the editor snaps to the terrain on load. `_scenario.lua` of all 61 comes back unchanged.
* `selftest_roundtrip` passes (the blank 256 map). `selftest_resize` (46 checks), `selftest_map` (Build + Verify after the reload) and `selftest_savejob` (11 checks) pass; `editor_lint.py` 0 errors.
* Vault zip: a released folder `rt_pkg.v0001` gives `rt_pkg.v0001.zip` (4 files, Python `zipfile` reads it, the sidecar is not in it).
* Upstream GoogleTests: `faf_editor_brush_tests` 219 passed, 6 skipped (retail emitter / vault data of other packages), with `FAF_RETAIL_MAPS` set.

## Limits

* The writer is version 60 only. Container 3 / 4 maps and mesh terrain maps (`TerrainSystem = 'mesh'`) keep the engine writer; nothing here touches `src/moho/sim/mapformat/` (Draiget/faf-re#387).
* Keys removed from `ScenarioInfo` make the scenario fall back to the full write.
* The first area of a map that has none (`Areas = {}`) is not patched in: the proof refuses it and the whole file is written.
* `ed_mapfile_capture` reads the whole map file once per session and keeps its image chunks in memory.
