# Paint undo, history limit and save (stabilization group C, 2026-11)

Measured with an own test instance (`paint`) on this machine while five other editors were running, so absolute frame times are noisy: compare the before / after columns of one run.

## Paint undo as packed tiles

Before: `Strata.Dab` kept three Lua hash tables per stroke (`base`, `cov`, `orig`, 40 bytes a touched cell), and `EndStroke` made two Lua tables of the stroke's whole bounding box (`before`, `after`: 16 bytes a
cell). `ClearMask` / `FillMask` / `AutoPaint` / Remove texture kept two tables of the whole mask (128 MB for one Clear on a 2048 mask). History kept 200 such entries. Lua 5.0 collects stop-the-world:
the UI state's heap (`lua heap` in the perf report) rose by the size of every stroke and every collection walked it.

Now (`maskdelta.lua`, `strata.lua`):

* The mask is cut into tiles of 32 x 32 cells. A stroke makes a tile record the first time a dab reaches it: the bytes the mask has there (= before the stroke) as a packed string, and a coverage table of 1024 cells.
  A cell's value before the stroke is `string.byte` of that string; the three per-cell hash tables are gone.
* `EndStroke` reads each tile the stroke changed once more, packs it, and keeps `{ x0, z0, w, h, before, after }`; a tile whose bytes are all equal is kept as the number. Unchanged tiles are dropped.
* Whole-mask edits (Clear, Fill, Auto paint, Remove texture, Move) work tile by tile: one tile is a Lua table at a time, the entry keeps the changed tiles only (Move keeps nothing: its undo is the swap).
* `History` sums `entry.bytes` and drops the oldest entries when the sum passes `History.MaxBytes` (64 MB; the newest entry always stays), besides `History.MaxEntries` (200). A redo branch cut off by a new edit
  gives its bytes back; `History.Stats()` returns entries, bytes, limit. `Merge` keeps the sum of its parts. Entries with native copies (fields.lua) or the native height stack count 0.
* Per dab: the `last` position table is reused (no table per dab), `math.min` / `math.max` calls in the cell loop are comparisons. The paint output is unchanged: the fixed strokes of `selftest_paintundo` produce the
  checksums the table-based version produced (compared on the old code).

2048 mask on the 1025 map (20x20 Fire 8v8), 942 dabs of radius 40 over the whole map (every tile touched), mask cell 0.5:

| | before | after |
|---|---|---|
| Lua heap at the end of the dabs (after a full collection, base 58 MB) | +123 MB | +18 MB (coverage tables) |
| highest heap seen during the stroke (raw `gcinfo`) | 362 MB | 151 MB |
| retained by the history entry | 65.5 MB | 1.7 to 3.2 MB (two runs) |
| `EndStroke` | 0.71 s | 0.21 to 0.25 s |
| a dab (25,600 cells) | 48.2 ms | 34.0 ms |
| undo / redo of that stroke (4096 tiles) | 0.05 s / 0.05 s | 0.16 s / 0.24 s |

The undo of a stroke that touched the whole map is slower because the bytes are unpacked cell by cell (`string.byte`, one value per call in this Lua); a stroke of a few dozen tiles undoes in a few ms.

## Autosave

`ed_map_save` is one native call (the engine's `.scmap` writer): 140 to 200 ms on a 1025 map, 390 ms on the 2049 `setons_isle`. It cannot be sliced from Lua. What Lua does is the text of `_save.lua`
(`luaser.lua`): 0.8 to 0.9 s on a mission map with thousands of units (Rebels' Rest: 6.6 MB, 979 markers).

* `luaser.lua` builds one list of pieces and joins it once (no join of the lines at every table level, no helper table per table, key text cached): 0.9 s -> 0.29 s for the 6.6 MB document, same text byte for byte
  (`selftest_savejob` keeps the old serialiser as a reference and compares).
* `maps.lua` `AutosaveTick` does not run the save on the first tick after the interval any more. It waits until the user has stopped (no edit and no mouse movement for `AutosaveQuiet` = 2 s, no brush stroke,
  area drag or gizmo drag; `AutosaveGrace` = 120 s overdue starts it anyway, never during a stroke), then makes the text of `_save.lua` in slices of about 4 ms per frame (`Map.SaveText(pace)` in a coroutine
  resumed by a thread; the clock reads nil inside a coroutine in this engine, so the slice is counted in pace calls and tuned from the time a resume took), and writes the map with `Map.SaveAs(..., { saveText })`.
  If the history version changed while the text was made, it is dropped and made again when the user stops. A manual save resets the autosave (`AutosaveSaved`): nothing to autosave until the map changes again.
* The files written by the sliced job are byte for byte the files a plain `SaveAs` writes (checked on Rebels' Rest: `.scmap`, `_save.lua`, `_script.lua`, `_editor.lua`, `_scenario.lua`).

Frame gap at the autosave of Rebels' Rest (probe thread, `WaitFrames(1)` loop, machine under load: median frame 30-43 ms):

| | before | after |
|---|---|---|
| longest frame at the autosave | 994 ms | 395 ms (the native write: 180-260 ms; the 1.4 s of text is spread over 34 frames) |
| `SaveAs` called synchronously | about 1.1 s | 0.64 s |

On the 20x20 map (185 markers) the Lua part is about 50 of 200-250 ms; the rest is `ed_map_save`. What is left is native (group D) or the sidecar texts of other modules (`mods.SidecarText` 15 ms, `maptextures.PrepareSave` 25 ms).

## Map open (Lua side)

`Map.Load` now logs its steps (`EDITOR map.Load: N ms (steps of 5 ms or more ...)`): 65 ms on the 20x20 map, 80 ms on `setons_isle`, 196 ms on Rebels' Rest (doscript of the 4 MB save 44 ms, mission script
import 35, layout sidecar 57, unit entities 25, symmetry detection 33). The map open takes 19 to 24 s from process start to ready; the Lua part in these files is under 1 %: it is the engine start, the blueprint load
and the HUD creation (known, not in this group). `Maps.List()` (a walk over the whole `/maps` tree, 191 ms, 421 maps) is not part of the open.

## Tests

`selftest_paintundo` (packing, stroke / undo / redo by `ed_field_checksum`, whole-mask edits, the byte limit with real strokes and with fake entries) and `selftest_savejob` (serialiser against a reference copy,
sliced text, SaveAs with the text made ahead); both are in `selftests.extra`.

## Known: selftests that crash the engine here

On this machine `selftest_strataconv`, `selftest_fields`, `selftest_shaders` and `selftest_maskgen` end in an access violation (`main_x64_la_p2.exe+0x8FAE23`, reading FFFFFFFFFFFFFFFF, about 10 s into the call); the
unmodified `main` tree does the same for `selftest_strataconv` and `selftest_fields` (checked on an own `paint0` instance), with and without `ed_gpu_enable(false)`. `selftest_env` (layers 9) and `selftest_assets`
(mirror symmetry stamp) fail on `main` as well. Not caused by this group; `selftest_paintundo`, `selftest_savejob`, `selftest_masksize`, `selftest_terrfix` pass.
