#!/usr/bin/env python3
"""Distribution of structure skirt sizes over the unit blueprints (input for the slope view's skirt slider, docs/projects/editor/SLOPE_VIEW.md).

    python3 -I scripts/skirt_stats.py [--json out.json] [root ...]

Default root: <FA>/units (FAF_STUDIO_FAF_REPO or /home/user/SupCom_Dev_Workspace/faf_repo/fa). Every *_unit.bp is run as Lua (lupa) with a stub UnitBlueprint.

The skirt the engine checks is what RUnitBlueprint does after loading (RUnitBlueprint.cpp ~634): SkirtOffset > 0 becomes 0, SkirtSize = max(SkirtSize, footprint size).
A structure here is a blueprint with the STRUCTURE category (or MotionType RULEUMT_None). The footprint of a structure comes from Footprint.SizeX/SizeZ
(top level), else from the unit's SizeX / SizeZ.
"""
import collections
import json
import os
import sys

import lupa

FA = os.environ.get('FAF_STUDIO_FAF_REPO', '/home/user/SupCom_Dev_Workspace/faf_repo/fa')


def load(path):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    box = lua.eval('{}')
    lua.globals().__box = box
    lua.execute('''
    local box = __box
    function UnitBlueprint(t) box.bp = t end
    local dummy
    dummy = setmetatable({}, { __index = function() return dummy end, __call = function() return dummy end })
    setmetatable(_G, { __index = function() return dummy end })
    ''')
    with open(path, encoding='utf-8', errors='replace') as f:
        src = f.read()
    try:
        lua.execute(src)
    except Exception:
        return None
    return box['bp']


def to_py(t):
    if lupa.lua_type(t) == 'table':
        d = {}
        for k, v in t.items():
            d[k] = to_py(v)
        return d
    return t


def num(v, default=0.0):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def info(bp):
    bp = to_py(bp)
    if not isinstance(bp, dict):
        return None
    phys = bp.get('Physics') or {}
    cats = bp.get('Categories') or {}
    cats = set(cats.values()) if isinstance(cats, dict) else set()
    structure = 'STRUCTURE' in cats or phys.get('MotionType') == 'RULEUMT_None'
    if not structure:
        return None
    fp = bp.get('Footprint') or {}
    fx = num(fp.get('SizeX'), num(bp.get('SizeX'), 1.0))
    fz = num(fp.get('SizeZ'), num(bp.get('SizeZ'), 1.0))
    ox = min(0.0, num(phys.get('SkirtOffsetX')))
    oz = min(0.0, num(phys.get('SkirtOffsetZ')))
    sx = max(num(phys.get('SkirtSizeX')), fx)
    sz = max(num(phys.get('SkirtSizeZ')), fz)
    return {
        'id': str(bp.get('BlueprintId') or ''), 'cats': cats,
        'flatten': bool(phys.get('FlattenSkirt')),
        'mgv': num(phys.get('MaxGroundVariation'), 1.0), 'mgvGiven': 'MaxGroundVariation' in phys,
        'sx': sx, 'sz': sz, 'ox': ox, 'oz': oz, 'fx': fx, 'fz': fz,
        'tech': [c for c in ('TECH1', 'TECH2', 'TECH3', 'EXPERIMENTAL') if c in cats],
        'build': bool(cats & {'BUILTBYTIER1ENGINEER', 'BUILTBYTIER2ENGINEER', 'BUILTBYTIER3ENGINEER', 'BUILTBYCOMMANDER', 'BUILTBYTIER3COMMANDER'}),
    }


def main():
    args = sys.argv[1:]
    out = None
    if '--json' in args:
        i = args.index('--json')
        out = args[i + 1]
        del args[i:i + 2]
    roots = args or [os.path.join(FA, 'units')]
    rows = []
    for root in roots:
        for dp, _, files in os.walk(root):
            for fn in files:
                if fn.lower().endswith('_unit.bp'):
                    bp = load(os.path.join(dp, fn))
                    r = info(bp) if bp is not None else None
                    if r:
                        r['file'] = fn
                        rows.append(r)
    print('structure blueprints:', len(rows))

    def sq(r):
        return max(r['sx'], r['sz'])

    def table(title, sel):
        sub = [r for r in rows if sel(r)]
        c = collections.Counter()
        for r in sub:
            c[(int(r['sx']) if r['sx'] == int(r['sx']) else r['sx'], int(r['sz']) if r['sz'] == int(r['sz']) else r['sz'])] += 1
        print('\n== %s: %d blueprints' % (title, len(sub)))
        cum = 0
        for (x, z), n in sorted(c.items(), key=lambda kv: (-kv[1], kv[0])):
            cum += n
            print('  %5s x %-5s %4d  cum %5.1f%%' % (x, z, n, 100.0 * cum / max(1, len(sub))))
        return sub

    table('all structures', lambda r: True)
    table('FlattenSkirt = true', lambda r: r['flatten'])
    table('FlattenSkirt = false', lambda r: not r['flatten'])
    table('MaxGroundVariation <= 2 (slope matters)', lambda r: r['mgv'] <= 2)
    table('MaxGroundVariation <= 2, FlattenSkirt true (ring rule)', lambda r: r['mgv'] <= 2 and r['flatten'])
    table('MaxGroundVariation <= 2, FlattenSkirt false (area rule)', lambda r: r['mgv'] <= 2 and not r['flatten'])

    print('\n== MaxGroundVariation x FlattenSkirt (given in the blueprint?)')
    c = collections.Counter((r['mgv'], r['flatten'], r['mgvGiven']) for r in rows)
    for k, n in sorted(c.items()):
        print('  mgv %-6s flatten %-5s given %-5s %4d' % (k[0], k[1], k[2], n))

    print('\n== square (max of X, Z) skirt per tech level, MaxGroundVariation <= 2')
    for t in ('TECH1', 'TECH2', 'TECH3', 'EXPERIMENTAL'):
        c = collections.Counter(int(sq(r)) for r in rows if r['mgv'] <= 2 and t in r['tech'])
        print('  %-12s %s' % (t, ' '.join('%d:%d' % kv for kv in sorted(c.items()))))

    print('\n== non-square skirts (MaxGroundVariation <= 2)')
    for r in rows:
        if r['mgv'] <= 2 and r['sx'] != r['sz']:
            print('  %-10s %s x %s' % (r['id'] or r['file'], r['sx'], r['sz']))

    print('\n== fractional offsets / sizes')
    for r in rows:
        if any(v != int(v) for v in (r['sx'], r['sz'], r['ox'], r['oz'])):
            print('  %-10s size %s x %s offset %s, %s' % (r['id'] or r['file'], r['sx'], r['sz'], r['ox'], r['oz']))

    if out:
        for r in rows:
            r['cats'] = sorted(r['cats'])
        with open(out, 'w') as f:
            json.dump(rows, f, indent=1)


if __name__ == '__main__':
    main()
