#!/usr/bin/env python
"""Repeatable QA run of FAF Studio: every self test, a log scan, a panel / menu / workspace sweep with screenshots, and the map-load stress test.

    python scripts/editor_nightly.py [--tag nightly] [--editor <runtime dir>] [--exe main_x64_la_p2.exe] [--loads 12] [--skip stress,shots]
                                     [--out <dir>] [--keep]

Steps (each one is pass / fail in the report; the exit code is 0 only when all pass, 1 when something failed, 2 when the setup failed):
  lint        scripts/editor_lint.py: a name used on an imported editor module that the module does not define (no engine needed)
  selftests   every selftest_* listed by editor_inst.py (+ selftests.extra of the tree): PASS / FAIL, with the FAIL lines
  panels      opens every registered panel through its `panel.open.<id>` command in each workspace and looks for "panel ... failed" in the log
  clicks      every button of every panel (and of the dialogs it opens) is pressed once (clicksweep.lua); a handler that raises is a failure
  menus       every menu-bar and context menu is built: each item has an action (a command that exists, a function or a submenu)
  tips        every interactive widget (buttons, sliders, text fields of every panel, of the dialogs, the top bar and the start screen), every tool, panel tab, workspace
              button and menu item has a tooltip text (tipcheck.lua; texts in tipdata.lua / tooltips.lua)
  workspaces  every workspace is shown at UI 100 % and 150 %; the tool is one the workspace offers; a screenshot of each is analysed
              (not blank, has the dark UI chrome, the viewport shows terrain) and kept in <out>/shots
  layout      layoutcheck.lua: every control (buttons, sliders, fields, labels, paragraph lines, list rows) stays inside the area the user sees (the panel, the dialog box, the window), no two
              overlap, no text is wider than its box. Run at 1920x1080 and 1280x720 (the instance is restarted at each size; the engine window cannot be resized while it runs) and UI 100 /
              150 / 200 %: every workspace, the same after a smaller dock area and with every split pulled to its narrowest / widest, every panel on its own, the dialogs (also with long
              map names and every empty status line filled with a long error text), the bars, and at 150 / 200 % in 1280x720 every button of every panel pressed (the dialogs they open)
  log         the editor log after all of it: LazyVar warnings, "failed" lines of the GUI, Lua errors, missing textures
  maps        scripts/editor_maps_qa.py: a big and a small real map are opened, edited, undone exactly, saved as and reopened (checksums, counts)
  selfloop    scripts/editor_selftest_loop.py: every self test N times in one process, shuffled (order dependence, shared state)
  missionsim  scripts/editor_mission_sim.py: generated missions of every node type are RUN in the sim (test run), what the nodes did is compared with what they should do
  simstress   scripts/editor_sim_stress.py: play tests with timers / waits / spawns / sim callbacks, left five ways, process + crash folder checked
  perf        frame cost budgets: a 1024 map with 3000 markers, 40 areas and 150 units (perfstress.lua), the camera zoomed in on it, perf timing on for ~25 s: the Lua ms per frame of
              the ui tick, of the name labels, the slowest frame and the Lua heap growth must stay under the budgets of PERF_BUDGETS (docs/projects/editor/PERFORMANCE.md)
  stress      scripts/ed_stress_load.py --mode full (all workspaces, graph, live link, pop-outs, play tests, dirty maps), survive every load and keep memory growth under the leak limit

The instance <tag> (default `nightly`) is created on first use and runs the Lua tree of `--editor` (default: this checkout's editor/runtime).
It is the only process this script ever starts or stops. Output: <out>/report.md and report.json (default .runs/<tag>/nightly/<stamp>/).
"""
import argparse
import contextlib
import io
import json
import os
import re
import struct
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst as EI  # noqa: E402

NL = chr(10)


# ---- talking to the instance -----------------------------------------------------------------------------------------------------------------

class Inst:
    def __init__(self, tag):
        self.tag = tag
        self.dir = EI.inst_dir(tag)

    def log_path(self):
        return os.path.join(self.dir, 'run.log')

    def log_lines(self):
        try:
            return open(self.log_path(), encoding='utf-8', errors='replace').read().splitlines()
        except OSError:
            return []

    def alive(self):
        return EI.alive(EI.read_pid(self.tag))

    def lua(self, src, timeout=90):
        """Runs a chunk in the editor; returns the text after 'OK: ' (raises RuntimeError on 'ERROR' or when the editor does not answer)."""
        cmdfile = os.path.join(self.dir, 'edcmd.lua')
        out = cmdfile + '.out'
        before = os.path.getmtime(out) if os.path.exists(out) else 0
        open(cmdfile, 'w', encoding='utf-8').write(src + NL + '-- run %d' % time.time_ns() + NL)
        start = time.time()
        woke = 0
        while time.time() - start < timeout:
            if time.time() - start > 4 + 6 * woke:
                woke += 1
                with contextlib.redirect_stdout(io.StringIO()):
                    try:
                        EI.cmd_focus(argparse.Namespace(tag=self.tag))
                    except Exception:
                        pass
            if os.path.exists(out) and os.path.getmtime(out) > before:
                time.sleep(0.15)
                text = open(out, encoding='utf-8', errors='replace').read().strip()
                if text.startswith('OK: '):
                    return text[4:]
                if text == 'OK:':
                    return ''
                raise RuntimeError(text[:600])
            if not self.alive():
                raise RuntimeError('the editor process died')
            time.sleep(0.25)
        raise RuntimeError('no answer within %d s' % timeout)

    def start(self, exe, editor=None, size=None):
        if not os.path.isdir(os.path.join(self.dir, 'bin')):
            EI.cmd_new(argparse.Namespace(tag=self.tag, editor=editor))
        elif editor:
            # an existing instance keeps the Lua tree it was created with: `--editor` of a later run would otherwise be ignored and the run would test another checkout
            link = os.path.join(self.dir, 'editor')
            if os.path.normcase(os.path.realpath(link)) != os.path.normcase(os.path.realpath(editor)):
                EI.junction(link, os.path.abspath(editor))
        with contextlib.redirect_stdout(io.StringIO()):
            EI.cmd_start(argparse.Namespace(tag=self.tag, map='editor_blank', exe=exe, wait=90, size=size or '1280x720'))

    def shot(self, path):
        with contextlib.redirect_stdout(io.StringIO()):
            EI.cmd_shot(argparse.Namespace(tag=self.tag, out=path, crop=None))


# ---- a tiny PNG reader (no PIL here): enough to judge a screenshot ---------------------------------------------------------------------------

def read_png(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG')
    pos, idat, w, h, bpp = 8, b'', 0, 0, 3
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
            if depth != 8 or ctype not in (2, 6):
                raise ValueError('unsupported PNG (depth %d type %d)' % (depth, ctype))
            bpp = 3 if ctype == 2 else 4
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


def analyse(path):
    """-> dict: mean luma of the whole picture, of the top bar strip and of the viewport middle, and the number of distinct colours (coarse)."""
    w, h, bpp, rows = read_png(path)

    def region(x0, y0, x1, y1, step=3):
        total, n, colours = 0, 0, set()
        for y in range(y0, min(y1, h), step):
            r = rows[y]
            for x in range(x0, min(x1, w), step):
                i = x * bpp
                red, green, blue = r[i], r[i + 1], r[i + 2]
                total += (red * 3 + green * 6 + blue) // 10
                n += 1
                colours.add((red >> 4, green >> 4, blue >> 4))
        return (total / n if n else 0), len(colours)
    whole, whole_c = region(0, 0, w, h)
    bar, _ = region(0, 0, w, 50)
    view, view_c = region(int(w * 0.3), int(h * 0.2), int(w * 0.6), int(h * 0.6))
    return { 'size': [w, h], 'mean': round(whole, 1), 'bar': round(bar, 1), 'view': round(view, 1), 'colours': whole_c, 'view_colours': view_c }


# ---- steps -----------------------------------------------------------------------------------------------------------------------------------

class Report:
    def __init__(self):
        self.steps = []

    def add(self, name, ok, summary, details=None):
        self.steps.append({ 'name': name, 'ok': bool(ok), 'summary': summary, 'details': details or [] })
        print('%-11s %s  %s' % (name, 'PASS' if ok else 'FAIL', summary), flush=True)
        for d in (details or [])[:12]:
            print('            ' + d, flush=True)


def step_selftests(inst, rep, exe, restart_args):
    names = re.findall(r"'(selftest_\w+)'", EI.SELFTEST_SCRIPT) + EI.extra_selftests(inst.tag)
    script = re.sub(r"for _, name in \{[^}]*\} do", "for _, name in { " + ", ".join("'%s'" % n for n in names) + " } do", EI.SELFTEST_SCRIPT)
    # the script only reports the first line of each test; add the FAIL lines so the report says what broke
    script = script.replace("table.insert(out, name .. ': ' .. first .. ' (' .. fails .. ' FAIL lines)')",
                            "table.insert(out, name .. ': ' .. first .. ' (' .. fails .. ' FAIL lines)')" + NL +
                            "        if fails > 0 then for line in string.gfind(text, '[^' .. string.char(10) .. ']*FAIL[^' .. string.char(10) .. ']*') do table.insert(out, '   > ' .. string.sub(line, 1, 200)) end end")
    try:
        text = inst.lua(script, timeout=600)
    except RuntimeError as e:
        rep.add('selftests', False, 'the self tests did not finish: %s' % e)
        return
    bad, details, ran = [], [], 0
    for line in text.splitlines():
        m = re.match(r'^(selftest_\w+):\s*(.*?)\s*\((\d+) FAIL lines\)$', line)
        if m:
            name, first, fails = m.group(1), m.group(2), int(m.group(3))
            if 'not in this tree' in first:
                continue
            ran += 1
            if fails > 0 or first.startswith(('FAIL', 'ERROR')):
                bad.append(name)
            details.append(line if name in bad else '')
        elif line.startswith('   >'):
            details.append(line)
    details = [d for d in details if d]
    rep.add('selftests', not bad and ran > 0, '%d self tests ran, %d failed%s' % (ran, len(bad), (': ' + ', '.join(bad)) if bad else ''), details)
    # the tests leave fixtures in the live document: restart so the sweeps below see a clean editor
    inst.start(exe)


PANEL_LUA = r"""
local Panels = import('/lua/editor/gui/panels.lua')
local Shell = import('/lua/editor/gui/shell.lua')
local out = {}
for _, def in Panels.All() do
    if def.id ~= 'viewport' then table.insert(out, def.id) end
end
return table.concat(out, ' ')
"""


def step_workspaces(inst, rep, outdir):
    """Shows every workspace at UI 100 % and 150 %, checks the tool and takes a screenshot."""
    shots = os.path.join(outdir, 'shots')
    os.makedirs(shots, exist_ok=True)
    names = inst.lua("return table.concat(import('/lua/editor/gui/workspace.lua').Presets(), ' ')").split()
    problems, details = [], []
    for scale in (1.0, 1.5):
        inst.lua("import('/lua/editor/gui/skin.lua').SetScale(%s) import('/lua/editor/gui/shell.lua').ShowWorkspace('Terrain') return 'ok'" % scale)
        for ws in names:
            try:
                state = inst.lua("local sh = import('/lua/editor/gui/shell.lua') sh.ShowWorkspace('%s') local ui = import('/lua/editor/ui.lua') "
                                 "local t = ui.ActiveTool() return ui.State.workspace .. '|' .. tostring(ui.State.tool) .. '|' .. tostring(t ~= nil)" % ws)
            except RuntimeError as e:
                problems.append('%s @%d%%: %s' % (ws, scale * 100, e))
                continue
            wsname, tool, allowed = state.split('|')
            if allowed != 'true':
                problems.append('%s @%d%%: the selected tool %s is not offered by the workspace' % (ws, scale * 100, tool))
            time.sleep(1.2)
            path = os.path.join(shots, '%s_%d.png' % (ws, int(scale * 100)))
            try:
                inst.shot(path)
                a = analyse(path)
            except Exception as e:  # noqa: BLE001
                problems.append('%s @%d%%: screenshot failed (%s)' % (ws, scale * 100, e))
                continue
            details.append('%-12s @%3d%%  mean %.0f  bar %.0f  view %.0f  colours %d' % (ws, scale * 100, a['mean'], a['bar'], a['view'], a['colours']))
            if a['mean'] < 8 or a['colours'] < 40:
                problems.append('%s @%d%%: the screenshot looks blank (mean %.0f, %d colours)' % (ws, scale * 100, a['mean'], a['colours']))
            if a['bar'] > 110:
                problems.append('%s @%d%%: the menu bar is not the dark chrome (mean %.0f)' % (ws, scale * 100, a['bar']))
    inst.lua("import('/lua/editor/gui/skin.lua').SetScale(1.0) import('/lua/editor/gui/shell.lua').ShowWorkspace('Terrain') return 'ok'")
    rep.add('workspaces', not problems, '%d workspaces x 2 scales, %d problems' % (len(names), len(problems)), problems + details)


def step_panels(inst, rep):
    ids = inst.lua(PANEL_LUA).split()
    names = inst.lua("return table.concat(import('/lua/editor/gui/workspace.lua').Presets(), ' ')").split()
    before = len(inst.log_lines())
    for ws in names:
        inst.lua("import('/lua/editor/gui/shell.lua').ShowWorkspace('%s') return 'ok'" % ws)
        # one chunk per workspace: every panel is shown (or added to the dock) and refreshed
        src = ("local Cmd = import('/lua/editor/gui/commands.lua') local bad = {} "
               "for id in string.gfind('%s', '%%S+') do local ok, err = pcall(Cmd.Run, 'panel.open.' .. id) if not ok then table.insert(bad, id .. ': ' .. tostring(err)) end end "
               "return table.concat(bad, ' | ')") % ' '.join(ids)
        try:
            res = inst.lua(src)
        except RuntimeError as e:
            rep.add('panels', False, 'workspace %s: %s' % (ws, e))
            return
        if res:
            rep.add('panels', False, 'a panel command failed in %s' % ws, res.split(' | '))
            return
        time.sleep(1.0)
    new = inst.log_lines()[before:]
    bad = [l[:220] for l in new if re.search(r'EDITOR gui: .*failed|panel .* failed|attempt to|stack traceback', l)]
    rep.add('panels', not bad, '%d panels opened in %d workspaces, %d errors in the log' % (len(ids), len(names), len(bad)), bad)
    inst.lua("import('/lua/editor/gui/shell.lua').ShowWorkspace('Terrain') return 'ok'")


def step_maps(inst, rep, count):
    """scripts/editor_maps_qa.py on a few real maps (a big one, a small one): open, stroke, undo exactness, save as, reopen and compare."""
    logfile = os.path.join(rep.outdir, 'maps.json') if getattr(rep, 'outdir', None) else None
    cmd = [sys.executable, os.path.join(HERE, 'editor_maps_qa.py'), inst.tag, '--count', str(count)]
    if logfile:
        cmd += ['--json', logfile]
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=dict(os.environ, MSYS_NO_PATHCONV='1'))
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    bad = [l.strip() for l in lines if l.strip().startswith('FAIL')]
    rep.add('maps', p.returncode == 0, lines[-1] if lines else 'no output', bad or lines[-12:])


def step_lint(rep):
    """scripts/editor_lint.py: names used on an imported editor module that the module does not define."""
    p = subprocess.run([sys.executable, os.path.join(HERE, 'editor_lint.py')], capture_output=True, text=True, encoding='utf-8', errors='replace')
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    rep.add('lint', p.returncode == 0, lines[-1] if lines else 'no output', lines[:-1])


def step_clicks(inst, rep):
    """Presses every button of every panel (and of the dialogs they open): handler errors are returned (clicksweep.lua)."""
    ids = inst.lua(PANEL_LUA).split()
    names = inst.lua("return table.concat(import('/lua/editor/gui/workspace.lua').Presets(), ' ')").split()
    # a workspace that offers the panel shows it in its layout; the panels are swept in the workspace that has most of them
    inst.lua("import('/lua/editor/gui/shell.lua').ShowWorkspace('Mission') return 'ok'")
    try:
        inst.lua("return import('/lua/editor/clicksweep.lua').Fixture()")
    except RuntimeError as e:
        rep.add('clicks', False, 'the fixture could not be built: %s' % e)
        return
    errors, pressed = [], 0
    for pid in ids:
        try:
            res = inst.lua("local n, e = import('/lua/editor/clicksweep.lua').Run('%s') return n .. '|' .. table.concat(e, ' @@ ')" % pid, timeout=120)
        except RuntimeError as e:
            errors.append('%s: %s' % (pid, e))
            continue
        n, _, tail = res.partition('|')
        pressed += int(n or 0)
        errors += [t.replace(NL, ' ')[:240] for t in tail.split(' @@ ') if t.strip()]
        # undo what the presses did to the document so the next panel starts from the same map
    inst.lua("import('/lua/editor/gui/shell.lua').ShowWorkspace('Terrain') return 'ok'")
    rep.add('clicks', not errors, '%d buttons pressed in %d panels, %d errors' % (pressed, len(ids), len(errors)), errors)


def step_tips(inst, rep):
    """Every interactive widget, tool, panel tab, workspace button and menu item has a tooltip text (tipcheck.lua)."""
    ids = inst.lua(PANEL_LUA).split()
    inst.lua("import('/lua/editor/gui/shell.lua').ShowWorkspace('Mission') return 'ok'")
    try:
        inst.lua("return import('/lua/editor/clicksweep.lua').Fixture()")
    except RuntimeError as e:
        rep.add('tips', False, 'the fixture could not be built: %s' % e)
        return
    missing, checked = [], 0
    for pid in ids:
        try:
            res = inst.lua("local n, m = import('/lua/editor/tipcheck.lua').Panel('%s') return n .. '|' .. table.concat(m, ' @@ ')" % pid, timeout=120)
        except RuntimeError as e:
            missing.append('%s: %s' % (pid, e))
            continue
        n, _, tail = res.partition('|')
        checked += int(n or 0)
        missing += [t.replace(NL, ' ')[:200] for t in tail.split(' @@ ') if t.strip()]
    for what in ('Dialogs', 'Shell', 'Menus'):
        try:
            res = inst.lua("local n, m = import('/lua/editor/tipcheck.lua').%s() return n .. '|' .. table.concat(m, ' @@ ')" % what, timeout=120)
        except RuntimeError as e:
            missing.append('%s: %s' % (what, e))
            continue
        n, _, tail = res.partition('|')
        checked += int(n or 0)
        missing += [what.lower() + ': ' + t.replace(NL, ' ')[:200] for t in tail.split(' @@ ') if t.strip()]
    for what in ('Tools', 'Panels', 'Workspaces'):
        try:
            res = inst.lua("return table.concat(import('/lua/editor/tipcheck.lua').%s(), ' ')" % what, timeout=60)
        except RuntimeError as e:
            missing.append('%s: %s' % (what, e))
            continue
        missing += ['%s without text: %s' % (what.lower(), t) for t in res.split() if t.strip()]
    inst.lua("import('/lua/editor/gui/shell.lua').ShowWorkspace('Terrain') return 'ok'")
    rep.add('tips', not missing, '%d widgets and menu items checked, %d without a tooltip' % (checked, len(missing)), missing)


# The layout step: window sizes (the engine's window cannot be resized while it runs: the instance is restarted at each size; the shrinking of the dock area that a
# resize causes is exercised in the editor by layoutcheck.Resize) x UI scales. Last size = the default size of the other steps.
LAYOUT_SIZES = ('1920x1080', '1280x720')
LAYOUT_SCALES = (1.0, 1.5, 2.0)
LAYOUT_PANEL_SWEEPS = (('1280x720', 1.5), ('1280x720', 2.0))      # the panels are also pressed through (their dialogs are measured) at these
LAYOUT_PANEL_ALONE = (('1920x1080', 1.0), ('1280x720', 1.5), ('1280x720', 2.0))      # every panel shown on its own at these (the workspaces only show the active tab of a stack)
# Panels that start unit thumbnail rendering (assetthumbs.lua): the engine of this machine crashes in it (access violation in the first frames after the thumbnails, seen in the
# editor log of the layout instance with the plain assets panel and with the unit browser), which would end the run. Their layout is seen in the workspaces that show them.
LAYOUT_SKIP_PANELS = ()
# Panels whose buttons are not pressed here (the `clicks` step does that): their buttons run a long native computation (field engine, erosion, recipes, scatter, the layout canvas); one Lua command
# that keeps the main loop busy for more than 12 s makes the engine's watchdog write a crash report and end the process, which would end the run. The dialogs of the other panels are enough for the layout.
LAYOUT_SKIP_SWEEP = ('fields', 'erosion', 'layoutcanvas', 'recipes', 'scatter')
LAYOUT_QUIET_LUA = "import('/lua/editor/assetthumbs.lua').Pause(true) return import('/lua/editor/clicksweep.lua').Fixture()"      # no thumbnail renders while the layout is measured

# {scale} {fn} {ids} {tag} {long}
LAYOUT_WORKSPACES_LUA = r"""
local LC = import('/lua/editor/layoutcheck.lua')
local out, total = {{}}, 0
for _, ws in import('/lua/editor/gui/workspace.lua').Presets() do
    local n, p = LC.{fn}(ws, {scale})
    total = total + n
    for _, l in p do table.insert(out, l) end
end
import('/lua/editor/gui/skin.lua').SetScale(1.0)
import('/lua/editor/gui/shell.lua').ShowWorkspace('Terrain')
return total .. '|' .. table.concat(out, ' @@ ')
"""

LAYOUT_PANELS_LUA = r"""
local LC = import('/lua/editor/layoutcheck.lua')
import('/lua/editor/gui/skin.lua').SetScale({scale})
import('/lua/editor/gui/shell.lua').ShowWorkspace('Mission')
local out, total = {{}}, 0
for _, id in {{ {ids} }} do
    local n, p = LC.PanelOnly(id, id .. '@{pct}')
    total = total + n
    for _, l in p do table.insert(out, l) end
end
import('/lua/editor/gui/skin.lua').SetScale(1.0)
return total .. '|' .. table.concat(out, ' @@ ')
"""

LAYOUT_PART_LUA = r"""
import('/lua/editor/gui/skin.lua').SetScale({scale})
import('/lua/editor/gui/shell.lua').ShowWorkspace('Mission')
local n, p = import('/lua/editor/layoutcheck.lua').{fn}({arg})
import('/lua/editor/gui/skin.lua').SetScale(1.0)
return n .. '|' .. table.concat(p, ' @@ ')
"""


def step_layout(inst, rep, exe=None, editor=None):
    """No control runs past the area the user sees or over another one, no text is wider than its box (layoutcheck.lua): every workspace, its resized and narrowest docks,
    every panel on its own, the dialogs (also with long text) and the bars, at 1920x1080 and 1280x720 and UI 100 / 150 / 200 %."""
    problems, checked, known = [], 0, []

    def add(label, res):
        nonlocal checked
        n, _, tail = res.partition('|')
        checked += int(n or 0)
        problems.extend('%s %s' % (label, t.replace(NL, ' ')[:260]) for t in tail.split(' @@ ') if t.strip())

    def call(label, src, timeout=300):
        began = time.time()
        try:
            add(label, inst.lua(src, timeout=timeout))
            print('  layout %-34s %5.1f s, %d problems so far' % (label, time.time() - began, len(problems)), flush=True)
        except RuntimeError as e:
            problems.append('%s: %s' % (label, str(e)[:200]))
            if not inst.alive() or 'no answer' in str(e):
                # a dead or hung editor: a fresh one for the rest (the failure above is kept)
                inst.start(exe or 'main_x64_la_p2.exe', editor, size=inst.size)
                try:
                    inst.lua(LAYOUT_QUIET_LUA)
                except RuntimeError:
                    pass

    for size in LAYOUT_SIZES:
        if size != getattr(inst, 'size', None):
            inst.size = size
            inst.start(exe or 'main_x64_la_p2.exe', editor, size=size)
        try:
            inst.lua(LAYOUT_QUIET_LUA)
        except RuntimeError as e:
            problems.append('%s: the fixture could not be built: %s' % (size, e))
            continue
        ids = [i for i in inst.lua(PANEL_LUA).split() if i not in LAYOUT_SKIP_PANELS]
        for scale in LAYOUT_SCALES:
            pct = int(scale * 100)
            tag = '%s@%d' % (size, pct)
            for fn in ('Workspace', 'Resize'):
                call('%s %s' % (tag, fn.lower()), LAYOUT_WORKSPACES_LUA.format(fn=fn, scale=scale))
            # every panel on its own (shown, not pressed), in chunks (a panel that hangs costs its chunk, not the run), then the dialogs and the bars
            if (size, scale) in LAYOUT_PANEL_ALONE:
                for k in range(0, len(ids), 10):
                    call('%s panel' % tag, LAYOUT_PANELS_LUA.format(scale=scale, pct=pct, ids=', '.join("'%s'" % i for i in ids[k:k + 10])), timeout=240)
            for fn, arg, label in (('Dialogs', 'false', 'dialogs'), ('Dialogs', 'true', 'dialogs (long text)'), ('Shell', '', 'bars')):
                call('%s %s' % (tag, label), LAYOUT_PART_LUA.format(scale=scale, fn=fn, arg=arg), timeout=600)
            if (size, scale) in LAYOUT_PANEL_SWEEPS:
                for pid in [i for i in ids if i not in LAYOUT_SKIP_SWEEP]:
                    call('%s sweep %s' % (tag, pid), LAYOUT_PART_LUA.format(scale=scale, fn='Panel', arg="'%s'" % pid), timeout=120)
            # problems of the panels of other groups (layoutcheck.Known) are kept apart
            try:
                tail = inst.lua("return table.concat(import('/lua/editor/layoutcheck.lua').TakeKnown(), ' @@ ')")
                known.extend('%s %s' % (tag, t.replace(NL, ' ')[:240]) for t in tail.split(' @@ ') if t.strip())
            except RuntimeError:
                pass
        inst.lua("import('/lua/editor/gui/skin.lua').SetScale(1.0) import('/lua/editor/gui/shell.lua').ShowWorkspace('Terrain') return 'ok'")
    problems = sorted(set(problems))
    known = sorted(set(known))
    summary = '%d widgets measured, %d problems' % (checked, len(problems))
    if known:
        summary += ', %d more in panels of other groups (known, listed at the end of the details)' % len(known)
    rep.add('layout', not problems, summary, problems + ['KNOWN ' + k for k in known])


MENU_LUA = r"""
local Menu = import('/lua/editor/gui/menu.lua')
local Commands = import('/lua/editor/gui/commands.lua')
import('/lua/editor/gui/menus.lua')
local bad, count = {}, 0
local function Check(where, items, depth)
    for _, it in items do
        if not it.separator then
            count = count + 1
            local title = it.title
            if type(title) == 'function' then local ok, t = pcall(title) title = ok and t or '?' end
            if not title and it.command and Commands.registry[it.command] then title = Commands.registry[it.command].title end
            if it.header then
            elseif it.submenu then
                local sub = it.submenu
                if type(sub) == 'function' then local ok, r = pcall(sub) sub = ok and r or nil end
                if not sub or table.getn(sub) == 0 then
                    if it.enabled == nil then table.insert(bad, where .. ' > ' .. tostring(title) .. ': empty submenu') end
                elseif depth < 4 then Check(where .. ' > ' .. tostring(title), sub, depth + 1) end
            elseif it.command then
                if not Commands.registry[it.command] then table.insert(bad, where .. ' > ' .. tostring(title) .. ': unknown command ' .. it.command) end
            elseif not it.run then
                table.insert(bad, where .. ' > ' .. tostring(title) .. ': no action')
            end
            if not title or title == '' then table.insert(bad, where .. ': an item without a title (' .. tostring(it.command) .. ')') end
        end
    end
end
for _, t in Menu.Titles do Check(t, Menu.Build('menubar.' .. t), 0) end
Check('world', Menu.Build('context.world', { wx = 100, wz = 100, height = 25 }), 0)
Check('marker', Menu.Build('context.object', { kind = 'marker', name = 'ARMY_1' }), 0)
Check('area', Menu.Build('context.object', { kind = 'area', name = 'NONE' }), 0)
return count .. ' items|' .. table.concat(bad, ' || ')
"""


def step_menus(inst, rep):
    try:
        res = inst.lua(MENU_LUA)
    except RuntimeError as e:
        rep.add('menus', False, str(e))
        return
    head, _, tail = res.partition('|')
    bad = [b for b in tail.split(' || ') if b]
    rep.add('menus', not bad, head + ', %d problems' % len(bad), bad)


LOG_BAD = [
    (r'Evaluating LazyVar failed', 'LazyVar warning'),
    (r'EDITOR gui: .*(failed|error)', 'GUI error'),
    (r'EDITOR menu .*failed', 'menu error'),
    (r'attempt to (index|call|perform|compare|concatenate)', 'Lua error'),
    (r'stack traceback', 'Lua traceback'),
    (r'Unable to load texture', 'missing texture'),
    (r'access to nonexistent global', 'global typo'),
    (r'DeviceD3D9\.cpp', 'D3D device error (the editor goes black)'),
]


def step_log(inst, rep):
    counts, samples = {}, {}
    for l in inst.log_lines():
        for pat, label in LOG_BAD:
            if re.search(pat, l):
                counts[label] = counts.get(label, 0) + 1
                samples.setdefault(label, l.strip()[:200])
    details = ['%d x %s: %s' % (n, k, samples[k]) for k, n in sorted(counts.items())]
    rep.add('log', not counts, 'no suspicious lines' if not counts else '%d kinds of suspicious lines' % len(counts), details)


def step_stress(inst, rep, loads, outdir):
    logfile = os.path.join(outdir, 'stress.json')
    cmd = [sys.executable, os.path.join(HERE, 'ed_stress_load.py'), inst.tag, '--loads', str(loads), '--mode', 'full', '--maps', 'mixed', '--log', logfile]
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    tail = [l for l in p.stdout.splitlines() if l.strip()][-8:]
    if p.returncode == 3:
        rep.add('stress', False, 'survived every load, but memory grew past the leak limit (see the trend lines)', tail)
    else:
        rep.add('stress', p.returncode == 0, ('survived every load (all workspaces, graph, link, pop-outs, play tests)' if p.returncode == 0 else 'the editor died or a load never finished (exit %d)' % p.returncode), tail)


def step_selfloop(inst, rep, runs):
    """Runs right after the selftests step (which leaves the standard blank map open: the tests assume it, and the maps step leaves a 65-sample map behind). Every self test several times in one process in random order: order dependence and shared state show up as failures that a single run hides."""
    cmd = [sys.executable, os.path.join(HERE, 'editor_selftest_loop.py'), inst.tag, '--runs', str(runs), '--fresh', '0', '--shuffle']
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    # the failing tests with their FAIL lines (the per-test table is long), then the run lines and the order of the first failing run
    tail = [l for i, l in enumerate(lines) if '<-- fails' in l or l.startswith('run ') and 'all ok' not in l or l.startswith('fresh') and 'all ok' not in l or l.startswith('order of') or (i > 0 and '<-- fails' in lines[i - 1])]
    tail = tail or lines[-8:]
    rep.add('selfloop', p.returncode == 0, ('%d shuffled runs without a failure' % runs if p.returncode == 0 else 'a self test failed in the loop (exit %d)' % p.returncode), tail)


def step_simstress(inst, rep, cycles):
    """Play tests with timers / waits / spawns / sim callbacks, left in five ways; the process and the crash folder are checked every cycle."""
    cmd = [sys.executable, os.path.join(HERE, 'editor_sim_stress.py'), inst.tag, '--cycles', str(cycles), '--seed', str(int(time.time()) % 1000)]
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    tail = [l for l in p.stdout.splitlines() if l.strip()][-8:]
    rep.add('simstress', p.returncode == 0, ('%d play cycles survived' % cycles if p.returncode == 0 else 'a play cycle failed (exit %d)' % p.returncode), tail)


# ---- perf: frame cost budgets ----------------------------------------------------------------------------------------------------------------
# Budgets of the `perf` step (docs/projects/editor/PERFORMANCE.md, "Frame cost budgets"): measured on the stress document with the camera zoomed in (the worst case for the name labels),
# about 4x the measured value so that a slower machine passes, and far below what the code cost before the frame cost work (shown in brackets).
PERF_BUDGETS = {
    'frame_tick_avg_ms': 1.5,     # `ui: frame tick (all)`, average ms per frame (measured 0.4 to 0.5; before 4.4)
    'labels_avg_ms': 0.6,         # `overlay: labels`, average ms per frame (measured 0.1 to 0.2; before 3.2)
    'worst_frame_ms': 30.0,       # the slowest ui tick in the sampled reports (measured 3 to 9; before 85 to 95); above ~30 ms is a visible hitch
    'heap_growth_mb': 6.0,        # Lua heap after a full collection at the end minus at the start of the sampled period
}
PERF_STRESS_LUA = r"""
local PS = import('/lua/editor/perfstress.lua')
local made = PS.Build({ markers = 3000, areas = 40, units = 150 })
import('/lua/editor/camera.lua').FocusOn(512, 512, 300)
return made
"""
PERF_ON_LUA = r"""
local P = import('/lua/editor/perf.lua')
P.Set(false)
P.Set(true)
collectgarbage(0) collectgarbage(0)
return tostring(gcinfo())
"""
PERF_STATE_LUA = "return tostring(import('/lua/editor/validate.lua').State)"
PERF_HEAP_LUA = r"""
collectgarbage(0) collectgarbage(0)
return tostring(gcinfo())
"""


def parse_perf_reports(lines):
    """The 'EDITOR perf:' reports of a log: a list of { 'fps': n, 'sections': { name: { 'avg': ms per call, 'max': ms } } }."""
    reports, cur = [], None
    for l in lines:
        if 'EDITOR perf: ' not in l:
            continue
        t = l.split('EDITOR perf: ', 1)[1]
        m = re.match(r'--- [\d.]+ s, (\d+) frames/s ---', t)
        if m:
            cur = { 'fps': int(m.group(1)), 'sections': {} }
            reports.append(cur)
            continue
        m = re.match(r'(.+?)\s+([\d.]+) ms/s\s+(\d+) calls\s+avg\s+([\d.]+)\s+max\s+([\d.]+)', t)
        if m and cur is not None:
            cur['sections'][m.group(1).strip()] = { 'avg': float(m.group(4)), 'max': float(m.group(5)), 'calls': int(m.group(3)) }
    return reports


def step_perf(inst, rep, exe, seconds=28):
    """Frame cost on a stress document: the Lua time per frame of the ui tick and the name labels, the slowest tick and the heap growth against PERF_BUDGETS."""
    # a clean 1024 map (the stress document is 3000 markers on it; the 257 map of the other steps would pack them into a knot)
    with contextlib.redirect_stdout(io.StringIO()):
        EI.cmd_start(argparse.Namespace(tag=inst.tag, map='editor_blank_1024', exe=exe, wait=90))
    made = inst.lua(PERF_STRESS_LUA, timeout=120)
    # the one-off costs are not sampled: making the objects, and laying the footprints of the resource markers again when the validation (which runs by itself a moment after the
    # markers appeared and finds problems with the random placement) is done
    deadline = time.time() + 90
    time.sleep(6)
    while time.time() < deadline and inst.lua(PERF_STATE_LUA, timeout=30) != 'done':
        time.sleep(2)
    inst.lua("import('/lua/editor/terrainepoch.lua').Touch()", timeout=30)          # the overlay lays everything onto the ground again now (and not by its 90 s net in the middle of the sample)
    time.sleep(4)
    n0 = len(inst.log_lines())
    heap0 = float(inst.lua(PERF_ON_LUA, timeout=60))
    time.sleep(seconds)
    perf_lines = [l for l in inst.log_lines()[n0:] if 'EDITOR perf: ' in l]
    if getattr(rep, 'outdir', None):
        open(os.path.join(rep.outdir, 'perf_reports.txt'), 'w', encoding='utf-8').write(NL.join(perf_lines))      # the raw reports, for the section that went over
    reports = parse_perf_reports(perf_lines)
    heap1 = float(inst.lua(PERF_HEAP_LUA, timeout=60))
    inst.lua("import('/lua/editor/perf.lua').Set(false) import('/lua/editor/perfstress.lua').Remove()", timeout=60)
    sampled = [r for r in reports if r['sections'].get('ui: frame tick (all)')]
    if len(sampled) < 3:
        rep.add('perf', False, 'only %d perf reports in %d s (the editor did not draw frames?)' % (len(sampled), seconds), ['stress: %s' % made])
        return
    def avg(name):
        vals = [r['sections'][name]['avg'] for r in sampled if name in r['sections']]
        return sum(vals) / len(vals) if vals else 0.0
    tick, labels = avg('ui: frame tick (all)'), avg('overlay: labels')
    worst = max(r['sections']['ui: frame tick (all)']['max'] for r in sampled)
    growth = (heap1 - heap0) / 1024.0
    fps = sum(r['fps'] for r in sampled) / len(sampled)
    B = PERF_BUDGETS
    checks = [
        ('ui frame tick avg %.2f ms/frame' % tick, tick <= B['frame_tick_avg_ms'], B['frame_tick_avg_ms']),
        ('name labels avg %.2f ms/frame' % labels, labels <= B['labels_avg_ms'], B['labels_avg_ms']),
        ('slowest ui tick %.1f ms' % worst, worst <= B['worst_frame_ms'], B['worst_frame_ms']),
        ('Lua heap growth %.1f MB' % growth, growth <= B['heap_growth_mb'], B['heap_growth_mb']),
    ]
    bad = [c for c in checks if not c[1]]
    details = ['%s %s budget %s' % (('ok  ' if ok else 'FAIL'), text, limit) for text, ok, limit in checks]
    if bad:
        # the sections of the slowest sampled report: where the time went
        slow = max(sampled, key=lambda r: r['sections']['ui: frame tick (all)']['max'])
        top = sorted(slow['sections'].items(), key=lambda kv: -kv[1]['max'])[:6]
        details.append('slowest report, sections by worst call: ' + '; '.join('%s max %.1f ms avg %.3f' % (k, v['max'], v['avg']) for k, v in top))
    details.append('stress: %s; %d reports, %.0f frames/s (not gated: the GPU and vsync decide it)' % (made, len(sampled), fps))
    rep.add('perf', not bad, '%s' % ('within budget: ' + ', '.join(c[0] for c in checks) if not bad else 'over budget: ' + ', '.join(c[0] for c in bad)), details)
    inst.start(exe)                               # the other steps want the usual blank document



def step_missionsim(inst, rep, exe=None):
    """Missions covering every node type are played in the real sim (scripts/editor_mission_sim.py): triggers fire, objectives complete, stages advance, the operation ends."""
    inst.start(exe)               # the cases build their own world on the usual blank document (the steps before left a real map open, without the armies and unit tables the cases extend)
    cmd = [sys.executable, os.path.join(HERE, 'editor_mission_sim.py'), inst.tag]
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    tail = [l for l in lines if 'PASS' in l or 'FAIL' in l or l.startswith('  ') or 'cases passed' in l][-24:]
    rep.add('missionsim', p.returncode == 0, ('every mission case ran to its end in the sim' if p.returncode == 0 else 'a mission case failed in the sim (exit %d)' % p.returncode), tail)


def write_report(rep, outdir, tag, exe, seconds):
    ok = all(s['ok'] for s in rep.steps)
    json.dump({ 'tag': tag, 'exe': exe, 'seconds': round(seconds), 'ok': ok, 'steps': rep.steps }, open(os.path.join(outdir, 'report.json'), 'w'), indent=1)
    lines = ['# FAF Studio nightly: %s' % ('PASS' if ok else 'FAIL'), '', 'instance `%s`, exe `%s`, %d s' % (tag, exe, seconds), '', '| step | result | summary |', '|---|---|---|']
    for s in rep.steps:
        lines.append('| %s | %s | %s |' % (s['name'], 'pass' if s['ok'] else '**FAIL**', s['summary'].replace('|', '/')))
    for s in rep.steps:
        if s['details']:
            lines += ['', '## ' + s['name'], ''] + ['    ' + d for d in s['details']]
    open(os.path.join(outdir, 'report.md'), 'w', encoding='utf-8').write(NL.join(lines) + NL)
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tag', default='nightly')
    ap.add_argument('--editor', help='Lua tree to run (default: this checkout editor/runtime)')
    ap.add_argument('--exe', default='main_x64_la_p2.exe')
    ap.add_argument('--loads', type=int, default=12, help='map loads of the stress step (3 modes in turn)')
    ap.add_argument('--loop-runs', type=int, default=3, help='shuffled runs of every self test (selfloop step)')
    ap.add_argument('--sim-cycles', type=int, default=6, help='play test cycles of the simstress step')
    ap.add_argument('--maps', type=int, default=3, help='maps of the lifecycle step (half big, half small)')
    ap.add_argument('--skip', default='', help='comma list of steps to leave out: lint, selftests, selfloop, panels, menus, clicks, tips, workspaces, log, maps, layout, missionsim, simstress, stress, perf')
    ap.add_argument('--out')
    ap.add_argument('--keep', action='store_true', help='leave the instance running at the end')
    a = ap.parse_args()
    skip = set(a.skip.split(','))
    started = time.time()
    inst = Inst(a.tag)
    stamp = time.strftime('%Y%m%d_%H%M%S')
    outdir = a.out or os.path.join(EI.runs_dir(), a.tag, 'nightly', stamp)
    os.makedirs(outdir, exist_ok=True)
    rep = Report()
    rep.outdir = outdir
    try:
        editor = a.editor or os.path.join(EI.ROOT, 'editor', 'runtime')
        inst.start(a.exe, editor)
    except BaseException as e:  # noqa: BLE001
        print('setup failed: %s' % e)
        return 2
    steps = [
        ('lint', lambda: step_lint(rep)),
        ('selftests', lambda: step_selftests(inst, rep, a.exe, None)),
        ('selfloop', lambda: step_selfloop(inst, rep, a.loop_runs)),
        ('panels', lambda: step_panels(inst, rep)),
        ('menus', lambda: step_menus(inst, rep)),
        ('clicks', lambda: step_clicks(inst, rep)),
        ('tips', lambda: step_tips(inst, rep)),
        ('workspaces', lambda: step_workspaces(inst, rep, outdir)),
        ('layout', lambda: step_layout(inst, rep, a.exe, editor)),
        ('log', lambda: step_log(inst, rep)),
        ('maps', lambda: step_maps(inst, rep, a.maps)),
        ('missionsim', lambda: step_missionsim(inst, rep, a.exe)),
        ('simstress', lambda: step_simstress(inst, rep, a.sim_cycles)),
        ('stress', lambda: step_stress(inst, rep, a.loads, outdir)),
        ('perf', lambda: step_perf(inst, rep, a.exe)),
    ]
    for name, fn in steps:
        if name in skip:
            continue
        try:
            fn()
        except BaseException as e:  # noqa: BLE001
            rep.add(name, False, 'the step itself broke: %s' % e)
            if not inst.alive():
                try:
                    inst.start(a.exe)
                except BaseException:  # noqa: BLE001
                    break
    ok = write_report(rep, outdir, a.tag, a.exe, time.time() - started)
    print('report: %s' % os.path.join(outdir, 'report.md'))
    if not a.keep:
        with contextlib.redirect_stdout(io.StringIO()):
            EI.cmd_stop(argparse.Namespace(tag=a.tag))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
