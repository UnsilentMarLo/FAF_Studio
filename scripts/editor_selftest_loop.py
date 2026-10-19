#!/usr/bin/env python
"""Flakiness hunt for the editor self tests: run the whole set many times in one process (the same Lua state, so shared module state and leftovers show) and across fresh
starts, optionally in shuffled order, and report per test how often it failed and with which FAIL lines.

    python scripts/editor_selftest_loop.py <tag> [--runs 20] [--fresh 3] [--shuffle] [--only selftest_a,selftest_b] [--seed 1] [--exe main_x64_la_p2.exe] [--json out.json]

  --runs N     consecutive full runs inside one editor process (default 20)
  --fresh K    additionally K rounds of "restart the editor, run the set once" (default 3; 0 = skip)
  --shuffle    a different random order for every run (finds order dependence); the order of each failing run is printed
  --only       limit to these tests

The instance <tag> must exist (editor_inst.py new / start). Exit code 0 = every run of every test passed, 1 = at least one failure (the report lists them), 2 = setup problem.
"""
import argparse
import json
import os
import random
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402
import editor_nightly as N  # noqa: E402

NL = chr(10)

SCRIPT = r"""
local names = { %s }
local out = {}
for _, name in names do
    local good, mod = pcall(import, '/lua/editor/' .. name .. '.lua')
    local run = good and mod and rawget(mod, 'Run')
    if run then
        local t0 = GetSystemTimeSeconds()
        local g2, res = pcall(run)
        local text = g2 and tostring(res) or ('ERROR ' .. tostring(res))
        local first = string.sub(text, 1, 120)
        local fails = {}
        for line in string.gfind(text, '[^' .. string.char(10) .. ']*FAIL[^' .. string.char(10) .. ']*') do table.insert(fails, string.sub(line, 1, 240)) end
        local bad = (not g2) or (string.sub(text, 1, 4) == 'FAIL') or (string.sub(text, 1, 5) == 'ERROR') or table.getn(fails) > 0
        table.insert(out, name .. '\t' .. (bad and 'FAIL' or 'ok') .. '\t' .. string.format('%%.1f', GetSystemTimeSeconds() - t0) .. '\t' .. table.concat(fails, ' // ') .. ((bad and table.getn(fails) == 0) and first or ''))
    else
        table.insert(out, name .. '\tskip\t0\tnot in this tree')
    end
end
return table.concat(out, string.char(10))
"""


def test_names(inst):
    names = re.findall(r"'(selftest_\w+)'", EI.SELFTEST_SCRIPT)
    path = os.path.join(inst.dir, 'editor', 'lua', 'editor', 'selftests.extra')
    if os.path.isfile(path):
        for line in open(path).read().split():
            if line.startswith('selftest_') and line not in names:
                names.append(line)
    return names


def run_once(inst, names):
    script = SCRIPT % ', '.join("'%s'" % n for n in names)
    text = inst.lua(script, timeout=900)
    res = {}
    for line in text.splitlines():
        p = line.split('\t')
        if len(p) >= 4:
            res[p[0]] = { 'result': p[1], 'seconds': float(p[2] or 0), 'info': p[3] }
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tag')
    ap.add_argument('--runs', type=int, default=20)
    ap.add_argument('--fresh', type=int, default=3)
    ap.add_argument('--shuffle', action='store_true')
    ap.add_argument('--only')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--exe', default='main_x64_la_p2.exe')
    ap.add_argument('--json')
    a = ap.parse_args()
    inst = N.Inst(a.tag)
    if not inst.alive():
        print('instance %s is not running' % a.tag)
        return 2
    names = test_names(inst)
    if a.only:
        names = [n for n in names if n in a.only.split(',')]
    rnd = random.Random(a.seed)
    stats = {}       # name -> { runs, fails, lines: {text: count}, seconds: [..] }
    failed_runs = []

    def record(label, order, res):
        for name in order:
            r = res.get(name)
            if not r or r['result'] == 'skip':
                continue
            st = stats.setdefault(name, { 'runs': 0, 'fails': 0, 'lines': {}, 'seconds': [] })
            st['runs'] += 1
            st['seconds'].append(r['seconds'])
            if r['result'] != 'ok':
                st['fails'] += 1
                key = r['info'][:300]
                st['lines'][key] = st['lines'].get(key, 0) + 1
                failed_runs.append((label, name, order[:order.index(name) + 1]))
    for i in range(a.runs):
        order = list(names)
        if a.shuffle:
            rnd.shuffle(order)
        t0 = time.time()
        try:
            res = run_once(inst, order)
        except RuntimeError as e:
            print('run %d: the editor stopped answering: %s' % (i + 1, e))
            break
        record('run %d' % (i + 1), order, res)
        bad = [n for n in order if res.get(n, {}).get('result') == 'FAIL']
        print('run %2d  %5.0f s  %s' % (i + 1, time.time() - t0, ('FAIL: ' + ', '.join(bad)) if bad else 'all ok'), flush=True)
    for k in range(a.fresh):
        with __import__('contextlib').redirect_stdout(__import__('io').StringIO()):
            inst.start(a.exe)
        order = list(names)
        if a.shuffle:
            rnd.shuffle(order)
        try:
            res = run_once(inst, order)
        except RuntimeError as e:
            print('fresh %d: the editor stopped answering: %s' % (k + 1, e))
            break
        record('fresh %d' % (k + 1), order, res)
        bad = [n for n in order if res.get(n, {}).get('result') == 'FAIL']
        print('fresh %d         %s' % (k + 1, ('FAIL: ' + ', '.join(bad)) if bad else 'all ok'), flush=True)
    print()
    print('%-26s %5s %5s %8s' % ('test', 'runs', 'fail', 'avg s'))
    flaky = False
    for name in sorted(stats):
        st = stats[name]
        avg = sum(st['seconds']) / max(1, len(st['seconds']))
        print('%-26s %5d %5d %8.1f%s' % (name, st['runs'], st['fails'], avg, '   <-- fails' if st['fails'] else ''))
        for text, n in st['lines'].items():
            print('       %dx %s' % (n, text))
        flaky = flaky or st['fails'] > 0
    if failed_runs and a.shuffle:
        print('order of the first failing run:', ' '.join(failed_runs[0][2]))
    if a.json:
        json.dump({ 'stats': stats, 'failed': [(l, n) for l, n, _ in failed_runs] }, open(a.json, 'w'), indent=1)
    return 1 if flaky else 0


if __name__ == '__main__':
    sys.exit(main())
