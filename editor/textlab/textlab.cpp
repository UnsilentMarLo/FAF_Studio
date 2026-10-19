// P0 text lab: offline comparison of the legacy game text path (GDI antialiased + DXT5 alpha round trip) with GDI
// ClearType and DirectWrite (gray with 4 sub-pixel phases, LCD with software versions of the planned GPU blend).
// Writes PNG sheets and results.txt. Design: docs/projects/editor_research/SPIKE_CLEAN_TEXT.md section 4.1.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwrite.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

// ---------------------------------------------------------------- image + PNG (stored deflate, no dependencies)
struct Img {
    int w, h;
    std::vector<uint8_t> px;  // RGB
    Img(int w_, int h_) : w(w_), h(h_), px((size_t)w_ * h_ * 3, 0) {}
    uint8_t* at(int x, int y) { return &px[((size_t)y * w + x) * 3]; }
    bool in(int x, int y) const { return x >= 0 && y >= 0 && x < w && y < h; }
};
static uint32_t crcTab[256];
static void crcInit() { for (uint32_t n = 0; n < 256; n++) { uint32_t c = n; for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1; crcTab[n] = c; } }
static uint32_t crc(const uint8_t* b, size_t n, uint32_t c = 0xFFFFFFFFu) { for (size_t i = 0; i < n; i++) c = crcTab[(c ^ b[i]) & 255] ^ (c >> 8); return c; }
static void be32(std::vector<uint8_t>& v, uint32_t x) { v.push_back(x >> 24); v.push_back(x >> 16); v.push_back(x >> 8); v.push_back(x); }
static void chunk(FILE* f, const char* type, const std::vector<uint8_t>& d) {
    std::vector<uint8_t> h; be32(h, (uint32_t)d.size()); fwrite(h.data(), 1, 4, f);
    std::vector<uint8_t> td(type, type + 4); td.insert(td.end(), d.begin(), d.end()); fwrite(td.data(), 1, td.size(), f);
    std::vector<uint8_t> c; be32(c, ~crc(td.data(), td.size())); fwrite(c.data(), 1, 4, f);
}
static void writePng(const Img& im, const char* path) {
    crcInit();
    std::vector<uint8_t> raw; raw.reserve((size_t)(im.w * 3 + 1) * im.h);
    for (int y = 0; y < im.h; y++) { raw.push_back(0); raw.insert(raw.end(), &im.px[(size_t)y * im.w * 3], &im.px[(size_t)y * im.w * 3] + im.w * 3); }
    std::vector<uint8_t> z = {0x78, 0x01};
    size_t pos = 0;
    while (pos < raw.size()) {
        size_t n = std::min<size_t>(65535, raw.size() - pos); bool last = pos + n >= raw.size();
        z.push_back(last ? 1 : 0); z.push_back(n & 255); z.push_back(n >> 8); z.push_back(~n & 255); z.push_back((~n >> 8) & 255);
        z.insert(z.end(), raw.begin() + pos, raw.begin() + pos + n); pos += n;
    }
    uint32_t a = 1, b = 0; for (uint8_t v : raw) { a = (a + v) % 65521; b = (b + a) % 65521; }
    be32(z, (b << 16) | a);
    FILE* f = fopen(path, "wb"); if (!f) return;
    const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10}; fwrite(sig, 1, 8, f);
    std::vector<uint8_t> ih; be32(ih, im.w); be32(ih, im.h); ih.push_back(8); ih.push_back(2); ih.push_back(0); ih.push_back(0); ih.push_back(0);
    chunk(f, "IHDR", ih); chunk(f, "IDAT", z); chunk(f, "IEND", {}); fclose(f);
}

// ---------------------------------------------------------------- blending (software references)
struct Col { float r, g, b; };  // 0..255
static float lin(float v) { v /= 255.f; return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f); }
static float unlin(float v) { v = v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1.f / 2.4f) - 0.055f; return v * 255.f; }
static uint8_t q8(float v) { return (uint8_t)std::min(255.f, std::max(0.f, v + 0.5f)); }
static float lum(Col c) { return (0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b) / 255.f; }

enum Blend { SRGB, LINEAR, LUMA };
static void blendPx(Img& im, int x, int y, const float cov[3], Col t, Blend m) {
    if (!im.in(x, y)) return;
    uint8_t* d = im.at(x, y); float tc[3] = {t.r, t.g, t.b};
    float e = 1.f - 0.3f * lum(t);  // LUMA: coverage exponent from the text colour only (what a pixel shader can know)
    for (int i = 0; i < 3; i++) {
        float c = cov[i];
        if (m == LUMA) c = std::pow(c, e);
        if (m == LINEAR) d[i] = q8(unlin(lin(d[i]) * (1 - c) + lin(tc[i]) * c));
        else d[i] = q8(d[i] * (1 - c) + tc[i] * c);
    }
}
// The planned GPU version: pass 0 dst*(1-cov) rounded to 8 bit, pass 1 += C*cov rounded to 8 bit.
static void blendTwoPass(Img& im, int x, int y, const float cov[3], Col t) {
    uint8_t* d = im.at(x, y); float tc[3] = {t.r, t.g, t.b};
    for (int i = 0; i < 3; i++) { uint8_t p0 = q8(d[i] * (1 - cov[i])); uint8_t add = q8(tc[i] * cov[i]); d[i] = (uint8_t)std::min(255, p0 + add); }
}

// ---------------------------------------------------------------- DirectWrite
static IDWriteFactory* gDW = nullptr;
static std::wstring gFamily = L"Segoe UI";
static double gRasterMs = 0; static int gRasterCount = 0;

struct GlyphBmp { RECT b; std::vector<uint8_t> t; };  // 3 bytes per pixel (RGB subpixel coverage)
static std::map<std::string, GlyphBmp> gCache;

struct Params { DWRITE_RENDERING_MODE mode; bool lcd; Blend blend; bool twoPass; };

struct TextRenderer : IDWriteTextRenderer {
    Img* im; Col color; Params p; float dx, dy;
    long ref = 1;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** o) override { if (IsEqualIID(id, __uuidof(IUnknown)) || IsEqualIID(id, __uuidof(IDWritePixelSnapping)) || IsEqualIID(id, __uuidof(IDWriteTextRenderer))) { *o = this; return S_OK; } *o = nullptr; return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++ref; }
    ULONG STDMETHODCALLTYPE Release() override { return --ref; }
    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void*, BOOL* d) override { *d = TRUE; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void*, DWRITE_MATRIX* m) override { *m = {1, 0, 0, 1, 0, 0}; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void*, FLOAT* v) override { *v = 1.f; return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawUnderline(void*, FLOAT, FLOAT, const DWRITE_UNDERLINE*, IUnknown*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawStrikethrough(void*, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH*, IUnknown*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawInlineObject(void*, FLOAT, FLOAT, IDWriteInlineObject*, BOOL, BOOL, IUnknown*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void*, FLOAT bx, FLOAT by, DWRITE_MEASURING_MODE mm, const DWRITE_GLYPH_RUN* run, const DWRITE_GLYPH_RUN_DESCRIPTION*, IUnknown*) override {
        float pen = bx;
        for (UINT32 i = 0; i < run->glyphCount; i++) {
            float gx = pen + (run->glyphOffsets ? run->glyphOffsets[i].advanceOffset : 0);
            float fl = std::floor(gx); int ph = (int)std::floor((gx - fl) * 4.f + 0.5f);  // 4 sub-pixel phases
            if (ph == 4) { ph = 0; fl += 1; }
            int gy = (int)std::floor(by + 0.5f);
            char key[160]; snprintf(key, sizeof key, "%p|%u|%.2f|%d|%d", (void*)run->fontFace, run->glyphIndices[i], run->fontEmSize, ph, (int)p.mode);
            auto it = gCache.find(key);
            if (it == gCache.end()) {
                auto t0 = std::chrono::high_resolution_clock::now();
                UINT16 gi = run->glyphIndices[i]; FLOAT adv = 0;
                DWRITE_GLYPH_RUN g = {run->fontFace, run->fontEmSize, 1, &gi, &adv, nullptr, FALSE, 0};
                IDWriteGlyphRunAnalysis* a = nullptr; GlyphBmp gb; gb.b = {0, 0, 0, 0};
                if (SUCCEEDED(gDW->CreateGlyphRunAnalysis(&g, 1.f, nullptr, p.mode, mm, ph / 4.f, 0.f, &a))) {
                    if (SUCCEEDED(a->GetAlphaTextureBounds(DWRITE_TEXTURE_CLEARTYPE_3x1, &gb.b)) && gb.b.right > gb.b.left) {
                        gb.t.resize((size_t)(gb.b.right - gb.b.left) * (gb.b.bottom - gb.b.top) * 3);
                        a->CreateAlphaTexture(DWRITE_TEXTURE_CLEARTYPE_3x1, &gb.b, gb.t.data(), (UINT32)gb.t.size());
                    }
                    a->Release();
                }
                gRasterMs += std::chrono::duration<double, std::milli>(std::chrono::high_resolution_clock::now() - t0).count(); gRasterCount++;
                it = gCache.emplace(key, std::move(gb)).first;
            }
            const GlyphBmp& gb = it->second; int w = gb.b.right - gb.b.left, h = gb.b.bottom - gb.b.top;
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                const uint8_t* s = &gb.t[((size_t)y * w + x) * 3]; float c[3] = {s[0] / 255.f, s[1] / 255.f, s[2] / 255.f};
                if (!p.lcd) { float a = (c[0] + c[1] + c[2]) / 3.f; c[0] = c[1] = c[2] = a; }
                int px = (int)fl + gb.b.left + x + (int)dx, py = gy + gb.b.top + y + (int)dy;
                if (!im->in(px, py)) continue;
                if (p.twoPass) blendTwoPass(*im, px, py, c, color); else blendPx(*im, px, py, c, color, p.blend);
            }
            pen += run->glyphAdvances[i];
        }
        return S_OK;
    }
};

static IDWriteTextFormat* makeFormat(float px) {
    IDWriteTextFormat* f = nullptr;
    gDW->CreateTextFormat(gFamily.c_str(), nullptr, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, px, L"en-us", &f);
    return f;
}
// Draws a string at fractional x with the DirectWrite pipeline; returns the layout advance width.
static float dwText(Img& im, const std::wstring& s, float x, float y, float px, Col c, Params p) {
    IDWriteTextFormat* f = makeFormat(px); IDWriteTextLayout* l = nullptr;
    gDW->CreateTextLayout(s.c_str(), (UINT32)s.size(), f, 4000.f, 200.f, &l);
    DWRITE_TEXT_METRICS tm{}; l->GetMetrics(&tm);
    DWRITE_LINE_METRICS lm{}; UINT32 n = 1; l->GetLineMetrics(&lm, 1, &n);
    TextRenderer r; r.im = &im; r.color = c; r.p = p; r.dx = 0; r.dy = 0;
    // DrawGlyphRun receives the baseline; layout origin is the top-left, so y + baseline is added by DirectWrite.
    l->Draw(nullptr, &r, x, y);
    float w = tm.widthIncludingTrailingWhitespace; l->Release(); f->Release(); return w;
}
static float dwWidth(const std::wstring& s, float px) {
    IDWriteTextFormat* f = makeFormat(px); IDWriteTextLayout* l = nullptr;
    gDW->CreateTextLayout(s.c_str(), (UINT32)s.size(), f, 4000.f, 200.f, &l);
    DWRITE_TEXT_METRICS tm{}; l->GetMetrics(&tm); float w = tm.widthIncludingTrailingWhitespace; l->Release(); f->Release(); return w;
}

// ---------------------------------------------------------------- GDI paths
struct Dib { HDC dc; HBITMAP bmp; uint8_t* bits; int w, h; HFONT font, old; };
static Dib dibNew(int w, int h) {
    Dib d{}; d.w = w; d.h = h; HDC s = GetDC(nullptr); d.dc = CreateCompatibleDC(s); ReleaseDC(nullptr, s);
    BITMAPINFO bi{}; bi.bmiHeader = {sizeof(BITMAPINFOHEADER), w, -h, 1, 32, BI_RGB, 0, 0, 0, 0, 0};
    d.bmp = CreateDIBSection(d.dc, &bi, DIB_RGB_COLORS, (void**)&d.bits, nullptr, 0); SelectObject(d.dc, d.bmp); return d;
}
static void dibFree(Dib& d) { if (d.font) { SelectObject(d.dc, d.old); DeleteObject(d.font); } DeleteObject(d.bmp); DeleteDC(d.dc); }
static void dibFont(Dib& d, const wchar_t* face, int px, DWORD quality) {
    d.font = CreateFontW(-px, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, quality, DEFAULT_PITCH, face);
    d.old = (HFONT)SelectObject(d.dc, d.font);
}
// Legacy emulation: per glyph GDI ANTIALIASED into a cell, alpha encoded like DXT5 (per 4x4 block: min/max, 8 levels), integer advance, no kerning.
static float legacyText(Img& im, const std::wstring& s, int x, int y, int px, Col c, const wchar_t* face) {
    Dib d = dibNew(64, 64); dibFont(d, face, px, ANTIALIASED_QUALITY);
    SetBkMode(d.dc, OPAQUE); SetBkColor(d.dc, 0); SetTextColor(d.dc, 0xFFFFFF);
    TEXTMETRICW tm; GetTextMetricsW(d.dc, &tm); int pen = x;
    for (wchar_t ch : s) {
        RECT all = {0, 0, 64, 64}; FillRect(d.dc, &all, (HBRUSH)GetStockObject(BLACK_BRUSH));
        TextOutW(d.dc, 4, 4, &ch, 1);
        SIZE sz; GetTextExtentPoint32W(d.dc, &ch, 1, &sz);
        std::vector<uint8_t> a(64 * 64); for (int i = 0; i < 64 * 64; i++) a[i] = d.bits[i * 4 + 1];
        for (int by = 0; by < 64; by += 4) for (int bx = 0; bx < 64; bx += 4) {  // DXT5 alpha block
            int mn = 255, mx = 0; for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) { int v = a[(by + j) * 64 + bx + i]; mn = std::min(mn, v); mx = std::max(mx, v); }
            int lv[8]; lv[0] = mx; lv[1] = mn; for (int k = 1; k < 7; k++) lv[k + 1] = ((7 - k) * mx + k * mn) / 7;
            for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) { int v = a[(by + j) * 64 + bx + i], best = lv[0]; for (int k = 1; k < 8; k++) if (abs(lv[k] - v) < abs(best - v)) best = lv[k]; a[(by + j) * 64 + bx + i] = (uint8_t)best; }
        }
        for (int j = 0; j < 64; j++) for (int i = 0; i < 64; i++) { float cv = a[j * 64 + i] / 255.f; if (cv <= 0) continue; float cc[3] = {cv, cv, cv}; blendPx(im, pen + i - 4, y + j - 4, cc, c, SRGB); }
        pen += sz.cx;
    }
    dibFree(d); return (float)(pen - x);
}
// GDI ClearType: GDI draws the whole string onto a copy of the destination.
static float gdiCt(Img& im, const std::wstring& s, int x, int y, int px, Col c, const wchar_t* face) {
    int w = 1100, h = px * 2 + 8; Dib d = dibNew(w, h); dibFont(d, face, px, CLEARTYPE_QUALITY);
    for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) { uint8_t* o = im.in(x + i, y + j) ? im.at(x + i, y + j) : nullptr; uint8_t* p = &d.bits[((size_t)j * w + i) * 4]; if (o) { p[0] = o[2]; p[1] = o[1]; p[2] = o[0]; } }
    SetBkMode(d.dc, TRANSPARENT); SetTextColor(d.dc, RGB(q8(c.r), q8(c.g), q8(c.b))); TextOutW(d.dc, 0, 0, s.c_str(), (int)s.size());
    for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) if (im.in(x + i, y + j)) { uint8_t* o = im.at(x + i, y + j); uint8_t* p = &d.bits[((size_t)j * w + i) * 4]; o[0] = p[2]; o[1] = p[1]; o[2] = p[0]; }
    SIZE sz; GetTextExtentPoint32W(d.dc, s.c_str(), (int)s.size(), &sz); dibFree(d); return (float)sz.cx;
}

// ---------------------------------------------------------------- sheets
static const wchar_t* kSample = L"The quick brown fox  AVATAR To Wa  0123 -1.5  Ä ß é Ω Ж 日本語";
static void fillPanel(Img& im, int kind) {
    for (int y = 0; y < im.h; y++) for (int x = 0; x < im.w; x++) {
        uint8_t* p = im.at(x, y);
        if (kind == 0) { p[0] = 35; p[1] = 38; p[2] = 43; }
        else if (kind == 1) { p[0] = 244; p[1] = 245; p[2] = 247; }
        else { float t = (float)x / im.w; p[0] = q8(30 + 150 * t); p[1] = q8(34 + 150 * t); p[2] = q8(40 + 150 * t); }
    }
}
static void sheet(int panel, double scale, const char* path) {
    Img im(1160, 40 + 4 * 0 + 3 * 7 * 40); fillPanel(im, panel);
    Col text = panel == 1 ? Col{25, 27, 31} : Col{232, 235, 238}; Col dim = panel == 1 ? Col{90, 96, 104} : Col{150, 158, 166};
    float sizes[3] = {11, 12, 14}; int y = 8;
    struct V { const char* name; Params p; };
    Params gray{DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, false, SRGB, false};
    V vs[] = {{"DW gray 4 phases", gray},
              {"DW LCD natural-symmetric, sRGB blend", {DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, true, SRGB, false}},
              {"DW LCD natural (vertical hinting), sRGB blend", {DWRITE_RENDERING_MODE_NATURAL, true, SRGB, false}},
              {"DW LCD natural-symmetric, linear-light blend (reference)", {DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, true, LINEAR, false}},
              {"DW LCD natural-symmetric, luma-adjusted coverage (GPU-realisable)", {DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, true, LUMA, false}}};
    for (float s0 : sizes) {
        float px = (float)std::floor(s0 * scale * 10 + 0.5) / 10.f; char hdr[96]; snprintf(hdr, sizeof hdr, "%.1f px  (%d%% UI scale, base %.0f px)", px, (int)(scale * 100 + 0.5), s0);
        std::wstring wh(hdr, hdr + strlen(hdr)); dwText(im, wh, 8, (float)y, 11, dim, vs[1].p); y += 18;
        legacyText(im, kSample, 8, y, (int)px, text, L"Arial"); { std::wstring l = L"legacy (Arial, GDI AA + DXT5)"; dwText(im, l, 760, (float)y, 11, dim, vs[1].p); } y += (int)px + 10;
        gdiCt(im, kSample, 8, y, (int)std::lround(px), text, gFamily.c_str()); { std::wstring l = L"GDI ClearType"; dwText(im, l, 760, (float)y, 11, dim, vs[1].p); } y += (int)px + 10;
        for (auto& v : vs) { dwText(im, kSample, 8.0f, (float)y, px, text, v.p); std::wstring l(v.name, v.name + strlen(v.name)); dwText(im, l, 760, (float)y, 11, dim, vs[1].p); y += (int)px + 10; }
        y += 10;
    }
    im.h = std::min(im.h, y + 8); Img out(im.w, im.h); out.px.assign(im.px.begin(), im.px.begin() + (size_t)im.w * im.h * 3); writePng(out, path);
}

// Zoomed (4x nearest) comparison of one short string per variant, to judge stems, fringes and weight by eye.
static void zoomSheet(int panel, double scale, const char* path) {
    const std::wstring str = L"Hamburgefonts  AV To Wa  il1I  0123";
    Img sm(330, 9 * 22); fillPanel(sm, panel);
    Col text = panel == 1 ? Col{25, 27, 31} : Col{232, 235, 238};
    float px = (float)(12 * scale);
    struct V { Params p; };
    Params ps[] = {{DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, false, SRGB, false}, {DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, true, SRGB, false},
                   {DWRITE_RENDERING_MODE_NATURAL, true, SRGB, false}, {DWRITE_RENDERING_MODE_GDI_NATURAL, true, SRGB, false},
                   {DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, true, LINEAR, false}, {DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, true, LUMA, false},
                   {DWRITE_RENDERING_MODE_GDI_NATURAL, true, LUMA, false}};
    int y = 2; legacyText(sm, str, 2, y, (int)px, text, L"Arial"); y += 22;
    gdiCt(sm, str, 2, y, (int)std::lround(px), text, gFamily.c_str()); y += 22;
    for (auto& p : ps) { dwText(sm, str, 2.f, (float)y, px, text, p); y += 22; }
    Img big(sm.w * 4, sm.h * 4);
    for (int j = 0; j < big.h; j++) for (int i = 0; i < big.w; i++) { uint8_t* s = sm.at(i / 4, j / 4); uint8_t* d = big.at(i, j); d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; }
    writePng(big, path);
}

// ---------------------------------------------------------------- acceptance checks
static double centroidX(Img& im, int bx0, int bx1, Col bg, int y0, int y1) {
    double sum = 0, w = 0; for (int y = y0; y < y1; y++) for (int x = bx0; x < bx1; x++) { uint8_t* p = im.at(x, y); double v = (p[0] + p[1] + p[2]) / 3.0 - (bg.r + bg.g + bg.b) / 3.0; if (v > 0) { sum += v * (x + 0.5); w += v; } }
    return w > 0 ? sum / w : 0;
}
static std::string checks() {
    std::string out; char b[256]; Params gray{DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, false, SRGB, false}, lcd{DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, true, SRGB, false};
    // 2 sub-pixel positioning
    out += "[2] Sub-pixel positioning: 'iiiiiiii' at 12 px, x = 10.00 / .25 / .50 / .75, gray; centroid step per 0.25 px (target 0.25 +/- 0.1)\n";
    double prev = 0; for (int k = 0; k < 4; k++) {
        Img im(200, 30); for (int i = 0; i < im.w * im.h; i++) { im.px[i * 3] = 0; im.px[i * 3 + 1] = 0; im.px[i * 3 + 2] = 0; }
        dwText(im, L"iiiiiiii", 10.f + k * 0.25f, 4, 12, Col{255, 255, 255}, gray); double c = centroidX(im, 0, 200, Col{0, 0, 0}, 0, 30);
        snprintf(b, sizeof b, "    x=%.2f  centroid=%.3f%s\n", 10 + k * 0.25, c, k ? ("  step=" + std::to_string(c - prev)).c_str() : ""); out += b; prev = c; }
    // 3 kerning
    out += "[3] Kerning (12 px): pair width vs sum of single widths (negative = kerned)\n";
    const wchar_t* pairs[] = {L"AV", L"To", L"Wa", L"LT", L"ab"};
    for (auto pr : pairs) { std::wstring s = pr; float w = dwWidth(s, 12), a = dwWidth(s.substr(0, 1), 12), c = dwWidth(s.substr(1), 12);
        snprintf(b, sizeof b, "    %c%c  pair=%.3f  sum=%.3f  delta=%.3f\n", (char)pr[0], (char)pr[1], w, a + c, w - (a + c)); out += b; }
    // 4 unicode
    out += "[4] Unicode: glyph bitmap differs from the missing-glyph box (U+FFFF) and is non-empty\n";
    auto sig = [&](const std::wstring& s) { Img im(60, 40); for (auto& v : im.px) v = 0; dwText(im, s, 6, 6, 14, Col{255, 255, 255}, gray); uint64_t h = 1469598103934665603ull; long ink = 0; for (auto v : im.px) { h = (h ^ v) * 1099511628211ull; ink += v; } return std::make_pair(h, ink); };
    auto miss = sig(L"￿");
    struct U { const wchar_t* s; const char* n; } us[] = {{L"ß", "sharp s"}, {L"é", "e acute"}, {L"ñ", "n tilde"}, {L"Ω", "Omega"}, {L"Ж", "Zhe"}, {L"€", "Euro"}, {L"日", "CJK ri"}, {L"☺", "smiley"}, {L"\U0001F600", "U+1F600 (surrogate pair)"}};
    for (auto& u : us) { auto g = sig(u.s); snprintf(b, sizeof b, "    %-26s %s (ink %ld)\n", u.n, (g.first != miss.first && g.second > 0) ? "ok" : "MISSING-GLYPH BOX", g.second); out += b; }
    // 5 sharpness
    out += "[5] Sharpness (12 px, 'l'): highest coverage in a stem column (target >= 0.90)\n";
    for (auto md : {DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_RENDERING_MODE_NATURAL, DWRITE_RENDERING_MODE_GDI_NATURAL}) { double best = 0; for (int k = 0; k < 4; k++) { Img im(40, 30); for (auto& v : im.px) v = 0; Params p{md, false, SRGB, false}; dwText(im, L"l", 8.f + k * 0.25f, 4, 12, Col{255, 255, 255}, p);
            for (int x = 0; x < 40; x++) { double s = 0; for (int y = 0; y < 30; y++) s = std::max(s, (double)im.at(x, y)[1]); best = std::max(best, s / 255.0); } }
        snprintf(b, sizeof b, "    %s: best phase %.2f, over four phases max stem coverage %.2f\n", md == DWRITE_RENDERING_MODE_NATURAL ? "natural" : md == DWRITE_RENDERING_MODE_GDI_NATURAL ? "gdi-natural" : "natural-symmetric", 0.0, best); out += b; }
    // 6 lcd
    out += "[6] LCD: white on dark stem edge has R != B; gray has R = G = B; two-pass blend vs ideal (target <= 2/255)\n";
    { Img a(60, 30), g(60, 30); for (auto& v : a.px) v = 30; for (auto& v : g.px) v = 30; dwText(a, L"Hl", 8, 6, 12, Col{235, 235, 235}, lcd); dwText(g, L"Hl", 8, 6, 12, Col{235, 235, 235}, gray);
      int diffA = 0, diffG = 0; for (int y = 0; y < 30; y++) for (int x = 0; x < 60; x++) { if (a.at(x, y)[0] != a.at(x, y)[2]) diffA++; if (g.at(x, y)[0] != g.at(x, y)[2] || g.at(x, y)[0] != g.at(x, y)[1]) diffG++; }
      snprintf(b, sizeof b, "    LCD pixels with R!=B: %d   gray pixels with R,G,B unequal: %d\n", diffA, diffG); out += b; }
    { int worst = 0; Img ideal(60, 30), gpu(60, 30); for (auto& v : ideal.px) v = 30; for (auto& v : gpu.px) v = 30;
      Params tp{DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, true, SRGB, true}; dwText(ideal, L"Hello Wy", 4, 6, 12, Col{235, 200, 90}, lcd); dwText(gpu, L"Hello Wy", 4, 6, 12, Col{235, 200, 90}, tp);
      for (size_t i = 0; i < ideal.px.size(); i++) worst = std::max(worst, abs((int)ideal.px[i] - (int)gpu.px[i]));
      snprintf(b, sizeof b, "    max channel error two-pass vs ideal: %d/255\n", worst); out += b; }
    // 8 cost
    out += "[8] Cost of rasterising glyphs (cold cache), 12 px, all printable ASCII x 4 phases:\n";
    { gCache.clear(); gRasterMs = 0; gRasterCount = 0; Img im(1500, 20); std::wstring all; for (wchar_t c = 33; c < 127; c++) all += c;
      for (int k = 0; k < 4; k++) dwText(im, all, (float)(k * 0.25f), 2, 12, Col{255, 255, 255}, gray);
      snprintf(b, sizeof b, "    %d glyph bitmaps in %.2f ms (%.3f ms each) -> budget 40 ms for a cold first frame\n", gRasterCount, gRasterMs, gRasterCount ? gRasterMs / gRasterCount : 0.0); out += b; }
    return out;
}

int main() {
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), (IUnknown**)&gDW))) { puts("DWriteCreateFactory failed"); return 1; }
    IDWriteFontCollection* fc = nullptr; gDW->GetSystemFontCollection(&fc, FALSE); UINT32 idx = 0; BOOL ex = FALSE;
    if (SUCCEEDED(fc->FindFamilyName(L"Segoe UI Variable Text", &idx, &ex)) && ex) gFamily = L"Segoe UI Variable Text";
    std::string res = "Family used: " + std::string(gFamily.begin(), gFamily.end()) + "\n"; fc->Release();
    setvbuf(stderr, 0, _IONBF, 0); fputs("factory ok", stderr); fputc(10, stderr);
    sheet(0, 1.0, "sheet_dark_100.png"); fputs("sheet1", stderr); fputc(10, stderr);
    sheet(0, 1.5, "sheet_dark_150.png"); sheet(1, 1.0, "sheet_light_100.png"); sheet(1, 1.5, "sheet_light_150.png");
    sheet(2, 1.0, "sheet_gradient_100.png"); fputs("sheets done", stderr); fputc(10, stderr);
    zoomSheet(0, 1.0, "zoom_dark_100.png"); zoomSheet(1, 1.0, "zoom_light_100.png"); zoomSheet(0, 1.5, "zoom_dark_150.png");
    res += checks();
    FILE* f = fopen("results.txt", "wb"); fwrite(res.data(), 1, res.size(), f); fclose(f); fputs(res.c_str(), stdout); return 0;
}
