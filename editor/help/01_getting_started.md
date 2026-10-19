# Getting started
summary: The window, the workspaces, the camera, undo, saving: the first ten minutes.
keywords: start, begin, first, window, layout, workspace, panel, tab, camera, tour, basics, overview

FAF Studio edits Supreme Commander maps, missions and mod units in the same window you play in. The map is shown live in the Viewport; everything around it is a panel.

## The window

- The menu bar and the workspace buttons are at the top, the status line at the bottom shows the pointer position and the last message.
- A **workspace** is a set of panels and tools for one job: Terrain (height and texture brushes), Objects (markers, start positions, props, decals, units), Environment (sun, fog, water), Generate (terrain from rules and graphs), Mission (armies, stages, objectives), Mod (units and their blueprints) and Review (look, validate, release). Switch with the buttons or Alt+1 to Alt+7.
- **Panels** sit in tab stacks. Click a tab to bring a panel forward, drag a tab to another place, or drag it out of the window to get a window of its own (closing that window docks the panel back). The editor remembers your layout, UI size, tools and brush settings between runs.
- The + and - buttons at the top right change the UI size. A panel whose content does not fit scrolls with the mouse wheel.

## Camera

- Mouse wheel: zoom. Middle button drag: pan. Right button drag, or Alt + left button drag: rotate. Ctrl + middle button drag: zoom.
- Keys: W A S D or the arrow keys move, Q and E turn, PageUp and PageDown tilt, Z and X zoom, Home resets the view, N faces north, T looks straight down, F focuses the selection.
- Ctrl+1 to Ctrl+9 jump to a camera bookmark; Ctrl+Shift+1 to Ctrl+Shift+9 save one.
- Every key and mouse gesture can be changed in the Hotkeys panel (Help > Hotkeys).

## Working

1. Pick a tool in the Tools panel (or press 1 to 8 for the tools of the workspace) and drag in the Viewport. A brush stroke is one undo step.
2. Ctrl+Z undoes, Ctrl+Y or Ctrl+Shift+Z redoes.
3. Ctrl+S saves. The first save asks where; the map is written to a folder named after the map with the version suffix .v0001, which is what the game expects.
4. F5 starts a test run of the map in the game; Stop brings you back to exactly where you were.

## When you are lost

- F1 opens this help; type in the search field to find a topic.
- Ctrl+Shift+P opens the command palette: type a few letters of anything the editor can do.
- Hover a tool or a panel tab for a short description.
- File > Start screen shows the start page again; Help > Take the tour repeats the first-run tour.
