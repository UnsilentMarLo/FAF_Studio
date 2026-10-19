# Mod / unit editor (M8): design

Scope is section 18 of [MAP_EDITOR_DESIGN.md](MAP_EDITOR_DESIGN.md). This document fixes what is verified, the data model and the stages. Status at the end.

## 1. Verified facts (read from `faf_repo/fa/lua/system/Blueprints.lua`, 2026-10-18)

- A mod blueprint with the same id as a base one and `Merge = true` is merged into it with `BlueprintMerged(base, mod)`: tables merge key by key, a value of `"__nil"` deletes the field, **arrays merge by
  index** (so a whole `Weapon` array must not be written; use `ModWeapon`).
- `ModWeapon = { { MergeLabel = '<weapon Label>', <field> = <value>, ... } }` merges into the base weapon with that `Label`; an unknown label inserts a new weapon (`AddIndex` positions it, never beyond the first dummy weapon).
- Unit ids are the lower-case file name: `units/<id>/<id>_unit.bp`; the merge file only needs `Merge = true` and the fields that change.
- Runtime blueprints are read-only. A change is tried by reloading the session with the mod enabled (the editor already does that for map mods: `ui.ApplyMods`, autosave and reopen, a few seconds).
- Mods are found as `/mods/<name>/mod_info.lua`; the editor mounts `<editor>/mods/*` (shipped) and now `<run>/modproj/*` (mod projects the user creates in the editor) there.

## 2. Model

- **Mod project** = a folder `modproj/<Name>/` with `mod_info.lua` and generated files only: `units/<id>/<id>_unit.bp` (merge blueprint, delta only). The editor never rewrites a file it did not generate (marker comment
  on the first line of generated files; a file without it is reported, not overwritten).
- **Edits** (`bpedit.lua`): per unit id a map `path -> value`, a path being `Economy.BuildCostMass` or `Weapon:<Label>.Damage`. The base value is always read from the running game's blueprint and shown beside the
  edit; reverting an edit removes it from the delta. Edits persist in the project folder (`edits.lua`) so the delta can be regenerated and the project reopened.
- **Writer**: `UnitBlueprint { Merge = true, BlueprintId = '<id>', <nested deltas>, ModWeapon = {...} }`, keys sorted, numbers as the editor shows them.

## 3. Stages

| Stage | Contents | Status |
|---|---|---|
| S1 | Mod project (create, list, enable), stats inspector for the unit blueprint (economy, defence, physics, intel, weapons) with sliders, merge blueprint writer, "write and test" (mod enabled, session reloaded), checks | first slice built and checked 2026-10-18 (mass and health edits reached the reloaded session) |
| S2 | Unit viewer: spawn the unit in the editor world, close-up and range framing, range / sense / footprint / hit box rings, animation list, speed and scrubber | built 2026-10-18 (bone overlay open) |
| S3 | Effect and projectile preview and editing (`EffectTemplates`, projectile `.bp` fields) | preview built 2026-10-18 (799 templates, 380 projectiles; emitter / projectile field editing open) |
| S4 | New unit wizard: copy-free scaffolding (`_unit.bp`, `_script.lua` stub, strings, build menu entry), mesh / texture import (shares M7), validators (missing files, bone names, weapon labels vs script, id casing, categories, footprint, icon) | open |
| S5 | Icon generator (offscreen render, vanilla recipe measured against the shipped icons) | built and measured 2026-10-18 (section 6: silhouette overlap 0.67 on 67 vanilla units; header identical to the shipped files) |

## 4. Open questions

- Vanilla icon file format: **answered 2026-10-18** from the DDS headers of three icons in `textures.scd`: 64 x 64, DXT5 (alpha channel), `UEL0106` / `UEB0101` without mip maps (4,224 bytes), `XSL0402` with the full chain of 7 mips (5,616 bytes). The icon generator writes 64 x 64 DXT5; mips optional (match the neighbours of the same faction). The camera / light recipe is still to be measured against the shipped icons.
- Script editing: text panel or forms only (recommendation: forms for the common weapon / build-menu hooks, text panel for the rest).
- Animation authoring versus viewing and re-timing.

## 5. Derived units (S4 first part, 2026-10-18)

"Derive unit..." in the Unit lab makes a new unit from an existing one **without copying any file**: the project writes `hook/lua/system/Blueprints.lua` (the hook path mirrors the VFS path, `/lua/system/Blueprints.lua`),
which chains `ModBlueprints`, deep-copies the base unit's blueprint under the new id, applies the unit's edits with `BlueprintMerged` / `MergeWeaponByLabel`, and sets name and description. Mesh, script, sounds and
build-menu categories stay the base unit's (so it shows up where the base does). The edits of a derived unit are the same `Economy.*` / `Weapon:<Label>.*` fields. Checked in the engine: `zml0001` from `uel0106`
(mass 99 / health 700 / damage 33, name and description set), the base kept 30 / 60 / 7, and the new unit spawns in the sim.
Findings while building it: runtime-mounted mod folders resolve by path but are not listed by the directory scan, so `schook/lua/mods.lua` now adds the projects named in `modproj/projects.txt` to `AllMods()`;
a hook file must sit under `hook/<VFS path>` (`hook/lua/system/...`), the older comment in `Blueprints.lua` (`hook/system`) is wrong for FAF; killing the editor between "enable mod" and the next session start leaves
the trial file, which restores the previous selection at the next launch (by design).
Still open in S4: new units with their own mesh / script / strings (needs mesh import), validators for those, bone and sound editing.

## 6. Icon generator (S5, 2026-10-18)

**Result.** The Icons panel (Mod workspace) renders the unit of the Unit lab / Units panel with a fixed recipe, shows it beside the icon the game ships and a silhouette difference, and writes a 64 x 64 DXT5 DDS into
the open project: `modproj/<Name>/textures/ui/common/icons/units/<id>_icon.dds`. "Batch" does every unit the project edits or derives (a derived unit is not in the running game until the project is enabled, and it has
its base unit's mesh, so the base is rendered). The DDS header is byte for byte the one of the shipped icons (checked against `UEL0201`: flags `0x81007`, caps `0x1000`, 4,224 bytes; with `mips = 7` against `XSL0402`:
flags `0xA1007`, caps `0x401008`, 5,616 bytes; decoding a shipped icon and encoding it again changes a colour channel by 0.04 on average).

**Render path (engine, `// EDITOR:` code).** `moho/editor/EdIcon.cpp` (natives) and a pass at the head of `WRenViewport::D3DWindowOnDeviceRender` (`moho/app/WxRuntimeTypes.cpp`). `ed_icon_request(x, y, z, heading, pitch, zoom, fov, size)`
queues one render; the next frame, before the normal frame (which clears and redraws the window, so nothing shows), renders the scene twice into the top left `size` x `size` pixels of the window with terrain, sky, water, effects,
shadows, bloom, ranges and UI off, cleared to black and to white, and saves both with the engine's own frame dump route (`SaveTexture` to a BMP in the temp folder). `ed_icon_result` mattes them (alpha = 1 - (white - black) / 255, the black
picture is the premultiplied colour), crops a square and reduces it by averaging; `ed_icon_bounds` gives the box of the unit. Areas smaller than 10 % of the largest connected one are ignored (a spark or a drone in a corner must not move
the frame). `ed_dds_write` / `ed_dds_read` are the DXT5 writer (principal-axis endpoint fit, alpha extremes, optional box-filtered mips) and a DXT1 / 3 / 5 / 32 bit reader that also reads inside the game's `.scd` files.
Traps found: `SimpleRenderWorldView::GetCamera` returns null, and `Render` skips a view without a camera (the strategic map preview therefore draws nothing either); a camera created in the render pass crashes in
`CScrLuaObjectFactory` (no Lua state), so the pass borrows `WorldCamera` and puts its viewport, heading, pitch, zoom, offset and field of view back; the camera's `zoom` is the visible vertical extent at the target
(eye distance = zoom / tan(fov / 2) / 2) and `TargetManual` derives the pitch and field of view from it, so the pass writes `mFarFov` etc. directly and calls `UpdateCoords`; the window may be larger than requested
(2048 x 1081 on a scaled display), the render square is the top left corner.

**Recipe (`icongen.lua`, `Recipe`).** Camera heading 3.7 rad, pitch 0.55 rad, field of view 22 degrees (the camera is fitted per unit: a 256 px probe finds the alpha box, the focus is moved by the box centre and the zoom scaled
until the unit fills 62 % of the probe, then a 512 px render is cropped to the box with the unit filling 88 % of the 64 px icon); neutral light team colour `{200, 205, 215}` (sim callback `EdArmyColor`, put back afterwards);
tone per faction (UEF `{2.15, 2.13, 2.11}`, Aeon `{1.14, 1.23, 1.45}`, Cybran `{2.06, 1.86, 1.71}`, Seraphim `{1.09, 1.12, 1.11}`: the lab map's light is dimmer than what the shipped icons show; `ToneFit` matches the channel means
over the pixels solid in both pictures); a white light edge 2 px solid + 2 px fade around the silhouette (the shipped icons have one, and their empty pixels are white); empty pixels white.
The vanilla icon is a perspective view from the front left above; heading is the sharp parameter, the rest is flat:

| heading | 2.4 | 3.0 | 3.4 | 3.5 | **3.7** | 3.8 | 4.2 | 4.8 |
|---|---|---|---|---|---|---|---|---|
| mean silhouette overlap (IoU) over 67 vanilla units | 0.54 | 0.56 | 0.63 | 0.66 | **0.67** | 0.65 | 0.52 | 0.51 |

With the final recipe: IoU 0.67 (land 0.76, naval 0.71, structures 0.64, air 0.62; worst: `ueb0303`, `urb3101`, `urb0103`, `urs0305`, `xsb4302`, structures and a big ship whose shipped icon is framed differently),
mean block difference 34 of 255, mean colour of the solid pixels differs by 32 of 255 (`Compare` in `icongen.lua`: `iou`, `color` pixel for pixel, `alpha`, `tint`, `coarse`). Pitch (0.4 / 0.7), field of view (10 / 35), fill (0.80 / 0.94)
and the width of the light edge move the overlap by less than 0.01 each. What stays open: the shipped icons are lit harder than the lab map (more contrast and specular), each faction frames some structures from another angle,
and per-unit overrides (heading, fill) are not exposed in the panel yet.

**Second pass (user review of the first icons).** The first icons had a white edge that was too strong, grid / dot artifacts, were soft, a little too bright with overblown highlights, and showed the whole unit while the shipped icons concentrate on the
front half. Changes: (1) the reduction of the 640 px render to 64 px is a separable Lanczos 3 filter on the premultiplied picture with every output pixel normalised by its own weights (the old box average divided by a constant area while a non-integer
ratio gave cells 7 or 8 pixels, which is what made the dot pattern; Lanczos is also sharper); (2) the light edge is 0.8 px solid + 2.5 px soft (area about 1.6 times the first one's, a glow instead of a white line; the shipped halo covers 0.2 to 0.4 of the unit's area);
(3) the tone gains are multiplied by 0.92 and a soft shoulder starts at 215 (highlights roll off to 255 instead of clipping; mean brightness of the render 74 to 105 against 60 to 130 of the shipped icons, blown pixels at or below the shipped share);
(4) the frame is fitted to the front half: the unit's front (+z) points on the screen along `(sin(heading) * 672, -cos(heading) * 540 * sin(pitch))`, `ed_icon_bounds` takes that direction and `halfMin` and only counts the pixels in front of the middle of the body
(`halfMin` -0.45: a bit more than half; the rear is cut by the icon frame like in the shipped icons). Measured over 67 units: overlap 0.62 to 0.64 (framing the whole unit gave 0.67, -0.6 gives 0.643, -0.3 gives 0.60, -0.15 gives 0.56: the shipped icons cut less than a strict half),
mean colour difference of the solid pixels (`tint`) 31 -> 14. The tone gains were fitted before the front half framing and not refitted.
*Team colour (user review):* the team colour areas of the shipped icons are almost white, ours were a muted grey; the team colour while rendering is now pure white `{255, 255, 255}` (it was `{200, 205, 215}`), and an S curve (`contrast` 0.4)
on the toned colours brightens the light areas and darkens the shadows like the shipped icons do.
*Colour curves instead of gains (second user review: still not matching, the shipped icons have hard contrast, large pure white team colour areas and black shadows).* `LutFit` (icongen.lua) renders about 70 vanilla units with no tone,
takes the interior pixels (no transparent pixel within 3 px, so the white halo of the shipped icons does not count as team colour) of the render and of the shipped icon, and per faction and colour channel matches the histogram of the render to the shipped one
(histogram specification). The result is 33 knots per curve in `icontone.lua` (`Recipe.lut = true`; the gains and the S curve stay as the fallback). The light edge became a faint wide glow (`glowSoft` 3.5, `glowPeak` 0.65, no solid part), since the shipped one is a soft gradient.
To refit after a recipe change: run `LutFit(ids, nil, <path of icontone.lua>)` in a thread (the test scripts of this section).
*Reflectiveness (third review: borders and team colour fine, the glossy highlights too strong).* The big smooth bright areas come from the sun's specular on the Aeon materials (zeroing the specular colour changed nothing; the shipped icons are matte).
Experiments on `ual0201` with four lightings (sun 1 / 0.35 / 0 with ambient 0.3 / 0.55 / 0.9): the weaker the sun the less gloss. A weak sun and high ambient for all units (sun 0.1, ambient 0.85) washed out the UEF units (their white
team colour areas at full ambient, and the histogram curves then amplified the noise there) and flattened the surface detail of the rest, so the lighting is per faction now: `Recipe.lights = { Aeon = { sun 0.25, ambient 0.6, fill 0.7 } }`, the other factions keep the map's own lighting
(set through `ed_world_set` during the capture and put back afterwards, not an undo step). UEF units are rendered with a grey team colour (`teamColors`, 150 / 158 / 172), the other factions with white. The curves were refitted after each change (`icontone.lua`).

**Test method.** `Evaluate(ids, recipe)` / `ToneFit(ids, recipe)` in `icongen.lua` (70 vanilla ids: every fifth icon of the UEF / Aeon / Cybran / Seraphim land, air, naval and structure sets, about 1 s per unit, run inside a thread);
`scripts/icon_tool.py` decodes shipped icons from `textures.scd` and makes contact sheets without any third party package. Test scripts must not run twice at once: the test channel can run a script twice, two capture
threads then fight over the lab spot and leave ghost meshes behind (the second capture of `Capture` is refused while one runs, and a non-empty lab spot is reported); a window that is not the active one idles, so
a long batch must run in the foreground.

## 7. Viewer, effect fields and project validators (2026-10-18, branch ed/viewer2)

**Unit viewer.** *Bones:* sim callback `EdBones` (`lua/editorsim/viewer.lua`: `GetBoneCount` / `GetBoneName` / `GetPosition(bone)` / `GetBoneDirection(bone)`, which returns three numbers) writes a file the UI reads back; the "Bones"
toggle draws a small box per bone, the picked bone (list mode "Bones" of the Unit viewer panel) a larger box and its forward axis; the bones are asked again every two seconds while visible, so they follow animations.
Orientation is only the forward direction (the engine has no bone orientation call). *LOD:* `LODs(id)` lists `Display.Mesh.LODs` with their cutoff ranges, "LOD n" iterates the camera distance (reads `cam:GetZoom()`, the eye distance)
into the middle of the range of LOD n; `LODInfo` says what was reached. The engine rule (`Mesh::ComputeLOD`, `Mesh.cpp`): a mesh uses the first LOD whose `LODCutoff` is at least its depth along the camera axis, and is not drawn beyond the last
cutoff (+ the dissolve range); the camera reaches the asked distance exactly (51.5 for 51.5). Checked on the shipped units: 560 of 633 have two or more LODs and **none** has a first cutoff below 70 (typical 100 to 500, `uel0401` 230 / 468), so the LOD ranges lie at camera distances where
the strategic icon covers the mesh and the camera runs out of zoom: switching between LODs is not visible in the viewer (compared at `uel0401` 60 and 150: the same mesh, only smaller; at 300+ the camera is at its limit and the map fills the view). The buttons are kept for the distance
numbers and for mods with short LOD ranges; the panel says when the camera cannot reach a range. *Team colour:* presets Army / Red / Blue / Green / Yellow / White / Black through `EdArmyColor`; the colour is read when a unit is made, so the unit is made again.
*Lighting:* presets Map / Noon / Evening / Overcast / Night / Icon set the sun, ambient and fill numbers through `world.lua` (`Change`, one undo step each; "Map" restores what the map had when the first preset was used).

**Emitter, beam, trail and projectile fields (Effects panel, tab "Fields").** The tab lists the emitters of the template that was played (or the projectile that was fired) and their numbers, with a slider, revert and "Write project".
`fxedit.lua` is the catalogue: emitters are not in `__blueprints` (the engine keeps them), so the `.bp` file is run in a sandbox (`doscript(path, env)` with `EmitterBlueprint` captured) and every number becomes a field, curve keys
as `SizeCurve.Keys.2.y` (91 fields for `dust_small_emit.bp`); projectiles read `__blueprints` and offer `Physics.*`, `Display.*`, `Economy.*`, `Defense.*`. The edits live in the same `Edits[id][key]` table as the unit edits (id = the blueprint
path, so undo, `edits.lua` and Write need nothing new) and are written as merge files at the game's own path: `effects/emitters/<name>_emit.bp` with `EmitterBlueprint { Merge = true, Source = '<path>', ... }`.
Verified from the source (`Blueprints.lua`): `SetBackwardsCompatId` makes the blueprint id `lower(Source)`, and a file in a mod gets its own mod path as `Source`, so the merge file must name the game's path or it would be a new blueprint; array
entries merge by index (a curve key is written `[1] = { y = 1.25 }`, the other fields of the key stay). The effect on screen needs the session reload ("Test" in the Unit lab): emitters cannot be changed live. Checked in a real reloaded session (2026-10-18, instance with a project enabled through `UI.ApplyMods`, a project hook on `ModBlueprints` recording what the loaded emitter holds): an emitter edit (`Lifetime` 2 -> 4.5, `EmitRateCurve.Keys.1.y` 2 -> 9) arrives
with `Keys[1].x` untouched (3.333, merge by index), and a projectile edit (`Physics.MaxSpeed` 40 -> 77) is read back from `__blueprints` with the other `Physics` fields intact. Both merge files are applied as written.

**Project validators (`modcheck.lua`, shown in the Validation panel under the map checks, with a summary of errors / warnings).** `mod_info.lua` there / compiles / name / uid; unit ids lower case, derived ids valid and their base unit present;
the game files that edits refer to (emitter / projectile path); generated merge files not written yet or stale (the text on disk differs from the edits); the blueprint hook on disk compiles (a syntax error empties the module for everyone);
weapon labels of edited / derived units against the unit script (script text must contain the label; scripts inside game archives cannot be read from Lua and are skipped, `import` of a unit script fails in the UI state);
an icon for every derived unit; everything `bpedit.Check()` reports. Self test: `selftest_modproj.lua` (27 checks; part of `editor_inst.py selftests`).


## 8. Unit viewer rework (2026-10-18, branch ed/viewer4)

- **Own stage.** The viewer has two stages: *Viewer* (default; terrain, sky, water and world border are switched off with the renderer console variables, the unit stands in a map corner away from every object with a floor grid drawn as overlay lines) and *Map* (the unit stands in the open map at the lab spot). Neither touches the map document, undo or the saved map; the camera is saved at the first Spawn and restored by Close; the flags are reset at module load. Leaving the Mod workspace or pressing Play closes the viewer.
- **Cleanup (`EdViewClear`).** The viewer's unit is protected (no damage, cannot be killed, not targetable, not reclaimable / capturable / selectable, immobile), so a naval unit on land does not die and leave a wreck. On unit change, Close, Play and map reload everything the viewer made is destroyed: its units, props that were not in the baseline taken at the first Spawn (wrecks), and the effect / projectile entities of the Effects panel (`ScenarioInfo.EdViewTemp`). Test: `selftest_viewer.RunLive`.
- **Bones every frame** come from the render side (native, `ed_unit_bones(entityId)`, `EdUnitBones.cpp`): world-space name, index, parent, position, forward and up axes of every bone, so animations are followed in the frame they play. Drawn as joints with three axes and a line to the parent.
- **Hit box** is the engine's own collision extents (`Unit:GetCollisionExtents`, read again 1.2 s after the spawn because an aircraft's shape changes when it settles), drawn as a 3D box (sphere collision: three great circles). Footprint and skirt are ground rectangles from the blueprint. An aircraft keeps its cruise altitude (the engine lifts it; its hit box is larger in flight than on the ground), the viewer does not force it down.
- **Camera** (`ed_camera_info` gives fov, eye, focus, heading, pitch, zoom, viewport). Verified facts: zoom is the visible vertical extent at the focus distance, the eye distance is `zoom / (2 tan(fov/2)) / 2` (this corrects the earlier eye-distance formula in section 7, which was wrong by the factor 2 tan), the field of view is interpolated between `cam_NearFOV` (65) and `cam_FarFOV` (60) by zoom, and zoom has a minimum `cam_NearZoom` (5), so a small unit would be a speck: the stage lowers `cam_NearZoom` / `cam_NearFOV` / `cam_FarFOV` and restores them on leaving. `UpdateFrame` snaps the focus to the terrain along the line of sight, so `FocusFor` computes the ground point whose line of sight passes through the unit's centre, shifted so the unit sits in the middle of the visible panel, not of the window. Iso / Front / Side / Back / Top and Fit use `Aim`; orbit sliders keep the distance.
- **Native edits:** new file `engine_decomp/faf-re-upstream/src/sdk/moho/editor/EdUnitBones.cpp` (+ entry in `main_ed.vcxproj`); build with `engine_decomp/_deps_src/build_engine.bat`. Editor instances need an exe built from it (without it the bones list is empty and the viewer falls back to blueprint extents).


## 9. New unit wizard (S4, 2026-10-19, branch ed/unitwiz)

A unit with its own id inside a mod project, **made from a template and never from a copy of a blueprint**. Panel *Unit wizard* (Mod workspace, tab beside the Unit lab), logic in `unitwiz.lua`, validators in `unitcheck.lua`, the in-game test in `unittest.lua` + `editorsim/unittest.lua`.

**Data flow.** A unit is a *spec* (plain table, saved in the project's `edits.lua` as `NewUnits[id]`: template, faction, tech, name, description, extra / removed categories, who builds it, economy / defence / physics / intel numbers, weapons, sound set, animations, mesh and texture sources). `bpedit.lua` holds `NewUnits` next to `Edits` and `Derived`; the Unit lab sees a wizard unit like any unit (`Fields(id)` reads the blueprint the spec generates, edits go into the generated blueprint as the last step, no separate merge file). `Write()` generates per unit:

| File | Generator | Contents |
|---|---|---|
| `units/<id>/<id>_unit.bp` | `Wiz.BlueprintText` | `UnitBlueprint { ... }` written field by field; sorted keys; first line is the generated mark (a file without the mark is the user's: reported, never overwritten) |
| `units/<id>/<id>_script.lua` | `Wiz.ScriptText` | `ClassUnit(<base>)` of the template and faction, one `ClassWeapon(<weapon class>)` per blueprint weapon label; `TypeClass` |
| `units/<id>/<id>_strings.lua` | `Wiz.StringsText` | `<id>_name` / `<id>_desc` in strings_db format. The blueprint uses `<LOC key>text`, which falls back to the text: FAF merges `strings_db.lua` of AI mods only, so the file is for translators to paste into `/loc/<language>/strings_db.lua` |
| `units/<id>/<id>_lod0.scm` (+ `_lod1`) | `Wiz.Mesh` | OBJ import or a placeholder, **skinned**: the template's skeleton or root + one bone per OBJ group |
| `units/<id>/<id>_albedo.dds`, `_normalsts.dds`, `_specteam.dds` | `Wiz.TextureSource` | imported / converted (DDS DXT1/3/5/32 bit, PNG, BMP, JPEG, TIFF -> DXT5 with mip maps) or a 64 x 64 placeholder |
| `textures/ui/common/icons/units/<id>_icon.dds` | `Wiz.WriteQuickIcon` | a software preview (`quickicon.lua`) until the Icons panel renders the real icon from the running game |

**Templates** (`Wiz.Templates`): land bot, tank, hover, naval, air, defence structure, economy structure, engineer, factory, for the four factions. `scripts/unitwiz_data.py` reads, for every template and faction, one vanilla *donor* unit (36 donors; list at the top of the script) and writes `unitwizdata.lua` (220 KB, generated, do not edit): the skeleton of the donor's LOD0 mesh from `units.scd` (bone name, parent, 12 numbers of the inverse bind pose, position, rotation; `scripts/scm_dump.py` is the reader), its sound set, animation paths, weapon bones and the numbers a unit of that kind needs (motion, footprint, scale, command caps, veteran, wreckage, `Air` flight parameters ...), plus weapon fields by *kind* (direct, cannon, artillery, aa, missile, torpedo, bomb) and faction with the weapon script class, and the unit script base class per template and faction. The wizard takes pieces by reference: sound cues, animation files, bone names, the numbers it writes itself. Donor-specific categories (`PRODUCTSC1`, weapon roles, tech, faction, `BUILTBY*`) are rebuilt from the spec; upgrade chains, `RaisedPlatforms` and `RollOffPoints` are not carried over.

**Skinned SCM writer** (`scm.lua`, additive: a mesh without `bones` writes the one root bone as before; the golden tests of the mesh import pass): `m.bones` = list of `{ name, parent, rest, pos, rot }`, `m.bone` = bone index per vertex; `BindPose` computes the inverse bind pose from position and rotation (checked against all 35 donors: largest difference 0.00003); `Bones(data)` and `FileBounds(data)` read a file for the validators. Vertex bone bytes: first byte the bone, the others 0; header "skinned bone count" = highest bone used + 1. OBJ import reuses `meshimport.lua` (`ParseObj` / `Build`): every OBJ object / group becomes a part, a group named like a bone is bound to it (case insensitive), the others to the root; the model is rotated (0 / 90 / 180 / 270 degrees), scaled so that its longest horizontal side is the spec's length, centred on x / z and put on the ground. A placeholder (no OBJ) is a box and, for a unit with weapon bones, a turret box and a barrel at the donor's bone positions, in the donor's proportions scaled to the length. The skeleton is scaled by the same factor; animations of the donor keep working while the bone names are the template's.

**Test in game** (`Test` tab): *Test in game* writes the project, remembers the test in `modproj/unittest.lua` (the Lua state does not survive the session change), adds the army `UNIT_TEST_TARGETS` (enemy of ARMY_1, undoable) to the map, enables the project and reloads the session; the Unit wizard panel (`Refresh`, once per session) then spawns the unit and two dummy targets (weapons disabled, 20,000 health, immobile) 28 units ahead and moves the camera. Quick commands: attack, move, patrol, stop, heal, kill, respawn, **build it from a factory** (a factory of the game, or an engineer for a structure, picked from the builders whose `BuildableCategory` matches, builds the unit: proves the build menu entry for real). *Restart* writes and reloads again (the blueprint is read again from disk); *End test* takes everything down and removes the army. Status line: health, orders, position, targets' health, damage dealt, built count. Checked 2026-10-19 on `zel0101` (a bot of the UEF template with its own mesh, textures and weapon): loaded without a log warning, the unit fired through the generated skeleton (322 damage in 20 s), and a T1 land factory built it (`built 1`). Findings: the blank map has one army, so the targets need a second one (an `IssueAttack` on a unit of the own army is not queued, orders 0); the army's stock only fills up to its storage and the storage counts from the next tick (`GiveStorage`, then `GiveResource` three ticks later); a dummy target with weapons killed the 60 health unit.
Engine rules found in the log while testing: `Blueprints.lua` raises `SizeX` / `SizeZ` to 10 % of the top speed (`Air.MaxAirspeed` for aircraft) and `SizeY` to 0.5 and warns (*"Overriding the x axis of collision box"*); the **collision box is `Size*`**, not `Physics.MeshExtents`. The wizard writes the box from the mesh bounds and at least that large. A weapon with `TurretDualManipulators = true` and no dual bones logs *"Trying to use the bone nil"*: the donor weapons are copied without it.

**Validators** (`unitcheck.lua`, merged into the project checks of `modcheck.lua`, shown in the Validation panel under the map checks, `Files` tab of the wizard). They read the files in the project (generated ones may have been edited by hand): files present and current; id (lower case, at least 6, not a game unit, unique); blueprint compiles, costs / health / build time / rate of fire; projectile files exist; script compiles, `TypeClass`, **weapon labels against the script's `Weapons` names both ways**; **bone names** the blueprint (turrets, racks, muzzles, build effects) and the script (`CreateRotator`, `ShowBone`, ...) use against the SCM file's bones (case differences are warnings); categories (faction, tech, layer, MOBILE xor STRUCTURE, SELECTABLE), skirt of structures; **build menu reachable**: category expressions (`A B` intersect, `+`, `-`, brackets) evaluated against the `BuildableCategory` of every builder of the game (the cheat engineer `zxa0001` with `ALLUNITS` does not count); collision box against the mesh (shipped units run 0.35 to 3.7 times the mesh bounds times `UniformScale`) and the engine's minimum; LOD cutoffs ascending, first not below 70, a mesh per LOD; SCM version 5, at most 65,535 vertices (error), 20,000 vertices / 3 MB (warning), textures DXT, power of two, at most 2048; animation files exist and need the template's skeleton; icon present. **Fix buttons** (Validation panel: *Fix* for the selected row, *Fix all*; Files tab: *Fix n*) exist where the repair is safe: write the unit (regenerates missing or stale files and the box), add the default builders, make the preview icon.

**Self test:** `selftest_unitwiz.lua` (registered in `selftests.extra`; 66 checks): donor data and bind pose, category expressions, all 36 template / faction pairs compile and are reachable, skinned SCM write / read, OBJ import with bone binding, project write, persistence, unit lab edits, 17 injected faults for the validators and their fixes, texture import, preview icon.
Limits: no LOD generation (a second LOD is the same mesh); the mesh keeps one material (a unit SCM has one); weapon bones of a skeleton made from groups are found by name (turret / barrel / muzzle) or set in `spec.bones`; naval units on the blank map stand on land (they fire, they do not swim).

## 10. Icon recipe per category, batch mode (S5, 2026-10-19, branch ed/unitwiz)

`icontune.lua`: measuring sets (`Sets`: 60 vanilla units, 16 land / 16 air / 12 naval / 16 structure, every faction, tech 1-3; `Holdout`: 32 other units), `Sweep(category, grid, path)`, `Report(path, sets)`. `icongen.Recipe.categories` holds per category overrides (precedence: Recipe, category, call). `icongen.Batch(ids)` / `ProjectUnits()` render and write the icons of every unit the project edits, derives or made with the wizard (Icons panel "Batch" uses it; a wizard unit must be in the running game: Test first). Colour curves can now be fitted per faction and category (`LutFit`, `LutOf` look up `UEF/air` first, then the faction); **not refitted yet**.
Baseline on the 60 units (mean silhouette overlap IoU): land 0.613, air 0.489, naval 0.471, structure 0.570, all 0.540 (the 67 unit sample of section 6 had no big T3 units). One factor at a time sweeps (heading 2.6 .. 5.0, then halfMin, fill, pitch at the best heading): land best heading 3.7, halfMin -0.7 gives 0.634; air heading 3.4 gives 0.535, fill 0.8 gives 0.558 (pitch 0.8 failed to render 6 of 16: thin aircraft); naval heading is flat, **pitch 0.8 gives 0.610 and cuts the tint error from 77 to 30**; structure heading 4.0 gives 0.580, halfMin -1 0.597, pitch 0.8 0.592 (tint 13). Combined sweep (third round): structure halfMin -1 + pitch 0.8 gives 0.611 (pitch 1.0 0.612 but a worse tint); naval pitch 1.0 / 1.2 / fill 0.8 give 0.582 / 0.563 / 0.594, so pitch 0.8 stays (0.610); land pitch 0.7 gives 0.620 and 0.4 gives 0.539, so 0.55 stays (0.634 with halfMin -0.7); air pitch 0.7 gives 0.480, fill 0.7 0.545, pitch 1.0 0.445 (fill 0.8, pitch 0.55 stays, 0.558). halfMin changes nothing for air and naval.
**Final recipe** (`Recipe.categories`): land `halfMin -0.7`; air `heading 3.4, fill 0.8`; naval `pitch 0.8`; structure `heading 4.0, halfMin -1, pitch 0.8`; everything else as in section 6. Colour curves refitted per faction **and category** on the 60 units (`UEF/air` ... 3 or 4 units each; fewer than 3 falls back to the faction's curves).

| Silhouette overlap IoU / colour / tint / coarse | before (60 units) | after (60 units) | holdout (25 other units, not fitted) |
|---|---|---|---|
| land | 0.613 / 84 / 20 / 34 | 0.634 / 84 / 22 / 32 | 0.717 / 80 / 4 / 24 |
| air | 0.489 / 120 / 108 / 53 | 0.558 / 90 / 16 / 43 | 0.607 / 89 / 9 / 36 |
| naval | 0.471 / 90 / 77 / 56 | 0.611 / 79 / 38 / 38 | 0.692 / 83 / 45 / 32 |
| structure | 0.570 / 88 / 29 / 47 | 0.611 / 86 / 11 / 41 | 0.635 / 85 / 18 / 33 |
| all | 0.540 / 96 / 57 / 47 | **0.603 / 85 / 21 / 38** | 0.652 / 85 / 18 / 32 |

(`tint` = difference of the mean colours of the solid pixels, `coarse` = 8 x 8 block difference, `color` = pixel for pixel; 0..255.) What is still off: the worst overlaps are a few T3 units whose shipped icon is framed differently (`xsa0103`, `xsb0101`, `ual0303`, `url0107`, `url0106`, `xss0302`: 0.22 to 0.40); pixel colour error stays high because the shipped icons are lit harder and have texture detail the lab light does not reproduce; naval tint (38 to 45) is the largest remaining colour offset (only 3 fit units per faction); the 7 holdout units without a shipped icon in the game were skipped. Re-run: `icontune.Sweep` for geometry, `icongen.LutFit` for the curves, `icontune.Report(path, Sets | Holdout)` for the numbers. Batch mode: `icongen.Batch()` writes the icons of the whole project with these recipes.
