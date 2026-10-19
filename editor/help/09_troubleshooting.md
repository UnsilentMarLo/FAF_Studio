# Troubleshooting and what the editor needs
summary: The game data it needs, crash reports, diagnostics for a bug report.
keywords: crash, error, problem, bug, report, diagnostics, log, faf, data, install, forged alliance, missing, black screen, does not start

## What the editor needs

FAF Studio uses the data of an installed Supreme Commander: Forged Alliance with the FAForever client (the FAF data folder, usually C:/ProgramData/FAForever, and the Forged Alliance files it points to). The editor does not contain or redistribute any game data. The launcher looks for the FAF data folder; the README of the package explains how to point it at another place.

## If the editor stops

- The engine writes a crash report (faf_crash_..., a text file and a dump) next to the program. At the next start the editor tells you its path and offers to restore the autosave of your work.
- Help > Save diagnostics for a bug report writes the version, paths, settings, the open map, monitors, the tail of the log and the newest crash report into diagnostics.txt in your user folder (and shows where it is). Attach that file to a bug report.

## Common questions

- The editor starts but shows only a menu of the game: it was started without the editor arguments; use the FAFStudio launcher.
- A map does not open: maps whose .scmap file is missing are refused with a message. Maps from mods need those mods in the Mods panel.
- The window is too big or too small: change the UI size with the + and - buttons at the top right.
- Layout in a mess: Workspace > Reset layout of this workspace.
