# P1: in-engine DirectWrite text backend (2026-10-17)

Status: **works in the recovered engine** (grayscale). Test: `editor/textlab/p1_test.lua` through the `/edcmd` channel, captured with
`editor/textlab/shot.py` (PrintWindow). Rows compared at 11 / 12 / 14 px on a dark and a light panel: legacy `Arial` (GDI + DXT5) against
`ed:Segoe UI Variable Text` (DirectWrite). Latin, accented Latin, Greek, Cyrillic and CJK all render (system font fallback); kerning and
fractional advances are visible; no crash and no new engine errors in the log (the `circular dependency in lazy evaluation` warnings come from
the test script creating `Text` controls before their layout, not from the backend). Retail text (the editor's own tool panel, status line) is
unchanged.

## What was built

| Piece | Where |
|---|---|
| `edtext.dll` (C ABI: layout, glyph raster, positions) | `editor/edtext/` (own `xmake.lua`; build as in its header comment); copy next to the engine exe |
| Engine backend | new `moho/editor/EdTextBackend.{h,cpp}` (loads the DLL next to the exe; per font: layout cache, glyph cache, 4 sub-pixel phases) |
| `ed:` face hook | `CD3DFont::Create` (prefix, metrics rounded to integers), `Render`, `GetAdvance`, `GetNearestCharacterIndex`, `GetCharInfo`, destructor |
| A8R8G8B8 glyph textures | `CD3DBatchTexture::GetSheetFormat()` (new virtual, default 12 = DXT5; the glyph texture returns 2) |
| Second atlas | `CD3DTextureBatcher(width, height, format)` + `GetArgbAtlas()` (2048 x 2048, 4 bytes per texel); `CD3DPrimBatcher::SetTexture / Flush` pick the atlas by texture format and flush when switching |
| Project | `main_ed.vcxproj`: `moho\editor\EdTextBackend.cpp` |

## Facts learned (corrections to the spike report)

- Glyph textures do **not** live in per-font atlases: every `CD3DBatchTexture` is packed by `CD3DTextureBatcher` into **one shared 1024 x 1024
  DXT5 atlas** (1 byte per texel; textures of half the atlas size or more take a direct per-texture sheet instead). Colour glyphs therefore need
  their own atlas, which is what the second `CD3DTextureBatcher` provides. The same atlas will carry LCD glyphs in P2.
- The atlas rounds every texture up to a multiple of 4 and takes its UV rectangle from that size, so bitmaps must be padded to multiples of 4
  (an unpadded glyph is shrunk inside its quad).
- `IDWriteTextRenderer::QueryInterface` must refuse `IDWriteTextRenderer1` (see P0).
- Moho Lua has no `\x` string escapes (decimal escapes only) and closures share loop variables: a lazy `Top` that captures a loop-modified local
  is evaluated later with the final value.

## Known gaps / next

- Gray mode only (alpha coverage, `kGrayExponent` 0.8 gives slightly heavy text; tune in P2 together with the LCD blend).
- Not yet measured in the engine: cold-frame cost, draw calls per label, atlas fill, behaviour after a device reset (the CPU copy is kept and
  the batcher's `Reset` re-uploads, but this was not exercised), `Edit` caret and clip on kerned text, fractional sizes (size is still an `int`
  in the Lua binders) and DPI.
- The atlas has no eviction other than the batcher's full `Reset` when it is full; glyph and layout caches are unbounded per font (layout cache
  is cleared at 4096 entries).
- DLL lookup is next to the exe, then the default search path; a missing DLL leaves the font on GDI with the prefix stripped.
- `static_assert` layout checks are disabled on x64 (`platform/X64LayoutAsserts.h`); the added members (`CD3DFont::mEdBackend`,
  `CD3DTextureBatcher::mFormat`, `CD3DPrimBatcher::mArgbAtlasInUse`) would break the x86 build.

## Divergence from upstream (for merges)

`CD3DFont.{h,cpp}`, `CD3DBatchTexture.{h,cpp}`, `CD3DTextureBatcher.{h,cpp}`, `CD3DPrimBatcher.{h,cpp}`, `main_ed.vcxproj`; new
`moho/editor/EdTextBackend.{h,cpp}`. Build: `engine_decomp/_deps_src/build_engine.bat` (writes `output/main/x64/Release/main_x64_la.exe`);
the test copy runs as `run_x64/bin/main_x64_la_p1.exe` so the editor session's staged exe is untouched.
