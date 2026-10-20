# Layouts, hotkeys and your settings
summary: What the editor remembers, where it keeps it and how to start over.
keywords: layout, settings, user folder, reset, hotkeys, shortcuts, rebind, window, monitor, second screen, pop-out, ui scale, workspace

## What is remembered

Everything below is kept per user between runs: the arrangement of the panels of each workspace (sizes, tabs, pop-out windows and where they were), the UI size, the workspace you were in, the tool of each workspace, the brush radius, strength and falloff, the grid and slope views, your hotkeys and the recent maps.

## Windows and monitors

Drag a panel tab out of the window to open it in its own window; move it to another monitor if you like. The editor restores it there at the next start. If that monitor is no longer connected, the window opens on the main monitor.

## Hotkeys

Help > Hotkeys opens the Hotkeys panel: every command has two key slots, and the camera gestures can be changed too. Assigning a key that is already in use moves it to the new command.

## Layout commands

- Workspace > Reset layout of this workspace: restores the default arrangement.
- Workspace > Save current layout / Load saved layout: your own named snapshot per workspace.

## Where is it, and starting over

- Help > Open settings folder shows where your settings are kept.
- Help > Reset user settings... clears layouts, UI size, hotkeys, recent maps and tool settings (not your maps or mod projects); restart the editor afterwards.
- A settings file that cannot be read is kept in the same folder with .bad appended, and the editor starts with the defaults.
