#!/usr/bin/env python
"""Per-beat sim digests of several headless executables on the same replays, compared beat by beat.

The proof that a build's simulation is upstream's: play the same recorded games in headless_x64.exe of plain upstream and of our
build (FAF_EDITOR=OFF, and the editor build's headless exe) with `--digests` / `--state-digests` and `--checksum-period 1`, so every
beat gives the MD5 of the sim's checksum and a digest of what the sim published; then compare the files. The first beat where
two builds differ is reported; identical files over thousands of beats say the sim is the same.

    python scripts/sim_digest_compare.py --run-dir C:/ProgramData/FAForever/bin_x64_digest --init init_parity.lua
        --exe up=<headless_x64.exe of upstream> --exe off=<...> --exe on=<...>
        --replay C:/.../28016454.scfareplay --replay ... --beats 6000 [--parallel 3] [--out DIR]

--run-dir is a folder with what headless needs next to the exe (the FAF data's init file `--init` that mounts the vault with the replay's map,
dxcompiler.dll, fafengine/ ...; tools/replay-parity/parity.py makes such a folder: bin_x64_<x>). Each exe is COPIED into it under its
own name (digest_<name>.exe), so builds never overwrite each other. Exit 0: every file equal; 1: a difference; 2: a run failed.
Only processes it started are ever stopped.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time


def read_digests(path):
    rows = {}
    try:
        with open(path, encoding="latin1") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    rows[int(parts[0])] = parts[1]
    except OSError:
        pass
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--init", default="init_parity.lua")
    ap.add_argument("--exe", action="append", required=True, help="name=path of a headless_x64.exe (the first one is the reference)")
    ap.add_argument("--replay", action="append", required=True)
    ap.add_argument("--beats", type=int, default=6000)
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--simworkers", default="8")
    ap.add_argument("--timeout-minutes", type=int, default=40)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    out = a.out or os.path.join(a.run_dir, "digests_" + time.strftime("%Y%m%d_%H%M%S"))
    os.makedirs(out, exist_ok=True)
    names = []
    for spec in a.exe:
        name, path = spec.split("=", 1)
        dst = os.path.join(a.run_dir, "digest_%s.exe" % name)
        shutil.copy2(path, dst)
        names.append((name, dst))

    jobs = []
    for replay in a.replay:
        rid = os.path.splitext(os.path.basename(replay))[0]
        for name, exe in names:
            base = os.path.join(out, "%s_%s" % (rid, name))
            jobs.append({"rid": rid, "name": name, "exe": exe, "replay": replay, "base": base})

    running = []
    pending = list(jobs)
    failed = []
    t0 = time.time()
    while pending or running:
        while pending and len(running) < a.parallel:
            j = pending.pop(0)
            cmd = [j["exe"], "--replay", j["replay"], "/init", os.path.join(a.run_dir, a.init), "/nosound", "/log", j["base"] + ".log",
                   "--label", "digest-%s-%s" % (j["rid"], j["name"]), "--timeout", str(a.timeout_minutes),
                   "--digests", j["base"] + ".digests", "--state-digests", j["base"] + ".state", "--checksum-period", "1",
                   "--stop-beat", str(a.beats), "/simworkers", a.simworkers]
            with open(j["base"] + ".out", "wb") as o:
                j["proc"] = subprocess.Popen(cmd, cwd=a.run_dir, stdout=o, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            running.append(j)
            print("started %s on %s (pid %d)" % (j["name"], j["rid"], j["proc"].pid), flush=True)
        time.sleep(2)
        for j in list(running):
            rc = j["proc"].poll()
            if rc is not None:
                running.remove(j)
                print("finished %s on %s: exit %d after %d s" % (j["name"], j["rid"], rc, time.time() - t0), flush=True)
                if rc != 0:
                    failed.append((j["rid"], j["name"], rc))

    # compare
    differ = 0
    ref = names[0][0]
    for replay in a.replay:
        rid = os.path.splitext(os.path.basename(replay))[0]
        for kind in ("digests", "state"):
            base = read_digests(os.path.join(out, "%s_%s.%s" % (rid, ref, kind)))
            print("%s %s: reference %s has %d beats (last %s)" % (rid, kind, ref, len(base), max(base) if base else "-"))
            for name, _ in names[1:]:
                other = read_digests(os.path.join(out, "%s_%s.%s" % (rid, name, kind)))
                first = None
                for beat in sorted(set(base) | set(other)):
                    if base.get(beat) != other.get(beat):
                        first = beat
                        break
                if first is None and base:
                    print("   %s: IDENTICAL over %d beats" % (name, len(other)))
                else:
                    differ += 1
                    print("   %s: DIFFERS, first at beat %s (%s vs %s)" % (name, first, base.get(first), other.get(first)))
    if failed:
        print("runs that failed:", failed)
        return 2
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())
