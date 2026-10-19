# P2: LCD text (two-pass blend) and the P1 measurements (2026-10-17)

Status: **works in the engine.** `ed:Family` draws ClearType-style LCD text with the new `TTextLcd` technique; `ed:Family;g` draws gray coverage
with the normal UI technique. Tests: `editor/textlab/p2_test.lua` (visual), `editor/textlab/p2_cost.lua` (cost), `/edcmd` channel, `shot.py`.

## What was added on top of P1

| Piece | Where |
|---|---|
| Shader block with `TTextLcd` (pass 0 `dst*(1-cov)` with Zero/InvSrcColor, pass 1 `+ C*cov` with One/One) and the constant `EdLcdBoost` | `editor/runtime/override/effects/edtext_techniques.fx.part`, appended to FAF's `primbatcher.fx` by `editor/tools/gen_primbatcher_fx.py` (header records the SHA-256 of FAF's file; `--check` detects staleness) |
| Mount order | `editor/runtime/init_editor.lua` puts `editor/runtime/override` at the **front** of `path`: **mounts earlier in the list win** (FAF's `effects.nx2` shadowed our file when it was mounted last; `ed_vfs_to_disk` proved it) |
| LCD glyphs | `EdTextBackend.cpp`: sub-pixel coverages in R, G, B of the A8R8G8B8 atlas; suffix `;g` selects gray |
| Technique switching | `CD3DPrimBatcher::mLcdTextActive` + `EndTextRun()`: the technique stays on across consecutive text runs and is left when a non-glyph quad, `Setup`, or the end of `CUIManager::RenderFrames` comes |
| Device reset | `CD3DTextureBatcher::OnDeviceExit()` via a device-event listener on the shared ARGB atlas |
| Fractional sizes | `CD3DFont::CreateF(float, face)` (cache key in 1/16 px for fractional `ed:` sizes), the three `SetNewFont` binders pass the float |
| Counters | Lua `ed_text_stats()` -> runs, quads, flushes, glyph bitmaps, raster ms, render ms (resets on read) |

## Measurements (this machine, `/nosound`, 1280x720, vsync-bound frame delta 4.17 ms)

250 visible labels of about 20 characters at 12 px (4,650 glyph quads), 120 frames after a 20-frame warm-up, three modes:

| Mode | frame | text render (CPU, in the backend) | flushes per frame | cold frame |
|---|---|---|---|---|
| legacy Arial | 4.17 ms | not counted | n/a | n/a |
| ed gray (`;g`) | 4.17 ms | 0.47-0.55 ms | 0 | 111 glyph bitmaps rasterised in 0.2-0.3 ms, first render 4.0-4.8 ms |
| ed LCD, flush per run (first version) | **6.23 ms** | 5.2 ms | **500** (2 per run) | 525 ms first render, once (see open items) |
| ed LCD, technique kept active (current) | 4.17 ms | **0.47 ms** | **1** | 111 glyph bitmaps in 0.18 ms, first render 0.86 ms |

Reading: the backend costs about 2 microseconds per quad; the two-pass technique is free once it is not switched per run. The per-run flush was the
whole cost of the first LCD version (+2 ms per frame at 250 labels).

## Device reset

Forced by resizing the window (`SetWindowPos`, three sizes, back to the start size):
- first version: text kept rendering but gray and LCD rows showed stray vertical lines after the reset;
- a fresh instance started at the odd size showed none, so it was the reset path, not the size;
- **fix: on device exit the shared atlas drops its sheet and clears itself** (`OnDeviceExit` -> `Reset()`); glyphs are added again when next drawn. Re-uploading
  the old CPU copy into a new sheet (the first attempt) still left stray lines; the cause was not isolated (stale rectangle state is the suspect), the clean
  restart removed it. After the fix the text stayed clean through two resets.

## Fractional sizes

Native support works: `Text:SetNewFont('ed:Segoe UI Variable Text', size)` gives widths 202, 206, 210, 214, 218 px for 13, 13.25, 13.5, 13.75, 14 for the same
string, so a UI scale of 1.25 reaches the rasteriser. **FAF's `Text:SetFont` floors the size** (`LayoutHelpers.ScaleNumber` = `floor(size * scale)`, in
`lua/maui/text.lua:57`), so editor widgets must call `SetNewFont` with a fractional size themselves (or the editor widget kit hooks `SetFont`).

## Look (screens captured from the engine)

- LCD: crisp stems, blue/yellow fringes on the dark panel, orange/blue on the light panel, works over the world (the two-pass formula needs no background).
- With both coverage boosts on (`EdLcdBoost` 0.85, gray exponent 0.8) both new modes looked too heavy; with them off LCD matches the P0 reference and gray is
  thinner than LCD. **Defaults now: `EdLcdBoost` 1.0 (off, still a constant in the fx part) and gray exponent 0.9 (one constant in `EdTextBackend.cpp`);
  the gray result at 0.9 was not looked at again.**

## Open items

- A 525 ms first render of the LCD technique happened once (first process after build); it did not repeat. Suspect lazy effect or technique creation or the OS
  shader cache; not isolated.
- Not tested: `Edit` caret and clip on kerned text; translucent controls (`AlphaMultiplier` below 1) in LCD; BGR sub-pixel order; DPI awareness; gray text over
  the world with the UI technique active; text drawn by code that selects its technique with `device->SelectTechnique` directly instead of `Setup`.
- The technique restore assumes `TAlphaBlendLinearSampleNoDepth` (what `CUIManager::RenderFrames` selects); other contexts must call `EndTextRun` themselves.
- Process note: a minimised engine window stops the `/edcmd` poller (it runs in `OnFrame`); restore it with `ShowWindow(h, SW_RESTORE)`.

## Divergence from upstream added by P2

`CD3DPrimBatcher.{h,cpp}` (`mLcdTextActive`, `EndTextRun`, `Setup`, both `SetTexture`), `CUIManager.cpp` (`EndTextRun` before the final flush),
`CD3DTextureBatcher.{h,cpp}` (device-exit listener, recreate on demand), `CD3DFont.{h,cpp}` (`CreateF`, `CreateScaled`), `UiRuntimeTypes.cpp` (three binders),
`editor/runtime/init_editor.lua` (override mount). New: `editor/runtime/override/effects/*`, `editor/tools/gen_primbatcher_fx.py`.
