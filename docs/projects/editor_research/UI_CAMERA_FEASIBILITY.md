# FAF Studio: UI shell and camera feasibility (research, 2026-10-17)

Read-only study. Question: can a Blender / Photoshop style UI (docking, tabs, saved layouts, UI scale, overlay
scrollbars, node graph, drag-and-drop) and a free editor camera be built on the recovered engine's Maui UI system, and
what must change in the C++? Context: [MAP_EDITOR.md](../MAP_EDITOR.md), [MAP_EDITOR_DESIGN.md](../MAP_EDITOR_DESIGN.md)
(rules 6 and 7).

Evidence tags: **[V]** read in the source (path:line), **[I]** inferred from names or structure, **[O]** open, needs a
run. Paths: `ENG` = `engine_decomp/faf-re-upstream/src/sdk/moho`, `FAF` = `faf_repo/fa`. `UiRT.cpp` = `ENG/ui/UiRuntimeTypes.cpp`
(28,927 lines; it holds every Maui control, the event mapper, the keymap and the world view).

Numbers marked *estimate* are not measured. Section 3.4 gives the 20-line benchmark that replaces them with facts
before the docking code is written.

## 0. Verdict in six lines

1. Maui is enough for panels, tabs, lists, text fields, tooltips, menus and drag and drop, **written in Lua on top of
   `Group`/`Bitmap`/`Text`/`Edit`/`ItemList`/`Dragger`**. It is a retained tree of lazy-variable layouts with no
   clipping, no scissor, no vector drawing, no rotation and no render-to-texture for panels.
2. **One new native control (`CMauiCanvas`, a retained draw list with clip) removes the three real blockers** at once:
   node-graph wires and nodes, clipped scroll areas and curve/timeline widgets. Everything else is small natives.
3. The FAF-specific Lua globals the stub files advertise (`UI_DrawLine`, `CopyToClipboard`, `SetColorMask`,
   `ProjectMultiple`) are **binary patches that do not exist in the recovered engine** (grep of `ENG`: zero hits). They
   must be written natively or avoided.
4. The camera is an orbit camera around a terrain-snapped focus point. **Orbit, pan, zoom-to-cursor, focus, top view,
   bookmarks and WASD-pan work from Lua today** (`Camera:SnapTo`, `SaveSettings`, `WorldView:ZoomScale`). A true
   fly camera, side orthographic views and an FOV control need about 150 lines in `CameraImpl.cpp`.
5. Biggest unknowns: Lua lazy-variable cost during live panel resize (measure first), keyboard routing without
   `IN_BindKey` (design in 4.6, untested), DPI awareness (none today).
6. Recommended order: widget kit and docking in Lua first (no C++), the canvas control second, camera Lua controller
   third, camera C++ fourth (section 5).

---

## 1. Maui capability inventory

### 1.1 Controls

| Control (Lua class) | Native class, where | What it really does | Limits for us |
|---|---|---|---|
| `Group` | `CMauiGroup`, `UiRT.cpp:12436` (no `DoRender` of its own) | Pure container; lazy-var rectangle | **No clipping of children**, no layout logic |
| `Bitmap` | `CMauiBitmap`, `UiRT.cpp:22817`, `DoRender` `:22918` | Textured quad per animation frame; `SetUV(u0,v0,u1,v1)` (atlas / sprite sheet), `SetTiled`, `UseAlphaHitTest`, `InternalSetSolidColor`, frame animation | Axis-aligned only, no rotation. Quad is clipped to its own rect via `DRAW_ClippedQuad` (`ENG/render/d3d/CD3DPrimBatcher.h:603`) |
| `Border` | `CMauiBorder`, `UiRT.cpp:25271` | 6 textures: 4 corners, 2 edge textures (vertical, horizontal), **stretched not tiled**, **no centre piece**; `SetSolidColor` | Not a true 9-slice. Lua `NinePatch` (`FAF/lua/ui/controls/ninepatch.lua`) builds 9 bitmaps instead |
| `Text` | `CMauiText`, ctor `:12828`, `DoRender` `:16379` | One line, UTF-8, drop shadow (+1,+1), centering, `SetNewClipToWidth` (cuts glyphs at control width), advance and ascent exposed as lazy vars | No wrap (Lua `MultiLineText` makes one `Text` per line), no outline, no rotation, no rich text |
| `Edit` | `CMauiEdit`, `UiRT.cpp:23293`, keys `:24041` | Single line, caret, selection, Home/End/word jumps, **Ctrl+C/V/X work** (`WIN_GetClipboardText`, `ENG/app/WinApp.cpp:3107`), `OnCharPressed`/`OnEnterPressed` hooks | Single line only, no numeric mode, no undo, no IME composition [O] |
| `ItemList` | `CMauiItemList`, `UiRT.cpp:12880`, `DoRender` `:13812` | **Native virtual text list**: draws only visible rows; selection, hover, scroll API; thousands of strings are cheap | Rows are plain text of one font; fixed row height `mHeight + mExternalLeading` |
| `Scrollbar` | `CMauiScrollbar`, `UiRT.cpp:15643` | Texture-based bar bound to a "scrollable" control through `GetScrollValues / ScrollLines / ScrollPages / ScrollSetTop` | Always drawn, needs 4 textures. We write our own overlay bar (3.5) |
| `Histogram` | `CMauiHistogram`, `UiRT.cpp:12523` | **`DoRender` is empty** (`:12561`, stub says "unimplemented") | Dead shell, but a free host class (see 2.1) |
| `Dragger` | `CMauiLuaDragger`, `UiRT.cpp:1461` | `PostDragger(frame, keycode, dragger)`: engine calls `OnMove/OnRelease/OnCancel` with **screen coordinates and mouse capture** (`SetCapture`, `UiRT.cpp:9226`) | The tool for splitters, window drag, tab drag, in-app drag and drop |
| `MapPreview` | `CUIMapPreview`, `UiRT.cpp:17462`, `DoRender` `:17581` | Draws any `ID3DTextureSheet`, aspect-fit; `SetTexture(path)`, `SetTextureFromMap` | Texture by path only today |
| `Mesh` (`maui/mesh.lua`) | `CMauiMesh`, `ENG/ui/CMauiMesh.cpp` | **Render-to-texture thumbnail of a mesh blueprint**: allocates a dynamic texture sheet of the control size (`NewDynamicTextureSheet`), `REN_RequestThumbnail`, draws it as a quad (`:104-170`) | Needs an active `CWldSession` (`:93`, true in the editor). Perfect for prop/unit previews |
| `WorldMesh` | `CUIWorldMesh`, `ENG/ui/CUIWorldMesh.cpp` | A mesh instance in world space (not a 2D control) | For gizmos and previews inside a second `WorldView` |
| `WorldView` | `CUIWorldView`, `UiRT.cpp:18262`, `ENG/ui/CUIWorldView.cpp` | 3D viewport with its own `CameraImpl` by name; the minimap is a second instance (ctor arg `isMiniMap`). `Project`, `UnProject`, `ZoomScale`, `LockInput`, `SetOrthographic` | More than one is supported by design [V: engine ships a minimap]. Cost per extra view = a full terrain pass [O] |
| `Movie`, `Cursor` | `CMauiMovie`, `CMauiCursor` `UiRT.cpp:3879` | Cursor = a texture plus hotspot (`SetNewTexture(file, hx, hy)`), animated in Lua (`maui/cursor.lua:39-67`) | No system cursors; resize/move/text cursors are our own textures |
| `Frame` | `CMauiFrame`, `UiRT.cpp:24489` | One root per **head**; `GetFrame(head)`, `GetNumRootFrames()` | See 1.7 multi-window |

Lua-only controls in `FAF/lua/maui`: `Button`, `Checkbox`, `RadioButtons`, `Slider`, `StatusBar`, `Grid`, `MultiLineText`,
`Window` (609 lines), plus `lua/ui/controls` (`combo`, `filepicker`, `ninepatch`, `popups/inputdialog`, `columnlayout`,
`textarea`). All are skinned with game textures; for a modern look we write our own thin kit (3.3).

### 1.2 Layout system

- Every control owns 7 **lazy variables** (`Left Top Right Bottom Width Height Depth`, `FAF/lua/maui/control.lua:ResetLayout`,
  default is a circular system that needs 4 of 6 defined). `FAF/lua/lazyvar.lua` (347 lines): a lazy var caches `self[1]`,
  tracks `uses` / `used_by` tables, evaluates its closure inside `pcall` (`:68-75`) and propagates `SetDirty` recursively
  to all dependents. C++ reads them through `CScriptLazyVar_float::GetValue`; a dirty value calls back into Lua.
- `LayoutHelpers` (`FAF/lua/maui/layouthelpers.lua`, 2,367 lines): 100+ helpers (`AtLeftTopIn`, `FillParent`,
  `Below`, `AtHorizontalCenterIn`, `SplitHorizontallyIn` `:1058` ...) plus the fluent `Layouter`. All pixel offsets are
  multiplied by **`pixelScaleFactor`** (`:35`, read once from the profile option `options.ui_scale`; `ScaleNumber`
  `:57`, `SetPixelScaleFactor` `:44`). The option offers 0.8 .. 2.0 and is marked `restart = true`
  (`FAF/lua/options/options.lua:922-937`). `Text:SetFont` multiplies the point size by `ScaleNumber`
  (`FAF/lua/maui/text.lua:62`). **Scale is not reactive**: a closure re-reads the upvalue only when it is re-evaluated.
  Live UI scale therefore means "call `SetPixelScaleFactor` then destroy and rebuild the panel tree from the layout
  data". That is fine for a data-driven UI (3.1).
- `Depth` defaults to parent depth + 1; `DepthOverParent` / `Over` order siblings. `CMauiControl::Render`
  (`UiRT.cpp:22110`) flattens the subtree and sorts it by depth whenever a control is created, destroyed, reparented
  or changes depth; `CMauiFrame::RenderChildControls` (`:22160`) then walks that **flat list**. Consequence: z-order is
  global per frame, children are not drawn "inside" their parent.

### 1.3 Event model

All mouse events: one `wxMouseEvent` handler (`CMauiWxEventMapper::OnMouseMove`, `UiRT.cpp:9549`).

- **Hit test**: `CMauiControl::GetTopmostControl` (`:22462`) scans the whole subtree depth-first and takes the visible,
  hit-testable control with the highest depth under the cursor (hidden controls still cost a visit). `Bitmap` can hit-test
  by alpha. O(controls) per mouse event, reading cached lazy vars [V]; cheap in C++ even for thousands.
- **Delivery**: `PostEvent` (`:22493`) calls Lua `HandleEvent(self, event)` on the hit control; if it returns false it
  **bubbles through all parents** (return true stops). `event` fields: `Type` ("ButtonPress", "ButtonRelease",
  "ButtonDClick", "MouseMotion", "MouseEnter", "MouseExit", "WheelRotation", "KeyDown", "Char", "KeyUp"),
  `KeyCode`, `RawKeyCode` (VK), `MouseX/Y` (client pixels), `WheelRotation/WheelDelta`, `Modifiers` table with
  `Shift Ctrl Alt Left Right Middle` (`FAF/engine/User/CMauiEdit.lua:1-60`; builder `UiRT.cpp:9444-9488`).
- **Double click** arrives as `ButtonDClick` instead of the second `ButtonPress` (`:9618, :9699`); handlers must treat both.
- **Mouse enter / exit** are synthesised from the topmost control changing (`:9600-9615`), so a child under the cursor
  makes the parent receive "exit" and the child "enter"; keep hover logic on the leaf or use rect tests.
- **Wheel**: delivered to the hovered control, then bubbles; vertical only (wx 2.4.2).
- **Capture**: only through `Dragger` (mouse capture while a drag lives). `AddInputCapture(control)` **re-roots hit testing
  at the capture control** (`ResolveTopInputCaptureControl`, `UiRT.cpp:1938, :9567`), so everything outside the capture
  control stops receiving mouse events. `MAP_EDITOR.md` already recorded this trap. For popups use a full-screen
  invisible catcher bitmap at high depth instead (4.1).
- **Keyboard**: `KeyDown / Char / KeyUp` go to the control that called `AcquireKeyboardFocus`, else to the top input
  capture, else wx `Skip()` to `CUIKeyHandler` (`DispatchMauiKeyEventToFocusOrCapture`, `UiRT.cpp:9724-9780`). While any
  Maui control has focus `CUIKeyHandler::OnKeyDown` ignores the key (`:27779-27790`), so typing in an `Edit` never fires
  hotkeys. The global keymap (`gUiKeyActionMap`, `IN_BindKey` `:27711`) maps **one key + shift/ctrl/alt to one console
  string**, with **no key-up, no chords, no mouse buttons, no context**. Held-key logic must poll `IsKeyDown(vk)`
  (Lua global, `FAF/engine/User.lua:840`) in an `OnFrame`.
- **Frame update**: `OnFrame(self, dt)` only for controls with `SetNeedsFrameUpdate(true)` (`CMauiControl::Frame`,
  `:22539`). `NeedsFrameUpdate` controls pay a Lua call per frame; static panels pay nothing.

### 1.4 Rendering limits

| Topic | Fact | Evidence |
|---|---|---|
| Batching | All Maui draws go through one `CD3DPrimBatcher` (`DrawQuad` with 4 arbitrary vertices, `DrawTri`, `DrawLine`, `DrawPoint`, `DrawQuads` / `DrawIndexedQuads` batch calls); textures are DXT atlas members so many small icons batch | `ENG/render/d3d/CD3DPrimBatcher.h:126-242`, `CD3DRawBatchTexture.h` |
| Solid colour | `CD3DBatchTexture::FromSolidColor(argb)` is cached and used by `ItemList`; flat modern UI costs one quad per rect | `UiRT.cpp:13820` |
| Clipping | **None.** No scissor anywhere (grep "scissor": only a disabled D3D10 rasteriser flag). Bitmap clips to its own rect, Text clips glyph runs to its width, nothing clips to a parent | `ENG/gpg/gal/backends/d3d10/D3D10Interfaces.cpp:1409` |
| Alpha | Per control `SetAlpha(a, children?)` -> packed vertex colour `mVertexAlpha` (`UiRT.cpp:21885`); this is also a colour multiplier, so a `SetColorMask` is 10 lines (RGB part of `mVertexAlpha`) | `UiRT.h:2213` |
| Fonts | GDI: `CD3DFont::Create(size, face)` -> `CreateFontA(-size, ..., quality 4 = antialiased, face)`; **any installed face**, UTF-8 input, one glyph rasterised on first use via `DrawTextW` into a 128x128 scratch DC and stored DXT; max glyph 128 px; cache per (size, face), never freed | `ENG/render/d3d/CD3DFont.cpp:583-604, :735-830` |
| Text axes | `CD3DFont::Render(text, batcher, origin, xAxis, yAxis, color, glyphScale, maxAdvance)` already accepts arbitrary axes and scale, but `Text` always passes (1,0,0)/(0,-1,0) | `CD3DFont.h:101`, `UiRT.cpp:16411` |
| Rotation | Bitmap, Text, Border cannot rotate | `UiRT.cpp:22918` |
| Vector shapes | None. No line, curve, polygon, circle control | grep of control list |
| Render to texture | Only `CMauiMesh` (mesh thumbnails) and `WorldView` (second camera). No generic offscreen target for a panel | `CMauiMesh.cpp` |
| Texture formats | File textures `dds tga bmp jpg png` watched for hot reload (`CD3DDeviceResources.cpp:37`); `GetTextureDimensions(file)` global exists | `FAF/engine/User.lua:617` |
| Dynamic textures | `ID3DDeviceResources::NewDynamicTextureSheet(w,h,format)` + `Lock/Unlock` exist and are used by `CMauiMesh`, but **no Lua API creates one** | `ENG/misc/ID3DDeviceResources.h:196` |

### 1.5 Cursor, clipboard, screenshot, misc

- Cursor: `GetCursor():SetTexture(file, hotspotX, hotspotY[, frames, fps])`, `Reset`, `Hide/Show` [V: `maui/cursor.lua`,
  `UiRT.cpp:4006`]. **Mouse scrub** (cursor pinned and hidden, deltas accumulated) exists for the camera drag but only as
  statics in `UiRT.cpp` (`func_StartMouseScrubbing` `:8881`, `func_ProcessMouseScrubbing` `:8846`); not exposed to Lua.
- Clipboard: Lua `CopyToClipboard(s)` is a FAF binary patch (`FA-Binary-Patches/section/CopyToClipBoard.cpp`), absent from
  `ENG`; native helpers `WIN_CopyToClipboard` / `WIN_GetClipboardText` exist (`ENG/app/WinApp.cpp:2238, :3107`) and
  `Edit` already uses paste. A paste global for panels is missing.
- Screenshot: console `dump_Frame` / `dump_Frames` (`ENG/app/FrameDumpCommands.cpp:38-44`, Desktop/SC_CAPTURE folder).
- Tooltips: `FAF/lua/ui/game/tooltip.lua` (mouse-over display with delay, `AddControlTooltip`); skinned, replaceable.
- Per-profile persistence: `Prefs.SetToCurrentProfile` (used by `Window`, `maui/window.lua:527`) or `ed_write_file`.

### 1.6 Drawing lines and curves (needed for node wires): options compared

| Option | How | Verdict |
|---|---|---|
| A. Many small bitmaps | What `ui.lua` does for area edges (squares, `ui.lua:618-646`) | A Bezier wire needs ~40 squares; 200 wires = 8,000 controls (each ~30 Lua allocations, 3.3). Re-created on every pan. **Reject** |
| B. `UI_DrawLine` / world debug lines | FAF patch draws through `CD3DPrimBatcher` inside the world view (`FA-Binary-Patches/section/DrawFunc.cpp`, Lua stubs `FAF/engine/User.lua:1316-1352`) | **Not in the decomp** (no binding). World space only. `CDebugCanvas` (`ENG/sim/CDebugCanvas.h`) is a sim-side buffer rolled per beat (`Sim.cpp:5458-5467`), useless with a frozen edit sim (design D4). Use for 3D gizmos only, via our own native (2.1 item 5) |
| C. **New native `CMauiCanvas` control** | Retained draw list submitted from Lua; `DoRender` emits quads/tris with the same `CD3DPrimBatcher` calls Bitmap/Border use | **Recommended.** Evidence it is cheap: `CMauiBorder::DoRender` (`:25271`) and `CUIMapPreview::DoRender` (`:17581`) already emit arbitrary `DrawQuad(Vertex...)`; `DrawTri`/`DrawLine` exist (`CD3DPrimBatcher.h:169, :213`); text can be emitted by `CD3DFont::Render` with any axes/scale |
| D. wx child window (like `WCurveEditor`) | Retail ships a wx emitter editor with its own curve widget (`ENG/app/WEmitterWx.h:55`, `WEmitterWx.cpp:1324` uses `wxFileDialog`) | Separate OS window, cannot sit in the docking tree. Reject for the graph, keep as proof wx widgets work on x64 |

Reuse trick for C: the dead `CMauiHistogram` class (`UiRT.h:3068`, created by `InternalCreateHistogram`, allocation
0x134, empty `DoRender` `UiRT.cpp:12561`, factory already specialised `UiRT.cpp:3601`) can host the canvas without a new
class or a new `CScrLuaMetatableFactory` specialisation; trade-off: a misleading name. A fresh class under
`moho/editor/` is cleaner and the boilerplate is a copy of the histogram files (2.1).

### 1.7 Multiple viewports and windows

- Several `WorldView`s with separate named cameras are a normal engine feature (minimap). A preview or quad view is a
  Lua-only job; cost per view is a full terrain render [O].
- **Heads**: `CUIManager::Init` creates one wx window plus one Maui root frame per head (`ENG/ui/CUIManager.cpp:252-281`);
  heads are set at startup from the secondary-adapter option (`ENG/app/CScApp.cpp:1186-1241`). Panels can be parented to
  `GetFrame(1)` (second monitor) but **a head cannot be added at run time**: a "pop out to second window" feature needs a
  launch option, or new C++ to create a head late.

---

## 2. Gaps that need new native code

Put new code in **new files under `ENG/editor/`** and bind it from `EditorLua.cpp` (pattern: `BindGlobal`,
`EditorLua.cpp:757-801`). This keeps the 29k-line `UiRuntimeTypes.cpp` free of upstream-merge conflicts (design decision
D1). Every touched upstream file goes into the divergence log (`MAP_EDITOR_DESIGN.md` section 5).

### 2.1 Table (priority order, effort is an *estimate* in focused days)

| # | Native | Why | Files / hook | Effort |
|---|---|---|---|---|
| 1 | **`CMauiCanvas` control** (Lua: `InternalCreateCanvas(self, parent)`; `Clear()`, `SetClip(l,t,r,b)`, `Rect(x,y,w,h,argb,[radius])`, `Line(x1,y1,x2,y2,argb,thick)`, `Polyline(points,argb,thick)`, `Bezier(p0,c0,c1,p1,argb,thick,segs)`, `Quad(texture,...)`, `Text(font,size,str,x,y,argb,[scale,rot])`, `Circle`, `Tri`; command list stays resident until `Clear`, pan/zoom handled by `SetTransform(ox,oy,scale)`) | wires, nodes, curve editors, minimaps, color wheels, timelines, rounded panels | New `ENG/editor/CMauiCanvas.{h,cpp}`; copy the histogram plumbing: class `UiRT.h:3068`, create function `UiRT.cpp:12500-12525`, `TypeInfo` pair `CMauiHistogramTypeInfo.cpp/.h`, upcast bridge `UiRuntimeTypeUpcastBridges.cpp:202-392`, **`CScrLuaMetatableFactory<CMauiCanvas>` specialisation in `ENG/lua/CScrLuaObjectFactory.h`** (this exact omission caused the nil-method bug of `MAP_EDITOR.md` finding 3), startup registration list `UiRT.cpp:28725-28760` or `EditorLua` binder | 4-6 |
| 2 | **Clip (scissor) for a control subtree**: `Control:SetClipChildren(true)` | scroll views and docked panels without the occlusion hack | Pattern of `SetCustomRender` (`UiRT.cpp:21955-21990`, side table keyed by control, no layout change). In `CMauiFrame::RenderChildControls` (`:22160`): when the clip owner of the next control differs, `primBatcher->Flush()` and set the device scissor (`IDirect3DDevice9::SetScissorRect` through `gpg::gal`, flag `D3DRS_SCISSORTESTENABLE`). Owner lookup is cached when the rendered lane is rebuilt (`RebuildRenderedChildrenLane`, `:22110`). Also skip clipped-out controls in `GetTopmostControl` (`:22462`) | 3-4 |
| 3 | `ed_dialog_open_file / save_file / pick_dir (title, filters, startDir [, multi])` | native file dialogs | `wxFileDialog` / `wxDirDialog` already used by the retail code (`WEmitterWx.cpp:1324-1471`, `FrameDumpCommands.cpp:98`); `wxUSE_FILEDLG`, `wxUSE_DIRDLG` = 1 in the built `lib/mswu/wx/setup.h:689, :680`. Modal loop stalls rendering only while open | 1 |
| 4 | **Drag and drop of files from Explorer**: `ed_dnd_enable()`; on drop call Lua `import('/lua/editor/dnd.lua').OnFilesDropped(files, x, y)` | assets into the browser, textures onto maps | `sMainWindow->SetDropTarget(new wxFileDropTarget)` (`wxUSE_DRAG_AND_DROP`=1, `wxUSE_OLE`=1 in the same `setup.h:813, :990`; header `include/wx/dnd.h`). Callback copies the Lua call pattern of `RunGlobalOnMouseButtonPressLuaCallback` (`UiRT.cpp:9498-9525`). Risk: wx 2.4.2 on x64 already needed `WXLPARAM` patching (MAP_EDITOR.md finding 4); OLE paths are untested here [O] | 1-2 |
| 5 | **World overlay lines**: `ed_overlay_line / circle / box / text / quad`, cleared per frame, drawn in `CUIWorldView::Render` after `RenderCommandGraph` (`ENG/ui/CUIWorldView.cpp:~95`) | marker rings, brush circle, gizmos, area edges (design rule 7) | Use the existing helpers `DRAW_WireCircle/WireBox/WireCoords/Rect/Circle` (`CD3DPrimBatcher.h:494-584`), which take thickness and a height field for terrain-draped shapes. Do **not** feed `CDebugCanvas` (sim-owned) | 2-3 |
| 6 | Clipboard: `ed_clipboard_get()`, `ed_clipboard_set(s)` | paste into non-Edit widgets, copy node graphs | Wrap `WIN_GetClipboardText` / `WIN_CopyToClipboard` (`WinApp.cpp:3107, :2238`) | 0.5 |
| 7 | Mouse scrub export: `ed_mouse_scrub(control, on)`, `ed_mouse_delta()` | infinite drag for orbit, fly-look, drag-numbers | Expose `func_StartMouseScrubbing` / `sMouseScrubDelta` (`UiRT.cpp:8881, :8846`) | 0.5 |
| 8 | `Bitmap:SetColorMask(argb)` | tint monochrome icons by theme (`FAF/engine/User/CMauiBitmap.lua:97`, patch #42, missing) | Write RGB of `mVertexAlpha` (`UiRT.cpp:21885`), 10 lines | 0.5 |
| 9 | `ed_font_load(path)` | ship a UI font (e.g. Inter, Segoe UI Variable is system) without installing it | `AddFontResourceExW(path, FR_PRIVATE)` before the first `CD3DFont::Create` (`CD3DFont.cpp:583`) | 0.5 |
| 10 | **DPI awareness** + `ed_get_dpi()`; feed `ui_scale` | sharp UI on 125-200 % displays | No manifest or `SetProcessDPIAware` exists in the sources (grep) [V]. Call `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` in `WinMain.cpp` before window creation; wx 2.4.2 reports physical sizes then. Add a Lua `Scale.Set(f)` rebuild path (1.2) | 1 |
| 11 | Runtime textures: `ed_texture_create(name,w,h)`, `ed_texture_write(name, rgba)`, shown by `MapPreview:SetDynamicTexture(name)` or a canvas quad | colour pickers, brush previews, heightmap/mask previews, minimaps | `NewDynamicTextureSheet` + `Lock/Unlock` as in `CMauiMesh::Frame` (`CMauiMesh.cpp`, `ClearThumbnailSheet`); `CUIMapPreview::DoRender` already draws any sheet (`UiRT.cpp:17581`) | 2 |
| 12 | `ed_texture_dimensions`/`ed_png_write` for screenshot of a region | asset thumbnails, bug reports | `dump_Frame` exists; a region variant is new | 1 |
| 13 | Unit/prop thumbnails baked to disk | asset browser with thousands of items | `REN_RequestThumbnail` (`ENG/mesh/MeshThumbnailRenderer.h`) renders to a sheet; add "save sheet as DDS" and a batch job; cache under `editor/cache/thumbs` | 2-3 |
| 14 | Re-add the FAF globals the FAF Lua expects if used: `UI_DrawLine/Circle/Rect`, `WorldView:ProjectMultiple`, `CopyToClipboard` | only if we reuse FAF UI Lua that calls them (painting, shapes) | The Lua shape classes call them (`FAF/lua/ui/game/shapes/LineShape.lua:53`) | skip |

### 2.2 What does *not* need C++

Tabs, splitters, floating windows, drag and drop inside the app, context menus, tooltips, dropdowns, tree view, virtual
lists, property inspector, overlay scrollbars, workspace presets, saved layouts, bookmarks, keymap editor: all Lua.

---

## 3. Docking system in Lua on Maui

### 3.1 Data model (JSON-like, serialised with the existing `luaser.lua`)

```lua
Layout = {
  version = 1, scale = 1.0,
  areas = {                              -- docked tree, one root per head
    { type='split', dir='h', ratio=0.22,
      a = { type='stack', active=1, panels={ {id='outliner'}, {id='assets', state={filter='props'}} } },
      b = { type='split', dir='v', ratio=0.78,
            a = { type='stack', panels={ {id='viewport', state={camera='persp'}} } },
            b = { type='stack', panels={ {id='console'}, {id='validation'} } } } },
  },
  floating = { { x=0.6, y=0.2, w=0.3, h=0.5, stack={ type='stack', panels={ {id='properties'} } } } },
  maximized = nil,                       -- id of a stack shown full screen (Ctrl+Space)
}
```

Rules: a stack has 1 to N panels (tabs). Splits store a ratio in 0..1, never pixels (UI-scale and resolution
independent). Minimum size comes from the panel descriptor. Layout files live in `editor/layouts/<name>.lua` (workspace
presets: Terrain, Props, Mission, Scripting, Mesh) and the user's copy in the editor data folder via `ed_write_file`.

### 3.2 Panel registry (moddable)

```lua
Panels.Register{
  id='outliner', title='Outliner', icon='/textures/editor/icons/outliner.dds', category='Scene',
  singleton=true, minSize={160,120}, defaultDock='left',
  Create=function(parent, state) return OutlinerPanel(parent, state) end,   -- returns a Group subclass
  -- Panel contract: :GetState() -> table, :SetState(t), :OnShow(), :OnHide(), :OnResize(w,h), :OnDestroy(), :Settings()
  menu='Window/Outliner', hotkey='Ctrl-Alt-O',
}
```

Modding: the editor already loads **editor mods** (`editor_mod = true`, `docs/EDITOR_MODDING.md`) whose `hook/lua/editor/...`
files are appended to editor modules. A mod calls `Panels.Register{...}` from a hook on `/lua/editor/ui/panels.lua`; a
declarative alternative is a scan of `DiskFindFiles(mod.location..'/editor/panels', '*.lua')` (Lua global in
`FAF/engine/Core.lua:123`). Workspaces and keymaps use the same two routes. Per-panel settings are the `GetState` table,
saved inside the layout; global settings (theme, scale) in `editor/settings.lua`.

### 3.3 Implementation sketch and Maui cost model

- **Geometry is computed in plain Lua**, not with chains of lazy-variable helpers: one `Relayout()` walks the tree and
  writes absolute rectangles with `control.Left:Set(n)` etc. into each *panel root* group. Only the content *inside* a
  panel uses relative `Layouter` helpers. Reason: lazy-var dependency chains make a root resize re-evaluate every
  descendant closure through `pcall` (1.2).
- **Splitter**: a thin `Bitmap` with `HandleEvent`; on press, `PostDragger`; on move compute the ratio, clamp by minima,
  call `Relayout()` for the two siblings only. Preview option: draw a ghost line and commit on release (setting
  "live resize").
- **Tabs**: header `Group` with one `Text`+`Bitmap` per tab; inactive panel roots `Hide()`. Overflow: scroll or "..." menu.
- **Drag to rearrange**: tab press -> `Dragger`; ghost bitmap follows `x,y`; drop zones (centre = add as tab, edges =
  split, outside = float) are rectangles computed in Lua from the layout tree, no Maui hit test needed; draw the preview
  with one translucent `Bitmap`.
- **Floating windows**: own `Group` with title bar, resize handles on 8 edges (pattern of `maui/window.lua:295-345`,
  but our own flat skin; do not reuse `Window`, it is bound to game textures and prefs ids).
- **Maximise / pin / close / "Window" menu** list every registered panel (reopen closed ones).
- **UI scale**: `LayoutHelpers.SetPixelScaleFactor(f)`, then rebuild the tree from `Layout` (panels are recreated from
  `GetState`). Fonts follow `ScaleNumber`. Use a few fixed font sizes (11, 12, 14, 16, 20) to keep the GDI glyph cache
  small; fractional scales give non-integer sizes and slight blur (Maui floors to integers).
- **Theme**: one `Theme` table (colours as `'aarrggbb'` strings, spacing, radii, font sizes) read by every widget;
  `InternalSetSolidColor` / `Border:SetSolidColor` for flat surfaces, a small atlas of 9-slice corner textures for
  rounded corners (until the canvas can draw rounded rects, 2.1 item 1), icons from one atlas via `SetUV`.

Memory and creation cost per Lua control [I from `control.lua`, `lazyvar.lua`, `text.lua`]: the instance table, 7 lazy vars
(each a table plus `uses`/`used_by` sets), 6 layout closures plus depth closure, and for `Text` three more lazy vars (font
family, size, colour). Roughly 30-40 Lua allocations, 2-3 KB. 1,000 controls = 2-3 MB, trivially fine.

### 3.4 Honest performance assessment (and the benchmark that settles it)

What is cheap [V]: steady-state rendering (flat list, batched quads), hit testing, idle panels (no `OnFrame`), a long
`ItemList`.
What is expensive [I]: (a) creating many controls in one frame (each is a Lua object with many tables; hundreds per frame
are fine, several thousand will hitch); (b) a **layout change that dirties many lazy vars** (splitter drag, window
resize, scale change): every dependent closure runs under `pcall` the next time C++ reads it, so cost is
O(descendants of the changed rectangle); (c) per-frame Lua `OnFrame` handlers on many controls; (d) `Depth` or
structure changes cause a full flatten and sort of the frame's control list (`CMauiControl::Render`, `:22110`).
*Estimate:* a few hundred controls per panel and ~2,000 in the whole editor is comfortable; a splitter drag over a
panel with 500 descendants may cost several ms per frame, which is the one place to budget.

Mitigations, in order: virtualise lists (3.6); build panel contents once and keep them (hide/show tabs instead of
destroying); throttle splitter relayout to 30 Hz or commit on release; give heavy panels a single `CMauiCanvas`
instead of hundreds of controls; keep per-row controls free of cross-row lazy dependencies.

**Benchmark to run before building** (via the `/edcmd` channel, `MAP_EDITOR.md` dev loop; not run in this study):
```lua
local t0 = GetSystemTimeSeconds(); local g = Group(GetFrame(0)); local c = {}
for i = 1, 1000 do local b = Bitmap(g); b:SetSolidColor('ff202830'); LayoutHelpers.AtLeftTopIn(b, g, (i*7)-math.floor(i/50)*350, math.floor(i/50)*10); LayoutHelpers.SetDimensions(b, 6, 8); c[i]=b end
LOG('create 1000 bitmaps', GetSystemTimeSeconds()-t0)            -- (a)
t0 = GetSystemTimeSeconds(); g.Left:Set(g.Left() + 1); for i=1,1000 do c[i].Left() end; LOG('relayout', GetSystemTimeSeconds()-t0)  -- (b)
```
Repeat for 1,000 `Text` controls and for one splitter drag over a dummy panel with 500 children. Decide thresholds
(for example creation < 150 ms per 1,000, relayout < 4 ms per 500) and record them in this file.

### 3.5 Smart scrollbars (auto-hide, overlay)

Write a `ScrollView` widget, do not use the native `Scrollbar` (needs 4 textures, always visible). Content moves by
repositioning a pooled set of row controls (3.6) or by changing one `offset` lazy var that the rows depend on. The bar
is a 6 px `Bitmap` thumb with `Dragger`; it sits over the content (overlay), alpha 0 until mouse enters the panel or the
wheel moves, fades in `OnFrame` (`SetAlpha`), widens on hover, supports click-on-track. Wheel events bubble from rows to
the `ScrollView`'s `HandleEvent` (1.3). Precedent for the data contract: `GetScrollValues / ScrollLines / ScrollPages /
ScrollSetTop / IsScrollable` in FAF's own `createunit.lua` virtual list (`FAF/lua/ui/dialogs/createunit.lua:1665-1700`),
so the native `Scrollbar` can still drive our lists where convenient.

### 3.6 Virtualising long lists (blueprint browser with thousands of entries)

- Data: `__blueprints` is readable in UI Lua (`createunit.lua`, `FAF/lua/ui/game/buildmode.lua` use it), filter and sort
  in Lua into an index array.
- Plain text lists: native `ItemList` (`UiRT.cpp:13812`) already draws only visible rows; 10,000 strings are fine.
- Rich rows (icon, name, tags, checkboxes): pool of `visibleRows + 2` row groups; the scroll offset changes which data
  item each row shows (`row:Bind(item)`: `SetText`, `SetNewTexture`), no controls created or destroyed while scrolling.
  Same pattern as `createunit.lua` and `maui/grid.lua`.
- Thumbnails: load lazily per visible row; unit icons already exist as textures; prop/mesh thumbnails need item 13
  of 2.1 (baked cache) or `Mesh` controls for the 20 visible rows only.
- Filtering: debounce the `Edit` text change by 150 ms in an `OnFrame` timer.

### 3.7 Node graph (Blender-like mission scripting)

Use `CMauiCanvas` (2.1 item 1). Nodes, pins and wires are draw commands, pan/zoom is the canvas transform, so a pan
costs zero lazy-variable work and thousands of nodes stay cheap. Hit testing (node, pin, wire, box select) runs in Lua on
a spatial grid of the model; the canvas is one Maui control that receives all mouse events. In-place editing: when a
field is clicked, place a real `Edit` above the canvas at that rectangle, commit on Enter. Text LOD: below ~60 %
zoom skip labels; font size snaps to the discrete UI sizes, `glyphScale` interpolates in between (slightly soft, [O]).
Without the canvas (fallback): nodes as `Group`s of bitmaps and text, wires as option A; workable to ~30 nodes only.

---

## 4. Camera

### 4.1 What the existing camera is [V]

`CameraImpl` (`ENG/render/camera/CameraImpl.cpp`, 4,428 lines; members `CameraImpl.h:1055-1131`) is an **orbit camera around a
terrain-snapped focus**:

- State: focus `mOffset`/`mTargetLocation`, `mHeading`, `mFarPitch`, `mTargetZoom` (a vertical extent in world units), `mNearZoom`
  (the zoom the user asked for; `mTargetZoom` slews toward it in log space with `cam_ZoomSpeedLarge/Small`,
  `UpdateBasis`, `:1625-1650`).
- Eye position (`UpdateCoords`, `:2362-2450`): `eyeDistance = targetZoom / tan(fov/2) / 2`; eye = focus + forward * eyeDistance;
  far clip `eyeDistance + 17000`, near clip `max(0.01, 1 % of distance)`. Perspective FOV is **derived from zoom**
  (`CalculateFOV`, `:1568`, log blend between `cam_NearFOV` 65 and `cam_FarFOV` 60). Pitch is derived from zoom too
  (`cam_NearPitch` 40 deg -> `cam_FarPitch` 89.9 deg, `:1568-1601`, defaults `ENG/misc/RuntimeTuningGlobals.cpp:108-133`)
  **until the camera is "rotated"** (`mIsRotated`), after which pitch/heading are held.
- Focus is forced onto the terrain every frame: `ClampFocusPos` (`:1537`) intersects the view ray from `mOffset` with the
  surface (`STIMap::SurfaceIntersection`). So the eye is always `eyeDistance` away from a terrain point along the view
  ray; **the eye cannot float at an independent altitude** and there is no eye-vs-terrain collision (eye may go under
  a hill).
- Limits: zoom `[cam_NearZoom = 5, GetMaxZoom()]` (`CameraZoom` `:746`; `GetMaxZoom` `:1265` = playable (or whole map when
  the focus army has `mUseWholeMap`) extent x `mMaxZoomMult` 1.4, `+ ren_BorderSize`); focus clamped inside the playable
  rectangle in proportion to zoom (`ClampTargetPos`, `:1459`) **unless `cam_Free`**; spin pitch clamped to
  `[cam_MinSpinPitch = 0.1 rad, 1.5608 rad (89.4 deg, hard-coded kCameraSpinPitchUpperBound, :156)]` (`CameraSpin`, `:709`).
- `cam_Free` (console bool, `ENG/console/CConCommand.cpp:4668-4728`, registered as `cam_Free`; FAF keymap `Ctrl-V` -> `Cam_Free`):
  removes the map-edge clamp (`CameraImpl.cpp:1694`), allows rotation without the zoom condition and without auto-revert
  (`UiRT.cpp:21115, :21240, :21269`), and hides strategic icons and resource splats (`CUIWorldView.cpp:62`,
  `UiRT.cpp:21487`). It does not lift zoom or pitch limits.
- Orthographic: `WorldView:SetOrthographic` -> `CameraSetOrtho` (`CUIWorldView.cpp:~214`, `CameraImpl.cpp:1002`);
  `UpdateCoords` builds a **top-down only** ortho view (heading pi, pitch pi/2 are hard-coded, `:2386-2410`).
- Built-in mouse/keys (`CUIWorldView::HandleEvent`, `UiRT.cpp:21103`): wheel = `CameraSetPivot(cursor)` + `CameraZoom` (zoom to
  cursor: while `mTargetType` is Location/Hermite the focus is pulled toward the pivot ray when the zoom shrinks,
  `CameraImpl.cpp:1660-1690`); MMB drag = `CameraDragger` -> `CameraPan` (`UiRT.cpp:21283-21291`, `CameraImpl.cpp:2173`,
  speed `cam_PanSpeed * zoom / viewportWidth`); Space + mouse motion = spin (`:21239-21265`, scrub-pinned cursor);
  `Insert/Delete` spin; arrow keys / screen edge pan in `CUIWorldView::Frame` (`:21467-21545`, `ui_Keyboard*Speed`).
- **The base `HandleEvent` runs the Lua `HandleEvent` first and stops if it returns true** (`UiRT.cpp:21136-21143`,
  "base control gets first refusal"). The editor's Lua hook (`editor/runtime/schook/lua/ui/controls/worldview.lua` ->
  `ui.HandleWorldPress`) can therefore take over all camera input, as it already does for left clicks.

### 4.2 Lua API surface today (`FAF/engine/User/CameraImpl.lua`, bindings `CameraImpl.cpp:2879-4344`)

`SnapTo(focus, {heading, pitch, roll}, zoom)` (calls `TargetManual(..., 0 s)` which sets heading, **pitch**, zoom and
`mIsRotated = 1`, so pitch and zoom are held and the zoom clamp in `UpdateBasis` is skipped, `:2736-2760, :1650`),
`MoveTo(..., seconds)` (Hermite blend), `MoveToRegion(rect, s)`, `SaveSettings() -> {Zoom,Pitch,Heading,Focus}`,
`RestoreSettings` (**also calls `CameraRevertRotation`**, so it re-slews pitch back to the zoom-derived value; use `SnapTo`
for bookmarks), `Spin(headingRate, zoomRate)` (continuous cinematic rate, not a mouse delta), `HoldRotation`, `SetZoom`,
`SetTargetZoom`, `GetZoom/GetTargetZoom/GetMinZoom/GetMaxZoom/GetFocusPosition`, `SetMaxZoomMult`, `SetAccMode`,
`EnableEaseInOut`, `TrackEntities`, `NoseCam`. `WorldView:ZoomScale(x, y, wheelRot, wheelDelta)`, `Project`, `UnProject`,
`GetMouseWorldPos`, `LockInput`, `GetsGlobalCameraCommands`, `IsKeyDown`.
**Not exposed:** raw `Pan(dx,dy)`, `Spin(dx,dy)` as deltas, `SetPitch/SetHeading`, `GetHeading/GetPitch` (only through
`SaveSettings`), FOV, eye position, ortho orientation, scrub.

### 4.3 Phase A: Lua-only controller (no C++), what it can do

A `CameraController` module that owns viewport mouse/keys through the world-view hook and keeps its own state
`(focus, heading, pitch, zoom)` applied each frame with `SnapTo`:

| Feature | How | Limit |
|---|---|---|
| Orbit | heading/pitch += mouse delta * k; clamp pitch to `[0.05, 1.56]` | pitch cannot go below the horizon or past nadir; no eye collision |
| Pan | move focus along camera right / ground-flattened forward by `zoomScaled * dx`, same maths as `CameraPan` (`:2173-2235`) | Y of focus is re-snapped to terrain |
| Zoom to cursor | `WorldView:ZoomScale(x,y,rot,delta)` or own: scale zoom, move focus toward `UnProject(cursor)` | zoom bounds: set `SetMaxZoomMult(large)` and `ConExecute('cam_NearZoom 0.5')`; `SnapTo` itself does not clamp |
| WASD "fly" | `IsKeyDown` in `OnFrame`, moves the **focus** (and so the eye) at `speed * dt`, speed scaled by zoom; Q/E = zoom in/out | eye altitude is a function of zoom + pitch; cannot hover above terrain at constant height |
| Focus selection / frame all | `SnapTo(pos, hpr, zoom)` with zoom from the selection's bounding radius; `MoveToRegion` | none |
| Bookmarks | store `{focus, heading, pitch, zoom}`; jump with `SnapTo` (not `RestoreSettings`); persist per map in `<stem>_editor.lua` | none |
| Top view | `SnapTo` with pitch 1.5607 rad (89.4 deg) and heading pi; ortho toggle `SetOrthographic(true)` | top only; front/side views need C++ (4.4) |
| Map edge | `ConExecute('cam_Free true')`, soft-limit in Lua to map + margin | `cam_Free` hides strategic icons and resource splats in edit mode |
| Mouse look with cursor lock | needs `ed_mouse_scrub` (2.1 item 7) | without it the cursor leaves the window on long drags |

### 4.4 Phase B: C++ changes that unlock the rest (all in `CameraImpl.cpp`, ~150 lines)

CameraImpl's member layout carries `static_assert`s that match the retail binary (`CameraImpl.h:1135+`). The editor does
not need binary parity, but to keep the divergence small use side tables keyed by camera (the pattern already used for
`SetCustomRender`, `UiRT.cpp:21955`) or append members and update the asserts.

1. **Free-fly mode** (`Camera:SetFreeFly(bool)`, `SetEye(x,y,z)`, `GetEye()`, `SetLook(heading,pitch)`): in `UpdateBasis`
   (`:1625`) return after storing heading/pitch when fly is on (skip zoom slew, `ClampTargetPos`, `ClampFocusPos`);
   in `UpdateCoords` (`:2362`) use the stored eye instead of `focus + dir * eyeDistance`. Leaving fly mode recomputes
   focus by intersecting the view ray with the terrain (the existing `ClampFocusPos` code) and derives zoom from the
   eye distance, so orbit resumes exactly where fly stopped.
2. **Orthographic with any orientation** (`:2386-2410`): replace the hard-coded `COORDS_Orient(kPi, kHalfPi)` with
   `COORDS_Orient(mHeading, mFarPitch)` and use `mOffset` as the ortho target; gives front/side/back/bottom views. Use
   `ortho extent = targetZoom`.
3. **FOV override** (`Camera:SetFov(deg)` / `-1` = auto): one branch in `CalculateFOV` (`:1568`).
4. **Pitch bounds** as console vars instead of the constant at `:156`; allow `0` (horizon) and negative values (look up)
   in a new `cam_EditorPitchMin/Max`, used only when fly or "editor camera" is on.
5. **Eye collision** (optional): in `UpdateCoords`, after computing the eye, raise it to
   `terrainHeight(eye.x, eye.z) + margin` using `mTerrainMap`'s height field (the same map handle used by `ClampFocusPos`).
6. **Lua exports** for raw deltas: `Camera:Pan(dx,dy)`, `Camera:SpinDelta(dx,dy)`, `Camera:Zoom(delta)`, `SetPivot(x,y)`,
   `SetHeading(r)`, `SetPitch(r)`, `GetHeading()`, `GetPitch()`, `GetFov()` (existing C++ methods `CameraPan`, `CameraSpin`,
   `CameraZoom`, `CameraSetPivot`, `CameraSetHeading`, `CameraSetPitch`; each binder is ~25 lines like
   `cfunc_CameraImplSpinL`, `:3374`). With these, the Phase A controller stops duplicating the engine's maths.
7. **Smoothing / inertia**: a per-camera `damping` factor applied in `Frame` (`:1892`) for fly velocity and orbit
   (Blender "smooth view"); the existing Hermite machinery (`TimedMoveInit`, `SetupHermite`) can animate view changes
   (numpad snaps) for 0.25 s.
8. Map-edge clamp as a editor-provided rectangle (`SetBounds(x0,z0,x1,z1,margin)`) instead of the all-or-nothing `cam_Free`
   (`ClampTargetPos`, `:1459`), so icons stay visible.
9. Four-view layout: four `WorldView`s with cameras "persp / top / front / side" (each 2 above + ortho). Per-view terrain pass
   cost [O].

### 4.5 Proposed keymap (Blender conventions, all rebindable)

Context "Viewport" (mouse over a 3D view and no text field focused). Mouse bindings are handled in Lua (the engine
keymap has none).

| Action | Default | Notes |
|---|---|---|
| Orbit | MMB drag | `Alt+LMB` alternative (Maya) and "emulate 3 buttons" for pen/trackpad |
| Pan | `Shift+MMB` drag | |
| Dolly / zoom drag | `Ctrl+MMB` drag | |
| Zoom to cursor | Wheel | setting "zoom to mouse position" (default on) |
| Fly mode (hold) | RMB held + `W A S D`, `Q` down, `E` up | Wheel while held changes speed, `Shift` x4, `Ctrl` /4 |
| Fly toggle (walk) | `Shift+\`` | |
| Frame selection | `F` (numpad `.`) | `Shift+F` frame with animation off |
| Frame all / map | `Home` | |
| View front / right / top | numpad `1` / `3` / `7`; `Ctrl+` = back / left / bottom | needs 4.4 item 2 for non-top |
| Perspective <-> ortho | numpad `5` | |
| Step orbit | numpad `4 6 8 2` (15 deg) | |
| Step pan | `Ctrl+` numpad `4 6 8 2` | |
| Zoom step | numpad `+` / `-` | |
| Camera bookmark jump / set | `Alt+1..9` / `Ctrl+Alt+1..9` | plus a Bookmarks panel (named, thumbnail optional) |
| Previous view | `Alt+Z` | history of last 16 views |
| Maximise area | `Ctrl+Space` | docking |
| Toggle HUD overlays | `Z` pie / `Shift+Z` | |
| Reset camera | `Ctrl+Home` | |

Everything else (tools, undo, panels) goes in the same keymap table `{ context, action, key|mouse, modifiers }`, with
conflict detection in a Keymap panel. Presets: "Blender", "Unity-like", "Maya-like", "Legacy FA".

### 4.6 Keyboard routing design (untested [O])

The engine keymap cannot express contexts, key-up or mouse chords (1.3). Proposed: one invisible `KeyRouter` control that
holds Maui keyboard focus (`AcquireKeyboardFocus`) while no `Edit` has it, receives `KeyDown/Char/KeyUp` with modifiers
(`DispatchMauiKeyEventToFocusOrCapture`, `UiRT.cpp:9724`), dispatches to the keymap by active context (viewport, graph,
list, global) and re-acquires focus in `OnLoseKeyboardFocus` (the press handler calls `LosingKeyboardFocus()` on the old
owner, `UiRT.cpp:9680-9686`). While the router has focus `CUIKeyHandler` is bypassed (`:27779`), so `IN_BindKey` bindings
stop working; that is intended. Held keys (WASD) can poll `IsKeyDown` instead. To verify: parameter meaning of
`AcquireKeyboardFocus(blocksKeyDown)`, focus loss when clicking a world view (it is a Maui control, so the same rule
applies), and IME composition.

---

## 5. Recommended approach, phases and risks

### 5.1 Approach

1. **Phase 1, Lua kit and docking (no C++; 2-3 weeks *estimate*)**: theme, widget kit (button, toggle, slider, number
   field with drag-to-change, text field, dropdown, tree, tabs, tooltip, context menu, toast), `ScrollView`, `VirtualList`,
   splitter/dock/float/tab-drag, `Layout` save/load, `Panels.Register`, workspaces, UI-scale rebuild, benchmark (3.4).
   Port the current `ui.lua` panels onto it. Occlusion hack for clipping (opaque chrome drawn over content spill).
2. **Phase 2, natives batch 1 (1-2 weeks)**: `CMauiCanvas` (+ rounded rects, lines, text, quads), clip groups,
   `ed_dialog_*`, clipboard, scrub, `SetColorMask`, `ed_font_load`, DPI, `ed_overlay_*`, then drag and drop of files
   and runtime textures.
3. **Phase 3, camera controller in Lua (3-5 days)** on `SnapTo` (4.3), bookmarks, keymap editor, KeyRouter.
4. **Phase 4, camera C++ (3-5 days)** items 1-6 of 4.4; replace the Lua maths by engine calls.
5. **Phase 5, node graph on the canvas (2-3 weeks)** with a graph model shared with the mission suite (M6).

Because every native lands in `ENG/editor/` plus 5-6 one-line hooks in upstream files, the cost of tracking upstream stays
small. Each native ships with a `selftest_*.lua` run through `/edcmd` (design rule 9).

### 5.2 Ranked risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| 1 | **Lazy-variable layout cost** makes live splitter / window resize janky with 500+ controls per panel | medium / high (UX) | Benchmark first (3.4); absolute-rect docking maths in Lua; deferred relayout; virtual lists; canvas for dense panels |
| 2 | **No clipping** forces hacks (occlusion by opaque chrome, hide partial rows) and breaks around translucent popups | high / medium | Scissor patch (2.1 item 2) early; canvas clips its own content geometrically |
| 3 | `CMauiCanvas` plumbing mistakes (reflection type info, **missing `CScrLuaMetatableFactory` specialisation** gives nil methods, upcast bridges) | medium / medium | Copy histogram plumbing file by file; follow rule "specialisation declared in `CScrLuaObjectFactory.h`"; selftest creating the control |
| 4 | **Keyboard routing**: global keymap lacks contexts/key-up; focus-router design unverified; `Edit` focus interplay | medium / medium | Prototype `KeyRouter` in week 1 of Phase 3; fallback: poll `IsKeyDown` plus `IN_BindKey` for global chords |
| 5 | wx 2.4.2 on x64: OLE drag and drop and modal dialogs untested (known pointer-width bugs already patched in `defs.h`, `window.cpp`, `textctrl.cpp`) | medium / low | Dialogs have retail precedent (`WEmitterWx.cpp`); test DnD early; keep "Open..." buttons as the primary path |
| 6 | Camera: free-fly interacting with Hermite moves, entity tracking and `ClampFocusPos` | medium / low | Fly as a separate branch in `UpdateBasis`/`UpdateCoords`; leaving fly resolves focus by ray cast; selftest by checksum of `SaveSettings` after enter/leave |
| 7 | GDI font quality and cost: grayscale AA glyphs stored as DXT, per-size cache, blur at fractional scale; no ClearType | medium / low | Few fixed sizes, integer-friendly scales, private font via `FR_PRIVATE`; glyph `glyphScale` only for zoomed graphs |
| 8 | Upstream merge conflicts if `UiRuntimeTypes.cpp` is edited | medium / medium | New files under `ENG/editor/`, hooks logged in the divergence table |
| 9 | DPI: wx 2.4.2 is unaware; per-monitor changes at run time | low-medium / medium | Process-level awareness at startup + scale option; no live per-monitor switching in v1 |
| 10 | Extra `WorldView`s (previews, quad view) each cost a terrain pass | medium / low | Use `Mesh` thumbnail control for previews; quad view optional, ortho views at lower detail |
| 11 | Missing FAF patch globals break reused FAF Lua (`UI_DrawLine`, `SetColorMask`, `ProjectMultiple`, `CopyToClipboard`) | low / low | Do not reuse FAF UI Lua that calls them; items 6, 8 add the useful ones |
| 12 | Pop-out to second monitor impossible at run time (heads fixed at startup) | certain / low | Out of scope for v1; document; floating panels stay inside the main window |

### 5.3 Open questions for the user

- Is a second-monitor pop-out required? (needs launch option or new head creation code)
- Strategic icons while the free camera is on: accept `cam_Free` hiding them, or add the bounds-rect variant (4.4 item 8)?
- Look: flat dark theme with 4 px rounded corners and soft shadows (needs canvas rounded rects or a texture set) or
  closer to the game's skin?
- Is a ClearType-quality UI font a must? (would need a different glyph path in `CD3DFont`)

---

## Appendix: source index

Engine (`ENG` = `engine_decomp/faf-re-upstream/src/sdk/moho`):
`ui/UiRuntimeTypes.cpp` (controls `:12436-25400`, event mapper `:9135-9830`, scrub `:8846-8945`, world view `:18262, :20518,
:21103, :21467`, keymap `:27619-27850`), `ui/UiRuntimeTypes.h` (class `CMauiHistogram` `:3068`, `CMauiControl::mVertexAlpha`
`:2213`), `ui/CUIWorldView.cpp`, `ui/CMauiMesh.cpp`, `ui/CUIManager.cpp:131-345`, `ui/SDebugLine.h`,
`render/camera/CameraImpl.{h,cpp}`, `render/d3d/CD3DPrimBatcher.h`, `render/d3d/CD3DFont.cpp`, `misc/RuntimeTuningGlobals.cpp`,
`console/CConCommand.cpp:4661-4840`, `app/WinApp.cpp:2238, :3107`, `app/WEmitterWx.cpp`, `app/CScApp.cpp:1186-1423`,
`editor/EditorLua.cpp`, `sim/CDebugCanvas.h`, `dependencies/wxWindows-2.4.2/lib/mswu/wx/setup.h`.
FAF Lua (`FAF` = `faf_repo/fa`): `lua/maui/*.lua`, `lua/lazyvar.lua`, `lua/ui/controls/*.lua`, `lua/ui/dialogs/createunit.lua`,
`lua/keymap/*.lua`, `lua/options/options.lua`, `engine/User.lua`, `engine/User/CMaui*.lua`, `engine/User/CameraImpl.lua`,
`engine/User/CUIWorldView.lua`. FAF patches (reference only, not in the build): `faf_repo/FA-Binary-Patches/section/DrawFunc.cpp`,
`CopyToClipBoard.cpp`. Editor: `editor/runtime/lua/editor/ui.lua`, `docs/EDITOR_MODDING.md`.
