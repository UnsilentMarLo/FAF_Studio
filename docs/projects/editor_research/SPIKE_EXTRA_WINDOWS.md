# Spike: extra native windows ("heads") at run time

Date 2026-10-17. Read-only analysis of `engine_decomp/faf-re-upstream/src/sdk` (target `main_ed.vcxproj`, D3D9, x64).
Nothing built or run. Tags: **[V]** read in source (file:line), **[I]** inferred, **[O]** open / needs a test.
Paths below are relative to `src/sdk/` unless they start with `docs/`, `faf_repo/` or `editor/`.

## 0. Answer in short

- "Heads are fixed at startup" is **true, but `CUIManager` is not the reason**. `CUIManager::AddFrame` can be called at
  any time [V `moho/ui/CUIManager.cpp:199-211`]. The real blockers are three layers lower:
  1. **A GAL head is an implicit swap chain of a D3D9 adapter-group device**, built only in `DeviceD3D9::Setup` /
     `Reset` from the whole `DeviceContext` (behaviour flag `0x200` = `D3DCREATE_ADAPTERGROUP_DEVICE`,
     `gpg/gal/backends/d3d9/D3D9Interfaces.cpp:1752`; per-head params `:1884-1932`; `GetBackBuffer(headIndex)` `:1956`).
     `CreateAdditionalSwapChain` / `IDirect3DSwapChain9` appear **nowhere** in the tree [V grep].
  2. **The multi-head path is fullscreen-only and needs an adapter group.** Every command-line or option branch that adds
     a second head sets both heads' `mWindowed = true`, which means *fullscreen* (`moho/app/CScApp.cpp:1189-1193`,
     `:1224-1228`; field meaning confirmed in `docs/projects/MAP_EDITOR.md:320`). `/windowed` gives exactly one head
     (`CScApp.cpp:1211-1217`). Setup also throws when `headCount > mAdapters.size()` (`D3D9Interfaces.cpp:408-411`,
     `:2001-2004`) and when `headCount > 1 && mAdapter != 0` (`:413-416`). Modern GPUs report one adapter per output but
     no multi-head group [I], so the retail dual-head mode very likely cannot create a device on this machine [O].
  3. **The renderer is hard-wired to two heads**: `WRenViewport` has `mBloomRenderers[2]`, `mPrimaryTargetLocks[2]`,
     `mSecondaryTargetLocks[2]`, `mDepthStencilLocks[2]`, `mNumHeads = hasSecondHead ? 2 : 1`
     (`moho/render/WRenViewport.h:451,477-479`; `moho/app/WxRuntimeTypes.cpp:1764`; `:3407-3419` release code writes
     indices 0 and 1 literally); `CD3DDevice` has `mRenderTargetLocks[2]`, `mDepthStencilLocks[2]`
     (`moho/render/d3d/CD3DDevice.h:840,842`). The `static_assert`s on these offsets are disabled in the x64 build
     (`platform/X64LayoutAsserts.h:19`), so the arrays can be enlarged.
- **Run-time heads in the retail sense (design A) are possible but expensive and give little. A smaller design (B) gets
  the user-visible feature: panel pop-out windows that bypass the head model entirely** (own wx top-level window, own
  `IDirect3DSwapChain9`, own Maui root frame, rendered by a small new loop). Recommendation: **B**, 6-8 days.

## 1. How heads are modelled

| Piece | Where | Fact |
|---|---|---|
| Head descriptor | `gpg/gal/Head.hpp:44-135` | `mHandle` (focus HWND), `mWindow` (device HWND), `mWindowed` (= fullscreen), `mWidth/mHeight`, MSAA, mode lists. 0x80 bytes. [V] |
| Head list | `gpg/gal/DeviceContext.hpp:116` `msvc8::vector<Head> mHeads`; `Device.cpp:326-337` `AddHead` | a plain vector, but only read at device (re)creation [V] |
| Build from options | `CScApp.cpp:1154-1323` `CreateDevice` | primary head always; second head from `/dualhead`-style option (alias sets `dual|multi|two` x `head|monitor|mon|display`, `moho/misc/StartupHelpers.cpp:97-98`, composed at `:2029`; `w0 h0 [w1 h1]`) or from prefs `secondary_adapter` (`:1221`) [V] |
| Windows | `CScApp.cpp:1334-1476` `CreateAppFrame` | head 0 = `WSupComFrame` (`:1367`) + child `WRenViewport` (`:1414`); `primaryHead.mHandle` = frame HWND, `mWindow` = viewport HWND (`:1418-1419`). Head 1 = a second **bare** `WSupComFrame` (`:1428`), `mHandle` copied from head 0, `mWindow` = its HWND (`:1430-1431`). No viewport child on head 1. [V] |
| Device | `CScApp.cpp:1442` `gpg::gal::Device::Create(&context)` -> `D3D9Interfaces.cpp:1725` `Setup` | one `CreateDevice(adapter, HAL, primaryWindow, 0x44|0x200 if >1 head, presentParameters[headCount])` (`:1752,1769`) [V] |
| Per-head present params | `D3D9Interfaces.cpp:1884-1915` | `hDeviceWindow = (head 0 && mWindowed) ? mHandle : mWindow`; `Windowed = mWindowed ? 0 : 1`; vsync only on head 0 [V] |
| Per-head surfaces | `:1940-1986` `CreateHeads` | `OutputContext[headCount]`: back buffer `GetBackBuffer(i)` + a `D24S8` depth surface of the back-buffer size. Throws if called twice. [V] |
| Present | `:3295-3308` | one `mDevice->Present(nullptr x4)`: presents the implicit chain(s) only [V] |
| Reset | `:2190-2224` | rebuilds params for the **same** head list, `mDevice->Reset`, `BuildDeviceCapabilities`, `CreateHeads` [V] |
| Maui side | `moho/ui/CUIManager.h:153-158` | `mFrames` (one `CMauiFrame` per head) parallel to `mInputWindows` / `mHostWindows` (`wxWindow*`) [V] |
| Frame creation | `CUIManager.cpp:216-289` `SetNewLuaState` (loop `:252-282`) | **destroys all frames and recreates one per registered window**; sets size from `mInputWindows[head]->GetClientSize()`, pushes the frame's `CMauiWxEventMapper` on the window, `mTargetHead = head`. Called on every Lua-state change. [V] |
| Registration | `CUIManager.cpp:199-211` `AddFrame(inputWindow, hostWindow)` | pushes both vectors, pushes a `CUIKeyHandler`, returns the index. No frame is made here. [V] |
| Lua | `moho/sim/Sim.cpp:16487` `GetFrame(i)`, `:16651-16690` `GetNumRootFrames()` = `mFrames.Size()` | FAF Lua treats `GetNumRootFrames() > 1` as "second monitor": `faf_repo/fa/lua/ui/game/multihead.lua:39-59`, `gamemain.lua:313,457`, `uimain.lua:61`, `uiutil.lua:1185` [V] |
| World view to head | `UiRuntimeTypes.cpp:18299, 20505` | `ren_Viewport->AddWorldView(view, rootFrame->mTargetHead, depth)`; `CMauiFrame:SetTargetHead/GetTargetHead` exist (`:7456-7560`) [V] |
| Existing run-time top-level frames | `moho/app/WxRuntimeTypes.cpp:1478` `WWinManagedFrame` (registry `managedFrames`, destroyed in `WINX_Exit` `WinApp.cpp:3294-3309`), `WEmitterWx`, log window | wx 2.4.2 frames are created/destroyed at run time today, and prefs persistence exists (`Windows.Log.x/y/width/height`, `:308-311`) [V] |

Not found: any `D3DPRESENT_PARAMETERS` use outside `GetHeadParameters`; any `CD3DWindow` class (the window class is
`WD3DViewport`, `moho/render/d3d/WD3DViewport.h:34`, a `wxWindow` that calls `CD3DDevice::Paint` from `EVT_PAINT`,
`WxRuntimeTypes.cpp:99-102,225-240`).

## 2. Rendering: what is shared, what breaks

Frame flow [V]: `CScApp::Main` calls `device->Refresh()` (`CScApp.cpp:1082`) -> `ren_Viewport->Refresh` -> `WM_PAINT` on the
viewport -> `WD3DViewport::OnPaint` -> `CD3DDevice::Paint` (`CD3DDevice.cpp:1693-1730`): `Present()` of the *previous*
frame, then `WRenViewport::D3DWindowOnDeviceRender` (`WxRuntimeTypes.cpp:3433-3470`) which loops `head < mNumHeads`
and calls `Render(head, worldViews)` (`:3696`). `Render` does per head: `UI ValidateFrame(head)`, `BeginScene`,
`SetRenderTarget2(head, clear...)`, `RenderFrames(head)`, then world passes, bloom, silhouette, UI draw
(`:3742-3761` and following). Main loop is single threaded (`WinApp.cpp:2478-2509`).

Shared (one object, any window can use it) [V/I]: the `IDirect3DDevice9`, all textures, vertex/index buffers, effects,
the pipeline-state cache, `CD3DPrimBatcher` / `CD3DTextureBatcher` / `CD3DFont` (owned by `WRenViewport`,
`WxRuntimeTypes.cpp:3262-3277`), dynamic texture sheets. So a second swap chain costs almost nothing in resources.

Per-head (the reason A is large) [V]:
- 3 full-size targets per head (primary, secondary, depth) + bloom pair (`D3DWindowOnDeviceInit`, `:3302-3330`).
- `CD3DDevice::mRenderTargetLocks[2]` rebuilt in `SetRenViewport` / `InitContext` from `GetHeadOutputContext(i)`
  (`CD3DDevice.cpp:402-413, 584-592`). `GetHeadOutputContext` throws for `i >= GetHeadCount()` (`D3D9Interfaces.cpp:2488-2497`).
- ~25 call sites of `GetHeadWidth/Height` outside `CD3DDevice.cpp` (15 in `WxRuntimeTypes.cpp`, 2 each in
  `MediumFidelityTerrain.cpp`, `HighFidelityTerrain.cpp`, `Silhouette.cpp`, 4 in `IUIManager.cpp`).
- Mouse scrub assumes head 1 = `GetHead(1).mWindow` (`UiRuntimeTypes.cpp:8910-8925`).

If a head were added after device creation (design A) [V/I]:
- **Back buffer size / device Reset.** Any change of the head list needs `IDirect3DDevice9::Reset`, which in this engine is
  `CD3DDevice::InitContext` (`CD3DDevice.cpp:368-438`): it releases *every* device-dependent resource (viewport exit,
  `ResetResourcesForContextTransition`, particle buffers, render-target locks), resets, and re-inits. The main window
  resize already pays this cost (`SyncSupComFrameClientSizeAndViewport`, `WxRuntimeTypes.cpp:1114-1158`, on
  `WM_EXITSIZEMOVE`/maximize, `:1351-1371`, head 0 only). Popping a panel out would stutter the whole editor.
- **Additional swap chains do not survive `Reset`** (D3D9 documented behaviour [I]) so whoever owns them must drop them
  on the device-exit event and recreate on device-init. `CD3DDevice` is a `Broadcaster<SD3DDeviceEvent>`
  (`CD3DDevice.h:99`, events sent at `CD3DDevice.cpp:389-390, 421-422`) which is the hook for that [V].
- **MSAA**: head MSAA comes from the `antialiasing` option for heads 0/1 (`CScApp.cpp:1295-1299`); the engine renders into
  its own targets and copies to the back buffer, so a pop-out chain can use `MULTISAMPLE_NONE` [I]. UI passes use
  technique `TAlphaBlendLinearSampleNoDepth` (`CUIManager.cpp:485`) so no depth surface is needed for UI-only windows [V].
- **wx 2.4.2 client-size bug**: `SetClientSize(1280,720)` yields 1280x729; the editor already works around it by sizing the
  back buffer to the actual client size (`CScApp.cpp:1384-1389`). Any new window must create its swap chain from
  `GetClientSize()` *after* showing it [V].
- **Present blocking**: head 0 uses the vsync option, others `D3DPRESENT_INTERVAL_IMMEDIATE` (`D3D9Interfaces.cpp:1910-1911`).
  A pop-out chain with the default interval would block the single main thread once per pop-out per frame; use IMMEDIATE
  and draw pop-outs only when dirty or at <= 30 Hz [I, O].
- **Hardware cursor**: the cursor is a D3D hardware cursor driven from `WD3DViewport::MSWWindowProc` on `WM_SETCURSOR`
  (`WxRuntimeTypes.cpp:257-283`); a new window class must repeat that or the cursor will be the Windows arrow [I, O].

## 3. Input: per head and per Maui frame

- Each root frame owns a `CMauiWxEventMapper` created in the `CMauiFrame` constructor (`UiRuntimeTypes.cpp:24509`); event table:
  all mouse events, key up/down, char (`:9823-9829`). `SetNewLuaState` pushes it on the head's input window and sets
  `mapper->mWindow` (`CUIManager.cpp:273-279`). So input routing is **per wx window -> per frame**, and works for any window
  that gets a frame via the same two calls [V].
- Hit testing: `ResolveTopInputCaptureControl()` (global `sInputCapture`, `UiRuntimeTypes.cpp:1806,1938`), else the mapper's
  own frame (`:9567-9570`). Mouse-over sentinel, current dragger, keyboard focus owner and mouse capture flag are
  **process globals, not per head** (`func_SetMouseCapture` `:9214-9232` uses `SetCapture` on the *origin* frame's window;
  `MAUI_SetKeyboardFocus` `:3194`). Consequences [V/I]: (a) dragging a panel from the main window to monitor 2 works for free:
  Win32 capture keeps delivering to the main window with out-of-client coordinates; (b) one keyboard focus owner exists
  across windows, which is the wanted behaviour; (c) `AddInputCapture` roots hit testing at the capture control for **all**
  windows (already a known editor trap, `MAP_EDITOR.md:286-290`).
- `AppDoSuppressWindowsKeys` / cursor clip look only at head 0 and `supcomFrame` (`CScApp.cpp:1485-1505`,
  `WxRuntimeTypes.cpp:1168-1200`); cursor lock `lock_fullscreen_cursor_to_window` must stay off while pop-outs exist [V].
- Keyboard: wx delivers key events to the focused HWND. Make the pop-out a `wxFrame` with one child `wxWindow` (like
  `WD3DViewport`) and `SetFocus` it on activate/click; the bare-frame pattern used for head 1 is not proven for keys [O].
- Layout events: `CUIManager::OnResize(head,w,h)` is called only from `D3DWindowOnDeviceInit` using *device* head sizes
  (`WxRuntimeTypes.cpp:3305-3307`), then Lua `OnApplicationResize` (`UiRuntimeTypes.cpp:25615`). A pop-out needs its own
  `EVT_SIZE -> OnResize(idx, clientW, clientH)` [V].
- **DPI**: no DPI call, manifest or per-monitor logic anywhere in `moho/app` or the project file [V grep]; wx 2.4.2 is
  DPI-unaware. Needs the process-level call already planned in `UI_CAMERA_FEASIBILITY.md` (item 10). Per-monitor scale changes
  while a window crosses monitors stay out of v1 [I].

## 4. Lifecycle: create, destroy, monitors, remembered rect

- Creating a wxFrame at run time is routine (log window, emitter editor) [V]. `wxApp::SetExitOnFrameDelete(true)`
  (`WinApp.cpp:2471`): the app exits when the **last** top-level frame is deleted, so pop-outs never end the app while the
  main frame lives [I]. Closing a pop-out must be handled by our own class: `WSupComFrame::OnCloseWindow` opens the
  escape dialog and `OnMove` overwrites `Windows.Main.x/y` (`WxRuntimeTypes.cpp:1243-1319`), so **do not reuse
  `WSupComFrame`** [V].
- Monitors: only `MonitorFromPoint` + `GetMonitorInfoW` in `ClampPositionToMonitor` (`CScApp.cpp:642-668`); no enumeration
  [V]. New natives need `EnumDisplayMonitors` (work area, DPI via `GetDpiForMonitor`) [I].
- Remember rect: store `{x,y,w,h,monitor}` per pop-out in the workspace file (Lua, `ed_write_file`), validate against current
  monitors on restore and clamp as `ClampPositionToMonitor` does. Pref keys of `WWinManagedFrame` show the engine pattern
  but are not required [I].
- Lua-state restarts (`LoadMap`, `SetNewLuaState`) recreate **all** frames empty (`CUIManager.cpp:229-282`); OS windows and
  swap chains may survive, panels are rebuilt from the workspace data [I].
- Teardown order: `CUIManager::ClearFrames` pops event handlers then destroys frames (`:302-334`); `CScApp::Destroy`
  shuts D3D down before destroying frames (`CScApp.cpp:1121-1141`) -> pop-outs must be destroyed before `D3D_Exit` [V].

## 5. Designs

### A. True additional heads (GAL heads at run time)

Make head count dynamic, windowed, and independent of adapter groups.
- Files: `gpg/gal/backends/d3d9/D3D9Interfaces.cpp` + `DeviceD3D9.hpp` (`AddHead/RemoveHead`, extra heads as additional
  swap chains, `GetDeviceParameters` limited to the implicit chain, `CreateHeads`, `Present` loop over chains, drop the
  `headCount > mAdapters.size()` and `mAdapter != 0` checks, `Reset` recreating chains); `gpg/gal/Device*.hpp/.cpp`,
  `DeviceContext.hpp`; `moho/render/d3d/CD3DDevice.{h,cpp}` (`mRenderTargetLocks[2]` -> N, `InitContext`, `SetRenViewport`,
  `Destroy`); `moho/render/WRenViewport.h` + `moho/app/WxRuntimeTypes.cpp` (all `[2]` arrays, `mNumHeads`, init/exit loops,
  `Render`); `CBloomRenderer`; `Silhouette.cpp`, `MediumFidelityTerrain.cpp`, `HighFidelityTerrain.cpp` (head size);
  `moho/app/CScApp.cpp` (window creation moved out of `CreateAppFrame`); `moho/ui/CUIManager.cpp` (`AddRootFrame`);
  `UiRuntimeTypes.cpp` (mouse scrub, `GetNumRootFrames`); FAF multihead Lua.
- Effort **12-18 days**. Risk **high**: touches the render core, three full-size targets plus bloom per pop-out (wasted for
  a panel host), `Render(head)` runs the whole world pipeline for each head even with no world view, `Reset` interplay,
  regressions in the main viewport.
- Gain over B: a viewport (world view with its own camera) can live on a pop-out head.

### B. One OS window per pop-out, own swap chain, own small Maui root (recommended)

Pop-outs are not GAL heads. They live next to the head system:
- A pop-out = `WEdPopoutFrame` (wxFrame, tool-window style, resizable) + child `WEdPopoutView` (`wxWindow`: `EVT_PAINT`,
  `EVT_SIZE`, `EVT_CLOSE`, `EVT_MOVE`, `WM_SETCURSOR` like `WD3DViewport`, activation) + an `IDirect3DSwapChain9`
  created with `CreateAdditionalSwapChain` (windowed, `DISCARD`, `A8R8G8B8`, `MULTISAMPLE_NONE`, `INTERVAL_IMMEDIATE`) at the
  *actual* client size + a Maui root frame.
- Maui plumbing reuses the existing arrays so that `GetFrame(id)`, `ValidateFrame`, `RenderFrames`, `SetToViewport`
  (`CD3DPrimBatcher.cpp:1620`, reads `mInputWindows[head]` client size) and the event mapper work unchanged:
  new `CUIManager::AddRootFrame(wxWindow*)` (body = one iteration of the `SetNewLuaState` loop,
  `CUIManager.cpp:252-282`) and `RemoveRootFrame(idx)` (pop handler, `Destroy`, **null the slot instead of erasing** so ids
  stay stable). Null-guards needed where a slot is dereferenced: `GetControlAtCursor` (`:546-562`), `DumpControlsUnderMouse`
  (`:572-587`), `ClearChildren`, `UpdateFrameRate` (already guarded). `GetNumRootFrames` must report only real heads
  (a new `mNumDisplayHeads`), otherwise FAF Lua enters its second-head code (`multihead.lua`, `gamemain.lua:313,457`).
- Render hook: one line at the end of `WRenViewport::D3DWindowOnDeviceRender` (after the head loop,
  `WxRuntimeTypes.cpp:3466`) calling `EdPopout_RenderAll()`. For each visible, dirty pop-out: `ValidateFrame(idx)`;
  `ClearTarget(OutputContext(swapchain backbuffer, null))` + `Clear` (pattern `CD3DDevice::BeginScene1`,
  `CD3DDevice.cpp:1024-1049`); `BeginScene`; `uiManager->RenderFrames(idx, ren_Viewport->GetPrimBatcher())`; `EndScene`;
  `swapChain->Present(...)`. Restore the main target afterwards (the next `Render` rebinds it: `SetRenderTarget2`,
  `WxRuntimeTypes.cpp:3755`).
- Reset safety: listen to `SD3DDeviceEvent` (exit: release back-buffer surfaces and swap chains; init: recreate at the
  window's current client size).
- Resize/move of a pop-out: recreate or `Reset`-free resize of that chain only (release chain, create at new size),
  `OnResize(idx, w, h)`; no device Reset.
- Files: new `moho/editor/EdPopout.{h,cpp}` (classes, manager, render, natives), new `gpg/gal/backends/d3d9/SwapChainD3D9.{hpp,cpp}`
  (thin wrapper: create, back buffer as `RenderTargetD3D9`, present, release; reaches `DeviceD3D9::mDevice`, public, via the
  `ActiveDeviceD3D9()` pattern, `D3D9Interfaces.cpp:252`), small edits in `CUIManager.{h,cpp}`, `Sim.cpp:16651` (root-frame
  count), `WxRuntimeTypes.cpp` (1 render hook), `EditorLua.cpp:771-801` (bindings), `main_ed.vcxproj` (2-3 new files).
  Lua side (outside the spike): `editor/runtime/lua/editor/popout.lua`.
- Effort **6-8 days** (GAL wrapper 1.5, wx classes + manager 2, CUIManager 1, natives + callbacks 1, hook/events 0.5,
  multi-monitor / cursor / focus debugging 1.5). Risk **medium**: cursor over extra windows, present pacing, focus/key
  routing, text fidelity on a differently-scaled monitor. Viewport pop-out is **not** covered (needs A or a later
  "world view on pop-out" extension, +6-10 days).

### C. Separate process (last resort)

A second `main_x64_la.exe` (or small host) drawing panels, state mirrored over a named pipe / files (like `/edcmd`).
- Files: new IPC natives in `moho/editor/` (~2 d), a replication protocol in Lua for every panel model (the bulk), process
  launcher, shared prefs. Engine start is 7 s with `/nosound`, 60-150 s with sound [`MAP_EDITOR.md:169,182`], so the helper
  must be a long-lived instance.
- Effort **8-12 days plus permanent upkeep**. Risk: double asset memory, state divergence, latency on every drag, undo and
  selection must cross a process boundary, drag-and-drop between windows impossible without OLE work. **Not recommended.**

### Recommendation

**B.** It delivers "drag a panel group out, put it on monitor 2, drag it back, remembered per workspace" without touching
the render core or the Reset path, keeps the viewport(s) on the main window (the fallback the design doc already
accepts, `MAP_EDITOR_DESIGN.md:204`), and leaves A open as a later extension for viewport pop-out.

## 6. Prototype plan (smallest useful slice of B)

### 6.1 Natives (new `moho/editor/EdPopout.cpp`, bound next to the others in `EditorLua.cpp:771-801`)

```
ed_window_create(x, y, w, h [, title]) -> id | nil, err   -- id = UI root-frame index (>= number of real heads)
ed_window_set_rect(id, x, y, w, h)     -> bool            -- outer rect, screen coordinates
ed_window_get_rect(id) -> x, y, w, h, clientW, clientH, monitorIndex
ed_window_destroy(id)  -> bool
ed_window_capture(id, path) -> bool                       -- D3DXSaveSurfaceToFile of the pop-out's back buffer copy
ed_monitors() -> { {x,y,w,h, wx,wy,ww,wh (work area), dpi}, ... }
```
`ed_window_list()` (ids), `ed_window_set_title(id, s)` and an event callback
`import('/lua/editor/popout.lua').OnWindowEvent(id, 'close'|'move'|'size'|'activate', a, b)` follow right after.
The prototype needs only create / destroy / get_rect / set_rect / capture, `GetFrame(id)` from existing Lua, and the
Maui controls already in the engine.

Implementation order (each step testable): (1) `CUIManager::AddRootFrame/RemoveRootFrame`, `GetNumRootFrames` guard;
(2) `SwapChainD3D9` wrapper; (3) `WEdPopout*` classes + manager + render hook; (4) device-event listener; (5) natives.

### 6.2 Test procedure with the existing channels

Start: `python scripts/ed_run.py --edcmd` (writes `engine_decomp/run_x64/edcmd.lua`, answer in `edcmd.lua.out`;
`MAP_EDITOR.md:189-191`). Capture: the existing `PrintWindow(..., PW_RENDERFULLCONTENT)` approach per HWND, plus
`ed_window_capture` as the reliable path (`PrintWindow` on an extra D3D window is unverified [O]).

0. **No-code baseline, 5 minutes**: run once with `/dualhead 1280 720 800 600` (windowed flags not accepted) and read
   `run.log`: expected `unable to create device` / `invalid head count` (`D3D9Interfaces.cpp:408-411, 1779-1786`), proving
   why A's premise fails on this hardware. [O, not run]
1. **Create**: `return ed_window_create(2000, 100, 640, 480, 'T1')` -> `OK: 2` (id 2 = first index after the main head).
   Check: `GetNumRootFrames()` still 1; `GetFrame(2):GetTargetHead()`, `GetFrame(2).Width()` equals `clientW` from
   `ed_window_get_rect(2)`.
2. **Draw**: chunk builds `local f = GetFrame(2); local b = Bitmap(f); b:SetSolidColor('ff3366aa'); LayoutHelpers.FillParent(b,f)`
   and a `UIUtil.CreateText(f,'popout 2',24)`; screenshot of the window shows the colour and text; main window unchanged.
3. **Resize / move**: `ed_window_set_rect(2, 200, 150, 900, 500)` then `get_rect`; screenshot again; frame width follows
   the client size (check the wx +9 px case), no device Reset in `run.log` (no `InitContext` re-init lines).
4. **Monitor**: with `ed_monitors()` pick monitor 2, `set_rect` onto it, screenshot; repeat on a monitor with a different scale
   (DPI risk, text sharpness).
5. **Input**: script moves the cursor with `SetCursorPos` + `mouse_event` over the pop-out (method used in `MAP_EDITOR.md:283`);
   the bitmap's `HandleEvent` stores into a global; next `/edcmd` reads it. Also: mouse-over highlight, wheel, a keyboard
   edit box (`Edit` control) typed into with `SendInput`, cursor shape over the window.
6. **Cross-window drag**: press on a main-window control that starts a `Dragger`, release over the pop-out; the dragger
   gets screen coordinates (per `UI_CAMERA_FEASIBILITY.md` table row `Dragger`; capture set in `UiRuntimeTypes.cpp:9241-9266`); verify `OnRelease` data and that capture was released.
7. **Reset survival**: resize the main window (`SetWindowPos` + `WM_EXITSIZEMOVE` or maximize) -> `InitContext`; the pop-out
   must redraw afterwards at the same size (swap chain recreated by the init event); also minimise/restore the main window.
8. **Lifecycle soak**: create/destroy 50 times in a loop thread (`ForkThread` with `WaitSeconds`), check `run.log`, process
   handle / GPU memory growth, no crash; destroy with open drag; destroy pop-out while mouse is over it; close with the
   system X button -> `OnWindowEvent('close')` and no escape dialog.
9. **State change**: `LoadMap(...)` (Lua state restart) with a pop-out open -> window survives, frame is empty and live again,
   no stale `mInputWindows` access (`CUIManager.cpp:252-282` re-creates its frame).
10. **Perf**: frame time of the main viewport with 0 / 1 / 3 pop-outs, static vs animating content.

### 6.3 Build

`main_ed.vcxproj` x64 Release as for the existing `moho/editor/EditorLua.cpp` (`MAP_EDITOR.md` build notes); only new
translation units + the small edits listed in section 5-B. wx must **not** need a rebuild (no `wx/` header changes).
Pass criterion for the spike: steps 1-3 and 7 work and a 50x create/destroy soak is clean.

## 7. Open points

- [O] Does this machine report an adapter group? (only matters for A.)
- [O] D3D hardware cursor over pop-out windows via our own `WM_SETCURSOR`; fallback = GDI cursors made from the Maui
  cursor textures.
- [O] `PrintWindow` on the extra D3D window; fallback `ed_window_capture`.
- [O] Present pacing with 2-3 pop-outs on 2 monitors with different refresh rates (throttle to dirty-only).
- [O] Key delivery to a child `wxWindow` in a tool-window `wxFrame` on wx 2.4.2 x64 (IME not tested).
- [O] Whether the Maui cursor, tooltips and drop-down popups (which the design plans as controls inside the main frame) can
  extend outside a pop-out's client area: they cannot (clipped to the window); panels with large popups must reserve room.
- [I] Pop-out frames cost one `Frame(delta)` tick each (`UpdateFrameRate`, `CUIManager.cpp:339-347`); closed windows must
  release their frame so `PurgeDeleted` keeps running only for live frames.
