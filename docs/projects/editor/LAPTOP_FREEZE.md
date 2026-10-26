# Hybrid laptop freeze (NVIDIA RTX 4060 Laptop + Intel): handoff

Status 2026-10-26. The editor freezes for good on the user's laptop (Windows 11, Intel iGPU + RTX 4060 Laptop GPU, Optimus; screen 3200 x 2000, 150 percent scaling,
window 3200 x 1876). It does not on the AMD desktop (RX 7900 XTX). Everything below was found by reading code and crash reports from the laptop; none of the fixes is
confirmed there. The next step is to debug on the laptop itself.

## Set up the laptop (about 30 minutes)

```
git clone --recurse-submodules https://github.com/UnsilentMarLo/FAF_Studio.git
cd FAF_Studio
python scripts/studio.py doctor            # lists what is missing
python scripts/studio.py engine --no-bump build     # CMake + clang-cl; --no-bump keeps VERSION at 0.5.0
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
