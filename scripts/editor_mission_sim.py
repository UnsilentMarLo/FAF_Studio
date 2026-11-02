#!/usr/bin/env python
"""Runs generated missions in the real sim: every mission node type is executed in a test run (Play) of the editor and what happened is compared with what the node should do.

    python scripts/editor_mission_sim.py <tag> [--cases actions,flow,...] [--timeout 120] [--json out.json]

The cases are in lua/editor/selftest_missionsim.lua (one mission per family of nodes: actions, flow, triggers, objectives, platoons, cutscene, coop, bases). Per case:
  1. Prepare(case) builds the test world and the mission in the open map and presses Play (the mission changed, so the session reloads with the test copy of the map,
     whose script traces every node it reaches: mission.lua Compile {test = true});
  2. Verify(case) is polled (missionrun.lua asks the sim for a dump: trace, flags, units per army, relations, economy, how the operation ended) until it says `done`
     (every expected node and trigger body was reached, the facts hold, the log has no script error) or `fail`, or until --timeout seconds;
  3. the engine log is searched for the `EDMISSION` lines the script wrote (trace / ended) as evidence, then Stop.
Exit code 0 = every case passed, 1 = a case failed or the editor died, 2 = setup problem. Only the instance <tag> is touched.
"""
import argparse
import glob
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_nightly as N  # noqa: E402

MODULE = "import('/lua/editor/selftest_missionsim.lua')"


def crash_files(inst):
    return set(glob.glob(os.path.join(inst.dir, 'bin', 'faf_crash_2*.txt')))


def wait_mode(inst, mode, timeout):
    """True when the editor reports State.mode == mode; False on timeout or when it died."""
    t0 = time.time()
    time.sleep(2)
    while time.time() - t0 < timeout:
        if not inst.alive():
            return False
        try:
            r = inst.lua("return import('/lua/editor/ui.lua').State.mode", timeout=20)
            if r.strip().endswith(mode):
                return True
        except RuntimeError as e:
            if 'died' in str(e):
                return False
        time.sleep(1.5)
    return False


def log_evidence(inst, start):
    """The EDMISSION lines of the engine log written after byte offset `start`: (trace count, ended line, first trace ids)."""
    try:
        text = open(inst.log_path(), encoding='utf-8', errors='replace').read()
    except OSError:
        return 0, '', []
    text = text[start:]
    traces = re.findall(r'EDMISSION trace (\S+)', text)
    ended = re.findall(r'EDMISSION ended .*', text)
    return len(traces), (ended[-1] if ended else ''), traces


def run_case(inst, case, timeout):
    res = {'case': case, 'ok': False, 'detail': ''}
    start = os.path.getsize(inst.log_path()) if os.path.exists(inst.log_path()) else 0
    t0 = time.time()
    try:
        # a run left in play mode (an earlier case, a person) is stopped first: Play does nothing while the editor is playing
        if inst.lua("return import('/lua/editor/ui.lua').State.mode", timeout=60).strip().endswith('play'):
            inst.lua("import('/lua/editor/ui.lua').Stop() return 'stop'", timeout=30)
            wait_mode(inst, 'edit', 90)
        r = inst.lua("return %s.Prepare('%s')" % (MODULE, case), timeout=120)
        if r.startswith('fail'):
            res['detail'] = r
            return res
        if not wait_mode(inst, 'play', 120):
            res['detail'] = 'the test run never started (%s)' % ('the editor died' if not inst.alive() else 'timeout')
            return res
        last = ''
        while time.time() - t0 < timeout:
            time.sleep(1.5)
            r = inst.lua("return %s.Verify('%s', %d)" % (MODULE, case, start), timeout=60)
            if r.startswith('done'):
                res['ok'] = True
                res['detail'] = r
                break
            if r.startswith('fail'):
                res['detail'] = r
                break
            last = r
        else:
            res['detail'] = 'timeout after %d s: %s' % (timeout, last)
    except RuntimeError as e:
        res['detail'] = 'the editor stopped answering: %s' % str(e).splitlines()[0][:200]
    n, ended, traces = log_evidence(inst, start)
    res['trace_lines'] = n
    res['ended'] = ended
    res['first_trace'] = traces[:6]
    res['seconds'] = round(time.time() - t0, 1)
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tag')
    ap.add_argument('--cases', default='')
    ap.add_argument('--timeout', type=int, default=120, help='seconds a case may run after the play test started')
    ap.add_argument('--json')
    a = ap.parse_args()
    inst = N.Inst(a.tag)
    if not inst.alive():
        print('instance %s is not running' % a.tag)
        return 2
    try:
        all_cases = inst.lua("return table.concat(%s.Cases, ',')" % MODULE, timeout=60).split(',')
    except RuntimeError as e:
        print('setup failed: %s' % str(e).splitlines()[0])
        return 2
    cases = [c for c in (a.cases.split(',') if a.cases else all_cases) if c]
    known = crash_files(inst)
    results = []
    bad = 0
    for case in cases:
        res = run_case(inst, case, a.timeout)
        new = crash_files(inst) - known
        known |= new
        if new:
            res['ok'] = False
            res['detail'] += ' | the editor wrote a crash report: %s' % sorted(new)[-1]
        print('%-10s %s  (%ss, %d trace lines in the log%s)' % (case, 'PASS' if res['ok'] else 'FAIL', res.get('seconds'), res.get('trace_lines', 0), ', ' + res['ended'] if res.get('ended') else ''))
        print('           ' + res['detail'])
        if res.get('first_trace'):
            print('           log: ' + ' '.join('EDMISSION trace ' + t for t in res['first_trace'][:3]) + ' ...')
        results.append(res)
        bad += 0 if res['ok'] else 1
        if not inst.alive():
            print('the editor died')
            break
        try:
            inst.lua("import('/lua/editor/ui.lua').Stop() return 'stop'", timeout=30)
            wait_mode(inst, 'edit', 90)
        except RuntimeError:
            pass
    print('%d of %d cases passed' % (len(results) - bad, len(cases)))
    if a.json:
        json.dump(results, open(a.json, 'w'), indent=1)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
