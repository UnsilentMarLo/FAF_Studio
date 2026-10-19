"""Map > Resize over a real reload: Setup (known content in the blank 256 map), Start (resize into ../mapout, the session reloads), Verify (the new session and its saved folder).

    python scripts/editor_resize_flow.py <instance tag> [case ...]       cases: expand crop scale level (default: all)

Uses scripts/editor_inst.py (restarts the instance before every case so the document is clean). Exit 0 when every case passes.
"""
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
INST = os.path.join(HERE, "editor_inst.py")
LUA = "import('/lua/editor/selftest_resize.lua')"


def inst(*args, timeout=180):
    return subprocess.run([sys.executable, INST, *args], capture_output=True, text=True, timeout=timeout)


def cmd(tag, code, timeout=90):
    path = os.path.join(tempfile.gettempdir(), "resize_flow_%d.lua" % os.getpid())
    with open(path, "w", encoding="utf-8") as f:
        f.write("return " + code + "\n")
    r = inst("cmd", tag, path, "--timeout", str(timeout), timeout=timeout + 60)
    return (r.stdout + r.stderr).strip()


def run_case(tag, case):
    r = inst("start", tag, "--wait", "90")
    if "ready" not in r.stdout:
        return False, "start failed: " + (r.stdout + r.stderr)[-300:]
    out = cmd(tag, LUA + ".Setup()")
    print("   setup:", out)
    if "setup:" not in out:
        return False, "setup failed"
    out = cmd(tag, LUA + ".Start('%s')" % case)
    print("   start:", out)
    if "resizing" not in out:
        return False, "start failed"
    # the session reloads, the payload is applied, the folder is saved ~3 s later
    time.sleep(20)
    last = ""
    for _ in range(10):
        last = cmd(tag, LUA + ".Verify('%s', true)" % case, timeout=60)
        if "ALL PASSED" in last or "FAILED" in last:
            break
        time.sleep(8)
    print("   verify:", last)
    if "ALL PASSED" not in last:
        return False, last
    # File > Open of the saved folder: the .scmap and the files must hold the same content
    out = cmd(tag, LUA + ".Reopen()")
    print("   reopen:", out)
    time.sleep(20)
    for _ in range(10):
        last = cmd(tag, LUA + ".Verify('%s')" % case, timeout=60)
        if "ALL PASSED" in last or "FAILED" in last:
            break
        time.sleep(8)
    print("   verify after reopen:", last)
    return "ALL PASSED" in last, last


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    tag = sys.argv[1]
    cases = sys.argv[2:] or ["expand", "crop", "scale", "level"]
    bad = 0
    for case in cases:
        print("== " + case)
        ok, why = run_case(tag, case)
        print("   ->", "PASS" if ok else "FAIL")
        if not ok:
            bad += 1
    if os.environ.get("RESIZE_FLOW_KEEP"):
        return 1 if bad else 0
    inst("start", tag, "--wait", "90")          # leave the instance with a clean document
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
