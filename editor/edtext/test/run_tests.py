#!/usr/bin/env python3
"""Validation of edraster.h (the grayscale glyph rasteriser behind edt_raster) on any machine with g++ and Python. No Windows, no DirectWrite.

    python editor/edtext/test/run_tests.py [--quick] [--images OUTDIR]

Needs: g++, numpy, Pillow, fontTools, shapely (pip install numpy pillow fonttools shapely). Fonts: the first of Liberation Sans / DejaVu Sans / Inter found on the system.

What is checked
  1. exact       coverage of real glyph outlines (TrueType quadratics and CFF cubics, 11-24 px, four sub-pixel phases) against exact polygon-area coverage computed with shapely
  2. random      random polygons (steep, shallow, many-pixel edges) against the same exact reference
  3. freetype    glyph coverage against FreeType rendering at 16x size reduced by a 16x16 box filter (independent rasteriser; FreeType hints a little, so the tolerance is wider)
  4. phase       a quarter-pixel phase moves the glyph by a quarter pixel (centroid)
  5. sanitizers  the driver rebuilt with -fsanitize=address,undefined runs the glyph set without a report
  6. xheight     XHeightSnapScale puts the x-height on a whole pixel row (reported, not a pass / fail)
Exit code 0 = all pass.
"""
import argparse, glob, math, os, random, subprocess, sys, tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from fontTools.pens.basePen import BasePen
from fontTools.ttLib import TTFont
from shapely import make_valid
from shapely.geometry import Polygon, box

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_CANDIDATES = {
    'quad': ['/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'],
    'cubic': ['/usr/share/fonts/opentype/inter/Inter-Regular.otf'],
}
TEXT = "RadiusgQ8&@%tfeykzwWmjS$ABCEHaorsn"


def find_font(kind):
    for p in FONT_CANDIDATES[kind]:
        if os.path.exists(p):
            return p
    return None


class Rec(BasePen):
    """Glyph outline as ('M'|'L'|'C'|'Z', coords) with quadratics raised to cubics, in pixels, y down (what DirectWrite hands the sink)."""
    def __init__(self, gs, scale):
        super().__init__(gs)
        self.s, self.cmds, self.cur = scale, [], (0, 0)

    def _pt(self, p):
        return (p[0] * self.s, -p[1] * self.s)

    def _moveTo(self, p):
        self.cur = self._pt(p); self.cmds.append(('M', [self.cur]))

    def _lineTo(self, p):
        self.cur = self._pt(p); self.cmds.append(('L', [self.cur]))

    def _curveToOne(self, a, b, c):
        a, b, c = self._pt(a), self._pt(b), self._pt(c)
        self.cmds.append(('C', [a, b, c])); self.cur = c

    def _qCurveToOne(self, q, p):
        q, p = self._pt(q), self._pt(p)
        c0 = self.cur
        a = (c0[0] + 2 / 3 * (q[0] - c0[0]), c0[1] + 2 / 3 * (q[1] - c0[1]))
        b = (p[0] + 2 / 3 * (q[0] - p[0]), p[1] + 2 / 3 * (q[1] - p[1]))
        self.cmds.append(('C', [a, b, p])); self.cur = p

    def _closePath(self):
        self.cmds.append(('Z', []))

    def _endPath(self):
        self.cmds.append(('Z', []))


def glyph_cmds(font, ch, px):
    cmap = font.getBestCmap()
    if ord(ch) not in cmap:
        return None
    name = cmap[ord(ch)]
    gs = font.getGlyphSet()
    rec = Rec(gs, px / font['head'].unitsPerEm)
    gs[name].draw(rec)
    return rec.cmds if rec.cmds else None


def cmds_text(cmds):
    out = []
    for op, pts in cmds:
        out.append(op + ' ' + ' '.join(f'{v:.6f}' for p in pts for v in p) if pts else op)
    return '\n'.join(out)


def flatten(cmds, steps=200):
    """Contours as point lists (high resolution flattening, independent of the C++ flattener)."""
    contours, cur, last = [], None, None
    for op, pts in cmds:
        if op == 'M':
            if cur and len(cur) > 2: contours.append(cur)
            cur = [pts[0]]; last = pts[0]
        elif op == 'L':
            cur.append(pts[0]); last = pts[0]
        elif op == 'C':
            p0, (p1, p2, p3) = last, pts
            for i in range(1, steps + 1):
                t = i / steps; u = 1 - t
                cur.append((u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
                            u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]))
            last = p3
        elif op == 'Z':
            if cur and len(cur) > 2: contours.append(cur)
            cur = None
    if cur and len(cur) > 2: contours.append(cur)
    return contours


def exact_coverage(contours, dx, sy, left, top, w, h):
    """Per-pixel exact area coverage (0..255 floats) with the same signed-sum / clamp model the rasteriser uses."""
    polys = []
    for c in contours:
        pts = [(x + dx, y * sy) for x, y in c]
        area = 0.5 * sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
        if area == 0: continue
        poly = Polygon(pts)
        if not poly.is_valid: poly = make_valid(poly)
        polys.append((1.0 if area > 0 else -1.0, poly))
    cov = np.zeros((h, w))
    for y in range(h):
        for x in range(w):
            b = box(left + x, top + y, left + x + 1, top + y + 1)
            s = 0.0
            for sign, poly in polys:
                if poly.bounds[2] < b.bounds[0] or poly.bounds[0] > b.bounds[2] or poly.bounds[3] < b.bounds[1] or poly.bounds[1] > b.bounds[3]: continue
                s += sign * poly.intersection(b).area
            cov[y, x] = min(1.0, abs(s)) * 255.0
    return cov


def run_cli(cli, jobs):
    """jobs: [(dx, sy, cmds)] -> [(left, top, w, h, ndarray)]"""
    lines = [str(len(jobs))]
    for dx, sy, cmds in jobs:
        lines.append(f'J {dx} {sy}'); lines.append(cmds_text(cmds)); lines.append('E')
    res = subprocess.run([cli], input='\n'.join(lines) + '\n', capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f'driver failed ({res.returncode}): {res.stderr[:2000]}')
    it = iter(res.stdout.split('\n'))
    out = []
    for _ in jobs:
        hdr = next(it).split()
        l, t, w, h = map(int, hdr[1:5])
        arr = np.array([list(map(int, next(it).split())) for _ in range(h)], dtype=float).reshape(h, w) if w and h else np.zeros((0, 0))
        out.append((l, t, w, h, arr))
    return out


def build(sanitize=False):
    exe = os.path.join(tempfile.gettempdir(), 'edraster_cli_san' if sanitize else 'edraster_cli')
    cmd = ['g++', '-std=c++17', '-O1' if sanitize else '-O2', '-Wall', '-Wextra', '-Werror', '-o', exe, os.path.join(HERE, 'edraster_cli.cpp')]
    if sanitize: cmd[3:3] = ['-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr); sys.exit(2)
    return exe


def report(name, ok, detail):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}")
    return ok


def test_exact(cli, kinds, quick):
    allok, worst, total, n = True, 0.0, 0.0, 0
    sizes = (12, 24) if quick else (11, 12, 14, 24)
    text = TEXT[:14] if quick else TEXT
    for kind in kinds:
        path = find_font(kind)
        if not path: print(f'  (skip {kind}: no font)'); continue
        font = TTFont(path)
        jobs, meta = [], []
        for px in sizes:
            for ch in text:
                cmds = glyph_cmds(font, ch, px)
                if not cmds: continue
                for ph in range(4):
                    jobs.append((ph / 4, 1.0, cmds)); meta.append((px, ch, ph, cmds))
        results = run_cli(cli, jobs)
        for (dx, sy, cmds), (px, ch, ph, _), (l, t, w, h, arr) in zip(jobs, meta, results):
            if w == 0: continue
            ref = exact_coverage(flatten(cmds), dx, sy, l, t, w, h)
            err = np.abs(arr - ref)
            worst = max(worst, err.max()); total += err.mean(); n += 1
            if err.max() > 3.5:
                allok = False
                print(f'    {os.path.basename(path)} {px}px {ch!r} phase {ph}: max error {err.max():.1f}')
    return report('exact area (glyph outlines)', allok and worst <= 3.5, f'{n} glyph renders, worst pixel error {worst:.2f}/255, mean error {total / max(1, n):.3f}/255')


def test_random(cli, quick):
    rnd = random.Random(7)
    jobs, polys = [], []
    for i in range(60 if quick else 250):
        k = rnd.randint(3, 9)
        cx, cy, rad = rnd.uniform(4, 12), rnd.uniform(4, 12), rnd.uniform(1.0, 7.0)
        ang = sorted(rnd.uniform(0, 2 * math.pi) for _ in range(k))
        stretch = rnd.choice((1, 1, 3))                                   # one stretch for the whole polygon: it stays star-shaped (simple)
        pts = [(cx + rad * (r := rnd.uniform(0.3, 1.0)) * math.cos(a) * stretch, cy + rad * r * math.sin(a)) for a in ang]
        if abs(sum(pts[j][0] * pts[(j + 1) % k][1] - pts[(j + 1) % k][0] * pts[j][1] for j in range(k))) < 1e-3: continue
        if not Polygon(pts).is_valid: continue                        # a self-intersecting polygon has no single right coverage (the model is non-zero winding, simple outlines)
        cmds = [('M', [pts[0]])] + [('L', [p]) for p in pts[1:]] + [('Z', [])]
        jobs.append((rnd.choice((0, .25, .5, .75)), 1.0, cmds))
    results = run_cli(cli, jobs)
    worst, bad = 0.0, 0
    for (dx, sy, cmds), (l, t, w, h, arr) in zip(jobs, results):
        if w == 0: continue
        pts = [p[0] for op, p in cmds if op in 'ML']
        ref = exact_coverage([pts], dx, sy, l, t, w, h)
        e = np.abs(arr - ref).max(); worst = max(worst, e)
        if e > 2.5: bad += 1
    return report('exact area (random polygons)', bad == 0, f'{len(jobs)} polygons, worst pixel error {worst:.2f}/255, {bad} over 2.5')


def test_freetype(cli, quick):
    path = find_font('quad')
    if not path: return True
    font = TTFont(path)
    worst, worst_mean, n = 0.0, 0.0, 0
    for px in (12, 14, 24):
        S = 16
        pil = ImageFont.truetype(path, px * S)
        for ch in "RadiusgQ8&e":
            cmds = glyph_cmds(font, ch, px)
            if not cmds: continue
            for ph in (0, 2):
                (l, t, w, h, arr), = run_cli(cli, [(ph / 4, 1.0, cmds)])
                W, H = 64, 64
                ox, oy = 16, 40                                     # glyph origin on the canvas (pixels)
                big = Image.new('L', (W * S, H * S), 0)
                ImageDraw.Draw(big).text((ox * S + ph * S // 4, oy * S), ch, font=pil, fill=255, anchor='ls')
                ref = np.asarray(big.reduce(S), dtype=float)
                mine = np.zeros((H, W))
                mine[oy + t: oy + t + h, ox + l: ox + l + w] = arr
                err = np.abs(mine - ref)
                worst = max(worst, err.max()); worst_mean = max(worst_mean, err.mean()); n += 1
    ok = worst <= 40 and worst_mean <= 1.0
    return report('freetype 16x reference', ok, f'{n} renders, worst pixel {worst:.0f}/255 (FreeType hints at 192 px: up to ~40 allowed), worst per-glyph mean {worst_mean:.2f}/255')


def test_phase(cli):
    path = find_font('quad')
    if not path: return True
    font = TTFont(path)
    ok, steps = True, []
    for ch in 'lIiH':
        cmds = glyph_cmds(font, ch, 12)
        cents = []
        for ph in range(5):
            (l, t, w, h, arr), = run_cli(cli, [(ph / 4, 1.0, cmds)])
            xs = (np.arange(w) + l + 0.5)
            cents.append((arr.sum(0) * xs).sum() / arr.sum())
        steps.append(np.diff(cents))
    s = np.concatenate(steps)
    # one pixel-centre centroid of a 1 px stem is quantised (that is why the text lab used a run of 'i'); the mean over many steps must be exact
    ok = abs(s.mean() - 0.25) < 0.005 and np.all(np.abs(s - 0.25) < 0.12)
    return report('sub-pixel phase', ok, f'centroid step per quarter pixel: mean {s.mean():.4f}, min {s.min():.3f}, max {s.max():.3f} (target 0.250)')


def test_sanitizers(quick):
    exe = build(sanitize=True)
    font = TTFont(find_font('quad'))
    jobs = []
    for px in (6, 12, 18, 40):
        for ch in TEXT:
            cmds = glyph_cmds(font, ch, px)
            if cmds:
                for ph in range(4): jobs.append((ph / 4, 1.0, cmds))
    degenerate = [('M', [(1, 1)]), ('L', [(1, 1)]), ('Z', [])]
    jobs += [(0, 1.0, degenerate), (0, 1.0, [('M', [(0, 0)]), ('L', [(3, 0)]), ('L', [(6, 0)]), ('Z', [])]),
             (.5, .94, [('M', [(0, 0)]), ('L', [(1e-6, 5)]), ('L', [(2e-6, 0)]), ('Z', [])]),
             (0, 1.0, [('M', [(-3.2, -4.9)]), ('C', [(50, 40), (-50, 40), (7.5, -4.9)]), ('Z', [])])]
    try:
        run_cli(exe, jobs)
        return report('sanitizers (asan + ubsan)', True, f'{len(jobs)} outlines incl. degenerate and cusp cases, no report')
    except RuntimeError as e:
        return report('sanitizers (asan + ubsan)', False, str(e)[:600])


def xheight_report(cli):
    path = find_font('quad')
    if not path: return
    font = TTFont(path)
    xh = font['OS/2'].sxHeight / font['head'].unitsPerEm
    for px in (11, 12, 13, 14):
        xhp = xh * px
        sc = 1.0
        # mirrors edr::XHeightSnapScale
        if 3 <= xhp <= 14:
            sc = max(0.94, min(1.06, round(xhp) / xhp))
        cmds = glyph_cmds(font, 'z', px)
        (l, t, w, h, a0), = run_cli(cli, [(0, 1.0, cmds)])
        (l1, t1, w1, h1, a1), = run_cli(cli, [(0, sc, cmds)])
        print(f'  x-height at {px}px: {xhp:.2f} px, snap scale {sc:.3f}; top row of z: max coverage {a0[0].max():.0f} -> {a1[0].max():.0f}, '
              f'rows touched {h} -> {h1}')


def render_line(cli, font, text, px, snap, gamma=0.72):
    """Renders one text line with 4 sub-pixel phases the way the engine backend does; returns coverage array and baseline row."""
    s = px / font['head'].unitsPerEm
    hm = font['hmtx'].metrics
    cmap = font.getBestCmap()
    xh = font['OS/2'].sxHeight * s
    sy = max(0.94, min(1.06, round(xh) / xh)) if snap and 3 <= xh <= 14 else 1.0
    pen, glyphs = 2.0, []
    for ch in text:
        name = cmap.get(ord(ch))
        if name is None: continue
        cmds = glyph_cmds(font, ch, px)
        if cmds:
            ip = math.floor(pen); ph = int((pen - ip) * 4)
            glyphs.append((ip, ph, cmds))
        pen += hm[name][0] * s
    res = run_cli(cli, [(ph / 4, sy, c) for _, ph, c in glyphs])
    H, W, base = int(px * 1.6) + 2, int(pen) + 6, int(px * 1.15)
    cov = np.zeros((H, W))
    for (ip, ph, _), (l, t, w, h, arr) in zip(glyphs, res):
        y0, x0 = base + t, ip + l
        cov[y0:y0 + h, x0:x0 + w] = np.maximum(cov[y0:y0 + h, x0:x0 + w], arr)
    lut = 255 * (np.arange(256) / 255) ** gamma
    return lut[np.clip(np.round(cov).astype(int), 0, 255)]


def old_pipeline_gray(cli, font, text, px, gamma=0.72):
    """Approximation of the previous path: ClearType 3x1 texture (3 samples per pixel, 5-tap FIR 1-2-3-2-1) averaged (R + 2G + B) / 4, then the same gamma."""
    path = find_font('quad')
    S = 48                                                               # render scale: 3 horizontal samples per pixel, 16 sub-samples each
    pil = ImageFont.truetype(path, px * S)
    s = px / font['head'].unitsPerEm
    hm = font['hmtx'].metrics; cmap = font.getBestCmap()
    W, H, base = 400, int(px * 1.6) + 2, int(px * 1.15)
    big = Image.new('L', (W * S, H * S), 0)
    d = ImageDraw.Draw(big)
    pen = 2.0
    for ch in text:
        name = cmap.get(ord(ch))
        if name is None: continue
        ip = math.floor(pen); ph = int((pen - ip) * 4)
        d.text(((ip + ph / 4) * S, base * S), ch, font=pil, fill=255, anchor='ls')
        pen += hm[name][0] * s
    cov = np.asarray(big.reduce((S // 3, S)), dtype=float)               # (H, W*3): one value per sub-pixel
    k = np.array([1, 2, 3, 2, 1]) / 9.0
    f = np.apply_along_axis(lambda r: np.convolve(r, k, mode='same'), 1, cov)
    sub = f.reshape(H, W, 3)                                             # R, G, B sub-pixels
    g = (sub[:, :, 0] + 2 * sub[:, :, 1] + sub[:, :, 2]) / 4.0
    lut = 255 * (np.arange(256) / 255) ** gamma
    out = lut[np.clip(np.round(g).astype(int), 0, 255)]
    return out[:, :int(pen) + 6]


def images(cli, outdir):
    os.makedirs(outdir, exist_ok=True)
    path = find_font('quad')
    font = TTFont(path)
    txt = 'Radius  Strength % (Shift inverts)  Mask generator  edge0 value'
    fg, bg = np.array([214, 220, 225], float), np.array([30, 33, 37], float)
    rows = []
    for px in (11, 12, 14):
        variants = [('old (approx.)', old_pipeline_gray(cli, font, txt, px)), ('new, exact', render_line(cli, font, txt, px, snap=False)),
                    ('new + x-height snap', render_line(cli, font, txt, px, snap=True))]
        W = max(v.shape[1] for _, v in variants)
        for label, v in variants:
            v = np.pad(v, ((0, 0), (0, W - v.shape[1])))
            rgb = bg + (fg - bg) * (v[..., None] / 255.0)
            rows.append(rgb.astype(np.uint8))
    maxw = max(r.shape[1] for r in rows)
    sheet = np.concatenate([np.pad(r, ((0, 3), (0, maxw - r.shape[1]), (0, 0)), constant_values=0) for r in rows], 0)
    img = Image.fromarray(sheet).resize((sheet.shape[1] * 5, sheet.shape[0] * 5), Image.NEAREST)
    p = os.path.join(outdir, 'text_compare_5x.png')
    img.save(p)
    print('  wrote', p, '(rows per size: old approximation, new exact, new + x-height snap; 11, 12, 14 px)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--quick', action='store_true')
    ap.add_argument('--images', metavar='DIR')
    args = ap.parse_args()
    cli = build()
    kinds = [k for k in ('quad', 'cubic') if find_font(k)]
    if not kinds: print('no test fonts found'); return 2
    oks = [test_exact(cli, kinds, args.quick), test_random(cli, args.quick), test_freetype(cli, args.quick), test_phase(cli), test_sanitizers(args.quick)]
    xheight_report(cli)
    if args.images: images(cli, args.images)
    print('ALL PASS' if all(oks) else 'FAILURES')
    return 0 if all(oks) else 1


if __name__ == '__main__':
    sys.exit(main())
