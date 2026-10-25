#!/usr/bin/env python
"""Texture lab: generates a terrain, textures it (texture set + stratum recipe) and photographs it in the real engine view, with the editor UI hidden.

    python scripts/texture_lab.py --out DIR [--tag lab] [--map 512] [--cases "mountains:temperate:1,hills:temperate:1"] [--views top,oblique,low]
                                  [--seed 3] [--no-water] [--keep]

A case is  terrain:theme:recipe  (terrain: a Generate preset id, or `-` to keep the map; theme: a texture set id of texsets.lua; recipe: the index into recipes.Presets). The
pictures are DIR/<terrain>_<theme>_<recipe>_<view>.png at the window size of the instance (1600 x 900). The recipe summary (share of every kind of ground) goes to
DIR/<case>.txt. The instance `tag` is created and started on a blank map when it is not running, and stopped at the end unless --keep.
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402

MAPS = {
    '256': '/maps/editor_blank/editor_blank_scenario.lua',
    '512': '/maps/editor_blank_512/editor_blank_512_scenario.lua',
    '1024': '/maps/editor_blank_1024/editor_blank_1024_scenario.lua',
}
VIEWS = {
    # x, z are fractions of the map size; zoom is a fraction of the map size; heading and pitch in degrees
    'top': (0.5, 0.5, 1.5, 0, 90),
    'oblique': (0.5, 0.75, 1.1, 0, 50),
    'low': (0.5, 0.58, 0.45, 20, 30),
    'low2': (0.35, 0.5, 0.4, 250, 28),
    'close': (0.5, 0.5, 0.18, 40, 35),
}


def run(tag, lua, timeout=900):
    path = os.path.join(EI.inst_dir(tag), 'lab_cmd.lua')
    with open(path, 'w') as f:
        f.write(lua)
    r = subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'cmd', tag, path, '--timeout', str(timeout), '--chars', '20000'], capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--tag', default='lab')
    ap.add_argument('--map', default='512')
    ap.add_argument('--cases', default='mountains:temperate:1')
    ap.add_argument('--views', default='top,oblique,low')
    ap.add_argument('--seed', type=int, default=3)
    ap.add_argument('--no-water', action='store_true')
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--amp', type=float, default=0)
    ap.add_argument('--name', default='')
    ap.add_argument('--post', default='', help='Lua run after the recipe (shader switch, generators ...)')
    ap.add_argument('--shader', default='', help='terrain shader to switch to before the recipe')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    inst = EI.inst_dir(a.tag)
    if not os.path.isdir(inst):
        subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'new', a.tag], check=True)
    subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'stop', a.tag], capture_output=True)
    subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'start', a.tag, '--map', MAPS.get(a.map, a.map), '--size', '1600x900'], check=True)
    first = True
    for case in a.cases.split(','):
        terrain, theme, recipe = (case.split(':') + ['', '', ''])[:3]
        graph_ids = []
        if terrain.startswith('g='):                       # g=id[+id2...]: premade terrain graphs of the Generate workspace, built one after the other
            graph_ids = terrain[2:].split('+')
            terrain = '-'
        t = "nil" if terrain in ('-', '') else "'%s'" % terrain
        keepmap = terrain in ('-', '') and theme in ('-', '') and recipe in ('0', '')
        lua = "LAB = { terrain = %s, theme = %s, recipe = %s, seed = %d, water = %s, amp = %s, sel = true }\n" % (
            t, ('nil' if theme in ('-', '') else "'%s'" % theme), ('nil' if recipe in ('0', '-', '') else recipe), a.seed,
            ('nil' if keepmap else ('false' if a.no_water else 'true')), (str(a.amp) if a.amp else 'nil'))
        if graph_ids:
            lua += "LAB.graph = '%s'\nLAB.graphs = { %s }\n" % (graph_ids[0], ', '.join("'%s'" % i for i in graph_ids))
        if a.post:
            lua += 'LAB.post = [[%s]]\n' % a.post
        if a.shader:
            lua += "LAB.shader = '%s'\n" % a.shader
        lua += open(os.path.join(HERE, '..', 'editor', 'textlab', 'lab_scene.lua'), encoding='utf-8').read()
        name = '%s_%s_%s' % (terrain.replace('-', 'keep'), theme.replace('-', 'keep'), recipe) if not a.name else a.name
        if graph_ids:
            name = 'g_' + '_'.join(graph_ids) + ('' if a.name else '_%s_%s' % (theme.replace('-', 'keep'), recipe))
        report = run(a.tag, lua)
        with open(os.path.join(a.out, name + '.txt'), 'w') as f:
            f.write(report)
        print('==', name)
        print(report[:900])
        for v in [x for x in a.views.split(',') if x]:
            fx, fz, fzoom, hd, pt = VIEWS[v]
            cam = "CAM = { %f, %f, %f, %f, %f }\n" % (fx, fz, fzoom, hd, pt)
            cam += open(os.path.join(HERE, '..', 'editor', 'textlab', 'lab_cam.lua'), encoding='utf-8').read()
            run(a.tag, cam)
            time.sleep(2.5)
            out = os.path.join(a.out, '%s_%s.png' % (name, v))
            subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'shot', a.tag, out], capture_output=True)
        first = False
    if not a.keep:
        subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'stop', a.tag], capture_output=True)


if __name__ == '__main__':
    main()
