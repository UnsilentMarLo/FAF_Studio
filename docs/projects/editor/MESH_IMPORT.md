# Mesh import (M5c: F3, F4, F5 and the vertex checks)

Status 2026-10-18: built in the worktree `ed/meshimport`, Lua only (no engine build), self test `selftest_meshimport` passes. Design and research: `docs/projects/editor_research/MESH_MAP_EDITOR_NEEDS.md` (F3-F5, V3/V4/V10/V15), `docs/projects/TERRAIN_MESH_MAPS.md`. Python reference: `scripts/meshmaps/scm.py`.

## What it does

An OBJ file becomes SCM v5 terrain patches in `<map folder>/terrain/` and entries in the manifest `terrain/terrain.lua`:

1. **Parse** (`meshimport.ParseObj`): `v`, `vt`, `vn`, `f` (any polygon, fan triangulated; `v`, `v/vt`, `v//vn`, `v/vt/vn`; negative indices), `usemtl`, `o`, `g`. Faces are grouped by material (default), by object, or not at all.
2. **Build** (`meshimport.Build`): units/axis/mirror/winding/V flip and offset applied once; degenerate triangles dropped; vertices welded by (position, uv, normal) reference; normals from the file or recomputed; **tangents always recomputed** from the uv; uv2 generated; each group split into patches.
3. **Split** (`scm.Split`, port of `scm.split`): a group of at most 65,535 vertices stays one patch, a larger one is cut by map tile (256 units, sorted by tile row, tile column, vertex numbers) so that each patch stays in one area. One patch has one material, so the split runs per group.
4. **Commit** (`meshimport.Commit`): writes `sectionGG_NNN.scm` (GG = group, NNN = serial within the group, numbering continues after the highest section in the manifest), adds a material per group (reusing one of the same name) and a patch entry with vertex/triangle count and min/max, inserts new entries before the first sky patch, and sets `mesh_high` from the written files (V15 rule).

## Options (`meshimport.Defaults`, the dialog's controls)

| Option | Meaning |
|---|---|
| `scale`, `offsetX/Y/Z` | OBJ unit to world unit, then offset |
| `axis` | `y_up` (the map's) or `z_up` (Blender default: `(x, y, z) -> (x, z, -y)`) |
| `mirrorX`, `mirrorZ` | mirror the mesh; the winding is corrected so faces keep pointing out |
| `flipWinding` | turn all faces over |
| `flipV` | default on: OBJ's v runs up, DDS textures run down |
| `normals` | `auto` (file normals when every corner has one, else smooth), `smooth` (area weighted over vertices at the same place, 0.01 unit welding), `flat` (every triangle its own vertices) |
| `uvTile` | when the OBJ has no uv: planar uv over x, z, this many world units per repeat |
| `uv2` | light mask coordinate: `planar` (x, z over the map, clamped to 0..1) or `copy` of uv1 |
| `groupBy` | `material` (usemtl), `object` (o / g), `none` |
| `limit`, `tile` | vertices per patch (at most 65,535) and the split tile |
| `minArea` | triangles below this area are dropped (1e-6) |

## Conventions (verified against a converted SC2 patch)

`sc2_mp_002/section01_000.scm` (1,410 vertices): 1,990 of 1,990 triangles run counter clockwise seen from the side of the normal (`cross(b - a, c - a) . n > 0`); tangent follows +u (398 of 398 sampled triangles); `cross(normal, tangent) . binormal > 0` for every sampled vertex. The importer writes exactly that frame (tangent = dP/du made perpendicular to the normal, binormal = normal x tangent). SC2's own 10-bit packed frames are not perfectly perpendicular (dot with the normal up to about 0.3), which is why V3 only warns above 0.5.

An OBJ with y up and counter clockwise faces seen from above (the usual export) needs no option except `flipV` (on by default).

## The panel and the dialog

* **Mesh import** panel (stack beside *Mesh terrain* in the Environment workspace; `panels_meshimport.lua`). Buttons: *Import OBJ...*, *Patches*, *Materials*, *Check mesh*, *Save*. It edits the model of the Mesh terrain panel (`meshmap.Current`).
  * *Patches*: list with material and vertex count; *Material <* / *>* assigns a material per patch, *Sky* draws the patch last without depth, *Remove* drops the entry (the file stays on disk).
  * *Materials*: *Add material*, rename (name field + Set), *Remove* (only unused ones), *Textures...*.
  * *Fields*: the nine texture slots (`diffuse_a/b`, `normal_a/b`, `specular`, `specular_b`, `light_mask_0..2`) and the flags (`blending`, `glow`, `highlight`, `additive`, `alpha_test`); type a path relative to `terrain/` (empty clears) and press Set. Fields keep the order convert.py writes (`meshmap.MaterialSet`).
  * *Check mesh*: `Mesh.Check(model, nil, { deep = true })`, findings in the list.
* **Import mesh dialog** (`dialogs_meshimport.lua`): path (absolute, or relative to the map folder or its `terrain/`), the options above, *Preview* (converts, shows triangles / vertices / patches per group and notes), *Import* (writes patches and manifest; the map needs a folder, save it first), *Replace the existing patches*. The scenario switch (*Mesh map in scenario* in the Mesh terrain panel) stays a separate decision.

## Checks added to `meshmap.Check` (`opts.deep`, code in `meshscan.lua`)

| Code | Rule | Severity |
|---|---|---|
| V3 | NaN or infinity; normal not unit (+-0.05); tangent or binormal not unit; tangent frame not perpendicular to the normal (> 0.5); degenerate triangles | W |
| V4 | uv2 outside 0..1 for patches whose material has a light mask slot | W |
| V10 | vertical ray samples (up to 160 x 160 over the playable rectangle, tested by rasterising every non-sky triangle) hit less than 99.9 % | W |
| V15 | `mesh_high` missing or more than 0.05 from the highest vertex in the playable rectangle grown by 32 units on every side (same rule as `manifest_heights.py`) | W |

Scans read one patch at a time. `meshscan.Scan(model, folder, { coverage = false })` skips V10. The cheap header check V1 stays in `meshmap.Check` without `deep`.

## SCM v5 in Lua (`scm.lua`)

`Read`, `Write`, `Header`, `Split`, `Bounds`, `PackF32`, `F32`. The editor's Lua numbers are 32-bit floats, which is the format's own precision, so read followed by write is byte exact. Two traps found on the way: **LuaPlus `string.byte(s, i, j)` returns only one value** (every byte is its own call), and a negative zero must be written with its sign bit (the golden file has `-0.0` normals from Python). No native code was needed: reading or writing a 65,535 vertex patch takes well under a second, a 90,000 vertex OBJ (3.7 MB) imports in about 2.5 s, writes in 2 s and a full deep scan of it takes about 1 s (timings from `GetSystemTimeSeconds`, rough).

## Tests

* `editor/tools/gen_scm_golden.py` builds (the file is force-added, `*.scm` is git-ignored) `editor/runtime/lua/editor/testdata/scm_golden.scm` with `scripts/meshmaps/scm.py` and prints the split numbers; `--check` compares the committed file with a fresh one. It finds `scm.py` in the main checkout when run from a worktree (`scripts/meshmaps` is not tracked yet).
* `selftest_meshimport.lua` (registered in `editor/runtime/lua/editor/selftests.extra`, a union-merged list that `editor_inst.py selftests` reads, so branches do not collide on the hard-coded list): writer output equals the Python bytes; reader returns the Python values; a converted SC2 patch survives read + write byte for byte (skipped when `SupCom_MeshMaps` is absent); split of a 40 x 40 grid equals `scm.split`; OBJ import conventions (winding, normals, tangent along u, binormal, flipV, flip, z_up, scale, mirror, flat, file normals, no uv, negative indices, limit); commit, numbering, replace, manifest round trip; V3, V4, V10, V15 on good and damaged patches; the real converted map `sc2_mp_002` scans with full coverage and `mesh_high` equal to its manifest (manual run).

## Not done (next)

* Only OBJ (glTF / FBX need the M7 converters). `mtllib` is ignored: textures are assigned by hand.
* Materials are assigned per OBJ group, not per triangle selection or uv island.
* No smoothing angle: vertices at the same place share one smooth normal, so hard edges (cliffs) need file normals or `flat`.
* F6 texture tools (DXT conversion, mips, atlas padding), F7 light mask baker, V5-V8 texture checks beyond "file exists".
* Patches replaced or removed leave their old `.scm` file in the folder (the editor has no file delete).
* The coverage check looks straight down, so overhangs and walls count as no cover; platform maps need F8's rules.
