#!/usr/bin/env python3
"""Builds and runs the native test of the path ops (moho/editor/tests/EdPathTest.cpp, ops in EdFieldPath.cpp) with MSVC.

    python scripts/ed_path_test.py [--update]        $ED_EDITOR_ROOT = the git worktree whose cases file is used (default: this checkout)
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
CASES = os.path.join(os.environ.get("ED_EDITOR_ROOT", ROOT), "editor", "runtime", "lua", "editor", "selftest_paths_cases.lua")


def main():
    os.makedirs(OUT, exist_ok=True)
    exe = os.path.join(OUT, "EdPathTest.exe")
    test_src = os.path.join(SDK, "moho", "editor", "tests", "EdPathTest.cpp")
    srcs = " ".join('"%s"' % os.path.join(SDK, "moho", "editor", s) for s in ("EdFieldCore.cpp", "EdFieldPath.cpp"))
    cmd = ('call "%s" >nul 2>&1 && cl /nologo /std:c++20 /EHsc /O2 /W3 /I"%s" "%s" %s /Fe:"%s"' % (VCVARS, SDK, test_src, srcs, exe))
    r = subprocess.run(cmd, shell=True, cwd=OUT, capture_output=True, text=True, encoding="cp850", errors="replace")
    if r.returncode != 0:
        print(r.stdout[-4000:], r.stderr[-1000:])
        print("BUILD FAILED: EdPathTest")
        return 1
    r = subprocess.run([exe, CASES] + sys.argv[1:], capture_output=True, text=True, encoding="cp850", errors="replace")
    print(r.stdout.strip())
    return 0 if r.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
