#!/usr/bin/env python3
"""Gives a .scmap the `<default>` environment cube entry the game needs.

    python scripts/fix_scmap_envcube.py map.scmap [out.scmap]

A map whose list of environment cubes has no `<default>` entry crashes the game at tick 0 (ACCESS_VIOLATION in CWldTerrainRes::GetEnvLookup). Maps saved by the editor before
2026-10-21 had an empty list. The file is changed in place (a copy `map.scmap.bak` is kept) or written to out.scmap; everything else in it stays byte for byte.
"""
import struct
import sys

DEFAULT = b"<default>\0/textures/environment/defaultenvcube.dds\0"


def patch(data):
    if data[:4] != b"Map\x1a":
        raise SystemExit("not a .scmap")
    preview = struct.unpack_from("<I", data, 30)[0]
    o = 34 + preview
    minor, w, h = struct.unpack_from("<III", data, o)
    o += 12 + 4 + (w + 1) * (h + 1) * 2
    if minor < 56:
        return None, "minor %d keeps a single cube path, nothing to do" % minor
    o += 1
    for _ in range(3):                      # shader, background, sky cube
        o = data.index(b"\0", o) + 1
    count = struct.unpack_from("<I", data, o)[0]
    pos = o + 4
    for _ in range(count):
        end = data.index(b"\0", pos)
        key = data[pos:end]
        pos = data.index(b"\0", end + 1) + 1
        if key == b"<default>":
            return None, "already has a <default> cube"
    # append the entry after the existing ones and raise the count
    out = bytearray(data[:o]) + struct.pack("<I", count + 1) + data[o + 4:pos] + DEFAULT + data[pos:]
    return bytes(out), "added <default> (%d cube entries before)" % count


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    src = argv[1]
    data = open(src, "rb").read()
    new, message = patch(data)
    print(src + ": " + message)
    if new is None:
        return 0
    if len(argv) > 2:
        open(argv[2], "wb").write(new)
    else:
        open(src + ".bak", "wb").write(data)
        open(src, "wb").write(new)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
