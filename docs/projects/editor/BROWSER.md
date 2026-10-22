# The categorized browser

Every "choose one of many" in the editor (a unit, a texture, a name from a long list) opens the same window, `gui/browser.lua`, instead of one long scroll list.

| Part | What it does |
|---|---|
| Sidebar | **All / Starred / Recent**, then one section per category with the number of entries behind each value (faction, tech, layer, type for units; kind and the folder tree for textures; prefix and first letter for plain names). One click narrows the list, a second click on the same value lifts it. Counts follow the search and the other filters, so a value that would show nothing is not offered. Sections collapse. A category with one value, and the folders every entry shares, are left out. |
| Search | Words, all of which must occur in the name, id, folder or a category (`cybran t2 air`). **Enter takes the first result**: type, Enter. |
| Results | A list with a picture on every row or a grid of pictures (kept per kind). A click takes the entry. |
| Preview | The large picture under the pointer, name, id, categories, path, and a star (favourites come first; Starred and Recent list what you used). |
| Chips | The active filters as buttons above the results: click one to lift it. |

Where it opens: `Browser.OpenUnits` (platoon unit types, the Units panel's Browse...), `Browser.OpenTextures` (layer textures, every sky / water / cube map picker through `texpicker.lua`), `Browser.OpenNames`
(`PickName` with 24 or more names: markers, chains, groups, wizard lists ...; shorter lists keep the small dialog). `Browser.Open{...}` takes any entries with `tags` and an optional `folder`.

The Units panel has Faction / Tech / Type buttons that open a menu of the values, and the Assets panel's filter buttons do the same (they used to step through the values one by one).

Tests: `selftest_browser.lua` (filters, counts, search, folders, picking); the nightly's `tips` step opens the three browsers; `layout` measures the Units panel.

## Texture pictures: speed and the map folder

**Pictures.** `assetthumbs.lua` keeps a persistent cache in the user data (`assetthumbs/v<Version>/`, a file per (kind, vfs path, time stamp of the source, Version), mounted as `/edassets`), so a texture is reduced once, not once per session. A picture is 96 x 96 (row and grid) or 256 x 256 (kind `texprev`, the large preview: the browser never loads the texture itself any more). The native `ed_dds_thumb(src, dst, size, 1)` starts from the smallest mip level that is still twice the thumbnail wide (a 2048 x 2048 texture is read as 256 x 256: 27 ms -> 0.4 ms of decoding in `EdDdsDecodeTest`; the file read, and for a file inside a .scd the inflate, stay).

Requests come in **waves**: a list calls `NewWave(owner)` before it binds its visible rows, so what scrolled out of view is cancelled in the worker and the rows on screen are made top to bottom (the order they were asked). `Hold` still pauses the worker while the wheel turns. The worker takes 12 ms per tick (30 ms while a browser is open), at least one picture, and tells the open lists at most every 0.2 s while pictures keep coming. `Warm(kind, items)` makes the rest of a texture list in the background (never cancelled, after everything visible), so the second open of a picker, or a scroll, finds everything on disk. Timings: `/perf` shows `thumbs: make textures`; `Thumbs.Stats()` has `avgMs`, `maxMs`, `cancelled`, `warm`.

**This map.** `texmap.lua` lists the `.dds` files of the open map's folder (`/maps/<folder>`, where `ed_vfs_mount` put it: DiskFindFiles on that path enumerates it) and the staged textures of `maptextures.lua` (`/edmaptex/maptex_*.dds`). `OpenTextures` puts them first under the folder `This map` and the value `This map` of the From category; the path a pick returns is the one the game reads. The Layers panel's pickers offer every `.dds` of the map folder that is not a decal (normal map = `normal` in the name); the Assets panel's Textures and Decals kinds list them too (group `This map`). A Rescan button, and a look every 2 s at the file list, bring in files that appear while the browser is open.

Save As: `maptextures.PrepareSave` copies every layer texture that lives in another map folder (or is a staged `maptex_*`) into `<new folder>/env/layers` and points the layer there (an existing file of that name with other contents makes the copy `name_2.dds`). Decal textures are not relocated.

Tests: `selftest_texbrowser.lua` (cache key, waves, warm-up, map folder lookup and listing with a fake VFS, picker entries); `EdDdsDecodeTest` (engine, `scripts/ed_native_tests.py`).

