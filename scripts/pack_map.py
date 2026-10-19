#!/usr/bin/env python
"""Zips a released map folder for the FAF vault: python scripts/pack_map.py <maps folder>/<name>.v0004 [out.zip]

The zip holds the folder itself as its root (name.v0004/...), without the editor's own files (*_editor.lua sidecar). Needs the folder to contain
<stem>_scenario.lua, <stem>_save.lua, <stem>_script.lua and <stem>.scmap."""
import os
import sys
import zipfile


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    folder = os.path.abspath(sys.argv[1]).rstrip("\\/")
    root = os.path.basename(folder)
    out = sys.argv[2] if len(sys.argv) > 2 else folder + ".zip"
    names = os.listdir(folder)
    stems = [n[: -len("_scenario.lua")] for n in names if n.endswith("_scenario.lua")]
    if len(stems) != 1:
        raise SystemExit("expected exactly one *_scenario.lua in %s, found %d" % (folder, len(stems)))
    stem = stems[0]
    for need in (stem + ".scmap", stem + "_save.lua", stem + "_script.lua"):
        if need not in names:
            raise SystemExit("missing " + need)
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, _, files in os.walk(folder):
            for f in files:
                if f.endswith("_editor.lua"):
                    continue
                full = os.path.join(dirpath, f)
                z.write(full, os.path.join(root, os.path.relpath(full, folder)).replace(os.sep, "/"))
                count += 1
    print("wrote %s (%d files)" % (out, count))


if __name__ == "__main__":
    main()
