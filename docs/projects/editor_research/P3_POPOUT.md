# Pop-out prototype (design B) results (2026-10-17)

Status: **works**. Panels can live in their own native windows on their own swap chains, with their own Maui root frame, mouse and keyboard input,
resize, close, reset survival and Lua-state restarts. Not covered: a second monitor, cross-window drag, hardware cursor shape, DPI.
Tests: `editor/textlab/p3_*.lua` through the `/edcmd` channel; captures with `PrintWindow` (`editor/textlab/shot.py`) and the native capture.

## What was built (all new code under `moho/editor/`, small hooks elsewhere)

| Piece | Where |
|---|---|
| Window classes, swap chain management, render, Lua natives | new `moho/editor/EdPopout.{h,cpp}`: `wxFrame` + child `wxWindow` (own `EVT_CLOSE`/`EVT_SIZE`; `WSupComFrame` is not reused), `IDirect3DSwapChain9` per window (`CreateAdditionalSwapChain`, windowed, discard, `D3DPRESENT_INTERVAL_IMMEDIATE`, no depth), natives `ed_window_create / destroy / get_rect / set_rect / capture` |
| Root-frame registry | `CUIManager`: `AddPopoutFrame` (registers the window, creates its Maui root frame at once), `RemovePopoutFrame` (pops handlers, destroys the frame, **nulls the slot**), `CreateRootFrameForHead` (the old `SetNewLuaState` loop body, shared), `mNumDisplayHeads`; null guards in `SetNewLuaState`, `GetControlAtCursor`, `DumpControlsUnderMouse`, and the suspend / restore handler loops in `UiRuntimeTypes.cpp` |
| Head count seen by FAF Lua | `GetNumRootFrames` returns `mNumDisplayHeads` (real heads), so `multihead.lua` etc. stay off: verified `GetNumRootFrames() == 1` with pop-outs open |
| Render hook | one line at the end of `WRenViewport::D3DWindowOnDeviceRender`: `edpopout::RenderAll()`; per window: `ValidateFrame`, bind the swap chain back buffer with raw `SetRenderTarget` (depth surface off), clear, `BeginScene`, `RenderFrames` + `DrawUI` + `DrawHead` with the viewport's prim batcher, `EndScene`, capture if requested, `Present`; the main targets are restored afterwards |
| Reset safety | device-exit listener (event type 1, which a reset sends with `mShouldReleaseTextures` false) releases the swap chains; `RenderAll` recreates them at the window's client size |

## Results of the planned test steps

| Step | Result |
|---|---|
| 1 Create | `ed_window_create(120, 120, 640, 480, 'T1')` -> id 1 (= root-frame index), `GetNumRootFrames` 1, `GetFrame(1)` is 624 x 441 = the window's client size (wx +16 / +39 non-client) |
| 2 Draw | a Maui `Bitmap`, an `ed:` LCD `Text` and a legacy Arial `Text` in the pop-out's root frame render correctly in the pop-out window; the main window is untouched. `PrintWindow` captures an extra D3D window correctly |
| 3 Resize / move | `ed_window_set_rect(1, 200, 150, 700, 400)`: outer 700 x 400, client 684 x 361, swap chain 684 x 361 on the next frame, stable; no device reset |
| 5 Input | synthetic window messages to the pop-out: `MouseEnter`, `MouseMotion`, `ButtonPress`, `ButtonRelease` arrive in the pop-out's own frame at the right local coordinates (60, 50); `WM_CHAR` x y z reach an `Edit` control in the pop-out and are inserted (`xyz`); the Edit must call `AcquireFocus` after the window exists |
| 7 Reset survival | resizing the main window twice (device resets): the pop-out redraws at its size and the main window is intact |
| 8 Lifecycle | 50 x create / destroy twice in a row (controls in every window): created 50, destroyed 50, failed 0; private memory 718 MB -> 718 MB and handles 938 -> 937 between the two runs (no leak); closing with `WM_CLOSE` (the X button) removes the window cleanly, no escape dialog, `ed_window_get_rect` returns nil afterwards |
| 9 State restart | `LoadMap` (Lua state restart) with a pop-out open: the window and its swap chain survive, the root frame is recreated empty and can be drawn into again (`GetFrame(id)` works) |
| 10 Perf | main frame delta with static pop-outs (40 labels each, redrawn every frame): 0 pop-outs 4.17 ms, 1 pop-out 4.16 ms, 3 pop-outs 6.0 ms |

## Findings and open items

- Pop-out slots are never reused: after 100 create / destroy cycles the next id was 102. Harmless but the registry grows; reuse freed slots (or compact) later.
- **Cost is per window per frame**: a pop-out is redrawn every frame. Redraw only when a control changed (dirty flag from the frame) or throttle to 30 Hz.
- `ed_window_capture(id, path)` writes the PNG on the next frame; the path must be absolute and use forward slashes in Lua (Moho Lua strings treat `\U` etc. as escapes; a relative path did not land in the engine's working directory).
- Surfaces: the swap chain back buffer is `X8R8G8B8` (windowed `D3DFMT_UNKNOWN`); `GetRenderTargetData` needs a system surface of the same format.
- Not tested: a second monitor and placement / remembered rect, cross-window drag (the dragger capture should work from the main window), the D3D hardware cursor over pop-outs (the OS arrow is used), DPI per monitor, popups that exceed a pop-out's client area, key delivery with a real keyboard and IME (only synthetic messages), `ed_window_set_title`, an event callback for close / move / size to Lua.
- Shutdown: pop-outs are released by the device-exit event, but they are not destroyed before `D3D_Exit` explicitly (the spike's note); add a destroy-all at application exit.
- Divergence from upstream: `CUIManager.{h,cpp}`, `Sim.cpp` (`GetNumRootFrames`), `UiRuntimeTypes.cpp` (suspend / restore loops), `WxRuntimeTypes.cpp` (include + one call), `main_ed.vcxproj`; new `moho/editor/EdPopout.{h,cpp}`.

## Polish round (2026-10-17, later)

- **Dirty-driven redraw:** a pop-out is redrawn on input / focus messages (`MSWWindowProc`), resize, `ed_window_invalidate`, a device reset, and a 100 ms heartbeat. 3 static pop-outs:
  main frame 4.154 ms (was 6.0 ms; 0 pop-outs 4.166 ms).
- **Second monitor:** the test machine has two monitors (second at x = -2048); a pop-out placed there reports monitor index 2, its swap chain follows the client size (504 x 321 tested) and
  `PrintWindow` captures it.
- **Slot reuse:** create a, b, c; destroy b; create d -> d takes b's id (1, 2, 3, 2).
- **Events for Lua:** `ed_window_poll_event()` returns `close` / `move` / `size` (move and size coalesced); `ed_window_set_defer_close(id, true)` makes the X button only post `close`
  (verified: the window stays until Lua destroys it).
- **Also added:** `ed_window_set_title`, `ed_monitor_count` / `ed_monitor_info`, `ed_main_window_rect`, destroy-all in `CScApp::Destroy`. Events from before an id exists are dropped.
- Still untested: cross-window drag, hardware cursor shape, DPI per monitor, real keyboard and IME in a pop-out.
