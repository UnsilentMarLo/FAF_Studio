"""Where things live. Every script of this repository takes its paths from here, so a checkout works wherever it is and every location can be moved with an
environment variable.

    ROOT          this checkout (a git worktree of the repository has its own ROOT)
    MAIN          the first worktree of the repository: the engine checkout, the staged engine and the test instances are shared by all worktrees and live there
    ENGINE_SRC    the engine sources: a checkout of the reconstructed Forged Alliance engine with our `editor` patch series applied
                  (default MAIN/engine/faf-re, made by `python scripts/studio.py engine setup`)     env FAF_STUDIO_ENGINE_SRC
    SDK           ENGINE_SRC/src
    ENGINE_RUN    the staged engine: bin/ (exe, DLLs, init files) and fa_path.lua     (default MAIN/engine/run)                         env FAF_STUDIO_ENGINE_RUN
    ENGINE_BIN    ENGINE_RUN/bin
    RUNS          the test instances (scripts/editor_inst.py)                                                   (default MAIN/.runs)  env FAF_STUDIO_RUNS
    FAF_DATA      the FAForever client's data folder (game data, init_faf.lua, fa_path.lua)                      (default %ProgramData%/FAForever)  env FAF_DATA
    FAF_REPO      a checkout of FAForever/fa (only the generators that read FAF's own Lua / blueprints need it)  env FAF_STUDIO_FAF_REPO
    RETAIL        the retail Forged Alliance install (only tools/gen_env_library.py reads its maps)             env FAF_STUDIO_RETAIL, else `fa_path` of FAF_DATA/fa_path.lua
"""
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

_main = None


def main_checkout():
    global _main
    if _main:
        return _main
    out = subprocess.run(['git', '-C', ROOT, 'worktree', 'list', '--porcelain'], capture_output=True, text=True, encoding='utf-8', errors='replace').stdout
    for line in out.splitlines():
        if line.startswith('worktree '):
            _main = line[len('worktree '):].strip()
            break
    _main = os.path.normpath(_main or ROOT)          # backslashes: mklink reads '/x' as an option
    return _main


def _env_path(name, default):
    return os.path.normpath(os.environ.get(name) or default)


MAIN = main_checkout()
ENGINE_DIR = os.path.join(MAIN, 'engine')
ENGINE_SRC = _env_path('FAF_STUDIO_ENGINE_SRC', os.path.join(ENGINE_DIR, 'faf-re'))
SDK = os.path.join(ENGINE_SRC, 'src')
ENGINE_RUN = _env_path('FAF_STUDIO_ENGINE_RUN', os.path.join(ENGINE_DIR, 'run'))
ENGINE_BIN = os.path.join(ENGINE_RUN, 'bin')
RUNS = _env_path('FAF_STUDIO_RUNS', os.path.join(MAIN, '.runs'))
FAF_DATA = _env_path('FAF_DATA', os.path.join(os.environ.get('ProgramData', r'C:\ProgramData'), 'FAForever'))
FAF_REPO = os.environ.get('FAF_STUDIO_FAF_REPO') or os.path.join(MAIN, 'external', 'fa')


def retail_install():
    """The retail Forged Alliance folder, or None."""
    p = os.environ.get('FAF_STUDIO_RETAIL')
    if p:
        return os.path.normpath(p)
    try:
        text = open(os.path.join(FAF_DATA, 'fa_path.lua'), encoding='utf-8', errors='replace').read()
        m = re.search(r'fa_path\s*=\s*"([^"]+)"', text)
        return os.path.normpath(m.group(1)) if m else None
    except OSError:
        return None


def need(path, what, how):
    """Exit with a message that says what is missing and how to make it."""
    if not os.path.exists(path):
        raise SystemExit('%s not found: %s\n  %s' % (what, path, how))
    return path
