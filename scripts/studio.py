#!/usr/bin/env python
"""FAF Studio: set-up, build and check commands of this repository. Everything else has its own script (docs/REPOSITORY.md lists them).

    python scripts/studio.py doctor                 what is installed, what is missing
    python scripts/studio.py build                  EVERYTHING in one go: apply new engine patches, build the engine, build edtext.dll, stage and brand the exe, say what changed
    python scripts/studio.py deps                   the engine's third-party libraries (boost, wxWindows, LuaPlus, zlib, WildMagic, FFmpeg) are NOT in git: find them (an older checkout, FAF_STUDIO_DEPS),
                                                    link them into engine/faf-re/dependencies, download FFmpeg when it is the only thing missing; `build` runs this first
    python scripts/studio.py engine setup           clone the reconstructed engine (engine/BASE.json) and apply our patch series (engine/patches) -> engine/faf-re
    python scripts/studio.py engine sync            apply the patches of engine/patches that engine/faf-re does not have yet (setup does this too; `git pull` adds patches, it does not apply them)
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
import email
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

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
    if os.path.isdir(os.path.join(P.ENGINE_SRC, '.git')):
        try:
            code, out = git('log', '--format=%s', meta()['base'] + '..HEAD', cwd=P.ENGINE_SRC)
            have = set(' '.join(line.split()) for line in out.splitlines())
            patches = sorted(glob.glob(os.path.join(PATCHES, '*.patch')))
            missing = [os.path.basename(p) for p in patches if patch_subject(p) not in have]
            row('engine patches applied', not missing, '%d of %d%s' % (len(patches) - len(missing), len(patches), ('   MISSING: ' + ', '.join(missing[:3]) + ('...' if len(missing) > 3 else '') + '   (python scripts/studio.py build applies them)') if missing else ''))
        except Exception as e:
            row('engine patches applied', False, str(e)[:100])
    if os.path.isdir(P.ENGINE_SRC):
        miss = deps_missing()
        row('engine dependencies', not miss, ('all %d in engine/faf-re/dependencies' % len(DEPENDENCIES)) if not miss else 'MISSING: ' + ', '.join(miss) + '   (python scripts/studio.py deps)')
    exe_path = os.path.join(P.ENGINE_BIN, 'FAFStudio.exe')
    built = os.path.join(P.ENGINE_SRC, 'output', 'main', 'x64', 'Release', 'main_x64_la.exe')
    if os.path.isfile(exe_path) and os.path.isfile(built):
        row('FAFStudio.exe is current', os.path.getmtime(exe_path) >= os.path.getmtime(built) - 5, 'FAFStudio.exe %s, built engine %s' % (stamp(exe_path)[:19], stamp(built)[:19]))
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
        engine_sync(a)
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


# ---- third-party libraries of the engine -----------------------------------------------------------------------------------------------------

# name under engine/faf-re/dependencies -> a file that proves it is complete enough. None of these are in git (upstream vendors them as private .7z archives; see
# engine/faf-re/dependencies/patches/*.md for what each one is): boost 1.34.1 (headers and 12 thread sources), LuaPlus Build 1081, zlib 1.2.3 (13 files), wxWindows 2.4.2 (patched, with
# lib\x64\wxmswu.lib), WildMagic 3.8 (Foundation.vcxproj is a project reference), FFmpeg 7.1.x shared LGPL (include, lib\*.lib, bin\*.dll; docs/FAF_SFD_COMPATIBILITY.md).
DEPENDENCIES = [
    ('boost_1_34_1', 'boost/config.hpp'),
    ('LuaPlus_Build1081', 'Src/LuaPlus/include'),
    ('zlib-1.2.3', 'include'),
    ('wxWindows-2.4.2', 'include/wx'),
    ('WildMagic3p8', 'Foundation/Foundation.vcxproj'),
    ('ffmpeg/x64', 'include/libavcodec/avcodec.h'),
]


def deps_dir():
    return os.path.join(P.ENGINE_SRC, 'dependencies')


def deps_missing():
    return [name for name, proof in DEPENDENCIES if not os.path.exists(os.path.join(deps_dir(), name, proof))]


def deps_candidates():
    """Folders that may hold a prepared `dependencies` tree: FAF_STUDIO_DEPS (the dependencies folder, or an engine checkout that has one), then the places an earlier workspace
    of this project kept it, next to this checkout (Documents\\SupCom_Dev_Workspace\\engine_decomp\\faf-re-upstream\\dependencies and the like)."""
    out = []
    env = os.environ.get('FAF_STUDIO_DEPS')
    if env:
        out += [env, os.path.join(env, 'dependencies')]
    parent = os.path.dirname(P.ROOT)
    for pattern in ('*/engine_decomp/*/dependencies', '*/engine_decomp/*/*/dependencies', '*/engine/faf-re/dependencies', '*/dependencies', '*/engine_decomp/_deps_src', '*/engine_decomp/_deps_src/*'):
        out += sorted(glob.glob(os.path.join(parent, pattern)))
    out += sorted(glob.glob(os.path.join(P.ROOT, 'engine_decomp', '*', 'dependencies')))
    here = os.path.realpath(deps_dir())
    seen, result = set(), []
    for c in out:
        r = os.path.realpath(c)
        if os.path.isdir(r) and r != here and r not in seen:
            seen.add(r)
            result.append(r)
    return result


def link_dir(link, target):
    """A folder link (junction on Windows: no administrator rights, no copy), else a copy."""
    os.makedirs(os.path.dirname(link), exist_ok=True)
    if os.path.lexists(link):
        return False
    if os.name == 'nt':
        r = subprocess.run(['cmd', '/c', 'mklink', '/J', link, target], capture_output=True, text=True)
        if r.returncode == 0:
            return True
    else:
        try:
            os.symlink(target, link)
            return True
        except OSError:
            pass
    shutil.copytree(target, link)
    return True


def fetch_ffmpeg():
    """FFmpeg 7.1.x LGPL shared build for Windows x64 (BtbN/FFmpeg-Builds: include, lib\\*.lib import libraries, bin\\*.dll) into dependencies/ffmpeg/x64. The asset is looked up
    in the release list at run time (its file name changes with every build). Returns True on success."""
    dst = os.path.join(deps_dir(), 'ffmpeg', 'x64')
    print('looking for an FFmpeg 7.1 LGPL shared build (BtbN/FFmpeg-Builds) ...')
    try:
        req = urllib.request.Request('https://api.github.com/repos/BtbN/FFmpeg-Builds/releases?per_page=8', headers={'User-Agent': 'faf-studio', 'Accept': 'application/vnd.github+json'})
        releases = json.load(urllib.request.urlopen(req, timeout=60))
        asset = None
        for rel in releases:
            for a in rel.get('assets', []):
                name = a['name']
                if name.endswith('.zip') and 'win64-lgpl-shared-7.1' in name and 'n7.1' in name:
                    asset = a
                    break
            if asset:
                break
        if not asset:
            print('no ffmpeg-n7.1...-win64-lgpl-shared-7.1.zip asset in the latest releases of BtbN/FFmpeg-Builds')
            return False
        zpath = os.path.join(P.ENGINE_DIR, asset['name'])
        os.makedirs(P.ENGINE_DIR, exist_ok=True)
        print('downloading %s (%.0f MB)' % (asset['name'], asset['size'] / 1e6))
        urllib.request.urlretrieve(asset['browser_download_url'], zpath)
    except Exception as e:
        print('download failed: %s' % e)
        return False
    tmp = os.path.join(P.ENGINE_DIR, '_ffmpeg_unpack')
    shutil.rmtree(tmp, ignore_errors=True)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(tmp)
    top = [d for d in os.listdir(tmp) if os.path.isdir(os.path.join(tmp, d))]
    src = os.path.join(tmp, top[0]) if top else tmp
    if not os.path.isfile(os.path.join(src, 'include', 'libavcodec', 'avcodec.h')) or not glob.glob(os.path.join(src, 'lib', 'avcodec*.lib')):
        print('the archive has no include/libavcodec and lib/avcodec*.lib: not a development package')
        return False
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst)
    for sub in ('include', 'lib', 'bin'):
        if os.path.isdir(os.path.join(src, sub)):
            shutil.copytree(os.path.join(src, sub), os.path.join(dst, sub))
    shutil.rmtree(tmp, ignore_errors=True)
    os.remove(zpath)
    print('FFmpeg is in', dst, '(LGPL shared build: its license texts and source offer have to travel with a distributed package)')
    return True


def cmd_deps(a=None):
    """Makes every third-party library of the engine available in engine/faf-re/dependencies; returns 0 when nothing is missing afterwards."""
    if not os.path.isdir(P.ENGINE_SRC):
        raise SystemExit('no engine checkout at %s: python scripts/studio.py engine setup' % P.ENGINE_SRC)
    missing = deps_missing()
    if not missing:
        print('engine dependencies: all %d present in %s' % (len(DEPENDENCIES), deps_dir()))
        return 0
    print('engine dependencies missing: ' + ', '.join(missing))
    candidates = deps_candidates()
    for name in list(missing):
        proof = dict(DEPENDENCIES)[name]
        for c in candidates:
            if os.path.exists(os.path.join(c, name, proof)):
                if link_dir(os.path.join(deps_dir(), name), os.path.join(c, name)):
                    print('  linked %-18s -> %s' % (name, os.path.join(c, name)))
                    break
    missing = deps_missing()
    if 'ffmpeg/x64' in missing:
        fetch_ffmpeg()
        missing = deps_missing()
    if not missing:
        print('engine dependencies: complete')
        return 0
    print()
    print('STILL MISSING in %s: %s' % (deps_dir(), ', '.join(missing)))
    print('These libraries are not in git (upstream keeps them as private archives). If you built the engine before, they are in the old engine checkout of that workspace')
    print('(for example ...\\SupCom_Dev_Workspace\\engine_decomp\\faf-re-upstream\\dependencies): point FAF_STUDIO_DEPS at that `dependencies` folder and run this again, e.g.')
    print('    set FAF_STUDIO_DEPS=C:\\Users\\<you>\\Documents\\SupCom_Dev_Workspace\\engine_decomp\\faf-re-upstream\\dependencies')
    print('    python scripts/studio.py deps')
    print('What each one is and how it is patched: engine/faf-re/dependencies/patches/*.md; FFmpeg: engine/faf-re/docs/FAF_SFD_COMPATIBILITY.md.')
    return 1


def patch_subject(path):
    """The commit subject of a format-patch file (the folded Subject header, without the [PATCH n/m] tag), whitespace normalised."""
    with open(path, 'rb') as f:
        msg = email.message_from_binary_file(f)
    subject = str(email.header.make_header(email.header.decode_header(msg.get('Subject', ''))))
    subject = re.sub(r'^\s*\[PATCH[^\]]*\]\s*', '', subject)
    return ' '.join(subject.split())


def engine_sync(a=None):
    """Applies the patches of engine/patches that the engine checkout does not have yet. `git pull` of this repository adds patch files but never touches engine/faf-re, so a
    build after a pull compiled the OLD engine: that is why the exe did not change. Matching is by commit subject. Returns the number of patches applied."""
    m = meta()
    dst = P.ENGINE_SRC
    if not os.path.isdir(os.path.join(dst, '.git')):
        raise SystemExit('no engine checkout at %s: python scripts/studio.py engine setup' % dst)
    patches = sorted(glob.glob(os.path.join(PATCHES, '*.patch')))
    code, out = git('log', '--format=%s', m['base'] + '..HEAD', cwd=dst)
    if code != 0:
        raise SystemExit('the engine checkout %s does not contain the base commit %s (engine/BASE.json): %s' % (dst, m['base'][:10], out[:200]))
    have = set(' '.join(line.split()) for line in out.splitlines())
    missing = [p for p in patches if patch_subject(p) not in have]
    if not missing:
        print('engine sources: all %d patches of engine/patches are applied' % len(patches))
        return 0
    code, out = git('status', '--porcelain', '--untracked-files=no', cwd=dst)
    if out.strip():
        raise SystemExit('%d new engine patches (%s ...) but the engine checkout has uncommitted changes, so they cannot be applied:\n%s\n'
                         'Commit them there (then `engine export`) or stash them, and run this again.' % (len(missing), os.path.basename(missing[0]), out))
    env = dict(os.environ, GIT_COMMITTER_NAME=os.environ.get('GIT_COMMITTER_NAME', 'FAF Studio'), GIT_COMMITTER_EMAIL=os.environ.get('GIT_COMMITTER_EMAIL', 'faf-studio@localhost'))
    print('engine sources lack %d patch(es): applying' % len(missing))
    for p in missing:
        print('  +', os.path.basename(p))
    r = run(['git', 'am', '--3way', '--keep-cr'] + missing, cwd=dst, check=False, env=env)
    if r.returncode != 0:
        run(['git', 'am', '--abort'], cwd=dst, check=False)
        raise SystemExit('the new patches do not apply to your engine checkout (it has changes of its own that clash). Nothing was changed. Options: commit your engine changes there and '
                         'run `engine export`, or move %s away and run `engine setup` for a fresh checkout.' % dst)
    print('engine sources are up to date: %d patch(es) applied' % len(missing))
    return len(missing)


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
    engine_sync(a)
    if cmd_deps(a) != 0:
        print('\nThe engine cannot be built until the libraries above are in place; nothing was compiled.')
        return 1
    log = os.path.join(P.ENGINE_DIR, 'build.log')
    os.makedirs(P.ENGINE_DIR, exist_ok=True)
    bat = os.path.join(P.ENGINE_DIR, '_build.bat')
    with open(bat, 'w') as f:
        f.write('@echo off\r\ncall "%s" >nul 2>&1\r\ncd /d "%s"\r\n' % (vc, P.SDK))
        f.write('msbuild main_ed.vcxproj /nologo /m /t:Build /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v145 "/p:DirectXInclude=%s\\Include" '
                '"/p:DirectXLibX64=%s\\Lib\\x64" /p:ContinueOnError=true "/flp:logfile=%s;verbosity=minimal;encoding=UTF-8" /p:CL_MPCount=8 /p:FafX64LargeAddress=heap\r\n' % (dx, dx, log))
        f.write('exit /b %ERRORLEVEL%\r\n')
    started = time.time()
    r = run(['cmd', '/c', bat], check=False)
    errors = 0
    if os.path.isfile(log):
        errors = sum(1 for line in open(log, encoding='utf-8', errors='replace') if ' error ' in line)
    print('build exit %d, %d error lines (log: %s)' % (r.returncode, errors, log))
    if r.returncode != 0 or errors:
        return 1
    exe = os.path.join(P.ENGINE_SRC, 'output', 'main', 'x64', 'Release', 'main_x64_la.exe')
    if not os.path.isfile(exe) or os.path.getmtime(exe) < started - 2:
        print('MSBuild reported success but %s was not rebuilt (its time is older than this build). Nothing was staged: the exe in %s stays the old one.' % (exe, P.ENGINE_BIN))
        return 1
    print('built %s (%s, %d bytes)' % (exe, time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(os.path.getmtime(exe))), os.path.getsize(exe)))
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
    out = os.path.join(P.ENGINE_SRC, 'output', 'main', 'x64', 'Release')
    exe = P.need(os.path.join(out, 'main_x64_la.exe'), 'the built engine', 'python scripts/studio.py engine build')
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
    for dll in glob.glob(os.path.join(out, '*.dll')):
        copy(dll, P.ENGINE_BIN)
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
    r = run([sys.executable, os.path.join(HERE, 'brand_exe.py')], check=False, capture_output=True, text=True)
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
    return {'setup': engine_setup, 'sync': lambda x: engine_sync(x) and 0, 'build': engine_build, 'stage': engine_stage, 'export': engine_export}[a.what](a)


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
    sub.add_parser('deps').set_defaults(f=cmd_deps)
    sub.add_parser('build').set_defaults(f=engine_build)
    p = sub.add_parser('engine')
    p.add_argument('what', choices=['setup', 'sync', 'build', 'stage', 'export'])
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
