#!/usr/bin/env python
"""Compiles every GPU kernel of EdGpuShaders.generated.h with the real HLSL compiler (fxc.exe of the Windows SDK, shader model cs_5_0), without the engine or a GPU.

    python scripts/gpu_fxc_check.py [kernel ...] [--keep DIR]

The generator's lint and the C++ emulation tests cannot see what the HLSL compiler rejects (found 2026-10-24: its preprocessor refuses `#define BARRIER()`, so no kernel
compiled at all on the first real run). Run this after changing a kernel or the prelude. Exit 0: all compile; 1: errors (listed per kernel).
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_paths as P  # noqa: E402


def find_fxc():
    base = os.path.join(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'), 'Windows Kits', '10', 'bin')
    found = sorted(glob.glob(os.path.join(base, '*', 'x64', 'fxc.exe')))
    return found[-1] if found else None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    keep = None
    if '--keep' in sys.argv:
        keep = sys.argv[sys.argv.index('--keep') + 1]
        args = [a for a in args if a != keep]
    fxc = find_fxc()
    if not fxc:
        print('fxc.exe not found (Windows SDK)')
        return 2
    header = os.path.join(P.SDK, 'moho', 'editor', 'EdGpuShaders.generated.h')
    text = open(header, encoding='utf-8').read()
    # a long kernel is several adjacent raw string literals (MSVC limits the length of one): join the pieces
    kernels = []
    for name, body in re.findall(r'kSource_(\w+)\[\] =(.*?)\)HLSL";', text, re.S):
        kernels.append((name, ''.join(re.findall(r'R"HLSL\((.*?)(?:\)HLSL")', body + ')HLSL"', re.S))))
    out_dir = keep or tempfile.mkdtemp(prefix='gpufxc_')
    os.makedirs(out_dir, exist_ok=True)
    bad = 0
    for name, src in kernels:
        if args and name not in args:
            continue
        path = os.path.join(out_dir, name + '.hlsl')
        with open(path, 'w', newline='') as f:
            f.write(src)
        r = subprocess.run([fxc, '/nologo', '/T', 'cs_5_0', '/E', 'CSMain', '/O3', path, '/Fo', os.path.join(out_dir, name + '.bin')], capture_output=True, text=True, errors='replace')
        if r.returncode != 0:
            bad += 1
            print('FAIL %s' % name)
            for line in (r.stdout + r.stderr).strip().splitlines()[:8]:
                print('   ' + line.replace(out_dir + os.sep, ''))
    print('%d kernels, %d failed (%s)' % (len([1 for n, _ in kernels if not args or n in args]), bad, out_dir))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
