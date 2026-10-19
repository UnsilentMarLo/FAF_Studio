# Parallel editor development: testing and merging

Several Claude sessions (or you) can work on FAF Studio features at the same time. Two scripts and four small conventions make that safe. Verified 2026-10-18: three engine
instances ran at once (two on the main checkout, one on a git worktree), each answered its own command channel while another window had the focus, a session reload worked in a
background window, and the self tests passed in each.

## 1. Testing: one isolated engine instance per session (`scripts/editor_inst.py`)

An instance `<tag>` lives in `engine_decomp/runs/<tag>/`: hard links of the engine exes and DLLs, its **own** state (`bin/editor_mods.txt`, trial file, crash files, config, workspaces),
its own `mapout/`, `modproj/`, `run.log` and command channel, and a junction `editor` to the Lua tree it runs. It only ever touches its own PID.

```
python scripts/editor_inst.py new <tag> [--editor <worktree>/editor/runtime]   # once; default: this checkout's tree
python scripts/editor_inst.py start <tag>        # also the way to pick up Lua edits (modules are cached per process)
python scripts/editor_inst.py cmd <tag> file.lua # run a Lua chunk in the editor, print the result (what hcmd.sh did)
python scripts/editor_inst.py shot <tag> out.png [--crop x0,y0,x1,y1]
python scripts/editor_inst.py selftests <tag>    # terrain, command stack, mission self tests
python scripts/editor_inst.py focus <tag>        # only if a window ever idles: a click on its title bar
python scripts/editor_inst.py list | stop <tag>
```

Rules:
- Pick a tag per session or feature (`mission`, `icons`, `reg`) and use **only** it. Do not use `C:/tmp/start_h.ps1` / `hcmd.sh` any more: they kill every `main_x64_la_p2` by name and share `bin/` state.
- A worktree has its own Lua tree: `new <tag> --editor <worktree>/editor/runtime`. `start` copies the git-ignored generated `maps/` (the blank map) into it once.
- Shared and still serial: the **native engine build** (`C:/tmp/build_deploy.ps1`) stops every instance by name and replaces `run_x64/bin/main_x64_la_p2.exe`; instances pick the new exe up at their next `start`.
  Build only when an engine change needs it, say so in the session, and restart your instance afterwards.
- Shared by design: the FAF data folders (read only), the shader cache.
- Write helper scripts with the Write tool: the Bash tool turns backslashes in heredocs into real characters.

## 2. Merging: a worktree and a branch per feature (`scripts/editor_merge.py`)

```
python scripts/editor_merge.py new <feature>          # .claude/worktrees/ed-<feature>, branch ed/<feature>, prints the instance command
  ... work, commit on the branch, test in your own instance ...
python scripts/editor_merge.py status                 # all ed/* branches: ahead/behind, files touched, which pairs would conflict
python scripts/editor_merge.py try a b [--test]       # merge them in order into a throw-away integration tree; --test runs the self tests of the result
python scripts/editor_merge.py land a b [--test]      # try, then merge into the base branch of the main checkout (one merge commit each)
```

`land` refuses when the main checkout has uncommitted changes in a file the branches touch (sessions that work in the main checkout without a worktree). Commit only your own files there.

## 3. Conventions that keep merges clean

| Conflict hot spot | Convention |
|---|---|
| `gui/shell.lua` panel imports and refresh calls | Every `gui/panels_*.lua` is imported automatically; a module-level `Refresh()` is ticked automatically (`NoAutoRefresh = true` opts out). Add a panel = add a file. |
| Commands and File / Edit menu entries | A `gui/feature_<name>.lua` is imported automatically and registers its own commands (`Commands.Register`) and menu items (`Menu.Extend`), see `feature_release.lua`. |
| `gui/workspace.lua` presets | `Panels.Register{ ..., stack = { workspace = 'Mod', with = 'unitlab' } }` puts the panel into an existing tab stack. Only a new workspace edits the presets. |
| `schook/lua/simcallbacks.lua` | New sim callbacks go in `lua/editorsim/<feature>.lua` with `function Register(Callbacks)` (loaded at the end of simcallbacks.lua; example `ping.lua`). |
| Design documents appended at the end | `.gitattributes` marks `MAP_EDITOR_DESIGN.md`, `MAP_EDITOR.md`, `MOD_UNIT_EDITOR_DESIGN.md` as `merge=union`: two branches that both add sections keep both. Number your section after merging if it matters. |
| `ui.lua` tool table, `menus.lua`, `commands` | Still shared files; they merge line by line. If a pair conflicts, `status` says so before you try. |

Not covered: two features that edit the same function of the same file need a human to merge; do that in the branch, not in the main checkout.

## 4. Start state of an instance (2026-10-19)

The editor now remembers layouts, UI scale, the last workspace, tools and brush settings between runs (docs/projects/editor/PACKAGING.md). An instance keeps them in `<instance>/bin/userdata`
(the real user folder comes from `/eduser`, which instances never get), and `editor_inst start` **clears that folder** so a test starts from the defaults. Pass `--keep-userdata` to test what is
remembered. `--nomap` starts without `/map` (the start screen comes up), `--extra /eduser <dir>` hands more arguments to the engine. A second window (pop-out, the Help window) is captured with
`python editor/textlab/shot.py <out.png> --pid <pid> --nth 2`. Maui's hover and tooltips need the real pointer (`SetCursorPos`), posted mouse messages are enough for clicks, drags and the wheel.
