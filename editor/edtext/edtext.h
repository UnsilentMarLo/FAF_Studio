// edtext.dll: DirectWrite text shaping and glyph rasterisation for the editor's text backend (docs/projects/editor_research/SPIKE_CLEAN_TEXT.md).
// C ABI so the engine (built against the DirectX SDK 2010 headers, which shadow Windows SDK dwrite.h) can load it with LoadLibrary.
// A copy of the types below lives in engine_decomp/faf-re-upstream/src/sdk/moho/editor/EdTextBackend.cpp: keep both in sync.
#pragma once
#include <cstdint>

#ifdef EDT_BUILD
#define EDT_API extern "C" __declspec(dllexport)
#else
#define EDT_API extern "C" __declspec(dllimport)
#endif

struct EdFont;  // opaque: one family at one pixel size

struct EdGlyph {
    uint32_t face;     // index into the font's face table (system fonts and fallbacks)
    uint32_t glyph;    // glyph index in that face
    float x;           // pen position of the glyph origin (pixels, from the start of the string)
    float advance;     // advance (pixels)
};

// Returns nullptr if DirectWrite is unavailable. px is the em size in pixels (fractional allowed).
EDT_API EdFont* edt_font_create(const wchar_t* family, float px);
EDT_API void edt_font_destroy(EdFont* f);
// ascent / descent / lineGap in pixels (unrounded).
EDT_API void edt_font_metrics(EdFont* f, float* ascent, float* descent, float* lineGap);
// Shapes a UTF-16 string on one line. Returns the glyph count (may exceed cap: then only cap are written). width = total advance.
EDT_API int edt_layout(EdFont* f, const wchar_t* text, int len, EdGlyph* out, int cap, float* width);
// x position (pixels) of the leading edge of every UTF-16 index 0..len (len+1 values).
EDT_API int edt_positions(EdFont* f, const wchar_t* text, int len, float* xs);
// Rasterises one glyph at a sub-pixel phase (0..3, quarter pixels). Output is 3 bytes per pixel, R = G = B = grayscale coverage (exact outline coverage, edraster.h;
// before 2026-10-20 it was ClearType 3x1 averaged to gray). Set EDTEXT_RASTER=dwrite for that older method, EDTEXT_GAMMA, EDTEXT_YSNAP=0: see edtext.cpp.
// left/top are relative to the glyph origin on the baseline (top is negative above the baseline). Returns 1 on success, 0 if the glyph is empty.
// If cap is too small, *w and *h are still set and 0 is returned with *needed set via w*h*3.
EDT_API int edt_raster(EdFont* f, uint32_t face, uint32_t glyph, int phase, int* left, int* top, int* w, int* h, uint8_t* rgb, int cap);
