#!/usr/bin/env python
"""The particle editor's retail audit (WP8, docs/projects/editor/WP8_PARTICLES.md): every emitter, beam and trail file of the game is read by the editor's natives and written back,
and the result is compared with the file byte for byte.

    python scripts/ed_fx_audit.py <tag> [--dir FOLDER] [--scd FILE]

<tag> is a running editor instance (python scripts/editor_inst.py start <tag> --exe <engine with the particle natives>).
Default: the retail effects.scd of the Forged Alliance install (from the FAF fa_path.lua), its effects/emitters/*.bp extracted to a temp folder and read from there (they have CRLF line
ends, as shipped). --dir takes a folder of .bp files instead, --scd another archive. Without either an unreadable install falls back to the game's own file system
(selftest_particles.Audit(): FAF's files, which are reformatted by hand and tools).

Reported per kind: files, read back as the same emitter, byte-identical through the plain writer (WriteEmitter: retail's editor layout), byte-identical through the file's own text
(the writer of the editor: only the keys an edit changes are replaced). Exit code 0 when every file reads back and is written back byte for byte, 1 otherwise.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def install_scd():
    for lua in (r"C:\ProgramData\FAForever\fa_path.lua", os.path.join(HERE, "..", "engine", "run", "fa_path.lua")):
        if os.path.isfile(lua):
            m = re.search(r'fa_path\s*=\s*"([^"]+)"', open(lua, encoding="utf-8", errors="replace").read())
            if m:
                scd = os.path.join(m.group(1), "gamedata", "effects.scd")
                if os.path.isfile(scd):
                    return scd
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tag")
    ap.add_argument("--dir")
    ap.add_argument("--scd")
    ap.add_argument("--timeout", type=int, default=240)
    a = ap.parse_args()

    tmp = None
    folder = a.dir
    if not folder:
        scd = a.scd or install_scd()
        if not scd:
            print("no effects.scd found: pass --scd or --dir")
            return 2
        tmp = tempfile.mkdtemp(prefix="fxaudit_")
        n = 0
        with zipfile.ZipFile(scd) as z:
            for name in z.namelist():
                low = name.lower()
                if low.startswith("effects/emitters/") and low.endswith(".bp"):
                    with open(os.path.join(tmp, os.path.basename(name)), "wb") as f:
                        f.write(z.read(name))
                    n += 1
        folder = tmp
        print("extracted %d files of %s" % (n, scd))
    names = sorted(f for f in os.listdir(folder) if f.lower().endswith(".bp"))
    lines = ["local names = {"] + ["  '%s'," % n.replace("'", "\\'") for n in names] + ["}"]
    lines.append("return import('/lua/editor/selftest_particles.lua').Audit('%s', names)" % folder.replace("\\", "/"))
    chunk = os.path.join(tempfile.gettempdir(), "fxaudit_%d.lua" % os.getpid())
    with open(chunk, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    r = subprocess.run([sys.executable, os.path.join(HERE, "editor_inst.py"), "cmd", a.tag, chunk, "--timeout", str(a.timeout), "--chars", "4000"], capture_output=True, text=True)
    text = (r.stdout + r.stderr).strip()
    print(text)
    m = re.search(r"emitters (\d+): read back as the same emitter (\d+), plain writer byte-identical (\d+), written back through the file's own text byte-identical (\d+) \| beams and trails (\d+): ok (\d+), byte-identical (\d+)", text)
    if not m:
        return 2
    e, ok, plain, kept, f, fok, fkept = map(int, m.groups())
    print("emitters %d: same %d, plain writer %d (%.1f%%), own text %d (%.1f%%); beams+trails %d: same %d, own text %d" % (e, ok, plain, 100.0 * plain / max(e, 1), kept, 100.0 * kept / max(e, 1), f, fok, fkept))
    return 0 if (ok == e and kept == e and fok == f and fkept == f) else 1


if __name__ == "__main__":
    sys.exit(main())
