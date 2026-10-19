# FAF Studio identity: process name, title bar, icon

| Where | What it shows | How |
|---|---|---|
| Process name (Task Manager, `tasklist`) | `FAFStudio.exe` | `scripts/brand_exe.py` copies the built exe to `engine_decomp/run_x64/bin/FAFStudio.exe` (the original `main_x64_la_p2.exe` is untouched). `C:/tmp/build_deploy.ps1` runs it after every build. A running instance locks the file: the script then leaves it and says so. |
| Task Manager group name, file properties | "FAF Studio" | the same script replaces the version resource (FileDescription / ProductName / OriginalFilename) in the copy |
| Explorer / pinned taskbar icon | the editor icon | the same script replaces the icon group of the copy (the FA icon is a *named* resource: both named and numbered groups are replaced) |
| Window icon (title bar, taskbar, Alt+Tab, pop-outs) | the editor icon | native `ed_app_set_icon(path)` (`EdWindow.cpp`, WM_SETICON + class icon), called by `gui/feature_branding.lua` with `branding/fafstudio.ico` |
| Title bar text | `FAF Studio  -  <map name>  *  [<workspace>]` (`*` = unsaved changes) | native `ed_app_set_title(text)`, refreshed by the feature module's `Refresh()` (ticked by the shell, only when the text changed) |

The icon (`editor/runtime/branding/fafstudio.ico`, 16 - 256 px, PNG compressed, preview `fafstudio_256.png`) is drawn by `python scripts/make_editor_icon.py` without any imaging library:
a dark rounded tile in the editor's skin colours with layered terrain ridges in the editor cyan, topographic contour lines and an orange start-position marker. Change the palette or shapes in that script and re-run it.

Notes: the natives are named `ed_app_*` because `ed_window_*` is the pop-out window API (`EdPopout.cpp`, including `ed_window_set_title(id, title)`); an exe without them keeps the engine's
"Forged Alliance" title and icon (the Lua side checks). The engine sources live outside the repository (`engine_decomp/`): `EdWindow.cpp` is registered in `main_ed.vcxproj`.
Run the branded build in a test instance with `python scripts/editor_inst.py start <tag> --exe FAFStudio.exe`.
