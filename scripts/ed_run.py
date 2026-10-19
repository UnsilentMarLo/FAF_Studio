#!/usr/bin/env python3
"""Starts the recovered engine in editor mode (see docs/projects/MAP_EDITOR.md).

    python scripts/ed_run.py [map-name-or-scenario] [--sound] [--wait] [--edcmd]

Default map: editor_blank (the flat blank world, written by scripts/ed_make_blank_map.py).
Runs the staged engine (engine/run/bin/main_x64_la.exe); never touches the FAF install.
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_paths as P  # noqa: E402
RUN = P.ENGINE_RUN


def main(argv):
    exe = os.path.join(RUN, "bin", "main_x64_la.exe")
    if not os.path.exists(exe):
        print("engine not staged: copy output/main/x64/Release/main_x64_la.exe to", exe)
        return 2
    blank = os.path.join(ROOT, "editor", "runtime", "maps", "editor_blank", "editor_blank.scmap")
    if not os.path.exists(blank):
        subprocess.check_call([sys.executable, os.path.join(ROOT, "scripts", "ed_make_blank_map.py")])
    # the engine reads its init file from bin/: keep that copy in sync with the editor folder
    shutil.copyfile(os.path.join(ROOT, "editor", "runtime", "init_editor.lua"), os.path.join(RUN, "bin", "init_editor.lua"))
    args = [a for a in argv if not a.startswith("--")]
    flags = [a for a in argv if a.startswith("--")]
    map_name = args[0] if args else "editor_blank"
    cmd = [exe, "/init", "init_editor.lua", "/log", os.path.join(RUN, "run.log"), "/nomovie",
           "/windowed", "1280", "720", "/editor", "/map", map_name]
    if "--sound" not in flags:
        cmd.insert(5, "/nosound")
    if "--edcmd" in flags:
        cmd += ["/edcmd", os.path.join(RUN, "edcmd.lua")]
    p = subprocess.Popen(cmd, cwd=os.path.join(RUN, "bin"))
    print("started pid", p.pid, "log", os.path.join(RUN, "run.log"))
    if "--wait" in flags:
        return p.wait()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
