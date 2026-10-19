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
