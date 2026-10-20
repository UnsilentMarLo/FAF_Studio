FAF Studio @VERSION@
=====================

A map, mission and unit editor for Supreme Commander: Forged Alliance (FAForever).
Built @BUILD@ from revision @REVISION@.


WHAT YOU NEED
-------------
* Windows 10 or 11, 64 bit, a graphics card that runs Forged Alliance.
* Supreme Commander: Forged Alliance with the FAForever client, installed and started
  at least once (the client downloads the game data the editor reads).
* The libraries Forged Alliance itself needs: the Microsoft DirectX End-User Runtime and the
  Visual C++ 2015-2022 runtime (the FAForever client installs both).

FAF Studio does not contain game data. It reads the FAForever data folder
(normally C:\ProgramData\FAForever) and the Forged Alliance files that folder points to
(fa_path.lua), exactly as the game does. Nothing in them is changed or copied.


START
-----
1. Unzip the folder anywhere you can write to (not into C:\Program Files).
2. Double-click bin\FAFStudio.exe. (Right-click it > Send to > Desktop for a shortcut.)

The program sets itself up: there is no launcher script. The first start links the FAF data into
this folder (folder junctions, no copying, no administrator rights) and shows the start screen: new map, open, recent maps, release,
mod project, tips. Press F1 in the editor for help, or choose Help > Take the tour.

If your FAForever data is somewhere else, set the environment variable FAF_DATA to the folder
that contains "gamedata" before you start:

    set FAF_DATA=D:\Games\FAForever
    bin\FAFStudio.exe

Open a map directly:  bin\FAFStudio.exe /map <map folder name or scenario path>


WHERE THINGS ARE
----------------
  bin\          the program (FAFStudio.exe and its libraries)
  editor\       the editor's own files (Lua code, help, brushes, icons, blank maps)
  mapout\       maps the editor saved without a file dialog (autosave, test runs)
  modproj\      your mod projects
  docs\         the help topics as text, PACKAGING.md (how this package is made and how it finds the game)
  tools\        pack_map.py: zips a released map folder for the map vault (needs Python 3)
  samples\      a sample map and the sample graphs

Your settings (layouts, UI size, hotkeys, recent maps), the log and the thumbnails of the start
screen are in %APPDATA%\FAFStudio (override with the environment variable FAFSTUDIO_USER).
Help > Where are my settings? shows the folder; Help > Reset user settings starts over.

Maps you save with File > Save go to the maps folder you choose in the dialog; the game finds them
in Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\Maps.


IF SOMETHING GOES WRONG
-----------------------
* The editor tells you when it ended with an error and where the crash report is
  (bin\faf_crash_<date>_<time>.txt). At the next start it offers to restore your autosave.
* Help > Save diagnostics for a bug report writes the version, settings, log tail and newest
  crash report into %APPDATA%\FAFStudio\diagnostics.txt. Attach the file to a bug report.
* "needs Supreme Commander" message at the start: see WHAT YOU NEED; check FAF_DATA.
* Logs: %APPDATA%\FAFStudio\logs\editor.log (previous run: editor.previous.log).

CHANGELOG.txt lists the changes of this build.
