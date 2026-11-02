#!/usr/bin/env python
"""FAF Studio: set-up, build and check commands of this repository. Everything else has its own script (docs/REPOSITORY.md lists them).

    python scripts/studio.py doctor                 what is installed, what is missing
    python scripts/studio.py build                  EVERYTHING in one go: bring the engine to the commit this repository pins, build it (CMake, clang-cl), build edtext.dll, stage and brand the exe, say what changed
    python scripts/studio.py engine setup           check out engine/faf-re (our fork UnsilentMarLo/faf-re, branch `editor`, a git submodule) with its own submodules
    python scripts/studio.py engine sync            move engine/faf-re to the commit this repository pins (fast-forward; refuses when the checkout has changes of its own)
    python scripts/studio.py engine build           configure (first time) and build the editor engine with CMake: -DFAF_EDITOR=ON, build/editor-x64 inside engine/faf-re, then stage it
    python scripts/studio.py engine stage           copy the built exe, FAF's init files and the editor's init_editor.lua into engine/run, brand the exe (FAFStudio.exe)
    python scripts/studio.py edtext                 build edtext.dll (DirectWrite text backend, xmake) and stage it
    python scripts/studio.py version                show the version (editor/VERSION, major.minor.patch); a successful `build` raises the patch number (--no-bump keeps it);
                                                    `version --bump minor|major` or `--set X.Y.Z` change it. The number goes into the exe's properties and the editor's start screen
    python scripts/studio.py generate               the generated, git-ignored assets: marker icons, cursors, layer textures, brush masks, blank map templates
    python scripts/studio.py check                  the checks that need no engine: Lua name lint, generated files up to date
    python scripts/studio.py check --full           + the nightly QA run (scripts/editor_nightly.py) on a staged engine

Paths and environment variables: scripts/studio_paths.py. The editor runs on top of the FAForever client's installation (FAF_DATA), nothing of the game is copied into this repository.
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_paths as P  # noqa: E402

ENGINE_FORK = 'https://github.com/UnsilentMarLo/faf-re.git'            # our fork: the engine with the editor, branch `editor` (engine/faf-re is a submodule of it)
ENGINE_UPSTREAM = 'https://github.com/Draiget/faf-re.git'             # where the reconstruction itself comes from
ENGINE_BRANCH = 'editor'
BUILD_SUBDIR = os.path.join('build', 'editor-x64')                     # inside engine/faf-re
ENGINE_EXE_NAME = 'main_ed_x64'


def run(cmd, cwd=None, check=True, **kw):
    print('>', ' '.join(cmd) if isinstance(cmd, list) else cmd)
    r = subprocess.run(cmd, cwd=cwd, **kw)
    if check and r.returncode != 0:
        raise SystemExit('failed (exit %d): %s' % (r.returncode, ' '.join(cmd) if isinstance(cmd, list) else cmd))
    return r


def git(*args, cwd=None):
    r = subprocess.run(['git'] + list(args), cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    return r.returncode, (r.stdout + r.stderr).strip()


# ---- doctor ---------------------------------------------------------------------------------------------------------------------------------

def find_vcvars():
    p = os.environ.get('FAF_STUDIO_VCVARS')
    if p and os.path.isfile(p):
        return p
    vswhere = os.path.join(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'), 'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
    if os.path.isfile(vswhere):
        r = subprocess.run([vswhere, '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'],
                           capture_output=True, text=True)
        base = r.stdout.strip().splitlines()[0] if r.stdout.strip() else ''
        cand = os.path.join(base, 'VC', 'Auxiliary', 'Build', 'vcvars64.bat')
        if base and os.path.isfile(cand):
            return cand
    return None


def find_dxsdk():
    for name in ('FAF_STUDIO_DXSDK', 'DXSDK_DIR'):
        p = os.environ.get(name)
        if p and os.path.isdir(os.path.join(p, 'Include')):
            return p.rstrip('\\/')
    return None


def cmd_doctor(a):
    rows = []

    def row(name, ok, detail):
        rows.append(ok)
        print('%-4s %-26s %s' % ('ok' if ok else 'MISS', name, detail))

    row('python', sys.version_info >= (3, 8), sys.version.split()[0])
    row('git', shutil.which('git') is not None, shutil.which('git') or 'install Git for Windows')
    row('FAForever client data', os.path.isfile(os.path.join(P.FAF_DATA, 'fa_path.lua')) and os.path.isdir(os.path.join(P.FAF_DATA, 'gamedata')), P.FAF_DATA + '   (FAF_DATA)')
    retail = P.retail_install()
    row('Forged Alliance install', bool(retail and os.path.isdir(retail)), str(retail))
    row('engine sources', os.path.isdir(os.path.join(P.SDK, 'moho', 'editor')), P.ENGINE_SRC + '   (studio.py engine setup)')
    row('staged engine', os.path.isfile(os.path.join(P.ENGINE_BIN, 'main_x64_la_p2.exe')), P.ENGINE_BIN + '   (studio.py engine stage)')
    if os.path.exists(os.path.join(P.ENGINE_SRC, '.git')):
        pinned = engine_pinned()
        code, head = git('rev-parse', 'HEAD', cwd=P.ENGINE_SRC)
        if pinned:
            code2, behind = git('merge-base', '--is-ancestor', pinned, head, cwd=P.ENGINE_SRC)
            row('engine at the pinned commit', code == 0 and code2 == 0, 'pinned %s, checked out %s%s' % (pinned[:9], head[:9], '' if code2 == 0 else '   (studio.py engine sync)'))
    cmake = find_cmake()
    row('CMake + Ninja', bool(cmake), cmake or 'Visual Studio 2022 / 2026 with the C++ CMake tools, or CMake 3.25+ and Ninja on PATH')
    llvm = find_llvm()
    row('LLVM (clang-cl)', bool(llvm), llvm or 'LLVM in C:\\Program Files\\LLVM or LLVM_ROOT (the engine builds with clang-cl)')
    exe_path = os.path.join(P.ENGINE_BIN, 'FAFStudio.exe')
    built = engine_exe()
    if os.path.isfile(exe_path) and os.path.isfile(built):
        row('FAFStudio.exe is current', os.path.getmtime(exe_path) >= os.path.getmtime(built) - 5, 'FAFStudio.exe %s, built engine %s' % (stamp(exe_path)[:19], stamp(built)[:19]))
    row('generated assets', os.path.isfile(os.path.join(P.ROOT, 'editor', 'runtime', 'maps', 'editor_blank', 'editor_blank.scmap')), 'studio.py generate')
    vc = find_vcvars()
    row('Visual Studio C++ tools', bool(vc), vc or 'the Windows SDK and runtime libraries the engine links (FAF_STUDIO_VCVARS)')
    dx = find_dxsdk()
    row('DirectX SDK (June 2010)', bool(dx), dx or 'only needed to build the engine (FAF_STUDIO_DXSDK or DXSDK_DIR)')
    row('xmake', shutil.which('xmake') is not None, shutil.which('xmake') or 'only needed for edtext.dll (https://xmake.io)')
    row('FAForever/fa checkout', os.path.isdir(P.FAF_REPO), P.FAF_REPO + '   (only the fx / unit-data generators; FAF_STUDIO_FAF_REPO)')
    print()
    print('To run the editor you need the first five; to build the engine, all of them; the last one only for the maintainers\' generators.')
    return 0


# ---- engine ---------------------------------------------------------------------------------------------------------------------------------
# engine/faf-re is a git submodule of this repository: our fork (UnsilentMarLo/faf-re), branch `editor`, which is the reconstructed engine of Draiget/faf-re (remote `upstream`) with the editor
# on top (src/moho/editor and the changes to the engine files, ordinary commits). This repository pins the commit it builds with; commit a new pin with `git add engine/faf-re`.

def engine_pinned():
    """The commit of the engine this repository is pinned to (the gitlink of engine/faf-re), or None."""
    code, out = git('ls-tree', 'HEAD', 'engine/faf-re', cwd=P.ROOT)
    parts = out.split()
    return parts[2] if code == 0 and len(parts) >= 3 and parts[1] == 'commit' else None


def find_cmake():
    """cmake.exe: the copy Visual Studio ships (its certificate handling downloads the dependencies; the cmake of some other installs cannot), else the one on PATH. Also puts Ninja on PATH."""
    vswhere = os.path.join(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'), 'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
    if os.path.isfile(vswhere):
        r = subprocess.run([vswhere, '-latest', '-products', '*', '-property', 'installationPath'], capture_output=True, text=True)
        base = r.stdout.strip().splitlines()[0] if r.stdout.strip() else ''
        bundled = os.path.join(base, 'Common7', 'IDE', 'CommonExtensions', 'Microsoft', 'CMake')
        exe = os.path.join(bundled, 'CMake', 'bin', 'cmake.exe')
        if base and os.path.isfile(exe):
            os.environ['PATH'] = os.path.join(bundled, 'Ninja') + os.pathsep + os.environ.get('PATH', '')
            return exe
    on_path = shutil.which('cmake')
    return on_path if on_path and shutil.which('ninja') else None


def find_llvm():
    root = os.environ.get('LLVM_ROOT') or r'C:\Program Files\LLVM'
    exe = os.path.join(root, 'bin', 'clang-cl.exe')
    return root if os.path.isfile(exe) else None


def engine_setup(a):
    dst = P.ENGINE_SRC
    if not os.path.exists(os.path.join(dst, '.git')):
        if engine_pinned():
            run(['git', 'submodule', 'update', '--init', 'engine/faf-re'], cwd=P.ROOT)
        else:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            run(['git', 'clone', '--branch', ENGINE_BRANCH, ENGINE_FORK, dst])
    code, out = git('remote', 'get-url', 'upstream', cwd=dst)
    if code != 0:
        run(['git', 'remote', 'add', 'upstream', ENGINE_UPSTREAM], cwd=dst)
    run(['git', 'submodule', 'update', '--init', '--recursive', '--depth', '1'], cwd=dst)        # Wild Magic, zlib, FX11, Vulkan headers, FFmpeg; CMake fetches boost, wxWidgets and DXC itself
    code, out = git('log', '--oneline', '-1', cwd=dst)
    print('engine sources:', dst, '\n  HEAD', out)
    engine_sync(a)
    return 0


def engine_sync(a=None):
    """Brings engine/faf-re to the commit this repository pins: a fast-forward only. A checkout that is AHEAD of the pin (your own commits) is left alone, with a reminder to commit the new pin;
    one with uncommitted changes to tracked files is not touched."""
    dst = P.ENGINE_SRC
    if not os.path.exists(os.path.join(dst, '.git')):
        raise SystemExit('no engine checkout at %s: python scripts/studio.py engine setup' % dst)
    pinned = engine_pinned()
    code, head = git('rev-parse', 'HEAD', cwd=dst)
    if not pinned:
        print('engine sources: this repository does not pin an engine commit (git add engine/faf-re); HEAD %s is used' % head[:9])
        return 0
    if head == pinned:
        print('engine sources: at the pinned commit %s' % pinned[:9])
        return 0
    if git('cat-file', '-e', pinned + '^{commit}', cwd=dst)[0] != 0:
        run(['git', 'fetch', 'origin'], cwd=dst)
    if git('merge-base', '--is-ancestor', pinned, head, cwd=dst)[0] == 0:
        print('engine sources: %s is ahead of the pinned commit %s: commit the new pin here (git add engine/faf-re)' % (head[:9], pinned[:9]))
        return 0
    code, out = git('status', '--porcelain', '--untracked-files=no', cwd=dst)
    if out.strip():
        raise SystemExit('the engine is behind the pinned commit %s but has uncommitted changes (commit or stash them in %s):\n%s' % (pinned[:9], dst, out))
    r = run(['git', 'merge', '--ff-only', pinned], cwd=dst, check=False)
    if r.returncode != 0:
        raise SystemExit('the engine checkout cannot fast-forward to the pinned commit %s (it has commits of its own that the pin lacks). Merge by hand in %s.' % (pinned[:9], dst))
    run(['git', 'submodule', 'update', '--init', '--recursive', '--depth', '1'], cwd=dst, check=False)
    print('engine sources: moved to the pinned commit %s' % pinned[:9])
    return 1


VERSION_FILE = os.path.join(P.ROOT, 'editor', 'VERSION')
BUILDINFO = os.path.join(P.ROOT, 'editor', 'runtime', 'lua', 'editor', 'buildinfo.lua')


def read_version():
    try:
        parts = [int(x) for x in open(VERSION_FILE, encoding='utf-8').read().strip().split('.')[:3]]
    except (OSError, ValueError):
        parts = []
    return (parts + [0, 0, 0])[:3]


def write_version(parts):
    with open(VERSION_FILE, 'w', encoding='utf-8', newline='\n') as f:
        f.write('%d.%d.%d\n' % tuple(parts))


def bump_version(level='patch'):
    """The version number of the next build: editor/VERSION is major.minor.patch, a build raises the patch (a `studio.py version minor|major` raises the others and resets what follows)."""
    major, minor, patch = read_version()
    if level == 'major':
        major, minor, patch = major + 1, 0, 0
    elif level == 'minor':
        minor, patch = minor + 1, 0
    else:
        patch += 1
    write_version([major, minor, patch])
    return '%d.%d.%d' % (major, minor, patch)


def write_buildinfo():
    """The number, date and git revision of this build for a development run (editor/runtime/lua/editor/buildinfo.lua, git-ignored; version.lua shows it instead of "development")."""
    version = '%d.%d.%d' % tuple(read_version())
    rev = run(['git', '-C', P.ROOT, 'rev-parse', '--short', 'HEAD'], check=False, capture_output=True, text=True)
    revision = (rev.stdout or '').strip() if rev.returncode == 0 else ''
    with open(BUILDINFO, 'w', encoding='utf-8', newline='\n') as f:
        f.write("-- written by `python scripts/studio.py engine build / stage`; not part of the repository\nVersion = '%s'\nBuild = '%s'\nRevision = '%s'\n" % (version, time.strftime('%Y-%m-%d'), revision))
    return version


def cmd_version(a):
    if a.set:
        try:
            parts = [int(x) for x in a.set.split('.')]
            assert len(parts) == 3
        except (ValueError, AssertionError):
            raise SystemExit('give the version as major.minor.patch, e.g. 0.5.0')
        write_version(parts)
        print('version set to %s (the next build raises the patch number)' % a.set)
    elif a.bump:
        print('version is now', bump_version(a.bump))
    else:
        print('%d.%d.%d' % tuple(read_version()))
    return 0


def engine_exe():
    return os.path.join(P.ENGINE_SRC, BUILD_SUBDIR, 'src', ENGINE_EXE_NAME + '.exe')


def engine_build(a):
    cmake = find_cmake()
    if not cmake:
        raise SystemExit('cmake and ninja not found: install Visual Studio with the C++ CMake tools, or put CMake 3.25+ and Ninja on PATH')
    if not find_llvm():
        raise SystemExit('LLVM (clang-cl) not found in C:\\Program Files\\LLVM: set LLVM_ROOT (the engine builds with clang-cl)')
    P.need(os.path.join(P.SDK, 'CMakeLists.txt'), 'engine sources', 'python scripts/studio.py engine setup')
    engine_sync(a)
    run([sys.executable, os.path.join(HERE, 'gen_gpu_shaders.py')], check=False)                 # the GPU kernels -> EdGpuShaders.generated.h (a tracked file of the engine: commit it when it changes)
    build_dir = os.path.join(P.ENGINE_SRC, BUILD_SUBDIR)
    if not os.path.isfile(os.path.join(build_dir, 'CMakeCache.txt')):
        run([cmake, '--preset', 'clang-x64-release', '-B', BUILD_SUBDIR.replace(os.sep, '/'), '-DFAF_EDITOR=ON', '-DFAF_OUTPUT_NAME=' + ENGINE_EXE_NAME, '-DFAF_X64_LARGE_ADDRESS=heap'], cwd=P.ENGINE_SRC)
    log = os.path.join(P.ENGINE_DIR, 'build.log')
    os.makedirs(P.ENGINE_DIR, exist_ok=True)
    started = time.time()
    with open(log, 'w', encoding='utf-8', errors='replace') as f:
        r = run([cmake, '--build', BUILD_SUBDIR.replace(os.sep, '/')], cwd=P.ENGINE_SRC, check=False, stdout=f, stderr=subprocess.STDOUT)
    errors = sum(1 for line in open(log, encoding='utf-8', errors='replace') if ' error' in line and 'error:' in line)
    print('build exit %d, %d error lines (log: %s)' % (r.returncode, errors, log))
    if r.returncode != 0:
        for line in open(log, encoding='utf-8', errors='replace'):
            if 'error:' in line:
                print('  ' + line.strip()[:200])
                errors -= 1
                if errors < -12:
                    break
        return 1
    exe = engine_exe()
    if not os.path.isfile(exe) or os.path.getmtime(exe) < started - 2 and not os.path.getsize(log) < 400:
        print('the build reported success but %s was not rebuilt. Nothing was staged: the exe in %s stays the old one.' % (exe, P.ENGINE_BIN))
        return 1
    print('built %s (%s, %d bytes)' % (exe, time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(os.path.getmtime(exe))), os.path.getsize(exe)))
    # a build that compiled is a new version: the number is raised before the exe is staged, so the exe's properties and the editor's start screen carry it
    if getattr(a, 'no_bump', False):
        print('version stays %d.%d.%d (--no-bump)' % tuple(read_version()))
    else:
        print('version %d.%d.%d -> %s' % (tuple(read_version()) + (bump_version(),)))
    if shutil.which('xmake'):
        try:
            cmd_edtext(a)        # the text DLL is part of the editor: build it with it, so it cannot be left behind
        except SystemExit as e:
            print('edtext.dll was NOT rebuilt (%s): the engine is staged with the DLL that was there' % e)
    else:
        print('note: xmake not found, edtext.dll is not rebuilt (https://xmake.io); the DLL in %s stays as it is' % P.ENGINE_BIN)
    return engine_stage(a)


def stamp(path):
    return '%s  %9d bytes' % (time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(os.path.getmtime(path))), os.path.getsize(path)) if os.path.isfile(path) else 'missing'


def engine_stage(a):
    exe = P.need(engine_exe(), 'the built engine', 'python scripts/studio.py engine build')
    out = os.path.dirname(exe)
    os.makedirs(P.ENGINE_BIN, exist_ok=True)
    locked = []

    def copy(src, dst):
        try:
            shutil.copy2(src, dst)
        except PermissionError:
            locked.append(os.path.basename(dst))

    target = os.path.join(P.ENGINE_BIN, 'main_x64_la_p2.exe')
    if os.path.exists(target):
        n = 1
        while os.path.exists(os.path.join(P.ENGINE_BIN, 'main_x64_la_p2_prev%d.exe' % n)):
            n += 1
        os.replace(target, os.path.join(P.ENGINE_BIN, 'main_x64_la_p2_prev%d.exe' % n))      # a running instance keeps its hard link; the old build stays for a rollback
    copy(exe, target)
    copy(exe, os.path.join(P.ENGINE_BIN, 'main_x64_la.exe'))
    for dll in glob.glob(os.path.join(out, '*.dll')):          # dxcompiler.dll and dxil.dll (Direct3D 12 / Vulkan shader compiler); FFmpeg is linked in
        copy(dll, P.ENGINE_BIN)
    hooks = os.path.join(out, 'fafengine')                       # the engine's own Lua hooks (the Graphics API option), mounted next to the exe
    if os.path.isdir(hooks):
        shutil.copytree(hooks, os.path.join(P.ENGINE_BIN, 'fafengine'), dirs_exist_ok=True)
    edtext = os.path.join(P.ROOT, 'editor', 'edtext', 'build', 'windows', 'x64', 'release', 'edtext.dll')
    if os.path.isfile(edtext):
        copy(edtext, P.ENGINE_BIN)
        sources = [os.path.join(P.ROOT, 'editor', 'edtext', f) for f in ('edtext.cpp', 'edraster.h', 'edtext.h')]
        if any(os.path.getmtime(f) > os.path.getmtime(edtext) for f in sources if os.path.isfile(f)):
            print('WARNING: edtext.dll is older than its sources (editor/edtext): run `python scripts/studio.py edtext` (needs xmake)')
    else:
        print('note: no edtext.dll yet (python scripts/studio.py edtext): the editor falls back to the engine fonts')
    # FAF's own init files and the path file: read from the FAForever client at every stage (they are FAF's, not redistributed here)
    for name in ('init_faf.lua', 'SupComDataPath.lua'):
        src = os.path.join(P.FAF_DATA, 'bin', name)
        if os.path.isfile(src):
            copy(src, os.path.join(P.ENGINE_BIN, name))
        else:
            print('MISSING %s in the FAForever client (%s): start the client once and run `engine stage` again' % (name, src))
    fa_path = os.path.join(P.FAF_DATA, 'fa_path.lua')
    if os.path.isfile(fa_path):
        copy(fa_path, os.path.join(P.ENGINE_RUN, 'fa_path.lua'))
    copy(os.path.join(P.ROOT, 'editor', 'runtime', 'init_editor.lua'), os.path.join(P.ENGINE_BIN, 'init_editor.lua'))
    version = write_buildinfo()
    r = run([sys.executable, os.path.join(HERE, 'brand_exe.py'), '--version', version], check=False, capture_output=True, text=True)
    print((r.stdout or '').strip())
    if (r.stdout or '').find('running or locked') >= 0 or r.returncode != 0:
        locked.append('FAFStudio.exe')
        if r.stderr:
            print(r.stderr.strip())
    print()
    print('staged in', P.ENGINE_BIN)
    for name in ('FAFStudio.exe', 'main_x64_la_p2.exe', 'main_x64_la.exe', 'edtext.dll', 'init_editor.lua'):
        print('  %-20s %s' % (name, stamp(os.path.join(P.ENGINE_BIN, name))))
    if locked:
        print('\nNOT UPDATED (locked: a running editor or a stuck process holds them): ' + ', '.join(sorted(set(locked))))
        print('Close every FAF Studio / main_x64_la window (Task Manager > Details: FAFStudio.exe, main_x64_la*.exe), then run `python scripts/studio.py engine stage` again.')
        return 1
    return 0


def cmd_engine(a):
    return {'setup': engine_setup, 'sync': lambda x: engine_sync(x) and 0, 'build': engine_build, 'stage': engine_stage}[a.what](a)


# ---- edtext, generate, check ----------------------------------------------------------------------------------------------------------------

def cmd_edtext(a):
    if not shutil.which('xmake'):
        raise SystemExit('xmake not found (https://xmake.io)')
    d = os.path.join(P.ROOT, 'editor', 'edtext')
    run(['xmake', 'f', '-P', '.', '-y', '-c', '-p', 'windows', '-a', 'x64', '--toolchain=msvc', '-m', 'release'], cwd=d)
    run(['xmake', '-P', '.', '-y'], cwd=d)
    dll = os.path.join(d, 'build', 'windows', 'x64', 'release', 'edtext.dll')
    if os.path.isfile(dll) and os.path.isdir(P.ENGINE_BIN):
        shutil.copy2(dll, P.ENGINE_BIN)
        print('staged', dll)
    return 0


GENERATORS = [
    ['editor/tools/gen_marker_icons.py'], ['editor/tools/gen_cursors.py'], ['editor/tools/gen_layer_textures.py'], ['editor/tools/gen_brush_masks.py'],
    ['scripts/ed_make_blank_map.py'],
    ['scripts/gen_gpu_shaders.py'],           # engine: moho/editor/EdGpuShaders.generated.h from gpu/*.hlsl (docs/projects/editor/GPU_COMPUTE.md); skips when the engine sources are not set up
]


def cmd_generate(a):
    for g in GENERATORS:
        run([sys.executable, os.path.join(P.ROOT, g[0])] + g[1:])
    return 0


def cmd_check(a):
    bad = []
    for name, cmd in (('lint', [sys.executable, os.path.join(HERE, 'editor_lint.py')]),
                      ('help data', [sys.executable, os.path.join(HERE, 'gen_help.py'), '--check']),
                      ('mission api', [sys.executable, os.path.join(HERE, 'editor_mission_api.py'), '--check'])):
        r = run(cmd, check=False)
        if r.returncode != 0:
            bad.append(name)
    for tool in ('gen_primbatcher_fx.py', 'gen_terrain_fx.py'):
        if os.path.isdir(P.FAF_REPO):
            r = run([sys.executable, os.path.join(P.ROOT, 'editor', 'tools', tool), '--check'], check=False)
            if r.returncode != 0:
                bad.append(tool)
        else:
            print('skipped %s (no FAForever/fa checkout at %s)' % (tool, P.FAF_REPO))
    r = run([sys.executable, os.path.join(HERE, 'gen_gpu_shaders.py'), '--check'], check=False)         # the GPU kernels: lint + generated header up to date (skips without engine sources)
    if r.returncode != 0:
        bad.append('gen_gpu_shaders.py')
    if a.full:
        r = run([sys.executable, os.path.join(HERE, 'editor_nightly.py')], check=False)
        if r.returncode != 0:
            bad.append('nightly')
    print('\nFAILED: ' + ', '.join(bad) if bad else '\nall checks passed')
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='c', required=True)
    sub.add_parser('doctor').set_defaults(f=cmd_doctor)
    p = sub.add_parser('build')
    p.add_argument('--no-bump', action='store_true', help='keep the version number (a build normally raises the patch number of editor/VERSION)')
    p.set_defaults(f=engine_build)
    p = sub.add_parser('engine')
    p.add_argument('what', choices=['setup', 'sync', 'build', 'stage'])
    p.add_argument('--no-bump', action='store_true', help='with build: keep the version number')
    p.set_defaults(f=cmd_engine)
    p = sub.add_parser('version', help='show or change the version (editor/VERSION)')
    p.add_argument('--set', metavar='X.Y.Z')
    p.add_argument('--bump', choices=['patch', 'minor', 'major'])
    p.set_defaults(f=cmd_version)
    sub.add_parser('edtext').set_defaults(f=cmd_edtext)
    sub.add_parser('generate').set_defaults(f=cmd_generate)
    p = sub.add_parser('check')
    p.add_argument('--full', action='store_true')
    p.set_defaults(f=cmd_check)
    a = ap.parse_args()
    sys.exit(a.f(a) or 0)


if __name__ == '__main__':
    main()
