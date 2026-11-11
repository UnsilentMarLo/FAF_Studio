#!/usr/bin/env python3
"""Retail round trip of the exact save (WP3 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md): every map of a maps folder is opened in an editor instance and saved untouched;
the file written must be the bytes of the file the map was read from.

    python scripts/ed_roundtrip.py <instance tag> [--maps DIR] [--exe NAME] [--only NAME ...] [--limit N] [--wait S]

DIR is the folder of the retail maps (default: $FAF_RETAIL_MAPS, else <Forged Alliance install>/maps read from the FAF fa_path.lua: SCMP_001 ... X1MP_017). It is only read.
Each map is queued with control.LoadMap (the session restarts), then selftest_roundtrip.Retail() saves it into the instance's ../mapout/_roundtrip folder and compares. Exit 0 when every
map that could be opened is identical.

Uses scripts/editor_inst.py (the instance must exist: python scripts/editor_inst.py new <tag>; start it once with the engine to test: --exe). Never kills by name.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
INST = os.path.join(HERE, "editor_inst.py")


def inst(*args, timeout=240):
    return subprocess.run([sys.executable, INST, *args], capture_output=True, text=True, timeout=timeout)


def cmd(tag, code, timeout=60):
    path = os.path.join(tempfile.gettempdir(), "roundtrip_%d.lua" % os.getpid())
    with open(path, "w", encoding="utf-8") as f:
        f.write(code + "\n")
    r = inst("cmd", tag, path, "--timeout", str(timeout), "--chars", "600", timeout=timeout + 60)
    return (r.stdout + r.stderr).strip()


def default_maps():
    env = os.environ.get("FAF_RETAIL_MAPS")
    if env and os.path.isdir(env):
        return env
    for lua in (r"C:\ProgramData\FAForever\fa_path.lua", os.path.join(HERE, "..", "engine", "run", "fa_path.lua")):
        if os.path.isfile(lua):
            m = re.search(r'fa_path\s*=\s*"([^"]+)"', open(lua, encoding="utf-8", errors="replace").read())
            if m and os.path.isdir(os.path.join(m.group(1), "maps")):
                return os.path.join(m.group(1), "maps")
    raise SystemExit("no retail maps folder: set FAF_RETAIL_MAPS or pass --maps")


def scenario_of(folder):
    names = [n for n in os.listdir(folder) if n.lower().endswith("_scenario.lua")]
    return names[0] if len(names) == 1 else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tag")
    ap.add_argument("--maps")
    ap.add_argument("--exe", default=None, help="engine exe of the instance (start it with this one first)")
    ap.add_argument("--only", nargs="*", default=[])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--wait", type=int, default=45, help="seconds to wait for a map to load")
    a = ap.parse_args()
    root = a.maps or default_maps()
    maps = sorted(n for n in os.listdir(root) if os.path.isdir(os.path.join(root, n)) and scenario_of(os.path.join(root, n)))
    if a.only:
        maps = [m for m in maps if m.lower() in [o.lower() for o in a.only]]
    if a.limit:
        maps = maps[: a.limit]
    print("%d maps in %s" % (len(maps), root))
    if a.exe:
        r = inst("start", a.tag, "--exe", a.exe, "--wait", "90")
        print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[-300:])
    same = diff = bad = 0
    lines = []
    for name in maps:
        folder = os.path.join(root, name)
        scen = scenario_of(folder)
        vfs = "/maps/%s/%s" % (name.lower(), scen.lower())
        # the map is opened from its own folder: a copy of the game's folder is not made, the VFS mounts it
        out = cmd(a.tag, "local ok, why = ed_vfs_mount(%r, %r) return import('/lua/editor/control.lua').LoadMap(%r)" % (folder.replace("\\", "/"), "/maps/" + name.lower(), vfs))
        time.sleep(6)
        res = ""
        deadline = time.time() + a.wait
        while time.time() < deadline:
            res = cmd(a.tag, "return import('/lua/editor/selftest_roundtrip.lua').Retail()", timeout=90)
            if ("[" + vfs + "]") in res:        # the answer of the session of THIS map (the old session answers until the new one is up)
                break
            time.sleep(3)
        else:
            res = "TIMEOUT " + res
        line = "%-10s %s" % (name, res.replace("\n", " ")[:240])
        print(line, flush=True)
        lines.append(line)
        if "OK stable=true same=true" in res:
            same += 1
        elif "] DIFF" in res or "same=false" in res or "stable=false" in res:
            diff += 1
        else:
            bad += 1
    print("identical %d, different %d, not run %d of %d" % (same, diff, bad, len(maps)))
    return 0 if diff == 0 and bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
