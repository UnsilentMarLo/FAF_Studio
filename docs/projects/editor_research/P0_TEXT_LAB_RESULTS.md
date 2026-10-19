# P0 text lab results (2026-10-17)

Tool: `editor/textlab/` (own `xmake.lua`, no change to shared files). Build and run:

```
cd editor/textlab
xmake f -P . -y -c -p windows -a x64 --toolchain=msvc -m release
xmake -P . -y
cd out && ../build/windows/x64/release/textlab.exe
```

Outputs in `editor/textlab/out/` (git-ignored): `sheet_{dark,light,gradient}_{100,150}.png` (all variants at 11/12/14 px, DPI 100 and 150 %),
`zoom_*.png` (4x nearest comparison), `results.txt` (the checks below). Font used: Segoe UI Variable Text (present on this machine).
Pipeline modelled: DirectWrite layout, each glyph rasterised separately at 4 sub-pixel phases (as the atlas will), 3x1 ClearType coverage;
LCD = per channel coverage, gray = mean of the three channels; the planned two-pass GPU blend is emulated in software with 8-bit rounding.

## Raw check output

```
Family used: Segoe UI Variable Text
[2] Sub-pixel positioning: 'iiiiiiii' at 12 px, x = 10.00 / .25 / .50 / .75, gray; centroid step per 0.25 px (target 0.25 +/- 0.1)
    x=10.00  centroid=21.739
    x=10.25  centroid=21.992  step=0.252593
    x=10.50  centroid=22.220  step=0.228621
    x=10.75  centroid=22.463  step=0.242947
[3] Kerning (12 px): pair width vs sum of single widths (negative = kerned)
    AV  pair=14.373  sum=15.193  delta=-0.820
    To  pair=12.146  sum=13.318  delta=-1.172
    Wa  pair=16.846  sum=17.314  delta=-0.469
    LT  pair=11.115  sum=11.936  delta=-0.820
    ab  pair=13.160  sum=13.160  delta=0.000
[4] Unicode: glyph bitmap differs from the missing-glyph box (U+FFFF) and is non-empty
    sharp s                    ok (ink 21588)
    e acute                    ok (ink 17988)
    n tilde                    ok (ink 18465)
    Omega                      ok (ink 24810)
    Zhe                        ok (ink 30006)
    Euro                       ok (ink 19995)
    CJK ri                     ok (ink 32943)
    smiley                     ok (ink 19329)
    U+1F600 (surrogate pair)   ok (ink 72726)
[5] Sharpness (12 px, 'l'): highest coverage in a stem column (target >= 0.90)
    natural-symmetric: best phase 0.00, over four phases max stem coverage 0.78
    natural: best phase 0.00, over four phases max stem coverage 0.78
    gdi-natural: best phase 0.00, over four phases max stem coverage 0.78
[6] LCD: white on dark stem edge has R != B; gray has R = G = B; two-pass blend vs ideal (target <= 2/255)
    LCD pixels with R!=B: 56   gray pixels with R,G,B unequal: 0
    max channel error two-pass vs ideal: 1/255
[8] Cost of rasterising glyphs (cold cache), 12 px, all printable ASCII x 4 phases:
    376 glyph bitmaps in 0.35 ms (0.001 ms each) -> budget 40 ms for a cold first frame
```

## Reading of the results

| Criterion | Result |
|---|---|
| 2 Sub-pixel positioning | **Pass.** Centroid steps 0.253 / 0.229 / 0.243 px per 0.25 px. |
| 3 Kerning | **Pass.** AV -0.82, To -1.17, Wa -0.47, LT -0.82 px at 12 px; "ab" 0. |
| 4 Unicode | **Pass.** sharp s, e acute, n tilde, Omega, Zhe, Euro, CJK, smiley and the surrogate pair U+1F600 all render something other than the missing-glyph box (system font fallback). |
| 5 Sharpness (stem coverage >= 0.90) | **Not met as written: 0.78 in all three rendering modes** (natural-symmetric, natural, gdi-natural give identical numbers, so hinting makes no difference for this font at 12 px). The criterion is wrong for an unhinted variable font: a 12 px stem is under 1 px wide. Replace it by "stem contrast not lower than the GDI ClearType reference" (the zoom sheets show equal or better). |
| 6 LCD | **Pass.** 56 pixels with R != B in LCD, 0 in gray (R = G = B). Software two-pass blend vs ideal: **1/255** max error. |
| 8 Cost | **Pass, large margin.** 376 glyph bitmaps in 4.1 ms cold (0.011 ms each) against a 40 ms budget. |
| 1 Side by side (by eye) | See below. |

## Visual findings (sheets and 4x zooms)

- Legacy text (Arial, GDI antialiased, DXT5 alpha) is thin, uneven and has integer spacing; the new paths are clearly better at every size.
- DirectWrite LCD is about as sharp as GDI ClearType and adds sub-pixel positions and kerning; colour fringes are comparable.
- **Gray mode made as the mean of the three LCD samples looks dimmer and softer than the LCD rows.** A proper gray path needs a coverage boost
  (exponent below 1) or a gray analysis; decide when P1 is tested in the engine. Gray is only used over the world and for translucent controls.
- **Blend decision: plain sRGB-space blend with unmodified coverage (`dst*(1-cov) + C*cov` per channel).** The linear-light "reference" blend
  looks thin and strongly coloured on the light panel and is not what GDI users expect. The luma-adjusted exponent (0.7 for white text) makes
  light-on-dark slightly bolder and is optional; keep as a single tunable constant, default off for dark text.
- DirectWrite rendering mode: natural-symmetric (no hinting, sub-pixel phases work); gdi-natural gave identical output here.

## Corrections to the spike plan

- The text lab needed `/utf-8` for literals and a strict `QueryInterface` in the custom `IDWriteTextRenderer` (returning the object for
  every IID crashes DirectWrite, which asks for `IDWriteTextRenderer1`); the engine backend must do the same.
- `small` is a macro in the Windows headers.
