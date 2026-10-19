#define EDT_BUILD
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwrite.h>
#include <algorithm>
#include <cmath>
#include <vector>
#include "edtext.h"

namespace {
IDWriteFactory* gFactory = nullptr;
bool ensureFactory() {
    if (!gFactory && FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(&gFactory)))) gFactory = nullptr;
    return gFactory != nullptr;
}
}  // namespace

struct EdFont {
    IDWriteTextFormat* format = nullptr;
    float px = 12.f;
    std::vector<IDWriteFontFace*> faces;  // AddRef'd, index = EdGlyph::face
    uint32_t faceId(IDWriteFontFace* f) {
        for (uint32_t i = 0; i < faces.size(); i++) if (faces[i] == f) return i;
        f->AddRef(); faces.push_back(f); return (uint32_t)faces.size() - 1;
    }
};

namespace {
// Collects glyph runs of a layout; strict QueryInterface (answering IDWriteTextRenderer1 with this object crashes DirectWrite).
struct Collector : IDWriteTextRenderer {
    EdFont* font; std::vector<EdGlyph> glyphs; long ref = 1;
    explicit Collector(EdFont* f) : font(f) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** o) override {
        if (IsEqualIID(id, __uuidof(IUnknown)) || IsEqualIID(id, __uuidof(IDWritePixelSnapping)) || IsEqualIID(id, __uuidof(IDWriteTextRenderer))) { *o = this; return S_OK; }
        *o = nullptr; return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++ref; }
    ULONG STDMETHODCALLTYPE Release() override { return --ref; }
    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void*, BOOL* d) override { *d = TRUE; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void*, DWRITE_MATRIX* m) override { *m = {1, 0, 0, 1, 0, 0}; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void*, FLOAT* v) override { *v = 1.f; return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawUnderline(void*, FLOAT, FLOAT, const DWRITE_UNDERLINE*, IUnknown*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawStrikethrough(void*, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH*, IUnknown*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawInlineObject(void*, FLOAT, FLOAT, IDWriteInlineObject*, BOOL, BOOL, IUnknown*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void*, FLOAT bx, FLOAT, DWRITE_MEASURING_MODE, const DWRITE_GLYPH_RUN* run, const DWRITE_GLYPH_RUN_DESCRIPTION*, IUnknown*) override {
        uint32_t face = font->faceId(run->fontFace); float pen = bx;
        for (UINT32 i = 0; i < run->glyphCount; i++) {
            float off = run->glyphOffsets ? run->glyphOffsets[i].advanceOffset : 0.f;
            glyphs.push_back({face, run->glyphIndices[i], pen + off, run->glyphAdvances[i]});
            pen += run->glyphAdvances[i];
        }
        return S_OK;
    }
};

IDWriteTextLayout* makeLayout(EdFont* f, const wchar_t* text, int len) {
    IDWriteTextLayout* l = nullptr;
    if (FAILED(gFactory->CreateTextLayout(text, (UINT32)len, f->format, 100000.f, 1000.f, &l))) return nullptr;
    l->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    return l;
}
}  // namespace

EDT_API EdFont* edt_font_create(const wchar_t* family, float px) {
    if (!ensureFactory()) return nullptr;
    EdFont* f = new EdFont(); f->px = px;
    if (FAILED(gFactory->CreateTextFormat(family, nullptr, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, px, L"en-us", &f->format))) { delete f; return nullptr; }
    return f;
}

EDT_API void edt_font_destroy(EdFont* f) {
    if (!f) return;
    for (auto* ff : f->faces) ff->Release();
    if (f->format) f->format->Release();
    delete f;
}

EDT_API void edt_font_metrics(EdFont* f, float* ascent, float* descent, float* lineGap) {
    *ascent = f->px * 0.8f; *descent = f->px * 0.2f; *lineGap = 0.f;
    IDWriteTextLayout* l = makeLayout(f, L"Hg", 2); if (!l) return;
    DWRITE_LINE_METRICS lm{}; UINT32 n = 1;
    if (SUCCEEDED(l->GetLineMetrics(&lm, 1, &n))) { *ascent = lm.baseline; *descent = lm.height - lm.baseline; }
    l->Release();
}

EDT_API int edt_layout(EdFont* f, const wchar_t* text, int len, EdGlyph* out, int cap, float* width) {
    *width = 0.f; if (len <= 0) return 0;
    IDWriteTextLayout* l = makeLayout(f, text, len); if (!l) return 0;
    DWRITE_TEXT_METRICS tm{}; l->GetMetrics(&tm); *width = tm.widthIncludingTrailingWhitespace;
    Collector c(f); l->Draw(nullptr, &c, 0.f, 0.f); l->Release();
    int n = (int)c.glyphs.size();
    for (int i = 0; i < n && i < cap; i++) out[i] = c.glyphs[i];
    return n;
}

EDT_API int edt_positions(EdFont* f, const wchar_t* text, int len, float* xs) {
    for (int i = 0; i <= len; i++) xs[i] = 0.f;
    if (len <= 0) return 0;
    IDWriteTextLayout* l = makeLayout(f, text, len); if (!l) return 0;
    for (int i = 0; i < len; i++) {
        FLOAT x = 0, y = 0; DWRITE_HIT_TEST_METRICS m{};
        l->HitTestTextPosition((UINT32)i, FALSE, &x, &y, &m); xs[i] = x;
    }
    DWRITE_TEXT_METRICS tm{}; l->GetMetrics(&tm); xs[len] = tm.widthIncludingTrailingWhitespace;
    l->Release(); return 1;
}

EDT_API int edt_raster(EdFont* f, uint32_t face, uint32_t glyph, int phase, int* left, int* top, int* w, int* h, uint8_t* rgb, int cap) {
    *left = *top = *w = *h = 0;
    if (face >= f->faces.size()) return 0;
    UINT16 gi = (UINT16)glyph; FLOAT adv = 0;
    DWRITE_GLYPH_RUN run = {f->faces[face], f->px, 1, &gi, &adv, nullptr, FALSE, 0};
    IDWriteGlyphRunAnalysis* a = nullptr;
    if (FAILED(gFactory->CreateGlyphRunAnalysis(&run, 1.f, nullptr, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL, phase / 4.f, 0.f, &a))) return 0;
    RECT b{};
    int ok = 0;
    if (SUCCEEDED(a->GetAlphaTextureBounds(DWRITE_TEXTURE_CLEARTYPE_3x1, &b)) && b.right > b.left && b.bottom > b.top) {
        *left = b.left; *top = b.top; *w = b.right - b.left; *h = b.bottom - b.top;
        int need = (*w) * (*h) * 3;
        if (need <= cap && SUCCEEDED(a->CreateAlphaTexture(DWRITE_TEXTURE_CLEARTYPE_3x1, &b, rgb, (UINT32)need))) {
            // Grayscale: the three sub-pixel coverages of a pixel become one value (copied to R, G, B). ClearType's per-channel coverage showed as colour fringes over the editor's
            // dark panels. A gamma below 1 gives the thinner light-on-dark strokes back their weight, so the text stays crisp instead of turning grey.
            static uint8_t lut[256]; static bool lutReady = false;
            if (!lutReady) { for (int i = 0; i < 256; i++) lut[i] = (uint8_t)std::min(255.0, 255.0 * std::pow(i / 255.0, 0.72) + 0.5); lutReady = true; }
            int px = (*w) * (*h);
            for (int i = 0; i < px; i++) {
                int g = (rgb[i * 3] + 2 * rgb[i * 3 + 1] + rgb[i * 3 + 2] + 2) / 4;      // the centre sub-pixel counts double: less horizontal blur than a plain average
                uint8_t v = lut[g];
                rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = v;
            }
            ok = 1;
        }
    }
    a->Release(); return ok;
}
