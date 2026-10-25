#!/usr/bin/env python
"""Copies the graphs written by scripts/graph_preset_upgrade.lua, graph_texture_presets.lua and graph_landform_presets.lua (<instance>/graphs_upgraded/<id>.lua) over
editor/runtime/lua/editor/graphpresets/<id>.lua, keeping the comment line (the first line) of the file that is replaced, and updates (or appends) the names / notes of index.lua.

    python scripts/graph_preset_install.py [--tag g1]
"""
import argparse
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402

PRESETS = os.path.join(HERE, '..', 'editor', 'runtime', 'lua', 'editor', 'graphpresets')

# the names and notes of graphs the upgrade scripts made or renamed
INDEX = {
    'valley': ('Open valley (plains, hills and cliffs)', 'The layout of a good map: flat open plains with clusters of hills that have defined flanks (Landforms node), droplet erosion for realism, painted with the open valley style: bare plains, green hills, rock on the steep ground.'),
    'texturing': ('Texture the existing terrain (ground kinds for any shader)', 'Reads the heights of the map and paints all kinds of ground (grass, dirt, wet ground, sand, rock, dark rock, high rock, snow) with the stratum recipe for the shader of the map: 4, 7 or 8 layers, the base layer, side-mapped layers, terrain types and roughness. The Terrain shader node shows what the shader paints.'),
    'lib_colour_pass': ('Texture, roughness and colour pass (no height change)', 'The ground kinds on the layers of the shader, plus what the shaders need besides the paint: the roughness mask (PBR), macrotexture, specular picture, roughness / height atlas (each is skipped with a note on a shader that does not read it) and a colour map file from the heights.'),
}


def esc(text):
    return text.replace('\\', '\\\\').replace("'", "\\'")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tag', default='g1')
    a = ap.parse_args()
    src = os.path.join(EI.inst_dir(a.tag), 'graphs_upgraded')
    for f in sorted(glob.glob(os.path.join(src, '*.lua'))):
        gid = os.path.basename(f)[:-4]
        dst = os.path.join(PRESETS, gid + '.lua')
        comment = ''
        if os.path.exists(dst):
            first = open(dst, encoding='utf-8').readline()
            if first.startswith('--'):
                comment = first.rstrip('\r\n') + '\n'
        text = open(f, encoding='utf-8').read().replace('\r\n', '\n')
        if text.startswith('return '):
            text = 'Graph = ' + text[len('return '):]       # graph.lua Text() gives `return {...}`; the shipped files are `Graph = {...}` (LoadPreset reads env.Graph)
        if gid in INDEX:
            comment = '-- ' + INDEX[gid][1] + '\n'
        with open(dst, 'w', encoding='utf-8', newline='\n') as out:
            out.write(comment + text)
        print('wrote', gid)
    idx = os.path.join(PRESETS, 'index.lua')
    s = open(idx, encoding='utf-8').read()
    for gid, (name, note) in INDEX.items():
        pat = re.compile(r"(    \{ id = '%s', name = ')[^\n]*?(', note = ')[^\n]*?('(?:, library = true)? \},\n)" % gid)
        s, n = pat.subn(lambda m: m.group(1) + esc(name) + m.group(2) + esc(note) + m.group(3), s)
        if n == 0 and ("id = '%s'" % gid) not in s:
            line = "    { id = '%s', name = '%s', note = '%s' },\n" % (gid, esc(name), esc(note))
            # new graphs go after the first eleven (the sample set), before the texture and check graphs
            marker = "    { id = 'texturing',"
            s = s.replace(marker, line + marker, 1)
            n = 'added'
        print('index', gid, n)
    with open(idx, 'w', encoding='utf-8', newline='\n') as out:
        out.write(s)


if __name__ == '__main__':
    main()
