#!/usr/bin/env python3
"""Renders the thumbnails of the lighting presets and strata themes: the same test scene (editor/runtime/lua/editor/envscene.lua) in a throw-away editor instance, once per look / theme.

    python editor/tools/gen_env_thumbs.py [--tag envthumbs] [--only looks|themes] [--first N --last M]

Needs a running-capable engine (scripts/editor_inst.py). Writes DXT1 pictures to editor/runtime/override/textures/editor/envthumbs/<look|theme>_<id>.dds (96 x 60 for looks, 64 x 64 for themes), which
lua/editor/envlib.lua Thumb() finds. Run again after gen_env_library.py changed the libraries.
"""
import argparse
import os
import struct
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "editor", "runtime", "override", "textures", "editor", "envthumbs")
INST = os.path.join(ROOT, "scripts", "editor_inst.py")


# ---- png in, dds out (no imaging library needed) ------------------------------------------------------------------------------------------------

def read_png(path):
    d = open(path, "rb").read()
    pos, idat, w, h, ct = 8, b"", 0, 0, 0
    while pos < len(d):
        n, t = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        pos += 12 + n
        if t == b"IHDR":
            w, h, _bd, ct = struct.unpack(">IIBB", body[:10])
        elif t == b"IDAT":
            idat += body
    raw = zlib.decompress(idat)
    bpp = {2: 3, 6: 4}[ct]
    stride = w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _y in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


def crop_resize(png, box, size):
    """Box-filter resize of the part `box` = (x0, y0, x1, y1) of the picture to size = (w, h): rows of (r, g, b) tuples."""
    w, h, bpp, rows = png
    x0, y0, x1, y1 = box
    tw, th = size
    out = []
    for ty in range(th):
        ya, yb = y0 + (y1 - y0) * ty / th, y0 + (y1 - y0) * (ty + 1) / th
        row = []
        for tx in range(tw):
            xa, xb = x0 + (x1 - x0) * tx / tw, x0 + (x1 - x0) * (tx + 1) / tw
            r = g = b = n = 0
            for yy in range(int(ya), max(int(ya) + 1, int(yb))):
                line = rows[min(h - 1, yy)]
                for xx in range(int(xa), max(int(xa) + 1, int(xb))):
                    k = min(w - 1, xx) * bpp
                    r += line[k]
                    g += line[k + 1]
                    b += line[k + 2]
                    n += 1
            row.append((r // n, g // n, b // n))
        out.append(row)
    return out


def rgb565(c):
    return ((c[0] >> 3) << 11) | ((c[1] >> 2) << 5) | (c[2] >> 3)


def from565(v):
    r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


def dxt1(pixels, w, h):
    blocks = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            px = [pixels[min(h - 1, by + j)][min(w - 1, bx + i)] for j in range(4) for i in range(4)]
            lo = tuple(min(p[k] for p in px) for k in range(3))
            hi = tuple(max(p[k] for p in px) for k in range(3))
            c0, c1 = rgb565(hi), rgb565(lo)
            if c0 < c1:
                c0, c1 = c1, c0
            if c0 == c1:
                blocks += struct.pack("<HHI", c0, c1, 0)
                continue
            a, b = from565(c0), from565(c1)
            pal = [a, b, tuple((2 * a[k] + b[k]) // 3 for k in range(3)), tuple((a[k] + 2 * b[k]) // 3 for k in range(3))]
            bits = 0
            for i, p in enumerate(px):
                best = min(range(4), key=lambda q: sum((p[k] - pal[q][k]) ** 2 for k in range(3)))
                bits |= best << (2 * i)
            blocks += struct.pack("<HHI", c0, c1, bits)
    return bytes(blocks)


def write_dds(path, pixels, w, h):
    header = b"DDS " + struct.pack("<7I", 124, 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000, h, w, ((w + 3) // 4) * ((h + 3) // 4) * 8, 0, 1)
    header += b"\0" * 44 + struct.pack("<2I4s5I", 32, 0x4, b"DXT1", 0, 0, 0, 0, 0) + struct.pack("<5I", 0x1000, 0, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(header + dxt1(pixels, w, h))


# ---- driving the editor -------------------------------------------------------------------------------------------------------------------------

def inst(*args, check=True):
    r = subprocess.run([sys.executable, INST] + list(args), capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit("editor_inst failed: " + " ".join(args) + "\n" + r.stdout + r.stderr)
    return r.stdout


def lua(tag, text, scratch):
    path = os.path.join(scratch, "thumb_cmd.lua")
    open(path, "w").write(text)
    out = inst("cmd", tag, path, "--chars", "400")
    for line in out.splitlines():
        if line.startswith("OK:"):
            return line[3:].strip()
        if line.startswith("ERROR"):
            raise SystemExit("editor error: " + out)
    return out.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="envthumbs")
    ap.add_argument("--exe", default="main_x64_la_p2.exe")
    ap.add_argument("--only", choices=("looks", "themes"))
    ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--last", type=int, default=100000)
    ap.add_argument("--delay", type=float, default=0.9)
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    scratch = os.path.join(os.environ.get("TEMP", "."), "envthumbs_scratch")
    os.makedirs(scratch, exist_ok=True)
    editor = os.path.join(ROOT, "editor", "runtime")
    inst("new", a.tag, "--editor", editor, check=False)
    inst("start", a.tag, "--exe", a.exe)
    try:
        info = lua(a.tag, "local S = import('/lua/editor/envscene.lua')\nlocal r = S.Setup()\nlocal l, t = S.Counts()\nreturn r.x .. ' ' .. r.y .. ' ' .. r.w .. ' ' .. r.h .. ' ' .. l .. ' ' .. t", scratch)
        nums = [int(x) for x in info.split()]
        x, y, w, h, nl, nt = nums
        print("viewport", x, y, w, h, "looks", nl, "themes", nt)
        shot = os.path.join(scratch, "thumb.png")
        jobs = []
        if a.only != "themes":
            jobs += [("look", i) for i in range(max(1, a.first), min(nl, a.last) + 1)]
        if a.only != "looks":
            jobs += [("theme", i) for i in range(max(1, a.first), min(nt, a.last) + 1)]
        for kind, i in jobs:
            call = "Look" if kind == "look" else "Theme"
            out = lua(a.tag, "local id, name = import('/lua/editor/envscene.lua').%s(%d)\nreturn tostring(id) .. '|' .. tostring(name)" % (call, i), scratch)
            ident = out.split("|")[0].strip()
            time.sleep(a.delay)
            inst("shot", a.tag, shot)
            png = read_png(shot)
            if kind == "look":
                box = (x, y + int(h * 0.12), x + w, y + int(h * 0.12) + int(w / 1.6))
                size = (96, 60)
            else:
                side = min(w, h)
                box = (x + (w - side) // 2, y, x + (w - side) // 2 + side, y + side)
                size = (64, 64)
            pixels = crop_resize(png, box, size)
            write_dds(os.path.join(OUT, "%s_%s.dds" % (kind, ident)), pixels, size[0], size[1])
            print(kind, i, ident)
    finally:
        inst("stop", a.tag, check=False)


if __name__ == "__main__":
    main()
