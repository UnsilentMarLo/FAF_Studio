// Test driver for edraster.h (built and called by run_tests.py; not part of the DLL).
// stdin:  N, then N jobs:  "J <dx> <sy>", commands "M x y" | "L x y" | "C x1 y1 x2 y2 x3 y3" | "Q x1 y1 x2 y2" | "Z", then "E".
// stdout: per job "R <left> <top> <w> <h>" followed by h lines of w space-separated coverage values (0..255); "R 0 0 0 0" when nothing is covered.
#include <cstdio>
#include <iostream>
#include <string>
#include "../edraster.h"

int main() {
    int n = 0;
    std::cin >> n;
    for (int j = 0; j < n; j++) {
        std::string tok;
        float dx = 0, sy = 1;
        std::cin >> tok >> dx >> sy;                 // "J"
        edr::Rasteriser r;
        while (std::cin >> tok && tok != "E") {
            float a, b, c, d, e, f;
            if (tok == "M") { std::cin >> a >> b; r.moveTo(a, b); }
            else if (tok == "L") { std::cin >> a >> b; r.lineTo(a, b); }
            else if (tok == "C") { std::cin >> a >> b >> c >> d >> e >> f; r.cubicTo(a, b, c, d, e, f); }
            else if (tok == "Q") { std::cin >> a >> b >> c >> d; r.quadTo(a, b, c, d); }
            else if (tok == "Z") r.close();
        }
        edr::Bitmap bm;
        if (!r.render(dx, sy, bm)) { std::printf("R 0 0 0 0\n"); continue; }
        std::printf("R %d %d %d %d\n", bm.left, bm.top, bm.w, bm.h);
        for (int y = 0; y < bm.h; y++) {
            for (int x = 0; x < bm.w; x++) std::printf("%d%c", bm.a[(size_t)y * bm.w + x], x + 1 < bm.w ? ' ' : '\n');
        }
    }
    return 0;
}
