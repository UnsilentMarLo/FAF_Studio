# FAF Studio: project history, release, validators, loading (design v0.1, 2026-10-17)

Part of [MAP_EDITOR_DESIGN.md](MAP_EDITOR_DESIGN.md). Written from the user's requests of 2026-10-17: no data loss
from crashes or mistakes, a git-like save history with a "release" into the game's maps folder, open existing maps,
validators, no loading screens. Evidence tags: **[verified]** (read in the tree), **[inferred]**, **[open]**.

## 1. Principles

1. **The editor never edits a game map folder in place.** Work happens in a project workspace. The game's maps
   folder only ever receives *releases*.
2. **Nothing is lost between two saves either.** A write-ahead command journal covers the time since the last save.
3. **Saving is cheap, so users do it constantly.** A save is a commit of changed chunks, not a full rewrite.
4. **Every state a user ever saved is restorable**, with a diff view to see what a restore changes.
5. **A release is a validated, immutable, game-ready map version.**

## 2. Layout on disk

```
<EditorData>/projects/<project>/            (default: Documents/SCEditor/projects; configurable)
  project.json            id, display name, source (new / imported-from path), current branch, settings
  work/                   live working copy in editor-native chunked form (see 3)
  history/
    objects/ab/cdef...    content-addressed chunks (zstd, SHA-256 name)
    commits/<n>.json      commit manifest: parent, time, label, author, stats, chunk list, validator summary
    refs/                 branches (variants) and tags (releases)
  journal/                write-ahead command log since the last commit, one file per session
  releases/               optional local copies of released folders and packages
  thumbnails/             per commit preview images
```

Game maps folder (target of a release) **[inferred from the install]**:
`Documents/My Games/Gas Powered Games/Supreme Commander Forged Alliance/Maps/` holds folders named `<name>.vNNNN`
(`Azalea_Gardens.v0004`, `Black_Sun`, ...). FAF's convention is the `.vNNNN` folder suffix and a version field in
`_scenario.lua`. A release writes the next free `<name>.vNNNN`, so earlier releases stay intact and the game
and the lobby treat each as a separate version.

## 3. Chunked storage (why saves are fast and diffs are possible)

The working copy and history split a map into addressable chunks. Unchanged chunks are never rewritten:

| Chunk | Granularity | Notes |
|---|---|---|
| Heightmap | tiles of 64 x 64 samples | 20 km map = 16 x 16 tiles of 64 plus edge; dirty tiles come from the command stack's dirty rectangles |
| Stratum masks | per layer, per tile | 10 layers, same tiling |
| Terrain type | per tile | |
| Water, lighting, fog, shader, global scmap fields | one chunk each | small |
| Props, decals | sorted lists, chunked by region | stable ids so diffs show moved / added / removed |
| Markers, areas, armies, groups | one JSON-like chunk per kind | |
| Scenario text files (`_scenario`, `_save`, `_script`) | whole text | script text diffed line-wise |
| Mission graph (node editor model) | one chunk per stage | |
| Imported assets (textures, meshes) | content-addressed blobs | deduplicated across commits |

Why not literal git: heightmaps and masks are large binaries, git stores them whole per change, needs LFS or
bloats, and gives no semantic diff. A git-**like** object model (content-addressed chunks, commits with parents,
refs) gives the same guarantees with tile-level deltas. The text parts (`_save.lua`, `_script.lua`, node graph
JSON) may additionally be mirrored into a real git repository on request **[open]** for users who want GitHub
workflows; that is an export option, not the core store.

## 4. Operations

| Operation | What it does | UI |
|---|---|---|
| **Autosave journal** | Every executed command is appended to the journal (fsync batched at ~1 s). After a crash or power loss the editor offers "recover unsaved work" and replays the journal over the last commit. | silent; recovery dialog on start |
| **Save** (Ctrl+S) | Commit: writes changed chunks, a manifest, a thumbnail; clears the journal. Optional label. Milliseconds for small edits. | toast "Saved #42" with Undo-save |
| **Save As / Duplicate project** | New project with the history copied by reference (chunks are shared, near zero cost). | |
| **History panel** | Timeline of commits with thumbnail, label, time, stats (tiles / objects changed), validator summary. Search, filter, pin, rename. | dock panel |
| **Compare** | Select two commits (or commit vs working copy): terrain diff heat-map overlaid on the world, lists of added / moved / removed objects and markers, script diff. | overlay + panel |
| **Restore** | Make a commit the working state. Never destructive: it creates a new commit on top ("restore of #17"); the abandoned state stays reachable. Partial restore: just terrain, just objects, just script, or a selected region (rectangle). | context menu in History |
| **Branch (variant)** | Cheap fork of the history for experiments ("v2 more mass", "naval version"). Merge of non-overlapping chunk sets; conflicts resolved by choosing a side per chunk or region. | branch switcher in the History panel and status bar (decided: part of the editor) |
| **Release** | Validate; refuse on errors (warnings listed, can be acknowledged); write the next `<name>.vNNNN` folder into the game's maps folder; render preview and minimap; bump `map_version` in the scenario; tag the commit; optionally build a zip for upload. | one dialog: version note, validator summary, destination |
| **Open from maps folder** | Browse installed maps (user maps folder, FAF map vault folder, and the game's `maps.scd` content for campaign maps, read-only). Opening **imports** into a new project (first commit "imported from <path>") and never touches the source. | start screen + File > Open |
| **Re-import release** | Pick up changes made outside the editor (a text edit of `_script.lua`, a map regenerated by a tool) as a new commit. | |

The engine's own `.scmap` writer **[verified]** and `luaser.lua` **[verified]** produce the files for a release, so a
release is byte-for-byte what the game loads. The chunked working copy is the editor's format only.

### Crash safety rules

- Journal and commits are written to a temp name and renamed; manifests are written last, so a half written commit is
  never visible.
- The editor process runs the map in a worker that can be restarted; if the render or sim side crashes, the UI shell
  and journal survive and restore the document (see MAP_EDITOR_DESIGN rule 1).
- Disk full or write error: save fails loudly and keeps the journal; never truncates the last good commit.
- Retention: last N commits kept in full, older ones thinned (keep every labelled / released commit); chunk garbage
  collection on a background thread.

## 5. Opening maps and the start screen (no loading screen)

Start screen: recent projects (thumbnail, last saved), "Open map from maps folder" with search, filters (size, player
count, source: user / vault / campaign / coop / mesh) and a preview image from the map's own preview. Opening a map
shows the terrain **progressively**, see section 7.

## 6. Validators

**Goal: the user always sees what is wrong, where, and how to fix it, before the game does.** Three tiers, all
sharing one rule registry:

| Tier | When | Cost |
|---|---|---|
| Live | After each command, only for the dirty region / changed object | microseconds to ms; shown as in-world markers and status-bar counts |
| Panel (full scan) | On demand and on Save, background thread | seconds on a 20 km map |
| Release gate | On Release | full scan plus a **smoke load** (below) |

Each finding has: severity (**error** blocks release, **warning**, **info**), rule id, message, world position or
object reference (click to focus the camera and select), and a **quick fix** where one exists (clamp into playable
area, snap to ground, remove duplicate, rename, add missing field). Users can suppress a warning per project with a
note; suppressions are versioned.

### Rule catalogue (initial; each is a small registered function so mods can add rules)

**Format and files**
- `.scmap` header and version; map size is a valid size; every chunk length matches; texture paths in strata and
  decals resolve in the VFS; preview image present and sized; DDS format and mip checks for custom textures.
- `_scenario.lua`: required fields (`name`, `description`, `type`, `size`, `map`, `save`, `script`, `Configurations`
  with `standard.teams` / `customprops`), file names match the folder stem, `map_version` present, sizes agree with
  the `.scmap`, ARMY names consistent between scenario, save and markers.
- `_save.lua`: schema, unique names, valid vectors, no NaN or inf, every referenced blueprint exists (including
  mods the map declares), marker types and required fields (resource markers carry `resource = true`, `size`,
  `type`), chain members exist, area rectangles ordered.
- Lua syntax and hook-style lint with the workspace validators (`scripts/validate_lua_syntax.py`) on `_script.lua`
  and generated script **[verified: exists in CLAUDE.md section 5]**.
- Size budget: total folder size, texture sizes, decal count, prop count (soft limits with explanation).

**Map layout**
- Playable area inside the map bounds; start positions (`ARMY_n`) inside the playable area, on buildable ground, not
  too close to the edge; count equals the declared players.
- Objects **off map**: units, props, markers, decals, areas outside the playable area (error) or the map (error).
- Ground: resources on water, deep water, steep slope or cliff (cannot be built on); start positions on unbuildable
  ground; props / units floating or buried (height mismatch against the terrain); units on impassable ground.
- Fairness: mass / hydro / reclaim counts and distance-to-start per team within a configurable tolerance; symmetry
  check against the declared symmetry (mirror, rotate) with a difference overlay.
- Connectivity: from the live sim, path from every start to every other start for land, and naval where water
  exists; unreachable resource markers; AI marker graphs (land / naval / air nodes) unlinked or unreachable
  **[open]** (the live path check after terrain edits is verified working in MAP_EDITOR.md).
- Water: elevation versus terrain, shoreline artifacts, deep-water level; lighting and fog values out of range;
  skybox and shader fields valid.

**Mission (from the scenario editor)**
- Stage graph: stage with no entry or exit, unreachable stage, cycle without exit; objective node with no trigger;
  trigger that never fires (area missing, group never spawned); group or marker referenced but undefined, or defined
  but never used; army with a base node but no units; difficulty or coop-player-count branches with no content.
- Generated code: compile and syntax check, plus a run of the mission loader in a scratch sim (smoke load).

**Mesh maps** (when `TerrainSystem = 'mesh'`) 
- SCM vertex limit 65,535 per patch, patch bounds against the playable area, material manifest completeness, texture
  atlas padding and DXT / mips, water outlines closed, `ground_low` / `ground_high` consistent with the mesh
  (see [TERRAIN_MESH_MAPS.md](TERRAIN_MESH_MAPS.md) and the mesh research report).

**Smoke load.** The strongest validator is the engine itself: spawn the released folder in a scratch session
(headless or hidden), run N sim ticks and read the log for Lua errors, missing resources and crashes. This catches
what static rules miss and is the same code path players use.

## 7. Loading without loading screens

Today: first start 7 s without sound, 150 s with sound banks; opening another map exits and restarts the process
**[verified, MAP_EDITOR.md]**; the editor sim is created with the map. Targets and means:

| Cost today | Plan |
|---|---|
| Process restart per map (`LoadMap` calls `ExitGame`) | Keep one resident process; tear down and create the world session in-process. Needs the front-end / session lifecycle in the decomp understood **[open]**. |
| Sound banks (~140 s) | Lazy: load banks on first sound preview; the editor needs almost none. |
| Shader compile | Persistent shader cache on disk, warmed once at install; compile on a worker thread. |
| Archive and blueprint scan | Persistent asset database (props, units, textures, markers, brushes), incrementally updated by file stamps; browsers read the database, not the disk. |
| Map load | Progressive: show a low-detail terrain from the height tiles at once, stream stratum masks, decals and props by view distance; the camera is usable immediately. |
| Sim creation | Frozen sim is created on a worker thread after the view is up; tools that need it (path check, snapping) show "preparing" for a moment; terrain and object editing do not wait. |
| Thumbnails and previews | Cached next to the asset database. |

A hard loading screen is allowed only for first-run setup (shader cache, asset database), with a progress bar and a
visible "you can start editing the map now" path where possible.

## 8. Open questions

1. ~~Branches and merge in v1?~~ **Decided: yes, part of the editor** (user, 2026-10-17). Merge is per chunk /
   region; conflicts shown side by side with per-chunk or per-region choice; a merge is itself a commit with two
   parents and can be undone by restore.
2. Optional mirror of text parts into a real git repository: wanted?
3. Retention defaults (count and age) and where `<EditorData>` lives by default.
4. Should a Release also upload or package for the FAF vault, or only write the folder?
5. Opening campaign / coop maps from `maps.scd`: always read-only import (recommended).
