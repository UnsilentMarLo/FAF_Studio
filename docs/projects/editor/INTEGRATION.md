# Editor port: integration of WP1 to WP10 (2026-11-11)

All ten work packages of `EDITOR_PORT_ANALYSIS.md` were done on separate local branches. This pass puts them on one branch and tests the result. Nothing is pushed, no PR or issue is open.

## Update 2026-11-12: upstream merged, 0 commits behind

`port/integration` (engine) now contains `upstream/master` @ `432a9df09` (59 commits since the first integration), head **`3eb58c320`**, `git rev-list --count HEAD..upstream/master` = 0.

**How the whole-tree format commit was handled** (upstream `107e6ad79`, formatting of 3020 files with clang-format 22.1.8, plus a CI "Format" check of the lines a PR changes):

1. Merged upstream up to the commit before it (`2c4ff1c85`): one conflict, `tests/CMakeLists.txt` (upstream added `SoundMuteTests.cpp` to `faf_editor_bake_tests` and listed three sources that our `faf_editor_logic` library already compiles: kept our target, added the new test file).
2. Formatted **our whole tree** with the same clang-format (22.1.8 from pip, `.clang-format` as of that commit; 3165 files, 2568 changed) and committed it (`9d50538d7`). Both sides are then formatted by the same tool, so upstream's format commit has nothing to fight with.
3. Upstream's format commit also turned 32 CRLF files into LF (clang-format alone keeps CRLF): the same 32 files were converted on our side (`92d9fb900`), plus one blank line of `ReflectionPrivate.h` taken as upstream has it.
4. Merged `107e6ad79` with `-X ours` (`d3d8fb719`): no conflict arose, and the merge changed nothing on our side (the tree equals its first parent). Check: the files that differ from upstream's formatted tree are exactly our 312 changed or added files; no file of upstream's that we did not touch differs.
5. Merged the rest of `upstream/master` (`670c25e8b`): two conflicts.
   * `src/moho/sim/CWldMap.h`: upstream removed the unused `MapSave` and `MapSetPreview`; kept only our `MapSaveToDiskPath` declaration (its definition lives in `CWldTerrainRes.cpp`).
   * `src/moho/app/WRenViewport.cpp`: includes, both sides kept (our editor includes plus upstream's `gpg/gal/PipelineDefer.h`; one duplicate `WxPrivate.h` dropped).
6. Compile errors after the merge, all from upstream's "remove functions nothing links and nothing calls" batches (they cannot see our editor sources, which call them): `CD3DPrimBatcher::DrawTri` and its private helper `AddVert` (the editor's UI clip cuts quads into triangles) and `moho::WIN_GetMainWindow` (frame rate limiter). All three restored as they were (`f6809736e`, `3eb58c320`). `MapSave` / `MapSetPreview` stay removed.
7. The CI command was run on the result (the file `.github/workflows/format-check.yml`): `git clang-format --style file --extensions c,cc,cpp,cxx,h,hh,hpp,hxx,inl --diff upstream/master HEAD -- src tests tools` with clang-format 22.1.8 prints nothing (one comment in `CWldMap.h` had to be wrapped, `ac7a6e2d4`). To redo it: `python -m venv V; V/Scripts/pip install clang-format==22.1.8`, then the command above.

**Results on the merged engine** (exe `main_ed_integ_x64`, instance `integ`, Lua of FAF_Studio `port/integration`; raw lists in the shared notes folder):

| Check | Result |
|---|---|
| Build `-DFAF_EDITOR=ON` | clean; the link-time `faf_math_dump` check now passes (`0 differ`, upstream's acos variant `b3f9efd43` came with the merge) |
| `ctest` (54 tests, 32 test executables) | **53 pass, 1 fails**: `math_dump` at its 1,000,000 iterations run: six `acos` blocks (2, 3, 8, 10, 12, 13) differ, nothing else; the same x87 `fpatan` last-bit effect that upstream's variants file lists for blocks 0 and 1 on EPYC runners; this machine is a Ryzen 7 5800X3D. `render_math` (camera `LookAt`) passes now: upstream fixed it in `7ab8b0336` |
| Editor native tests (`FAF_RETAIL_MAPS` set) | `faf_editor_brush_tests` 219 pass, 6 skipped (same data-dependent six as before); `faf_editor_bake_tests` 6/6 (4 + upstream's 2 `SoundMute`); water bodies 14/14 and 6/6 |
| All selftests (`editor_inst.py selftests integ`) | **everything PASS**, including `selftest_alphagen` (it ran out of memory in the earlier full runs) |
| `editor_lint.py` | 0 errors, 0 warnings (442 files) |
| Retail round trip, 61 maps | 60 byte-identical, 1 different (`X1MP_007`, the kept fix), as before |
| Play with a water body | sim ran 795 ticks, `sim_FixWaterBodies=1`, surface 20 inside the lake (terrain 10), 25 outside |
| Play of a map saved with a baked WP10 layer | layer 3 points into the map folder, 256 px DDS, sim ran 871 ticks |
| `-DFAF_EDITOR=OFF` | not rebuilt in this pass (the refactor is left out on purpose); the 52 undefined symbols counted below were found before the merge |

Regressions caused by the merge: none beyond the three restored functions above. New upstream editor work that overlaps `src/editor/` (the code our replacement PR removes) and is **not** ported to our editor: `aef890e75` selected props outlined in yellow, `1410b4cdf` / `8571b64e1` prop and tree hover outlines (techniques appended to `mesh.fx`), `521a034ef` the editor's sound mutes while its window is in the background (`SoundMuteTests` are in the bake test now; the audio change itself is engine code), `229d86dd4` a play test about walking around a raised ridge, and `81939e660` the prop browser in the Properties panel (before the first integration).

## Where it lives

| What | Where | Head |
|---|---|---|
| Engine (C++) | `C:\Users\Marlo\Documents\GitHub\faf-re-port-integ`, branch `port/integration` of the engine repo (`FAF_Studio/engine/faf-re`), cut from `editor-upstream-merge` = `editor` @ `178f1d7fe` | `3eb58c320` (with upstream `432a9df09` merged; `1ea968d29` before that: the 9 merges and the WP commits) |
| Lua (FAF_Studio) | worktree `C:\Users\Marlo\Documents\GitHub\FAF_Studio-integ`, branch `port/integration`, cut from `main` @ `6a0bf3a` | `14286d0` (3 fix commits on top of `main`) |

The WP Lua commits (WP2 `b7b6b96` ... WP10 `6a0bf3a`) were all committed to `main` of FAF_Studio, so **no Lua merge was needed**; `port/integration` there is `main` plus the three fixes below. `main` of the shared checkout has uncommitted changes of other sessions (`map.lua`, `tipdata.lua`, `tooltips.lua`, `units.lua`, the `engine/faf-re` pin); none of them is in `port/integration`.

The WP branches themselves and `port/wp5-int` were not touched.

## Merge order and conflicts (engine)

Order: WP1 `port/wp1-logic-lib`, WP2 `port/wp2-importers`, WP3 `port/wp3-exact-save`, WP4 `port/wp4-vault`, WP5 `port/wp5-adaptive`, WP6 `port/wp6-water`, WP7 `port/wp7-brushes`, WP8 `port/wp8-particles` (contains WP3), WP10 `port/wp10-material` (contains WP8). WP9 is Lua only.

| Merge | Commit | Conflict |
|---|---|---|
| WP1 | `99dcdb72f` | none |
| WP2 | `a3060db3f` | none |
| WP3 | `0bc2b18a2` | `src/moho/editor/editor_sources.cmake`: both add a binding file at the same place. Kept both (`EdUpImportLua.cpp`, `EdUpMapFileLua.cpp` + `editor/doc/EdMapFile.cpp`) |
| WP4 | `051e6cde4` | the same file, same cause, kept both |
| WP5 | `2d00d762b` | the same |
| WP6 | `96a9038e3` | the same |
| WP7 | `4b708482c` | the same |
| WP8 | `d669951c8` | the same |
| WP10 | `1ea968d29` | none |

`editor_sources.cmake` is the only file that conflicted. `EdUpCommon.h` and the other CMake lists merged without help. No conflict markers are left (`git grep` over `src tests cmake docs`), and no source is listed twice.

After each merge the engine was built (`-DFAF_EDITOR=ON`, exe `main_ed_integ_x64`): every step compiled and linked. The only failing step of every build is the `faf_math_dump` check (see below), which is not related to the merges.

## Fixes made on the integration branch

Engine: none needed.

Lua (FAF_Studio `port/integration`):

1. `10ae6d5` **`tipdata.lua` did not load at all.** WP5 had appended two entries (`adaptive.panel`, `adaptive.window`) after the closing `}` of the `Command` table: a syntax error (`unexpected symbol near '['`, line 1234). The editor falls back silently, so every widget and command tooltip was empty. Found because `selftest_assets` reported "nonexistent global variable Widget". Package: WP5. (`editor_lint.py` does not catch it; the dialect check is clean either way.)
2. `e9a617b` **Missing tip texts** found by `selftest_assets` once the file loaded: the panel tabs `material`, `materialnode`, `materialout` (WP10), the menu command `file.vault` and the start screen button `FAF vault` (WP4). Added. **`selftest_roundtrip` (WP3) assumed a fresh session** and failed ("nothing is marked changed in a fresh session", "the masks were not touched") when run after the other selftests, which edit the map: the fresh-session check is now reported as skipped when the session was edited, and the masks check compares with the state at the start.
3. `14286d0` the `ed_adaptive_tables_path` stub in `selftest_waterbodies.Build` (WP6/WP8/WP10 notes) is removed: the integrated engine has the adaptive natives. (The WP8 test stub lived outside the committed files.)

## Test results

| Check | Result |
|---|---|
| Build `-DFAF_EDITOR=ON`, all 9 merges | links every time; `faf_math_dump` check fails (below) |
| `python scripts/editor_inst.py selftests integ` (all selftests of the Lua tree, third run after the fixes) | everything PASS except `selftest_alphagen`: out of memory late in the long run (it passed, 27 checks, in the first full run; known caveat of long runs, noted by WP5). `selftest_assets` and `selftest_roundtrip` pass after the fixes above; they failed before. In the first run all of WP1-WP10's selftests passed: `vault` 34, `import`, `wp7`, `adaptive` 132, `waterbodies` 47, `particles`, `material` |
| `python scripts/editor_lint.py` | 18626 uses checked, 0 names missing; dialect: 442 files, 0 errors, 0 warnings |
| Native tests, `ctest` (53 registered, 31 test executables built via `--target faf_tests`) | 51 pass, 2 fail, both **not from this work**: `math_dump` and `render_math`, see below |
| Editor native tests with `FAF_RETAIL_MAPS` set | `faf_editor_brush_tests` 225 tests: 219 pass, 6 skipped (need data not set up here: `AdaptiveTables.DualGapsGeneratedFileChangesOneLine`, `GroupOptions.DualGapAdaptive`, `EffectGraph.TheGamesEmittersAndTemplates`, `Emitter.TheGamesBeamsAndTrailsReadAndWriteBack`, `Emitter.TheGamesEmittersReadAndWriteBack`, `Vault.RealVaultArchiveInstalls`); `faf_editor_bake_tests` 4/4; `faf_water_bodies_tests` 14/14; `faf_water_bodies_map_tests` 6/6; `faf_terrain_check` skipped. The skipped ones passed in their WP sessions with the extracted game files; not repeated here |
| Retail round trip (`scripts/ed_roundtrip.py integ`, 61 retail maps opened and saved untouched) | **60 byte-identical, 1 different**: `X1MP_007` (the `.scmap` differs by 34 bytes, because `strata.Normalize` gives a layer with an albedo and no normal the neutral normal): the fix the user decided to keep. Every map saved twice gives the same bytes |
| Play with water bodies (map `wp6_lakes`, built by `selftest_waterbodies.Build`, saved, reloaded, `Verify` 7/7, then Play) | the sim ran 918 ticks with `sim_FixWaterBodies=1`; `GetSurfaceHeight` is 20 inside the lake (terrain 10) and 25 outside (terrain 25) |
| Play of a map saved with a baked WP10 layer (noise mask, 256 px, layer 3, tile 20) | the save copied the files into the map folder; after the reload layer 3 points to `/maps/wp10_bake.v0001/env/layers/maptex_mata_1.dds` (normal `maptex_matn_2.dds`, a 256 px DDS); Play ran 958 ticks in the game UI, no error in the log |
| Sim checksum / replay digest of an unedited retail map | **not run** as a runtime comparison. What is known: the nine merges change three files outside `src/moho/editor` and `src/editor`: `src/CMakeLists.txt` (7 lines), `src/moho/render/textures/CD3DFileBatchTexture.cpp` (client) and `src/moho/terrain/CWldTerrainRes.cpp` (client). `headless_x64` links neither (it uses `WldTerrainResHeadless.cpp`); no sim file (`STIMap`, `WaterBodies`, `Sim*`) differs from the base. The `.text` of base and integrated `headless_x64.exe` has the same size (6,185,984 bytes), the hashes differ (embedded build info and paths); that is consistent with identical code but is not a proof. The AI game harness that could give digests lives on the `fai` branch; this exe has no `--skirmish` |
| Nightly (`scripts/editor_nightly.py`) | not run (the user wants it only for big cross-cutting changes or on request) |

### The two failing native tests are not ours

* **`faf_math_dump`, `acos 0` and `acos 1` golden blocks.** `tests/math_dump` is identical to upstream's. Upstream's `b3f9efd43` ("cpu_variants.txt accepts acos blocks 0 and 1 as AMD EPYC 9V45 runners give them (x87 fpatan's last bit)") is newer than our merge. Plain upstream `81939e660`, built here in `faf-re-upstream`, passes `--check` on this machine (Ryzen 7 5800X3D) with exactly these two blocks reported as `VARIANT`. So it is a CPU-dependent last bit that upstream fixed after our merge point, not a regression.
* **`render_math`, `RenderGeomCamera.LookAtPlacesTheCamera`** (the test's forward vector has the opposite sign). `GeomCamera` and the test are not changed by us; the same test built from plain upstream `81939e660` fails the same way.

## `-DFAF_EDITOR=OFF` build (engine files that call editor code unguarded)

Target `faf_main`, `build/off-x64`: every file compiles, the **link fails with 52 undefined symbols from 18 engine source files** (full list: `off_link_errors.txt` in the shared notes folder, summary `off_link_summary.txt`). The refactor was not started.

| Group | Symbols | Examples |
|---|---|---|
| `moho::editor::...` (launch state, perf, shadow cache, text) | 20 | `editor::launch::Active()` |
| `moho::edtext::...` (the editor's text faces) | 8 | `edtext::IsEdFace(char const*)` |
| cvar-like globals defined in editor code | 6 | `ren_WaterSkipDisabled`, `ui_SkipTransparent`, `ui_CullOffscreen`, `ren_ShadowCache`, `ren_ShadowCacheTrees`, `ren_ShadowCacheMaxAge` |
| `edfxaa` (FXAA frame scope) | 5 | `FrameScope::FrameScope`, `Resolve`, `AddRect`, `ReleaseDeviceResources` |
| `edicon` (icon generator request) | 5 | `TakeRequest`, `Complete`, `TempPath`, `gActive`, `gClearArgb` |
| `edmesh` (mesh view) | 5 | the mesh terrain draw and pick functions |
| `edpopout` | 2 | `RenderAll` |
| `edoverlay` | 1 | takes a `CD3DPrimBatcher*` |

Referencing files: `app` (`CScApp`, `StartupClientHelpers`, `WRenViewport`, `WinApp`), `render` (`Shadow`, `CD3DDevice`, `CD3DFont`), `terrain` (`CWldTerrainRes`, `HighFidelityTerrain`, `HighFidelityWater`, `LowFidelityWater`), `ui` (`CMauiBitmap`, `CMauiBorder`, `CMauiControl`, `CMauiFrame`, `CMauiText`, `CUIManager`, `CUIWorldView`). Most are in `WRenViewport.cpp` (about 16 call sites), `HighFidelityTerrain.cpp` (9), `CD3DFont.cpp` (9). The earlier count of 55 files was a text count of engine files that mention editor code; the link shows the 18 that actually break the OFF build (the other mentions are guarded, header-only or inline).

How to close it (not done): a hook table in one engine header (null in the game, set by `EdBootstrap` like `gSimBeforeBeat`) for the call sites, and the cvars defined in an engine file with the editor only reading them.

## Remaining blockers before any PR

1. ~~The branch is 25 commits behind `upstream/master`~~ **done 2026-11-12**: 0 behind, formatted as the CI wants (see the update at the top). Open: upstream moves fast (59 commits in a day); merge again right before opening a PR, and run the format command.
2. **The OFF build does not link** (above). PR A needs it: the engine without the editor must be what upstream's CI builds.
3. **Engine edits outside `moho/editor`** are visible to review and some are unguarded: `CD3DFileBatchTexture.cpp` (WP8, marked `// EDITOR:`), `CWldTerrainRes.cpp` (WP3/WP6), the FXAA, text, popout and shadow-cache hooks of the base.
4. **Not run:** the nightly; a runtime sim digest of retail maps (needs the `fai` harness or a replay on an installed map); the skipped native tests listed above with their data; vault sign-in and a real search/download (needs the user's FAF login); WP8's effect-graph canvas does not exist; WP8's "mod with a new emitter file in a game session"; WP5's "Preview a game"; Play with an `.scmwtr` water file.
5. `alphagen` runs out of memory at the end of a full selftest run (old caveat).
6. Strip the AI attribution lines from every commit that goes into a PR branch (CONTRIBUTING); the engine commits made here have none, the FAF_Studio fixes carry the usual line.
7. User decisions still open: the vault client id note (kept as upstream's), and when the PRs A (native replacement) and B (Lua) are opened (wait for the maintainer's answer on #388 unless told otherwise).

## Reproducing

```
git -C <engine> worktree add -b port/integration <dir> editor-upstream-merge
# merge the nine branches in the order above; keep both sides in editor_sources.cmake
python scripts/editor_inst.py new integ                       # in the FAF_Studio worktree
python scripts/editor_inst.py start integ --exe main_ed_integ_x64.exe
python scripts/editor_inst.py selftests integ
python scripts/ed_roundtrip.py integ --exe main_ed_integ_x64.exe
```

A fresh worktree needs the dependency folders: copy `dependencies/` from another worktree instead of letting CMake download Boost and wxWidgets (the download stalled here).
