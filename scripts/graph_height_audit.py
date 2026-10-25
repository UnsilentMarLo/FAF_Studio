#!/usr/bin/env python
"""Builds every shipped terrain graph on a blank map (default 512) in a test instance and prints the table of scripts/graph_height_audit.lua.

    python scripts/graph_height_audit.py [--map 512] [--tag lab] [--ids a,b] [--seed N] [--keep]
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402
import texture_lab as TL  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--map', default='512')
    ap.add_argument('--tag', default='lab')
    ap.add_argument('--ids', default='')
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--keep', action='store_true')
    a = ap.parse_args()
    py = sys.executable
    if not os.path.isdir(EI.inst_dir(a.tag)):
        subprocess.run([py, os.path.join(HERE, 'editor_inst.py'), 'new', a.tag], check=True)
    subprocess.run([py, os.path.join(HERE, 'editor_inst.py'), 'stop', a.tag], capture_output=True)
    subprocess.run([py, os.path.join(HERE, 'editor_inst.py'), 'start', a.tag, '--map', TL.MAPS.get(a.map, a.map)], check=True)
    cfg = 'AUDIT = { ' + ('ids = { %s }, ' % ', '.join("'%s'" % i for i in a.ids.split(',')) if a.ids else '') + ('seed = %d ' % a.seed if a.seed else '') + '}\n'
    lua = cfg + open(os.path.join(HERE, 'graph_height_audit.lua'), encoding='utf-8').read()
    print(TL.run(a.tag, lua, 1800))
    if not a.keep:
        subprocess.run([py, os.path.join(HERE, 'editor_inst.py'), 'stop', a.tag], capture_output=True)


if __name__ == '__main__':
    main()
