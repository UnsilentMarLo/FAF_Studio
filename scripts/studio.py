#!/usr/bin/env python
"""FAF Studio: set-up, build and check commands of this repository. Everything else has its own script (docs/REPOSITORY.md lists them).

    python scripts/studio.py doctor                 what is installed, what is missing
    python scripts/studio.py engine setup           clone the reconstructed engine (engine/BASE.json) and apply our patch series (engine/patches) -> engine/faf-re
    python scripts/studio.py engine build           MSBuild the editor engine (Visual Studio + the June 2010 DirectX SDK), then stage it
    python scripts/studio.py engine stage           copy the built exe and DLLs, FAF's init files and the editor's init_editor.lua into engine/run, brand the exe (FAFStudio.exe)
    python scripts/studio.py engine export          write the commits of engine/faf-re on top of the base back to engine/patches (commit them here)
    python scripts/studio.py edtext                 build edtext.dll (DirectWrite text backend, xmake) and stage it
    python scripts/studio.py generate               the generated, git-ignored assets: marker icons, cursors, layer textures, brush masks, blank map templates
    python scripts/studio.py check                  the checks that need no engine: Lua name lint, generated files up to date
    python scripts/studio.py check --full           + the nightly QA run (scripts/editor_nightly.py) on a staged engine

Paths and environment variables: scripts/studio_paths.py. The editor runs on top of the FAForever client's installation (FAF_DATA), nothing of the game is copied into this repository.
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_paths as P  # noqa: E402

ENGINE_META = os.path.join(P.ROOT, 'engine', 'BASE.json')
PATCHES = os.path.join(P.ROOT, 'engine', 'patches')


def run(cmd, cwd=None, check=True, **kw):
    print('>', ' '.join(cmd) if isinstance(cmd, list) else cmd)
    r = subprocess.run(cmd, cwd=cwd, **kw)
    if check and r.returncode != 0:
        raise SystemExit('failed (exit %d): %s' % (r.returncode, ' '.join(cmd) if isinstance(cmd, list) else cmd))
    return r


def git(*args, cwd=None):
    r = subprocess.run(['git'] + list(args), cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    return r.returncode, (r.stdout + r.stderr).strip()


def meta():
    return json.load(open(ENGINE_META, encoding='utf-8'))


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
    row('generated assets', os.path.isfile(os.path.join(P.ROOT, 'editor', 'runtime', 'maps', 'editor_blank', 'editor_blank.scmap')), 'studio.py generate')
    vc = find_vcvars()
    row('Visual Studio C++ tools', bool(vc), vc or 'only needed to build the engine (FAF_STUDIO_VCVARS)')
    dx = find_dxsdk()
    row('DirectX SDK (June 2010)', bool(dx), dx or 'only needed to build the engine (FAF_STUDIO_DXSDK or DXSDK_DIR)')
    row('xmake', shutil.which('xmake') is not None, shutil.which('xmake') or 'only needed for edtext.dll (https://xmake.io)')
    row('FAForever/fa checkout', os.path.isdir(P.FAF_REPO), P.FAF_REPO + '   (only the fx / unit-data generators; FAF_STUDIO_FAF_REPO)')
    print()
    print('To run the editor you need the first five; to build the engine, all of them; the last one only for the maintainers\' generators.')
    return 0


# ---- engine ---------------------------------------------------------------------------------------------------------------------------------

def engine_setup(a):
    m = meta()
    url = os.environ.get('FAF_STUDIO_ENGINE_UPSTREAM') or m['upstream']
    dst = P.ENGINE_SRC
    if os.path.isdir(os.path.join(dst, '.git')):
        code, out = git('log', '--oneline', '-1', cwd=dst)
        print('engine sources exist:', dst, '\n  HEAD', out)
        return 0
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    run(['git', 'clone', '--no-checkout', url, dst])
    run(['git', 'checkout', '-B', 'editor', m['base']], cwd=dst)
    patches = sorted(glob.glob(os.path.join(PATCHES, '*.patch')))
    if not patches:
        print('no patches in engine/patches: the plain upstream engine is checked out')
        return 0
    env = dict(os.environ, GIT_COMMITTER_NAME=os.environ.get('GIT_COMMITTER_NAME', 'FAF Studio'), GIT_COMMITTER_EMAIL=os.environ.get('GIT_COMMITTER_EMAIL', 'faf-studio@localhost'))
    r = run(['git', 'am', '--3way', '--keep-cr'] + patches, cwd=dst, check=False, env=env)
    if r.returncode != 0:
        run(['git', 'am', '--abort'], cwd=dst, check=False)
        raise SystemExit('the patch series does not apply to %s at %s: is engine/BASE.json right?' % (url, m['base']))
    print('engine ready: %d patches on top of %s' % (len(patches), m['base'][:10]))
    return 0


def engine_export(a):
    m = meta()
    dst = P.ENGINE_SRC
    code, out = git('status', '--porcelain', cwd=dst)
    if out.strip():
        raise SystemExit('the engine checkout has uncommitted changes (commit them first):\n' + out)
    for f in glob.glob(os.path.join(PATCHES, '*.patch')):
        os.remove(f)
    os.makedirs(PATCHES, exist_ok=True)
    run(['git', 'format-patch', '--no-stat', '-N', '--zero-commit', '--no-signature', m['base'] + '..HEAD', '-o', PATCHES], cwd=dst, stdout=subprocess.DEVNULL)
    n = len(glob.glob(os.path.join(PATCHES, '*.patch')))
    print('wrote %d patches to engine/patches (commit them in this repository)' % n)
    return 0


def engine_build(a):
    vc = find_vcvars()
    dx = find_dxsdk()
    if not vc:
        raise SystemExit('Visual Studio with the C++ tools not found (set FAF_STUDIO_VCVARS to vcvars64.bat)')
    if not dx:
        raise SystemExit('the June 2010 DirectX SDK not found (set FAF_STUDIO_DXSDK, e.g. C:\\Program Files (x86)\\Microsoft DirectX SDK (June 2010))')
    P.need(os.path.join(P.SDK, 'main_ed.vcxproj'), 'engine sources', 'python scripts/studio.py engine setup')
    log = os.path.join(P.ENGINE_DIR, 'build.log')
    os.makedirs(P.ENGINE_DIR, exist_ok=True)
    bat = os.path.join(P.ENGINE_DIR, '_build.bat')
    with open(bat, 'w') as f:
        f.write('@echo off\r\ncall "%s" >nul 2>&1\r\ncd /d "%s"\r\n' % (vc, P.SDK))
        f.write('msbuild main_ed.vcxproj /nologo /m /t:Build /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v145 "/p:DirectXInclude=%s\\Include" '
                '"/p:DirectXLibX64=%s\\Lib\\x64" /p:ContinueOnError=true "/flp:logfile=%s;verbosity=minimal;encoding=UTF-8" /p:CL_MPCount=8 /p:FafX64LargeAddress=heap\r\n' % (dx, dx, log))
        f.write('exit /b %ERRORLEVEL%\r\n')
    r = run(['cmd', '/c', bat], check=False)
    errors = 0
    if os.path.isfile(log):
        errors = sum(1 for line in open(log, encoding='utf-8', errors='replace') if ' error ' in line)
    print('build exit %d, %d error lines (log: %s)' % (r.returncode, errors, log))
    if r.returncode != 0 or errors:
        return 1
    return engine_stage(a)


def engine_stage(a):
    out = os.path.join(P.ENGINE_SRC, 'output', 'main', 'x64', 'Release')
    exe = P.need(os.path.join(out, 'main_x64_la.exe'), 'the built engine', 'python scripts/studio.py engine build')
    os.makedirs(P.ENGINE_BIN, exist_ok=True)
    target = os.path.join(P.ENGINE_BIN, 'main_x64_la_p2.exe')
    if os.path.exists(target):
        n = 1
        while os.path.exists(os.path.join(P.ENGINE_BIN, 'main_x64_la_p2_prev%d.exe' % n)):
            n += 1
        os.replace(target, os.path.join(P.ENGINE_BIN, 'main_x64_la_p2_prev%d.exe' % n))      # a running instance keeps its hard link; the old build stays for a rollback
    shutil.copy2(exe, target)
    shutil.copy2(exe, os.path.join(P.ENGINE_BIN, 'main_x64_la.exe'))
    for dll in glob.glob(os.path.join(out, '*.dll')):
        shutil.copy2(dll, P.ENGINE_BIN)
    edtext = os.path.join(P.ROOT, 'editor', 'edtext', 'build', 'windows', 'x64', 'release', 'edtext.dll')
    if os.path.isfile(edtext):
        shutil.copy2(edtext, P.ENGINE_BIN)
    else:
        print('note: no edtext.dll yet (python scripts/studio.py edtext): the editor falls back to the engine fonts')
    # FAF's own init files and the path file: read from the FAForever client at every stage (they are FAF's, not redistributed here)
    for name in ('init_faf.lua', 'SupComDataPath.lua'):
        src = os.path.join(P.FAF_DATA, 'bin', name)
        if os.path.isfile(src):
            shutil.copy2(src, P.ENGINE_BIN)
        else:
            print('MISSING %s in the FAForever client (%s): start the client once and run `engine stage` again' % (name, src))
    fa_path = os.path.join(P.FAF_DATA, 'fa_path.lua')
    if os.path.isfile(fa_path):
        shutil.copy2(fa_path, os.path.join(P.ENGINE_RUN, 'fa_path.lua'))
    shutil.copy2(os.path.join(P.ROOT, 'editor', 'runtime', 'init_editor.lua'), P.ENGINE_BIN)
    run([sys.executable, os.path.join(HERE, 'brand_exe.py')], check=False)
    print('staged in', P.ENGINE_BIN)
    return 0


def cmd_engine(a):
    return {'setup': engine_setup, 'build': engine_build, 'stage': engine_stage, 'export': engine_export}[a.what](a)


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
]


def cmd_generate(a):
    for g in GENERATORS:
        run([sys.executable, os.path.join(P.ROOT, g[0])] + g[1:])
    return 0


def cmd_check(a):
    bad = []
    for name, cmd in (('lint', [sys.executable, os.path.join(HERE, 'editor_lint.py')]),
                      ('help data', [sys.executable, os.path.join(HERE, 'gen_help.py'), '--check'])):
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
    p = sub.add_parser('engine')
    p.add_argument('what', choices=['setup', 'build', 'stage', 'export'])
    p.set_defaults(f=cmd_engine)
    sub.add_parser('edtext').set_defaults(f=cmd_edtext)
    sub.add_parser('generate').set_defaults(f=cmd_generate)
    p = sub.add_parser('check')
    p.add_argument('--full', action='store_true')
    p.set_defaults(f=cmd_check)
    a = ap.parse_args()
    sys.exit(a.f(a) or 0)


if __name__ == '__main__':
    main()
