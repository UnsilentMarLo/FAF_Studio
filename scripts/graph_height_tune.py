#!/usr/bin/env python
"""Runs scripts/graph_height_tune.lua on a blank map (default 512) in a test instance: scales the height range of the shipped terrain graphs to a target mean slope.

    python scripts/graph_height_tune.py [--ids a,b] [--map 512] [--tag lab]
    python scripts/graph_preset_install.py --tag lab        # copies the tuned graphs into editor/runtime/lua/editor/graphpresets

Targets are the numbers of the user's maps (scripts/map_texture_stats.py: mean slope 4-18 degrees, median 10, 3-22 percent of the ground over 30 degrees on 512 maps), per kind of landscape.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402
import texture_lab as TL  # noqa: E402

SOFT = lambda node: [[node, 'below', 5], [node, 'radius', 20], [node, 'strength', 0.7]]       # flatten settings that keep the relief of a gentle landscape
# id: (parameter presets, nodes whose Height range is scaled, target mean slope in degrees)
TABLE = {
    'mountains': ([], [3], 22), 'badlands': ([], [3], 22), 'pathing': ([], [2], 14), 'lib_alpine': ([], [3], 26), 'lib_highlands': ([], [3], 22),
    'lib_volcano': ([], [9], 22), 'archipelago': ([], [6], 15), 'lib_archipelago_fair': ([], [5], 18), 'lib_desert_dunes': ([], [7], 18),
    'lib_badlands': ([], [3], 22), 'lib_ffa4_diag': ([], [3], 18), 'pathable': ([], [2], 14),
    'plains': (SOFT(11), [2], 5), 'lib_hex6': (SOFT(19), [3], 7), 'lib_tundra': (SOFT(18), [3], 7), 'lib_wetlands': (SOFT(15), [4], 5),
    'lib_ffa4_corners': (SOFT(22), [3], 8),
}

MAXSPAN = {'lib_volcano': 70, 'lib_alpine': 80, 'lib_highlands': 80}      # most the heights may span in total (units)


def lua_table(ids):
    parts = []
    for i in ids:
        sets, ranges, slope = TABLE[i]
        s = ', '.join('{ %d, \'%s\', %s }' % (n, k, v) for n, k, v in sets)
        cap = ', maxspan = %d' % MAXSPAN[i] if i in MAXSPAN else ''
        parts.append("{ id = '%s', set = { %s }, ranges = { %s }, slope = %s%s }" % (i, s, ', '.join(str(r) for r in ranges), slope, cap))
    return 'TUNE = {\n    ' + ',\n    '.join(parts) + '\n}\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--map', default='512')
    ap.add_argument('--tag', default='lab')
    ap.add_argument('--ids', default='')
    a = ap.parse_args()
    ids = [i for i in a.ids.split(',') if i] or list(TABLE)
    py = sys.executable
    if not os.path.isdir(EI.inst_dir(a.tag)):
        subprocess.run([py, os.path.join(HERE, 'editor_inst.py'), 'new', a.tag], check=True)
    subprocess.run([py, os.path.join(HERE, 'editor_inst.py'), 'stop', a.tag], capture_output=True)
    subprocess.run([py, os.path.join(HERE, 'editor_inst.py'), 'start', a.tag, '--map', TL.MAPS.get(a.map, a.map)], check=True)
    lua = lua_table(ids) + open(os.path.join(HERE, 'graph_height_tune.lua'), encoding='utf-8').read()
    print(TL.run(a.tag, lua, 3500))
    subprocess.run([py, os.path.join(HERE, 'editor_inst.py'), 'stop', a.tag], capture_output=True)


if __name__ == '__main__':
    main()
