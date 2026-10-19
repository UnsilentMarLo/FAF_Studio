# Research: feature list of the GPG map editor (SCEditor.exe) and the FAF Unity map editor

Purpose: input for the FAF Studio ([../MAP_EDITOR.md](../MAP_EDITOR.md), [../MAP_EDITOR_DESIGN.md](../MAP_EDITOR_DESIGN.md)).
Date: 2026-10-17. Read-only research; no source file was changed.

Evidence tags: **[decompile ref]** found in `external_projects/SCEditorDecomp/out/` (address = function in
`SCEditor.exe.c`; class names are real RTTI names from `SCEditor.exe.symbols.tsv`, everything else is `FUN_xxxxxxxx`);
**[asset index]** from `_asset_index/scd/editor.scd.tsv` or `external_tools.tsv` (no binary was opened);
**[web]** public GitHub repo `ozonexo3/FAForeverMapEditor` (source tree, release notes, issue tracker; fetched with
the GitHub API/raw files, treated as data); **[inferred]** conclusion from names, sizes or structure, not proven.

How the decompile was read: strings were extracted per function (`L"..."` literals, 1,107 distinct), RTTI vftable names
gave the class inventory (the editor lives in namespace `sce::`), and a few functions were read for behaviour. Dialog
code is wxWidgets 2.4 (`wxListCtrl`, `wxNotebook`, `wxGrid`, ...). The decompile is noisy: pairing of hotkey names with
actions is inferred, brush maths is only partly legible.

Limits of this research (honest): the web search tool returned almost nothing about editor complaints (the FAF wiki
returns 403, forum searches hit unrelated sites). Complaints below come from the Unity editor's own GitHub issue
tracker (100 newest of ~160 issues read) and from what the decompile itself shows. Statements about GPG-editor
crash behaviour that are not in the decompile are marked [inferred].

---------------------------------------------------------------------------------------------------------------------

## 1. The GPG editor (SCEditor.exe, 2007, 32-bit, wxWidgets + GPG engine DLLs)

### 1.1 Architecture facts
- Same engine libraries as the game: `gpgcore.dll`, `gpggal.dll` (graphics abstraction), `MohoEngine` services
  (`Moho::DISK_*`, `IRenderWorldView`, `CHeightField`, `IWldTerrainRes`, `CDiskWatchListener`) [decompile ref:
  imports in `SCEditor.exe.symbols.tsv`]. So terrain, water, decals and units are drawn by the game's renderer: 1:1
  look (this is also our product definition).
- Startup runs `/lua/editorInit.lua` (-> `globalInit.lua`) [decompile ref 00430640; `faf_repo/fa/lua/EditorInit.lua`]
  and reads UI state from `Editor.prefs` (keys `Windows.<Dialog>.x/y/width/height/maximized`, hotkey map)
  [decompile ref 0041ee50, 00422900, 00430640].
- Data model classes (RTTI): `Scenario`, `Army`, `ArmyManager`, `UnitGroup`, `Unit`, `UnitNode`, `Squad`, `Platoon`,
  `PlatoonManager`, `Marker`, `MarkerManager`, `MarkerChain` (shared_ptr), `Area`, `Rectangle`, `Prop`, `PropManager`,
  `DecalManager`, `OrderManager`, `OrderQueue`, `GameConfig`, `GameManager`, `Tileset`, `Brush`, `FilterBrush`
  [decompile ref: symbols].
- Command/hotkey system: `ActionManager`, `Action`, `ActionKey`, one `ActionXxx` subclass per command
  (`ActionUndo/Redo/Copy/Paste/Delete/Lock/Save/SelectAll/DeselectAll/SelectAllOfMatchingType`), `ActivateXxx` for
  tool/layer switching, `HotkeysDialog`, `HotkeysKeyHandler`, `LayerKeyHandler` [decompile ref: symbols; 0043c710,
  00419fb0 default map].
- Undo: `EditStack` + `Edit` base + per-domain edits (`ElevationEdit`, `StrataMaskEdit`, `TerTypeEdit`, `WaterMaskEdit`,
  `WaveEdit`, `LightingEdit`, `DecalCreate/Delete/Edit/Select`, `MarkerCreate/Delete/Edit/Select`,
  `PropCreate/Delete/Edit/Select`, `UnitDelete`, `ArmyDelete`), `CompoundEdit` for grouping, mementos
  (`ArmyMemento/DecalMemento/MarkerMemento/PropMemento/UnitMemento/WaterMemento/WaveMemento/LightingMemento`)
  [decompile ref: symbols; EditStack at 0041ceb0/00454a60]. Brush strokes are recorded as `BrushStroke<unsigned short>`
  (heights) and `BrushStroke<unsigned char>` (masks) made of `StrokeSample<T>` [decompile ref 0045e2c0, 0045f0c0].
- The editor keeps one "editing state" per layer: `EditingElevation/LowerStrata/Strata/UpperStrata/TerType/Water/
  Lighting/Prop/Decal/Marker/Area/Army/Platoon/Order/Game` plus `EditorState/Initialized/Uninitialized/Resetting`
  [decompile ref: symbols]. UI concept: the **Layers dialog** is a mode switch, not a visibility list.

### 1.2 Menus and global commands [decompile ref 00422f80]
File: New..., Open..., Open Recent, Save, Save As..., Export (Decals, Props, Lighting, Water, Strata "Theme" as `.lua`;
Heightmap `.raw`; Strata masks `.raw`), Import (same set), Exit. Edit: Undo, Redo, Copy, Paste, Select All, Deselect
All, Scenario... (properties). View: Wireframe, Skirts, Intel Ranges, Weapon Ranges, Grid, Areas, Slope, Preview, Layers,
Tool, Resources, Console, Log, Water, Force Decals, Gizmo, Strategic (icons), Units (visibility), Debug submenu,
Statistics..., Reset View. Options: AutoSnap to o-grid, AutoSnap to terrain, AutoSnap to land layer (the last is
`Auto&Snap to land layer`), Hotkeys. Toggles execute console commands: `ren_ShowWireframe`, `ren_Water`,
`ren_Shoreline`, `ren_IgnoreDecalLOD`, `ren_FogOfWar`, `ren_Ui`, `WIN_ShowLogDialog` [decompile ref 0042eb40-0042eba0,
004302d0, 00430320, 00430640].

### 1.3 Default hotkeys (decompile 00419fb0; pairing partly inferred)
- Layer switching: F1 Games, F2 Armies, F3 Platoons, F4 Orders, F5 Areas, F6 Markers, F7 Props, F8 Terrain Type,
  F9 Water, F10 Decals, F11 Dev Stats. Layer actions also exist for Elevation, Lighting, Strata 0..5 (no default key
  recovered).
- Editing: Delete (Delete), Equals / Minus = Brush Size Increase / Decrease, RightBracket / LeftBracket = Brush Height
  Increase / Decrease, Backslash = Brush Invert Effect, Space (Group or Properties, unclear), plus unkeyed actions
  Paste, Select All, Deselect All, Select All of matching type, Group, Properties, Brush, Filter, Gizmo Rotate / Move /
  Elevation / Scale / Group Rotate, Hide/Show Toggle, Insert, Stamp, Shadow Map, Reset View, View Gizmo Toggle,
  View Debug Slope Toggle, Props Autoplace Toggle. All are user-rebindable in the Hotkeys dialog (search "Find Command",
  "Press shortcut keys", Assign, Restore Defaults) [decompile ref 0043c710, 0043dc40, 004caf60].

### 1.4 Tools (ToolDialog = one properties panel per tool) [decompile ref 004492b0, 00416c40, 004169c0]
`ElevPropertiesTool, ElevBrushTool, ElevFilterTool, ElevRazeTool, LightPropertiesTool, StrataPropertiesTool,
StrataBrushTool, StrataEraseTool, WaterPropertiesTool, WaterBrushTool, WaterWavesTool, TerTypeBrushTool,
DecalPropertiesTool, DecalEditTool, PropPropertiesTool, PropEditTool, MarkerPropertiesTool, AreaPropertiesTool,
OrderPropertiesTool, ArmyPropertiesTool, GamePropertiesTool, PlatoonTool`. Layer -> tools: Elevation = Properties /
Brush / Filter / Raze; Strata = Properties / Brush / Erase; Water = Properties / Brush / Waves; Decals = Properties /
Edit; Props = Properties / Edit (with autoplace) [decompile ref 0041f490, 0041f9c0, 004201a0, 00420680, 0041fd90].

---------------------------------------------------------------------------------------------------------------------

## 2. Feature groups of the GPG editor (details)

### 2.1 Terrain / elevation
- **Heightmap import/export**: `.raw` 16-bit; import dialog has Black/White levels mapped to "Elev. Max.",
  "Rescale", High/Low [decompile ref 00455830, 00456540]. Export error "Unable to open file for export".
- **Elevation Brush** panel: Strength, Size, Minimum, Maximum (height clamp) + thumbnail list of brushes (64 x 64
  image list) and three bitmap buttons (import `.raw` as brush, save `.brush`, and a third, inferred delete) [decompile
  ref 004574a0, 00459680, 004588b0, 00458570].
- **Elevation Filter** (convolution): kernels Impulse, Sharpen, Unsharpen, Blur, Blur North/South/West/East; Strength,
  Size; saves `.filter` [decompile ref 00459bf0, 0045b190, `FilterBrush`, `Filter<unsigned short>`].
- **Elevation Raze** ("Raze elevation"): flattens to a Target height; Size; Brush Height +/- keys change the target;
  saves `.raze` [decompile ref 0045c050, 0045d0b0, 0045db20].
- Brush modifiers: Brush Size +/-, Brush Height +/-, **Brush Invert Effect** (raise <-> lower).
- **Stamp** action and `/editor/raw/*.raw` (Crater, Mesa, Default, up/down/left/right ramps, chalk/round 1k hard shapes)
  [decompile ref 00419fb0 "Stamp"; asset index]. Interpretation: heightmap patterns usable as brushes or stamps
  [inferred].
- Map creation limits: grid dimensions and Max. Elevation shown in statistics [decompile ref 004483f0].
- Slope overlay (`TTerrainOverlay`): min/max slope, buildable / pathable / blocking colours (`Menu.View.Slope.*`)
  [decompile ref 004284f0].

### 2.2 Strata / textures
- 10 texture layers: Lower Stratum, Stratum 1-8, Upper Stratum (layers dialog) [decompile ref 00440680]. Per layer:
  Visible, Albedo texture + repeat rate, Normal texture + repeat rate, Import Mask / Export Mask (`.raw`) [decompile ref
  00464ef0, 00465d80]. Theme export/import writes `strata = { LowerAlbedo, LowerNormal, Albedo0..7, Normal0..7,
  UpperAlbedo }` [decompile ref 0042bb70, 0042e230].
- Strata Brush: Strength, Size, brush list, Brush Invert; Strata Erase tool ("Erase strata"); `StrataMaskEdit` undo
  [decompile ref 00466580, 00467900, 004683a0, 00467a60].
- Resource Browser: Tileset, Category, tabs Stratum / Decals / Splats / Props; drag texture from browser onto slot
  (`DropListener`, `DropTarget`, `stratumNAlbedoSelector`, `lowerNormalSelector` ...) [decompile ref 00442c10].
- Albedo and Normal selectors are separate (a normal cannot be dropped on an albedo slot; Unity later copied this).

### 2.3 Terrain type
- Terrain Type Brush (`TerTypeBrushTool`, `TerTypeEdit`), "Import Mask for Terrain Type", choose type list from the
  terrain-type table ("No terrain types found.") [decompile ref 004204e0, 00501230, 00501350].

### 2.4 Water
- Water Properties: surface / deep / abyss elevation; sun colour, surface colour, colour lerp (min/max); reflection
  (sun, sky, unit); refraction; shininess; strength; glow; fresnel bias and power; texture maps: sky cube, water ramp,
  Normals 0-3 each with Direction / Speed / Frequency ("sceNormalMapCtrl"); export / import water settings as `.lua`
  with the real key names (`surface_elev, deep_elev, abyss_elev, surface_color, color_lerp, refraction_scale,
  fresnel_bias, fresnel_power, unit_reflection, sky_reflection, sun_shininess, sun_strength, sun_glow, sun_reflection,
  normal_movement, normal_repeat, local_cubemap, local_normals, water_ramp`) [decompile ref 00479710, 00478120,
  0042b230, 0042d3e0]. "Enable" toggles water; "Restore Defaults".
- Water Brush paints the three water masks: **Flatness, Foam, Depth Bias**, with Strength and Size [decompile ref
  0047cfc0, 0047e2b0, 0047e750 `WaterMaskEdit`].
- Water Waves tool: Shore Depth, Generate, Reset; wave patterns from `/editor/tools/water/wavepatterns.lua` (text,
  readable; `nopreview.bmp` thumbnail) [decompile ref 0047eff0, 00480910, `WaveEdit`, `WavePattern`; asset index].

### 2.5 Lighting / environment
- Terrain Shader choice, Background, Sky Cube, Environment Lookup Textures (list with Label / File, Add / Remove),
  light direction as Right Ascension + Declination, Multiplier, Light Color, Ambient Light Color, Shadow Color, Specular,
  Glow Amount, Bloom, Fog Color / Start / End; export / import `.lua` (`right_ascension, declination, multiplier,
  light_color, ambient_light_color, shadow_color, specular_color, specular_glow, bloom, fog_color, fog_start, fog_end`)
  [decompile ref 00460730, 00462e10, 0042abf0, 0042ca80]. Note: sun direction is spherical (RA / Dec) here; Unity uses
  presets plus a direction gizmo.

### 2.6 Decals
- Decal Properties: Texture, 2nd Texture, Type (`<Choose Type>`), LOD Cutoff, Near LOD Cutoff (+ resets), Group, Position,
  Yaw, Scale, "Map centered rotation / scale", ABS / REL; "WARNING: The following cannot be undone" on bulk type
  changes; memory statistics per decal type (albedo, normal, water mask / albedo / normal) [decompile ref 0046d170,
  0046fe30, 0046ecd0, 004486d0, 004337f0]. Decal Edit tool = place / move / rotate / scale with gizmos. Import / export
  decals as `.lua` [decompile ref 0042a5a0, 0042c2a0]. "Force Decals" = ignore decal LOD.

### 2.7 Props
- Prop Properties + Prop Edit. **Autoplace (spray)**: active props list, "Size of paint area (radius)", "Min distance
  between props", "Props to place per second", "Slope falloff angles (degrees): Start 20, End 60", enable toggle
  (hotkey "Props Autoplace Toggle"), "Rotate about map center", Yaw / Set; hints: hold CTRL = pitch, SHIFT = roll,
  CTRL while changing elevation = snap to ground [decompile ref 0048a960, 0048cdb0]. Export / import props `.lua`
  [decompile ref 0042a8d0, 0042c670]. Prop statistics (instances / unique) [decompile ref 00448df0].

### 2.8 Markers, chains, areas
- Marker Editor: notebook with Templates, Markers, Chains; "Hide All Markers", "Delete Selection", "New Chain",
  "Add Selected Markers To Chain"; property control per marker; orientation helpers ("Set the camera's orientation to the
  marker's", "Set the marker's orientation to the camera's") [decompile ref 0049da20, 004a4b70, 004a1b60].
- **Data-driven marker types**: loaded from `/lua/MarkerTemplates.lua` (`faf_repo/fa/lua/MarkerTemplates.lua`: Blank
  Marker, Mass, Hydrocarbon, Combat Zone, Defensive Point, Effect, Expansion Area, Large Expansion Area, Naval Area, Naval
  Defensive Point, Naval Rally Point, Protected Experimental Construction, Rally Point, Island, Naval Exclude, Weather
  Definition, Weather Generator, Camera Info, Transport Marker, Naval Link, Land / Water / Air / Amphibious Path Node);
  each template gives `prop`, `color`, `editorIcon`, `resource`, `amount`, `size`, `hint` [decompile ref 00496980,
  00491a10; asset: `/textures/editor/marker_*.bmp`, `/env/common/props/markers/*`].
- Rules in code: marker names and chain names must be unique ("A marker with the name [%s] already exists"), master chain
  `_MASTERCHAIN_` holds every marker; legacy chain order bug warning [decompile ref 00494a30, 004973d0, 00492270,
  00493c90].
- Area Properties: rectangles saved as `Areas = {...}` [decompile ref 004a93e0, 0048ee30].

### 2.9 Armies, units, orders, platoons, game configuration (the mission part)
- Army panel: Alliances (Neutral / Ally / Enemy matrix), Faction, Colour, Personality (None / Human / AI) and **AI Plan**
  picker from `/lua/ai/*.lua` [decompile ref 004bfe70]. Army tree: groups (`ARMY_`, `GROUP`, `INITIAL`), drag-drop of
  units and groups (rules: group cannot go onto a unit; no army creation by drag-drop), Select Stacked (units on top of
  each other), Abs Yaw, "Save anyway? stacked units" warning on save [decompile ref 004c4d80, 004c6b00, 004c76f0,
  00429e70, 004baf80].
- Unit placement: `UnitInserter`, `CreateUnitHandler`, `UnitSelector`, `SelectUnitsInside`, `SelectSingleUnit`,
  `SelectAllUnits`; range / skirt overlays (`UnitRangeDraw`, `UnitSkirtDraw`) with colours for radar, sonar, omni, weapon
  min / max / damage [decompile ref 004292e0; symbols]. Strategic icons toggle.
- Orders (`OrderQueue`, 34 order classes): Stop, Move, Dive, Formation Move, Build Silo / Factory / Mobile / Assist,
  Attack, Formation Attack, Nuke, Teleport, Guard, Patrol, Ferry, Formation Patrol, Reclaim, Repair, Capture, Transport
  Load / Unload, Self Kill, Self Destroy, Detach, Upgrade, and 8 platoon orders (Move To Location / Target, Ferry To
  Location, Patrol, Destroy, Formation Override, Attack Target, Use Teleporter, Guard Target). Saved as Lua text
  (`cmd = function (tblUnit,target) IssueMove(tblUnit, ...) end`) [decompile ref 004b1190, 004ab190-004b0e90, 004b6120].
- Platoons: PlatoonTool, Platoon Build Manager / Browser / Editor; platoon builders with `PlatoonTemplate`, `PlatoonType`
  (Attack, Artillery, Support, Guard, Scout), `LocationType`, `Priority`, `BuildConditions`, `BuildCallbacks`,
  `PlatoonAIFunction`, `PlatoonAddFunctions`, `PlatoonData` tree editor (`PlatoonDataEditor`: insert Boolean / Integer /
  Float / String / Table); function specs are read from `/lua/Editor/*.lua`, `/lua/ai/OpAI/*.lua`, `_EditorFunctions.lua`
  and validated ("FUNCTION SPEC ERROR/WARNING", parameter-count mismatch checks) [decompile ref 004d82b0, 004e1400,
  004e14f0, 004aabe0; `faf_repo/fa/lua/AI/OpAI/*_EditorFunctions.lua`].
- Game configurations: several named configurations, Teams (`New Team %d`), available armies, Custom Data table
  (Insert Boolean / Float / Vector2 / Vector3 / Rectangle / String), no-rush radius and per-army offsets
  (`norushradius`, `norushoffsetX_`, `norushoffsetY_`) [decompile ref 004d3090, 004d0210, 004cf7c0, 004d6360].

### 2.10 File and scenario lifecycle
- Create New Scenario: name, description, type (skirmish / campaign / special), "Use existing map" (`.scmap`) or "Create
  new map" (Width / Height spin controls, Initial Elev., Water Elev., Deep Elev., Abyss Elev.) [decompile ref 00437f50,
  0043b6f0]. Open takes `*_scenario.lua` (maps must be in `/maps`; "might need /edit" path error) [decompile ref 00432170].
- Scenario Properties: Name, Description, Type, Script file (`*_script.lua`) [decompile ref 00446200, 00447780].
- Save writes `Scenario = {...}` with counters `next_area_id, next_army_id, next_group_id, next_unit_id,
  next_platoon_id, next_queue_id, next_platoon_builder_id`, plus Props, Areas, Markers, Chains, MasterChain, Orders,
  Platoons, Armies, Configurations [decompile ref 0048ec90, 004bca60, 004e0f50, 004b6120, 00496690, 004d0210]. This is the
  same `_save.lua` layout our `luaser.lua` targets.
- "Save and Run Game": launches the game with `/map <path>` ("Run current scenario?") [decompile ref 004458a0].
- Statistics dialog (stats / value list), Log window, Console with variable list, Dev Stats, Shadow Map view
  [decompile ref 00447d90, 00437340, `DisplayDevStats`, `DisplayShadowMap`].
- Remembers window positions per dialog (Layers, Tool, Resources, Console, Hotkeys, Statistics, Markers tree column
  widths, PlatoonBrowser, PropertiesDialog) [decompile ref strings `Windows.*`].

### 2.11 Camera and misc
- Camera is the game's world camera; "Reset View", camera marker with "canSetCamera / canSyncCamera" to copy camera <->
  marker orientation [decompile ref 004a4b70]. AutoSnap options (o-grid, terrain, land layer). Gizmos: Move, Rotate,
  Elevation, Scale, Group Rotate (`/textures/engine/editor_gizmo.dds`, `editor_group_gizmo.dds`) [decompile ref 0041e2d0,
  0041e3b0]. Copy / Paste / Lock selection / Select All of matching type.

---------------------------------------------------------------------------------------------------------------------

## 3. The FAF Unity map editor (ozonexo3/FAForeverMapEditor, last release v0.704-alpha, April 2021, MIT)

Source: **[web]** `github.com/ozonexo3/FAForeverMapEditor` (359 commits, 37 open issues of ~160, Unity project; scripts
in `Assets/Scripts`), local build `external_tools/FAForeverMapEditorBin` (v0.704-alpha, resources listed below).

### 3.1 Windows and tools (from `Assets/Scripts/UI`) [web]
- Windows: New Map, Armies window (`ArmysWindow`), Symmetry window, Last maps popup, Upload map popup (FAF OAuth login,
  broken, issue 149), Version-control popup (`AppMenu_VersionControll`: save as new version), generic popups, Settings
  (`FafEditorSettings`: FAF gamedata path, maps path, backup path, undo history length default 50, play-as faction,
  fog of war toggle, 2D markers, heightmap clamp, UI scale).
- Tools: Map info (scenario fields incl. author / credit / changelog / tools / url), Terrain (heightmap), Stratum, Terrain
  Type window, Water (+ waves), Lighting, Decals (list, settings, merge, selection), Props, Units (+ groups, browser),
  Markers (list, layers, selection options, new marker presets, adaptive tab), Areas, Armies, Ruler, Render Map (preview /
  minimap render), Resource browser, Unit browser.
- Misc: Neroxis map generator integration (`NeroxisGen/GenerateMapTask`, `Structure/Neroxis/toolsuite-all.jar` + IKVM
  plugin), "Generate random heightmap", map backups (`MapsBackup/<map>.v0001`), recent maps, drag-and-drop of files
  (`UnityWindowsFileDrag-Drop`), window state saver, tooltips, UI scaling.

### 3.2 Terrain editing (TerrainInfo.cs, PaintWithBrush.cs, BrushGenerator.cs) [web]
- Four brush types: **Standard** (raise/lower), **Flatten**, **Smooth**, **Sharp**. Keys: Tab = next type, 1-4 direct
  (also numpad); LeftAlt = invert; LeftShift = temporary smooth.
- Parameters: Size (1-256, max 512 since v0.605; issue 111 asked for more), Strength (0-100), Rotation (degrees, rotates the
  brush bitmap on the CPU; issue 143 made it a hotkey and dropped rotation brushes to 128), Target height (flatten level),
  Min and Max height clamp, plus optional "heightmap clamp" preference (never more than 50 units between lowest and
  highest point).
- Mouse/keys: hold V or S + drag = strength, hold B or W + drag = size, Q / + / = raises target, A / - lowers target
  (auto repeat 0.5 s then 10 / s), Ctrl + LMB / RMB / MMB sample terrain height into target / min / max, F = focus camera,
  G = grid, Ctrl + G = slope overlay.
- Symmetry (shared by terrain, strata, terrain type, props, decals, markers, units): 9 modes `sym0..sym8`: none, horizontal
  mirror, vertical mirror, both (point), 4-way, diagonal 1, diagonal 2, both diagonals, **rotational N** (N >= 2, "unsafe" when the
  field is briefly empty, issue 97); tolerance setting; paint positions are computed for each mirrored position
  (`PaintPositions[]`) and the brush bitmap is mirrored per position (`PaintImage[]`).
- Height I/O: import `.raw`, `.r16` (World Machine), `.bmp`; export `.raw`, `.r16`; wrong-size popup; clamp question when
  range > 50 [web: TerrainInfo.cs 487-700, release 0.606]. No PNG import (issue 124: users could not make a valid heightmap
  without Photoshop). Known conversion bug: BMP import scales by 0.567, capping heights at ~145 (issue 157).

### 3.3 Strata (StratumInfo.cs) [web]
- 10 layers (lower, 8 painted, upper) = two RGBA control textures; "TerrainXP" toggle for layers 5-8; order up/down; per-layer
  albedo + normal textures with scale sliders; preview buttons; brush: Size, Strength, Rotation, Target value, Min / Max
  **slope angle** limits (skips pixels outside the angle range), Scatter, **Linear brush** toggle (linear vs gamma-corrected
  blend), invert (Alt), smooth (Shift) [StratumInfo 760-870]. Brush strength curve = `(strength/100)^1.5 * 0.6`; alpha is
  `Clamp01(sample - 0.0255)` then `GammaToLinearSpace`.
- Terrain Type window (by Zkov): type layers + custom layers, pipette, erase, current layer, import / export, symmetry.

### 3.4 Brush storage [web + asset index]
- `Structure/brush/*.png` (any file in the folder is loaded at start; 11 files shipped) [asset index below, section 4].
- Applied as an R8 alpha mask scaled to the brush size by index (`x = i/size * width`, nearest neighbour, no filtering).

### 3.5 Objects [web]
- Props: browser, scatter / paint with Size, Strength, Min / Max, Scatter, free rotation, snap to ground, allow water level,
  per-prop edit, reclaim values from blueprints (mass / energy numbers coloured by value), clear all, random scale removed
  (does not work in game), prop selection / translation (0.605).
- Decals: list with counts (total / on screen), merge, settings (cutoff, shared values), selection, copy / paste.
- Units: browser (search by Name / CodeName), groups (double-click selects the group), placement mode, army colours, strategic
  icons, wreckage, range display (build range, PD T1-T3 from spawn points), warning "building too close to the edge (< 2.5)",
  real unit size selection box, 28 history types incl. unit move / remove / group change.
- Markers: layers panel (Basic / Paths / AI toggles, Blank, Spawn, Spawn ranges, Resources, Camera, Land / Amphibious /
  Naval / Air nodes, Connections, Rally, Combat, Defense, Prot. Exp., Expand, Other), marker presets (`MarkerPresets/
  pathnode_air_5x5 / 10x10 / 20x20 km.fafmapmarkers`, JSON), connected-node chains with line rendering (`RenderChainLine`,
  `RenderMarkersConnections`, `RenderMarkersWarnings`), 2D markers that scale with camera distance, Weather Generator /
  Definition markers, Effect markers, Objective marker, adaptive map tab (Cookie's `AdaptiveMap` script and options).
- Armies window: spawn markers per army, alliances, teams, colours; notification for odd/even spawn rule.
- Water: waves renderer + wave generator (v0.700), shore depth, reflection renderer, glow post effect.
- Lighting: info window with presets (54 campaign lighting thumbnails, `Presets/Tropical/*.scmlighting/.scmskybox/.scmst/.scmwtr`).
- Undo (`Undo/HistoryObjects`, 28 classes): area(s), army(ies), chain markers, decals (change / move / shared / values),
  lighting, map info, markers (change / move / remove), props (change / move), stratum (change / order / paint), terrain
  height, terrain type, unit group (change / remove), units (move / remove), water elevation / settings / waves.

### 3.6 Release history in one line each (what was added when) [web]
0.503-0.523 (2017-18): file save / heightmap / props reclaim; 0.600 (2018-06): armies, terrain type, units, unit groups,
unit browser; 0.601-0.605: marker categories, brush size 512, props translation; 0.606 (2020): heightmap clamp, credits
fields; 0.607: terrain type symmetry + import / export, adaptive symmetry, preview renders decals; 0.700 (2021-01): water
waves renderer + generator, random heightmap; 0.701: weather markers, strategic icons, duplicate (Ctrl+D), UI scale;
0.702: save-as copies map folder, custom `.scd` / `.nx2` gamedata loading; 0.703-0.704: fixes. No release since April 2021.

---------------------------------------------------------------------------------------------------------------------

## 4. Brush system

### 4.1 Every brush found

**GPG editor, inside `editor.scd` (VFS `/editor/...`)** [asset index `_asset_index/scd/editor.scd.tsv`, 63 rows]:

| Folder | Files | Size in bytes | Reading of the size [inferred] |
|---|---|---|---|
| `/editor/tools/elevation/` | `Errodeous01NE/NW/SE/SW.brush`, `Errodeous02NE/NW/SE/SW.brush`, `Errodeous03N/E/S/W.brush` (12 erosion-pattern brushes with compass variants) | 524,328-524,329 | 512 x 512 x 2 bytes (16 bit) + header |
| | `Peaks01.brush`, `Peaks02.brush`, `peaks_25_16_fwd.brush`, `peaks_25_16_bak.brush` | 524,323-524,331 | same, 512 x 512 u16 |
| | `Sluff__03.brush`, `Sluff__N/E/S/W_01/02.brush`, `Sluff__NE/NW/SE/SW_01.brush` (slump / landslide brushes, 13 files) | 524,325-524,328 | same |
| | `up10_4.brush`, `up10_20.brush` (raise ramps) | 2,097,186-2,097,187 | 1024 x 1024 x 2 bytes + header |
| | `round1k.brush`, `nround1k.brush` (round soft brush, and negative "n" version) | 4,194,339 / 4,194,342 | 4 MB payload: 1024 x 1024 x 4 bytes (32-bit) or 2048 x 1024 x 2; not decided |
| | `blur128.filter`, `sharp128.filter`, `unsharp128.filter` | 32,847-32,855 | 128 x 128 x 2 + header (convolution kernels) |
| | `unsharp128_hard.filter` | 2,097,244 | 1024 x 1024 x 2 + header |
| | `default.raze` | 32,803 | 128 x 128 x 2 + header |
| `/editor/tools/stratum/` | `round1k.brush`, `nround1k.brush` | 4.19 MB | same two round brushes |
| `/editor/tools/terrainType/` | `round1k_hard_interp.brush` | 2,097,199 | 1024 x 1024 u16 hard-edge round |
| `/editor/tools/water/` | `round1k.brush`, `nround1k.brush` | 4.19 MB | |
| `/editor/raw/` (plain 16-bit RAW) | `Default.raw` 32,768 (128 x 128), `Crater.raw` 32,768, `Mesa.raw` 8,192 (64 x 64), `up/down/left/right.raw` 8,192 (64 x 64 ramps), `chalk_hard_interp.raw` 131,072 (256 x 256), `round1k.raw`, `round1k_hard_interp.raw`, `round1k_hard_real.raw`, `neground1k.raw` (1024 x 1024, 2,097,152) | | headerless u16 square images |

Also in `editor.scd`: `/editor/tools/cartography/decalsplits.lua`, `/editor/tools/SkyDome/decalsplits.lua` (decal-split helpers,
text), `/editor/tools/water/wavepatterns.lua` (wave pattern table, text), `/editor/tools/water/nopreview.bmp`.

**FAF Unity editor, `FAForeverMapEditor_Data/Structure/brush/`** (8-bit greyscale PNGs, sizes from asset index):

| File | Bytes | Menu name shown |
|---|---|---|
| `brush0_standard.png` | 60,097 | Standard |
| `brush1_constant.png` | 24,380 | Constant |
| `brush1_sharp.png` | 48,538 | Sharp |
| `brush1_soft.png` | 61,805 | Soft |
| `brush2_crater.png` | 69,956 | Crater |
| `brush2_hexa.png` | 5,262 | Hexa |
| `brush2_piramid.png` | 5,677 | Piramid |
| `brush2_square.png` | 10,899 | Square |
| `brush3_noise.png` | 11,463 | Noise |
| `test_mountain.png`, `test_mountain2.png` | 9,415 / 9,915 | Mountain, Mountain2 |

Other editor data folders in the Unity build: `Structure/LightingPresets` (54 PNG thumbnails SCMP_001..040, X1CA_TUT, X1MP_001..017),
`Structure/Presets/Tropical` (4 preset files), `Structure/MarkerPresets` (3 JSON node grids), `Structure/Waves/wavepatterns.lua`,
`Structure/AdaptiveMap` (README + 3 Lua templates), `Structure/MapUpload/config.txt` (ships API client credentials in plain
text: security smell, see section 6), `Structure/Neroxis/toolsuite-all.jar` (19 MB generator).

### 4.2 How the GPG brush files work (decompile)
- In memory a `sce::Brush` holds: a name (std::string), parameters (`+0x20/+0x24` = width/height, `+0x28` = u16 sample
  array), a **256 x 256 float table** (0x40000 bytes, initialised to a constant), a **256 x 256 byte mask** (0x10000 bytes,
  initialised to 0xFF) and a `wxImage` for the thumbnail [decompile ref 00402fc0]. `FilterBrush` adds an embedded
  `Filter<unsigned short>` (the kernel: "Impulse" ctor `FUN_0040b300`) [decompile ref 0040a6c0]. So the brush is a square
  16-bit greyscale image plus a resampled 256 x 256 working copy and a thumbnail.
- **RAW import** (`FUN_00403240`, called by the "RAW Brush File" file dialog in all six brush tools: elevation 00458570,
  filter 0045ae50, raze 0045cd70, strata 00467240, water 0047df70, terrain type 00500b70 / 00501a90): the file size must be
  even; sample count = size / 2 must be in a **13-entry table of allowed counts** (data table at 0058ac0c; consistent
  with square powers of two 1 x 1 ... 4096 x 4096 [inferred]); then samples are read as little-endian u16, row by row; the
  brush is resampled to 256 x 256 for display (`FUN_00404090`). A file that is not a valid size is rejected silently.
- **`.brush` / `.filter` / `.raze` save**: one "Save Brush" file dialog per tool (wildcards `*.brush`, `*.filter`, `*.raze`;
  004588b0, 0045b190, 0045d0b0, 00467580, 0047e2b0, 00500eb0). The files are an engine archive, not plain RAW: the sizes
  differ by exactly one byte per character of the brush name (`Peaks01`, 7 chars = 524,323 bytes; `Errodeous01NE`, 13
  chars = 524,329, i.e. +6), so the **name is stored in the file**; the header is about 28 bytes + name, the rest u16 samples [inferred
  from byte counts only; the archive reader was not traced]. A brush list loads every file of its tool folder
  (`/editor/tools/<layer>/`), and "directories dummy" placeholders exist (`dummy` files, 44 bytes).
- **Application** (`FUN_0045ed00`, the per-stroke inner loop): per pixel, `result = clamp(old + (target - old) * mask *
  strength * k)` where `mask` is the u16 brush sample under the pixel, the result is clamped to 0 .. 65535 (the u16 height
  range) and written back as u16 into a tile buffer; strokes cover the field in tiles of 0x28-byte descriptors
  (`FUN_0045e3f0` iterates tiles intersecting the dab rectangle) [decompile ref 0045ed00, 0045e3f0, 0045eb50]. The
  operation `target` comes from the tool: Brush = raise or lower (`Invert` flips sign), Filter = convolve with the kernel,
  Raze = fixed target height, Stamp = absolute pattern. Strata / water / terrain type brushes use the same stroke engine on
  u8 masks (`BrushStroke<unsigned char>`).
- Parameters per tool: Elevation Brush = Strength, Size, Minimum, Maximum; Filter = Strength, Size + filter kernel;
  Raze = Size, Target; Strata / Water / TerType = Strength, Size (water brush: channel Flatness / Foam / Depth Bias).
  No rotation, spacing, flow, scatter or falloff curve exposed. Brush rotation is not a feature of the original editor
  (compass-variant brushes `*N/E/S/W/NE/...` exist instead: rotation is baked into files). Hotkeys change Size and the
  Height / Target by steps.

### 4.3 How the Unity brushes work (source)
- Loader: `BrushGenerator.LoadBrushes` reads **all files** in `Structure/brush` (no extension filter), `Texture2D.LoadImage`
  (so any PNG/JPG size and bit depth, converted to 8 bit, uses the red channel), label = text after the last `_` of the file
  name without extension, capitalised; order = file system order (the `brush0_..brush3_` prefix is a sort key)
  [web: BrushGenerator.cs 56-93].
- Dab: size in map pixels, position `int` truncation, brush sampled by nearest neighbour; mask threshold `>= 0.02`
  (height) / `>= 0.003` (strata) [web: PaintWithBrush.cs, StratumInfo.cs]. Heights: Standard adds `mask * strength * 0.0002`
  per dab; Smooth lerps toward the dab mean by `strength * 0.4 * mask^2 * |delta|`; Sharp pushes away from the mean;
  Flatten pulls toward the target height. All clamp to `[min,max]`. Strength has a response curve (`HeightmapPaintStrength`,
  `HeightmapBlurStrength` animation curves).
- Symmetry creates per-position copies of the brush bitmap (mirrors, rotations by `Quaternion`), so each symmetric dab is
  exact only to integer rounding (issue 74: "symmetry offset by 1 pixel").
- Rotation by CPU `rotateTexture` of the whole brush bitmap (cheap at 128, slow at 512; issue 143).
- GPU preview: the brush texture is also set on the terrain material (`_BrushTex`, `_BrushSize`, `_BrushUvX/Y`) to draw the
  ring/preview.

### 4.4 Recommended dynamic brush-menu design for the FAF Studio

Goal: any greyscale PNG / DDS (also 16-bit PNG, RAW, R16, BMP, TGA) dropped into a folder becomes a brush without code or restart.

1. **Brush registry in the binary, one native**: `ed.brush_scan(dirs)` returns `{id, path, stamp, w, h, bits, kind}`; decoding
   and mip chain in native code (we own `edcore` `dds.cpp`; add a PNG/BMP/RAW/R16 reader). Lua builds the menu from the list.
2. **Search path (higher wins)**: `<project>/brushes/`, `<EditorData>/brushes/` (user, drop folder), `<mod>/editor/brushes/**`
   (mods ship brushes), VFS `/editor/brushes/` (shipped defaults), read-only legacy `/editor/tools/*/*.brush|.filter|.raze`
   and `/editor/raw/*.raw` from `editor.scd` through the VFS (so all original GPG brushes appear). Subfolder = group
   (`height/`, `strata/`, `terraintype/`, `decal/`, `prop/`, `stamp/`); a root-level file is offered to every tool.
3. **File conventions**: no naming magic required (Unity's `brush1_soft.png` -> "Soft" trick still accepted). Label = file
   stem with `_`/`-` -> spaces. Optional sidecar `<name>.brush.lua` with: `label`, `group`, `tools = {...}`,
   `mode = 'relative'|'absolute'`, `invert`, `gamma`, `levels = {black, white}`, defaults for `size`, `strength`,
   `spacing`, `rotation`, `scatter`, `falloff` (applied on top), `tile` (repeat as pattern), `author`.
4. **Pixel semantics**: luminance of RGB, or alpha if the image has alpha and is otherwise uniform; 16-bit sources keep
   16-bit precision; sRGB PNGs are treated as **linear data** (brush masks are not colours) unless the sidecar says
   `gamma`; auto-levels toggle in the import dialog for low-contrast images; max 4096 x 4096.
5. **Two kinds of brush**, both selectable from the same menu: *relative* (mask multiplies the stroke effect; all Unity
   brushes, GPG `round1k`) and *absolute / stamp* (the image is a height pattern, e.g. `Mesa.raw`, `Crater.raw`, ramps, the
   Peaks / Errodeous / Sluff brushes: placed at `base + (pixel - 0.5) * height_scale`, with blend/mask edge). Sidecar
   `mode` decides; default heuristic: images with a 50 % grey average are treated as absolute (signed) stamps.
6. **Procedural brushes** (circle, square, hex, star, noise) live as Lua functions `f(u,v) -> 0..1` in the same registry with a
   falloff curve editor (hard / linear / smooth / bell / custom spline), so the menu mixes image and procedural entries.
7. **Dab engine** (native): float world-space dab centre (no int truncation; subpixel offset fixes symmetry rounding);
   brush sampled bilinearly from a pre-built mip chain (pick mip by on-screen size; GPG used 256 float table, Unity nearest);
   rotation applied by sampling transform (no bitmap rotation); spacing as percentage of size; flow vs opacity per dab and
   per stroke; random rotation / scatter / size jitter per dab; stroke stabiliser. Symmetry replays the same dab through a
   point transform (mirror, rotate N, diagonal) instead of regenerating bitmaps.
8. **Per-tool application rules** (one table, data not code): heights (relative add with min/max, flatten to target,
   smooth, sharpen, plateau / terrace, ramp, erode via the legacy erosion stamps), strata (mask value toward target,
   optional slope range and height range like Unity's Min/Max angle, gamma vs linear blend), terrain type (index fill, no
   blend), water masks (flatness / foam / depth bias channels), decals and props (density / spray, using the brush as a
   probability map, min distance, slope falloff 20-60 like GPG's autoplace).
9. **Menu UI**: grid of thumbnails (generated once, cached as DDS next to the registry), group tabs, search box, favourites,
   recent list, per-tool filter by sidecar tags, drag-and-drop of image files onto the panel (native copy into the user
   folder + instant refresh), right-click "reveal in folder / edit sidecar / delete", live brush ring and heat-map preview
   on the terrain, hotkeys: `[` `]` size, `Shift+[`/`]` hardness, `Ctrl+drag` rotation (GPG: Equals/Minus size, brackets
   height, backslash invert; Unity: B/W size, V/S strength, E rotate), numeric entry for every value.
10. **Hot reload**: poll folder stamps (CDiskWatch in the engine tree, edit-mode only) so a brush saved from an image editor
    updates in the menu and in the preview within a second.
11. **Import/export of legacy brushes**: read `.raw` (any square size, 16-bit LE), `.brush/.filter/.raze` (header guess +
    u16 body; verify against `Peaks01.brush` byte count 524,323 before trusting the header layout), and write-through
    "Save brush from selection" as 16-bit PNG + sidecar (round-trips, opens in any image editor).

---------------------------------------------------------------------------------------------------------------------

## 5. Comparison table

Legend: Y = present, P = partial, N = absent, ? = not verified. Decompile refs are addresses in `SCEditor.exe.c`.

| Feature | GPG editor | FAF Unity editor | Where in the GPG decompile | Notes for our editor |
|---|---|---|---|---|
| Heightmap raise / lower brush | Y (Strength, Size, Min, Max) | Y (Standard, Strength 0-100, Size 1-512) | `ElevBrushTool` 004574a0, 0045ed00 | We have raise/lower/flatten/smooth/noise in `terrain.lua`; add rotation, spacing, flow |
| Flatten to level | Y as Raze (Target height) | Y (Flatten, Ctrl+click samples height) | `ElevRazeTool` 0045c050 | Add "pick height" modifier like Unity; target keys like GPG brackets |
| Smooth / sharpen | Y as convolution filters (Impulse, Sharpen, Unsharpen, Blur N/S/W/E) | Y (Smooth, Sharp, Shift = smooth) | `ElevFilterTool` 00459bf0 | Keep kernel idea; make kernel a registry item |
| Invert effect key | Y (Backslash) | Y (Alt) | 004164c0, 00419fb0 | Both |
| Brush images | Y 16-bit `.brush`, RAW import | Y 8-bit PNG folder | 00403240, 004574a0 | Section 4.4 |
| Brush rotation | N (rotation baked into compass variants) | Y (CPU, field + E key) | n/a | Sample-transform rotation, random / follow stroke |
| Brush size limit | 256-wide working table, big files resample | 512 | 00402fc0 | Allow >= 2048 in world units (issue 111) |
| Height clamp (min/max) | Y | Y + global "50 units" clamp preference | 004574a0 | Per-brush and per-document limits |
| Stamp heightmap patterns | Y (`Stamp` action, `/editor/raw`) | N (via brush images) | 00419fb0 | Absolute-mode brushes |
| Symmetry | N (not found in strings) | Y 9 modes incl. rotational N | n/a | Needs float-exact replay; apply to every object tool; share one symmetry definition |
| Heightmap import / export | Y `.raw` (+ black / white rescale) | Y `.raw`, `.r16`, `.bmp` import; no PNG | 00455830, 00456540 | Add 16-bit PNG, TIFF-less pipeline, auto-scale dialog, tile import |
| Random terrain generator | N | Experimental random heightmap + Neroxis jar | n/a | Generator runner already planned (parity table) |
| Strata layers | Y 10 layers, albedo + normal + repeat rates, mask import / export | Y 10 layers, scale sliders, order up / down, XP toggle, previews | 00464ef0, 00440680 | Add reorder, per-layer blend preview, layer groups |
| Strata brush | Y (Strength, Size, Erase tool) | Y + slope range, linear-blend toggle, scatter, target value | 00466580, 004683a0 | Unity's slope range is valuable; add height range and curvature |
| Strata auto-paint by slope / height | N | P (slope limits only while painting) | n/a | Rule-based auto-strata (slope, height, noise) as a pass |
| Terrain type | Y brush + mask import | Y window, custom layers, pipette, symmetry, import / export | 004204e0 | Link to strata (issue 119), overlay |
| Water properties | Y full set + textures + normal movement | Y same + waves renderer | 00479710 | Sun/reflection preview live |
| Water masks (foam / flatness / depth bias) | Y brush | P (info only; v0.700 waves) | 0047cfc0 | Brush with channel select |
| Wave generator | Y (patterns Lua, Generate / Reset) | Y (renderer + generator, undo) | 0047eff0, 00480910 | Keep pattern Lua; add shoreline auto |
| Lighting | Y RA / Dec sun, colours, bloom, fog, env lookup textures | Y info window, presets, thumbnails | 00460730 | Presets + live sun gizmo; ship all 54 campaign presets as text |
| Skybox / cube map | Y (Background, Sky Cube) | Y procedural skybox + presets | 00460730 | Use engine's sky |
| Decals | Y properties, edit tool, LOD cutoff, groups, memory stats | Y list, merge, settings, selection | 0046d170, 0046fe30, 004486d0 | Add decal brush / scatter with the brush registry |
| Props | Y browser tab, autoplace spray (radius, min distance, rate, slope falloff 20-60) | Y scatter / paint, reclaim display colours, free rotation, snap | 0048a960 | Same registry as brushes; reclaim totals live |
| Prop rotate gizmo with pitch / roll | Y (Ctrl / Shift) | P (E key rotate) | 0048a960 | Full gizmo |
| Marker types | Y data-driven `MarkerTemplates.lua` | Y built-in enums + presets (path-node grids) | 00496980 | Read `MarkerTemplates.lua` so mods add types |
| Marker chains / graphs | Y chains + master chain | Y connected nodes with lines + validation | 0049da20, 00493c90 | Graph editor with live reachability check |
| Areas | Y rectangles | Y | 004a93e0 | Add polygon later |
| Armies / teams / alliances | Y panel, game configurations, no-rush | Y armies window, adaptive map tab | 004bfe70, 004d3090 | M6 mission suite |
| Unit placement | Y groups, tree drag-drop, orders, stacked check | Y browser, groups, army colours, ranges, strategic icons | 004c4d80, 004292e0 | Keep stacked-unit validator; add collision / footprint snapping |
| Unit orders in editor | Y 34 order types as Lua | N | 004b1190 | M6; reuse `ScenarioFramework` outlines |
| Platoon builders | Y with function specs from OpAI Lua | N | 004d82b0, 004e1400 | M6; read `_EditorFunctions.lua` specs |
| Object copy / paste / duplicate | Y copy / paste | Y Ctrl+C / V / D | `ActionCopy/Paste` | Include "paste with offset", array/radial duplicate |
| Undo / redo | Y EditStack, compound edits, mementos; some edits "cannot be undone" | Y 28 history classes, default depth 50, setting | 0041ceb0, 0046d170 | One command stack with unlimited (disk-backed) depth |
| Hotkeys | Y user-rebindable, searchable dialog | N (fixed; issue 143 added E) | 0043c710 | Rebindable keymap saved per user |
| Layer / mode switching | Y F1-F11 | Panel tabs | 00419fb0 | Both |
| Gizmos | Y Move / Rotate / Elevation / Scale / Group Rotate | Y | 0041e2d0 | Add numeric entry |
| Overlays | Y intel, weapon ranges, skirts, grid, areas, slope, wireframe | Y ranges, slope, grid, spawn ranges, markers 2D | 004292e0, 004284f0 | Add unit-footprint, buildability, nav graph, mass density overlays |
| Run in game | Y "Save and Run Game" | P ("Play Map", crashes, issue 151) | 004458a0 | Our in-process play/stop (M1) |
| Export/import of parts | Y lighting, water, strata theme, props, decals as Lua | N | 0042abf0, 0042b230, 0042bb70 | Keep: reusable "style" files; add share/import between maps |
| Map statistics | Y statistics dialog | P decal count | 00447d90 | Validation panel (design doc section 4) |
| Resource browser | Y tileset / category / stratum / decals / splats / props with drag-drop | Y resource + unit browser | 00442c10 | Persistent asset database, mods first class |
| Window state | Y `Editor.prefs`, per-dialog geometry | Y window state saver | 0041ee50 | Docking + layout presets |
| Backups / versions | N | Y `MapsBackup/<map>.v0001`, save-as-new-version | n/a | Backup on every save, diffable `_save.lua` |
| Preview / minimap render | N | Y render map (decals, no ranges) | n/a | Add (parity table) |
| Upload to FAF | N | Y but auth broken (issue 149) | n/a | Out of scope; export package only |
| Console / log | Y console variable dialog, log window | Y editor log | 00437340 | Keep, add Lua REPL (`/edcmd`) |
| Platform | Windows 32-bit wx 2.4 | Unity (Win) | n/a | Own exe on the recovered engine |

---------------------------------------------------------------------------------------------------------------------

## 6. Things both editors do badly or lack

Evidence: Unity issue tracker (open and closed) **[web]** unless stated; GPG items from the decompile.

### 6.1 Unity editor (documented complaints)
1. **No release since April 2021** and 37 open issues; maintainer inactive (issue 110 "is this still being worked on?").
2. **Instability on load / unit lists**: "Cannot finish loading unit list" (152), "Fixed units not showing" (156), "Texts do not
   draw" (148), "Play Map crashes" (151), campaign map 3 does not open (147), crash on Ctrl+Z after water toggle (92, closed).
3. **Unit names lost on open** (144, open) -> broken scripts; unit IDs saved upper case (118, fixed); chains re-sorted after save (145).
4. **Heightmap import pain**: no PNG, BMP scaling bug at 0.567 (157), users could not import without Photoshop (124),
   brush max size too small for big maps (111; raised to 512 only), no brush rotation for long (117).
5. **Symmetry**: not applied to terrain type and adaptive markers originally (130; fixed in 0.607), 1-pixel offset (74, open),
   typing in the rotation count field breaks the editor (97).
6. **Asset reload**: map decals/assets are cached, edits to images need a restart (142); custom paths in `.scmap` cannot be
   edited (136); no army colours on units (140); selection frame invisible for small units when zoomed out (135).
7. **Missing features** requested: copy / paste (109, done), group content tree like GPG (108, open), "only selected group mode"
   (85), custom unit presets (72), reclaim UI (86), rotate prop groups to terrain (88), glow (98), odd/even spawn notice (77),
   weather dropdown values (139), window can be saved off-screen (95), UI scale breaks selection box (146).
8. **Brushes**: nearest-neighbour sampling, integer positions, no spacing/flow/jitter, brush list order depends on file name,
   brush folder not hot-reloaded (loaded once at start), no user-facing way to add brushes except copying files.
9. **Upload feature hard-wired** to FAF OAuth with credentials in `Structure/MapUpload/config.txt` (issue 149 says the
   flow will stop working; issue 112 asked to remove it).
10. **Performance**: unit and decal heavy maps slow (render pipeline tuning in release notes, decal count display added to
    diagnose); preview renders non-playable area (84, fixed).

### 6.2 GPG editor (from the decompile; user complaints beyond this were not retrievable)
1. **Single heightmap resolution quirk**: brush working table is fixed at 256 x 256; RAW import accepts only a fixed list of
   sizes (13-entry table), otherwise fails silently.
2. **No symmetry, no brush rotation, no spacing / flow / falloff controls, no random scatter** (no such strings anywhere).
3. **Undo gaps**: explicit "WARNING: The following cannot be undone" for decal type / texture changes; platoon builder edits
   have a manual save-or-discard prompt; no undo for army creation by drag-drop (feature refused).
4. **Fragile file handling**: errors reported as strings only ("Unable to open file for export / reading / writing"); chain
   order legacy bug ("may not be preserved after loading"); `FUNCTION SPEC ERROR` messages when OpAI function specs mismatch;
   "might need /edit" path translation error when a map lies outside `/maps` [inferred cause of crashes on large or odd
   maps, not proven].
5. **UI**: wxWidgets 2.4 dialogs, one properties panel for everything, tiny preview lists (64 x 64 icons), no search in
   most lists (only hotkeys have "Find Command"), no recent-brush list.
6. **No automatic backups, no versions, no preview render, no validation** (only stacked-units warning on save and name
   uniqueness for markers / chains).
7. **Strengths to keep**: Unity issues 127 and 108 say the GPG editor shows unit icons at any zoom and lists group contents,
   which the Unity editor lacked.
8. **32-bit process** limits large maps (we are x64 on the recovered engine) [inferred].

### 6.3 Gaps shared by both (opportunities for our editor)
- No **procedural terrain tools** beyond brushes: hydraulic / thermal erosion, terracing, ridge / valley generation, noise
  layers, stamp libraries with random variants (GPG ships erosion stamps but no erosion simulation).
- No **non-destructive layers** for terrain (everything baked into one heightmap); no layer masks, no blend modes.
- No **rule-based painting**: slope / height / curvature rules for strata and props are manual (Unity has slope limits only).
- No **validation** that checks playability: start positions, mass fairness, path connectivity (the engine can do this live),
  naval connectivity, expansion counts, file size limits.
- No **live play-test loop** without leaving the editor, no time slider / snapshot.
- No **extensible tools**: brushes and tools are compiled or fixed folders; no mod/Lua API for tools (we plan Lua tools).
- No **multi-map workflows**: copy objects, styles, strata themes and lighting between maps (GPG has export/import files,
  Unity has presets) with a single library browser.
- No **mesh-terrain** support (our M5) and no support for >20 km maps with tiled editing.
- No **collaboration-friendly saves**: stable text diffs (we have sorted-key `luaser.lua`), no merge tool.
- No **accessibility / documentation**: tooltips only; no in-editor docs or tutorial maps.
- Both treat the **Lua mission side** (triggers, objectives, ScenarioFramework calls) as text-editor work (M6 opportunity).

---------------------------------------------------------------------------------------------------------------------

## 7. Suggestions for the roadmap (short)

1. Build the brush registry and the dab engine first (M3 dependency, small, high value): folder scan, PNG/DDS/RAW decode,
   mip chain, thumbnails, sidecar, float dab with symmetry replay; reuse `terrain.lua`'s `Brush` as the default procedural entry.
2. Import legacy brushes from `editor.scd` at first start (read through the VFS, convert to PNG-16 plus sidecar into
   the user folder) so the 60-odd GPG erosion / sluff / peak stamps and `Crater/Mesa/ramp` RAWs are immediately available.
3. Copy GPG's good ideas: data-driven marker templates, export / import of lighting / water / strata "themes", hotkey
   editor with search, F1-F11 mode keys, props autoplace spray, function-spec driven platoon editor.
4. Copy Unity's good ideas: symmetry (all tools), slope-limited strata painting, linear/gamma strata blend, pick height from
   terrain (Ctrl+click), V/B-drag brush strength and size, heightmap clamp, marker layers, adaptive map tab, versioned backups,
   Neroxis runner, preview render.
5. Fix known failures by design: float symmetry, 16-bit PNG import, brush size in world units, hot reload of assets,
   validation panel, rebindable keys, native undo stack with disk backing.

Open items to verify later: the `.brush` archive header layout (trace the Archive reader or compare with a second sample),
the real contents of the 13-entry size table (`DAT_0058ac0c`), what the third bitmap button of the brush list does, whether
`Stamp` loads from `/editor/raw`, and exact default hotkey pairs (read the `ActionManager` default table at 0041c3b0 and
`FUN_00419d10`).
