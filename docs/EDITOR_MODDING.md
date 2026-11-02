# Extending the editor: editor mods (FAF Studio)

An *editor mod* is a mod folder that the editor loads on its own and that hooks the editor's Lua. This page is the reference for what a mod may rely on (**editor API version 1**), what the
editor does when a mod misbehaves, and how the editor's own hooks into the game are built. The working example is `editor/runtime/mods/editor_example/` (a Crater tool and a command); the
selftest `selftest_modapi.lua` loads it, calls its parts and simulates failures.

Contents: [kinds of mods](#kinds-of-mods) - [the API version](#the-api-version) - [writing an editor mod](#writing-an-editor-mod) - [extension points](#extension-points) -
[when a mod misbehaves](#when-a-mod-misbehaves) - [sim state](#sim-state) - [the map sidecar](#the-map-sidecar) - [the game hooks of the editor](#the-game-hooks-of-the-editor-schook) -
[for the map maker](#for-the-map-maker-the-mods-dialog)

## Kinds of mods

The editor (`main_x64_la.exe /editor`, content in `editor/runtime/`) decides itself which mods are active; the player's mod manager selection is ignored. Implementation:
`lua/editor/mods.lua` plus a hook on `/lua/mods.lua` (`schook/lua/mods.lua`) that answers `GetSelectedMods()` for `/editor`.

| Kind | How it is recognised | Active when |
|---|---|---|
| **Editor mod** | `editor_mod = true` in `mod_info.lua` | always (UI state; also sim state when `ui_only = false`, see [Sim state](#sim-state)); not listed in the browser; kept out when it is incompatible or broken (see below) |
| **Game (sim) mod** | not `ui_only`, not `editor_mod` | only when the map maker loaded it in the **Mods** panel (plus the mods it `requires`) |
| **UI mod** | `ui_only = true`, not `editor_mod` | never (they hook the same UI classes the editor builds on) |

Every mod folder is still mounted (installed mods from the user's `My Games/.../mods`, editor mods from `editor/runtime/mods/<name>/`, mod projects made in the unit lab from `modproj/<Name>/`),
so loading a mod later needs no new mount, only a new session.

## The API version

```lua
local Editor = import('/lua/editor/api.lua')
Editor.ApiVersion       -- 1: the version of the extension points below; raised whenever one of them changes shape
Editor.MinApiVersion    -- 1: the oldest `editor_api` the editor still loads
Editor.Has('panels')    -- true / false: does this editor offer the extension point (Editor.Has('panels', 2): at that version or newer)
Editor.Capabilities     -- { panels = 1, commands = 1, tools = 1, hooks = 1, sim_hooks = 1, sidecar = 1, safe = 1, mission_nodes = 1 }
```

A mod says which API it was written for in `mod_info.lua`:

```lua
editor_api = 1          -- missing = 1
```

The editor does not load a mod whose `editor_api` is newer than `ApiVersion` or older than `MinApiVersion`; it logs why and the Mods panel lists it under "Not loaded". Rules for the editor's
developers: an additive change (a new optional field, a new function) keeps the number; a change that can break an existing mod raises `ApiVersion` and, once the old shape is gone,
`MinApiVersion`. Only the points listed in this page are API; everything else in `lua/editor/*.lua` is internal and may change in any build (a mod that wraps an internal function does so at its own risk).

## Writing an editor mod

1. A folder with `mod_info.lua`:
   ```lua
   name = "My editor mod"
   uid = "<unique guid>"
   version = 1
   editor_api = 1        -- the extension API this mod was written for
   ui_only = true        -- false when it also hooks the sim side (see "Sim state")
   editor_mod = true     -- always loaded, hidden from the browser
   ```
   Put it in `editor/runtime/mods/<name>/` (ships with the editor) or in the user's mods folder.
2. Hook an editor Lua file under `hook/` mirroring its VFS path: `hook/lua/editor/ui.lua`, `hook/lua/editor/gui/panels.lua`, `hook/lua/editor/terrain.lua`, ... A hook is **appended to the
   module's source and compiled with it as one chunk**. So: wrap everything in `do ... end`, no top-level `local`, call the old function with all its arguments and return what it returned.
   The module's own functions and variables are visible (`Tools` in a hook on `ui.lua`). The editor is plain Lua 5.0 (Moho LuaPlus): no `^` (`math.pow`), no `#` (`table.getn`; `#` starts a
   comment), no `%` (`math.mod`), no `...` expression (`arg`), no `string.match` (`string.find` / `string.gfind`), no `goto`; reading a nil field is silent, writing into nil raises; numbers are
   32-bit floats; closures made in a `for` loop share the loop variable (copy it to a local). `python scripts/editor_lint.py` checks all of that for the editor's own files and its schook files.
3. Register what the mod adds through its registrar, so that every failure names the mod:
   ```lua
   do
       local Editor = import('/lua/editor/api.lua')
       local mod = Editor.Mod('My editor mod')
       mod.Command{ id = 'mymod.hello', title = 'My mod: say hello', run = function() Say('hello') end }
       mod.Tool(Tools, { id = 'mytool', label = 'My tool', OnPress = function(wx, wz, event) return true end })
   end
   ```
   (`Say`, `Tools` are globals of `ui.lua`; the example mod hooks `ui.lua` for that reason.) A panel is registered from a hook on `gui/panels.lua` with `Register{ mod = 'My editor mod', ... }`
   (there `Editor.Mod(...).Panel(def)` is the same call once `panels.lua` has loaded; a hook on that very file calls the module's own `Register`).

## Extension points

All of these are API version 1.

| Point | Call | Notes |
|---|---|---|
| Commands | `Commands.Register{ id, title, keys, run, mod }` (`gui/commands.lua`) / `mod.Command{...}` | Every action is a command: menus, buttons, hotkeys and the palette run commands by id. `Commands.Run(id)`, `Commands.Find(text)`, `Commands.Intercept(fn)` (take a command while a canvas owns the keyboard). |
| Panels | `Panels.Register{ id, title, create = function(group, host) ... return panel end, minW, minH, transparent, stack, mod }` (`gui/panels.lua`) | `create` builds controls as children of `group` and returns a plain table that may define `OnResize(w, h)`, `Refresh()`, `Destroy()`, `OnShow()`, `OnHide()`, `Update()`, `Tick()`. Every number setting is a `W.Slider`, every widget needs a tooltip entry, lay buttons out with `W.Flow`. `Panels.OnFailure(fn)`: `fn(id, message, mod)` is called when a panel could not be built; `Panels.failed[id]` holds the message. |
| Tools | `table.insert(Tools, { id, label, kind = 'custom', OnPress = function(wx, wz, event) ... end, workspaces })` in a hook on `ui.lua` / `mod.Tool(Tools, def)` | `OnPress` returns `false` to let the click through to the game, anything else consumes it. Brush tools (`kind = 'brush'`) use the terrain brush of `terrain.lua`. |
| Menus | `Menu.Extend('menubar.File', function(ctx) return { { command = 'mymod.hello' } } end, order)` (`gui/menu.lua`) | Providers that raise are skipped. Menu ids: `menubar.<Title>`, `context.world`, `context.object`, `context.list`. |
| Mission nodes | `Mission.Register(entry)`, `Mission.KindChecks[kind]`, `Mission.Edit(label, fn)` (`mission.lua`) | Node types for the mission compiler; owned by the mission code. A node's `emit` is run by the compiler, whose own handling decides what a failing node does; the API layer here does not wrap it. |
| Safe calls | `local Safe = import('/lua/editor/safe.lua')`: `Safe.Try(site, fn, ...)`, `Safe.Wrap(site, fn)`, `Safe.Call(site, fn, ...)` | A `pcall` that reports: the first failure of a site is logged, then the 10th, 100th ... (with the count). `site` is a short fixed text ("mymod.refresh"), not a per-call value. |
| Protected data files | `import('/lua/editor/safeload.lua').File(path, opts)` / `.Text(text, opts)` | Load a data file (a map sidecar, a project file) without trusting it; see [the map sidecar](#the-map-sidecar). |

## When a mod misbehaves

Code a mod registers with its name (`Editor.Mod(name)`, or `mod = '...'` in the definition) is **isolated**:

| What | What happens when it raises |
|---|---|
| a command's `run` | caught; logged once as `EDITOR command:<id>: failed: [mod <name>] <error>` (Console, red); the command is disabled until the editor restarts and leaves the palette |
| a tool's `OnPress` | caught; the click goes through to the game; logged and disabled the same way |
| a panel's `create` | caught; the panel shows "The panel ... could not be built (mod ...): error" instead of a blank page; `Panels.failed[id]`, `Panels.OnFailure` listeners; a mod panel is not built again in the session |
| a panel's `OnResize`, `Refresh`, `Destroy`, `OnShow`, `OnHide`, `Update`, `Tick` | caught, logged; for a mod's panel that method is off afterwards |
| `mod.Try(site, fn, ...)` | caught, logged with the mod's name, disabled |

The editor's own commands, tools and panels are protected the same way but never disabled (a transient error must not remove a built-in command): their failures are logged once per site.

**What cannot be isolated.** A hook is part of the module's chunk (see above): a *syntax error* or a *runtime error at the top level of a hook* stops that module from loading, and a module like
`ui.lua` stopping means the editor does not come up. The editor defends in three layers (`mods.lua`):

1. an editor mod that needs another API version (`editor_api`) is not loaded;
2. every hook file is compiled on its own when the mods are read; a hook with a syntax error keeps its mod out ("Not loaded: ... a hook does not compile: file:line: message" in the Mods panel and the log);
3. a trial: the editor mods that are loaded are written to `editor_emods_trial.txt` when the first session of a process starts, and the file is emptied when the editor is up. A start that
   finds the file filled did not come up: those mods go on the off list (`editor_emods_off.txt`) and stay out until the maker runs **Mods: enable the editor mods that were turned off** from the command
   palette and restarts. The first start with such a mod still fails (the window stays dark), the second one recovers on its own.

So: keep hook top levels trivial (register things, do not run logic), put the work in functions the API calls, and test a hook by starting the editor.

## Sim state

An editor mod with `ui_only = false` in its `mod_info.lua` is also loaded by the sim of the editor session, so `hook/lua/editorsim/*.lua`, `hook/lua/sim/*.lua` and `hook/lua/simcallbacks.lua` take effect there.
With `ui_only = true` only the UI state sees the hooks. This was tested (a probe mod with a hook on `lua/editorsim/peace.lua` wrote a file from the sim state with `ui_only = false` and did not with
`ui_only = true`; ScenarioInfo existed in that state). The comment at the top of `coopshim.lua` ("the engine's mod hooks are not applied to the sim of an editor session") is about the FAF coop support mod
(`lobby_coop.cop`), which the editor does not load, not about editor mods.

Differences of the sim state: only `ed_read_file`, `ed_write_file` and a few `ed_*` calls exist there (not `ed_vfs_to_disk`, `ed_file_stamp`); the UI state's `Say`, the dock and the Console are not there; use `LOG` / `WARN`.

## The map sidecar

A map's editor data (the mod list, the mission, the terrain graph, paths, layout, import / export settings, the mask range) lives in `<stem>_editor.lua` next to the map, one assignment per
feature (`Mission = { ... }`) written by `luaser.lua`. It is read by `mods.SidecarEnv(scenarioFile)` once per map open through `safeload.lua`:

- the file runs in an empty environment (no globals, no `import`), is size limited (8 MB) and its sections are type checked (`mods.SidecarSchema`);
- a syntax or runtime error in one section loses only that section (the file is cut at its top-level assignments and each is run on its own); the original text is kept as `<file>.bad`; a map with a
  broken sidecar always opens;
- `version = N` is the schema version (`mods.SIDECAR_VERSION`, 1). A file without it is version 0 and reads the same. A newer file opens as far as it is understood. When a section changes shape:
  raise `SIDECAR_VERSION` and add `Mods.Migrate[<old version>] = function(env) ... end` (it turns a version v table into version v + 1 in place; a migration that raises refuses the file);
- a feature that stores data adds its section to `SidecarText` (`mods.lua`) and reads it in `LoadSidecar` with `Mods.SidecarEnv(scenarioFile)`: never `doscript` a data file.

A mod project's `edits.lua` is loaded the same way (version 1); `bpedit.lua` keeps the previous good copy as `edits.lua.bak`, verifies every write by reading it back, opens from the backup when the file
is unreadable, and refuses to overwrite a file it could not read (`Write(true)` after the maker decided). Lua has no rename here (`os` / `io` do not exist in the UI state): the writes are in place
with a good copy on disk at every moment.

## The game hooks of the editor (schook)

`editor/runtime/schook/<vfs path>` is appended to the game's own file of that path and compiled with it as one chunk (the same rule as for mod hooks: `do ... end`, no top-level `local`, old
function with all arguments). `python scripts/editor_lint.py` checks the structure and that the path is a file of the installed game; `python scripts/hook_baseline.py check` compares the game
functions the hooks replace with the fingerprints in `schook/BASELINE.txt` (the game build they were read against is `VERIFIED` in `lua/editor/hookcheck.lua`; at run time a different build logs a warning
once). Update the baseline with `hook_baseline.py update` after reading what changed.

| Hook (base file) | What it does | Replaces or extends | Outside `/editor` |
|---|---|---|---|
| `lua/mods.lua` | `GetSelectedMods` answers the editor's own mod list, `AllMods` adds the mod projects | wraps both | base functions |
| `lua/SinglePlayerLaunch.lua` | `StartCommandLineSession`: one human army, passive civilians, no AI, no victory; a map that cannot be opened falls back to the blank map and leaves the reason for the start screen | **replaces** the body (re-implements FAF's sessionInfo and player setup: re-read the base function when FAF changes it; the baseline watches it) | base function |
| `lua/ui/uimain.lua` | `StartFrontEndUI`: after a session ended, open the queued map instead of the front end; drops `__modules` between sessions | wraps | base function |
| `lua/ui/game/gamemain.lua` | `OnFirstUpdate` protected, editor start after it; the loading dialog is the editor's | wraps | base functions |
| `lua/ui/game/tabs.lua`, `lua/ui/dialogs/eschandler.lua` | the game's top menu and Escape quit dialog are off; the window's X runs File > Exit | wraps | base functions |
| `lua/sim/scenarioutilities.lua` | no ACU in an editor world; `CreateResources` makes only the deposits | wraps; `CreateResources` is **replaced** in editor mode | base functions |
| `lua/sim/units/structureunit.lua` | no tarmac, no skirt flattening, no turning in editor mode | re-subclasses `StructureUnit` (`ClassUnit(baseStructureUnit)`); checked against build 3840: nothing else in the base file refers to `StructureUnit`, and every file that subclasses it imports the module after the hook ran | base methods |
| `lua/simcallbacks.lua` | the editor's sim callbacks (`Callbacks.EdXxx`) | adds only | harmless |

A failed map launch (`/map /maps/nope/nope_scenario.lua`, or File > Open of a map that is gone): the hook catches the error, opens `editor_blank`, writes `editor_launch_error.txt`; the start screen
opens behind a dialog that says which map and why (`gui/feature_launcherror.lua`). Verified with the instance (a screenshot of the dialog and of the start screen). Not covered from Lua: a map
that opens but whose `.scmap` is damaged fails later, inside the engine's map loader. Native follow-up for the engine side: the map-loader failure has to end the session (call back into the front end
hook) instead of leaving the loading screen; the fatal "index expected but got boolean" of `faf_crash_20261019_211727.txt` is the engine's `import` stub (`LS_import` pushes `false`) answering a C++
caller before `globalInit.lua` replaced it (see the comment in `CScApp.cpp`): ordering in the engine, fixed there, nothing to catch in Lua.

## For the map maker: the Mods dialog

Tool panel -> **Mods**: one toggle per game mod, **Apply & reload**. Mods are applied when a session starts, so Apply autosaves the map to `mapout/_modreload.v0001` and reopens it (terrain, markers and props
survive; undo history does not). The selection is saved with the map in the sidecar (`EditorMods = { uid, ... }`) and restored when the map is opened; a map without one opens with no game mods. The working copy of the
selection is `editor_mods.txt` next to the exe.

If a mod breaks blueprint loading or the sim start, the session never comes up. `editor_mods_trial.txt` holds the previous selection while a load is being tried (cleared by `control.Start()` once a session
runs); at the next launch a leftover trial file restores the previous selection instead of the map's list. Restart the editor to recover.

World clicks are taken by a wrapper that `ui.lua` installs on the final `WorldView.HandleEvent` after all hooks ran, so a mod that wraps `WorldView.HandleEvent` cannot bring back the game's selection box in edit mode.

## Where errors are swallowed

`docs/projects/editor/BARE_PCALLS.md` (generated by `python scripts/pcall_audit.py --write`) lists every `pcall(...)` statement whose result nobody reads, per file and owning group. Convert one with
`Safe.Try('site', fn, ...)`; mark one that is deliberately best effort with `-- best effort` on the same line.
