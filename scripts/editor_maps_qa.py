#!/usr/bin/env python
"""Map lifecycle QA: open each map in the editor, edit it, undo exactly, save it, open the saved copy and compare. Uses an editor_inst.py instance.

    python scripts/editor_maps_qa.py <tag> [--maps /maps/a/a_scenario.lua,/maps/b/b_scenario.lua | big | small | all] [--count 3] [--timeout 240] [--json out.json]

Per map (all values printed and, with --json, written): load seconds, size, props / decals / markers / units, a brush stroke + undo (the document checksum must come back
exactly), redo (must equal the edited checksum), save as (seconds, files written), open the saved copy (checksum, counts, prop / decal numbers must equal the original's).
Exit code 0 = every map passed, 1 = a check failed or the editor died, 2 = setup problem. It never kills anything but the instance's own process (through editor_inst).
"""
import argparse
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402
import editor_nightly as N  # noqa: E402

NL = chr(10)

STATS = r"""
local Map = import('/lua/editor/map.lua')
local w, h = ed_doc_attach()
local nm = 0
for _ in Map.Doc.save.MasterChain['_MASTERCHAIN_'].Markers do nm = nm + 1 end
local na = 0
for _ in (Map.Doc.save.Areas or {}) do na = na + 1 end
local nu = 0
for _ in import('/lua/editor/units.lua').All() do nu = nu + 1 end
return string.format('%s|%d|%d|%d|%d|%d|%d|%s|%s', tostring(Map.Doc.scenarioPath), w or 0, h or 0, ed_prop_count(), ed_decal_count(), nm, nu,
    tostring(ed_doc_checksum(0, 0, 100000, 100000)), tostring(Map.Doc.info and Map.Doc.info.name))
"""

STROKE = r"""
local T = import('/lua/editor/terrain.lua')
local H = import('/lua/editor/history.lua')
local w, h = ed_doc_attach()
T.ClearHistory()
H.Clear()
T.Brush.mode = 'raise' T.Brush.radius = 18 T.Brush.strength = 8
local cx, cz = math.floor(w / 2), math.floor(h / 2)
local before = ed_doc_checksum(0, 0, 100000, 100000)
T.BeginStroke()
for i = 0, 6 do T.Dab(cx + i * 6, cz + i * 3) end
T.EndStroke()
H.PushTerrain()
local after = ed_doc_checksum(0, 0, 100000, 100000)
H.Undo()
local undone = ed_doc_checksum(0, 0, 100000, 100000)
H.Redo()
local redone = ed_doc_checksum(0, 0, 100000, 100000)
H.Undo()
local back = ed_doc_checksum(0, 0, 100000, 100000)
return string.format('%s|%s|%s|%s|%s', tostring(before), tostring(after), tostring(undone), tostring(redone), tostring(back))
"""


def wait_map(inst, expect_stem, timeout):
    """After Maps.Open the session restarts: wait until the new document answers with the expected scenario."""
    t0 = time.time()
    time.sleep(6)
    last = ''
    while time.time() - t0 < timeout:
        try:
            r = inst.lua("local Map = import('/lua/editor/map.lua') return tostring(Map.Doc and Map.Doc.scenarioPath)", timeout=20)
            last = r
            if expect_stem.lower() in r.lower():
                return time.time() - t0
        except RuntimeError as e:
            last = str(e)
            if 'died' in last:
                raise
        time.sleep(2)
    raise RuntimeError('the map did not load in %d s (last: %s)' % (timeout, last))


def parse(stats):
    p = stats.split('|')
    return { 'scenario': p[0], 'w': int(p[1]), 'h': int(p[2]), 'props': int(p[3]), 'decals': int(p[4]), 'markers': int(p[5]), 'units': int(p[6]), 'sum': p[7], 'name': p[8] }


def run_map(inst, path, timeout):
    res = { 'map': path, 'checks': [], 'ok': True }
    stem = re.sub(r'_scenario\.lua$', '', os.path.basename(path))

    def check(name, ok, info=''):
        res['checks'].append('%s %s%s' % ('ok  ' if ok else 'FAIL', name, (' ' + info) if info else ''))
        if not ok:
            res['ok'] = False
    inst.lua("import('/lua/editor/maps.lua').Open('%s') return 'opening'" % path)
    try:
        res['load_s'] = round(wait_map(inst, stem, timeout), 1)
    except RuntimeError as e:
        check('load', False, str(e))
        return res
    time.sleep(3)
    st = parse(inst.lua(STATS, timeout=60))
    res.update({ k: st[k] for k in ('w', 'h', 'props', 'decals', 'markers', 'units') })
    check('document attached', st['w'] > 0 and st['h'] > 0, '%dx%d, %d props, %d decals, %d markers, %d units, load %.0f s' % (st['w'], st['h'], st['props'], st['decals'], st['markers'], st['units'], res['load_s']))
    sums = inst.lua(STROKE, timeout=120).split('|')
    before, after, undone, redone, back = sums
    check('brush stroke changed the height field', before != after)
    check('undo restores the checksum exactly', undone == before)
    check('redo reaches the edited checksum', redone == after)
    check('second undo restores it again', back == before)
    out = '../mapout/qa_%s.v0001' % stem
    t0 = time.time()
    saved = inst.lua("local sc, why = import('/lua/editor/map.lua').SaveAs('%s', 'qa_%s', { preview = false }) return tostring(sc) .. '|' .. tostring(why)" % (out, stem), timeout=240)
    res['save_s'] = round(time.time() - t0, 1)
    scenario = saved.split('|')[0]
    check('save as', scenario.startswith('/maps/'), '%s in %.1f s' % (saved, res['save_s']))
    if not scenario.startswith('/maps/'):
        return res
    inst.lua("import('/lua/editor/maps.lua').Open('%s') return 'opening'" % scenario)
    try:
        res['reopen_s'] = round(wait_map(inst, 'qa_' + stem, timeout), 1)
    except RuntimeError as e:
        check('reopen the saved copy', False, str(e))
        return res
    time.sleep(3)
    st2 = parse(inst.lua(STATS, timeout=60))
    check('saved copy: same size', (st2['w'], st2['h']) == (st['w'], st['h']))
    check('saved copy: same props / decals / markers / units', (st2['props'], st2['decals'], st2['markers'], st2['units']) == (st['props'], st['decals'], st['markers'], st['units']),
          '%s vs %s' % ((st2['props'], st2['decals'], st2['markers'], st2['units']), (st['props'], st['decals'], st['markers'], st['units'])))
    check('saved copy: identical height field checksum', st2['sum'] == st['sum'], '%s vs %s' % (st2['sum'], st['sum']))
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tag')
    ap.add_argument('--maps', default='mixed')
    ap.add_argument('--count', type=int, default=3)
    ap.add_argument('--timeout', type=int, default=240)
    ap.add_argument('--json')
    a = ap.parse_args()
    inst = N.Inst(a.tag)
    if not inst.alive():
        print('instance %s is not running (editor_inst.py start %s)' % (a.tag, a.tag))
        return 2
    listing = inst.lua("local l = import('/lua/editor/maps.lua').List() local o = {} for i, m in l do table.insert(o, m.path) end return table.concat(o, '|')", timeout=60).split('|')
    listing = [p for p in listing if p and '/sc2_ca_' not in p and '/_' not in p]
    if ',' in a.maps or a.maps.startswith('/maps'):
        maps = [m for m in a.maps.split(',') if m]
    else:
        big = [p for p in listing if re.search(r'x20|20x20|sc2_mp_30|1024|4096', p, re.I)]
        small = [p for p in listing if p not in big]
        if a.maps == 'big':
            maps = big[:a.count]
        elif a.maps == 'small':
            maps = small[:a.count]
        else:
            maps = (big[:max(1, a.count // 2)] + small[:max(1, a.count - a.count // 2)])
    allres, ok = [], True
    for m in maps:
        print('== %s' % m, flush=True)
        try:
            r = run_map(inst, m, a.timeout)
        except RuntimeError as e:
            r = { 'map': m, 'ok': False, 'checks': ['FAIL the editor stopped answering: %s' % e] }
        for c in r['checks']:
            print('   ' + c, flush=True)
        allres.append(r)
        ok = ok and r['ok']
        if not inst.alive():
            print('the editor process died')
            break
    if a.json:
        json.dump(allres, open(a.json, 'w'), indent=1)
    print('%d maps, %s' % (len(allres), 'all passed' if ok else 'FAILED'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
