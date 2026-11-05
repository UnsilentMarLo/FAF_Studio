# Direct3D 11 only (2026-11-05)

Decision (owner, 2026-11-05): Direct3D 9 is dropped from FAF Studio, Direct3D 11 is the baseline. Reason: the FAF community retires Direct3D 9 (lobby flags keep players without a DX11 GPU out of lobbies that need it),
the fork's map-format work is built on Direct3D 11 and later, and the editor's last Direct3D 9 specialities (swap chain anti-aliasing, device Resets, the NVIDIA workarounds) were the cause of the hybrid laptop freeze
(LAPTOP_FREEZE.md). Engine branch `editor-d3d11` of `UnsilentMarLo/faf-re` (the editor branch with this change; `editor` itself still has the Direct3D 9 editor).

## What the editor does now

* **The renderer is Direct3D 11 and nothing else.** `CScApp.cpp` `RendererAttemptOrder` returns `{Direct3D11}` in an editor build; `/d3d9`, `/D3D10`, `/d3d12`, `/vulkan` on the command line and the `graphics_api` option the FAF client
  saves are ignored with a log line (`renderer: ... the editor runs on Direct3D 11 only`). There is no Direct3D 9 fallback: when the device cannot be made the start fails.
* **The natives draw on the raw Direct3D 11 device.** `moho/editor/EdD3D11Device.h` (`D3D11RawDevice`, `D3D11RawContext`, `D3D11Gal`) replaces `EdD3D9Device.h`. A native that changes pipeline state outside the
  engine's `PipelineStateD3D11` saves what it changed and puts it back (`EdMeshDraw.cpp` `SavedState`), what the Direct3D 9 state blocks did.

| Native | Direct3D 9 (before) | Direct3D 11 (now) |
|---|---|---|
| Pop-out windows (`EdPopout.cpp`) | `CreateAdditionalSwapChain`, the UI drawn into its back buffer, `GetRenderTargetData` + `D3DXSaveSurfaceToFile` for captures | one flip-model DXGI swap chain per window (`CreateSwapChainForHwnd`, no vsync); the UI is drawn into an engine render target (a gal `OutputContext` without depth), `CopyResource` to the chain's buffer, `Present(0, 0)`; `ed_window_capture` copies to a staging texture and writes the PNG with WIC. The target is released on the device exit event and made again lazily |
| FXAA timing (`EdFxaa.cpp`, `ed_fxaa_time`) | `IDirect3DQuery9` timestamps | `ID3D11Query` timestamp + disjoint. The gate "swap chain anti-aliasing is on: do nothing" is gone: a flip-model swap chain is never multisampled |
| GPU compute adapter match (`EdGpuLua.cpp`) | `GetCreationParameters` / `GetAdapterIdentifier` | `IDXGIDevice::GetAdapter` of the game's own device (the compute device is still a separate Direct3D 11 device, now on the same adapter by construction) |
| Mesh terrain (`EdMeshDraw.cpp`) | SM 3 shaders (`D3DXCompileShader`), state blocks, `D3DPOOL_MANAGED` buffers | the same shaders as SM 4 (`D3DCompile`, constant buffers b0, `Texture2D` + `SamplerState`), immutable buffers, textures through `d3dx11_43.dll` (`D3DX11CreateTextureFromMemory`), eleven sampler states, blend / depth / rasterizer states, a saved and restored pipeline |
| Device Reset (`CD3DDevice.cpp`) | the editor queued Resets (`ED_ApplyPendingDeviceContext`), watched them (15 s watchdog) and made them in two steps on NVIDIA once a pop-out had existed | gone: size and vsync changes call the stock `InitContext` (a Direct3D 11 "Reset" is a `ResizeBuffers`), nothing is queued, no two-step, no watchdog |
| Anti-aliasing | swap chain MSAA modes (not offered on NVIDIA), FXAA | **FXAA or Off.** A saved Direct3D 9 packed mode reads as Off (`graphics.lua`) |
| V-Sync | Off / On (only On on NVIDIA: a Reset froze the laptop) | Off / On everywhere |
| `ed_present_wait`, `ed_engine_info().nvidia`, `FAFSTUDIO_NVIDIA_AA` | hooks into `D3D9Interfaces.cpp` | removed; `D3D9Interfaces.cpp` is the fork's file again, without editor changes |

## Verified (2026-11-05, RX 7900 XTX, instance `d11`, exe built from `editor-d3d11`)

* The start: log `D3D11: device created ... feature level 11_1`, `flip-discard 2 buffers`, no `/d3d11` needed. The blank map and `sc2_mp_002` (a converted SC2 mesh map) look the same as on the Direct3D 9 exe: the viewport
  of `sc2_mp_002` differs by a mean of 0.11 per channel (0.25 % of the pixels by more than 24, the marker icons).
* A pop-out (Settings, 502 x 373): the window draws every frame (`ed_window_get_rect` frame counter), the capture shows the whole panel.
* `ed_fxaa 1` with `ed_fxaa_time 1`: `EDITOR fxaa: GPU 0.020 ms per frame`. GPU compute: active on the RX 7900 XTX, `ed_gpu_selftest` ok.
* `selftest_meshview`: `Run` and `Check2` pass (`the viewport drew the mesh`, draw 0.01 ms).
* `studio.py check`: passes. Nightly (`editor_nightly.py`, maps / simstress / missionsim / selfloop / stress skipped): lint, 70 selftests, 70 panels, 217 menu items, 1161 buttons, workspaces, layout (75578 widgets, 0 problems), log and
  perf (ui frame tick 0.23 ms, budget 1.5) pass. `tips` failed once in the full run (two sliders, `Radius (units)` and `Gain`, of the mask generator's Add dialog, a graph node's parameters, without a tooltip; 3972 widgets
  checked) and passes on its own on both this exe and the Direct3D 9 one (3979 checked, 0 missing): an order dependence of the sweep, not the renderer, not investigated.

## Not verified / known differences

* **Not run on an NVIDIA or Intel GPU, and not on the hybrid laptop.** That the freeze is gone there is a hope from the cause (a Direct3D 9 driver deadlock after a same-size Reset), not a measurement.
* **The depth bias of the "Both" mesh mode** (`ed_mesh_mode 2`: mesh and height field together) is converted by hand: Direct3D 9 `-0.002` becomes `-33554` (a 24 bit depth buffer) and slope scale `-4`. It was not compared to the old picture.
* **Mesh textures** are loaded with `MipLevels = 0` (a full chain), as the Direct3D 9 loader did; the mip count was not checked on a file with fewer levels than the chain.
* **The hardware cursor** (Direct3D 9 only) is the Windows cursor now, as the engine does for every other renderer.
* **The shared engine still contains the Direct3D 9 backend** (`gpg/gal/backends/d3d9`, the `CD3D*` classes use its types, d3dx9 is still imported by the exe). That is the fork's code, shared with the game, and is the fork's decision
  (`map-formats-no-d3d9` retires it for the game); the editor no longer starts it, calls it or patches it. Removing it from the source tree is a change of the fork's `master`, not of the editor.
* **`primbatcher.fx` / `edtext_techniques.fx.part`** still say "D3D9 has no dual-source blending" as the reason for the two-pass text. Direct3D 11 has it; a one-pass text shader is an optimisation, not done.
* `editor/runtime/override/effects/terrain.fx` keeps its Direct3D 9 pixel-centre comment (the effect is the game's).
* The engine fork's `master` is 398 commits ahead of the base of `editor` (a trial merge conflicts in 10 files, in code upstream moved out of `Sim.cpp`, `CWldMap.cpp`, `StartupHelpers.cpp`); catching up is a separate task.
