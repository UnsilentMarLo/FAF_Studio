#!/usr/bin/env python3
"""Draws the editor's mouse cursors (32 x 32 uncompressed ARGB DDS, white glyph with a dark outline) into
editor/runtime/override/textures/editor/cursors/.  Pure Python, no dependencies.

    python editor/tools/gen_cursors.py

Hotspots live in editor/runtime/lua/editor/cursors.lua (keep both in sync).
"""
import math
import os
import struct

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "editor", "runtime", "override", "textures", "editor", "cursors")
SIZE = 32
SS = 4          # supersampling per axis
OUTLINE = 1.1   # outline width in pixels


# ---- primitives: f(x, y, grow) -> inside? (grow widens the shape by `grow` pixels on every side, for the outline) ----------------

def line(x0, y0, x1, y1, t):
    def f(x, y, g):
        dx, dy = x1 - x0, y1 - y0
        l2 = dx * dx + dy * dy
        u = 0.0 if l2 == 0 else max(0.0, min(1.0, ((x - x0) * dx + (y - y0) * dy) / l2))
        d = math.hypot(x - (x0 + u * dx), y - (y0 + u * dy))
        return d <= t / 2 + g
    return f


def ring(cx, cy, r, t):
    def f(x, y, g):
        return abs(math.hypot(x - cx, y - cy) - r) <= t / 2 + g
    return f


def disc(cx, cy, r):
    def f(x, y, g):
        return math.hypot(x - cx, y - cy) <= r + g
    return f


def poly(points):
    def inside(x, y):
        c = False
        j = len(points) - 1
        for i in range(len(points)):
            xi, yi = points[i]
            xj, yj = points[j]
            if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                c = not c
            j = i
        return c

    def f(x, y, g):
        if inside(x, y):
            return True
        if g <= 0:
            return False
        for i in range(len(points)):   # grown: distance to any edge
            x0, y0 = points[i]
            x1, y1 = points[(i + 1) % len(points)]
            dx, dy = x1 - x0, y1 - y0
            l2 = dx * dx + dy * dy
            u = 0.0 if l2 == 0 else max(0.0, min(1.0, ((x - x0) * dx + (y - y0) * dy) / l2))
            if math.hypot(x - (x0 + u * dx), y - (y0 + u * dy)) <= g:
                return True
        return False
    return f


def box_outline(x0, y0, x1, y1, t, dash=0):
    parts = [line(x0, y0, x1, y0, t), line(x1, y0, x1, y1, t), line(x1, y1, x0, y1, t), line(x0, y1, x0, y0, t)]
    return lambda x, y, g: any(p(x, y, g) for p in parts)


def arrow(cx, cy, angle, length=6.0, head=3.2, t=1.6):
    """A short arrow from the centre outward at `angle` degrees."""
    a = math.radians(angle)
    ex, ey = cx + math.cos(a) * length, cy + math.sin(a) * length
    bx, by = cx + math.cos(a) * (length - head), cy + math.sin(a) * (length - head)
    nx, ny = -math.sin(a) * head * 0.9, math.cos(a) * head * 0.9
    return [line(cx, cy, bx, by, t), poly([(ex, ey), (bx + nx, by + ny), (bx - nx, by - ny)])]


# ---- cursors ---------------------------------------------------------------------------------------------------------------------

def crosshair(cx, cy, r=7.0, gap=2.5, t=1.4, with_ring=True):
    parts = [line(cx - r - 3, cy, cx - gap, cy, t), line(cx + gap, cy, cx + r + 3, cy, t),
             line(cx, cy - r - 3, cx, cy - gap, t), line(cx, cy + gap, cx, cy + r + 3, t)]
    if with_ring:
        parts.append(ring(cx, cy, r, t))
    return parts


def brush(symbol):
    parts = crosshair(14, 14)
    sx, sy = 25, 25
    if symbol == '+':
        parts += [line(sx - 3, sy, sx + 3, sy, 1.6), line(sx, sy - 3, sx, sy + 3, 1.6)]
    elif symbol == '-':
        parts += [line(sx - 3, sy, sx + 3, sy, 1.6)]
    elif symbol == '=':
        parts += [line(sx - 3, sy - 1.6, sx + 3, sy - 1.6, 1.4), line(sx - 3, sy + 1.6, sx + 3, sy + 1.6, 1.4)]
    elif symbol == '~':
        pts = [(sx - 4, sy + 1), (sx - 2, sy - 1.5), (sx, sy), (sx + 2, sy + 1.5), (sx + 4, sy - 1)]
        parts += [line(*pts[i], *pts[i + 1], 1.4) for i in range(len(pts) - 1)]
    elif symbol == '.':
        parts += [disc(sx - 3, sy - 2, 1.2), disc(sx + 2, sy - 3, 1.2), disc(sx, sy + 2, 1.2), disc(sx + 4, sy + 3, 1.2)]
    return parts


def marker_pin():
    # teardrop: head circle at (16, 11), point at (16, 29)
    parts = [poly([(10.5, 14), (21.5, 14), (16, 29)]), disc(16, 11, 6.5)]
    return parts


def area_cursor():
    parts = crosshair(12, 12, r=5, gap=2, t=1.4, with_ring=False)
    parts += [box_outline(17, 17, 29, 27, 1.5)]
    return parts


def move_cross():
    parts = []
    for ang in (0, 90, 180, 270):
        parts += arrow(16, 16, ang, length=11, head=4.5, t=1.8)
    return parts


def size(angle):
    parts = []
    for a in (angle, angle + 180):
        parts += arrow(16, 16, a, length=11, head=4.5, t=1.8)
    return parts


def pointer():
    return [poly([(3, 2), (3, 22), (8, 17.5), (11.5, 25), (14.5, 23.5), (11, 16.5), (17.5, 16.5)])]


CURSORS = {
    # id: (shapes, hotspot x, hotspot y)
    'brush_raise': (brush('+'), 14, 14),
    'brush_lower': (brush('-'), 14, 14),
    'brush_flatten': (brush('='), 14, 14),
    'brush_smooth': (brush('~'), 14, 14),
    'brush_noise': (brush('.'), 14, 14),
    'marker': (marker_pin(), 16, 29),
    'area': (area_cursor(), 12, 12),
    'select': (pointer(), 3, 2),
    'move': (move_cross(), 16, 16),
    'size_ew': (size(0), 16, 16),
    'size_ns': (size(90), 16, 16),
    'size_nwse': (size(45), 16, 16),
    'size_nesw': (size(135), 16, 16),
}


def render(shapes):
    """BGRA bytes of a SIZE x SIZE image: white glyph, dark outline, antialiased by supersampling."""
    out = bytearray()
    for py in range(SIZE):
        for px in range(SIZE):
            fill = 0
            edge = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = px + (sx + 0.5) / SS
                    y = py + (sy + 0.5) / SS
                    if any(s(x, y, 0.0) for s in shapes):
                        fill += 1
                    elif any(s(x, y, OUTLINE) for s in shapes):
                        edge += 1
            n = SS * SS
            a_fill = fill / n
            a_edge = edge / n
            alpha = a_fill + a_edge * 0.9 * (1 - a_fill)
            if alpha <= 0:
                out += bytes((0, 0, 0, 0))
                continue
            # white over dark: premixed colour by coverage
            lum = (255 * a_fill) / alpha
            out += bytes((int(lum), int(lum), int(lum), int(min(255, alpha * 255))))
    return bytes(out)


def dds(bgra):
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x8   # caps, height, width, pixelformat, pitch
    header = b'DDS ' + struct.pack('<7I', 124, flags, SIZE, SIZE, SIZE * 4, 0, 1) + b'\0' * 44
    header += struct.pack('<8I', 32, 0x41, 0, 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    header += struct.pack('<5I', 0x1000, 0, 0, 0, 0)
    assert len(header) == 128, len(header)
    return header + bgra


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (shapes, _hx, _hy) in CURSORS.items():
        path = os.path.join(OUT, name + '.dds')
        with open(path, 'wb') as fh:
            fh.write(dds(render(shapes)))
        print('wrote', os.path.relpath(path, ROOT))


if __name__ == '__main__':
    main()
