#!/usr/bin/env python3
"""Prop scale round trip: Python writes a map with props (rotation, non-uniform and negative scale), the editor
engine opens it, dumps what it holds, saves it untouched and edited, and the Python .scmap reader checks the files.

    python scripts/ed_prop_roundtrip.py

Needs the editor engine staged (python scripts/studio.py build). It runs in its own editor instance (.runs/rt, scripts/editor_inst.py) and stops only that
process, so it does not touch a running editor.
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
TAG = "rt"
RUN = os.path.join(P.RUNS, TAG)
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
    """Runs the check in its own editor instance (scripts/editor_inst.py, tag `rt`); returns the selftest's answer or None."""
    inst = [sys.executable, os.path.join(HERE, "editor_inst.py")]
    subprocess.run(inst + ["new", TAG], check=True, stdout=subprocess.DEVNULL)
    started = subprocess.run(inst + ["start", TAG, "--map", "/maps/prop_scale_in.v0001/prop_scale_in_scenario.lua", "--wait", "150"],
                             capture_output=True, text=True)
    try:
        if started.returncode != 0:
            errors.append("engine did not reach the command channel: " + (started.stdout + started.stderr).strip()[-300:])
            return None
        cmdfile = os.path.join(RUN, "roundtrip_cmd.lua")
        with open(cmdfile, "w") as fh:
            fh.write("return import('/lua/editor/selftest_props.lua').Run('../mapout/prop_scale_out.v0001', 'prop_scale')" + chr(10))
        done = subprocess.run(inst + ["cmd", TAG, cmdfile, "--timeout", "120"], capture_output=True, text=True)
        if done.returncode != 0 or not done.stdout.strip():
            errors.append("no result from the engine: " + (done.stdout + done.stderr).strip()[-300:])
            return None
        return done.stdout
    finally:
        subprocess.run(inst + ["stop", TAG], stdout=subprocess.DEVNULL)


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
            ry = rot_y(-0.3)   # the engine's heading h is the file rows of rot_y(-h): MatrixToQuat / VAxes3 are the binary's (decompiled), Python's rot_y is the other way round
            if not (close(added[0]["rot_x"], ry[0]) and close(added[0]["rot_z"], ry[2])):
                errors.append(f"edit: added prop rotation {added[0]['rot_x']} {added[0]['rot_z']}")
    if errors:
        print("FAIL\n" + "\n".join(errors))
        return 1
    print("PASS: prop scale round trip (load, untouched save, edit and save) matches the Python reader")
    return 0


if __name__ == "__main__":
    sys.exit(main())
