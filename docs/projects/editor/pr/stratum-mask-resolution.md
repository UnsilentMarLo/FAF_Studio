# PR draft: stratum masks keep the resolution they were saved with

Branch: `pr/stratum-mask-resolution` (worktree `C:\Users\Marlo\Documents\GitHub\faf-re-stratum`, one commit on top of upstream/master 4ce00d001).
Nothing is pushed and no PR is open. Title (Conventional Commits, squash-merged):

    fix(terrain): stratum masks keep the resolution they were saved with

## What changed

`CWldTerrainRes::Finalize` copied both stratum masks (the two `_utilitya_mask` / `_utilityb_mask` textures that blend the eight terrain layers) into new dynamic sheets of exactly half the map's size, and that copy is a resample on every render API. A mask a mapper saved finer than that was reduced to the preset: a 40 km map (2048 cells) kept 1024 of its 2048 texels, an 81 km map 2048 of 4096.

Each sheet is now sized by `StratumMaskExtent` (`src/moho/terrain/StratumMaskSize.h`, one axis): the mask keeps the size it was saved with, never less than half the map's size (a coarser mask is raised to it, as before) and never more than `max(2048, 2 x the map's cells)`, 8192 at the most. A mask saved at half the map's size, which is what the game's tools write, loads exactly as before. The log gets one line per map (`Terrain: stratum masks ...`). Memory: two RGBA8 sheets, 32 MB at 2048, 128 MB at 4096, 512 MB at 8192.

Files: `src/moho/terrain/CWldTerrainRes.cpp` (`Finalize`), `src/moho/terrain/StratumMaskSize.h` (new, the rule with `static_assert`s), `tests/render_math/StratumMaskSizeTests.cpp` (GoogleTest of the rule, registered in the render_math tests), `docs/RENDERER_BACKENDS.md` (section "Stratum mask resolution").

Found by the decompile graphics work on the fork (the same oversight exists in the retail binary; a retail exe resamples either way, so retail maps look the same: this matters for engines that no longer have the limit).

## Sim impact

- [x] **None.** UI, rendering, audio, movies, tooling, docs or build only; nothing the sim reads or writes.

The masks are read by the terrain renderer and by the map editor's natives only. No file under the sim folders changes.

## Build

- Arch: x64 (the change is arch neutral)
- Compiler and config: clang-cl Release (preset `clang-x64-release`)
- Checked so far: the changed translation unit compiles (`-fsyntax-only` with the project's flags). **Still to do before opening the PR:** `cmake --build --preset clang-x64-release --target faf_render_math_tests` and `ctest -L Render`, and the `clang-x86-retail-layout` preset (the change touches no recovered layout).

## Testing

Replay table: not required for "None".

- [ ] A map whose masks are finer than half its size, on D3D11, D3D12 and Vulkan, before and after (log line shows the kept size; the picture shows the finer paint). The fork's decompile session did this on Setons Isle (40 km, masks saved at 2048) with a test pattern: with 2048 sheets the detail is in the picture, with the old 1024 sheets it is gone. That used debug switches that are NOT in this PR, so repeat it with a real map (or the editor's `ed_stratum_set_size`) on this branch.
- [ ] A map saved at half its size loads with identical sheets as before (log line `stratum masks 1024x1024 ... half the map is 1024x1024`).

## Notes for the reviewer

- The retail binary has the same behaviour; the comment above `Finalize` says what the fork changes. Retail divergence: none for maps saved at half size.
- The rule is a header so a test can state it. If you prefer a smaller footprint, the three lines of `Finalize` that use it can inline `std::max(half, std::min(saved, cap))`.
- The map editor in the fork (FAF Studio) can now set the mask size per map; that part is not in this PR.
