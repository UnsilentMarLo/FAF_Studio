// edcore: DDS decode / encode.
#include "edcore/dds.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace ed {

namespace {

uint32_t rd32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24); }
void wr32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v & 255);
    p[1] = static_cast<uint8_t>((v >> 8) & 255);
    p[2] = static_cast<uint8_t>((v >> 16) & 255);
    p[3] = static_cast<uint8_t>(v >> 24);
}

void rgb565(uint32_t c, uint8_t* o) {
    o[0] = static_cast<uint8_t>(((c >> 11) & 31) * 255 / 31);
    o[1] = static_cast<uint8_t>(((c >> 5) & 63) * 255 / 63);
    o[2] = static_cast<uint8_t>((c & 31) * 255 / 31);
}

void decodeColourBlock(const uint8_t* b, uint8_t out[16][4]) {
    const uint32_t c0 = static_cast<uint32_t>(b[0] | (b[1] << 8)), c1 = static_cast<uint32_t>(b[2] | (b[3] << 8));
    uint8_t col[4][4];
    rgb565(c0, col[0]);
    rgb565(c1, col[1]);
    col[0][3] = col[1][3] = 255;
    if (c0 > c1) {
        for (int k = 0; k < 3; ++k) {
            col[2][k] = static_cast<uint8_t>((2 * col[0][k] + col[1][k]) / 3);
            col[3][k] = static_cast<uint8_t>((col[0][k] + 2 * col[1][k]) / 3);
        }
        col[2][3] = col[3][3] = 255;
    } else {
        for (int k = 0; k < 3; ++k) {
            col[2][k] = static_cast<uint8_t>((col[0][k] + col[1][k]) / 2);
            col[3][k] = 0;
        }
        col[2][3] = 255;
        col[3][3] = 0;
    }
    const uint32_t bits = rd32(b + 4);
    for (int i = 0; i < 16; ++i) memcpy(out[i], col[(bits >> (2 * i)) & 3], 4);
}

int shiftOf(uint32_t m) {
    int s = 0;
    while (m && !(m & 1)) { m >>= 1; ++s; }
    return s;
}

int bitsOf(uint32_t m) {
    int c = 0;
    while (m) { c += static_cast<int>(m & 1); m >>= 1; }
    return c;
}

}  // namespace

bool ddsInfo(const uint8_t* d, size_t n, DdsInfo& info) {
    if (n < 128 || memcmp(d, "DDS ", 4) != 0) return false;
    info.height = static_cast<int>(rd32(d + 12));
    info.width = static_cast<int>(rd32(d + 16));
    info.mips = std::max<int>(1, static_cast<int>(rd32(d + 28)));
    const uint32_t pfFlags = rd32(d + 80), bits = rd32(d + 88);
    info.cube = (rd32(d + 112) & 0x200) != 0;
    if (pfFlags & 4) info.format.assign(reinterpret_cast<const char*>(d + 84), 4);
    else if (bits == 32) info.format = "ARGB8";
    else if (bits == 24) info.format = "RGB8";
    else if (bits == 16) info.format = "RGB16";
    else if (bits == 8) info.format = "L8";
    else info.format = "?";
    return true;
}

bool ddsDecode(const uint8_t* d, size_t n, Image& out, std::string* error) {
    auto fail = [&](const char* m) {
        if (error) *error = m;
        return false;
    };
    DdsInfo info;
    if (!ddsInfo(d, n, info)) return fail("not a DDS file");
    const int w = info.width, h = info.height;
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return fail("bad size");
    out.width = w;
    out.height = h;
    out.rgba.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
    const uint8_t* p = d + 128;
    const size_t avail = n - 128;
    if (info.format == "DXT1" || info.format == "DXT3" || info.format == "DXT5") {
        const int bw = (w + 3) / 4, bh = (h + 3) / 4;
        const size_t bs = info.format == "DXT1" ? 8 : 16;
        if (avail < static_cast<size_t>(bw) * static_cast<size_t>(bh) * bs) return fail("truncated");
        for (int by = 0; by < bh; ++by)
            for (int bx = 0; bx < bw; ++bx) {
                const uint8_t* b = p + (static_cast<size_t>(by) * static_cast<size_t>(bw) + static_cast<size_t>(bx)) * bs;
                uint8_t px[16][4];
                decodeColourBlock(bs == 8 ? b : b + 8, px);
                if (info.format == "DXT3") {
                    for (int i = 0; i < 16; ++i)
                        px[i][3] = static_cast<uint8_t>(((b[i / 2] >> ((i & 1) * 4)) & 15) * 17);
                } else if (info.format == "DXT5") {
                    uint8_t al[8] = {b[0], b[1]};
                    if (al[0] > al[1]) {
                        for (int i = 1; i < 7; ++i) al[i + 1] = static_cast<uint8_t>(((7 - i) * al[0] + i * al[1]) / 7);
                    } else {
                        for (int i = 1; i < 5; ++i) al[i + 1] = static_cast<uint8_t>(((5 - i) * al[0] + i * al[1]) / 5);
                        al[6] = 0;
                        al[7] = 255;
                    }
                    uint64_t bits = 0;
                    for (int i = 0; i < 6; ++i) bits |= static_cast<uint64_t>(b[2 + i]) << (8 * i);
                    for (int i = 0; i < 16; ++i) px[i][3] = al[(bits >> (3 * i)) & 7];
                }
                for (int i = 0; i < 16; ++i) {
                    const int x = bx * 4 + (i & 3), y = by * 4 + (i >> 2);
                    if (x < w && y < h)
                        memcpy(&out.rgba[(static_cast<size_t>(y) * static_cast<size_t>(w) + static_cast<size_t>(x)) * 4], px[i], 4);
                }
            }
        return true;
    }
    const uint32_t rm = rd32(d + 92), gm = rd32(d + 96), bm = rd32(d + 100), am = rd32(d + 104);
    const size_t count = static_cast<size_t>(w) * static_cast<size_t>(h);
    if (info.format == "ARGB8" || info.format == "RGB8") {
        const size_t step = info.format == "ARGB8" ? 4 : 3;
        if (avail < count * step) return fail("truncated");
        for (size_t i = 0; i < count; ++i) {
            const uint8_t* s = p + i * step;
            const uint32_t px = step == 4 ? rd32(s) : static_cast<uint32_t>(s[0] | (s[1] << 8) | (s[2] << 16));
            out.rgba[i * 4 + 0] = static_cast<uint8_t>((px & rm) >> shiftOf(rm));
            out.rgba[i * 4 + 1] = static_cast<uint8_t>((px & gm) >> shiftOf(gm));
            out.rgba[i * 4 + 2] = static_cast<uint8_t>((px & bm) >> shiftOf(bm));
            out.rgba[i * 4 + 3] = am ? static_cast<uint8_t>((px & am) >> shiftOf(am)) : 255;
        }
        return true;
    }
    if (info.format == "L8") {
        if (avail < count) return fail("truncated");
        for (size_t i = 0; i < count; ++i) {
            out.rgba[i * 4] = out.rgba[i * 4 + 1] = out.rgba[i * 4 + 2] = p[i];
            out.rgba[i * 4 + 3] = 255;
        }
        return true;
    }
    if (info.format == "RGB16") {
        if (avail < count * 2) return fail("truncated");
        auto chan = [](uint32_t px, uint32_t m, uint8_t def) -> uint8_t {
            if (!m) return def;
            const int b = bitsOf(m);
            return static_cast<uint8_t>(((px & m) >> shiftOf(m)) * 255u / ((1u << b) - 1u));
        };
        for (size_t i = 0; i < count; ++i) {
            const uint32_t px = static_cast<uint32_t>(p[i * 2] | (p[i * 2 + 1] << 8));
            out.rgba[i * 4] = chan(px, rm, 0);
            out.rgba[i * 4 + 1] = chan(px, gm, 0);
            out.rgba[i * 4 + 2] = chan(px, bm, 0);
            out.rgba[i * 4 + 3] = chan(px, am, 255);
        }
        return true;
    }
    return fail("unsupported DDS format");
}

Image resize(const Image& s, int w, int h) {
    Image o;
    o.width = w;
    o.height = h;
    o.rgba.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
    if (s.width <= 0 || s.height <= 0 || w <= 0 || h <= 0) return o;
    for (int y = 0; y < h; ++y) {
        const int y0 = y * s.height / h, y1 = std::max(y0 + 1, (y + 1) * s.height / h);
        for (int x = 0; x < w; ++x) {
            const int x0 = x * s.width / w, x1 = std::max(x0 + 1, (x + 1) * s.width / w);
            unsigned sum[4] = {};
            unsigned cnt = 0;
            for (int yy = y0; yy < y1; ++yy)
                for (int xx = x0; xx < x1; ++xx) {
                    const uint8_t* p = &s.rgba[(static_cast<size_t>(yy) * static_cast<size_t>(s.width) + static_cast<size_t>(xx)) * 4];
                    for (int k = 0; k < 4; ++k) sum[k] += p[k];
                    ++cnt;
                }
            for (int k = 0; k < 4; ++k)
                o.rgba[(static_cast<size_t>(y) * static_cast<size_t>(w) + static_cast<size_t>(x)) * 4 + static_cast<size_t>(k)] =
                    static_cast<uint8_t>((sum[k] + cnt / 2) / cnt);
        }
    }
    return o;
}

namespace {

uint16_t pack565(const uint8_t* c) {
    return static_cast<uint16_t>(((c[0] >> 3) << 11) | ((c[1] >> 2) << 5) | (c[2] >> 3));
}

// one 4x4 colour block (8 bytes) from 16 RGBA pixels: range fit between the two most distant colours
void encodeColour(const uint8_t px[16][4], uint8_t* out) {
    int hi = 0, lo = 0, best = -1;
    for (int i = 0; i < 16; ++i)
        for (int j = i + 1; j < 16; ++j) {
            const int d = (px[i][0] - px[j][0]) * (px[i][0] - px[j][0]) + (px[i][1] - px[j][1]) * (px[i][1] - px[j][1]) +
                          (px[i][2] - px[j][2]) * (px[i][2] - px[j][2]);
            if (d > best) { best = d; hi = i; lo = j; }
        }
    uint16_t c0 = pack565(px[hi]), c1 = pack565(px[lo]);
    if (c0 < c1) { std::swap(c0, c1); std::swap(hi, lo); }
    uint8_t col[4][3];
    for (int k = 0; k < 3; ++k) {
        col[0][k] = px[hi][k];
        col[1][k] = px[lo][k];
        col[2][k] = static_cast<uint8_t>((2 * col[0][k] + col[1][k]) / 3);
        col[3][k] = static_cast<uint8_t>((col[0][k] + 2 * col[1][k]) / 3);
    }
    uint32_t bits = 0;
    if (c0 != c1) {
        for (int i = 0; i < 16; ++i) {
            int bi = 0, bd = 1 << 30;
            for (int k = 0; k < 4; ++k) {
                const int d = (px[i][0] - col[k][0]) * (px[i][0] - col[k][0]) + (px[i][1] - col[k][1]) * (px[i][1] - col[k][1]) +
                              (px[i][2] - col[k][2]) * (px[i][2] - col[k][2]);
                if (d < bd) { bd = d; bi = k; }
            }
            bits |= static_cast<uint32_t>(bi) << (2 * i);
        }
    }
    out[0] = static_cast<uint8_t>(c0 & 255);
    out[1] = static_cast<uint8_t>(c0 >> 8);
    out[2] = static_cast<uint8_t>(c1 & 255);
    out[3] = static_cast<uint8_t>(c1 >> 8);
    wr32(out + 4, bits);
}

void encodeAlpha5(const uint8_t px[16][4], uint8_t* out) {
    int a0 = 0, a1 = 255;
    for (int i = 0; i < 16; ++i) {
        a0 = std::max<int>(a0, px[i][3]);
        a1 = std::min<int>(a1, px[i][3]);
    }
    out[0] = static_cast<uint8_t>(a0);
    out[1] = static_cast<uint8_t>(a1);
    uint64_t bits = 0;
    if (a0 != a1) {
        int lv[8] = {a0, a1};
        for (int i = 1; i < 7; ++i) lv[i + 1] = ((7 - i) * a0 + i * a1) / 7;
        for (int i = 0; i < 16; ++i) {
            int bi = 0, bd = 1 << 30;
            for (int k = 0; k < 8; ++k) {
                const int d = std::abs(lv[k] - px[i][3]);
                if (d < bd) { bd = d; bi = k; }
            }
            bits |= static_cast<uint64_t>(bi) << (3 * i);
        }
    }
    for (int i = 0; i < 6; ++i) out[2 + i] = static_cast<uint8_t>((bits >> (8 * i)) & 255);
}

void writeHeader(std::vector<uint8_t>& o, int w, int h, int mips, DdsFormat f) {
    o.assign(128, 0);
    memcpy(o.data(), "DDS ", 4);
    wr32(&o[4], 124);
    uint32_t flags = 0x1 | 0x2 | 0x4 | 0x1000 | (f == DdsFormat::ARGB8 ? 0x8u : 0x80000u);
    if (mips > 1) flags |= 0x20000;
    wr32(&o[8], flags);
    wr32(&o[12], static_cast<uint32_t>(h));
    wr32(&o[16], static_cast<uint32_t>(w));
    const uint32_t blocks = static_cast<uint32_t>(((w + 3) / 4) * ((h + 3) / 4));
    wr32(&o[20], f == DdsFormat::ARGB8 ? static_cast<uint32_t>(w) * 4 : blocks * (f == DdsFormat::DXT1 ? 8u : 16u));
    wr32(&o[28], static_cast<uint32_t>(mips));
    wr32(&o[76], 32);
    if (f == DdsFormat::ARGB8) {
        wr32(&o[80], 0x41);
        wr32(&o[88], 32);
        wr32(&o[92], 0x00FF0000);
        wr32(&o[96], 0x0000FF00);
        wr32(&o[100], 0x000000FF);
        wr32(&o[104], 0xFF000000);
    } else {
        wr32(&o[80], 4);
        memcpy(&o[84], f == DdsFormat::DXT1 ? "DXT1" : "DXT5", 4);
    }
    wr32(&o[108], 0x1000u | (mips > 1 ? 0x400008u : 0u));
}

void encodeLevel(const Image& im, DdsFormat f, std::vector<uint8_t>& o) {
    const int w = im.width, h = im.height;
    if (f == DdsFormat::ARGB8) {
        for (size_t i = 0; i < static_cast<size_t>(w) * static_cast<size_t>(h); ++i) {
            o.push_back(im.rgba[i * 4 + 2]);
            o.push_back(im.rgba[i * 4 + 1]);
            o.push_back(im.rgba[i * 4 + 0]);
            o.push_back(im.rgba[i * 4 + 3]);
        }
        return;
    }
    for (int by = 0; by < (h + 3) / 4; ++by)
        for (int bx = 0; bx < (w + 3) / 4; ++bx) {
            uint8_t px[16][4];
            for (int i = 0; i < 16; ++i) {
                const int x = std::min(bx * 4 + (i & 3), w - 1), y = std::min(by * 4 + (i >> 2), h - 1);
                memcpy(px[i], &im.rgba[(static_cast<size_t>(y) * static_cast<size_t>(w) + static_cast<size_t>(x)) * 4], 4);
            }
            uint8_t blk[16];
            if (f == DdsFormat::DXT5) {
                encodeAlpha5(px, blk);
                encodeColour(px, blk + 8);
                o.insert(o.end(), blk, blk + 16);
            } else {
                encodeColour(px, blk);
                o.insert(o.end(), blk, blk + 8);
            }
        }
}

}  // namespace

bool ddsEncode(const Image& img, DdsFormat f, bool mips, std::vector<uint8_t>& out) {
    if (img.width <= 0 || img.height <= 0 ||
        img.rgba.size() != static_cast<size_t>(img.width) * static_cast<size_t>(img.height) * 4)
        return false;
    int levels = 1;
    if (mips) {
        int w = img.width, h = img.height;
        while (w > 1 || h > 1) {
            w = std::max(1, w / 2);
            h = std::max(1, h / 2);
            ++levels;
        }
    }
    writeHeader(out, img.width, img.height, levels, f);
    Image cur = img;
    for (int l = 0; l < levels; ++l) {
        encodeLevel(cur, f, out);
        if (l + 1 < levels) cur = resize(cur, std::max(1, cur.width / 2), std::max(1, cur.height / 2));
    }
    return true;
}

}  // namespace ed
