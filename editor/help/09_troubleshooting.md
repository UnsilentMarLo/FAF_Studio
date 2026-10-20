# Troubleshooting and what the editor needs
summary: The game data it needs, crash reports, diagnostics for a bug report.
keywords: crash, error, problem, bug, report, diagnostics, log, faf, data, install, forged alliance, missing, black screen, does not start

## What the editor needs

FAF Studio needs an installed copy of Supreme Commander: Forged Alliance and the FAForever client (the FAF data folder, usually C:/ProgramData/FAForever, and the Forged Alliance files it points to). The editor does not contain or redistribute any game data. The editor finds the FAF data folder on its own at startup; the README of the package explains how to use a different folder (FAF_DATA).

## If the editor stops

- The engine writes a crash report (faf_crash_..., a text file and a dump) next to the program. At the next start the editor tells you its path and offers to restore the autosave of your work.
- Help > Save diagnostics for bug report saves the version, paths, settings, the open map, monitors, the tail of the log and the newest crash report into diagnostics.txt in your user folder (and shows where it is). Attach that file to a bug report.

## Common questions

- The editor says the FAF data is missing: install the FAForever client and start it once, or set the environment variable FAF_DATA to the folder that contains gamedata.
- A map does not open: the editor refuses maps whose .scmap file is missing and shows a message. Maps from mods need those mods in the Mods panel.
- The window is too big or too small: change the UI size with the + and - buttons at the top right.
- The layout is messed up: Workspace > Reset layout of this workspace.
