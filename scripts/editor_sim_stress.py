#!/usr/bin/env python
"""Sim thread stress for the editor: play tests with mission timers / waits, sim callbacks (effects, projectiles, spawns, viewer entities), then Stop / Open map at
random moments, over and over. Looks for the unreproduced crash "luaV_execute null in a resumed sim thread" (sctools, 2026-10-18; docs/projects/editor/LOAD_CRASH.md):
a thread of the old session that is resumed after the session was torn down.

    python scripts/editor_sim_stress.py <tag> [--cycles 30] [--seed 1] [--seconds 4] [--map /maps/x/x_scenario.lua] [--json out.json]

Every cycle: build a mission with timers, waits, triggers and spawns in the open map (plus a second army with groups) -> Play -> let it run a random 0..--seconds
while firing sim callbacks and, in some cycles, mission jump / skip / time scale / flag callbacks and unit viewer entities -> leave the run in a random way
(Stop, Open map, Open map while paused, Stop twice, play again at once) -> wait for the next session -> check the process, the crash files, the log.
Exit code 0 = every cycle survived, 1 = the editor died (the newest crash report is summarised) or a session never came back, 2 = setup problem.
"""
import argparse
import glob
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

BUILD = r"""
local M = import('/lua/editor/mission.lua')
local CS = import('/lua/editor/clicksweep.lua')
pcall(CS.Fixture)
M.Data = { mode = 'both', stages = {}, bases = {}, dialogues = {} }
M.AddStage('One') M.AddStage('Two') M.AddStage('Three')
local function node(stage, id, params, parent)
    local ok, path = M.AddNode(stage, 'ready', id, nil, parent)
    if ok then for k, v in params do M.SetParam(stage, 'ready', path, k, v) end end
    return ok and path
end
M.AddDialogue('Intro') M.AddLine(1, 'Commander, hold the line.')
node(1, 'text', { text = 'stage one', seconds = 2 })
local t1 = node(1, 'timer', { seconds = 1 })
if t1 then node(1, 'text', { text = 'timer 1 fired' }, t1) end
local t2 = node(1, 'timer', { seconds = 3 })
if t2 then
    node(1, 'spawn', { army = 'Enemy', group = 'WAVE1', var = 'w1' }, t2)
    node(1, 'wait', { seconds = 1 }, t2)
    node(1, 'text', { text = 'timer 2 fired' }, t2)
end
node(1, 'wait', { seconds = 2 })
node(2, 'wait', { seconds = 1 })
node(2, 'timer', { seconds = 2 })
node(3, 'timer', { seconds = 1 })
node(3, 'end', {})
M.Revision = M.Revision + 1
local n = 0
for _, s in M.Data.stages do n = n + table.getn(s.ready) end
return 'mission nodes=' .. n .. ' findings=' .. table.getn(M.Check())
"""

FIRE = [
    "SimCallback({ Func = 'EdEffect', Args = { emitters = { '/effects/emitters/dust_small_emit.bp' }, x = 120, y = 25, z = 120, seconds = 2 } }, false) return 'effect'",
    "SimCallback({ Func = 'EdSpawnUnit', Args = { bp = 'uel0106', army = 'ARMY_1', x = 100, z = 100 } }, false) return 'spawn'",
    "SimCallback({ Func = 'EdMissionFlag', Args = { name = 'qa_flag', value = true } }, false) return 'flag'",
    "SimCallback({ Func = 'EdMissionScale', Args = { scale = 4 } }, false) return 'scale4'",
    "SimCallback({ Func = 'EdMissionSkip', Args = {} }, false) return 'skip'",
    "SimCallback({ Func = 'EdMissionJump', Args = { stage = 2 } }, false) return 'jump2'",
    "SimCallback({ Func = 'EdMissionJump', Args = { stage = 3 } }, false) return 'jump3'",
    "SimCallback({ Func = 'EdFire', Args = { projectile = '/projectiles/adfireball01/adfireball01_proj.bp', bp = 'uel0106', x = 100, z = 100, speed = 15 } }, false) return 'fire'",
]

LEAVE = ['stop', 'stop_twice', 'open_other', 'open_same_paused', 'play_again']


def crash_files(inst):
    return set(glob.glob(os.path.join(inst.dir, 'bin', 'faf_crash_2*.txt')))


def crash_summary(path):
    keep = []
    for l in open(path, encoding='utf-8', errors='replace'):
        l = l.rstrip()
        if l.startswith(('exe stamp', 'Address', 'AV target', 'Reason', 'session', 'File:', 'Line:')) or l.startswith('[fault]   #'):
            keep.append(re.sub(r"\(C:\\[^)]*\\([A-Za-z_.0-9]+):(\d+)\)", r"(\1:\2)", l)[:200])
        if len(keep) > 18:
            break
    return keep


def wait_session(inst, expect, timeout):
    t0 = time.time()
    time.sleep(5)
    while time.time() - t0 < timeout:
        if not inst.alive():
            return False
        try:
            r = inst.lua("local Map = import('/lua/editor/map.lua') return tostring(Map.Doc and Map.Doc.scenarioPath) .. '|' .. import('/lua/editor/ui.lua').State.mode", timeout=15)
            if expect.lower() in r.lower() and r.endswith('edit'):
                return True
        except RuntimeError as e:
            if 'died' in str(e):
                return False
        time.sleep(2)
    return None


def wait_play(inst, timeout):
    t0 = time.time()
    time.sleep(3)
    while time.time() - t0 < timeout:
        if not inst.alive():
            return False
        try:
            r = inst.lua("return import('/lua/editor/ui.lua').State.mode", timeout=15)
            if r.strip().endswith('play'):
                return True
        except RuntimeError as e:
            if 'died' in str(e):
                return False
        time.sleep(2)
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tag')
    ap.add_argument('--cycles', type=int, default=30)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--seconds', type=float, default=4.0)
    ap.add_argument('--map', default=None)
    ap.add_argument('--timeout', type=int, default=120)
    ap.add_argument('--json')
    a = ap.parse_args()
    inst = N.Inst(a.tag)
    if not inst.alive():
        print('instance %s is not running' % a.tag)
        return 2
    rnd = random.Random(a.seed)
    other = a.map
    if not other:
        paths = inst.lua("local o = {} for i, m in import('/lua/editor/maps.lua').List() do table.insert(o, m.path) end return table.concat(o, '|')", timeout=60).split('|')
        small = [p for p in paths if p and '/sc2_ca_' not in p and '/_' not in p and re.search(r'adaptive_(islet|wonder|sin)|scmp_03', p)]
        other = small[0] if small else paths[1]
    known = crash_files(inst)
    log = []
    ok = True
    for c in range(1, a.cycles + 1):
        leave = LEAVE[rnd.randrange(len(LEAVE))]
        delay = rnd.uniform(0, a.seconds)
        fires = rnd.sample(FIRE, rnd.randint(2, 5))
        info = '%2d/%d leave=%-16s run %.1fs  %s' % (c, a.cycles, leave, delay, ' '.join(f.split("Func = '")[1].split("'")[0] for f in fires))
        try:
            inst.lua(BUILD, timeout=60)
            inst.lua("import('/lua/editor/ui.lua').Play() return 'play'", timeout=60)
            # a changed mission makes Play reload the map (new session that starts in play mode): wait for it
            if not wait_play(inst, a.timeout):
                state = False if not inst.alive() else None
                raise RuntimeError('no play session')
            time.sleep(1.0)
            end = time.time() + delay
            for f in fires:
                inst.lua(f, timeout=30)
                time.sleep(0.2)
            while time.time() < end:
                inst.lua("local ok, t = pcall(GetGameTimeSeconds) return 'time ' .. tostring(ok and t)", timeout=30)     # keeps the window foreground, lets game time pass
                time.sleep(0.4)
            if leave == 'stop':
                inst.lua("import('/lua/editor/ui.lua').Stop() return 'stop'", timeout=30)
                expect = '_playtest'
            elif leave == 'stop_twice':
                inst.lua("import('/lua/editor/ui.lua').Stop() import('/lua/editor/ui.lua').Stop() return 'stop2'", timeout=30)
                expect = '_playtest'
            elif leave == 'open_other':
                inst.lua("import('/lua/editor/maps.lua').Open('%s') return 'open'" % other, timeout=30)
                expect = os.path.basename(other).replace('_scenario.lua', '')
            elif leave == 'open_same_paused':
                inst.lua("import('/lua/editor/ui.lua').PauseToggle() import('/lua/editor/maps.lua').Open(import('/lua/editor/ui.lua').State.backup) return 'open'", timeout=30)
                expect = '_playtest'
            else:
                inst.lua("local ui = import('/lua/editor/ui.lua') ui.Stop() return 'stop'", timeout=30)
                expect = '_playtest'
            state = wait_session(inst, expect, a.timeout)
        except RuntimeError as e:
            state = False if not inst.alive() else None
            info += '  (%s)' % str(e).splitlines()[0][:160]
        new = crash_files(inst) - known
        if state is True and not new:
            print('%s  ok' % info, flush=True)
            log.append({ 'cycle': c, 'leave': leave, 'ok': True })
            continue
        ok = False
        known |= new
        print('%s  FAIL (%s)' % (info, 'died' if state is False else 'no session'), flush=True)
        for f in sorted(new)[-1:]:
            for l in crash_summary(f):
                print('      ' + l)
        log.append({ 'cycle': c, 'leave': leave, 'ok': False, 'crash': sorted(new) })
        break
    print('%d of %d cycles survived' % (sum(1 for l in log if l['ok']), a.cycles))
    if a.json:
        json.dump(log, open(a.json, 'w'), indent=1)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
