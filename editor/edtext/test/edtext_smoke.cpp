// Smoke test of edtext.dll through its C ABI (cross-compiled with mingw and run under Wine, or built with MSVC on Windows).
//   edtext_smoke.exe <edtext.dll> <family> <px> <text>
// Prints, per glyph of the text and per phase 0..3 with raster returning 1:  "G <index> <phase> <left> <top> <w> <h>" then h rows of w gray values (R == G == B is checked).
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "../edtext.h"

typedef EdFont* (*FnCreate)(const wchar_t*, float);
typedef int (*FnLayout)(EdFont*, const wchar_t*, int, EdGlyph*, int, float*);
typedef int (*FnRaster)(EdFont*, uint32_t, uint32_t, int, int*, int*, int*, int*, uint8_t*, int);

int main(int argc, char** argv) {
    if (argc < 5) { std::fprintf(stderr, "usage: edtext_smoke <dll> <family> <px> <text>\n"); return 2; }
    HMODULE m = LoadLibraryA(argv[1]);
    if (!m) { std::fprintf(stderr, "LoadLibrary failed (%lu)\n", GetLastError()); return 3; }
    auto create = (FnCreate)GetProcAddress(m, "edt_font_create");
    auto layout = (FnLayout)GetProcAddress(m, "edt_layout");
    auto raster = (FnRaster)GetProcAddress(m, "edt_raster");
    if (!create || !layout || !raster) { std::fprintf(stderr, "exports missing\n"); return 3; }
    std::wstring family(argv[2], argv[2] + std::strlen(argv[2])), text(argv[4], argv[4] + std::strlen(argv[4]));
    EdFont* f = create(family.c_str(), (float)std::atof(argv[3]));
    if (!f) { std::fprintf(stderr, "edt_font_create failed\n"); return 4; }
    EdGlyph g[256]; float width = 0;
    int n = layout(f, text.c_str(), (int)text.size(), g, 256, &width);
    std::printf("N %d width %.3f\n", n, width);
    std::vector<uint8_t> buf(64 * 64 * 3);
    int bad = 0;
    for (int i = 0; i < n; i++) {
        for (int ph = 0; ph < 4; ph++) {
            int l, t, w, h;
            int ok = raster(f, g[i].face, g[i].glyph, ph, &l, &t, &w, &h, buf.data(), (int)buf.size());
            if (!ok) { std::printf("E %d %d\n", i, ph); continue; }
            std::printf("G %d %d %d %d %d %d\n", i, ph, l, t, w, h);
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    const uint8_t* p = &buf[((size_t)y * w + x) * 3];
                    if (p[0] != p[1] || p[1] != p[2]) bad++;
                    std::printf("%d%c", p[0], x + 1 < w ? ' ' : '\n');
                }
            }
        }
    }
    std::printf("NONGRAY %d\n", bad);
    return 0;
}
