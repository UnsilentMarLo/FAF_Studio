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
git clone <this repository> FAF_Studio
cd FAF_Studio
python scripts/studio.py doctor                # what is installed, what is missing
python scripts/studio.py engine setup          # clone the reconstructed engine, apply engine/patches
python scripts/studio.py engine build          # MSBuild (Visual Studio C++ tools, DirectX SDK June 2010), then stage into engine/run
python scripts/studio.py edtext                # DirectWrite text backend (xmake)
python scripts/studio.py generate              # git-ignored generated assets (icons, cursors, layer textures, blank maps)
python scripts/editor_inst.py new dev          # a test instance
python scripts/editor_inst.py start dev        # starts the editor (window 1280x720; --size 1920x1080)
```

Without a build environment, take a staged engine (`engine/run`) from a teammate or use a packaged build (`python scripts/package_editor.py`): the Lua side
(`editor/runtime`) runs on any staged engine, so most work (panels, tools, tests) needs no compiler.

## Repository map

| Path | What |
|---|---|
| `editor/runtime/` | The editor itself, as Lua: `lua/editor/` (model, tools, panels, `gui/`), `schook/` (hooks into the game's Lua), `override/` (shaders), `mods/`, `branding/` |
| `editor/core/`, `editor/edtext/`, `editor/tools/` | Engine-independent C++ core (formats), the DirectWrite text DLL, asset generators |
| `editor/help/`, `editor/packaging/`, `editor/samples/` | In-app help topics, the packaged launcher, sample maps |
| `engine/` | `BASE.json` (which engine commit we build on) and `patches/` (our commits, the native `Ed*.cpp` code) |
| `scripts/` | `studio.py` (set-up), `editor_inst.py` (test instances), `editor_merge.py` (parallel feature branches), `editor_nightly.py` (QA), `package_editor.py`, generators |
| `docs/` | Design, QA reports, packaging, release, parallel-work docs: start with `docs/REPOSITORY.md` |

## Testing

```
python scripts/studio.py check                 # lint + generated-file checks (no engine needed)
python scripts/studio.py check --full          # + the nightly: self tests, panels, clicks, tooltips, layout, workspaces, map stress (about an hour)
python scripts/editor_inst.py selftests dev    # every selftest_* in a running instance
```

See `docs/REPOSITORY.md` for the full workflow (instances, parallel branches, engine changes, packaging, release).
