#!/usr/bin/env python3
"""Golden data for the Lua SCM v5 reader / writer and the patch split (editor/runtime/lua/editor/scm.lua, selftest_meshimport.lua).

    python editor/tools/gen_scm_golden.py            writes testdata/scm_golden.scm and prints the split numbers the selftest expects
    python editor/tools/gen_scm_golden.py --check    compares the committed file with a fresh one (exit 1 when it differs)

The reference implementation is scripts/meshmaps/scm.py (writer, split). It lives in the main checkout; this script looks for it next to
the script's own repository and in the main checkout of a worktree. All numbers are dyadic fractions, so Python doubles and the editor's
32-bit Lua numbers hold exactly the same values.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "runtime", "lua", "editor", "testdata", "scm_golden.scm")


def find_scm():
    roots = [os.path.join(HERE, "..", "..")]
    try:
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=HERE, capture_output=True, text=True).stdout.strip()
        roots.append(os.path.join(os.path.abspath(os.path.join(HERE, common)), ".."))
    except OSError:
        pass
    for root in roots:
        path = os.path.abspath(os.path.join(root, "scripts", "meshmaps"))
        if os.path.isfile(os.path.join(path, "scm.py")):
            return path
    sys.exit("scripts/meshmaps/scm.py not found")


sys.path.insert(0, find_scm())
import scm  # noqa: E402

_orig_unit = scm._unit
# scm.write takes SC2's packed tangent words; the golden file wants plain float frames
scm._unit = lambda w: w if isinstance(w, tuple) else _orig_unit(w)

COUNT = 12


def golden_mesh():
    verts, tangents = [], []
    for k in range(COUNT):
        pos = (100 + k * 0.75, (k * k % 17) * 0.25 + 3.125, 200 - k * 1.5)
        nrm = (0.25 * (k % 3), 0.5, -0.125 * (k % 5))
        uv1 = (k * 0.125 - 2, 1.5 - k * 0.0625)
        uv2 = (k / 16, 1 - k / 16)
        verts.append((pos, nrm, uv1, uv2))
        tangents.append(((0.5, 0.25 * (k % 4), -0.5), (0.125 * k, 0.75, 0.0625)))
    indices = []
    for t in range(COUNT - 2):
        indices += [t, t + 1, t + 2]
    return verts, indices, tangents


def grid(n=40, step=8):
    verts, tangents = [], []
    for j in range(n):
        for i in range(n):
            verts.append(((float(i * step), float((i * j) % 7), float(j * step)), (0.0, 1.0, 0.0), (0.0, 0.0), (0.0, 0.0)))
            tangents.append(None)
    indices = []
    for j in range(n - 1):
        for i in range(n - 1):
            a, b, c, d = j * n + i, j * n + i + 1, (j + 1) * n + i, (j + 1) * n + i + 1
            indices += [a, c, b, b, c, d]
    return verts, indices, tangents


def split_numbers(limit=500, tile=64.0):
    verts, indices, tangents = grid()
    out = []
    for pv, pi, _ in scm.split(verts, indices, tangents, limit, tile):
        total = 0
        for k, v in enumerate(pv, 1):
            x, y, z = v[0]
            total = (total + k * int(x + 3 * z + 7 * y)) % 100003
        index_sum = 0
        for i, v in enumerate(pi, 1):
            index_sum = (index_sum + i * (v + 1)) % 100003
        out.append((len(pv), len(pi) // 3, total, index_sum))
    return out


def build(path):
    verts, indices, tangents = golden_mesh()
    scm.write(path, verts, indices, tangents, info=("Terrain mesh patch",))


def main():
    if "--check" in sys.argv:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = os.path.join(tmpdir, os.path.basename(OUT))      # the file name is the bone name inside the file
            build(tmp)
            same = open(tmp, "rb").read() == open(OUT, "rb").read()
        print("scm_golden.scm", "matches" if same else "DIFFERS")
        sys.exit(0 if same else 1)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    build(OUT)
    print("wrote", os.path.normpath(OUT), os.path.getsize(OUT), "bytes")
    print("SPLIT_EXPECTED = {")
    for row in split_numbers():
        print("    { %d, %d, %d, %d }," % row)
    print("}")


if __name__ == "__main__":
    main()
