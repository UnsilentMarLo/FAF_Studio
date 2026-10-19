#!/usr/bin/env python3
"""Renders the thumbnails of the graph library (stage T7) from the graphs themselves.

    python scripts/make_graph_thumbs.py [--tag t7] [--ids a,b,c] [--size 128]

An editor instance (scripts/editor_inst.py, started on a 1024 map: `editor_inst.py start <tag> --map editor_blank_1024`) evaluates every library graph at its preview resolution
(257 x 257 samples), draws it (graphlib.lua: shaded relief with cast shadows, land colours, water, the texture layers tinted on top) and hands over

  * a DXT5 DDS of --size pixels in editor/runtime/lua/editor/graphpresets/thumbs/<id>.dds (the palette shows it when the graph is loaded),
  * three raw 16 bit channel files, which this script turns into docs/projects/editor/graphlib/<id>.png (257 x 257, for the documentation),

and writes docs/projects/editor/TERRAIN_GRAPH_LIBRARY.md (a table with the picture and the README line of every graph).
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
EDITOR = os.path.join(ROOT, 'editor', 'runtime', 'lua', 'editor')
THUMBS = os.path.join(EDITOR, 'graphpresets', 'thumbs')
DOCS = os.path.join(ROOT, 'docs', 'projects', 'editor')
PICS = os.path.join(DOCS, 'graphlib')
WORK = os.environ.get('GRAPH_THUMBS_WORK') or tempfile.mkdtemp(prefix='graph_thumbs_')      # raw channel files and the command chunk (outside the repository)


def png(path, w, h, rgb):
    raw = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def library_entries():
    text = open(os.path.join(EDITOR, 'graphpresets', 'index.lua'), encoding='utf-8').read()
    out = []
    for m in re.finditer(r"\{ id = '([^']+)', name = '((?:[^'\\]|\\.)*)', note = '((?:[^'\\]|\\.)*)', library = true \}", text):
        out.append((m.group(1), m.group(2).replace("\\'", "'"), m.group(3).replace("\\'", "'")))
    return out


def run_lua(tag, code, timeout=900):
    path = os.path.join(WORK, 'thumbs_cmd.lua')
    with open(path, 'w') as f:
        f.write(code)
    r = subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'cmd', tag, path, '--timeout', str(timeout), '--chars', '6000'], capture_output=True, text=True, cwd=ROOT)
    return (r.stdout + r.stderr).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tag', default='t7')
    ap.add_argument('--ids', default='')
    ap.add_argument('--size', type=int, default=128)
    a = ap.parse_args()
    entries = library_entries()
    if a.ids:
        want = a.ids.split(',')
        entries = [e for e in entries if e[0] in want]
    os.makedirs(THUMBS, exist_ok=True)
    os.makedirs(PICS, exist_ok=True)
    raw = os.path.join(WORK, 'raw')
    os.makedirs(raw, exist_ok=True)
    lua_dir = lambda p: p.replace('\\', '/')
    failed = []
    for i in range(0, len(entries), 4):
        batch = entries[i:i + 4]
        code = ["local Lib = import('/lua/editor/graphlib.lua')", 'local out = {}']
        for gid, _, _ in batch:
            code.append("do local ok, r, e = pcall(Lib.Export, '%s', '%s') table.insert(out, '%s export ' .. tostring(ok) .. ' ' .. tostring(r) .. ' ' .. tostring(e)) end" % (gid, lua_dir(raw), gid))
            code.append("do local ok, r, e = pcall(Lib.WriteThumb, '%s', '%s', %d) table.insert(out, '%s thumb ' .. tostring(ok) .. ' ' .. tostring(r) .. ' ' .. tostring(e)) end" % (gid, lua_dir(THUMBS), a.size, gid))
        code.append("return table.concat(out, '\\n')")
        res = run_lua(a.tag, '\n'.join(code))
        print(res)
        for gid, _, _ in batch:
            ch = []
            ok = True
            for c in 'rgb':
                p = os.path.join(raw, '%s_%s.raw' % (gid, c))
                if not os.path.isfile(p):
                    ok = False
                    break
                ch.append(open(p, 'rb').read())
            if not ok:
                failed.append(gid)
                continue
            n = len(ch[0]) // 2
            side = int(round(n ** 0.5))
            if side * side != n:
                failed.append(gid)
                continue
            words = [struct.unpack('<%dH' % n, c) for c in ch]
            rgb = bytearray(n * 3)
            for k in range(n):
                rgb[3 * k] = words[0][k] >> 8
                rgb[3 * k + 1] = words[1][k] >> 8
                rgb[3 * k + 2] = words[2][k] >> 8
            png(os.path.join(PICS, gid + '.png'), side, side, bytes(rgb))
    # the documentation table
    lines = ['# Terrain graph library', '',
             'Twenty ready graphs for the terrain graph editor (Generate workspace > Nodes > Graphs > *Library*). Every picture is rendered from the graph itself by `scripts/make_graph_thumbs.py`',
             '(shaded relief with cast shadows, land colours, water, the texture layers tinted on top; preview resolution of a 1025 map). The graphs are written by `scripts/make_graph_library.py`.', '',
             'Conventions: sizes are shares of the map width (a *Map share* node wired into the scale / radius / width port), so a graph looks the same on every map size; texture layers 2 cliff / rock,',
             '3 sand, 4 snow / ice, 5 lush, 6 rock outcrops, 7 dark / occluded; competitive layouts have ONE base pad in the master part of the map and a *Symmetrize* node that copies it.', '',
             '| Picture | Graph | What it makes |', '|---|---|---|']
    for gid, name, note in library_entries():
        pic = '![%s](graphlib/%s.png)' % (gid, gid) if os.path.isfile(os.path.join(PICS, gid + '.png')) else '(no picture)'
        lines.append('| %s | **%s**<br>`%s` | %s |' % (pic, name, gid, note))
    lines.append('')
    open(os.path.join(DOCS, 'TERRAIN_GRAPH_LIBRARY.md'), 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
    print('pictures: %d, failed: %s' % (len(entries) - len(failed), failed))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
