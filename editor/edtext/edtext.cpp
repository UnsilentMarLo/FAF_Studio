#define EDT_BUILD
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d2d1.h>        // ID2D1SimplifiedGeometrySink: DirectWrite's IDWriteGeometrySink is a typedef of it (interface only: nothing from d2d1.dll is called)
#include <dwrite.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <vector>
#include "edtext.h"
#include "edraster.h"

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
    std::vector<float> ySnap;             // per face: vertical glyph scale that puts the x-height on a whole pixel row (edr::XHeightSnapScale); < 0 = not measured yet
    uint32_t faceId(IDWriteFontFace* f) {
        for (uint32_t i = 0; i < faces.size(); i++) if (faces[i] == f) return i;
        f->AddRef(); faces.push_back(f); ySnap.push_back(-1.f); return (uint32_t)faces.size() - 1;
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

namespace {
// Tunables, read once. They exist so the look can be adjusted without rebuilding the DLL (set the variable before starting the editor):
//   EDTEXT_RASTER=dwrite   the previous method: DirectWrite's ClearType texture averaged to gray (softer; for A/B comparison)
//   EDTEXT_GAMMA=0.72      coverage curve; below 1 gives thin light-on-dark strokes more weight, 1 = none
//   EDTEXT_YSNAP=0         switch off the x-height snap (glyphs keep their designed height)
struct RasterSettings {
    bool dwriteGray = false;
    bool ySnap = true;
    uint8_t lut[256];
    RasterSettings() {
        const char* r = getenv("EDTEXT_RASTER");
        dwriteGray = r && (r[0] == 'd' || r[0] == 'D');
        const char* y = getenv("EDTEXT_YSNAP");
        ySnap = !(y && y[0] == '0');
        float gamma = 0.72f;
        if (const char* g = getenv("EDTEXT_GAMMA")) { float v = (float)atof(g); if (v >= 0.3f && v <= 2.5f) gamma = v; }
        edr::BuildContrastLut(lut, gamma);
    }
};
const RasterSettings& settings() { static RasterSettings s; return s; }

// Receives a glyph outline from IDWriteFontFace::GetGlyphRunOutline: straight lines and cubic Beziers (DirectWrite raises TrueType quadratics to cubics), y down, origin on the baseline.
struct OutlineSink : IDWriteGeometrySink {
    edr::Rasteriser* ras; long ref = 1;
    explicit OutlineSink(edr::Rasteriser* r) : ras(r) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** o) override {
        if (IsEqualIID(id, __uuidof(IUnknown)) || IsEqualIID(id, __uuidof(IDWriteGeometrySink))) { *o = this; return S_OK; }
        *o = nullptr; return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++ref; }
    ULONG STDMETHODCALLTYPE Release() override { return --ref; }            // lives on the caller's stack
    void STDMETHODCALLTYPE SetFillMode(D2D1_FILL_MODE) override {}
    void STDMETHODCALLTYPE SetSegmentFlags(D2D1_PATH_SEGMENT) override {}
    void STDMETHODCALLTYPE BeginFigure(D2D1_POINT_2F p, D2D1_FIGURE_BEGIN) override { ras->moveTo(p.x, p.y); }
    void STDMETHODCALLTYPE AddLines(const D2D1_POINT_2F* pts, UINT32 n) override { for (UINT32 i = 0; i < n; i++) ras->lineTo(pts[i].x, pts[i].y); }
    void STDMETHODCALLTYPE AddBeziers(const D2D1_BEZIER_SEGMENT* b, UINT32 n) override {
        for (UINT32 i = 0; i < n; i++) ras->cubicTo(b[i].point1.x, b[i].point1.y, b[i].point2.x, b[i].point2.y, b[i].point3.x, b[i].point3.y);
    }
    void STDMETHODCALLTYPE EndFigure(D2D1_FIGURE_END) override { ras->close(); }
    HRESULT STDMETHODCALLTYPE Close() override { return S_OK; }
};

// Vertical snap scale of one face (edr::XHeightSnapScale), measured once on first use: the top of the glyph 'x' (flat topped, so it is the x-height of the instance in use,
// also for variable fonts), else the font metrics' xHeight, else 1 (no snap).
float measureSnap(IDWriteFontFace* face, float px) {
    UINT32 cp = 'x'; UINT16 gi = 0;
    if (SUCCEEDED(face->GetGlyphIndices(&cp, 1, &gi)) && gi != 0) {
        edr::Rasteriser r; OutlineSink sink(&r); FLOAT adv = 0;
        if (SUCCEEDED(face->GetGlyphRunOutline(px, &gi, &adv, nullptr, 1, FALSE, FALSE, &sink)) && r.minY() < 0.f) return edr::XHeightSnapScale(-r.minY());
    }
    DWRITE_FONT_METRICS m{};
    face->GetMetrics(&m);
    if (m.designUnitsPerEm > 0 && m.xHeight > 0) return edr::XHeightSnapScale(px * (float)m.xHeight / (float)m.designUnitsPerEm);
    return 1.f;
}

// The previous rasteriser: ClearType 3x1 coverage averaged to one value. Kept behind EDTEXT_RASTER=dwrite.
int rasterDWriteGray(EdFont* f, uint32_t face, uint32_t glyph, int phase, int* left, int* top, int* w, int* h, uint8_t* rgb, int cap, const uint8_t* lut) {
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
            int px = (*w) * (*h);
            for (int i = 0; i < px; i++) {
                int g = (rgb[i * 3] + 2 * rgb[i * 3 + 1] + rgb[i * 3 + 2] + 2) / 4;
                rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = lut[g];
            }
            ok = 1;
        }
    }
    a->Release(); return ok;
}
}  // namespace

EDT_API int edt_raster(EdFont* f, uint32_t face, uint32_t glyph, int phase, int* left, int* top, int* w, int* h, uint8_t* rgb, int cap) {
    *left = *top = *w = *h = 0;
    if (face >= f->faces.size() || !ensureFactory()) return 0;
    const RasterSettings& st = settings();
    if (st.dwriteGray) return rasterDWriteGray(f, face, glyph, phase, left, top, w, h, rgb, cap, st.lut);

    // Grayscale from the outline: exact pixel coverage, no ClearType filter and no colour (edraster.h).
    UINT16 gi = (UINT16)glyph; FLOAT adv = 0;
    edr::Rasteriser ras;
    OutlineSink sink(&ras);
    if (FAILED(f->faces[face]->GetGlyphRunOutline(f->px, &gi, &adv, nullptr, 1, FALSE, FALSE, &sink))) return 0;
    edr::Bitmap bm;
    float sy = 1.f;
    if (st.ySnap) {
        if (f->ySnap[face] < 0.f) f->ySnap[face] = measureSnap(f->faces[face], f->px);
        sy = f->ySnap[face];
    }
    if (!ras.render(phase / 4.f, sy, bm)) return 0;
    *left = bm.left; *top = bm.top; *w = bm.w; *h = bm.h;
    if (bm.w * bm.h * 3 > cap) return 0;
    const size_t n = (size_t)bm.w * bm.h;
    for (size_t i = 0; i < n; i++) rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = st.lut[bm.a[i]];     // the backend expects R, G, B per pixel: gray = all three equal
    return 1;
}
