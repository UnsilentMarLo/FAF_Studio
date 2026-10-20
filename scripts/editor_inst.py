#!/usr/bin/env python
"""Isolated editor test instances, so several sessions (or worktrees) can run the FAF Studio engine at the same time.

An instance <tag> lives in .runs/<tag>/ (studio_paths.RUNS):
    bin/        hard links of the engine files (exe, dlls, init_faf.lua) + its own state (editor_mods.txt, crash files, config/, workspaces/)
    editor      junction to the Lua sources it runs (default: <this checkout>/editor/runtime, so a worktree tests its own code)
    mapout/ modproj/   its own saved test maps and mod projects
    run.log  edcmd.lua(.out)   its own log and command channel
    pid.txt     the process it started: stop / restart only ever touch that PID

    python scripts/editor_inst.py new <tag> [--editor PATH]    create (or re-point) the instance
    python scripts/editor_inst.py start <tag> [--map NAME] [--exe NAME] [--wait N] [--keep-userdata] [--nomap] [--extra ARGS...]    start it (restarts it when it runs); prints the pid
    python scripts/editor_inst.py cmd <tag> <file.lua> [--timeout S]      run a Lua chunk in the editor (UI state), print its result
    python scripts/editor_inst.py shot <tag> <out.png> [--crop x0,y0,x1,y1]  screenshot of that instance's window
    python scripts/editor_inst.py focus <tag>                   wake an idle window (a click on its title bar); `cmd` does it by itself once after 6 s of silence
    python scripts/editor_inst.py stop <tag>                    stop that instance only
    python scripts/editor_inst.py list                          instances and whether they run
    python scripts/editor_inst.py selftests <tag> [--keep]        run every selftest_* of the Lua tree that has a Run() and report, then restart the editor (clean document) unless --keep

Never kills by process name. Needs Windows (junctions, ctypes). See docs/EDITOR_PARALLEL.md.
"""
import argparse
import ctypes
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_paths as P

ROOT = P.ROOT                                                 # the checkout this script belongs to
main_checkout = lambda: P.MAIN                                # the first worktree: the staged engine and the instances are shared by all worktrees


def runs_dir():
    return P.RUNS


def inst_dir(tag):
    return os.path.join(P.RUNS, tag)


def base_bin():
    return P.need(P.ENGINE_BIN, 'the staged engine', 'build and stage it: python scripts/studio.py engine setup / build / stage')


IMMUTABLE_EXT = ('.exe', '.dll')
IMMUTABLE_NAMES = ('init_faf.lua', 'SupComDataPath.lua')


def junction(link, target):
    if os.path.lexists(link):
        subprocess.run(['cmd', '/c', 'rmdir', os.path.normpath(link)], capture_output=True)
    r = subprocess.run(['cmd', '/c', 'mklink', '/J', os.path.normpath(link), os.path.normpath(target)], capture_output=True)
    if r.returncode != 0:
        raise SystemExit('junction failed: ' + (r.stdout or b'').decode('cp850', 'replace') + (r.stderr or b'').decode('cp850', 'replace'))


def cmd_new(a):
    d = inst_dir(a.tag)
    os.makedirs(os.path.join(d, 'bin'), exist_ok=True)
    for sub in ('mapout', 'modproj'):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    # engine files: hard links (same volume); rebuilt exes are refreshed by `start`
    for name in os.listdir(base_bin()):
        src = os.path.join(base_bin(), name)
        if os.path.isfile(src) and (name.lower().endswith(IMMUTABLE_EXT) or name in IMMUTABLE_NAMES):
            dst = os.path.join(d, 'bin', name)
            if not os.path.exists(dst):
                os.link(src, dst)
    shutil.copyfile(os.path.join(P.ENGINE_RUN, 'fa_path.lua'), os.path.join(d, 'fa_path.lua'))       # read by init_faf.lua as ../fa_path.lua
    os.makedirs(os.path.join(d, 'bin', 'config'), exist_ok=True)
    os.makedirs(os.path.join(d, 'bin', 'workspaces'), exist_ok=True)
    # the shared game data of the FAF install (read only)
    faf = P.FAF_DATA
    for name in ('cache', 'gamedata', 'movies', 'sounds', 'themes'):
        link = os.path.join(d, name)
        target = os.path.join(faf, name)
        if not os.path.lexists(link) and os.path.exists(target):
            junction(link, target)
    editor = os.path.abspath(a.editor or os.path.join(ROOT, 'editor', 'runtime'))
    junction(os.path.join(d, 'editor'), editor)
    for f in ('editor_mods.txt', 'editor_mods_trial.txt'):
        p = os.path.join(d, 'bin', f)
        if not os.path.exists(p):
            open(p, 'w').close()
    print('instance', a.tag, 'at', d, 'runs', editor)


def read_pid(tag):
    try:
        return int(open(os.path.join(inst_dir(tag), 'pid.txt')).read().strip())
    except Exception:
        return None


def alive(pid):
    if not pid:
        return False
    out = subprocess.run(['tasklist', '/FI', 'PID eq %d' % pid, '/FO', 'CSV', '/NH'], capture_output=True, text=True, errors='replace').stdout
    return ('"%d"' % pid) in out


def cmd_stop(a):
    pid = read_pid(a.tag)
    if alive(pid):
        subprocess.run(['taskkill', '/PID', str(pid), '/F'], capture_output=True)
        print('stopped', a.tag, pid)
    else:
        print(a.tag, 'is not running')


def refresh_engine(d, exe):
    src = os.path.join(base_bin(), exe)
    dst = os.path.join(d, 'bin', exe)
    if not os.path.exists(src):
        raise SystemExit('no ' + src)
    if os.path.exists(dst) and os.stat(dst).st_ino == os.stat(src).st_ino:
        return
    if os.path.exists(dst):
        os.remove(dst)
    os.link(src, dst)


def dpi_env():
    """Environment for the engine process. The editor must run DPI aware: otherwise Windows draws it at 96 dpi and stretches the window to the display scale (125 % = every
    edge and glyph resampled, text blurry; measured in screenshots: a 90 px button is 112.5 px wide). `__COMPAT_LAYER=HighDpiAware` makes the process DPI aware without a manifest
    change. The UI scale then has to follow the display scale: FAFSTUDIO_UISCALE (read by init_editor.lua) is the first-run UI scale. FAFSTUDIO_DPI=0 turns this off."""
    env = dict(os.environ)
    if sys.platform != 'win32' or env.get('FAFSTUDIO_DPI') == '0':
        return env
    layer = env.get('__COMPAT_LAYER', '')
    if 'HighDpiAware' not in layer:
        env['__COMPAT_LAYER'] = (layer + ' HighDpiAware').strip()
    try:
        import winreg
        dpi = 96
        for sub, name in (('Control Panel\\Desktop\\WindowMetrics', 'AppliedDPI'), ('Control Panel\\Desktop', 'LogPixels')):
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, sub) as k:
                    dpi = int(winreg.QueryValueEx(k, name)[0])
                    break
            except OSError:
                continue
        scale = max(1.0, min(3.0, round(dpi / 96.0 * 4) / 4))     # the UI scale buttons step by 0.25
        env.setdefault('FAFSTUDIO_UISCALE', '%.2f' % scale)
    except Exception:
        pass
    return env


def cmd_start(a):
    d = inst_dir(a.tag)
    if not os.path.isdir(d):
        cmd_new(argparse.Namespace(tag=a.tag, editor=None))
    pid = read_pid(a.tag)
    if alive(pid):
        subprocess.run(['taskkill', '/PID', str(pid), '/F'], capture_output=True)
        time.sleep(2)
    exe = a.exe
    refresh_engine(d, exe)
    # init_editor.lua comes from the Lua tree the instance runs
    editor = os.path.realpath(os.path.join(d, 'editor'))
    # generated, untracked content of the tree (git-ignored: blank map, brush masks, marker / cursor textures): a worktree gets it from the main checkout
    for rel in ('maps', 'brushes', os.path.join('override', 'textures')):
        main_dir = os.path.join(main_checkout(), 'editor', 'runtime', rel)
        if os.path.isdir(main_dir) and not os.path.isdir(os.path.join(editor, rel)):
            shutil.copytree(main_dir, os.path.join(editor, rel))
            print('copied the generated %s/ into %s' % (rel.replace(os.sep, '/'), editor))
            # (a worktree's .gitignore may not list it yet: keep it out of commits through the shared exclude file)
            exclude = os.path.join(main_checkout(), '.git', 'info', 'exclude')
            entry = 'editor/runtime/%s/' % rel.replace(os.sep, '/')
            try:
                text = open(exclude).read() if os.path.exists(exclude) else ''
                if entry not in text:
                    os.makedirs(os.path.dirname(exclude), exist_ok=True)
                    open(exclude, 'a').write(('' if text.endswith('\n') or not text else '\n') + entry + '\n')
            except OSError:
                pass
    shutil.copyfile(os.path.join(editor, 'init_editor.lua'), os.path.join(d, 'bin', 'init_editor.lua'))
    log = os.path.join(d, 'run.log')
    if os.path.exists(log):
        os.remove(log)
    cmdfile = os.path.join(d, 'edcmd.lua')
    # the editor remembers layouts, UI scale, brush ... in <bin>/userdata: a test starts from the defaults unless it asks to keep them
    if not getattr(a, 'keep_userdata', False):
        shutil.rmtree(os.path.join(d, 'bin', 'userdata'), ignore_errors=True)
    open(cmdfile, 'w').write('return "ready"\n-- start %d\n' % time.time_ns())
    args = [os.path.join(d, 'bin', exe), '/init', 'init_editor.lua', '/log', log, '/nomovie', '/nosound', '/windowed'] + getattr(a, 'size', '1280x720').split('x') + [
            '/editor'] + ([] if getattr(a, 'nomap', False) else ['/map', a.map]) + ['/edcmd', cmdfile] + list(getattr(a, 'extra', None) or [])
    p = subprocess.Popen(args, cwd=os.path.join(d, 'bin'), env=dpi_env())
    open(os.path.join(d, 'pid.txt'), 'w').write(str(p.pid))
    open(os.path.join(d, 'start_args.txt'), 'w').write(a.map + chr(10) + exe + chr(10))     # what `selftests` restarts with
    print('started', a.tag, p.pid)
    deadline = time.time() + a.wait
    out = cmdfile + '.out'
    while time.time() < deadline:
        if os.path.exists(out) and os.path.getmtime(out) > os.path.getmtime(cmdfile) - 1 and open(out).read().strip():
            print('ready:', open(out).read().strip())
            return
        time.sleep(1)
    print('no answer from the command channel after', a.wait, 's (the window may be idle: use focus)')


def user32():
    return ctypes.windll.user32


def window_of(pid):
    u = user32()
    found = []
    EnumProc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    def cb(h, _):
        p = ctypes.c_ulong()
        u.GetWindowThreadProcessId(h, ctypes.byref(p))
        if p.value == pid and u.IsWindowVisible(h) and u.GetWindowTextLengthW(h) > 0:
            found.append(h)
        return True
    u.EnumWindows(EnumProc(cb), 0)
    return found[0] if found else None


class RECT(ctypes.Structure):
    _fields_ = [('l', ctypes.c_long), ('t', ctypes.c_long), ('r', ctypes.c_long), ('b', ctypes.c_long)]


class POINT(ctypes.Structure):
    _fields_ = [('x', ctypes.c_long), ('y', ctypes.c_long)]


def cmd_focus(a):
    pid = read_pid(a.tag)
    h = window_of(pid) if alive(pid) else None
    if not h:
        print('no window for', a.tag)
        return
    u = user32()
    if u.IsIconic(h):
        u.ShowWindow(h, 9)
        time.sleep(0.5)
    # SwitchToThisWindow raises the window whatever covers it; the title-bar click below only works when nothing else sits at that spot
    u.SwitchToThisWindow(h, True)
    time.sleep(0.3)
    r = RECT()
    u.GetWindowRect(h, ctypes.byref(r))
    old = POINT()
    u.GetCursorPos(ctypes.byref(old))
    u.SetCursorPos((r.l + r.r) // 2, r.t + 12)
    time.sleep(0.12)
    u.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.06)
    u.mouse_event(0x0004, 0, 0, 0, 0)
    u.SetCursorPos(old.x, old.y)
    print('focused', a.tag)


def cmd_cmd(a):
    d = inst_dir(a.tag)
    src = open(a.file, encoding='utf-8').read()
    cmdfile = os.path.join(d, 'edcmd.lua')
    out = cmdfile + '.out'
    before = os.path.getmtime(out) if os.path.exists(out) else 0
    open(cmdfile, 'w', encoding='utf-8').write(src + '\n-- run %d\n' % time.time_ns())
    start = time.time()
    deadline = start + a.timeout
    woke = False
    while time.time() < deadline:
        if os.path.exists(out) and os.path.getmtime(out) > before:
            time.sleep(0.15)
            print(open(out, encoding='utf-8', errors='replace').read()[:a.chars].rstrip())
            return
        # an idle window (not the active application, e.g. while other instances run) answers after a click on its title bar: do it once, after a few quiet seconds
        if not woke and time.time() - start > 6:
            woke = True
            cmd_focus(argparse.Namespace(tag=a.tag))
        time.sleep(0.3)
    print('TIMEOUT: no answer (window idle? try: focus %s)' % a.tag)
    sys.exit(2)


def cmd_shot(a):
    pid = read_pid(a.tag)
    args = [sys.executable, os.path.join(ROOT, 'editor', 'textlab', 'shot.py'), a.out, '--pid', str(pid)]
    if a.crop:
        args += ['--crop', a.crop]
    subprocess.run(args)


def cmd_list(a):
    base = runs_dir()
    if not os.path.isdir(base):
        print('no instances')
        return
    for tag in sorted(os.listdir(base)):
        pid = read_pid(tag)
        editor = os.path.realpath(os.path.join(base, tag, 'editor')) if os.path.lexists(os.path.join(base, tag, 'editor')) else '?'
        print('%-16s %-8s pid %-7s %s' % (tag, 'RUNNING' if alive(pid) else 'stopped', pid, editor))


SELFTEST_SCRIPT = r"""
local out = {}
for _, name in { 'selftest_terrain', 'selftest_cmd', 'selftest_mission', 'selftest_qa', 'selftest_modproj' } do
    local good, mod = pcall(import, '/lua/editor/' .. name .. '.lua')
    local run = good and mod and rawget(mod, 'Run')
    if run then
        local g2, res = pcall(run)
        local text = g2 and tostring(res) or ('ERROR ' .. tostring(res))
        local nl = string.find(text, '\n', 1, true)
        local first = string.sub(text, 1, nl and (nl - 1) or 80)
        local fails = 0
        for _ in string.gfind(text, 'FAIL') do fails = fails + 1 end
        table.insert(out, name .. ': ' .. first .. ' (' .. fails .. ' FAIL lines)')
    else
        table.insert(out, name .. ': not in this tree')
    end
end
return table.concat(out, '\n')
"""


def extra_selftests(tag):
    """Self tests a feature branch registers in editor/runtime/lua/editor/selftests.extra (one name per line; .gitattributes merges that file
    as a union, so branches do not collide on the list in SELFTEST_SCRIPT). -> names that SELFTEST_SCRIPT does not list already."""
    path = os.path.join(inst_dir(tag), 'editor', 'lua', 'editor', 'selftests.extra')
    if not os.path.isfile(path):
        return []
    listed = re.findall(r"'(selftest_\w+)'", SELFTEST_SCRIPT)
    names = []
    for line in open(path).read().split():
        if line.startswith('selftest_') and line not in listed and line not in names:
            names.append(line)
    return names


def cmd_selftests(a):
    tmp = os.path.join(inst_dir(a.tag), 'selftests.lua')
    open(tmp, 'w').write(SELFTEST_SCRIPT)
    cmd_cmd(argparse.Namespace(tag=a.tag, file=tmp, timeout=120, chars=4000))
    extra = extra_selftests(a.tag)
    if extra:
        script = re.sub(r"for _, name in \{[^}]*\} do", "for _, name in { " + ", ".join("'%s'" % n for n in extra) + " } do", SELFTEST_SCRIPT)
        open(tmp, 'w').write(script)
        cmd_cmd(argparse.Namespace(tag=a.tag, file=tmp, timeout=120, chars=4000))
    # the tests leave their fixtures in the live document (areas, markers, units of selftest_mission): start from a clean document again
    if not getattr(a, 'keep', False):
        saved = os.path.join(inst_dir(a.tag), 'start_args.txt')
        m, e = (open(saved).read().split() + ['', ''])[:2] if os.path.isfile(saved) else ('', '')
        cmd_start(argparse.Namespace(tag=a.tag, map=m or 'editor_blank', exe=e or 'main_x64_la_p2.exe', wait=60))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='c', required=True)
    p = sub.add_parser('new'); p.add_argument('tag'); p.add_argument('--editor'); p.set_defaults(f=cmd_new)
    p = sub.add_parser('start'); p.add_argument('tag'); p.add_argument('--map', default='editor_blank'); p.add_argument('--exe', default='main_x64_la_p2.exe')
    p.add_argument('--wait', type=int, default=60)
    p.add_argument('--keep-userdata', action='store_true', help='keep <bin>/userdata (layouts, settings) of the instance; the default starts from a clean user folder')
    p.add_argument('--nomap', action='store_true', help='no /map argument: the editor shows its start screen')
    p.add_argument('--size', default='1280x720', help='window size WxH (default 1280x720)')
    p.add_argument('--extra', nargs=argparse.REMAINDER, default=[], help='further engine arguments, e.g. --extra /eduser C:/tmp/u')
    p.set_defaults(f=cmd_start)
    p = sub.add_parser('stop'); p.add_argument('tag'); p.set_defaults(f=cmd_stop)
    p = sub.add_parser('focus'); p.add_argument('tag'); p.set_defaults(f=cmd_focus)
    p = sub.add_parser('cmd'); p.add_argument('tag'); p.add_argument('file'); p.add_argument('--timeout', type=int, default=60); p.add_argument('--chars', type=int, default=1500); p.set_defaults(f=cmd_cmd)
    p = sub.add_parser('shot'); p.add_argument('tag'); p.add_argument('out'); p.add_argument('--crop'); p.set_defaults(f=cmd_shot)
    p = sub.add_parser('list'); p.set_defaults(f=cmd_list)
    p = sub.add_parser('selftests'); p.add_argument('tag'); p.add_argument('--keep', action='store_true', help='leave the editor running with the test fixtures in the document'); p.set_defaults(f=cmd_selftests)
    a = ap.parse_args()
    a.f(a)


if __name__ == '__main__':
    main()
