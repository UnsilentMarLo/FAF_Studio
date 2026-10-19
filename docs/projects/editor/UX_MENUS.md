# FAF Studio: menu structure (proposal and what was built, 2026-10-18)

## What was confusing (observed in the 2026-10-18 build)

- "Import heightmap" and "Export heightmap" sit in **File** and again in **Terrain** (twice in Terrain: the raw file import and the Gaea / World Machine import have the same name).
- **Edit** holds two map checks ("Snap resource markers", "Validate") that are not editing; **View** holds layout commands (reset / save / load) that belong to **Workspace**; the ruler's
  "Clear the measurement" is the first row of **View**.
- **Workspace** items show no key although every workspace is a command; **Window** is a flat list of 30 panels in registration order and does not fit the screen (the last entries are cut off).
- Items are greyed out without saying why (Paste, Delete, Deselect, Recover autosave, Open recent, heightmap import in the read-only Review workspace); Undo / Redo do not say what they undo.
- Key text is missing for Deselect, Select all, the workspaces and the Play test is buried between Map info and the import items.

## Structure

Rules: one place per command; File = the document on disk, Edit = changing the document, View = what is shown, Map = map-wide data and checks, Terrain = height field operations, Workspace = layouts, Window = panels,
Help. A disabled item says why in the place where the key text sits. Titles carry no category prefix. Dots mean a dialog follows.

| Menu | Items |
|---|---|
| **File** | New map... `Ctrl+N` / Open map... `Ctrl+O` / Open recent > / Recover autosave  --  Save map `Ctrl+S` / Save map as... `Ctrl+Shift+S`  --  Import > (Heightmap file..., Heightmap from an external tool..., Masks from an external tool...) / Export > (Heightmap file..., For external tools...)  --  Release map... |
| **Edit** | Undo: <last action> `Ctrl+Z` / Redo: <next action> `Ctrl+Y`  --  Cut `Ctrl+X` / Copy `Ctrl+C` / Paste at the pointer `Ctrl+V` / Duplicate `Ctrl+D` / Delete `Delete`  --  Select all `Ctrl+A` / Deselect `Ctrl+Shift+A` |
| **View** | Build grid `G` / Slope `H`  --  Camera > (Reset view `Home`, Face north `N`, Look straight down `T`, Focus on selection `F`, Go to bookmark >, Save bookmark >)  --  Clear the ruler measurement  --  UI scale: larger / smaller |
| **Map** | Map info...  --  Playable area...  --  Validate resource markers / Snap resource markers to the build grid  --  Mods...  --  Play test `F5` |
| **Terrain** | Generate... / Flatten the map...  --  Live link to Gaea / World Machine... |
| **Workspace** | Terrain `Alt+1` ... Review `Alt+7` (checked: the showing one)  --  Reset layout of this workspace / Save current layout / Load saved layout |
| **Window** | One submenu per area (Terrain, Objects, World, Mission, Mod, Generate, General) listing its panels; a checked panel is open in the showing workspace. Choosing one shows it (tab or new dock). |
| **Help** | Hotkeys... / Command palette... `Ctrl+Shift+P` |

Toolbar (second row): the workspace tabs, the Grid and Slope toggles (same commands as View) and the UI scale; unchanged.

## Right-click menus

- **Viewport (`context.world`)**: header with the position; the object under the pointer (below); Place marker here (types >), Add start position here, Paste here; Focus camera here; Camera > (top down / north / reset).
- **Object (`context.object`, markers and areas, also from the Outliner)**: Select, Focus camera on it, Cut / Copy / Duplicate / Delete, Set army (start positions), Snap to build grid (resource markers), Properties.
- **Selection in a select tool (units, props, decals)**: Focus camera on the selection, Copy, Duplicate, Delete, Deselect; units add Set army > and Move to group >.
- **Lists**: markers list (use for placing, place at the camera), outliner (object menu), layers (unchanged).

Every item runs a command or a function that is covered by a check (`selftest_qa.lua`, "context menu" block) or was exercised with real input.
