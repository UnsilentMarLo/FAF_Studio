#!/usr/bin/env python
"""Draws the FAF Studio icon (no third-party packages): a dark rounded tile, layered terrain ridges in the editor's cyan with topographic contour lines, and an orange start-position marker.
Writes editor/runtime/branding/fafstudio.ico (PNG-compressed images of 16 / 24 / 32 / 48 / 64 / 128 / 256 px) and fafstudio_256.png (preview).

    python scripts/make_editor_icon.py
"""
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), 'editor', 'runtime', 'branding')
SIZES = (16, 24, 32, 48, 64, 128, 256)

BG_TOP, BG_BOTTOM = (0x2c, 0x31, 0x39), (0x14, 0x16, 0x19)
CYAN = (0x3f, 0xb7, 0xd4)
MARKER = (0xff, 0x87, 0x3e)

# skylines: (x, y) in 0..1, y down; the ridge is the area below the line
BACK = [(0.0, 0.50), (0.18, 0.40), (0.34, 0.47), (0.52, 0.30), (0.70, 0.45), (0.86, 0.36), (1.0, 0.46)]
MID = [(0.0, 0.62), (0.15, 0.55), (0.30, 0.60), (0.46, 0.46), (0.60, 0.58), (0.78, 0.50), (1.0, 0.62)]
FRONT = [(0.0, 0.78), (0.20, 0.70), (0.38, 0.76), (0.56, 0.62), (0.74, 0.74), (0.90, 0.68), (1.0, 0.76)]


def skyline(points, x):
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x0 <= x <= x1:
            t = (x - x0) / (x1 - x0) if x1 > x0 else 0.0
            return y0 + (y1 - y0) * t
    return points[-1][1]


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def rounded_alpha(x, y, r=0.22):
    """Coverage of the rounded tile at a point (hard edge; supersampling smooths it)."""
    cx = min(max(x, r), 1 - r)
    cy = min(max(y, r), 1 - r)
    return 1.0 if (x - cx) ** 2 + (y - cy) ** 2 <= r * r else 0.0


def shade(x, y):
    """RGBA (0..255 floats) of the icon at a point of the unit square."""
    a = rounded_alpha(x, y)
    if a == 0.0:
        return (0, 0, 0, 0.0)
    col = mix(BG_TOP, BG_BOTTOM, y)
    # a faint sky glow behind the ridges
    glow = max(0.0, 1.0 - math.hypot(x - 0.72, y - 0.22) / 0.45)
    col = mix(col, (0x3f, 0x6b, 0x80), glow * 0.35)
    for points, base, depth in ((BACK, (0x24, 0x48, 0x5a), 0.0), (MID, (0x2c, 0x78, 0x90), 0.0), (FRONT, CYAN, 0.0)):
        top = skyline(points, x)
        if y >= top:
            d = y - top
            col = mix(base, (base[0] * 0.55, base[1] * 0.55, base[2] * 0.55), min(1.0, d / 0.35))
            if points is FRONT:
                # topographic contour lines parallel to the ridge
                k = d / 0.065
                if abs(k - round(k)) * 0.065 < 0.0085 and d > 0.01:
                    col = mix(col, (0xd6, 0xf3, 0xfb), 0.75)
            elif points is MID:
                k = d / 0.08
                if abs(k - round(k)) * 0.08 < 0.007 and d > 0.01:
                    col = mix(col, (0x9f, 0xdc, 0xec), 0.45)
    # start position marker: ring and dot, upper right
    mr = math.hypot(x - 0.74, y - 0.24)
    if mr < 0.055:
        col = MARKER
    elif 0.075 < mr < 0.105:
        col = mix(col, MARKER, 0.95)
    # tile border
    edge = min(x, y, 1 - x, 1 - y)
    # distance to the rounded boundary
    r = 0.22
    cx = min(max(x, r), 1 - r)
    cy = min(max(y, r), 1 - r)
    dist = r - math.hypot(x - cx, y - cy)
    if dist < 0.035:
        col = mix(col, CYAN, 0.85)
    return (col[0], col[1], col[2], 255.0)


def render(size, ss=4):
    rows = []
    n = size * ss
    for py in range(size):
        row = bytearray()
        for px in range(size):
            r = g = b = a = 0.0
            for sy in range(ss):
                for sx in range(ss):
                    cr, cg, cb, ca = shade((px * ss + sx + 0.5) / n, (py * ss + sy + 0.5) / n)
                    r += cr * ca
                    g += cg * ca
                    b += cb * ca
                    a += ca
            if a > 0:
                row += bytes((int(r / a + 0.5), int(g / a + 0.5), int(b / a + 0.5), int(a / (ss * ss) + 0.5)))
            else:
                row += bytes((0, 0, 0, 0))
        rows.append(bytes(row))
    return rows


def png(rows, size):
    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)
    raw = b''.join(b'\x00' + r for r in rows)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')


def main():
    os.makedirs(OUT, exist_ok=True)
    images = []
    for s in SIZES:
        rows = render(s, 6 if s <= 48 else 4)
        images.append((s, png(rows, s)))
        if s == 256:
            open(os.path.join(OUT, 'fafstudio_256.png'), 'wb').write(images[-1][1])
    header = struct.pack('<HHH', 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b''
    blob = b''
    for s, data in images:
        entries += struct.pack('<BBBBHHII', s % 256, s % 256, 0, 0, 1, 32, len(data), offset + len(blob))
        blob += data
    open(os.path.join(OUT, 'fafstudio.ico'), 'wb').write(header + entries + blob)
    print('wrote', os.path.join(OUT, 'fafstudio.ico'), [s for s, _ in images])


if __name__ == '__main__':
    main()
