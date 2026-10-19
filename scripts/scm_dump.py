#!/usr/bin/env python
"""Dump the skeleton of unit SCM files from the game archives (for the unit wizard's template data, editor/runtime/lua/editor/unitwizdata.lua).

  scm_dump.py bones <ID> [<ID>...]      print the bones (index, parent, position, name) of the LOD0 mesh of each unit
  scm_dump.py header <ID>               print the header counts
  scm_dump.py lua <ID> [<ID>...]        print a Lua table per unit: bones, vertices, triangles, bounds

SCM v5 layout: see editor/runtime/lua/editor/scm.lua. Bone record (108 bytes): 16 floats inverse rest pose matrix, 3 floats position (relative to the parent),
4 floats rotation, u32 name offset, u32 parent index, 2 reserved u32.
Archive: <retail install>/gamedata/units.scd (read only).
"""
import os
import struct
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_paths as P  # noqa: E402
_retail = P.retail_install()
# the retail Forged Alliance install (FAF_STUDIO_RETAIL, else fa_path of the FAForever client's fa_path.lua)
CANDIDATES = [os.path.join(_retail, 'gamedata', 'units.scd')] if _retail else []


def archive():
    for c in CANDIDATES:
        if os.path.isfile(c):
            return c
    raise SystemExit('units.scd not found')


def read_scm(uid, lod=0):
    with zipfile.ZipFile(archive()) as z:
        names = {n.lower(): n for n in z.namelist()}
        key = 'units/%s/%s_lod%d.scm' % (uid.lower(), uid.lower(), lod)
        if key not in names:
            raise KeyError(key)
        return z.read(names[key])


def parse(data):
    if data[:4] != b'MODL':
        raise ValueError('not an SCM')
    (version, bone_at, skinned, vert_at, extra_at, vcount, idx_at, icount, info_at, info_size, total) = struct.unpack_from('<11I', data, 4)
    bones = []
    for i in range(total):
        o = bone_at + i * 108
        rest = struct.unpack_from('<16f', data, o)
        pos = struct.unpack_from('<3f', data, o + 64)
        rot = struct.unpack_from('<4f', data, o + 76)
        name_off, parent = struct.unpack_from('<2I', data, o + 92)
        end = data.index(b'\0', name_off)
        name = data[name_off:end].decode('latin-1')
        if parent == 0xFFFFFFFF:
            parent = -1
        bones.append(dict(i=i, name=name, parent=parent, pos=pos, rot=rot, rest=rest))
    xs, ys, zs = [], [], []
    for k in range(vcount):
        x, y, z = struct.unpack_from('<3f', data, vert_at + k * 68)
        xs.append(x); ys.append(y); zs.append(z)
    bounds = (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs)) if xs else (0,) * 6
    return dict(version=version, skinned=skinned, total=total, vertices=vcount, indices=icount, bones=bones, bounds=bounds)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, ids = argv[1], argv[2:]
    for uid in ids:
        info = parse(read_scm(uid))
        if cmd == 'header':
            print(uid, {k: v for k, v in info.items() if k != 'bones'})
        elif cmd == 'bones':
            print('== %s: %d bones, %d vertices' % (uid, info['total'], info['vertices']))
            for b in info['bones']:
                print('%3d %3d  %8.3f %8.3f %8.3f  %s' % (b['i'], b['parent'], b['pos'][0], b['pos'][1], b['pos'][2], b['name']))
        elif cmd == 'lua':
            print('-- %s' % uid)
            print('%s = { vertices = %d, triangles = %d, bounds = { %s }, bones = {' % (uid.lower(), info['vertices'], info['indices'] // 3, ', '.join('%.3f' % v for v in info['bounds'])))
            for b in info['bones']:
                print("  { '%s', %d, %.4f, %.4f, %.4f, %.5f, %.5f, %.5f, %.5f }," % ((b['name'], b['parent']) + tuple(b['pos']) + tuple(b['rot'])))
            print('} }')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
