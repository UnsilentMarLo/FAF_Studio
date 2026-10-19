# Mods in the editor (FAF Studio)

The editor (`main_x64_la.exe /editor`, content in `editor/runtime/`) decides itself which mods are active; the
player's mod manager selection is ignored. Implementation: `editor/runtime/lua/editor/mods.lua` plus a hook on
`/lua/mods.lua` (`editor/runtime/schook/lua/mods.lua`) that answers `GetSelectedMods()` for `/editor`.

| Kind | How it is recognised | Active when |
|---|---|---|
| **Editor mod** | `editor_mod = true` in `mod_info.lua` | always (UI state; also sim state when `ui_only = false`); not listed in the browser |
| **Game (sim) mod** | not `ui_only`, not `editor_mod` | only when the map maker loaded it in the **Mods** dialog (plus the mods it `requires`) |
| **UI mod** | `ui_only = true`, not `editor_mod` | never (they hook the same UI classes the editor builds on) |

Every mod folder is still mounted (installed mods from the user's `My Games/.../mods`, editor mods from
`editor/runtime/mods/<name>/`), so loading a mod later needs no new mount, only a new session.

## Map maker: the Mods dialog

Tool panel -> **Mods**: one toggle per game mod, paging with `<` `>`, **Apply & reload**. Mods are applied when a
session starts, so Apply autosaves the map to `mapout/_modreload.v0001` and reopens it (terrain, markers and props
survive; undo history does not). The selection is saved with the map as `<stem>_editor.lua`
(`EditorMods = { uid, ... }`, written by `Map.SaveAs`) and restored when the map is opened; a map without that file
opens with no game mods. The working copy of the selection is `editor_mods.txt` next to the exe.

If a mod breaks blueprint loading or the sim start, the session never comes up. `editor_mods_trial.txt` holds the
previous selection while a load is being tried (cleared by `control.Start()` once a session runs); at the next
launch a leftover trial file restores the previous selection instead of the map's list. Restart the editor to
recover.

## Modder: writing an editor mod

1. Folder with `mod_info.lua`:
   ```lua
   name = "My editor mod"
   uid = "<unique guid>"
   version = 1
   ui_only = true        -- false when it also hooks the sim side (simcallbacks, scenarioutilities)
   editor_mod = true     -- always loaded, hidden from the browser
   ```
   Put it in `editor/runtime/mods/<name>/` (ships with the editor) or in the user's mods folder.
2. Hook any editor Lua file under `hook/` mirroring its VFS path: `hook/lua/editor/ui.lua`, `terrain.lua`,
   `map.lua`, `control.lua`, `mods.lua` ... The usual FAF rules apply (appended as one chunk: wrap in `do ... end`,
   no top-level `local`, keep old functions' arguments and returns). Editor code is plain Lua 5.0 modules, so
   `Tools`, `State`, `Terrain.Brush`, `Map.Doc` etc. can be extended or wrapped.
3. New tool: append to `Tools` with `kind = 'custom'` and `OnPress(wx, wz, event)` (return `false` to let the click
   through). See `editor/runtime/mods/editor_example/` (adds a Crater tool).

World clicks are taken by a wrapper that `ui.lua` installs on the final `WorldView.HandleEvent` after all hooks
ran, so a mod that wraps `WorldView.HandleEvent` cannot bring back the game's selection box in edit mode.
