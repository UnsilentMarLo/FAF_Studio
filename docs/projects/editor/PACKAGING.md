# FAF Studio: packaging, user data, help, crash handling

Branch `ed/package` (2026-10-19). Goal: the editor can be given to somebody else who has Forged Alliance and the FAForever client, and a first-time user finds their way. Five parts: the start screen, per-user
persistence, in-app help, the package, crash handling. Verified in the engine with real input (instance `package`) and by `python scripts/package_editor.py --test` (a clean copy with a space in its path).

## 1. The package

`python scripts/package_editor.py [--out dist] [--version X.Y.Z] [--no-zip] [--test]` writes `dist/FAFStudio/` and `dist/FAFStudio-<version>.zip` (`dist/` is git-ignored: **never commit or upload the exe**; handing
out the build is the owner's decision, see "What may be shipped"). The version number is `editor/VERSION`; the build date, git revision (`+changes` when the tree is dirty) are stamped into the packaged
`lua/editor/version.lua` and shown on the start screen and in the diagnostics.

```
FAFStudio/
  README.txt  CHANGELOG.txt (from git)  VERSION.txt  MANIFEST.txt (sha256 of every file)
  bin/                     FAFStudio.exe + the DLLs it imports (ffmpeg libraries, edtext.dll) + init_editor.lua
  editor/                  the Lua tree (lua/ schook/ mods/ override/ brushes/ branding/ maps/ = blank templates), help/ is in docs/help
  docs/                    help topics as text (docs/help), PACKAGING.md        tools/pack_map.py        samples/
  mapout/ modproj/         empty; the editor writes autosave, test runs and mod projects here (a sample map is put into mapout/)
```

The DLL list is not hand maintained: the script reads the import table of the exe (`pe_imports`) and copies the DLLs of `engine_decomp/run_x64/bin` that it needs, recursively. Self tests (`selftest_*.lua`) and
their data stay out. The script refuses to finish when `init_faf.lua`, `SupComDataPath.lua`, `fa_path.lua` or a game data folder ended up inside, when the help data is stale (`gen_help.py --check`) or when a file
the exe needs is missing.

Generated content that git ignores (`editor/runtime/maps`, `brushes`, `override/textures`) is taken from the main checkout when a worktree does not have it, like `editor_inst start` does.

### What the package needs and how it finds the game (the FAF data dependency)

The engine is the Forged Alliance executable the editor was built from. At start it runs `init_faf.lua` (FAF's file), which reads `../fa_path.lua` (written by the FAForever client: `fa_path` = the Forged
Alliance install, `custom_vault_path` = the user's `My Games\...\Supreme Commander Forged Alliance` folder with their maps and mods, `GameVersion`, ...) and mounts: from the Forged Alliance install the
`gamedata/*.scd`, `movies`, `sounds`, `maps`, `fonts`; from `../gamedata/*.nx2` (the folder one level above `bin`) FAF's patch files; the user's vault. `cache`, `movies`, `sounds` and `themes` next to `gamedata`
are FAF's own folder layout, which the engine expects as well. The editor adds its own tree (`init_editor.lua`: `../editor`, `../mapout/*`, `../modproj/*`). Nothing of the game data is in the package. There is **no launcher script**: `bin\FAFStudio.exe` is double-clicked, and the exe sets itself up before the engine starts
(`moho/editor/EdBootstrap.cpp`, called first in `WinMain`; engine patch 0034; the module and its test are described in the header of `EdBootstrap.h`):

0. the process becomes DPI aware (see DPI.md) and its working folder becomes `bin\` (Lua reads and writes `editor_boot.txt`, `editor_mods.txt` ... relative to it), whatever started it;

1. looks for the FAF data folder: `%FAF_DATA%`, else `%ProgramData%\FAForever` (where the FAForever client puts it); it must hold `gamedata`, `fa_path.lua`, `bin\init_faf.lua`, `bin\SupComDataPath.lua`.
   When it does not (and no earlier start left a complete set-up in the package), a message box says what is missing and how to set `FAF_DATA`; the process ends with exit code 2 and nothing starts.
2. copies `init_faf.lua` and `SupComDataPath.lua` into `bin\` and `fa_path.lua` into the package root when they are missing or older (FAF updates them; they are FAF's files and are not redistributed);
3. links `cache`, `gamedata`, `movies`, `sounds`, `themes` of the FAF folder into the package root as folder junctions (no copy, no administrator rights; a junction that points elsewhere is replaced;
   a real folder of that name is left alone; where junctions are impossible (a drive that is not NTFS) a directory symbolic link is tried; when `gamedata` still is not there, a message says so, exit code 3);
4. creates `mapout`, `modproj`, `bin\config`, the (empty) `editor_mods*.txt`, rotates the log (`editor.log` -> `editor.previous.log` in the user folder);
5. completes the arguments: `/init init_editor.lua /editor /nomovie /nosound /windowed <w> <h> /log <user>\logs\editor.log /eduser <user>`, each only when you did not give it (a window of 90 % of the work area in real
   pixels, at most 1920 x 1080), and sets `FAFSTUDIO_UISCALE` (the display scale) for the first-run UI scale. A start that has `/init` is left alone (scripts, tests): only the DPI awareness applies. Paths with a space
   work (the test uses a folder with a space in its name); a user name with letters outside the ANSI code page falls back to the 8.3 path;
6. then the engine starts as before.

`bin\FAFStudio.exe /map <name>` opens a map (no start screen). `FAFSTUDIO_NOGUI=1` (the package test) writes the message of a start that cannot go on to `<user>\logs\boot_message.txt` instead of opening a
message box. An exe that has no `init_editor.lua` next to it and no `/editor` argument (the plain game executable) is not touched. There is no message after a crash any more (nothing waits for the process):
see 5.

### What may be shipped

- Game data: **no**. The exe links the user's own FAForever folders; `init_faf.lua`, `SupComDataPath.lua` and `fa_path.lua` are copied from the user's install, not from us.
- Run time requirements outside the package: Windows 10 / 11 64 bit, the Microsoft DirectX End-User Runtime libraries the exe imports (`d3dx9_43`, `d3dx10`, `x3daudio1_7`; Forged Alliance installs them), the
  Visual C++ runtime (`vcruntime140`, `msvcp140`, installed by the FAForever client).
- `bin\*.dll`: the ffmpeg libraries (`avcodec-61` ...) are LGPL / GPL builds: when the package is given away, their license texts and source offer have to travel with it (not added yet, listed under open items).
- `FAFStudio.exe` is built from the engine reconstruction in `engine_decomp/`; whether and where to distribute it is a decision for the owner, which is why the script writes only to the ignored `dist/`.

## 2. User data (`userdata.lua`, `persist.lua`)

One folder per user: the command line argument `/eduser <dir>` (the exe adds `%APPDATA%\FAFStudio`, or `%FAFSTUDIO_USER%`, when it is started without arguments). Without it (development instances, tests) the folder is `userdata` next to the exe, so
every test instance keeps its own and never touches a real user's settings; `editor_inst start` clears it unless `--keep-userdata` is given.

| File | Content | Written |
|---|---|---|
| `settings.lua` | `format`, `uiScale`, `workspace`, `tools` (tool per workspace), `brush` (radius, strength, falloff, sign), `grid`, `slope`, `startScreen`, `tourDone` / `tourPending`, `crashSeen`, `autosave`, `after` | `Set` + `Flush` (the shell ticks `Flush` about 4 times a second) |
| `layouts/<Workspace>.lua` | the dock tree of the workspace, split ratios, tab order, the pop-out windows with position and size | when a panel is moved or resized, a window opened / closed / moved (`LayoutChanged`) |
| `saved/<Workspace>.lua` | the layout the user saved on purpose (Workspace > Save current layout) | on that command |
| `hotkeys.lua` | the changed key bindings and camera gestures | on every binding change |
| `recent.txt` | the recent maps (12) | on open / save |
| `thumbs/*.dds` | the start screen thumbnails cut from the `.scmap` previews | on demand |
| `crash.lua`, `diagnostics.txt` | the last diagnostics (Help > Copy diagnostics) | on that command |

- **Versioned**: every table file starts with `format = N` (`UserData.FORMAT`). `UserData.Upgrade` is where a later version turns an older table into the current one; a file with a *newer* format is read as far as it fits and
  never overwritten.
- A file that cannot be read is kept as `<file>.bad` and the editor starts from the defaults (selftest). Layouts are sanitised on load: panels the editor does not have are dropped, empty stacks collapse, a pop-out
  that lies on no monitor is moved onto the main monitor (`ed_monitor_*`), a split ratio out of range is reset.
- **Reset**: Help > Reset user settings... empties every known file (Lua has no delete; an empty file counts as missing) and says to restart. Workspace > Reset layout of this workspace forgets one layout. Help > Where are my
  settings? shows the folder.
- Older state next to the exe (`config/editor_hotkeys.lua`, `editor_recent.txt`, `workspaces/*.lua`) is read when the user folder has none, so nobody loses bindings or recents on the first start of this version.
- A new session (opening a map restarts the engine session) restores the last workspace, its kept layout, UI scale, tool and brush: before this the layout was lost on every map open.

## 3. Start screen (`gui/startscreen.lua`, `gui/feature_start.lua`)

When the program is started **without `/map`**: `init_editor.lua` writes `editor_boot.txt` = `0` at process start; the `uimain.lua` hook (the front end the engine asks for when there is no map) opens the blank map, and the first
editor session of the process shows the start screen over the shell; afterwards `editor_boot.txt` is `1`, so the sessions that opening a map starts do not show it again. With `/map` nothing changes (tests, command line use).
The setting `startScreen` ("Show this screen at start") turns it off; File > Start screen shows it any time.

Content: New map (the three sizes of `Maps.Sizes`), recent maps as cards with the preview picture of the `.scmap` (`thumbs.lua` cuts the blob after the 30 byte header out of the file, caches it in `thumbs/` under a name
with the file's size and time, mounts the folder as `/edthumbs`; one map per frame so a big map does not freeze the page), Open map..., Open from my maps folder (`Maps.ListUser`), Release a map... (opens the map, then runs
`file.release` in the next session: the `after` setting), Mod project... (open or create, then the Mod workspace), Recover the autosave, Take the tour, Help, a tip (`tips.lua`), Show at start.

## 4. Help (`help.lua`, `helpdata.lua`, `gui/panels_help.lua`, `gui/tooltip.lua`, `gui/tour.lua`)

- **F1** (`help.open`) opens the Help panel in a window of its own the first time (or shows it where it is docked). A search field lists the topics (every word must occur in the title, keywords, summary or text; titles
  count most), a click opens a topic, Back returns. The panel scrolls with the wheel.
- **Topics are documents**: `editor/help/NN_name.md` (title, `summary:`, `keywords:`, `##` headings, paragraphs, `-` bullets, `1.` steps; ASCII only). `python scripts/gen_help.py` writes `helpdata.lua`; `--check` is used
  by the package script. Topics: Getting started, Terrain from nothing, Import from Gaea / World Machine, Markers units props and decals, Mission basics, Mods and the unit lab, Saving autosave releasing, Layouts hotkeys
  and settings, Troubleshooting.
- **Two topics are generated from the running editor** so they cannot go out of date: *Keyboard and mouse shortcuts* (the command registry with the keys in use now, the camera gestures) and *Tools, panels and
  workspaces* (the tool table, the panel registry, `tooltips.lua`).
- **Tooltips**: `W.Button(..., { tip = text | function })`, the panel tabs and the workspace buttons show a framed text after 0.55 s of rest (`gui/tooltip.lua`). The texts are in `tooltips.lua` (tools, panels,
  workspaces); a tool or panel without an entry just has no tooltip. `selftest_package` lists the gaps (it does not fail on them: branches add tools without waiting for this file).
- **Tour**: 8 steps (`gui/tour.lua`): a dimmed screen, the part of the window that the step talks about lit up (its rectangle comes from the dock, so it follows the user's own layout; a step whose panel is not there is
  skipped), Back / Next / Skip. It starts once after the first start screen (setting `tourPending`, cleared by `tourDone`) and from Help > Take the tour.
- Adding to the help: write or edit a `.md` topic and run `gen_help.py`; add a tooltip line for a new tool or panel; add a tip to `tips.lua`.

## 5. Crash handling (`crash.lua`, `gui/feature_crash.lua`)

- The engine writes `faf_crash_<date>_<time>.txt` / `.dmp` into `bin` when it dies. Nothing else runs at that moment (there is no launcher waiting for the process any more, and the engine's own crash handler
  cannot show Lua text), so the editor says it at the **next start**:
- the first session of the process shows "The editor stopped unexpectedly" for crash reports this user folder has not seen (the first start with a new user folder treats what is on disk as history):
  the report path, Copy the report path, Copy diagnostics, Continue.
- **Autosave recovery**: `Maps.AutosaveTick` (every 5 minutes when the map changed) records `autosave = { map }` in the user settings; saving (`MarkClean`), Discard in the unsaved changes dialog and Recover clear it.
  When it is still set at the next start, a dialog offers Restore it / Ask me later / Discard it (this covers a crash, a closed window and a killed process alike). File > Recover autosave stays.
- **Help > Copy diagnostics** (`help.diagnostics`): version, installation and user folder, UI scale, workspace, pop-outs, the open map (type, unsaved), active mods, monitors, the pending autosave, `settings.lua`,
  the head of the newest crash report and the tail (120 lines) of the log. On the clipboard (`CopyToClipboard`) and in `diagnostics.txt` of the user folder.

## 6. Tests

- `selftest_package.lua` (registered in `selftests.extra`): user data round trip, bad and newer files, reset, layout sanitising, help search and generated topics, tooltip coverage report, thumbnail parser, crash
  report detection, tour steps, start screen build. Run with `python scripts/editor_inst.py selftests <tag>`; `python scripts/editor_merge.py try package --test`.
- `python scripts/package_editor.py --test`: the clean folder test described in the script header (start screen with no map, version stamp, user folder, installation folder, links, log, text backend drawing, sample map listed, `/map` start, settings written, the exe's message for a missing FAF install (exit code 2, `boot_message.txt`), started from another working folder like a double click, screenshot `dist/package_test_start.png`). Last result 2026-10-19: PASS, 6 DLLs, 150 MB unpacked, 50 MB zip.
- Real input (instance `package`): start screen with 5 recent maps and thumbnails, a click on a card opened the map, layout / UI scale / brush restored after a restart, tooltips with a real hover (the pointer has to be
  moved for real: posted mouse messages do not drive Maui's hover), the tour clicked through, the help window.

## Open items

- ffmpeg license texts for the DLLs in `bin` (see "What may be shipped"); an installer (`.msi` / Inno Setup) instead of a zip; code signing (SmartScreen will warn about an unsigned exe).
- The crash notice at the next start cannot say *what* crashed; the dump files are for the developers.
- The main window's size and position are chosen at start (90 % of the work area), not remembered.
- Help topics are English only, ASCII only (the in-game font set).
