# FAF Studio: spike, clean text rendering (read-only, 2026-10-17)

Question: how to get crisp, sub-pixel-positioned, kerned, DPI-aware, full-Unicode text with system fonts and
ClearType-style per-channel coverage in the editor UI, on the recovered D3D9 / Maui engine.
Context: [MAP_EDITOR_DESIGN.md](../MAP_EDITOR_DESIGN.md) section 8 "Text rendering" and decision 15.4,
[UI_CAMERA_FEASIBILITY.md](UI_CAMERA_FEASIBILITY.md) risk 7 and open question "ClearType-quality font".
Tags: **[V]** read in source (path:line), **[I]** inferred / API knowledge not checked in this tree, **[O]** open, needs a run.
Paths: `ENG` = `engine_decomp/faf-re-upstream/src/sdk/moho`, `FX` = `faf_repo/fa/effects`. Effort numbers are focused-day
*estimates*. Nothing was built or run.

## 0. Verdict

1. The whole text path is one small class, `CD3DFont`, reached through six members. **A second backend can be selected by
   family name inside `CD3DFont::Create`** and every Maui consumer (Text, Edit, ItemList, canvas later, sim overlays) follows
   without being edited. Game fonts and retail UI stay on the old path. This is the least invasive hook (section 5).
2. Recommended design: **DirectWrite for shaping and rasterisation (CPU, no D2D/D3D interop), a native A8R8G8B8 glyph atlas with
   4 horizontal sub-pixel phases, rendered through the engine's own `primbatcher` effect extended by two techniques**. LCD
   (ClearType-style) is done on D3D9 with a **two-pass blend (`Zero,InvSrcColor` then `One,One`)**: exact per-channel
   blend over *any* backbuffer content, no known background colour needed. Both blend macros already exist in the engine
   (section 3).
3. Stage it: grayscale first (no shader change), LCD second. Total about 11-14 days, MVP about 6-7 days (section 6).
4. Biggest risks: draw-call growth from batch breaks (technique/texture switch per text run), DXSDK-2010 `DWrite.h` shadowing the
   Windows SDK header (isolate in a DLL), atlas survival over device reset, Edit caret/hit-test on kerned text.

## 1. Current pipeline (evidence)

### 1.1 Font object and glyph creation

| Fact | Evidence |
|---|---|
| Lua `SetNewFont(family, size)` truncates the size to **int** and calls `CD3DFont::Create(pointSize, familyName)`; Text, Edit and ItemList each do this | Text `ENG/ui/UiRuntimeTypes.cpp:16494-16503`, Edit `:10049-10064`, ItemList `:13030` [V] |
| Defaults when no font is set: Text "New Times Roman" 16 (`:12900`), ItemList same (`:13795`), Edit "Courier New" 14 (`:2962`, `:23333`) | [V] |
| Fonts are cached forever per (int size, face) in a static `std::map`; glyph cache is 256 pages x 256 `SCharInfo` indexed by UTF-16 code unit | `ENG/render/d3d/CD3DFont.cpp:46`, `:113-117`, `:224-227`, `:749-755` [V] |
| Win32 font: `CreateFontA(-pointSize, ..., charset 1, quality 4, face)`, i.e. **GDI `ANTIALIASED_QUALITY` (grayscale, fully hinted)**, height is a **pixel em** (negative height), weight 0, no italic, ANSI face string | `CD3DFont.cpp:597` [V] |
| Metrics = GDI `TEXTMETRICW` as integers: height, ascent, descent, internal / external leading, average width | `CD3DFont.cpp:658-668` [V] |
| Kerning pairs are read with `GetKerningPairsW` and sorted, but **never used** (no reader of `mKerningPairs` outside the ctor/dtor) | `CD3DFont.cpp:670-688`; repo-wide grep of `mKerningPairs` / `KerningPair` outside `CD3DFont.*`: zero hits [V] |
| One glyph is rasterised on first use: `DrawTextW` white on black into a **128x128 32bpp memory DC**, read back with **per-pixel `GetPixel`** (up to 128x128 calls), cropped to 4x4-block bounds | `CD3DFont.cpp:654`, `:760-802`, `:840-917` [V] |
| Advance = integer width from `DrawTextW(DT_CALCRECT)` (GDI hinted widths), so **no fractional advances, no kerning, no sub-pixel placement** | `CD3DFont.cpp:764-766`, `:945` [V] |
| Max glyph 128 px, otherwise "Clamping character ... MAX_CHAR_WIDTH" warning | `CD3DFont.cpp:772-779` [V] |
| Glyph bitmap is **encoded to DXT5 alpha only** (8 alpha levels per 4x4 block: block min / max plus 6 steps plus exact 0 and 255), colour block is constant white | `CD3DFont.cpp:919-939`, `ENG/render/textures/DXTCodec.cpp:39-105` [V] |

Consequence: text is grayscale, GDI-hinted, integer-spaced, un-kerned, with up to 1/12 of the block alpha range of quantisation error per
pixel; correct but "classic Windows 95" quality.

### 1.2 Atlas, drawing, shader and blend state

| Fact | Evidence |
|---|---|
| Each glyph is a `CD3DBatchTexture` that holds **only DXT5 blocks** (`SBatchTextureData::mDxt5Blocks`); there is no other format on this path | `ENG/render/textures/CD3DRawBatchTexture.cpp:35-52`, `SBatchTextureData.cpp:11-40` [V] |
| Glyphs smaller than half the atlas go into one **1024x1024 DXT5 composite** (engine format token 12 = `D3DFMT_DXT5`, mapping `0x35545844 <-> 12`); the atlas is reset when full | `ENG/render/d3d/CD3DTextureBatcher.cpp:18-20`, `:110-125`, `:153-194`; `ENG/render/d3d/CD3DPrimBatcher.cpp:401-450`; `gpg/gal/backends/d3d9/D3D9Interfaces.cpp:704` [V] |
| A string is drawn glyph by glyph: `CD3DFont::Render` loops UTF-8 code points, `DrawChar` emits one quad per glyph, pen advances by `mAdvance` along `xAxis`. `glyphScale` is ignored | `CD3DFont.cpp:956-990`, `CD3DPrimBatcher.cpp:1086-1109` [V] |
| Text control placement: origin = control left (or centred by `advance`), baseline = `top + mAscent`; drop shadow = second `Render` at (+1,+1) in black; `SetNewClipToWidth` passes `maxAdvance` and `Render` stops at the first glyph that would overflow | `UiRuntimeTypes.cpp:16379-16437` [V] |
| All UI is drawn in the **`primbatcher` effect, technique `TAlphaBlendLinearSampleNoDepth`**, once per render pass mask (1, 4, 8), then one `Flush` | `ENG/ui/CUIManager.cpp:479-530` [V] |
| That technique: blend `SrcAlpha, InvSrcAlpha`, colour write RGB, depth off, alpha test `> 0`, `vs_1_1` / `ps_2_0`, PS = `tex2D(LinearSampler, uv) * vertexColor`, then `a *= AlphaMultiplier` | `FX/primbatcher.fx:64-72`, `:290-307` [V] |
| Vertex format is `{x,y,z, ARGB colour, u, v}` only (no extra channels) | `CD3DPrimBatcher.cpp:1099-1102` [V] |
| Pixel alignment is correct: the UI projection carries the D3D9 half-pixel shift (`-1/w`, `+1/h`) and matches the client size, so integer quads sample texels 1:1 | `CD3DPrimBatcher.cpp:1620-1657` [V] |
| Back buffer is A8R8G8B8 (non-sRGB); no `SRGBWRITE` / gamma state anywhere in `gpg` or `moho`. So blends happen in gamma space | `D3D9Interfaces.cpp:1898`; grep `SRGB` in `ENG`, `gpg`: zero hits [V] |

### 1.3 Unicode, DPI, scaling

- UTF-8 is decoded with `gpg::STR_DecodeUtf8Char` into a 16-bit `wchar_t`; 4-byte sequences are mis-decoded. So **BMP only, no surrogates,
  no emoji**. Glyph fallback depends on the GDI font mapper / DrawText behaviour of the chosen face [I, O: font linking not verified]. `String.cpp:166-217` [V].
- **No DPI awareness** anywhere (grep `DpiAware|SetProcessDPI|GetDpiFor` over `ENG`, `gpg`: zero hits) [V]; confirmed by UI_CAMERA_FEASIBILITY 2.1 item 10.
- Non-native sizes: Lua scale `LayoutHelpers.ScaleNumber` multiplies the size (`FAF/lua/maui/text.lua:62`, option range 0.8-2.0), the cast to int drops the
  fraction, the glyphs are then **re-rasterised at the truncated size** (crisp but metrics drift by up to 1 px). Quads are never scaled. [V]
- Fonts shipped with a mod: `REN_Init` enumerates VFS `/fonts/*.ttf` and registers each with `AddFontMemResourceEx` (process-private GDI fonts), called from
  app init before the device. A ttf under `editor/runtime/fonts/` is therefore found by the **GDI** path with no new code. `ENG/render/d3d/CD3DDevice.cpp:1753-1795`,
  `ENG/app/CScApp.cpp:945-950` [V]. (Makes item 9 `ed_font_load` of UI_CAMERA_FEASIBILITY unnecessary for GDI.)

### 1.4 What Lua can set (and cannot)

`Text:SetFont(family, size)` (scale applied, lazy vars, then `SetNewFont`), `SetColor`, `SetDropShadow`, `SetCenteredHorizontally/Vertically`,
`SetNewClipToWidth`, `GetStringAdvance(str)` (Text, Edit, ItemList), lazy vars `TextAdvance`, `FontAscent`, `FontDescent`,
`FontExternalLeading`; `UIUtil.CreateText(parent, label, size, font, dropshadow)`. `Text.Height = floor(ascent + descent)`,
`Text.Width = floor(TextAdvance)` (`FAF/lua/maui/text.lua:34-45`, `FAF/engine/User/CMauiText.lua`). **Not settable:** weight, italic, quality,
LCD vs gray, fractional size, per-glyph colour, wrapping (Lua `WrapText` calls `GetStringAdvance` per word, `text.lua`), rotation. [V]

### 1.5 Consumers of the font object (the complete surface)

`Render` / `Render2D`, `GetAdvance(text, flags)` (flags ignored in the recovered body), `GetNearestCharacterIndex`, `GetCharInfo(wchar).mAdvance`, and the members
`mAscent mDescent mInternalLeading mExternalLeading mHeight mAveCharWidth`. Users: Text (`UiRuntimeTypes.cpp:16307-16437, 16921`), Edit (`:2443, 2821-2901, 3074, 3095, 23408-23489, 23970-24266`),
ItemList (`:13590-14760`), sim overlays (`sim/CWldSession.cpp:11430-12762`, `sim/Sim.cpp:6583`, `sim/SimDriver.cpp:2133-2238`, `app/WxRuntimeTypes.cpp:2558-2677`). [V]
Only Edit uses per-code-point advances (`:2840`, `:2901`, clip loops) and a prefix measure for the caret (`:23489`).

## 2. Options to replace the glyph source

All three keep the engine side identical: rasterise on the CPU into RGB coverage, upload into an atlas, draw quads.

| | (a) GDI ClearType | (b) DirectWrite | (c) FreeType |
|---|---|---|---|
| API | `CreateFont(CLEARTYPE_QUALITY)`, `ExtTextOutW` white-on-black into a 32bpp DIB (per-channel result), `GetCharABCWidths(Float)`, `GetKerningPairs` | `IDWriteFactory::CreateGlyphRunAnalysis` -> `GetAlphaTextureBounds` / `CreateAlphaTexture(DWRITE_TEXTURE_CLEARTYPE_3x1)` (3 bytes per pixel, no DC) [I] | `FT_Render_Glyph(FT_RENDER_MODE_LCD)`, `FT_Get_Kerning` (`kern` table only) |
| Sub-pixel glyph position | **No** (GDI places integer pixels; hinted widths) | **Yes**: analysis takes a fractional baseline origin; cache N horizontal phases (4) [I] | Yes via `FT_Outline_Translate` before render |
| Kerning / shaping | Pairs from `kern` only (we already load them, unused today); no GPOS, no ligatures, no complex scripts | Full: `IDWriteTextAnalyzer` / `IDWriteTextLayout` (GPOS kerning, ligatures, bidi, Indic / Arabic shaping) [I] | `kern` only; GPOS and shaping need HarfBuzz (more vendoring) |
| System fonts + fallback | Installed faces, GDI font mapper, no real fallback | Installed faces, family / weight / style model, variable fonts, system font fallback in layout [I] | **None**: must find font files (registry / `C:\Windows\Fonts`) and implement fallback; or ship fonts |
| Full Unicode | BMP via `ExtTextOutW`; no surrogates without Uniscribe | Full (UTF-16, surrogates) | Full glyph set per face, no fallback |
| Hinting | GDI full hinting (classic look) | `NATURAL_SYMMETRIC` (no horizontal hinting, good with fractional positions) or `GDI_CLASSIC`; gamma / contrast per `IDWriteRenderingParams` [I] | v40 bytecode (ClearType-like), autohinter light, or none; Harmony LCD filter by default [I] |
| Deps | none (already linked) | `dwrite.lib`, system DLL; COM | FreeType source (FTL / GPLv2 dual, ~15 C files for a TrueType-only build), optionally HarfBuzz |
| x64 / VS 2026 (v145) | none | none (system API); **header trap below** | compiles as plain C with /MD; extra module / config work; no OS dependency |
| Output identical across machines | no (OS version, ClearType settings) | no (OS rasteriser) | **yes** |
| Quality ceiling | Medium: crisp, un-kerned, integer spacing | **High** (matches what Windows apps show) | High, plus control; weaker without fallback |
| Effort for rasteriser + shaping | 3-4 days | 4-5 days | 7-9 days (+3 with HarfBuzz) |

Header trap for (b) [V]: the engine's build points `DirectXInclude` at the **June 2010 DXSDK** (`engine_decomp/_deps_src/build_engine.bat`) and that SDK ships its own
`Include/DWrite.h` and `Lib/x64/dwrite.lib` (found under `engine_decomp/_deps_src/dxsdk/DXSDK/`). Windows is case-insensitive, so `#include <dwrite_3.h>` can mix with the old
`dwrite.h`. Put all DirectWrite code in **a separate small DLL** (`edtext.dll`, plain C API, built with the Windows SDK only, e.g. a new xmake target next to `edcore` in
`editor/xmake.lua`; /MD to match the engine's release CRT, or no CRT dependence) loaded with `LoadLibrary`. This also keeps COM and `/FORCE` link quirks out of `main_x64_la.exe` and lets the
text lab (section 4) run without the engine.

**Recommendation: (b).** Windows-only editor, the OS provides shaping, fallback and system fonts for free, and ClearType-class quality is the stated goal. Keep (a)'s one-line quality change
(`CreateFontA` quality 4 -> 5) in mind only as a 15-minute experiment for the old path. Choose (c) only if bit-identical output across machines (screenshots in bug reports, golden images) becomes
a requirement; then keep DirectWrite for font enumeration / fallback and FreeType for rasterisation.

## 3. The D3D9 blend (ClearType on a fixed-function-style blender)

Dual-source blending does not exist in D3D9 [I]. Usable techniques:

| # | Technique | Verdict |
|---|---|---|
| A | **Two passes**, same geometry: P0 `SrcBlend=Zero, DestBlend=InvSrcColor`, PS outputs `cov.rgb` -> `dst*(1-cov)`; P1 `SrcBlend=One, DestBlend=One`, PS outputs `cov.rgb * textColor.rgb` -> `+ C*cov`. Result `dst*(1-cov) + C*cov` per channel | **Recommended.** Exact, independent of the background (works over opaque panels *and* the world), colour per vertex, no extra render state outside the effect. Costs 2 draws per flush |
| B | One pass with `SrcBlend=BLENDFACTOR (text colour), DestBlend=InvSrcColor`, PS outputs `cov` | One draw, but one colour per batch and `D3DRS_BLENDFACTOR` must be set outside the effect (no per-draw hook in `CD3DPrimBatcher`). Later optimisation for canvas batches grouped by colour |
| C | Three passes with `ColorWriteEnable` R, G, B and `SrcAlpha` blend, PS emits one coverage channel per pass | Works, 3 draws; the write-mask macros partly exist (`Write_RG`, `Write_RBA`) but not R / G / B singly. Reject |
| D | PS reads a copy of the framebuffer (`StretchRect` region) | Expensive, interacts with the MSAA back buffer. Reject |
| E | Render text per panel into an offscreen texture | No generic render-to-texture for Maui panels (UI_CAMERA_FEASIBILITY 1.4). Reject |

Evidence that A fits the engine [V]:
- `FX/d3d9states.compat:102-107` defines `AlphaBlend_Zero_InvSrcColor` (Zero / InvSrcColor, write RGB) and `:161-166` `AlphaBlend_One_One` (write RGB). The compat file is prepended to every `.fx`
  (`ENG/render/d3d/CD3DEffectTechnique.cpp:476-520`).
- `CD3DDevice::DrawTriangleList` iterates **all passes of the selected technique**, one indexed draw each (`ENG/render/d3d/CD3DDevice.cpp:1384-1420`). So a two-pass technique needs no engine change.
- Effects are every `/effects/*.fx` in the VFS compiled at device init, hot-reloaded on disk change, named by file base name (`ENG/render/d3d/CD3DDeviceResources.cpp:36-40, 702-713, 785-830`). The editor mounts
  its folder on `/` (`editor/runtime/init_editor.lua:11`), so `editor/runtime/effects/*.fx` is visible. [I that an overriding or additional file is enumerated once.]

### 3.1 Exact shader / state changes

Where to put the techniques: `CD3DPrimBatcher::Flush` writes `CompositeMatrix`, `Texture1`, `AlphaMultiplier` through `ShaderVar` objects bound to the effect named **"primbatcher"**
(`ENG/render/d3d/ShaderVar.cpp:361-392`, `CD3DPrimBatcher.cpp:1015-1040`). A new effect file would need its own three `ShaderVar` registrations **and** a private flush. Therefore:

- Generate `editor/runtime/effects/primbatcher.fx` = FAF's `primbatcher.fx` + a block `edtext_techniques.fx` (a script concatenates them and records the FAF file's hash, so a FAF change is noticed). It shadows
  FAF's file in the editor only. [I] Alternative without shadowing: `edtext.fx` + 3 `RegisterShaderVar(..., "edtext")` + own vertex flush, about +1 day.

```hlsl
// appended to primbatcher.fx (uses VS_OUTPUT, PrimBatcherVS, CompositeMatrix, Texture1, AlphaMultiplier already defined there)
sampler TextSampler = sampler_state { Texture = <Texture1>; MipFilter = NONE; MinFilter = POINT; MagFilter = POINT;
                                     AddressU = Clamp; AddressV = Clamp; };
float3 AdjustCov(float3 cov, float3 c) {            // coverage curve by text luminance, constants tuned on screenshots [O]
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    return pow(cov, lerp(1.0, 0.65, lum));          // light text gets heavier, dark text unchanged (gamma-space blend)
}
float4 TextPS_Cov(VS_OUTPUT i) : COLOR { float3 cov = AdjustCov(tex2D(TextSampler, i.Tex1).rgb, i.Color.rgb)
                                         * (i.Color.a * AlphaMultiplier); return float4(cov, 1); }
float4 TextPS_Add(VS_OUTPUT i) : COLOR { float3 cov = AdjustCov(tex2D(TextSampler, i.Tex1).rgb, i.Color.rgb)
                                         * (i.Color.a * AlphaMultiplier); return float4(cov * i.Color.rgb, 1); }
float4 TextPS_Gray(VS_OUTPUT i) : COLOR { float3 t = tex2D(TextSampler, i.Tex1).rgb;
                                          float c = AdjustCov(t.ggg, i.Color.rgb).x; return float4(i.Color.rgb, c * i.Color.a * AlphaMultiplier); }
technique TTextLcd  { pass P0 { AlphaState(AlphaBlend_Zero_InvSrcColor)   DepthState(Depth_Disable) RasterizerState(Rasterizer_Cull_None)
                                VertexShader = compile vs_1_1 PrimBatcherVS(); PixelShader = compile ps_2_0 TextPS_Cov(); }
                      pass P1 { AlphaState(AlphaBlend_One_One_Write_RGB)  DepthState(Depth_Disable) RasterizerState(Rasterizer_Cull_None)
                                VertexShader = compile vs_1_1 PrimBatcherVS(); PixelShader = compile ps_2_0 TextPS_Add(); } }
technique TTextGray { pass P0 { AlphaState(AlphaBlend_SrcAlpha_InvSrcAlpha_Write_RGB) DepthState(Depth_Disable) RasterizerState(Rasterizer_Cull_None)
                                VertexShader = compile vs_1_1 PrimBatcherVS(); PixelShader = compile ps_2_0 TextPS_Gray(); } }
```
(Alpha test is deliberately absent: partial coverage zero must not write anything anyway; `pow` of 0 is 0.)

C++ side, in the new backend's `Render` (all calls exist): `primBatcher->Flush()` if vertices are queued; `device->SelectTechnique("TTextLcd")`; `primBatcher->mRebuildComposite = 0`;
`primBatcher->SetTexture(atlasSheet)` (the `ID3DTextureSheet` overload binds a sheet with identity UVs, `CD3DPrimBatcher.cpp:470-495`); emit quads with `DrawQuad`; and **restore** `TAlphaBlendLinearSampleNoDepth` after the last
glyph of the run (flush first). To limit breaks, the backend keeps the technique selected until the next non-text draw: a cheap check in `SetTexture` / `Flush` entry [I], or simply restore at the end of each `Render` and measure (O).

Gamma [V/I]: framebuffer is non-sRGB, so exact linear-light blending is impossible without reading the destination. The luminance-dependent coverage curve (as in Skia and DirectWrite's "enhanced contrast")
is the standard remedy; constants are an open tuning item [O]. Grayscale mode in stage 1 (no shader change) bakes one compromise curve into the atlas alpha instead.

LCD vs gray policy: choose by **family suffix** so no new Lua API is needed, e.g. `Text:SetFont('ed:Segoe UI', 12)` (LCD) vs `'ed:Segoe UI;g'` (gray, used for text over the world and for any control with `SetAlpha < 1`).
Ignore LCD above about 200 % scale where fringes are invisible [I]. Subpixel order (RGB/BGR) is a setting.

## 4. Prototype plan and test procedure

### 4.1 P0, offline text lab (about 1.5 days, no engine)
New target in `editor/xmake.lua` (`edtext` DLL + `edtool text-lab`). Renders one test sheet to PNG for: legacy emulation (GDI `ANTIALIASED_QUALITY` + DXT5 round trip using the same block rules as `DXTCodec.cpp`),
GDI ClearType, DirectWrite gray with 4 phases, DirectWrite LCD with the two-pass formula computed in software over a dark panel, a light panel and a gradient. Sizes 11 / 12 / 14 px at DPI 100 % (11, 12, 14) and 150 % (16.5, 18, 21).
It also decides the open constants (gamma curve, hinting mode `NATURAL_SYMMETRIC` vs `GDI_CLASSIC`) by eye before engine work starts.

### 4.2 P1, in-engine backend, grayscale only (about 3 days)
Smallest native piece: **the backend under `CD3DFont`, not a new Maui control**. New `ENG/editor/EdTextBackend.{h,cpp}` (loads `edtext.dll`, owns the `ID3DTextureSheet` atlas, 1024x1024 A8R8G8B8 = engine format token 2, created like
`CD3DTextureBatcher` does at `CD3DTextureBatcher.cpp:119-125`, updated per glyph with `CD3DDynamicTextureSheet::LockRect` (`CD3DDynamicTextureSheet.cpp:57-75`), CPU shadow copy for device reset) plus about 60 lines in `CD3DFont.{h,cpp}`:
`Create()` strips an `ed:` prefix and sets `mBackend`; `Render / GetAdvance / GetNearestCharacterIndex / GetCharInfo` forward when `mBackend != nullptr`. Register new files in `main_ed.vcxproj` (explicit `ClCompile`, next to `:1245`).
No new Lua global is required for the test. Optional `ed_text_info(family)` returns metrics and atlas use.

Test by the existing command channel (`scripts/ed_run.py --edcmd`, `editor/runtime/lua/editor/control.lua:23-83`):
```lua
-- engine_decomp/run_x64/edcmd.lua
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap;  local Text = import('/lua/maui/text.lua').Text
local bg = Bitmap(GetFrame(0)); bg:SetSolidColor('ff23262b'); bg.Left:Set(0); bg.Top:Set(0); bg.Width:Set(900); bg.Height:Set(600)
local y = 8
for _, sz in {11, 12, 14} do for _, fam in {'Arial', 'ed:Segoe UI'} do
    local t = Text(bg); t:SetFont(fam, sz); t:SetColor('ffe6e6e6'); t:SetText('The quick brown fox  AVATAR To Wa  0123 -1.5  Ä ß é Ω Ж 日本語')
    t.Left:Set(8); t.Top:Set(y); y = y + sz + 8 end end
return 'OK'
```
then capture with `scripts/meshmaps/screenshot.py` (PrintWindow, `PW_RENDERFULLCONTENT`; it currently matches `ForgedAlliance.exe` by name, so add `--exe main_x64_la.exe`, a 3-line change)
and crop. DPI 150 %: first with `LayoutHelpers.SetPixelScaleFactor(1.5)` plus rebuild; the true test needs the DPI-awareness change (UI_CAMERA_FEASIBILITY 2.1 item 10, 1 day) and Windows display scale 150 %.

### 4.3 P2, LCD (about 2.5 days)
Add the `.fx` block (section 3.1), technique swap in the backend, family suffix `;g`, then repeat the screenshots over a gradient and over the world (a `WorldView` visible behind a half-transparent panel).

### 4.4 Acceptance criteria (each measured on the cropped PNGs, scripted in Python)
1. **Side-by-side**: for sizes 11 / 12 / 14 and DPI 100 / 150 %, one sheet per cell showing legacy vs new vs reference (P0); a reviewer approves, plus items below.
2. **Sub-pixel positioning**: the string "iiiiiiii" placed at x = 10.0 / 10.25 / 10.5 / 10.75 gives four different bitmaps; ink centroid steps by 0.25 +/- 0.1 px.
3. **Kerning**: "AV", "To", "Wa", "LT" are narrower than the sum of single-glyph advances by at least the font's kern value; `GetStringAdvance` equals the drawn ink extent +/- 1 px.
4. **Unicode**: `ß é ñ Ω Ж € 日本語 ☺` and one surrogate pair (U+1F600) are not the missing-glyph box (pixel compare with `U+FFFF` render) with fallback fonts.
5. **Sharpness**: at 12 px a vertical stem of "l" / "I" has at least one pixel column at >= 90 % coverage (hinting), and the gradient energy of the 150 % render is >= 0.95 x the 100 % render scaled.
6. **LCD**: vertical white-on-dark stem edge pixels have R != B; gray mode has R = G = B; blend over a horizontal gradient equals a CPU reference (`dst*(1-cov)+C*cov`) with max error <= 2/255 per channel.
7. **Layout parity**: `Text.Width` / `Height` from the backend are integers; no last-glyph clipping in a `SetNewClipToWidth` control; Edit caret x matches `GetStringAdvance(prefix)`.
8. **Cost**: 500 labels of 20 characters, warm cache: frame CPU delta <= 1.0 ms and draw calls <= 2 x (number of text runs); cold first frame rasterisation <= 40 ms; atlas fill reported.
9. **Regression**: retail UI text (family `Arial`, "Zeroes Three", etc.) is pixel-identical to before the change.

## 5. Can the Maui text control take a new font backend? Yes (least invasive hook)

Evidence [V]: Text, Edit and ItemList hold a `CD3DFont*` and call only the members of section 1.5; the creation point is one function (`CD3DFont::Create`, called from the three `SetNewFont` binders and four defaults). The
class is not virtual, but on x64 the retail layout asserts are neutralised (`platform/X64LayoutAsserts.h:17-19`), so adding `mBackend` is free.

Hook design:
1. `CD3DFont::Create(size, face)`: if `face` starts with `ed:` -> construct a `CD3DFont` shell whose metrics come from the backend (ascent, descent, leading **rounded to integers** so Lua `Text.Height/Width` stay pixel aligned) and `mBackend` is set. The cache key already includes the face string,
   so size/face/suffix variants are separate objects.
2. `Render`, `GetAdvance`, `GetNearestCharacterIndex`, `GetCharInfo(wchar).mAdvance` check `mBackend`; the legacy body stays untouched.
3. `Render(text,...)`: UTF-8 -> UTF-16 with a **local decoder** (do not use `STR_DecodeUtf8Char`, it breaks surrogates), shape with a cached layout (key: font, string), emit one quad per glyph at `floor(pen)` with phase `frac(pen)` quantised to 1/4 px, advance by shaped (fractional) advances, honour `maxAdvance` at cluster boundaries, ignore the `xAxis/yAxis` rotation unless it is the standard (1,0)/(0,-1) (fallback: legacy path or per-glyph rotated quads for world text).
4. Edit: its two clip loops use `GetCharInfo(decoded).mAdvance` (`:2840`, `:2901`); with the backend that returns the un-kerned advance, so the clip is off by the kerning amount only; replace by prefix measures when Edit is polished (1 day). The caret (`:23489`) and hit test (`:23970-24266`) already use prefix / nearest-index calls, which the backend serves from the layout (`HitTestTextPosition`) [I].
5. Fractional sizes: change the three binders to read the size as `float` for `ed:` families (one line each, `:16494-16500`, `:10061`, `:13030`); otherwise 11 px x 1.25 = 13.75 is truncated to 13.
6. Per-control LCD / gray stays on the family string; alpha < 1 or world-attached controls use `;g`.

Not recommended: a Lua-visible second `Text` class or a new `CMauiCanvas` text first. Canvas text (`CMauiCanvas:Text`) can then call the same `CD3DFont::Render` and inherit everything.

## 6. Recommended design, effort and risks

**Design:** `edtext.dll` (DirectWrite shaping + `GlyphRunAnalysis` rasterisation, font collection = system fonts + editor ttf files under `editor/runtime/fonts/` via a custom `IDWriteFontCollectionLoader`; **[O]** AddFontMemResourceEx fonts are GDI-private and
probably invisible to DirectWrite's system collection, so a loader is needed) -> `EdTextBackend` (A8R8G8B8 atlas, shelf packer, 4 sub-pixel phases, LRU of shaped layouts, CPU shadow copy) -> `CD3DFont` forwarding hook -> `primbatcher` techniques `TTextLcd` / `TTextGray`.

| Work item | Days (estimate) |
|---|---|
| `edtext.dll` core: factory, fonts, shaping, glyph raster (gray + LCD, phases), PNG text lab, tests | 3-4 |
| Engine hook: `Create` / `Render` / `GetAdvance` / `GetNearestCharacterIndex` / metrics, atlas upload, reset safety, vcxproj, `ed:` prefix | 2-3 |
| LCD: fx techniques, generator script, `ShaderVar`-free technique swap, run batching, gamma tuning | 2-3 |
| Edit control polish (clip loops, caret on clusters), fractional sizes, `ed_text_info` | 1.5 |
| DPI awareness at process level + scale feed (shared with UI_CAMERA_FEASIBILITY item 10) | 1 |
| Screenshot harness (`--exe`), acceptance scripts, first sign-off pass | 1.5 |
| **Total** | **11-14 (MVP gray + hook: 6-7)** |

Risks (ranked):
1. **Draw-call growth** from the technique / texture switch per text run (`SetTexture` of a different sheet flushes, `CD3DPrimBatcher.cpp:470-495`) and 2 passes. Mitigate: keep the text technique across a run, group by colour for blend-factor mode B, make dense panels use one canvas. Measure early (criterion 8). [I]
2. **DXSDK header shadowing** of the Windows SDK DirectWrite headers. Mitigate: separate DLL with its own include set (section 2). [V that the old header is there]
3. **Device reset / lost texture**: the legacy atlas re-uploads from a CPU copy and registers a `DeviceExitListener` (`CD3DBatchTexture.cpp:93-113`, `CD3DTextureBatcher.cpp:223-262`); the backend must copy that pattern. [I that the editor resets on resize]
4. **Edit semantics** with kerning and clusters; the recovered `GetAdvance(text, flags)` ignores `flags` while Edit passes a position (`UiRuntimeTypes.cpp:2821, 2876`), so long-text scrolling may already be imprecise in the recovered build. [V]
5. **fx shadowing / hot reload**: `/EnableDiskWatch` stalled the sim in this build (MAP_EDITOR.md), so shader iteration needs restarts (about 7 s with `/nosound`). [V from MAP_EDITOR.md]
6. **Look settings**: user ClearType setting and subpixel order are not read; expose RGB/BGR/gray in the editor font setting; gray fallback above 200 %. [I]
7. **COM in a `/FORCE` linked x64 exe**: avoided by the DLL boundary. [I]
8. Retail-text regressions: none expected because the legacy body is untouched (criterion 9).

Open questions for the user: (1) is bit-identical rendering across machines required (then FreeType for rasterisation); (2) which UI font ships (Segoe UI Variable is system, Inter would be a bundled ttf and needs the custom collection loader);
(3) LCD default on, or gray default with LCD as a setting.

## Appendix: source index

`ENG/render/d3d/CD3DFont.{h,cpp}`, `CD3DFontTypes.h`, `CD3DPrimBatcher.{h,cpp}`, `CD3DTextureBatcher.cpp`, `CD3DDevice.cpp:1384-1420, 1468-1500, 1753-1795`, `CD3DDeviceResources.cpp:566-600, 702-830`,
`CD3DEffectTechnique.cpp:455-540`, `ShaderVar.cpp:361-392`, `ENG/render/textures/{CD3DBatchTexture,CD3DRawBatchTexture,SBatchTextureData,CD3DDynamicTextureSheet,DXTCodec}.cpp`, `ENG/ui/CUIManager.cpp:479-530`,
`ENG/ui/UiRuntimeTypes.cpp` (lines cited), `ENG/app/CScApp.cpp:945`, `gpg/core/containers/String.cpp:160-217`, `gpg/gal/backends/d3d9/D3D9Interfaces.cpp:660-720, 812`, `platform/X64LayoutAsserts.h`,
`FX/primbatcher.fx`, `FX/d3d9states.compat`, `faf_repo/fa/lua/maui/text.lua`, `faf_repo/fa/engine/User/CMauiText.lua`, `editor/runtime/{init_editor.lua, lua/editor/control.lua}`, `editor/xmake.lua`,
`scripts/{ed_run.py, meshmaps/screenshot.py}`, `engine_decomp/_deps_src/{build_engine.bat, dxsdk/DXSDK/Include/DWrite.h}`.
