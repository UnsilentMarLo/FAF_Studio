#!/usr/bin/env python
"""Pipeline lab: rough terrain -> erosion -> Oversample -> ground kinds -> every output a shader can use, for every terrain shader, then checks what was written.

    python scripts/pipeline_lab.py --out DIR [--tag pl] [--map 1024] [--k 2] [--shaders A,B,...] [--shots Terrain202B,TTerrainXP] [--keep]

For each shader (default: all of them the game has that the editor supports) it runs editor/textlab/pipeline_run.lua in the instance and decodes the map textures the build wrote
(DXT5 through Pillow): the normal map (A = x, R = G = B = z), the lighting / info texture (R water depth, G = B occlusion, A shadow), the roughness / height atlas (R / B roughness, G / A height),
macro and specular textures, and the paint of the layers. DIR/pipeline.json has everything, DIR/pipeline.md is the table. --shots makes camera pictures of the listed shaders.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402

try:
    from PIL import Image
except ImportError:                                    # pragma: no cover
    Image = None

MAPS = {'256': 'editor_blank', '512': 'editor_blank_512', '1024': 'editor_blank_1024', '2048': 'editor_blank_2048'}
SKIP = ('Terrain301', 'TerrainPBR')
EXPECT = {                      # the map-wide pictures each class of shaders reads (maptextures.lua MAPS)
    'legacy': ('macro',), 'ext': ('normal', 'light', 'macro'), 'spec': ('normal', 'light', 'specular'),
    'pbr': ('normal', 'light', 'atlas'), 'splat': ('normal', 'light', 'atlas'),
}


def run_lua(tag, lua, timeout=900):
    path = os.path.join(EI.inst_dir(tag), 'pl_cmd.lua')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(lua)
    r = subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'cmd', tag, path, '--timeout', str(timeout), '--chars', '30000'], capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()


def parse(text):
    res = {'warnings': [], 'kinds': [], 'raw': text}
    for line in text.replace('OK: ', '', 1).splitlines():
        if '=' not in line:
            continue
        k, v = line.split('=', 1)
        if k == 'WARNING':
            res['warnings'].append(v)
        elif k == 'kind':
            res['kinds'].append(v)
        else:
            res[k] = v
    return res


def chan_stats(im, i):
    ch = im.split()[i]
    lo, hi = ch.getextrema()
    hist = ch.histogram()
    n = sum(hist)
    mean = sum(v * c for v, c in enumerate(hist)) / n
    return {'min': lo, 'max': hi, 'mean': round(mean, 1)}


def close(a, b, tol=6.0):
    """Two channels equal up to the DXT5 colour quantisation (5-6-5 end points): mean absolute difference below `tol`."""
    pa, pb = a.tobytes(), b.tobytes()
    step = max(1, len(pa) // 400000)
    return sum(abs(pa[i] - pb[i]) for i in range(0, len(pa), step)) / len(range(0, len(pa), step)) < tol


def analyse(path, kind, inst):
    """Decodes a staged DDS (relative to the instance's bin folder) and reports what its channels hold."""
    if Image is None:
        return {'error': 'Pillow missing'}
    disk = os.path.normpath(os.path.join(inst, 'bin', path.split('|')[0]))
    if not os.path.isfile(disk):
        return {'error': 'no file ' + disk}
    im = Image.open(disk).convert('RGBA')
    with open(disk, 'rb') as f:
        head = f.read(128)
    mips = int.from_bytes(head[28:32], 'little')
    if im.width > 4096:
        im = im.resize((2048, 2048), Image.BILINEAR)
    out = {'size': '%dx%d' % tuple(Image.open(disk).size), 'mips': mips, 'bytes': os.path.getsize(disk)}
    names = {'normal': ('z', 'z', 'z', 'x'), 'light': ('depth', 'ao', 'ao', 'shadow'), 'atlas': ('rough', 'height', 'rough2', 'height2'),
             'macro': ('r', 'g', 'b', 'opacity'), 'specular': ('r', 'g', 'b', 'sharpness')}[kind]
    for i, n in enumerate(names):
        out['RGBA'[i] + '=' + n] = chan_stats(im, i)
    if kind == 'normal':
        r, g, b = im.split()[0], im.split()[1], im.split()[2]
        out['R==G==B'] = close(r, g) and close(g, b)
    if kind == 'light':
        g, b = im.split()[1], im.split()[2]
        out['G==B'] = close(g, b)
    return out


def verdict(res, shader, cls, inst):
    notes = []
    exp = EXPECT.get(cls, ())
    maps = {}
    for kind in ('normal', 'light', 'macro', 'specular', 'atlas'):
        v = res.get('map_' + kind)
        if v:
            maps[kind] = analyse(v, kind, inst)
            maps[kind]['slot'] = v.split('|')[1]
    res['maps'] = maps
    for kind in exp:
        if kind not in maps:
            notes.append('missing ' + kind)
        elif 'error' in maps[kind]:
            notes.append(kind + ': ' + maps[kind]['error'])
    for kind in maps:
        if kind not in exp:
            notes.append('unexpected ' + kind)
    if 'normal' in maps and 'error' not in maps['normal']:
        n = maps['normal']
        if not n.get('R==G==B') or n['A=x']['max'] - n['A=x']['min'] < 40:
            notes.append('normal map: bad channels')
    if 'light' in maps and 'error' not in maps['light']:
        l = maps['light']
        if not l.get('G==B'):
            notes.append('light: G != B')
        if l['A=shadow']['min'] > 250:
            notes.append('light: no shadow at all')
        if l['R=depth']['max'] == 0:
            notes.append('light: no water depth')
    if 'atlas' in maps and 'error' not in maps['atlas']:
        a = maps['atlas']
        if a['G=height']['max'] - a['G=height']['min'] < 20:
            notes.append('atlas: flat heights')
    unexpected = [w for w in res['warnings'] if 'not applied' not in w and 'not written: nothing changed' not in w]
    for w in unexpected:
        notes.append('warning: ' + w)
    if 'BUILD_FAILED' in res or 'ERROR' in res:
        notes.append(res.get('BUILD_FAILED') or res.get('ERROR'))
    layers_painted = [int(res.get('painted', 0))]
    painted = 0
    for i in range(1, 9):
        m = res.get('mask%d' % i)
        if m and float(m.split('/')[2]) > 0.5:
            painted += 1
    res['layers_with_paint'] = painted
    return notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--tag', default='pl')
    ap.add_argument('--map', default='1024')
    ap.add_argument('--k', type=int, default=2)
    ap.add_argument('--shaders', default='')
    ap.add_argument('--shots', default='')
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--theme', default='temperate')
    ap.add_argument('--from-map', action='store_true', help='start from the heights of the open map instead of generated noise (use with --map PATH)')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    inst = EI.inst_dir(a.tag)
    if not os.path.isdir(inst):
        subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'new', a.tag], check=True)
    subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'start', a.tag, '--map', MAPS.get(a.map, a.map), '--size', '1600x900'], check=True)
    body = open(os.path.join(HERE, '..', 'editor', 'textlab', 'pipeline_run.lua'), encoding='utf-8').read()
    if a.shaders:
        shaders = a.shaders.split(',')
    else:
        text = run_lua(a.tag, "local S = import('/lua/editor/shaders.lua') local t = {} for _, s in S.List() do table.insert(t, s.id) end return table.concat(t, ',')")
        shaders = [s for s in text.replace('OK: ', '', 1).split(',') if s and s not in SKIP]
    shots = a.shots.split(',') if a.shots else []
    results = {}
    for shader in shaders:
        t0 = time.time()
        text = run_lua(a.tag, "PL = { shader = '%s', k = %d, theme = '%s', fromMap = %s }\n%s" % (shader, a.k, a.theme, 'true' if a.from_map else 'false', body))
        res = parse(text)
        cls = res.get('class', '?')
        res['notes'] = verdict(res, shader, cls, inst)
        res['wall_s'] = round(time.time() - t0, 1)
        results[shader] = res
        print('%-14s %-6s build %6s ms  maps %s  painted %s  %s' % (shader, cls, res.get('build_ms', '?'), ','.join(sorted(res['maps'])), res['layers_with_paint'],
                                                                  'OK' if not res['notes'] else '; '.join(res['notes'])), flush=True)
        if shader in shots:
            for view, cam in (('oblique', (0.5, 0.72, 0.6, 0, 48)), ('close', (0.5, 0.5, 0.12, 40, 35))):
                lua = "CAM = { %f, %f, %f, %f, %f }\n" % cam + open(os.path.join(HERE, '..', 'editor', 'textlab', 'lab_cam.lua'), encoding='utf-8').read()
                run_lua(a.tag, lua)
                time.sleep(2.5)
                subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'shot', a.tag, os.path.join(a.out, '%s_%s.png' % (shader, view))], capture_output=True)
    with open(os.path.join(a.out, 'pipeline.json'), 'w') as f:
        json.dump(results, f, indent=1)
    if not a.keep:
        subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'stop', a.tag], capture_output=True)
    bad = [s for s, r in results.items() if r['notes']]
    print('\n%d shaders, %d with notes' % (len(results), len(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
