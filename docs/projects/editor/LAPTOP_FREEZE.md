# Hybrid laptop freeze (NVIDIA RTX 4060 Laptop + Intel): handoff

Status 2026-10-26. The editor freezes for good on the user's laptop (Windows 11, Intel iGPU + RTX 4060 Laptop GPU, Optimus; screen 3200 x 2000, 150 percent scaling,
window 3200 x 1876). It does not on the AMD desktop (RX 7900 XTX). Everything below was found by reading code and crash reports from the laptop; none of the fixes is
confirmed there. The next step is to debug on the laptop itself.

## Set up the laptop (about 30 minutes)

```
git clone --recurse-submodules https://github.com/UnsilentMarLo/FAF_Studio.git
cd FAF_Studio
python scripts/studio.py doctor            # lists what is missing
python scripts/studio.py engine --no-bump build     # CMake + clang-cl; --no-bump keeps VERSION unchanged
python scripts/studio.py engine --no-bump stage
python scripts/editor_inst.py new dev
python scripts/editor_inst.py start dev --map editor_blank
```

Needs: Visual Studio 2022 / 2026 with the C++ tools (CMake and Ninja come with it), LLVM (clang-cl), the June 2010 DirectX SDK (d3dx9), Python 3, xmake (edtext.dll),
Forged Alliance with the FAForever client installed once. README.md and docs/REPOSITORY.md have the details; CLAUDE.md has the rules for agents.
The engine is the submodule `engine/faf-re` (fork UnsilentMarLo/faf-re, branch `editor`): `git -C engine/faf-re log` shows the editor commits.
The build writes a PDB (`engine/faf-re/build/editor-x64/src/main_ed_x64.pdb`): attach a debugger to a frozen editor and the stacks are symbolized.

## How to look at the freeze

1. Start the editor from the dev build, let it freeze, attach WinDbg or Visual Studio (Debug > Attach to Process) and take the stacks of all threads (`~* kb`). The main
   thread is the one that owns `UserPrefs` in the crash report ("UserPrefs: opened on tid ..."). Past reports only had the driver frames (`nvd3dumx.dll+0x15289C`,
   a wait on an event or semaphore) because the unwinder stops inside the driver: a debugger with the NVIDIA symbols gets further.
2. Without a debugger the editor writes a report by itself: when the main loop is silent for 12 s it writes `faf_crash_<time>.txt` next to the exe (all thread stacks, Lua state,
   recent log; `EdPerf.cpp` FreezeWatchdogMain). Writing takes about 30 s: wait a minute before killing the process.
3. The log lines `EDITOR device reset: ...`, `EDITOR D3D9 adapter ...` and `EDITOR D3D9 Reset parameters ...` (CD3DDevice.cpp, D3D9Interfaces.cpp) show each device reset and the
   adapters. The Display report (File > Settings > Display report) prints the exe build, adapter, driver, monitor refresh, frame cap and level of detail.

## What is known

* All freezes happened right after a `IDirect3DDevice9::Reset` of the editor's single D3D9 device (AA click, V-Sync click, and the startup reset that the FAF game's saved
  `antialiasing` option requests), once the editor had presented its first frames. Resets before the first Present, and resets with a real window size change (maximize),
  worked.
* In the last reports the main thread waits in `nvd3dumx.dll` (NVIDIA D3D9 user mode driver) and a worker thread (the prefetcher, `D3DXCreateTextureFromFileInMemoryEx`)
  waits for the D3D9 device lock behind it (the device is created `D3DCREATE_MULTITHREADED`). The Intel driver (`igd9trinity64.dll`) is loaded too (the D3D9 runtime
  enumerates both adapters) but only idle.
* The window is also hit by "seconds of flicker and invisible UI" when minimized and restored (reported before the freezes).

## Bugs found and fixed on the way (all in `engine/faf-re`, branch `editor`)

* `GetAntiAliasingOptions` packed `type | quality << 5`; every reader and the FAF client use `(type << 5) | quality` (256 for 8x). Fixed.
* `SC_AntiAliasingSamples <n>` forwarded its own name (token 0), so the game's AA option never did anything. Fixed.
* Closing a pop-out left a null window in `CUIManager::mInputWindows`; `FlushEvents` crashed at the next map open. Fixed.
* The editor offers no swap chain anti-aliasing when any NVIDIA D3D9 adapter is installed (8x was active at the first freeze).
* Device changes from UI (AA, V-Sync, size) are queued and applied at the top of `CScApp::Main` (`ED_ApplyPendingDeviceContext`), not inside a window message.
* A Reset that would change nothing is skipped (`ED_D3D9ResetWouldChange`); V-Sync stays On when an NVIDIA adapter is installed.

## Hypotheses still open (in the order I would test them)

1. **A Reset after the first Presents deadlocks the NVIDIA D3D9 driver** (the Optimus present path through the Intel display adapter, a cross-adapter copy). Test: run
   with the device created on the Intel adapter (`SC_PrimaryAdapter`, `D3D9Interfaces.cpp` adapter selection) and see whether the freeze goes; force a Reset from a console
   command on a fresh start, before and after the first frames.
2. **`D3DCREATE_MULTITHREADED` plus the prefetcher thread**: another thread inside a D3D9 call while the main thread resets. Test: stop the prefetcher
   (`res_PrefetcherActivityDelay` large) and repeat.
3. **The additional swap chains of pop-out windows** (EdPopout.cpp) or the second D3D11 device of the GPU compute (EdGpu*.cpp, same adapter) while the D3D9 device resets. Test:
   `gpu_compute` Off, no pop-out open.
4. **The editor's frame limiter** (EdPerf.cpp: waitable timer, 60 fps idle cap): unlikely, the freeze also happened with the limiter's state `active`, but switch it off
   (`ed_fps_throttle 0`).

## Anti-aliasing options (from another session)

The retail swap chain MSAA ("SAA") is a D3D9 feature; upstream faf-re now has D3D11 / D3D12 / Vulkan backends where only post process anti-aliasing (FXAA, SMAA, TAA) is
sensible. The editor's natives (EdGpuLua, EdMeshDraw, EdPopout) cast the GAL device to `DeviceD3D9`, so the editor runs on D3D9 only (`CScApp.cpp` RendererAttemptOrder). A
post process FXAA / SMAA pass in the editor's own render path would give every adapter smooth edges without a multisampled back buffer and make the swap chain MSAA (and
the NVIDIA special case) unnecessary.

**Done 2026-10-27 (branch `fxaa`): FXAA** is a state of the Anti-aliasing setting (`ed_fxaa`), one full-screen pass on every adapter, UI unfiltered, no device Reset to switch it. See FXAA.md. It still has to be tried on this laptop.


## Findings from the laptop (2026-11-03, packaged 0.6.1 build, revision da6ce9e)

Machine: Windows 11 26200, Intel Arc iGPU (32.0.101.6881) + RTX 4060 Laptop (32.0.15.6626), one active display (3200 x 2000 panel), window 3200 x 1876, UI 150 %.
**D3D9 enumerates exactly one adapter: the RTX 4060** (`EDITOR D3D9 adapter 0 (head 0)`). The Intel adapter is not a D3D9 adapter here, so hypothesis 1 ("create the device on the
Intel adapter") cannot be tested through `SC_PrimaryAdapter` (that console command is a resolution command anyway); it would need the Windows graphics preference of the exe.

Method: the packaged exe was started with `/windowed 3200 1876 /map editor_blank /edcmd <file>` (the exe adds `/init` itself; no engine build needed), Lua chunks were run through the
command channel, and a frozen process was walked with `dbghelp` + `symbols\main_ed_x64.pdb` (`StackWalk64` from a small ctypes script; no debugger installed). The script, the
launcher and every log are in `evidence\` of the handoff folder (not committed).

### Runs

| run | state | trigger | result |
|---|---|---|---|
| 1 | default start, 6 min idle | none (startup AA request skipped: "leaves the device parameters as they are") | alive, responsive |
| 2 | default, no pop-out | start | alive; start screen and panels drawn correctly at 3200 x 1876 |
| 3a | `FAFSTUDIO_NVIDIA_AA=1`, **no pop-out** | 16 AA resets (2x, 4x, 8x, off, repeated, 20-27 ms each) | **no freeze**, longest frame about 200 ms |
| 3b | same, **Settings pop-out open** | AA 4x | **FREEZE** (`faf_crash_20261103_102642`) |
| 4 | same, pop-out open 60 s first (no reset: fine, 48-60 fps) | AA 4x | **FREEZE** |
| 5 | default, pop-out open; main window resize / maximize / restore | size resets (46 ms) | no freeze |
| 5b | same run | `SC_VerticalSync 0` (reset, MSAA 0, interval IMMEDIATE) | **FREEZE** |
| 6 | pop-out open **and minimized** | `SC_VerticalSync 0` | **FREEZE** |
| 7 | pop-out opened, then **closed** (`shell.CloseWindow`) | `SC_VerticalSync 0` | no freeze (reset 23 ms) |
| 8 | pop-out open; maximize, restore, minimize, restore, 3 resizes (2 of them reset the device) | window changes | no freeze, no "device lost", longest frame 179 ms |

### What the freezes are

All four freezes have the same stacks (`evidence\run*_freeze.stacks_symbolized.txt`):

* **Main thread**, in the paint of the main window after the Reset had returned (`IDirect3DDevice9::Reset returned after 9-22 ms`, resources recreated, viewport relaid out):
  `ntdll!NtWaitForSingleObject <- nvd3dumx+0x1534cd <- nvd3dumx+0x158039 <- d3d9+0x11086 <- d3d9+0x10648 <- d3d9+0x10335 <- TextureD3D9::Lock (D3D9Interfaces.cpp:5704) <-
  CD3DDynamicTextureSheet::Lock (:162, D3DLOCK_DISCARD) <- CD3DTextureBatcher::GetCompositeTexture (:376) <- CD3DPrimBatcher::Flush <- CMauiBitmap::DoRender <- CUIManager::DrawHead <-
  WRenViewport::Render <- CD3DDevice::Paint <- WD3DViewport::OnPaint <- wxWindow::HandlePaint <- WIN_AppExecute`.
  It is **not inside Reset**. It is the first discard-lock of the UI atlas texture that `GetCompositeTexture` recreates after the Reset ("the sheet was released by OnDeviceExit").
* **One NVIDIA driver thread** waits on a GPU synchronization object from the CPU: `win32u!NtGdiDdDDIWaitForSynchronizationObjectFromCpu <- d3d9+0x6a74f <-
  nvd3dumx!QueryOglResource+0x37473 <- nvd3dumx+0x5691f ...` (tid 1952 in run 3b). It never returns, so the lock never gets its buffer. A driver deadlock on a sync object, not a GPU hang
  (Windows TDR did not fire; the window stays "Not responding" for ever).
* **Everything else is idle**: the prefetcher thread waits on its condition variable (`ResourceManager::PrefetchThread`), the sim threads wait, the Intel driver threads
  (`igd9trinity64`) wait on condition variables, 23 more `nvd3dumx` worker threads wait at the same spot. Nobody else holds the device lock. **Hypothesis 2 (prefetcher plus
  MULTITHREADED) is refuted for this freeze.** Hypothesis 3b (GPU compute's D3D11 device): no thread of it is in a D3D wait, and compute was On in all runs, so it is not involved.
* The on-screen picture is the last presented frame (run 6 shows the splash "Loading map..." frame): this is the "frozen for good" the owner sees.

### Condition (reproduced 4 times out of 4, scripted)

Freeze needs **both** of:
1. a **pop-out window is alive** (even minimized; EdPopout.cpp has created an additional swap chain for it before), and
2. a **Reset that does not change the back buffer size** (AA mode change, V-Sync interval change).

Not sufficient: a pop-out alone (60 s, 5 min), any number of Resets without a pop-out (16 AA resets), a Reset that changes the size with a pop-out open (maximize, restore, resize),
a pop-out that was opened and closed again before the Reset. Closing the pop-out window removes the problem; releasing its swap chain (the DeviceListener does that on the exit event of
every Reset) does not, and hiding or minimizing the window does not. That fits the history: the AA and V-Sync buttons are in the **Settings pop-out**, so every click
that reset the device happened with a pop-out open (the startup reset only froze when a saved workspace had pop-outs; not checked).
Hypothesis 4 (frame limiter) and the NVIDIA AA list as such are not needed for it (the V-Sync case has MSAA 0 throughout). Sample sizes are small (one run per row for the
non-freezing cases with a pop-out), the freezing cases are 4 of 4.

### Is it reachable in 0.6.1 by a user?

Not by the Settings panel: on an NVIDIA machine the panel offers only AA Off / FXAA and V-Sync On (`graphics.lua`, `VSyncStates`, `Get`), a saved other value is sanitized, and a
Reset that changes nothing is skipped. It is reachable by the Console panel (`SC_VerticalSync 0`, `SC_AntiAliasingSamples <n>` with `FAFSTUDIO_NVIDIA_AA=1`) with a pop-out open,
and by any future code path that makes a same-size Reset. Window moves, resize, maximize, minimize and restore with a pop-out open were stable (run 8).

### Proposed mitigation (not implemented, needs an engine build: this laptop has no VS C++ tools, clang-cl, DirectX SDK or xmake yet)

In `ED_ApplyPendingDeviceContext` (CD3DDevice.cpp): when an NVIDIA D3D9 adapter is installed (`ED_NoteNvidiaAdapterInstalled`) and a pop-out exists, refuse a Reset that keeps the back
buffer size and say so in the log / console; or close the pop-outs before such a Reset and reopen them after it (a pop-out that was closed first is safe, run 7). The second is
more work and has to be tested; the first is a few lines and equals what the Settings panel already does in Lua. Either needs the recipe above as its before / after test.
The cause itself (an NVIDIA / Optimus driver deadlock after a same-size Reset while the window of an additional swap chain exists) is in the driver; I found no workaround on the
swap chain side without a build to try variants (for example drawing the pop-out into a render target and blitting it, instead of an additional swap chain).

### Other findings

* **Lua bug, not hardware specific, fixed** (`gui/widgets.lua`, `AutoFit` / `Refit`): opening the Settings pop-out logged `EDITOR panel:settings.OnResize: failed: skin.lua(52): stack overflow`
  on every run. `Apply` stores `fitDone = nil` for a room of `Skin.S(8)` or less, `Refit` compared the raw room with it, so a button label in a host that has no width yet (a pop-out whose
  frame is 0 wide when the tree is set) re-applied itself through `onText -> Center -> Refit` for ever. Fix: `Refit` normalizes the room the same way. Before: one overflow line per
  Settings open (runs 3-8). After (run 9, scratch copy of the package with the fixed file): none, and the panel is laid out correctly (`evidence\run9_fixed_settings_screen.png`).
  Not verified: the other panels that open as pop-outs; the nightly `layout` step (no staged engine here).
* **Level of detail**: after start the camera's LOD scale is 0.70 (Display report, and the Oct 26 `diagnostics.txt` of this laptop says 0.700 too) although the saved "Model detail" is
  High. `SC_CameraScaleLOD 2 / 1 / 0` gives exactly 0.90 / 1.00 / 1.20 afterwards. So the saved setting is not in effect after start on this laptop (applied before the camera exists, or
  overwritten); a scale of 0.70 makes models drop to their low LOD earlier, a candidate for "units fade early". Cause not found; check whether the desktop shows 0.70 too.
* **Frame rate**: the engine reports a 165 Hz monitor and a cap that follows it (173), but the loop runs at 60 fps (frame 16.7 ms, vsync on, state active). Which of the two is right for the
  panel was not checked.
* **GPU compute** works on the RTX 4060 (D3D11 feature level 11_0, all four self tests pass in 53 ms). It is not the freeze trigger.
* Idle frame cost on `editor_blank` at 3200 x 1876: 55-60 fps, frame 16.7-18 ms with limiter wait 13 ms, render CPU 1.3 ms, Present 1.5 ms (adapter: RTX 4060). A Reset costs a 150-200 ms frame.
* `python scripts/studio.py check`: lint and dialect pass (0 errors); `mission api` fails with "the table is out of date with the game's Lua (lua.nx2)", identically on the clean tree
  (the installed FAF game's Lua differs from the table), so it is not caused by this branch.

### Not done on this laptop (so unverified)

The layout checker and the nightly steps (they need a staged engine and therefore a build), camera-distance symptoms (grid flips, icon fade) beyond the LOD number above, Maui clipping
checks by screenshot of every panel, FXAA by eye, open-map time, the Priority 3 items. Only the packaged exe was run; no engine code was changed.
