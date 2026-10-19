"""Platoons / orders / builders over a real map and a reload: opens a map that has platoon builders, edits them, saves a copy, reopens it and compares.

    python scripts/editor_platoons_flow.py <instance tag> [scenario path ...]       default: the user's SCCA_Coop_A01 and SCCA_Coop_E01 (campaign missions with platoon builders)

Uses scripts/editor_inst.py. Exit 0 when every map passes. The copies are written to the instance's mapout folder.
"""
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
INST = os.path.join(HERE, "editor_inst.py")
LUA = "import('/lua/editor/selftest_platoons.lua')"
DEFAULT = ["/maps/scca_coop_a01.v0017/SCCA_Coop_A01_scenario.lua", "/maps/scca_coop_e01.v0023/SCCA_Coop_E01_scenario.lua"]


def inst(*args, timeout=180):
    return subprocess.run([sys.executable, INST, *args], capture_output=True, text=True, timeout=timeout)


def cmd(tag, code, timeout=90):
    path = os.path.join(tempfile.gettempdir(), "platoons_flow_%d.lua" % os.getpid())
    with open(path, "w", encoding="utf-8") as f:
        f.write("return " + code + "\n")
    r = inst("cmd", tag, path, "--timeout", str(timeout), timeout=timeout + 60)
    return (r.stdout + r.stderr).strip()


def run_map(tag, scenario):
    r = inst("start", tag, "--wait", "90")
    if "ready" not in r.stdout:
        return False
    print("   open:", cmd(tag, LUA + ".RoundTripStart('%s')" % scenario))
    time.sleep(25)
    out = ""
    for _ in range(8):
        out = cmd(tag, LUA + ".RoundTripEdit()", timeout=120)
        if "FAIL the map has no platoon builders" in out or "saved" in out or "FAIL save" in out:
            break
        time.sleep(8)
    print("   edit:", out)
    if "saved" not in out:
        return False
    time.sleep(25)
    last = ""
    for _ in range(8):
        last = cmd(tag, LUA + ".RoundTripVerify()", timeout=60)
        if "ALL PASSED" in last or "FAILED" in last:
            break
        time.sleep(8)
    print("   verify:", last)
    return "ALL PASSED" in last


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    tag = sys.argv[1]
    maps = sys.argv[2:] or DEFAULT
    bad = 0
    for m in maps:
        print("==", m)
        ok = run_map(tag, m)
        print("   ->", "PASS" if ok else "FAIL")
        bad += 0 if ok else 1
    if not os.environ.get("PLATOONS_FLOW_KEEP"):
        inst("start", tag, "--wait", "90")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
