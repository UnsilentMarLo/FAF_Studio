#!/usr/bin/env python
"""Builds and runs the test of the exe's own start-up (engine/faf-re/src/moho/editor/tests/EdBootstrapTest.cpp: arguments, folders, copies, links, messages)
without the engine.

    python scripts/edbootstrap_test.py

Windows with Visual Studio: `cl` from a developer prompt; junction creation is tested for real. Elsewhere (Linux): mingw-w64 (x86_64-w64-mingw32-g++) and Wine; Wine can make no
links, so the test lets the module "link" by copying and skips what needs a real junction. Needs the engine checkout (python scripts/studio.py engine setup).
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_paths as P  # noqa: E402

SDK = P.SDK


def main():
    test = os.path.join(SDK, 'moho', 'editor', 'tests', 'EdBootstrapTest.cpp')
    mod = os.path.join(SDK, 'moho', 'editor', 'EdBootstrap.cpp')
    if not os.path.isfile(test):
        print('engine checkout not found or without patch 0034: %s (python scripts/studio.py engine setup)' % test)
        return 2
    work = os.path.join(tempfile.gettempdir(), 'edbootstrap_test')
    os.makedirs(work, exist_ok=True)
    exe = os.path.join(work, 'edbootstrap_test.exe')
    native = sys.platform == 'win32'
    if native and shutil.which('cl'):
        cmd = ['cl', '/nologo', '/std:c++20', '/EHsc', '/O1', '/I', SDK, '/Fe:' + exe, '/Fo:' + work + os.sep, test, mod, 'user32.lib', 'gdi32.lib']
        run = [exe, os.path.join(work, 'data')]
    else:
        gxx = shutil.which('x86_64-w64-mingw32-g++-posix') or shutil.which('x86_64-w64-mingw32-g++')
        if not gxx:
            print('neither cl nor x86_64-w64-mingw32-g++ found')
            return 2
        cmd = [gxx, '-std=c++20', '-O1', '-Wall', '-Wextra', '-I', SDK, '-o', exe, test, mod, '-static', '-static-libgcc', '-static-libstdc++', '-luser32', '-lgdi32']
        wine = [] if native else [shutil.which('wine64') or '/usr/lib/wine/wine64']
        data = os.path.join(work, 'data')
        run = wine + [exe, ('Z:' + data.replace('/', '\\')) if wine else data] + ([] if native else ['--copy-links'])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        return 2
    env = dict(os.environ, WINEPREFIX=os.environ.get('WINEPREFIX', os.path.join(work, 'wineprefix')), WINEDEBUG='-all', DISPLAY='')
    r = subprocess.run(run, env=env, text=True)
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
