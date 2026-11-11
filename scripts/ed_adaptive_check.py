#!/usr/bin/env python3
"""Adaptive map check (WP5 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md): opens adaptive maps of a maps folder in an editor instance, edits the groups of one option table through
adaptive.lua, writes the files and compares them with the files the map was loaded from (selftest_adaptive.Retail): only the edited table's line may differ.

    python scripts/ed_adaptive_check.py <instance tag> [--maps DIR] [--only NAME ...] [--limit N] [--wait S]

DIR defaults to the custom vault folder of the FAF client (fa_path.lua custom_vault_path/maps: the maps downloaded from the vault), else $FAF_RETAIL_MAPS. A map is taken when its folder has a
`*_tables.lua`. The folders are only read; the files written go to the instance's ../mapout/_adaptive_retail. Exit 0 when every map that could be opened passes.
"""
import argparse
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ed_roundtrip import cmd, scenario_of   # noqa: E402


def default_maps():
    env = os.environ.get("FAF_RETAIL_MAPS")
    if env and os.path.isdir(env):
        return env
    for lua in (r"C:\ProgramData\FAForever\fa_path.lua",):
        if os.path.isfile(lua):
            m = re.search(r'custom_vault_path\s*=\s*"([^"]+)"', open(lua, encoding="utf-8", errors="replace").read())
            if m and os.path.isdir(os.path.join(m.group(1), "maps")):
                return os.path.join(m.group(1), "maps")
    raise SystemExit("no maps folder: pass --maps")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tag")
    ap.add_argument("--maps")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--wait", type=int, default=60)
    a = ap.parse_args()
    root = a.maps or default_maps()
    maps = sorted(n for n in os.listdir(root) if os.path.isdir(os.path.join(root, n)) and scenario_of(os.path.join(root, n))
                  and any(f.lower().endswith("_tables.lua") for f in os.listdir(os.path.join(root, n))))
    if a.only:
        maps = [m for m in maps if m.lower() in [o.lower() for o in a.only]]
    if a.limit:
        maps = maps[: a.limit]
    print("%d adaptive maps in %s" % (len(maps), root))
    ok = bad = skipped = 0
    for name in maps:
        folder = os.path.join(root, name)
        vfs = "/maps/%s/%s" % (name.lower(), scenario_of(folder).lower())
        cmd(a.tag, "local ok, why = ed_vfs_mount(%r, %r) return import('/lua/editor/control.lua').LoadMap(%r)" % (folder.replace("\\", "/"), "/maps/" + name.lower(), vfs))
        time.sleep(6)
        res, deadline = "", time.time() + a.wait
        while time.time() < deadline:
            res = cmd(a.tag, "return import('/lua/editor/selftest_adaptive.lua').Retail()", timeout=90)
            if ("[" + vfs + "]") in res:
                break
            time.sleep(3)
        else:
            res = "TIMEOUT " + res
        print("== %s\n%s" % (name, res), flush=True)
        if "] PASS" in res:
            ok += 1
        elif "] SKIP" in res:
            skipped += 1        # an older template whose tables the model does not read, or a map without mex lists: nothing to edit
        else:
            bad += 1
    print("passed %d, skipped %d, failed or not run %d of %d" % (ok, skipped, bad, len(maps)))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
