# CLAUDE.md: FAF Studio

Read `README.md` and `docs/REPOSITORY.md` first. These rules are mandatory for work in this repository.

## Lua dialect: Moho LuaPlus (Lua 5.0.1)

- No `^` (`math.pow`), no `#` length (`table.getn`; `#` starts a comment), no `%` (`math.mod`), no `...` expression (`arg`), no `string.match` (`string.find` / `string.gfind`), no `goto`.
- Reading a nil field is silent, writing into nil crashes: create every table you write into. Numbers are 32-bit floats.
- `import('/lua/...')` with absolute lowercase paths; module globals are module fields. Closures in `for` loops share the loop variable: copy it to a local.
- Modules are cached per process: restart the test instance after a Lua edit.
- `type()` of a native function (`ConExecute`, `ed_*`) is `'cfunction'`, not `'function'`: a check `type(f) == 'function'` rejects every native.
- A hook under `editor/runtime/schook/<vfs path>` is appended to the base file and compiled as one chunk: mirror the full VFS path, wrap in `do ... end`, no top-level `local`,
  call the old function with all arguments. Read the base definition first (a FAForever/fa checkout, `FAF_STUDIO_FAF_REPO`).

## UI

- Maui clips only below a control that was told to: `control:SetClipChildren(true)` (engine, `moho/editor/EdUiClip.h`; panels' scroll holders and dialogs do it, `W.ScrollContent`). Anywhere else a control past its parent's edge is
  drawn over its neighbour (and a control half inside a clipping group is drawn cut, and hit only inside it). Lay rows of buttons out with `W.Flow`; no fixed x positions that assume a panel width.
- Every number setting is a `W.Slider` (field + bar + minus / plus). Every widget has a tooltip (`tipdata.lua`). Every panel is a `gui/panels_*.lua` that registers itself.
- Choosing from a long list (units, textures, more than ~20 names) goes through `gui/browser.lua` (categories, search, preview: `docs/projects/editor/BROWSER.md`), never a flat scroll list.
- The game's own HUD (top menu, Escape quit dialog, unit life bars) is off in the editor and in test runs; the editor owns leaving, restarting and quitting.

## Testing

- `python scripts/studio.py check` (lint, generated files) after any change; for UI work start a test instance and look at the result with `editor_inst.py shot`.
- A test instance has its own tag; never stop a process by name, only by the pid an instance wrote. Do not touch other people's instances.
- Never enable page heap or change the FAF installation; never overwrite `ForgedAlliance.exe`; never commit or upload an exe.

- A change is not done until it ran in an instance and you looked at it (screenshot, perf report, log). "Could not run it" means unverified: say so, do not ship the guess.
- Run the selftests of what you touched, `studio.py check`, and for layout / frame cost the nightly steps `layout` and `perf` (`python scripts/editor_nightly.py --tag <own tag> --skip <others>`). A performance or layout fix needs a before / after number from them.
- Git Bash rewrites `/maps/...` arguments: `export MSYS_NO_PATHCONV=1` before `editor_inst.py start --map /maps/...`; a worktree needs `--editor $(pwd -W)/editor/runtime`.

## Engine

The native code is the git submodule `engine/faf-re` (fork UnsilentMarLo/faf-re, branch `editor`; `src/moho/editor`). Change it there, commit, push, then commit the new pin here (`git add engine/faf-re`); build with `studio.py build`.
