# FAF Studio

A native map, mission and mod editor for **Supreme Commander: Forged Alliance** (FAF). It is the game's own engine in an editor mode: what you see is rendered by the
game's renderer, with the game's own simulation behind it for test runs.

- **Terrain:** height brushes, erosion, a native field engine (100+ ops), a node-graph generator (Gaea / World Machine class), splines, SC-specific tools (pads, symmetry,
  reachability), live Gaea / World Machine import, texture layers, stratum themes, lighting presets, mesh terrain.
- **Objects and missions:** markers, areas, chains, props, units, army setup, platoons, mission stages with a script compiler, bases, dialogues, test runs in the real sim.
- **Mods and units:** a mod project browser, blueprint editor, new-unit wizard with validators, unit viewer (animations, bones, LODs), effect viewer, icon generator.
- **Release:** map packaging, validation, and a packaged editor (`scripts/package_editor.py`) that runs on top of any FAForever client install.

The editor needs the FAForever client installed (its game data, `init_faf.lua`, `fa_path.lua`); nothing of the game is copied into this repository.

## Quick start

```
git clone --recurse-submodules <this repository> FAF_Studio       # the engine (engine/faf-re) is a submodule: our fork of the reconstructed engine
cd FAF_Studio
python scripts/studio.py doctor                # what is installed, what is missing
python scripts/studio.py build                 # THE command after every pull: moves the engine to the pinned commit, builds it (CMake + clang-cl, DirectX SDK June 2010 for d3dx9),
                                               # builds edtext.dll (xmake), stages into engine/run and brands FAFStudio.exe; prints what was updated and what could not be
python scripts/studio.py generate              # git-ignored generated assets (icons, cursors, layer textures, blank maps)
python scripts/editor_inst.py new dev          # a test instance
python scripts/editor_inst.py start dev        # starts the editor (window 1280x720; --size 1920x1080)
```

The engine is [UnsilentMarLo/faf-re](https://github.com/UnsilentMarLo/faf-re), a fork of [Draiget/faf-re](https://github.com/Draiget/faf-re) (the reconstruction of the Moho engine). The branch `editor` is
upstream plus the editor: `src/moho/editor` and a few changes in engine files, ordinary commits (remote `upstream` = Draiget). This repository pins the commit it builds with (`git add engine/faf-re`
records a new one). CMake brings the engine's third-party libraries itself (boost, wxWidgets, DXC are downloaded and patched at configure; the rest are submodules of the engine): nothing is
kept outside git by hand any more. The editor is built with `-DFAF_EDITOR=ON` (`src/CMakeLists.txt` of the engine), output `build/editor-x64/src/main_ed_x64.exe` inside `engine/faf-re`.

`git pull` moves the pin of `engine/faf-re` but not the checkout: `studio.py build` (or `engine sync`) fast-forwards it. The exe is updated when `studio.py build` ends with the list of staged
files and no "NOT UPDATED" line (a running FAF Studio or main_x64_la process locks the exe: close it first).

Without a build environment, take a staged engine (`engine/run`) from a teammate or use a packaged build (`python scripts/package_editor.py`): the Lua side
(`editor/runtime`) runs on any staged engine, so most work (panels, tools, tests) needs no compiler.

## Repository map

| Path | What |
|---|---|
| `editor/runtime/` | The editor itself, as Lua: `lua/editor/` (model, tools, panels, `gui/`), `schook/` (hooks into the game's Lua), `override/` (shaders), `mods/`, `branding/` |
| `editor/core/`, `editor/edtext/`, `editor/tools/` | Engine-independent C++ core (formats), the DirectWrite text DLL, asset generators |
| `editor/help/`, `editor/packaging/`, `editor/samples/` | In-app help topics, the package README, sample maps |
| `engine/` | `faf-re/` (git submodule: our fork of the reconstructed engine, branch `editor`: the native editor code in `src/moho/editor`), `run/` (staged, ignored) |
| `scripts/` | `studio.py` (set-up), `editor_inst.py` (test instances), `editor_merge.py` (parallel feature branches), `editor_nightly.py` (QA), `package_editor.py`, generators |
| `docs/` | Design, QA reports, packaging, release, parallel-work docs: start with `docs/REPOSITORY.md` |

## Testing

```
python scripts/studio.py check                 # lint + generated-file checks (no engine needed)
python scripts/studio.py check --full          # + the nightly: self tests, panels, clicks, tooltips, layout, workspaces, map stress (about an hour)
python scripts/editor_inst.py selftests dev    # every selftest_* in a running instance
```

See `docs/REPOSITORY.md` for the full workflow (instances, parallel branches, engine changes, packaging, release).
