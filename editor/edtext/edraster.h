// edraster.h: grayscale glyph rasteriser with exact area coverage (no platform headers, header only).
//
// Why: DirectWrite has no true grayscale alpha texture for a glyph run. The editor used to take the ClearType 3x1 texture and average its sub-pixels, but that texture has
// already been through ClearType's horizontal filter (about 1.7 px wide), so every stem came out soft. This rasteriser gets the glyph outline from DirectWrite
// (IDWriteFontFace::GetGlyphRunOutline) and computes, per pixel, the exact fraction of the pixel the outline covers: no filter, no sub-pixel colour.
//
// Method: signed-area accumulation (the scheme of font-rs / stb_truetype v2). Every outline edge adds its signed area to a buffer; a running sum along each row then gives the
// coverage. Non-zero winding is approximated by min(1, |sum|): overlapping contours of the same direction (variable fonts have them) clamp to full coverage; overlapping contours of
// opposite direction would cancel, which does not occur in the fonts the editor uses.
//
// Tested against an exact polygon-area reference and a 16x supersampled FreeType render: editor/edtext/test/ (run_tests.py).
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace edr {

struct Bitmap {
    int left = 0, top = 0;        // pixel position of the first column / row, relative to the glyph origin (y grows downwards, the baseline is y = 0)
    int w = 0, h = 0;
    std::vector<uint8_t> a;       // coverage 0..255, row-major, top row first
};

class Rasteriser {
public:
    void clear() { pts_.clear(); starts_.clear(); open_ = false; }

    void moveTo(float x, float y) {
        close();
        starts_.push_back((int)pts_.size());
        pts_.push_back({x, y});
        open_ = true;
    }
    void lineTo(float x, float y) {
        if (!open_) { moveTo(x, y); return; }
        pts_.push_back({x, y});
    }
    void cubicTo(float x1, float y1, float x2, float y2, float x3, float y3) {
        if (!open_) moveTo(x1, y1);
        const P p0 = pts_.back(), p1 = {x1, y1}, p2 = {x2, y2}, p3 = {x3, y3};
        // uniform subdivision: chord error <= 0.75 * dd / n^2 with dd the larger second difference of the control polygon
        float d1 = std::hypot(p0.x - 2 * p1.x + p2.x, p0.y - 2 * p1.y + p2.y);
        float d2 = std::hypot(p1.x - 2 * p2.x + p3.x, p1.y - 2 * p2.y + p3.y);
        int n = (int)std::ceil(std::sqrt(0.75f * std::max(d1, d2) / kFlatness));
        n = std::max(1, std::min(n, 64));
        for (int i = 1; i <= n; i++) {
            float t = (float)i / (float)n, u = 1.f - t;
            float b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t;
            pts_.push_back({b0 * p0.x + b1 * p1.x + b2 * p2.x + b3 * p3.x, b0 * p0.y + b1 * p1.y + b2 * p2.y + b3 * p3.y});
        }
    }
    void quadTo(float x1, float y1, float x2, float y2) {
        if (!open_) moveTo(x1, y1);
        const P p0 = pts_.back();
        cubicTo(p0.x + 2.f / 3.f * (x1 - p0.x), p0.y + 2.f / 3.f * (y1 - p0.y), x2 + 2.f / 3.f * (x1 - x2), y2 + 2.f / 3.f * (y1 - y2), x2, y2);
    }
    void close() { open_ = false; }       // contours are closed implicitly when edges are generated

    bool empty() const { return pts_.size() < 3; }
    float minY() const { float m = 0.f; for (const P& p : pts_) m = std::min(m, p.y); return m; }     // highest point above the baseline (negative), 0 if none

    // Renders the outline moved by dx (pixels, the sub-pixel phase) and scaled by sy about the baseline (1 = unchanged; < 1 pulls tall glyphs down).
    // Returns false when nothing is covered. The bitmap is trimmed to the pixels that have coverage.
    bool render(float dx, float sy, Bitmap& out) const {
        out = Bitmap();
        if (empty()) return false;
        float minx = 1e30f, miny = 1e30f, maxx = -1e30f, maxy = -1e30f;
        for (const P& p : pts_) {
            float x = p.x + dx, y = p.y * sy;
            minx = std::min(minx, x); maxx = std::max(maxx, x);
            miny = std::min(miny, y); maxy = std::max(maxy, y);
        }
        int left = (int)std::floor(minx), top = (int)std::floor(miny);
        int right = (int)std::ceil(maxx), bottom = (int)std::ceil(maxy);
        int w = right - left, h = bottom - top;
        if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return false;
        const int stride = w + 2;
        std::vector<float> acc((size_t)stride * h, 0.f);

        int ncont = (int)starts_.size();
        for (int c = 0; c < ncont; c++) {
            int b = starts_[c], e = (c + 1 < ncont) ? starts_[c + 1] : (int)pts_.size();
            if (e - b < 2) continue;
            for (int i = b; i < e; i++) {
                const P& p = pts_[i];
                const P& q = pts_[i + 1 < e ? i + 1 : b];          // the contour closes back to its start
                line(acc, stride, w, h, p.x + dx - left, p.y * sy - top, q.x + dx - left, q.y * sy - top);
            }
        }

        std::vector<uint8_t> cov((size_t)w * h, 0);
        int x0 = w, x1 = -1, y0 = h, y1 = -1;                  // bounds of the non-empty part
        for (int y = 0; y < h; y++) {
            float sum = 0.f;
            const float* row = &acc[(size_t)y * stride];
            for (int x = 0; x < w; x++) {
                sum += row[x];
                float c = std::min(1.f, std::fabs(sum));
                uint8_t v = (uint8_t)(c * 255.f + 0.5f);
                cov[(size_t)y * w + x] = v;
                if (v) { x0 = std::min(x0, x); x1 = std::max(x1, x); y0 = std::min(y0, y); y1 = std::max(y1, y); }
            }
        }
        if (x1 < 0) return false;                               // nothing visible (a space, or a sliver below 1/510 coverage)
        out.left = left + x0; out.top = top + y0; out.w = x1 - x0 + 1; out.h = y1 - y0 + 1;
        out.a.resize((size_t)out.w * out.h);
        for (int y = 0; y < out.h; y++)
            std::copy(&cov[(size_t)(y + y0) * w + x0], &cov[(size_t)(y + y0) * w + x0] + out.w, &out.a[(size_t)y * out.w]);
        return true;
    }

private:
    struct P { float x, y; };
    static constexpr float kFlatness = 0.004f;    // pixels: chord error of the flattened curves (about 1/255 of a pixel of area)
    std::vector<P> pts_;
    std::vector<int> starts_;
    bool open_ = false;

    // Adds the signed area of one edge (coordinates already relative to the bitmap) to the accumulation buffer.
    static void line(std::vector<float>& a, int stride, int w, int h, float x0, float y0, float x1, float y1) {
        if (y0 == y1) return;
        float dir = 1.f;
        if (y0 > y1) { std::swap(x0, x1); std::swap(y0, y1); dir = -1.f; }
        const float dxdy = (x1 - x0) / (y1 - y0);
        float x = x0;
        int ys = std::max(0, (int)y0);
        if (y0 < 0.f) x -= y0 * dxdy;
        const int ye = std::min(h, (int)std::ceil(y1));
        const float fw = (float)w;
        for (int y = ys; y < ye; y++) {
            float* row = &a[(size_t)y * stride];
            float dy = std::min((float)(y + 1), y1) - std::max((float)y, y0);
            float xnext = x + dxdy * dy;
            float d = dy * dir;
            float xa = std::min(x, xnext), xb = std::max(x, xnext);
            xa = std::max(0.f, std::min(fw, xa));
            xb = std::max(0.f, std::min(fw, xb));
            float xaf = std::floor(xa);
            int xai = (int)xaf;
            float xbc = std::ceil(xb);
            int xbi = (int)xbc;
            if (xbi <= xai + 1) {
                float xmf = 0.5f * (xa + xb) - xaf;
                row[xai] += d - d * xmf;
                row[xai + 1] += d * xmf;
            } else {
                float s = 1.f / (xb - xa);
                float x0f = xa - xaf;
                float a0 = 0.5f * s * (1.f - x0f) * (1.f - x0f);
                float x1f = xb - xbc + 1.f;
                float am = 0.5f * s * x1f * x1f;
                row[xai] += d * a0;
                if (xbi == xai + 2) {
                    row[xai + 1] += d * (1.f - a0 - am);
                } else {
                    float a1 = s * (1.5f - x0f);
                    row[xai + 1] += d * (a1 - a0);
                    for (int xi = xai + 2; xi < xbi - 1; xi++) row[xi] += d * s;
                    float a2 = a1 + (float)(xbi - xai - 3) * s;
                    row[xbi - 1] += d * (1.f - a2 - am);
                }
                row[xbi] += d * am;
            }
            x = xnext;
        }
    }
};

// Contrast curve for light text on dark panels: coverage^gamma (gamma < 1 thickens thin strokes). lut must hold 256 entries.
inline void BuildContrastLut(uint8_t* lut, float gamma) {
    for (int i = 0; i < 256; i++) {
        float v = 255.f * std::pow((float)i / 255.f, gamma) + 0.5f;
        lut[i] = (uint8_t)std::min(255.f, std::max(0.f, v));
    }
}

// Vertical scale that makes the x-height a whole number of pixels (a light version of what FreeType's auto-hinter does): flat lowercase tops land on a pixel row instead of
// straddling two. Limited to +-6 % so glyph shapes stay as designed; 1 when the font is large enough that rounding does not matter.
inline float XHeightSnapScale(float xHeightPx) {
    if (xHeightPx < 3.f || xHeightPx > 14.f) return 1.f;
    float target = std::floor(xHeightPx + 0.5f);
    float s = target / xHeightPx;
    return std::max(0.94f, std::min(1.06f, s));
}

}  // namespace edr
