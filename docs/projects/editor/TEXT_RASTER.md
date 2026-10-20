# Editor text: grayscale rasteriser (2026-10-20)

`edtext.dll` draws the editor's text (`ed:` fonts). Until now a glyph was rasterised by DirectWrite as a ClearType 3x1 texture and averaged to gray. That texture has already been
through ClearType's horizontal filter (about 1.7 px wide), so the result was fringe-free but soft. `edt_raster` now gets the glyph **outline** from DirectWrite
(`IDWriteFontFace::GetGlyphRunOutline`) and computes the exact fraction of every pixel the outline covers (`editor/edtext/edraster.h`): no filter, no sub-pixel colour.

## What it does

| Step | Where |
|---|---|
| outline (lines and cubic Beziers, y down, origin on the baseline), moved by the sub-pixel phase (`phase / 4` px) | `edtext.cpp` (`OutlineSink`) |
| exact area coverage by signed-area accumulation, `min(1, abs(sum))` as the non-zero winding rule; bitmap trimmed to the covered pixels | `edraster.h` (`Rasteriser`) |
| contrast curve `coverage ^ 0.72` (thin light-on-dark strokes keep their weight) | `edraster.h` (`BuildContrastLut`) |
| x-height snap: the glyph is scaled vertically (at most +-6 %) so the x-height is a whole number of pixel rows; flat lowercase tops sit on one row instead of two | `edraster.h` (`XHeightSnapScale`), measured per face from the outline of `x` (`measureSnap`) |

The C ABI (`edtext.h`) is unchanged: 3 bytes per pixel, R = G = B. The engine backend needs no change and no rebuild, only the new `edtext.dll` next to the exe.

## Switches without a rebuild

Environment variables, read once when the DLL first rasterises (set them before starting the editor):

| Variable | Effect |
|---|---|
| `EDTEXT_RASTER=dwrite` | the previous method (ClearType texture averaged to gray) for an A/B comparison |
| `EDTEXT_GAMMA=0.72` | the coverage curve (0.3 to 2.5; below 1 gives more weight to thin strokes; 1 = none) |
| `EDTEXT_YSNAP=0` | no x-height snap: glyphs keep the designed height |
| `EDTEXT_SNAPX=1` | whole-pixel glyph positions: the backend places every bitmap at the whole pixel below the pen and asks for phase = round(fraction * 4); this maps phases 0-1 to the bitmap at x = 0 and 2-3 to the same bitmap one pixel right, so vertical stems always cover the same pixel columns (crisp, evenly weighted; spacing is off by up to half a pixel). Try it if stems look uneven or soft. |

## Limits

- Unhinted: vertical stems are positioned by the sub-pixel phase (quarter pixels), so a 1 px stem can straddle two columns and look dimmer and wider than its neighbour.
  `EDTEXT_SNAPX=1` removes that (see above).
- Gray fonts (`ed:Family;g`, used on translucent surfaces) go through the backend's own gray curve (`grayLut`) on top of the DLL's `EDTEXT_GAMMA`; the default `ed:Family` text
  (drawn by the `TTextLcd` technique with R = G = B) only gets the DLL's curve.
- Opposite-direction overlapping contours would cancel (same-direction overlaps, which variable fonts have, are fine). Not seen in the fonts checked.
- The x-height snap changes glyph heights by up to 6 %. If a font looks wrong with it, `EDTEXT_YSNAP=0`.

## Validation

`python editor/edtext/test/run_tests.py [--quick] [--images DIR]` (g++, numpy, Pillow, fontTools, shapely; any Linux or Windows machine with those, no DirectWrite needed).
Result on 2026-10-20, Liberation Sans (TrueType quadratics) and Inter (CFF cubics), 11 to 24 px, four phases:

| Check | Result |
|---|---|
| exact area of 1,088 glyph renders against shapely polygon areas | worst pixel error 1.48 / 255, mean 0.22 / 255 |
| 241 random simple polygons against the same reference | worst 0.50 / 255 |
| 66 renders against FreeType at 16x, box-reduced (an independent rasteriser that hints a little) | worst 13 / 255, worst per-glyph mean 0.06 / 255 |
| sub-pixel phase moves the glyph by a quarter pixel | mean step 0.2500 |
| AddressSanitizer + UBSan over 548 outlines incl. degenerate, cusp and zero-height cases | no report |

The DLL glue (`edtext.cpp`) was cross-compiled with mingw-w64 (real `dwrite.h` / `d2d1.h`, `-Wall -Wextra` clean) and run under Wine with
`editor/edtext/test/edtext_smoke.cpp` and `compare_dll.py`: gray output only, the gamma curve applied exactly, bitmaps placed where the host rasteriser puts the same glyph, the
phases move the glyph a quarter pixel, the old path still works, bad environment values are ignored. Wine's `GetGlyphRunOutline` returns hinted outlines, so pixel values were
not compared there (the x-height snap is a no-op on already hinted outlines); Windows' own outlines are unhinted. **Not done: a build with MSVC and a look at the result in the editor.**
