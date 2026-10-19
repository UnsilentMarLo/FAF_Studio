#!/usr/bin/env python3
"""Draws the editor's marker icons (32 x 32 uncompressed ARGB DDS) into editor/runtime/override/textures/editor/markers/.

One icon per marker type of the game's MarkerTemplates: a badge whose silhouette tells the family (diamond = resource, square =
area, shield = defence, circle = path node ...), the template colour as fill and a white glyph inside. Plus `army` (spawn) and
`default` (marker types added by mods). Pure Python, no dependencies.

    python editor/tools/gen_marker_icons.py

The slug list lives in editor/runtime/lua/editor/overlay.lua (ICON_SLUGS): keep both in sync.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_cursors import line, ring, disc, poly, box_outline, dds  # noqa: E402  (drawing primitives and the DDS writer)

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "editor", "runtime", "override", "textures", "editor", "markers")
SIZE = 32
SS = 4

DARK = (24, 28, 34)
WHITE = (255, 255, 255)


# ---- badge silhouettes --------------------------------------------------------------------------------------------------------------

def circle():
    return disc(16, 16, 12)


def square():
    return poly([(5, 5), (27, 5), (27, 27), (5, 27)])


def diamond():
    return poly([(16, 2.5), (29.5, 16), (16, 29.5), (2.5, 16)])


def hexagon():
    pts = [(16 + 13 * math.cos(math.radians(60 * i + 30)), 16 + 13 * math.sin(math.radians(60 * i + 30))) for i in range(6)]
    return poly(pts)


def shield():
    return poly([(6, 4.5), (26, 4.5), (26, 16), (16, 28.5), (6, 16)])


def triangle():
    return poly([(16, 3.5), (29.5, 27.5), (2.5, 27.5)])


def octagon():
    pts = [(16 + 13.5 * math.cos(math.radians(45 * i + 22.5)), 16 + 13.5 * math.sin(math.radians(45 * i + 22.5))) for i in range(8)]
    return poly(pts)


# ---- glyphs (centred near 16, 16) --------------------------------------------------------------------------------------------------

def g_plus(t=3.0):
    return [line(16, 9, 16, 23, t), line(9, 16, 23, 16, t)]


def g_cross():
    return [line(10, 10, 22, 22, 3.0), line(22, 10, 10, 22, 3.0)]


def g_ring():
    return [ring(16, 16, 6, 2.6)]


def g_dot():
    return [disc(16, 16, 3.6)]


def g_flag():
    return [line(11.5, 8, 11.5, 24, 2.4), poly([(11.5, 8), (23, 12), (11.5, 16)])]


def g_wave(y=19):
    pts = [(8, y), (11, y - 3), (14, y), (17, y + 3), (20, y), (23, y - 3)]
    return [line(*pts[i], *pts[i + 1], 2.0) for i in range(len(pts) - 1)]


def g_flame():
    return [poly([(16, 6.5), (22, 17), (19, 17), (19, 24), (13, 24), (13, 17), (10, 17)])]


def g_burst():
    parts = []
    for ang in range(0, 180, 45):
        a = math.radians(ang)
        parts.append(line(16 - math.cos(a) * 8, 16 - math.sin(a) * 8, 16 + math.cos(a) * 8, 16 + math.sin(a) * 8, 2.2))
    return parts


def g_cloud():
    return [disc(12, 17, 4), disc(17.5, 14.5, 5.2), disc(21.5, 18, 3.6), poly([(11, 18), (23, 18), (23, 21.5), (11, 21.5)])]


def g_camera():
    return [poly([(8, 11.5), (24, 11.5), (24, 23), (8, 23)]), poly([(12, 8.5), (16, 8.5), (17, 11.5), (11, 11.5)])]


def g_lens():
    return [ring(16, 17.2, 3.4, 1.8)]


def g_arrow():
    return [line(7.5, 16, 20, 16, 3.0), poly([(24.5, 16), (18, 10.5), (18, 21.5)])]


def g_anchor():
    return [ring(16, 9.5, 2.3, 2.0), line(16, 12, 16, 23, 2.4), line(11, 15.5, 21, 15.5, 2.2),
            line(9.5, 19.5, 16, 24, 2.2), line(22.5, 19.5, 16, 24, 2.2)]


def g_slash():
    return [ring(16, 16, 7.5, 2.4), line(10.5, 21.5, 21.5, 10.5, 2.6)]


def g_mountains():
    return [poly([(8, 23), (14, 12), (20, 23)]), poly([(14, 23), (20.5, 14), (26, 23)])]


def g_link():
    return [disc(9.5, 22.5, 3.2), disc(22.5, 9.5, 3.2), line(9.5, 22.5, 22.5, 9.5, 2.4)]


def g_wings():
    return [line(7.5, 11.5, 16, 21, 3.0), line(24.5, 11.5, 16, 21, 3.0)]


def g_two_dots():
    return [disc(10.5, 16, 3.2), disc(21.5, 16, 3.2)]


def g_square():
    return [box_outline(10, 10, 22, 22, 2.8)]


def g_star():
    pts = []
    for i in range(10):
        r = 9.5 if i % 2 == 0 else 4.0
        a = math.radians(-90 + 36 * i)
        pts.append((16 + r * math.cos(a), 16.5 + r * math.sin(a)))
    return [poly(pts)]


def g_pin():
    return [poly([(11.5, 14), (20.5, 14), (16, 25)]), disc(16, 12, 5.5)]


def g_diamond_small():
    return [poly([(16, 9), (23, 16), (16, 23), (9, 16)])]


# ---- type table: slug -> (name, template colour, badge, glyph layers) -------------------------------------------------------------------

def spec():
    return {
        'blank_marker': ('ff800080', circle, g_ring()),
        'mass': ('ff808080', diamond, g_diamond_small()),
        'hydrocarbon': ('ff008000', hexagon, g_flame()),
        'combat_zone': ('ff800000', octagon, g_cross()),
        'defensive_point': ('ff008000', shield, g_dot()),
        'effect': ('ffbffcd0', circle, g_burst()),
        'expansion_area': ('ff008080', square, g_plus(3.0)),
        'large_expansion_area': ('ffff0080', square, g_plus(4.6)),
        'naval_area': ('ff0000FF', square, g_anchor()),
        'naval_defensive_point': ('ff0080FF', shield, g_wave(17)),
        'naval_rally_point': ('ff00FFFF', circle, g_flag() + g_wave(25)),
        'protected_experimental_construction': ('ff0000AA', shield, g_star()),
        'rally_point': ('FF808000', circle, g_flag()),
        'island': ('ff0000AA', circle, g_mountains()),
        'naval_exclude': ('ff0000AA', circle, g_slash()),
        'weather_definition': ('FF808000', circle, g_cloud()),
        'weather_generator': ('FF808000', circle, g_cloud() + [line(16, 21.5, 16, 26, 2.4)]),
        'camera_info': ('ff808000', square, g_camera()),
        'transport_marker': ('ff80A088', circle, g_arrow()),
        'naval_link': ('ffff0000', circle, g_link()),
        'land_path_node': ('ff00ff00', circle, g_square()),
        'water_path_node': ('ff0000ff', circle, g_wave(16)),
        'air_path_node': ('ffffffff', circle, g_wings()),
        'amphibious_path_node': ('ff00ffff', circle, g_two_dots()),
        'army': ('ffd02020', diamond, g_star()),
        'default': ('ff808080', circle, g_pin()),
    }


def parse(argb):
    h = argb[-6:]
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def brighten(rgb):
    r, g, b = rgb
    # template colours are dark game colours: lift them so the badge reads on grass and rock
    r, g, b = (c + (255 - c) * 0.30 for c in (r, g, b))
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    if lum < 95:
        k = 95 / max(lum, 1)
        r, g, b = min(255, r * k + 20), min(255, g * k + 20), min(255, b * k + 20)
    return int(r), int(g), int(b)


def render(layers):
    out = bytearray()
    n = SS * SS
    for py in range(SIZE):
        for px in range(SIZE):
            covered = 0
            sr = sg = sb = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = px + (sx + 0.5) / SS
                    y = py + (sy + 0.5) / SS
                    col = None
                    for fn, rgb, grow in layers:
                        if fn(x, y, grow):
                            col = rgb
                    if col:
                        covered += 1
                        sr += col[0]
                        sg += col[1]
                        sb += col[2]
            if covered == 0:
                out += bytes((0, 0, 0, 0))
            else:
                out += bytes((sb // covered, sg // covered, sr // covered, min(255, covered * 255 // n)))
    return bytes(out)


def union(shapes):
    return lambda x, y, g: any(s(x, y, g) for s in shapes)


def build(slug, argb, badge, glyph):
    fill = brighten(parse(argb))
    lum = 0.299 * fill[0] + 0.587 * fill[1] + 0.114 * fill[2]
    glyph_rgb = DARK if lum > 170 else WHITE
    b = badge()
    layers = [(b, DARK, 1.9), (b, WHITE, 1.0), (b, fill, 0.0)]
    if glyph:
        layers.append((union(glyph), glyph_rgb, 0.0))
    return layers


def rings():
    """Selection and hover rings drawn under a marker icon (the leading '_' sorts them first, so they are drawn first)."""
    sel = ring(16, 16, 13.2, 3.4)
    hov = ring(16, 16, 13.6, 2.0)
    return {
        '_select': [(sel, DARK, 1.6), (sel, (255, 224, 64), 0.0)],
        '_hover': [(hov, DARK, 1.4), (hov, WHITE, 0.0)],
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    for slug, layers in rings().items():
        with open(os.path.join(OUT, slug + '.dds'), 'wb') as fh:
            fh.write(dds(render(layers)))
    for slug, (argb, badge, glyph) in spec().items():
        path = os.path.join(OUT, slug + '.dds')
        with open(path, 'wb') as fh:
            fh.write(dds(render(build(slug, argb, badge, glyph))))
    print('wrote', len(spec()), 'icons to', os.path.relpath(OUT, ROOT))
    print(' '.join(spec().keys()))


if __name__ == '__main__':
    main()
