#!/usr/bin/env python3
"""Builds and runs the native test of the interop ops (moho/editor/tests/EdInteropTest.cpp, ops in EdFieldInterop.cpp) with MSVC.

    python scripts/ed_interop_test.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
import studio_paths as P  # noqa: E402
SDK = os.environ.get("ED_SDK") or P.SDK      # the engine sources (engine/faf-re, made by studio.py engine setup)
OUT = os.path.join(P.ENGINE_DIR, "native_tests")
VCVARS = r"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"


def main():
    os.makedirs(OUT, exist_ok=True)
    exe = os.path.join(OUT, "EdInteropTest.exe")
    test_src = os.path.join(SDK, "moho", "editor", "tests", "EdInteropTest.cpp")
    srcs = " ".join('"%s"' % os.path.join(SDK, "moho", "editor", s) for s in ("EdFieldCore.cpp", "EdFieldInterop.cpp"))
    cmd = ('call "%s" >nul 2>&1 && cl /nologo /std:c++20 /EHsc /O2 /W3 /I"%s" "%s" %s /Fe:"%s"' % (VCVARS, SDK, test_src, srcs, exe))
    r = subprocess.run(cmd, shell=True, cwd=OUT, capture_output=True, text=True, encoding="cp850", errors="replace")
    if r.returncode != 0:
        print(r.stdout[-4000:], r.stderr[-1000:])
        print("BUILD FAILED: EdInteropTest")
        return 1
    r = subprocess.run([exe] + sys.argv[1:], capture_output=True, text=True, encoding="cp850", errors="replace")
    print(r.stdout.strip())
    return 0 if r.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
