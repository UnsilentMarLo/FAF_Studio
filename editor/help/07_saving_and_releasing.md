# Saving, autosave, releasing
summary: Where maps are written, how autosave and recovery work, and how a release differs from a save.
keywords: save, save as, autosave, recover, recovery, backup, release, version, folder, vault, pack, zip, recent, open

## Saving

- Ctrl+S saves the map to its current location; a new map asks where to save first (Save map as...). The map is written as a folder named after the map plus a version suffix, for example my_map.v0001, containing the .scmap and the scenario, save and script files.
- Before an existing map is overwritten for the first time in a session, its old files are copied to editor_backups next to the maps folder. Nothing is overwritten without a copy.
- Opening or creating a map while there are unsaved changes asks whether to Save, Discard or Cancel.

## Autosave and recovery

- While you work, the editor saves a copy every few minutes (only when something changed) to a separate autosave folder.
- If the editor is closed or stops with unsaved changes, the next start offers to restore the autosave. File > Recover autosaved map opens it at any time.

## Recent maps and opening

- File > Open recent lists the last maps; the start screen shows them with a picture.
- File > Open map... lists every map the game knows. "Open from my maps folder" on the start screen lists only the maps in your own maps folder.

## Reviewing a map

The Review workspace (Alt+7) is read-only: nothing you do there changes the map. It has the viewport and one set of tabs with what a review needs:

- View: build grid, slope view, marker layers and the other overlays.
- Validation, Statistics and Terrain checks: the problems and the numbers of the map. The buttons that would fix something are dimmed here; fix in Objects or Terrain.
- Images: every image of the map (height map, the eight layer masks, terrain types, water masks, preview image, layer textures) with a small preview. Export... writes one as a 16-bit PNG, Export all... writes all of them into a folder as name_item.png. Import... is for the Terrain workspace; it is disabled in Review.
- Outliner, Console and Tools (Select, Ruler, Camera, Save, Play test).

If your Review workspace still shows the old tabs, Workspace > Reset layout of this workspace restores the current arrangement (an older kept layout is dropped once by itself).

## Release

File > Release map... checks the map and writes the next free version folder (my_map.v0002) beside the working map; the working map stays open and unchanged. Errors (for example fewer than two start positions or a script that does not compile) block the release, warnings do not.

To publish, zip the released folder with its folder name as the root (tools/pack_map.py in the editor folder can do this) and upload it to the map vault.
