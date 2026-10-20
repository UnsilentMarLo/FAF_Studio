#!/usr/bin/env python3
"""Checks the built edtext.dll through its C ABI (edtext_smoke.exe): the DirectWrite glue around edraster.h.

    python editor/edtext/test/compare_dll.py <edtext.dll> <edtext_smoke.exe> [runner]          e.g. runner = /usr/lib/wine/wine64 on Linux, none on Windows
    family 'Liberation Sans' (or set EDT_FAMILY) must be in the system font collection.

edraster.h itself is validated bit-for-bit against exact area by run_tests.py. Here the DLL is checked for what that cannot see:
  gray        every output pixel has R == G == B
  lut         EDTEXT_GAMMA is applied exactly (same bitmap, two gamma values)
  geometry    origin and orientation: the bitmap lies where the host rasteriser puts the same glyph (top row within one row, ink within 30 %: Wine's outlines are hinted, so no pixel match)
  phase       a quarter-pixel phase moves the glyph a quarter pixel (mean centroid step)
  snap x      EDTEXT_SNAPX=1 maps the four phases to two whole-pixel positions (same bitmap, left + 1 for phases 2 and 3)
  old path    EDTEXT_RASTER=dwrite still renders (the previous method, for A/B)
  bad env     garbage in EDTEXT_GAMMA is ignored
"""
import os, subprocess, sys
import numpy as np
from fontTools.ttLib import TTFont
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_tests as T

dll, exe = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
runner = sys.argv[3].split() if len(sys.argv) > 3 else []
fam = os.environ.get('EDT_FAMILY', 'Liberation Sans')
px = 12
cli = T.build()
font = TTFont(T.find_font('quad'))


def run(text, env_extra=None):
    env = dict(os.environ, **(env_extra or {}))
    r = subprocess.run(runner + [exe, dll, fam, str(px), text], capture_output=True, text=True, env=env, cwd=os.path.dirname(dll))
    if r.returncode != 0:
        raise SystemExit(f'smoke exe failed ({r.returncode}): {r.stdout[-400:]} {r.stderr[-400:]}')
    glyphs, nongray, it = {}, 0, iter(r.stdout.split('\n'))
    for line in it:
        if line.startswith('G '):
            _, i, ph, l, t, w, h = line.split(); i, ph, l, t, w, h = map(int, (i, ph, l, t, w, h))
            glyphs[(i, ph)] = (l, t, w, h, np.array([list(map(int, next(it).split())) for _ in range(h)], float))
        elif line.startswith('NONGRAY'):
            nongray = int(line.split()[1])
    return glyphs, nongray


results = []
def check(name, ok, detail):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}"); results.append(ok)

text = 'Radiusgxl'
base, ng0 = run(text, {'EDTEXT_YSNAP': '0', 'EDTEXT_GAMMA': '1.0'})
check('gray', ng0 == 0 and len(base) > 0, f'{len(base)} bitmaps, {ng0} pixels with R, G, B not equal')

g72, _ = run(text, {'EDTEXT_YSNAP': '0', 'EDTEXT_GAMMA': '0.72'})
lut = np.round(255 * (np.arange(256) / 255) ** 0.72)
worst = 0.0
for k, (l, t, w, h, a) in base.items():
    worst = max(worst, np.abs(lut[a.astype(int)] - g72[k][4]).max()) if g72[k][:4] == (l, t, w, h) else 999
check('lut', worst <= 1, f'gamma 0.72 vs 1.0 on identical bitmaps: worst difference {worst:.0f}/255')

bad = []
for (i, ph), (l, t, w, h, a) in base.items():
    ch = text[i]
    cmds = T.glyph_cmds(font, ch, px)
    (hl, ht, hw, hh, ha), = T.run_cli(cli, [(ph / 4, 1.0, cmds)])
    ink_d, ink_h = a.sum() / 255, ha.sum() / 255
    if abs(t - ht) > 1 or abs(t + h - (ht + hh)) > 1 or abs(l - hl) > 1 or abs(ink_d - ink_h) > 0.3 * ink_h:
        bad.append(f'{ch!r} ph{ph}: dll {(l, t, w, h)} ink {ink_d:.1f}, host {(hl, ht, hw, hh)} ink {ink_h:.1f}')
check('geometry', not bad, f'{len(base)} bitmaps vs host rasteriser' + ('' if not bad else '; ' + '; '.join(bad[:4])))

cent = []
for ch_idx in (0, 8):                 # 'R' and 'l'
    c = []
    for ph in range(4):
        l, t, w, h, a = base[(ch_idx, ph)]
        c.append((a.sum(0) * (np.arange(w) + l + 0.5)).sum() / a.sum())
    cent += list(np.diff(c))
check('phase', abs(np.mean(cent) - 0.25) < 0.06, f'centroid step per phase: mean {np.mean(cent):.3f} (target 0.25; hinted outlines under Wine are not exact), steps {[round(x, 2) for x in cent]}')

snap, _ = run(text, {'EDTEXT_GAMMA': '1.0'})
changed = sum(1 for k in base if base[k][:4] != snap[k][:4] or not np.array_equal(base[k][4], snap[k][4]))
check('y snap', True, f'{changed} of {len(base)} bitmaps change with the x-height snap on (informational: depends on the font size and font)')

sx, _ = run(text, {'EDTEXT_YSNAP': '0', 'EDTEXT_GAMMA': '1.0', 'EDTEXT_SNAPX': '1'})
bad = []
for i in range(len(text)):
    if (i, 0) not in sx: continue
    l0, t0, w0, h0, a0 = sx[(i, 0)]
    for ph in (1, 2, 3):
        l, t, w, h, a = sx[(i, ph)]
        want_l = l0 + (1 if ph >= 2 else 0)
        if (l, t, w, h) != (want_l, t0, w0, h0) or not np.array_equal(a, a0): bad.append((text[i], ph))
check('snap x', not bad and len(sx) > 0, f'EDTEXT_SNAPX=1: phases 1 equals 0, phases 2 and 3 equal 0 shifted one pixel right' + ('' if not bad else f'; wrong: {bad[:4]}'))

old, ngo = run(text, {'EDTEXT_RASTER': 'dwrite'})
check('old path', len(old) > 0 and ngo == 0, f'EDTEXT_RASTER=dwrite: {len(old)} bitmaps, {ngo} non-gray pixels')

junk, ngj = run(text, {'EDTEXT_YSNAP': '0', 'EDTEXT_GAMMA': 'abc'})
ref72 = g72
check('bad env', all(np.array_equal(junk[k][4], ref72[k][4]) for k in ref72), 'GAMMA=abc falls back to 0.72')

print('ALL PASS' if all(results) else 'FAILURES')
sys.exit(0 if all(results) else 1)
