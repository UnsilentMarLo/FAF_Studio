# Plan: bringing FAF Studio's engine work into Draiget/faf-re (2026-11-11)

Status: **plan, nothing pushed, no issue or PR opened.** Written after merging `upstream/master` (4ce00d001) into our editor branch.
The comparison it rests on is `docs/projects/editor/EDITOR_COMPARISON.md` (copy of the agent's report).

## 0. Direction change (user, 2026-11-11, after the first version of this plan)

"Take what is better on the upstream editor and just PR ours as a replacement. Also PR the lua part separately as it's necessary to run the editor."

This replaces the strategy of sections 4-7 (contribute libraries, keep FAF Studio downstream). New shape:

1. **Port first.** Bring what is better in upstream's editor into ours (list in `EDITOR_COMPARISON.md` section 4: the byte-exact classic `.scmap` / save-file writer and packaging, the FAF vault, adaptive maps, the particle and material editors, water bodies and wave generators, the FAFME importers, the live-edit play loop, the script editor and checks, decal path mode, tile undo, their tests). Their logic is C++ under `src/editor/`; it has to be moved out of their ImGui / `EdDocument` model and exposed to our Lua as `ed_*` natives, with maui panels on our side. A read-only port analysis (files, ImGui share, effort, order, risks, work packages) is being written to `scratchpad/port_analysis.md` and will be copied next to this file as `EDITOR_PORT_ANALYSIS.md`.
2. **PR A, the replacement:** `src/moho/editor/` (our native side with the ported features), the engine hooks and guards of section 5, `CMakeLists` / presets / `build.ps1` for the new editor, `docs/MAP_EDITOR.md` rewritten, the tests ported to GoogleTest; and the removal of `src/editor/`, the `faf_editor` target and `FafEditor_x64` that it replaces.
3. **PR B, the Lua part, stacked on A:** the Lua tree (`FAF_Studio/editor/runtime`, about 133 k lines: maui panels, graph, mission, mod and unit tooling, selftests) into the repository (location to settle, e.g. `data/editor/`), plus the packaging script and docs. A alone does not run without B; B alone is only data. The PR text of each says so and links the other.
4. **Already separate and unchanged:** PR 0 (stratum masks) and #387 (map format containers; the editor's map format natives call its reader / exporter).

**Risk the user should know, and the plan's answer.** Upstream's editor is four days old, by the maintainer, and it is what `docs/MAP_EDITOR.md` and CI describe. A PR that deletes it without his agreement will most likely be closed, and CONTRIBUTING asks for an issue first for anything big. The plan therefore keeps the PRs unopened until the port is done and the issue (section 6, rewritten for the replacement) has been posted and answered, unless the user says to open them anyway. Nothing is opened or posted by this session without that go-ahead.

**Issue opened 2026-11-11:** [Draiget/faf-re#388](https://github.com/Draiget/faf-re/issues/388) (text in the session scratchpad `issue_editor.md`; it says the PRs wait for the maintainer's answer and offers the stratum and hooks PRs first). No PR for the editor is open.

## 1. The situation

- Upstream faf-re already has a map editor: `src/editor/` (83 files, ImGui, `FafEditor_x64.exe`, Direct3D 12 / Vulkan), written by the maintainer since 2026-11-08, 194 commits, documented in `docs/MAP_EDITOR.md`.
- Ours is a second editor, built since about 2026-10-15: `src/moho/editor/` (native, 35.7 k lines + 106 HLSL kernels), driven by Lua (133 k lines, in the FAF_Studio repo) on the game's own maui UI, Direct3D 11.
- Nobody on upstream knew about ours and we did not know about theirs (a communication issue, not a design disagreement).
- A PR "add our editor" would be 238 native files + 55 engine files + a Lua tree that is not even in that repository: a second editor next to theirs, built on a renderer upstream does not use for the editor. It would not be merged and it should not be offered as one PR (CONTRIBUTING: one topic per PR; open an issue first for anything bigger than a small fix).

## 2. What the merge showed

Branch `editor-upstream-merge` (worktree `C:\Users\Marlo\Documents\GitHub\faf-re-editor-merge`), `editor` merged with upstream/master:

- 21 files conflicted. Upstream split `Sim.cpp`, `CWldMap.cpp`, `Mesh.cpp`, `UiRuntimeTypes.cpp` and `WxRuntimeTypes.cpp` into many files; our edits were re-applied in the new files. Two hunks the patch tool placed in the wrong function were found by the compiler and moved back.
- Both sides had done the same things: the texture-atlas lookup cache (ours dropped for upstream's `ren_TextureAtlasCache`), a per-beat sim hook (now ours installs into upstream's `gSimBeforeBeat`), stratum masks, normal map speed, text and UI draw.
- The merged tree compiles and links both programs (`main_ed_x64.exe` = FAF Studio, `FafEditor_x64.exe` = upstream's editor). The merged FAF Studio exe starts, loads the blank map, and passes the selftests run so far (paint mask size 14, alpha generation 27, shaders 82, graph 326).
- Not yet clean: `faf_math_dump` reports two `acos` golden differences (`tests/math_dump`), nothing in the merge touches that code; to be checked on plain upstream/master to see whether it is this toolchain (clang 23.1.2). `headless_x64` failed to link until the editor sources were kept out of `faf_sim` and the sim's GC gate became a hook (done in the merge branch).

## 3. Rules that decide the shape (CONTRIBUTING.md)

1. One topic per PR, issue first for anything big, Conventional Commit titles, squash merge.
2. No AI or bot attribution line in any commit of a PR branch: the PR branches are rebuilt from upstream/master with clean messages; our working branches keep their history.
3. Sim parity: anything under `src/moho/{sim,...}` must keep retail checksums unless gated on `sim_FafGameVersion`; sim hooks must be null in the game. Replays from `docs/PR_REPLAY_CHECK.md` are listed in the PR for any sim-touching change.
4. GoogleTest for new tests (our native tests use their own harness: they must be ported).
5. A feature that is only for the editor must not change the game.

## 4. The design: contribute engine-level pieces, keep FAF Studio as the product on top

Do not PR the editor. Split what is useful into independent PRs that each stand without our UI, each with tests, and that upstream's own editor can use. FAF Studio keeps living in the fork (and its Lua UI in the FAF_Studio repo) and consumes the same code.

| # | PR (title sketch) | Contents | Sim impact | Needs first |
|---|---|---|---|---|
| 0 | `fix(terrain): stratum masks keep the resolution they were saved with` | ready on `pr/stratum-mask-resolution`, draft in `docs/projects/editor/pr/stratum-mask-resolution.md` | none (render) | build + test run, an in-game check |
| 1 | `feat(maps): map format containers` | **open**: issue [#386](https://github.com/Draiget/faf-re/issues/386), PR [#387](https://github.com/Draiget/faf-re/pull/387) (branch `UnsilentMarLo:pr/map-formats-containers`, one commit on upstream db2f85efb, no attribution lines, no editor code, GoogleTest, 8/8 core replays match headless). Opened by the map-format session at the user's request. It is PR 1 of a series; sim and render stages follow later | gated | review of #387 |
| 2 | `refactor(engine): editor hooks` | the null-in-the-game hooks our editor needs, each one tiny: `gSimGcDue/Done` next to `gSimBeforeBeat`, `SimpleRenderWorldView` not final, per-control clip hook for the UI, `ren` frame counters, the `CD3DTextureBatcher` ARGB atlas. Only the ones a second consumer (our editor, or later upstream's) needs; each gets a comment saying who calls it | none (null hooks); parity statement required | the guard work in section 5 |
| 3 | `feat(field): engine-independent terrain field library` | `EdField*` maths (no moho types), CPU erosion suite, goldens ported to GoogleTest, bit-identical across thread counts | none | decision on where it lives (`src/field/`?), a consumer |
| 4 | `feat(field): GPU compute backend for the field ops` | `EdGpu*`, 106 HLSL kernels, separate D3D11 compute device on the game's adapter (works beside D3D12/Vulkan), kernel check script | none | PR 3 |
| 5 | `feat(editor): erosion and terrain generation tools in the editor` | a panel in **upstream's** editor (ImGui) that calls PR 3/4: Erode / Rain / Deposit brushes first | none | agreement from the maintainer, since it touches `src/editor` |
| 6 | later, one each: Gaea / World Machine interop, mission compiler model, node-graph generator on upstream's `EdNodeCanvas` | | none | maintainer interest |

The Lua UI, the maui panels, mission / mod / unit tooling, packaging and the nightly harness stay in FAF_Studio. If the maintainer wants a second editor in the repo that is a conversation for the issue, not a PR.

### Why this order
PR 0 is small and independent. PR 2 is what makes every later PR possible without touching game behaviour; PR 3-4 are the largest valuable pieces and the most self-contained (the comparison found them engine-independent and golden-tested). PR 5 is the first thing a user of upstream's editor would see.

## 5. Work before any of them can be opened

1. **Guard every engine call into the editor.** The merged tree has 55 engine files outside `src/moho/editor` that we changed (about 2000 lines). Many call `moho::editor::...` directly and unguarded (Shadow.cpp 16 calls, WRenViewport.cpp 15, CD3DFont.cpp 9, CD3DPrimBatcher.cpp 8, CMauiFrame.cpp 6, WinApp.cpp 5, CUIManager.cpp, CMauiControl.cpp, CD3DDevice.cpp, StartupClientHelpers.cpp ...). That links only when the editor is compiled in. For PRs they must be either hook pointers (like `gSimBeforeBeat`) or inside `#if defined(FAF_STUDIO_EDITOR)`. The sim file (`SimTick.cpp`) is already converted.
2. **Drop or gate our divergences from retail:** prop scale lanes kept in `CWldMap` (`EDITOR DIVERGENCE`), the AA / token fixes (dropped in the merge), the null-slot pop-out fix (that one is a real crash fix and can go as its own `fix(ui)` PR).
3. **Port the native tests to GoogleTest** (`scripts/ed_native_tests.py` runs 38 files with a private harness).
4. **Check the toolchain failure** (`acos` goldens) on plain upstream/master.
5. **In-game check of PR 0** with a real map whose masks are finer than half the map (D3D11, and D3D12 / Vulkan where it can run).
6. **Rebase the PR branches** from the merge branch onto current upstream/master right before opening (it moves several commits a day), strip attribution lines, write the template's Sim impact / Build / Testing sections honestly.

### What the editor work can build on from #387 (message of the map-format session, 2026-11-11)
- `src/moho/sim/mapformat/` (standard C++): `LoadExtendedMap(bytes, LoadOptions, ExtendedMap&, err)` reads container 3 / 4; `ExportClassic(ExtendedMap, options, result, err)` is "export for older game versions" (`result.notes` lists approximations); `DetectFormat` / `DescribeFormat` in `MapFormat.h`; the Python reference writer in `tools/mapformat/mapfmt/` is the byte-exact oracle.
- Engine side: `WLD_GetMapFormatInfo()` and `WLD_GetExtendedMap()` (`CWldMap.h`) for the loaded map, `GetMapFormat()` in Lua.
- **Not in #387, so the editor must not assume it:** map writing in C++ (only the Python writer exists), `SaveSupplement` (markers / areas into the save file), the render requirement / lobby flag, all render and sim stages.
- Consequence for our editor: `ed_map_format`, `ed_map_info` and "`ed_map_save` refuses container 3 / 4 maps" (branch `editor-mapformat`) belong with the editor work and must call that reader / exporter instead of re-implementing them. Until a C++ writer exists the editor cannot save container 3 / 4 maps; it keeps refusing.
- Spec questions go to the reviewer on #386 / #387.

## 6. Draft of the first issue (to post before PR 2-5; nothing posted)

> **Title:** RFC: contributing a terrain field library, GPU erosion and the engine hooks it needs
>
> I have been building a map editor for the fork (FAF Studio: maui UI, Lua, Direct3D 11) without knowing the editor in `src/editor` existed. The two overlap in the UI, and I do not want to propose a second editor. What I can offer as separate PRs, each with GoogleTest coverage and no change to the game:
> 1. a stratum-mask resolution fix (small, ready),
> 2. a few null-in-the-game engine hooks (sim GC gate, clip hook, non-final `SimpleRenderWorldView`),
> 3. an engine-independent terrain field library (100+ ops, CPU hydraulic / thermal / droplet erosion, bit-identical across thread counts, goldens),
> 4. a GPU compute backend for it on a separate D3D11 device (works beside D3D12 / Vulkan),
> 5. an erosion / generation tool in the existing editor built on 3 and 4.
>
> Would you want these, and is `src/field/` (library) + a tool in `src/editor/tools/` the layout you prefer? I will keep each PR to one topic and list the replays for anything near the sim.

## 7. Decisions for the user

1. Keep FAF Studio as a separate downstream product (recommended) and contribute libraries and the erosion tool, or ask the maintainer whether he wants a second editor? (Section 4 assumes the first.)
2. Which renderer for FAF Studio long term: staying D3D11 (and `EdMeshDraw`, `EdFxaa`, `EdPopout`, `EdOverlay` on the raw device) or moving them to D3D12 / Vulkan so the code can sit next to upstream's editor? Does not block PR 0-4.
3. May I post the issue draft in section 6, and from which account? (I will not post anything without a go-ahead.)
