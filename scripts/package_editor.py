#!/usr/bin/env python
"""Assembles FAF Studio into a folder (and a zip) that runs on another machine that has Forged Alliance and the FAForever client installed.

    python scripts/package_editor.py [--out dist] [--version X.Y.Z] [--exe FAFStudio.exe] [--no-zip] [--test]

What goes in (see docs/projects/editor/PACKAGING.md):
    bin/        FAFStudio.exe, the DLLs it imports (found by reading its import table), init_editor.lua
    editor/     the editor's Lua tree, shaders, brushes, icons, blank maps (this checkout, generated parts from the main checkout when a worktree lacks them)
    docs/       help topics, PACKAGING.md        tools/ pack_map.py        samples/ sample map and graph notes
    README.txt, CHANGELOG.txt (from git), VERSION.txt, MANIFEST.txt (sha256 of every file)
What stays out: all game data (the exe links the user's FAForever folders when it starts), init_faf.lua / SupComDataPath.lua / fa_path.lua (copied from the FAForever install at every start),
self tests and their data, anything outside the editor.

--test unpacks a copy into a folder with a space in its name and double-clicks it, in effect: bin/FAFStudio.exe without any argument but the command channel, from another
working folder, with a throw-away user folder (once without a map: the start screen must come up; once with /map) and checks version, user folder, logs and links. It runs a real editor window for a minute.
The package is never committed: dist/ is ignored by git, and the exe stays the user's to distribute (docs/projects/editor/PACKAGING.md).
"""
import argparse
import datetime
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


# ---- helpers -------------------------------------------------------------------------------------------------------------------------------

def git(*args, cwd=ROOT):
    r = subprocess.run(['git', '-C', cwd] + list(args), capture_output=True, text=True, encoding='utf-8', errors='replace')
    return r.stdout.strip()


def main_checkout():
    out = git('worktree', 'list', '--porcelain')
    for line in out.splitlines():
        if line.startswith('worktree '):
            return os.path.normpath(line[len('worktree '):].strip())
    return ROOT


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def pe_imports(path):
    """DLL names a 64 bit PE file imports (the import directory), lower case."""
    with open(path, 'rb') as f:
        data = f.read()
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        raise SystemExit('%s is not a PE file' % path)
    nsec = struct.unpack_from('<H', data, pe + 6)[0]
    opt_size = struct.unpack_from('<H', data, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from('<H', data, opt)[0]
    dd = opt + (112 if magic == 0x20B else 96)               # data directories
    imp_rva = struct.unpack_from('<I', data, dd + 8)[0]
    if imp_rva == 0:
        return []
    sections = []
    sec = opt + opt_size
    for i in range(nsec):
        vsize, vaddr, rawsize, rawptr = struct.unpack_from('<IIII', data, sec + 8 + 40 * i)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def off(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size:
                return rva - vaddr + rawptr
        raise ValueError('rva %x' % rva)

    names = []
    p = off(imp_rva)
    while True:
        orig, _, _, name_rva, _ = struct.unpack_from('<IIIII', data, p)
        if name_rva == 0 and orig == 0:
            break
        q = off(name_rva)
        end = data.index(b'\0', q)
        names.append(data[q:end].decode('ascii', 'replace').lower())
        p += 20
    return names


# libraries the exe loads by name at run time (LoadLibrary), which an import table does not show: the DirectWrite text backend of the editor
RUNTIME_DLLS = ('edtext.dll',)


def needed_dlls(exe, bindir):
    """The DLLs of `bindir` that `exe` needs, directly or through each other (system DLLs are not in bindir and are skipped), plus RUNTIME_DLLS."""
    have = {n.lower(): n for n in os.listdir(bindir) if n.lower().endswith('.dll')}
    found, todo = {}, [exe]
    for extra in RUNTIME_DLLS:
        if extra not in have:
            raise SystemExit('%s is missing from %s (build editor/edtext, docs/projects/editor_research/P1_TEXT_BACKEND.md)' % (extra, bindir))
        found[extra] = have[extra]
    while todo:
        cur = todo.pop()
        for dll in pe_imports(cur):
            if dll in have and dll not in found:
                found[dll] = have[dll]
                todo.append(os.path.join(bindir, have[dll]))
    return sorted(found.values())


def copy_tree(src, dst, skip_dirs=(), skip_files=()):
    n = 0
    for base, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in skip_dirs and d != '__pycache__']
        rel = os.path.relpath(base, src)
        target = dst if rel == '.' else os.path.join(dst, rel)
        os.makedirs(target, exist_ok=True)
        for f in files:
            if f.endswith('.pyc') or any(re.match(p, f) for p in skip_files):
                continue
            shutil.copy2(os.path.join(base, f), os.path.join(target, f))
            n += 1
    return n


# ---- assembling ----------------------------------------------------------------------------------------------------------------------------

def changelog():
    """CHANGELOG.txt from the git history of the editor: one block per day, newest first; merge commits and internal notes are left out."""
    out = git('log', '--date=short', '--pretty=format:%ad%x09%h%x09%s', '-n', '600', '--', 'editor', 'scripts/editor_inst.py', 'scripts/editor_merge.py',
              'scripts/package_editor.py', 'scripts/gen_help.py', 'docs/projects/editor')
    lines = ['FAF Studio: changes', '=====================', '']
    day = None
    for row in out.splitlines():
        try:
            date, rev, subject = row.split('\t', 2)
        except ValueError:
            continue
        if subject.startswith('merge ') or subject.startswith('Merge '):
            continue
        subject = subject.encode('ascii', 'replace').decode('ascii')
        if date != day:
            day = date
            lines += ['', date]
        lines.append('  - ' + (subject if len(subject) <= 200 else subject[:197] + '...'))
    return '\n'.join(lines) + '\n'


def stamp_version(path, version, build, revision):
    text = open(path, encoding='utf-8').read()
    text = re.sub(r"^Version = '.*'", "Version = '%s'" % version, text, flags=re.M)
    text = re.sub(r"^Build = '.*?'", "Build = '%s'" % build, text, flags=re.M)
    text = re.sub(r"^Revision = '.*?'", "Revision = '%s'" % revision, text, flags=re.M)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def assemble(a):
    version = a.version or open(os.path.join(ROOT, 'editor', 'VERSION'), encoding='utf-8').read().strip()
    build = datetime.date.today().isoformat()
    revision = git('rev-parse', '--short', 'HEAD')
    if git('status', '--porcelain', '--', 'editor', 'scripts', 'docs/projects/editor'):
        revision += '+changes'
    main = main_checkout()
    import studio_paths as P
    engine_bin = P.ENGINE_BIN
    exe_src = os.path.join(engine_bin, a.exe)
    if not os.path.isfile(exe_src):
        raise SystemExit('no %s: build the editor engine and run scripts/brand_exe.py first (docs/projects/editor/BRANDING.md)' % exe_src)

    # help data must match the topics
    r = subprocess.run([sys.executable, os.path.join(HERE, 'gen_help.py'), '--check'], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(r.stdout.strip() or 'helpdata.lua is out of date: python scripts/gen_help.py')

    name = 'FAFStudio'
    out = os.path.abspath(os.path.join(ROOT, a.out))
    pkg = os.path.join(out, name)
    if os.path.isdir(pkg):
        shutil.rmtree(pkg)
    os.makedirs(pkg)
    print('package folder', pkg)

    # bin
    bindir = os.path.join(pkg, 'bin')
    os.makedirs(bindir)
    shutil.copy2(exe_src, os.path.join(bindir, 'FAFStudio.exe'))
    dlls = needed_dlls(exe_src, engine_bin)
    for d in dlls:
        shutil.copy2(os.path.join(engine_bin, d), os.path.join(bindir, d))
    print('exe + %d DLLs: %s' % (len(dlls), ', '.join(dlls)))
    shutil.copy2(os.path.join(ROOT, 'editor', 'runtime', 'init_editor.lua'), os.path.join(bindir, 'init_editor.lua'))

    # editor tree: tracked content from this checkout, generated content (git-ignored) from here or from the main checkout
    runtime = os.path.join(ROOT, 'editor', 'runtime')
    dest = os.path.join(pkg, 'editor')
    n = copy_tree(runtime, dest, skip_dirs=('testdata', '.editor_backup'), skip_files=(r'^selftest_.*\.lua$', r'^selftests\.extra$'))
    for rel in ('maps', 'brushes', os.path.join('override', 'textures')):
        if not os.path.isdir(os.path.join(dest, rel)) or not os.listdir(os.path.join(dest, rel)):
            src = os.path.join(main, 'editor', 'runtime', rel)
            if os.path.isdir(src):
                n += copy_tree(src, os.path.join(dest, rel))
            else:
                raise SystemExit('generated content %s is missing: run the generators in editor/tools (docs/projects/editor/PACKAGING.md)' % rel)
    print('editor tree: %d files' % n)
    stamp_version(os.path.join(dest, 'lua', 'editor', 'version.lua'), version, build, revision)

    # README, docs, tools, samples (no launcher: bin/FAFStudio.exe starts by itself)
    pk = os.path.join(ROOT, 'editor', 'packaging')
    readme = open(os.path.join(pk, 'README.txt'), encoding='utf-8').read()
    readme = readme.replace('@VERSION@', version).replace('@BUILD@', build).replace('@REVISION@', revision)
    with open(os.path.join(pkg, 'README.txt'), 'w', encoding='utf-8', newline='\r\n') as f:
        f.write(readme)
    with open(os.path.join(pkg, 'CHANGELOG.txt'), 'w', encoding='utf-8', newline='\r\n') as f:
        f.write(changelog())
    with open(os.path.join(pkg, 'VERSION.txt'), 'w', encoding='utf-8', newline='\r\n') as f:
        f.write('FAF Studio %s\nbuilt %s from revision %s\n' % (version, build, revision))
    docs = os.path.join(pkg, 'docs')
    copy_tree(os.path.join(ROOT, 'editor', 'help'), os.path.join(docs, 'help'))
    shutil.copy2(os.path.join(ROOT, 'docs', 'projects', 'editor', 'PACKAGING.md'), os.path.join(docs, 'PACKAGING.md'))
    os.makedirs(os.path.join(pkg, 'tools'))
    shutil.copy2(os.path.join(HERE, 'pack_map.py'), os.path.join(pkg, 'tools', 'pack_map.py'))
    samples = os.path.join(ROOT, 'editor', 'samples')
    os.makedirs(os.path.join(pkg, 'samples'), exist_ok=True)
    os.makedirs(os.path.join(pkg, 'mapout'), exist_ok=True)
    os.makedirs(os.path.join(pkg, 'modproj'), exist_ok=True)
    if os.path.isdir(samples):
        copy_tree(samples, os.path.join(pkg, 'samples'))
        # the sample maps are folders the game can mount: they also go where the editor mounts its own maps, so File > Open lists them
        maps = os.path.join(samples, 'maps')
        if os.path.isdir(maps):
            copy_tree(maps, os.path.join(pkg, 'mapout'))
    # the sample graphs are part of the editor tree (lua/editor/graphpresets): say where
    presets = os.path.join(dest, 'lua', 'editor', 'graphpresets')
    with open(os.path.join(pkg, 'samples', 'README.txt'), 'w', encoding='utf-8', newline='\r\n') as f:
        f.write('Sample map: mapout\\sample_island.v0001 (File > Open map lists it as "sample_island").\n'
                'Sample terrain graphs: the node palette of the Generate workspace lists them (Graph library); the files are in editor\\lua\\editor\\graphpresets.\n')
        if os.path.isdir(presets):
            f.write('Graphs: ' + ', '.join(sorted(os.listdir(presets))) + '\n')

    # manifest
    rows = []
    for base, _, files in os.walk(pkg):
        for fn in files:
            p = os.path.join(base, fn)
            rows.append('%s  %10d  %s' % (sha256(p), os.path.getsize(p), os.path.relpath(p, pkg).replace(os.sep, '/')))
    rows.sort(key=lambda r: r.split('  ', 2)[2])
    with open(os.path.join(pkg, 'MANIFEST.txt'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(rows) + '\n')
    total = sum(int(r.split()[1]) for r in rows)
    print('%d files, %.1f MB' % (len(rows), total / 1e6))

    # verify: the things the exe and the editor look for
    for rel in ('bin/FAFStudio.exe', 'bin/init_editor.lua', 'editor/lua/editor/userdata.lua', 'editor/lua/editor/helpdata.lua',
                'editor/maps/editor_blank/editor_blank_scenario.lua', 'editor/schook/lua/ui/uimain.lua', 'README.txt', 'CHANGELOG.txt', 'docs/PACKAGING.md'):
        if not os.path.isfile(os.path.join(pkg, rel)):
            raise SystemExit('the package lacks ' + rel)
    for forbidden in ('init_faf.lua', 'SupComDataPath.lua', 'fa_path.lua'):
        if os.path.exists(os.path.join(pkg, 'bin', forbidden)) or os.path.exists(os.path.join(pkg, forbidden)):
            raise SystemExit(forbidden + ' belongs to the FAForever install and must not be in the package')
    for d in ('gamedata', 'cache', 'movies', 'sounds', 'themes'):
        if os.path.exists(os.path.join(pkg, d)):
            raise SystemExit('game data folder %s in the package' % d)

    zip_path = None
    if not a.no_zip:
        zip_path = os.path.join(out, '%s-%s.zip' % (name, version))
        if os.path.exists(zip_path):
            os.remove(zip_path)
        with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for base, _, files in os.walk(pkg):
                for fn in files:
                    p = os.path.join(base, fn)
                    z.write(p, os.path.join(name, os.path.relpath(p, pkg)))
        print('zip', zip_path, '%.1f MB' % (os.path.getsize(zip_path) / 1e6))
    return pkg, zip_path, version


# ---- test from a clean folder ------------------------------------------------------------------------------------------------------------

def run_exe(pkg, user, extra, env_extra=None, wait=False):
    """Starts bin\\FAFStudio.exe the way a double click does: no arguments except `extra`, the working folder is NOT bin (the exe has to find its way itself), no launcher.
    wait=False: returns the Popen of the running editor; wait=True: waits for the end and returns the finished process (a start that cannot go on ends by itself)."""
    env = dict(os.environ)
    env['FAFSTUDIO_USER'] = user
    env.update(env_extra or {})
    cmd = [os.path.join(pkg, 'bin', 'FAFStudio.exe')] + extra
    if wait:
        return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120, cwd=os.path.dirname(pkg))
    return subprocess.Popen(cmd, env=env, cwd=os.path.dirname(pkg))


def kill(pid):
    subprocess.run(['taskkill', '/PID', str(pid), '/F'], capture_output=True)


def command(chan, lua, timeout=90):
    """Runs a Lua chunk through the editor's command channel (the file protocol of control.lua)."""
    out = chan + '.out'
    before = os.path.getmtime(out) if os.path.exists(out) else 0
    with open(chan, 'w', encoding='utf-8') as f:
        f.write(lua + '\n-- run %d\n' % time.time_ns())
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(out) and os.path.getmtime(out) > before:
            time.sleep(0.2)
            return open(out, encoding='utf-8', errors='replace').read().strip()
        time.sleep(0.3)
    return 'TIMEOUT'


def package_test(pkg_src):
    """Copies the package to a clean folder whose name has a space in it, starts bin\\FAFStudio.exe like a double click and checks what the user would see."""
    base = os.path.join(os.environ.get('TEMP', 'C:/tmp'), 'fafstudio pkg test')
    if os.path.isdir(base):
        shutil.rmtree(base, ignore_errors=True)
    pkg = os.path.join(base, 'FAF Studio')
    shutil.copytree(pkg_src, pkg)
    user = os.path.join(base, 'user data')
    problems = []

    def check(ok, what):
        print(('  ok   ' if ok else '  FAIL ') + what)
        if not ok:
            problems.append(what)

    # 1. no map argument: the start screen
    chan = os.path.join(base, 'chan 1.lua')
    open(chan, 'w').write('return "ready"\n')
    proc = run_exe(pkg, user, ['/edcmd', chan])
    pid = proc.pid
    try:
        ready = command(chan, 'return "ready"', 120)
        check(ready.startswith('OK'), 'editor answers on the command channel: ' + ready[:60])
        res = command(chan, """
local V = import('/lua/editor/version.lua')
local U = import('/lua/editor/userdata.lua')
local C = import('/lua/editor/crash.lua')
local S = import('/lua/editor/gui/startscreen.lua')
local H = import('/lua/editor/help.lua')
return table.concat({ V.Text(), U.Dir(), C.Root(), tostring(S.IsOpen()), tostring(table.getn(H.Topics())), tostring(ed_file_exists('../fa_path.lua')) }, '\\n')
""")
        lines = res.replace('OK: ', '', 1).split('\n')
        check(len(lines) >= 6, 'editor reports its state: ' + ' | '.join(lines)[:200])
        if len(lines) >= 6:
            check(lines[0].startswith('FAF Studio ') and 'development' not in lines[0], 'version stamped: ' + lines[0])
            check(os.path.normcase(os.path.normpath(lines[1])) == os.path.normcase(os.path.normpath(user)), 'user folder is the one given: ' + lines[1])
            check(os.path.normcase(os.path.normpath(lines[2])) == os.path.normcase(os.path.normpath(pkg)), 'installation folder found from the Lua tree: ' + lines[2])
            check(lines[3] == 'true', 'start screen is open when no map is given')
            check(int(lines[4]) >= 10, 'help topics: ' + lines[4])
            check(lines[5] == 'true', 'fa_path.lua was copied from the FAF install by the exe')
        runs = command(chan, "return tostring(ed_text_stats())")
        check(runs.startswith('OK') and float(runs.replace('OK: ', '') or 0) > 0, 'the DirectWrite text backend (edtext.dll) draws the text: ' + runs)
        shot = os.path.join(os.path.dirname(os.path.abspath(pkg_src)), 'package_test_start.png')
        subprocess.run([sys.executable, os.path.join(ROOT, 'editor', 'textlab', 'shot.py'), shot, '--pid', str(pid)], capture_output=True)
        check(os.path.isfile(shot), 'screenshot of the start screen: ' + shot)
        check(os.path.isfile(os.path.join(user, 'logs', 'editor.log')), 'log written to the user folder')
        for d in ('gamedata', 'cache'):
            check(os.path.isdir(os.path.join(pkg, d)), d + ' is linked')
    finally:
        kill(pid)
        time.sleep(2)

    # 2. a map argument: no start screen, settings are written into the user folder
    chan2 = os.path.join(base, 'chan 2.lua')
    open(chan2, 'w').write('return "ready"\n')
    proc = run_exe(pkg, user, ['/map', 'editor_blank', '/edcmd', chan2])
    pid = proc.pid
    try:
        ready = command(chan2, 'return "ready"', 120)
        check(ready.startswith('OK'), 'second start with /map answers: ' + ready[:60])
        res = command(chan2, "local found = false for _, m in import('/lua/editor/maps.lua').List() do if m.name == 'sample_island' then found = true end end return tostring(found)")
        check(res == 'OK: true', 'the sample map is listed by File > Open: ' + res)
        res = command(chan2, "return tostring(import('/lua/editor/gui/startscreen.lua').IsOpen())")
        check(res == 'OK: false', 'no start screen with /map: ' + res)
        res = command(chan2, "local U = import('/lua/editor/userdata.lua') U.Set('qa', 7) U.Flush() return tostring(ed_file_exists(U.Path('settings.lua')))")
        check(res == 'OK: true', 'settings.lua is written into the user folder: ' + res)
    finally:
        kill(pid)
        time.sleep(1)
    # 3. no FAForever data: the exe says what is missing (no message box under test: logs\\boot_message.txt) and ends with exit code 2, it does not crash
    nofaf = os.path.join(base, 'no faf here')
    os.makedirs(nofaf, exist_ok=True)
    shutil.rmtree(os.path.join(pkg, 'gamedata'), ignore_errors=True)
    for link in ('gamedata', 'cache', 'movies', 'sounds', 'themes'):
        p = os.path.join(pkg, link)
        if os.path.isdir(p):
            os.rmdir(p)                                    # a junction: removes the link, not the data
    for f in ('fa_path.lua',):
        if os.path.isfile(os.path.join(pkg, f)):
            os.remove(os.path.join(pkg, f))
    r = run_exe(pkg, user, [], env_extra={'FAF_DATA': nofaf, 'FAFSTUDIO_NOGUI': '1'}, wait=True)
    msg_file = os.path.join(user, 'logs', 'boot_message.txt')
    msg = open(msg_file, encoding='utf-8', errors='replace').read() if os.path.isfile(msg_file) else ''
    check(r.returncode == 2 and 'needs Supreme Commander' in msg and 'FAF_DATA' in msg, 'a missing FAF install is explained (exit %d): %s' % (r.returncode, ' '.join(msg.split())[:100]))
    print('package test: %s' % ('PASS' if not problems else 'FAIL (%d)' % len(problems)))
    shutil.rmtree(base, ignore_errors=True)
    return not problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='dist')
    ap.add_argument('--version')
    ap.add_argument('--exe', default='FAFStudio.exe')
    ap.add_argument('--no-zip', action='store_true')
    ap.add_argument('--test', action='store_true', help='start the package from a clean folder and check it')
    a = ap.parse_args()
    pkg, zip_path, version = assemble(a)
    if a.test and not package_test(pkg):
        sys.exit(1)
    print('done')


if __name__ == '__main__':
    main()
