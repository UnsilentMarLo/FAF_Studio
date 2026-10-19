"""Stress test for the editor's session restart: open map after map (Maps.Open -> ExitGame -> front end -> new session) and check that the
process survives every load. Regression test for the "editor crashes when loading a map" bug (teardown of the old session, heap corruption).

  python scripts/ed_stress_load.py <tag> [--loads 30] [--mode plain|dirty|rapid|workspaces|graph|link|popout|play|all|full] [--maps big|small|mixed|path1,path2]
                                         [--seed 1] [--timeout 180] [--log result.json] [--leak-mb 150]

<tag> is an editor_inst.py instance (use your own; `editor_inst.py new <tag>` once). The script never kills anything: a process that died is
reported with the newest bin/faf_crash_*.txt of that instance (top frames).

Modes (what the editor has in its document / what runs while the map is replaced):
  plain   an untouched document
  dirty   units, props, paths, markers, an effect and a sim entity placed, undo history filled, overlay / terrain type view on
  rapid   the next Open is sent while the previous load is still running (the second command overrides the queue file)
  all     plain, dirty and rapid in turn
  workspaces  a random workspace is showing with every panel of the editor opened in it (the panels hold controls, caches and sim entities of the old session)
  graph   the terrain graph canvas (Generate workspace) is evaluated right before the load: the field engine holds native buffers while the session is torn down
  link    the Gaea / World Machine live link is watching a folder
  popout  panels are torn out into their own windows (a second D3D swap chain, its own frame and key handler)
  play    a test run is under way when the next map is opened (mission script threads, sim entities, the play-test HUD)
  full    a random mix of the above on every load (workspace + graph + link + popout + play + dirty)
Every load also samples the process (working set, private bytes) and the editor's Lua heap; the report fits a line through the samples after a warm-up and
flags growth above --leak-mb per 100 loads (default 150 MB). With --loads 200 it is the long run the follow-up list asks for.

Exit code 0 = every load survived, 1 = the editor died (or a load never finished), 2 = setup failure, 3 = survived but memory grows (see --leak-mb).
"""
import argparse
import glob
import json
import os
import random
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402

LIST_LUA = ("local l = import('/lua/editor/maps.lua').List() local o = {} for i, m in l do table.insert(o, m.path) end "
            "return table.concat(o, '\\n')")

# State a user plausibly has in the document before opening another map. Every step is pcall'd: a missing helper must not stop the run.
# The heart of it is a whole-map height write (rect ends on the last row / column, the camera low enough for SyncTerrain to copy the dirty
# rect): that used to write one row past the sim height field (heap overflow, found 2026-10-18) and kill the editor a load or two later.

# One preparation per mode: what the editor has open / running when the next map is requested. Every step is pcall'd (a missing helper must not stop the run).
PREP = {
    'workspaces': """
local out = {}
local Sh = import('/lua/editor/gui/shell.lua')
local ws = import('/lua/editor/gui/workspace.lua').Presets()
local pick = ws[math.random(1, table.getn(ws))]
local ok, err = pcall(function() Sh.ShowWorkspace(pick) end)
table.insert(out, 'ws=' .. pick .. (ok and '' or (' ERR ' .. tostring(err))))
local Cmd = import('/lua/editor/gui/commands.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local n = 0
for _, def in Panels.All() do
    if def.id ~= 'viewport' then
        local ok2 = pcall(Cmd.Run, 'panel.open.' .. def.id)
        if ok2 then n = n + 1 end
    end
end
table.insert(out, 'panels=' .. n)
return table.concat(out, ' ')
""",
    'graph': """
local out = {}
pcall(function() import('/lua/editor/gui/shell.lua').ShowWorkspace('Generate') end)
local ok, err = pcall(function()
    local Graph = import('/lua/editor/graph.lua')
    local GRun = import('/lua/editor/graphrun.lua')
    if not Graph.Current or table.getn(Graph.Current.nodes or {}) == 0 then
        Graph.New('stress')
        local a = Graph.Add('perlin', 0, 0, { scale = 80, octaves = 4 })
        local b = Graph.Add('blur', 200, 0, { radius = 3 })
        local c = Graph.Add('out_height', 400, 0)
        if a and b and c then pcall(Graph.Connect, a.id, 'out', b.id, 'a') pcall(Graph.Connect, b.id, 'out', c.id, 'a') end
    end
    GRun.Refresh(true)
end)
table.insert(out, 'graph=' .. (ok and 'ok' or ('ERR ' .. tostring(err))))
return table.concat(out, ' ')
""",
    'link': """
local ok, err = pcall(function()
    local I = import('/lua/editor/interop.lua')
    I.Link.mode = 'folder'
    I.Link.folder = 'interop_link'
    I.LinkStart()
end)
return 'link=' .. (ok and 'ok' or ('ERR ' .. tostring(err)))
""",
    'popout': """
local out = {}
local Sh = import('/lua/editor/gui/shell.lua')
for i, id in { 'console', 'properties' } do
    local ok, err = pcall(function() return Sh.Detach(id, 100 + i * 40, 100 + i * 40, nil, { 100 + i * 40, 100 + i * 40, 420, 260 }) end)
    table.insert(out, id .. (ok and '=ok' or ('=ERR ' .. tostring(err))))
end
return table.concat(out, ' ')
""",
    'play': """
local ok, err = pcall(function() import('/lua/editor/ui.lua').Play() end)
return 'play=' .. (ok and 'ok' or ('ERR ' .. tostring(err)))
""",
}
PREP_MODES = ['workspaces', 'graph', 'link', 'popout', 'play']

# the sample taken after every finished load
MEM_LUA = r"""
local ok, kb = pcall(function() return collectgarbage('count') end)
if not ok then ok, kb = pcall(function() return gcinfo() end) end
return tostring(ok and kb or -1)
"""

DIRTY_LUA = r"""
local out = {}
local function try(name, f)
    local ok, err = pcall(f)
    table.insert(out, name .. '=' .. (ok and 'ok' or ('ERR ' .. tostring(err))))
end
try('zoom', function() GetCamera('WorldCamera'):SetZoom(40, 0) end)
try('edge_write', function()
    local w, h = ed_terrain_info()
    local words = ed_terrain_read_rect(0, 0, w - 1, h - 1)
    for i = 1, table.getn(words) do words[i] = math.mod(words[i] + 37, 60000) end
    ed_cmd_begin('stress edge write')
    ed_doc_height_write(0, 0, w - 1, h - 1, words)
    ed_cmd_end()
end)
try('overlay', function()
    local ok, O = pcall(import, '/lua/editor/overlay.lua')
    if ok and O and O.Show then O.Show('terraintype') end
end)
return table.concat(out, ' ')
"""


class Inst:
    def __init__(self, tag):
        self.tag = tag
        self.dir = EI.inst_dir(tag)
        self.bin = os.path.join(self.dir, 'bin')

    def pid(self):
        return EI.read_pid(self.tag)

    def alive(self):
        return EI.alive(self.pid())

    def log_size(self):
        try:
            return os.path.getsize(os.path.join(self.dir, 'run.log'))
        except OSError:
            return 0

    def log_since(self, pos):
        try:
            with open(os.path.join(self.dir, 'run.log'), 'rb') as f:
                f.seek(pos)
                return f.read().decode('utf-8', errors='replace')
        except OSError:
            return ''

    def restart(self):
        args = open(os.path.join(self.dir, 'start_args.txt'), encoding='utf-8').read().splitlines()
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            EI.cmd_start(argparse.Namespace(tag=self.tag, map=args[0], exe=args[1], wait=90))

    def crash_files(self):
        return set(glob.glob(os.path.join(self.bin, 'faf_crash_2*.txt')))

    def send(self, src, timeout=60):
        """Run a Lua chunk in the editor; returns its text or None when the editor did not answer in time."""
        cmdfile = os.path.join(self.dir, 'edcmd.lua')
        out = cmdfile + '.out'
        before = os.path.getmtime(out) if os.path.exists(out) else 0
        open(cmdfile, 'w', encoding='utf-8').write(src + '\n-- run %d\n' % time.time_ns())
        start = time.time()
        end = start + timeout
        woke = 0
        while time.time() < end:
            # an editor window that is not the foreground window idles (see editor_inst.py cmd): click its title bar every ~8 s
            if time.time() - start > 6 + 8 * woke:
                woke += 1
                try:
                    EI.cmd_focus(argparse.Namespace(tag=self.tag))
                except Exception:
                    pass
            if os.path.exists(out) and os.path.getmtime(out) > before:
                time.sleep(0.1)
                return open(out, encoding='utf-8', errors='replace').read().strip()
            if not self.alive():
                return None
            time.sleep(0.25)
        return None

    def crash_summary(self, files):
        lines = []
        for f in sorted(files)[-1:]:
            for l in open(f, encoding='utf-8', errors='replace'):
                l = l.rstrip()
                if l.startswith(('exe stamp', 'Address', 'AV target', 'Reason', 'session', 'File:', 'Line:')) or l.startswith('[fault]   #'):
                    l = re.sub(r"\(C:\\[^)]*\\([A-Za-z_.0-9]+):(\d+)\)", r"(\1:\2)", l)
                    lines.append(l[:200])
                    if len(lines) > 16:
                        break
        return '\n    '.join(lines)


def map_list(inst):
    r = inst.send(LIST_LUA, 60)
    if not r or not r.startswith('OK: '):
        raise SystemExit('cannot list maps: %r' % r)
    return [p for p in r[4:].splitlines() if p]


def pick_maps(inst, how, n, rnd):
    # the SC2 campaign ports (sc2_ca_*) need the SC2 campaign mod: without it the mission script fails and no editor UI starts (not a crash)
    paths = [p for p in map_list(inst) if '/sc2_ca_' not in p]
    if ',' in how or how.startswith('/maps'):
        given = [p for p in how.split(',') if p]
        return given * n if len(given) == 1 else given    # one path = the same map n times (separates a leak of the editor from the engine caching each new map)
    big = [p for p in paths if re.search(r'1024|4096|2048|_20km|sc2_mp', p, re.I)]
    small = [p for p in paths if p not in big]
    pool = {'big': big or paths, 'small': small or paths}.get(how)
    out = []
    for i in range(n):
        if pool:
            out.append(rnd.choice(pool))
        else:  # mixed
            out.append(rnd.choice(big if (i % 3 == 0 and big) else (small or paths)))
    return out



def process_memory(pid):
    """(working set MB, private MB) of a process through ctypes (no psutil here); None when it cannot be read."""
    try:
        import ctypes
        from ctypes import wintypes

        class PMC(ctypes.Structure):
            _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD), ('PeakWorkingSetSize', ctypes.c_size_t), ('WorkingSetSize', ctypes.c_size_t),
                        ('QuotaPeakPagedPoolUsage', ctypes.c_size_t), ('QuotaPagedPoolUsage', ctypes.c_size_t), ('QuotaPeakNonPagedPoolUsage', ctypes.c_size_t),
                        ('QuotaNonPagedPoolUsage', ctypes.c_size_t), ('PagefileUsage', ctypes.c_size_t), ('PeakPagefileUsage', ctypes.c_size_t), ('PrivateUsage', ctypes.c_size_t)]
        k32 = ctypes.windll.kernel32
        psapi = ctypes.windll.psapi
        k32.OpenProcess.restype = wintypes.HANDLE
        h = k32.OpenProcess(0x1000 | 0x0010, False, pid)        # QUERY_LIMITED_INFORMATION | VM_READ
        if not h:
            h = k32.OpenProcess(0x0400 | 0x0010, False, pid)    # QUERY_INFORMATION | VM_READ
        if not h:
            return None
        c = PMC()
        c.cb = ctypes.sizeof(c)
        ok = psapi.GetProcessMemoryInfo(h, ctypes.byref(c), c.cb)
        k32.CloseHandle(h)
        if not ok:
            return None
        return c.WorkingSetSize / 1048576.0, c.PrivateUsage / 1048576.0
    except Exception:
        return None


def slope(ys):
    """Least squares slope of ys over 0..n-1."""
    n = len(ys)
    if n < 3:
        return 0.0
    mx = (n - 1) / 2.0
    my = sum(ys) / n
    den = sum((i - mx) ** 2 for i in range(n))
    return sum((i - mx) * (y - my) for i, y in enumerate(ys)) / den if den else 0.0


MIN_VERDICT_LOADS = 30    # samples after the warm-up before a trend can count as a leak


def leak_report(samples, leak_mb):
    """samples: list of { ws, priv, lua }. -> (text lines, leaked?)"""
    lines = []
    leaked = False
    warm = max(3, len(samples) // 5)
    body = samples[warm:] if len(samples) > warm + 3 else samples
    for key, label in (('ws', 'working set MB'), ('priv', 'private MB'), ('lua', 'Lua heap KB')):
        ys = [x[key] for x in body if x.get(key) is not None and x[key] >= 0]
        if len(ys) < 4:
            continue
        per100 = slope(ys) * 100
        first, last = ys[0], ys[-1]
        flag = ''
        limit = leak_mb if key != 'lua' else leak_mb * 1024
        # a short run (the nightly's 12 loads) is dominated by which maps came up: the trend is shown but gives no verdict
        if per100 > limit and len(body) >= MIN_VERDICT_LOADS:
            flag = '   <-- grows %.0f per 100 loads (limit %.0f)' % (per100, limit)
            leaked = True
        lines.append('%-15s first %.0f  last %.0f  min %.0f  max %.0f  trend %+.1f per 100 loads%s' % (label, first, last, min(ys), max(ys), per100, flag))
    if len(body) < MIN_VERDICT_LOADS:
        lines.append('(fewer than %d loads after the warm-up: trends are for information, no leak verdict)' % MIN_VERDICT_LOADS)
    return lines, leaked


def scenario_now(inst, timeout=10):
    r = inst.send("return tostring(SessionGetScenarioInfo and SessionGetScenarioInfo().file) .. ' | ' "
                  ".. tostring(import('/lua/editor/control.lua').started)", timeout)
    return r


def wait_loaded(inst, want, timeout):
    """Polls until the editor answers from a session whose scenario is `want`."""
    stems = [os.path.basename(w).lower() for w in (want if isinstance(want, (list, tuple)) else [want])]
    end = time.time() + timeout
    while time.time() < end:
        if not inst.alive():
            return 'dead'
        r = inst.send("return tostring(SessionGetScenarioInfo().file)", 12)
        if r and r.startswith('OK: ') and any(st in r.lower() for st in stems):
            return 'ok'
        time.sleep(1.0)
    return 'timeout'


def run(a):
    inst = Inst(a.tag)
    if not inst.alive():
        print('instance %s is not running (python scripts/editor_inst.py start %s)' % (a.tag, a.tag))
        return 2
    rnd = random.Random(a.seed)
    modes = ['plain', 'dirty', 'rapid'] if a.mode == 'all' else ([a.mode] if a.mode != 'full' else ['full'])
    maps = pick_maps(inst, a.maps, a.loads, rnd)
    known = inst.crash_files()
    result = {'loads': 0, 'ok': 0, 'failed': None, 'times': [], 'memory': []}
    for i, path in enumerate(maps):
        mode = modes[i % len(modes)]
        preps = []
        if mode == 'full':
            preps = [m for m in PREP_MODES if rnd.random() < 0.5]
            if rnd.random() < 0.5:
                preps.append('dirty')
            mode = 'rapid' if (rnd.random() < 0.25 and i + 1 < len(maps)) else 'plain'
        elif mode in PREP:
            preps = [mode]
            mode = 'plain'
        for prep in preps:
            r = inst.send(DIRTY_LUA if prep == 'dirty' else PREP[prep], 90)
            if r is None:
                result['failed'] = {'load': i, 'map': path, 'stage': 'prepare ' + prep, 'mode': mode}
                break
            if 'ERR' in r and prep != 'dirty':
                print('        prepare %s: %s' % (prep, r[:160]), flush=True)
        if result['failed']:
            print('[%3d/%d] %-6s FAIL (%s: no answer from the editor) %s' % (i + 1, len(maps), mode, result['failed'].get('stage', 'prepare'), path), flush=True)
            break
        if mode == 'dirty':
            r = inst.send(DIRTY_LUA, 60)
            if r is None:
                result['failed'] = {'load': i, 'map': path, 'stage': 'prepare', 'mode': mode}
                break
        t0 = time.time()
        log_from = inst.log_size()
        if mode == 'rapid' and i + 1 < len(maps):
            # two Opens back to back: the second one overrides the queue file while the first load is under way
            inst.send("import('/lua/editor/maps.lua').Open('%s') return 'a'" % path, 20)
            time.sleep(rnd.uniform(0.2, 2.0))
            if inst.alive():
                inst.send("import('/lua/editor/maps.lua').Open('%s') return 'b'" % maps[i + 1], 5)
        else:
            inst.send("import('/lua/editor/maps.lua').Open('%s') return 'opening'" % path, 30)
        # rapid: the second Open is answered by whichever session is up when it arrives: either map counts as a finished load
        want = [path, maps[i + 1]] if (mode == 'rapid' and i + 1 < len(maps)) else path
        state = wait_loaded(inst, want, a.timeout)
        dt = time.time() - t0
        result['loads'] += 1
        new = inst.crash_files() - known
        if state == 'ok' and not new:
            result['ok'] += 1
            result['times'].append(round(dt, 1))
            pm = process_memory(inst.pid())
            lk = inst.send(MEM_LUA, 20)
            try:
                lua_kb = float(lk[4:]) if lk and lk.startswith('OK: ') else -1.0
            except ValueError:
                lua_kb = -1.0
            result['memory'].append({'ws': pm[0] if pm else None, 'priv': pm[1] if pm else None, 'lua': lua_kb})
            print('[%3d/%d] %-6s ok   %5.1fs  %-30s %s  %s' % (i + 1, len(maps), mode, dt, '+'.join(preps) if preps else '', ('%4.0f MB ws %4.0f MB priv lua %.0f KB' % (pm[0], pm[1], lua_kb)) if pm else '', path), flush=True)
            continue
        if state == 'timeout' and not new and inst.alive() and 'BeginSession() failed' in inst.log_since(log_from):
            # the map itself cannot start a game session (its script names an army the scenario lacks): no editor session comes up for it, in the plain game either. Not an editor failure:
            # note it, restart the instance (the dead session has no editor to answer) and go on
            result.setdefault('bad_maps', []).append(path)
            print('[%3d/%d] %-6s SKIP (the map fails BeginSession, not an editor fault; instance restarted) %s' % (i + 1, len(maps), mode, path), flush=True)
            inst.restart()
            continue
        known |= new
        result['failed'] = {'load': i, 'map': path, 'mode': mode, 'state': state, 'crash': sorted(new)}
        print('[%3d/%d] %-6s FAIL (%s) %s' % (i + 1, len(maps), mode, state, path), flush=True)
        if new:
            print('    ' + inst.crash_summary(new))
        break
    print('survived %d of %d loads' % (result['ok'], result['loads']))
    lines, leaked = leak_report(result['memory'], a.leak_mb)
    for l in lines:
        print('  ' + l)
    result['leak'] = leaked
    if a.log:
        json.dump(result, open(a.log, 'w'), indent=1)
    if result['failed']:
        return 1
    return 3 if leaked else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tag')
    ap.add_argument('--loads', type=int, default=30)
    ap.add_argument('--mode', default='plain', choices=['plain', 'dirty', 'rapid', 'workspaces', 'graph', 'link', 'popout', 'play', 'all', 'full'])
    ap.add_argument('--leak-mb', type=float, default=150.0, help='growth per 100 loads (MB; Lua heap: x1024 KB) above which the run reports a leak')
    ap.add_argument('--maps', default='mixed')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--timeout', type=int, default=180)
    ap.add_argument('--log')
    sys.exit(run(ap.parse_args()))


if __name__ == '__main__':
    main()
