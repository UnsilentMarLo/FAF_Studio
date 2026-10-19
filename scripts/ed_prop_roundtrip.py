#!/usr/bin/env python3
"""Prop scale round trip: Python writes a map with props (rotation, non-uniform and negative scale), the editor
engine opens it, dumps what it holds, saves it untouched and edited, and the Python .scmap reader checks the files.

    python scripts/ed_prop_roundtrip.py

Needs the editor engine staged (python scripts/studio.py engine stage). Stops only the engine process it started; it uses its
own log (roundtrip.log) and command file, so it does not touch a running editor's run.log.
"""
import math
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
sys.path.insert(0, os.path.join(HERE, "pylib"))
sys.path.insert(0, HERE)
import ed_make_blank_map  # noqa: E402
from scmap import ScMap  # noqa: E402

BLANK = "/env/common/props/markers/M_Blank_prop.bp"
EPS = 1e-4


def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return [c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]


def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return [1.0, 0.0, 0.0], [0.0, c, -s], [0.0, s, c]


def prop(position, rot, scale):
    rx, ry, rz = rot
    return dict(path=BLANK, position=position, rot_x=rx, rot_y=ry, rot_z=rz, scale=scale)


def make_props():
    return [
        prop([40.0, 25.0, 60.0], rot_y(0.7), [1.5, 1.5, 1.5]),
        prop([80.0, 25.0, 60.0], rot_x(0.4), [0.5, 2.0, 3.25]),
        prop([120.0, 25.0, 60.0], rot_y(0.0), [1.0, 1.0, 1.0]),
        prop([160.0, 25.0, 60.0], rot_y(2.5), [-1.0, 1.0, 1.0]),
    ]


def close(a, b, eps=EPS):
    return all(abs(x - y) <= eps for x, y in zip(a, b))


def read_props(folder, stem):
    return ScMap.read(os.path.join(folder, stem + ".scmap")).props


def compare(label, got, want, errors):
    if len(got) != len(want):
        errors.append(f"{label}: {len(got)} props, expected {len(want)}")
        return
    for i, (g, w) in enumerate(zip(got, want), 1):
        if g["path"] != w["path"]:
            errors.append(f"{label} prop {i}: path {g['path']} != {w['path']}")
        if not close(g["position"], w["position"], 1e-5):
            errors.append(f"{label} prop {i}: position {g['position']} != {w['position']}")
        for k in ("rot_x", "rot_y", "rot_z"):
            if not close(g[k], w[k]):
                errors.append(f"{label} prop {i}: {k} {g[k]} != {w[k]}")
        if not close(g["scale"], w["scale"], 0.0):
            errors.append(f"{label} prop {i}: scale {g['scale']} != {w['scale']}")


def run_engine(errors):
    exe = os.path.join(RUN, "bin", "main_x64_la.exe")
    log = os.path.join(RUN, "roundtrip.log")
    if os.path.exists(log):
        os.remove(log)
    shutil.copyfile(os.path.join(ROOT, "editor", "runtime", "init_editor.lua"),
                    os.path.join(RUN, "bin", "init_editor.lua"))
    cmdfile = os.path.join(RUN, "edcmd_roundtrip.lua")
    for name in (cmdfile, cmdfile + ".out", cmdfile + ".stamp", os.path.join(RUN, "bin", "edcmd_roundtrip.lua.stamp")):
        if os.path.exists(name):
            os.remove(name)
    cmd = [exe, "/init", "init_editor.lua", "/log", log, "/nomovie", "/nosound", "/windowed", "1280", "720",
           "/editor", "/map", "/maps/prop_scale_in.v0001/prop_scale_in_scenario.lua", "/edcmd", cmdfile]
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    proc = subprocess.Popen(cmd, cwd=os.path.join(RUN, "bin"), env=env)
    print("engine pid", proc.pid)
    result = None
    try:
        for _ in range(150):
            time.sleep(1)
            if os.path.exists(log) and "command channel" in open(log, encoding="utf-8", errors="replace").read():
                break
        else:
            errors.append("engine did not reach the command channel")
            return None
        time.sleep(3)
        with open(cmdfile, "w") as fh:
            fh.write("return import('/lua/editor/selftest_props.lua').Run('../mapout/prop_scale_out.v0001', 'prop_scale')\n")
        for _ in range(60):
            time.sleep(1)
            if os.path.exists(cmdfile + ".out"):
                result = open(cmdfile + ".out", encoding="utf-8").read()
                break
        else:
            errors.append("no result from the engine")
    finally:
        proc.kill()
        proc.wait()
    return result


def main():
    in_dir = os.path.join(RUN, "mapout", "prop_scale_in.v0001")
    proj = ed_make_blank_map.build(in_dir, stem="prop_scale_in")
    want = make_props()
    proj.scmap.props = want
    proj.save()
    errors = []
    compare("python in", read_props(in_dir, "prop_scale_in"), want, errors)

    out_dir = os.path.join(RUN, "mapout", "prop_scale_out.v0001")
    shutil.rmtree(out_dir, ignore_errors=True)
    result = run_engine(errors)
    if result is None:
        print("FAIL\n" + "\n".join(errors))
        return 1
    print(result.strip())
    if "FAIL" in result or result.startswith("ERROR"):
        errors.append("engine reported: " + result.strip().splitlines()[0])
    else:
        compare("pure round trip", read_props(os.path.join(out_dir, "pure"), "prop_scale_pure"), want, errors)
        # edit: prop 1 rescaled, prop 2 removed, then the two added props
        edited = read_props(os.path.join(out_dir, "edit"), "prop_scale_edit")
        kept = [dict(want[0]), want[2], want[3]]
        kept[0]["scale"] = [0.25, 0.5, 0.75]
        compare("edit (kept props)", edited[:3], kept, errors)
        added = edited[3:]
        if len(added) != 2:
            errors.append(f"edit: {len(added)} added props, expected 2")
        else:
            if not close(added[0]["scale"], [2.0, 3.0, 4.0], 0.0):
                errors.append(f"edit: added prop scale {added[0]['scale']}")
            if not close(added[1]["scale"], [1.75, 1.75, 1.75], 0.0):
                errors.append(f"edit: uniform prop scale {added[1]['scale']}")
            ry = rot_y(0.3)
            if not (close(added[0]["rot_x"], ry[0]) and close(added[0]["rot_z"], ry[2])):
                errors.append(f"edit: added prop rotation {added[0]['rot_x']} {added[0]['rot_z']}")
    if errors:
        print("FAIL\n" + "\n".join(errors))
        return 1
    print("PASS: prop scale round trip (load, untouched save, edit and save) matches the Python reader")
    return 0


if __name__ == "__main__":
    sys.exit(main())
