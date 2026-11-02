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
  layout      layoutcheck.lua: no button, slider or field runs past the edge of its panel, no two overlap, no button text is wider than its button; every workspace at
              UI 100 % and 150 % at the instance's window size, and every panel on its own
  log         the editor log after all of it: LazyVar warnings, "failed" lines of the GUI, Lua errors, missing textures
  maps        scripts/editor_maps_qa.py: a big and a small real map are opened, edited, undone exactly, saved as and reopened (checksums, counts)
  selfloop    scripts/editor_selftest_loop.py: every self test N times in one process, shuffled (order dependence, shared state)
  simstress   scripts/editor_sim_stress.py: play tests with timers / waits / spawns / sim callbacks, left five ways, process + crash folder checked
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
    problems, checked = [], 0

    def add(label, res):
        nonlocal checked
        n, _, tail = res.partition('|')
        checked += int(n or 0)
        problems.extend('%s %s' % (label, t.replace(NL, ' ')[:260]) for t in tail.split(' @@ ') if t.strip())

    def call(label, src, timeout=300):
        try:
            add(label, inst.lua(src, timeout=timeout))
        except RuntimeError as e:
            problems.append('%s: %s' % (label, str(e)[:200]))
            if not inst.alive() or 'no answer' in str(e):
                # a dead or hung editor: a fresh one for the rest (the failure above is kept)
                inst.start(exe or 'main_x64_la_p2.exe', editor, size=inst.size)
                try:
                    inst.lua("return import('/lua/editor/clicksweep.lua').Fixture()")
                except RuntimeError:
                    pass

    for size in LAYOUT_SIZES:
        if size != getattr(inst, 'size', None):
            inst.size = size
            inst.start(exe or 'main_x64_la_p2.exe', editor, size=size)
        try:
            inst.lua("return import('/lua/editor/clicksweep.lua').Fixture()")
        except RuntimeError as e:
            problems.append('%s: the fixture could not be built: %s' % (size, e))
            continue
        ids = inst.lua(PANEL_LUA).split()
        for scale in LAYOUT_SCALES:
            pct = int(scale * 100)
            tag = '%s@%d' % (size, pct)
            for fn in ('Workspace', 'Resize'):
                call('%s %s' % (tag, fn.lower()), LAYOUT_WORKSPACES_LUA.format(fn=fn, scale=scale))
            # every panel on its own (shown, not pressed), then the dialogs and the bars
            call('%s panel' % tag, LAYOUT_PANELS_LUA.format(scale=scale, pct=pct, ids=', '.join("'%s'" % i for i in ids)), timeout=600)
            for fn, arg, label in (('Dialogs', 'false', 'dialogs'), ('Dialogs', 'true', 'dialogs (long text)'), ('Shell', '', 'bars')):
                call('%s %s' % (tag, label), LAYOUT_PART_LUA.format(scale=scale, fn=fn, arg=arg), timeout=600)
            if (size, scale) in LAYOUT_PANEL_SWEEPS:
                for pid in ids:
                    call('%s sweep' % tag, LAYOUT_PART_LUA.format(scale=scale, fn='Panel', arg="'%s'" % pid), timeout=120)
        inst.lua("import('/lua/editor/gui/skin.lua').SetScale(1.0) import('/lua/editor/gui/shell.lua').ShowWorkspace('Terrain') return 'ok'")
    rep.add('layout', not problems, '%d widgets measured, %d problems' % (checked, len(problems)), sorted(set(problems)))


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
    ap.add_argument('--skip', default='', help='comma list of steps to leave out: lint, selftests, selfloop, panels, menus, clicks, tips, workspaces, log, maps, simstress, stress')
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
        ('simstress', lambda: step_simstress(inst, rep, a.sim_cycles)),
        ('stress', lambda: step_stress(inst, rep, a.loads, outdir)),
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
