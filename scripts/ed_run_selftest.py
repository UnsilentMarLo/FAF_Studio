#!/usr/bin/env python3
"""Runs editor self tests in a fresh editor engine through the /edcmd channel and prints their results.

    python scripts/ed_run_selftest.py                      the standard set (command stack, terrain, props)
    python scripts/ed_run_selftest.py "<lua expr>[@seconds]" ...   run these expressions one after the other,
                                                           waiting `seconds` after each (default 1)

Each expression is a Lua chunk run in the editor's UI state; its returned text must start with PASS (or be
anything but FAIL / ERROR for a pass). Uses its own log and command file and stops only the engine it started.
"""
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
import studio_paths as P  # noqa: E402
RUN = P.ENGINE_RUN

STANDARD = [
    ("return import('/lua/editor/selftest_cmd.lua').Run()", 5),
    ("return import('/lua/editor/selftest_cmd.lua').Check2()", 0),
]


def run(steps, map_name="editor_blank"):
    exe = os.path.join(RUN, "bin", "main_x64_la.exe")
    log = os.path.join(RUN, "selftest.log")
    cmdfile = os.path.join(RUN, "edcmd_selftest.lua")
    for name in (log, cmdfile, cmdfile + ".out", cmdfile + ".stamp"):
        if os.path.exists(name):
            os.remove(name)
    shutil.copyfile(os.path.join(ROOT, "editor", "runtime", "init_editor.lua"),
                    os.path.join(RUN, "bin", "init_editor.lua"))
    cmd = [exe, "/init", "init_editor.lua", "/log", log, "/nomovie", "/nosound", "/windowed", "1280", "720",
           "/editor", "/map", map_name, "/edcmd", cmdfile]
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    proc = subprocess.Popen(cmd, cwd=os.path.join(RUN, "bin"), env=env)
    results = []
    try:
        for _ in range(150):
            time.sleep(1)
            if os.path.exists(log) and "command channel" in open(log, encoding="utf-8", errors="replace").read():
                break
        else:
            return [("start", "FAIL the engine did not reach the command channel")]
        time.sleep(3)
        for expr, wait in steps:
            if os.path.exists(cmdfile + ".out"):
                os.remove(cmdfile + ".out")
            with open(cmdfile, "w") as fh:
                fh.write(expr + "\n")
            text = None
            for _ in range(90):
                time.sleep(0.5)
                if os.path.exists(cmdfile + ".out"):
                    time.sleep(0.2)
                    text = open(cmdfile + ".out", encoding="utf-8", errors="replace").read().strip()
                    break
            results.append((expr, text if text is not None else "FAIL no answer"))
            time.sleep(wait)
    finally:
        proc.kill()
        proc.wait()
    return results


def main(argv):
    steps = []
    for a in argv:
        expr, _, wait = a.rpartition("@")
        if expr and wait.replace(".", "").isdigit():
            steps.append((expr, float(wait)))
        else:
            steps.append((a, 1))
    if not argv:
        steps = STANDARD
    results = run(steps)
    bad = 0
    for expr, text in results:
        ok = text.startswith("OK: PASS") or (text.startswith("OK:") and "FAIL" not in text and "ERROR" not in text)
        print(("PASS  " if ok else "FAIL  ") + expr)
        print("      " + text.replace("\n", "\n      "))
        bad += 0 if ok else 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
