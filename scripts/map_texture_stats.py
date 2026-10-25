#!/usr/bin/env python
"""Reads every .scmap of a maps folder (scripts/pylib/scmap.py) and writes, per map, what the author painted: the textures of the strata layers, how much each layer covers
and on WHICH ground it lies (slope, height above the land median, height above the surroundings), plus the lighting and water colours. Pure Python, no third-party modules.

    python scripts/map_texture_stats.py [--maps DIR] [--out FILE] [--jobs N] [--limit N]

Default maps folder: <Documents>/My Games/Gas Powered Games/Supreme Commander Forged Alliance/Maps. Default output: .runs/maptex/maps.json (a list of records).
scripts/map_texture_presets.py reads that file and writes the texture sets / recipe styles (editor/runtime/lua/editor/mapsets.lua).

Record: { name, size, shader, minor, water = elevation or null, hmin, hmax, hmed (land median), slope = { mean, p5, p20, p30 },
          light = { multiplier, sun, ambience, shadow, fog, bloom, spec }, wcolor,
          layers = [ { layer 0..9, albedo, scale, normal, cover (mean weight), slope, h (height percentile 0..1 of the land), rel (height above surroundings, units), crisp (share of the cells that are not in transition), peak (share of the cells at full weight),
                     bys (mean weight per slope bin, SLOPE_EDGES), byh (per height decile) } ] }
Layer 0 is the base (weight = what the painted layers leave), 1..8 are the mask channels (R, G, B, A of the low mask, then of the high mask), 9 the upper layer (macrotexture; no mask).
"""
import argparse
import json
import math
import multiprocessing
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'pylib'))
sys.path.insert(0, HERE)
from scmap import ScMap  # noqa: E402
import studio_paths as SP  # noqa: E402

SLOPE_EDGES = (0, 3, 6, 10, 15, 20, 30, 45)     # lower edges of the slope bins (degrees); the last bin is open
GRID = 128          # the analysis grid: at most GRID x GRID samples per map


def default_maps():
    return os.path.join(os.path.expanduser('~'), 'Documents', 'My Games', 'Gas Powered Games', 'Supreme Commander Forged Alliance', 'Maps')


def mask_channels(blob):
    """-> (width, height, [4 bytearrays]) of an uncompressed ARGB DDS (channel order R, G, B, A = strata 1..4 / 5..8), or None."""
    if blob is None or len(blob) < 128 or blob[:4] != b'DDS ':
        return None
    h, w = struct.unpack_from('<II', blob, 12)
    fourcc = blob[84:88]
    if fourcc != b'\0\0\0\0' or len(blob) < 128 + w * h * 4:
        return None
    px = blob[128:128 + w * h * 4]
    return w, h, [bytearray(px[2::4]), bytearray(px[1::4]), bytearray(px[0::4]), bytearray(px[3::4])]


def percentile(sorted_vals, q):
    if not sorted_vals:
        return 0.0
    i = min(len(sorted_vals) - 1, max(0, int(q * (len(sorted_vals) - 1))))
    return sorted_vals[i]


def analyse(path):
    m = ScMap.read(path)
    W, H = m.width, m.height
    n = max(8, min(GRID, W // 2, H // 2))
    sx, sz = W / float(n), H / float(n)
    stride = W + 1
    hs, sc = m.heights, m.height_scale

    def hgt(ix, iz):
        ix = 0 if ix < 0 else (W if ix > W else ix)
        iz = 0 if iz < 0 else (H if iz > H else iz)
        return hs[iz * stride + ix] * sc

    # heights, slope and relief on the grid
    hv = [0.0] * (n * n)
    sl = [0.0] * (n * n)
    for j in range(n):
        iz = int((j + 0.5) * sz)
        for i in range(n):
            ix = int((i + 0.5) * sx)
            h = hgt(ix, iz)
            hv[j * n + i] = h
            gx = (hgt(ix + 1, iz) - hgt(ix - 1, iz)) * 0.5
            gz = (hgt(ix, iz + 1) - hgt(ix, iz - 1)) * 0.5
            sl[j * n + i] = math.degrees(math.atan(math.sqrt(gx * gx + gz * gz)))
    water = m.water['elevation'] if m.water.get('present') else None
    land = sorted(h for h in hv if water is None or h > water)
    if not land:
        land = sorted(hv)
    hmed = percentile(land, 0.5)
    lo, hi = percentile(land, 0.02), percentile(land, 0.98)
    # relief: height above the mean of a box of ~ 1/12 of the map (the surroundings)
    r = max(2, n // 12)
    pre = [[0.0] * (n + 1) for _ in range(n + 1)]
    for j in range(n):
        row = 0.0
        for i in range(n):
            row += hv[j * n + i]
            pre[j + 1][i + 1] = pre[j][i + 1] + row

    def boxmean(i, j):
        i0, i1, j0, j1 = max(0, i - r), min(n, i + r + 1), max(0, j - r), min(n, j + r + 1)
        s = pre[j1][i1] - pre[j0][i1] - pre[j1][i0] + pre[j0][i0]
        return s / float((i1 - i0) * (j1 - j0))

    rel = [hv[j * n + i] - boxmean(i, j) for j in range(n) for i in range(n)]
    ssl = sorted(sl)
    out = {'name': os.path.basename(os.path.dirname(path)), 'file': os.path.basename(path), 'size': W, 'shader': m.shader, 'minor': m.minor,
           'water': water, 'hmin': min(hv), 'hmax': max(hv), 'hmed': hmed, 'hspan': hi - lo,
           'slope': {'mean': sum(sl) / len(sl), 'p5': sum(1 for s in sl if s > 5) / float(len(sl)), 'p20': sum(1 for s in sl if s > 20) / float(len(sl)),
                     'p30': sum(1 for s in sl if s > 30) / float(len(sl)), 'median': percentile(ssl, 0.5)},
           'relief': math.sqrt(sum(x * x for x in rel) / len(rel))}
    L = m.lighting
    out['light'] = {'multiplier': L['multiplier'], 'sun': L['sun_color'], 'ambience': L['ambience'], 'shadow': L['shadow_fill'], 'fog': L['fog_color'], 'bloom': L['bloom'],
                    'spec': L['specular'], 'sundir': L['sun_direction']}
    out['wcolor'] = m.water.get('surface_color') if m.water.get('present') else None
    # the mask weights on the grid
    weights = [None] * 10
    for blob, first in ((m.mask_low, 1), (m.mask_high, 5)):
        mc = mask_channels(blob)
        if not mc:
            continue
        mw, mh, chans = mc
        for c in range(4):
            g = [0.0] * (n * n)
            ch = chans[c]
            for j in range(n):
                row = min(mh - 1, int((j + 0.5) * mh / float(n))) * mw
                for i in range(n):
                    g[j * n + i] = ch[row + min(mw - 1, int((i + 0.5) * mw / float(n)))] / 255.0
            weights[first + c] = g
    # base weight: what the painted layers leave (the shader lets each layer lerp over the ones below)
    base = [1.0] * (n * n)
    for k in range(1, 9):
        if weights[k]:
            wk = weights[k]
            for q in range(n * n):
                base[q] *= (1.0 - wk[q])
    weights[0] = base
    pct = {}
    rank = sorted(range(n * n), key=lambda q: hv[q])
    for pos, q in enumerate(rank):
        pct[q] = pos / float(n * n - 1)
    layers = []
    for k in range(10):
        albedo, scale = m.strata[k]
        nrm, nscale = (m.strata_normals[k] if k < 9 else ('', 0.0))
        rec = {'layer': k, 'albedo': albedo, 'scale': scale, 'normal': nrm}
        w = weights[k]
        if w:
            tot = sum(w)
            rec['cover'] = tot / len(w)
            if tot > 0.01 * len(w):
                rec['slope'] = sum(w[q] * sl[q] for q in range(n * n)) / tot
                rec['h'] = sum(w[q] * pct[q] for q in range(n * n)) / tot
                rec['rel'] = sum(w[q] * rel[q] for q in range(n * n)) / tot
                sb, sn, hb, hn = [0.0] * len(SLOPE_EDGES), [0] * len(SLOPE_EDGES), [0.0] * 10, [0] * 10
                for q in range(n * n):
                    b = 0
                    while b + 1 < len(SLOPE_EDGES) and sl[q] >= SLOPE_EDGES[b + 1]:
                        b += 1
                    sb[b] += w[q]
                    sn[b] += 1
                    d = min(9, int(pct[q] * 10))
                    hb[d] += w[q]
                    hn[d] += 1
                rec['bys'] = [round(sb[b] / sn[b], 3) if sn[b] else None for b in range(len(SLOPE_EDGES))]      # mean weight by slope bin
                rec['byh'] = [round(hb[b] / hn[b], 3) if hn[b] else None for b in range(10)]                      # mean weight by height decile of the map
                inter = sum(1 for v in w if 0.1 < v < 0.9)
                full = sum(1 for v in w if v >= 0.9)
                rec['crisp'] = 1.0 - inter / float(max(1, inter + full))
                rec['peak'] = full / float(len(w))
        layers.append(rec)
    out['layers'] = layers
    return out


def work(path):
    try:
        return analyse(path)
    except Exception as e:     # stubs, campaign base maps, unsupported minors
        return {'name': os.path.basename(os.path.dirname(path)), 'error': str(e)[:120]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--maps', default=default_maps())
    ap.add_argument('--out', default=os.path.join(SP.RUNS, 'maptex', 'maps.json'))
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 4) - 2))
    ap.add_argument('--limit', type=int, default=0)
    a = ap.parse_args()
    files = []
    for d in sorted(os.listdir(a.maps)):
        p = os.path.join(a.maps, d)
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if f.lower().endswith('.scmap'):
                    files.append(os.path.join(p, f))
                    break
    if a.limit:
        files = files[:a.limit]
    t0 = time.time()
    with multiprocessing.Pool(a.jobs) as pool:
        recs = pool.map(work, files, chunksize=2)
    good = [r for r in recs if 'error' not in r]
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, 'w', encoding='utf-8') as fh:
        json.dump(good, fh)
    print('%d maps read, %d skipped, %.0f s -> %s' % (len(good), len(recs) - len(good), time.time() - t0, a.out))
    for r in recs:
        if 'error' in r:
            print('  skipped', r['name'], r['error'])


if __name__ == '__main__':
    main()
