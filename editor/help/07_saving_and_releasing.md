# Saving, autosave, releasing
summary: Where maps are written, how autosave and recovery work, and how a release differs from a save.
keywords: save, save as, autosave, recover, recovery, backup, release, version, folder, vault, pack, zip, recent, open

## Saving

- Ctrl+S saves to where the map came from; a new map asks first (Save map as...). The map is written as a folder named after the map plus a version suffix, for example my_map.v0001, containing the .scmap and the scenario, save and script files.
- Before an existing map is overwritten for the first time in a session, its old files are copied to editor_backups next to the maps folder. Nothing is overwritten without a copy.
- Opening or creating a map while there are unsaved changes asks: Save, Discard or Cancel.

## Autosave and recovery

- While you work, the editor saves a copy every few minutes (only when something changed) to a separate autosave folder.
- If the editor is closed or stops with unsaved changes, the next start offers to restore the autosave. File > Recover autosave opens it at any time.

## Recent maps and opening

- File > Open recent lists the last maps; the start screen shows them with a picture.
- File > Open map... lists every map the game knows. "Open from my maps folder" on the start screen lists only the maps in your own maps folder.

## Release

File > Release map... checks the map and writes the next free version folder (my_map.v0002) beside the working map; the working map stays open and unchanged. Errors (for example fewer than two start positions or a script that does not compile) block the release, warnings do not.

To publish, zip the released folder with its folder name as the root (tools/pack_map.py in the editor folder does that) and upload it to the map vault.
