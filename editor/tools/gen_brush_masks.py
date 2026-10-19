#!/usr/bin/env python3
"""Writes the image brush masks that ship with the editor into editor/runtime/brushes (16-bit greyscale PNG, 128 x 128).

    python editor/tools/gen_brush_masks.py

The editor lists every greyscale image in /brushes (and in the brush folders of mods) in its Shapes panel; white = full brush strength,
black = none. Add your own the same way.
"""
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "runtime", "brushes")
N = 128


def smooth(a, b, x):
    # 0 at x = a, 1 at x = b; a may be larger than b (it then falls as x grows)
    t = (x - a) / (b - a)
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def vnoise(x, z, seed=0):
    def h(ix, iz):
        n = (ix * 374761393 + iz * 668265263 + seed * 1442695041) & 0xFFFFFFFF
        n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
        return (n & 0xFFFF) / 65535.0

    ix, iz = math.floor(x), math.floor(z)
    fx, fz = x - ix, z - iz
    fx, fz = fx * fx * (3 - 2 * fx), fz * fz * (3 - 2 * fz)
    a, b, c, d = h(ix, iz), h(ix + 1, iz), h(ix, iz + 1), h(ix + 1, iz + 1)
    return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fz


def fractal(x, z, seed=0):
    return 0.5 * vnoise(x * 2, z * 2, seed) + 0.3 * vnoise(x * 4, z * 4, seed + 1) + 0.2 * vnoise(x * 8, z * 8, seed + 2)


def crater(u, v):
    d = math.hypot(u, v)
    rim = smooth(0.35, 0.72, d) * smooth(1.0, 0.8, d)
    bowl = 0.25 * smooth(0.5, 0.0, d)
    return min(1.0, rim + bowl)


def volcano(u, v):
    d = math.hypot(u, v)
    slope = smooth(1.0, 0.15, d)
    mouth = 1.0 - 0.45 * smooth(0.18, 0.0, d)
    return slope * mouth * (0.85 + 0.3 * fractal(u * 1.5 + 5, v * 1.5 + 5))


def canyon(u, v):
    wob = 0.18 * math.sin(u * 3.0) + 0.1 * math.sin(u * 7.0 + 1.0)
    w = abs(v - wob)
    return smooth(0.45, 0.05, w) * smooth(1.0, 0.8, abs(u))


def dunes(u, v):
    d = math.hypot(u, v)
    wave = 0.5 + 0.5 * math.sin((u * 6.0 + 2.0 * fractal(u, v) * 3.0))
    return wave * smooth(1.0, 0.7, d)


def ridgeline(u, v):
    d = math.hypot(u, v)
    r = 1.0 - abs(2.0 * fractal(u * 1.2 + 9, v * 1.2 + 4, 7) - 1.0)
    return min(1.0, max(0.0, r * r)) * smooth(1.0, 0.55, d)


MASKS = {"crater": crater, "volcano": volcano, "canyon": canyon, "dunes": dunes, "ridgeline": ridgeline}


def write_png16(path, rows):
    h, w = len(rows), len(rows[0])
    raw = b"".join(b"\x00" + struct.pack(">%dH" % w, *row) for row in rows)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 16, 0, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in MASKS.items():
        rows = []
        for j in range(N):
            v = (j + 0.5) / N * 2 - 1
            row = []
            for i in range(N):
                u = (i + 0.5) / N * 2 - 1
                value = max(0.0, min(1.0, fn(u, v)))
                row.append(int(round(value * 65535)))
            rows.append(row)
        path = os.path.join(OUT, name + ".png")
        write_png16(path, rows)
        print("wrote", path)


if __name__ == "__main__":
    main()
