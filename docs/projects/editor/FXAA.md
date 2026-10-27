# FXAA: post-process anti-aliasing for the world view

Status 2026-10-27 (branch `fxaa`). Works on the AMD desktop (RX 7900 XTX); **not yet run on the NVIDIA hybrid laptop**, which is the reason it exists (see LAPTOP_FREEZE.md:
swap chain MSAA froze the RTX 4060 laptop, the editor offers only "Off" there). Off by default until it has been seen on that machine.

## What the user gets

Settings > Graphics > **Anti-aliasing** has a new state **FXAA** (stored as `-1`; the packed engine modes 0, 64, 128, 256 are untouched). It is offered on every adapter, the NVIDIA laptop
included, where the list is now `Off, FXAA`. Choosing it sets `ed_fxaa 1` and the swap chain's anti-aliasing to 0; choosing any other entry sets `ed_fxaa 0` first.

Console variables (`EdFxaa.h`):

| Variable | Default | What |
|---|---|---|
| `ed_fxaa` | 0 | the pass on / off |
| `ed_fxaa_subpix` | 0.75 | how much thin lines and single pixels are blended (0 to 1) |
| `ed_fxaa_edge` | 0.166 | edges with less contrast than this fraction of the local maximum are left alone; 0.125 / 0.063 find more edges but soften fine texture |
| `ed_fxaa_edge_min` | 0.0833 | edges with less absolute luma contrast are left alone: raise it to keep fine texture detail |
| `ed_fxaa_passes` | 1 | draws the pass N times per frame (1 to 40), for measuring only |
| `ed_fxaa_time` | 0 | 1: GPU time of the copy and the pass from D3D9 timestamp queries, logged every 120 frames (`EDITOR fxaa: GPU ...`) |

## How the frame is composed (and where FXAA sits)

`WRenViewport::Render` draws everything into the head's render target, which `CD3DDevice` keeps as `mRenderTargetLocks[head]`, a `CD3DRenderTarget` wrapping the swap chain's back buffer
surface. Every pass asks for that target with `GetWriterLock1(head)` / `SetRenderTarget2(head, ...)`, so redirecting the wrapper's surface redirects the whole frame without touching a pass:

1. `FrameScope` (EdFxaa.cpp, created after `ProcessPendingRequests`) swaps `mSurface` of the head's wrapper for an off-screen render target of the same size and format
   (`CreateRenderTarget(w, h, 2)`, the format of the viewport's own screen sized targets; a texture, so the shader can read it). The depth buffer stays the head's.
2. The frame runs as before into that target: Maui frames pass, sky, terrain, shadows, meshes, water (its refraction copy reads the head target: it reads the scene target now), effects,
   the world view overlay (`worldView->mView->Render`: grids, gizmos, editor overlay, marker labels).
3. After the world view loop, before the cartographic pass and **before `DrawUI`**: `Resolve()` puts the real back buffer back, `StretchRect`s the whole scene into it (the part of the window
   outside the world view), then draws one full-screen quad per world view rectangle with `effects/fxaa.fx` (technique `TFxaa`) reading the scene target and writing the back buffer.
4. `DrawUI` (every Maui control, text), `RenderUI`, silhouettes, bloom run afterwards on the real back buffer: **unfiltered**. Measured: 0 pixels differ outside the world view rectangle.

The icon pass (`ed_icon_request`) never uses it (hard edges against the matte colours). The scope restores the real surface on every way out (destructor), so an exception from a pass
cannot leave the head pointing at the scene target.

Device Reset: the scene target and the quad's vertex sheet are released in `WRenViewport::D3DWindowOnDeviceExit` (`edfxaa::ReleaseDeviceResources`, also unbinds the texture from the effect) and made
again lazily by the next frame. Tested: AA 4x then FXAA again (two resets) while running, and the startup reset.

FXAA stays off while the swap chain is multisampled (`StretchRect` from a plain target into a multisampled surface is not allowed): choosing MSAA in the list switches `ed_fxaa` off by itself,
and a console `ed_fxaa 1` with MSAA on does nothing.

## The shader (`editor/runtime/override/effects/fxaa.fx`)

FXAA 3.11 "quality" algorithm (preset 39 search steps, luma from the colour: `dot(rgb, 0.299 0.587 0.114)`), shader model 3.0, own vertex shader on the frame quad of `CRenFrame`.
Pitfalls found (all in the engine's D3DX compiler, which is older than `fxc` of the June 2010 SDK: `fxc /T fx_2_0` accepted the first version, the engine did not):

* a failed `.fx` is fatal at start: `CD3DDeviceResources::InitResources` dies for any effect it cannot compile. Check the file with fxc **and** by starting an instance (`run.log`: `Compiled shader: /effects/fxaa.fx`).
* no `[unroll]` ("unexpected token '['"): the search steps are written out with a macro;
* no `return` inside an `if` ("asymetric returns from if statements not yet implemented"): one `return` at the end;
* `vs_3_0` + `ps_3_0` as a pair; the pixel shader takes only `TEXCOORD0` (no `POSITION` input); effect passes run with `D3DXFX_DONOTSAVESTATE`, so the technique sets all render states it needs.

Taps are clamped to the world view rectangle (texel centres), so nothing of the panels around the view bleeds into the edge pixels.

## Measured (2026-10-27, RX 7900 XTX, 1920 x 1080, map scmp_009, Ultra graphics, D3D9 timestamp queries, `ed_fxaa_time`)

| | GPU ms per frame |
|---|---|
| copy of the whole scene into the back buffer (`StretchRect`) | 0.018 |
| FXAA pass, normal scene (about 3 % of the pixels are edges) | 0.038 |
| **total** | **0.057** |
| FXAA pass, worst case (`ed_fxaa_edge 0.02`, `ed_fxaa_edge_min 0`: every pixel runs the full search) | 0.057 (+ 0.018 copy = 0.075) |

Frame time with vertical sync and the limiter off was CPU bound (about 2.9 to 3.3 ms, 300 to 345 fps) and did not move measurably with FXAA on (2.90 vs 2.95 ms; 40 passes per frame: 3.18 to 3.38 vs 3.04 to 3.35): the GPU
has idle time there. The picture changes in 3 % of the world view pixels (28 356 of 869 526 with a difference above 8/255 at 1536 x 864 screenshot size), 0 outside it.

Screenshots (`docs/projects/editor/img/`): `fxaa_map_off.png`, `fxaa_map_on.png` (whole window), `fxaa_compare_trees.png` and `fxaa_compare_shore.png` (5x crops, off left, on right).
The cliff test on the blank map (plateaus 22 to 62 high, `SetRect`) is dominated by the blank map's noise texture; use a real map for the comparison.

## Known limits and open items

* FXAA smooths texture as well as geometry edges (fine grain, the blank map's noise). `ed_fxaa_edge` / `ed_fxaa_edge_min` trade that; defaults are FXAA's own "default" preset (0.166 / 0.0833).
* The world view overlay (marker labels, gizmos, grid lines, the editor overlay) is drawn before the pass, so it is smoothed too: marker label text in the viewport is slightly softer than with FXAA off.
  Drawing the overlay after the pass would need the pass inside `Render` per world view (one world view in the editor today); not done.
* The cartographic (strategic) view and silhouettes are drawn after the pass: not smoothed.
* Pop-out windows (`EdPopout.cpp`) have their own swap chains and are not smoothed.
* **Not tested on the NVIDIA hybrid laptop.** The scene target is an ordinary default pool render target like `mPrimaryTargetLocks`, and no device Reset is needed to switch FXAA on or off, which was the trigger of the freeze;
  but the first frames after a Reset on that machine are the thing to watch (`EDITOR device reset:` lines, `EDITOR fxaa: on`).
* SMAA 1x (edge detection + weights + blend, three passes, two lookup textures) is not done; FXAA is the one pass version.
