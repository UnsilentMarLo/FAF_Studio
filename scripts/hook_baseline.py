#!/usr/bin/env python
"""Baselines of the game's functions the schook hooks replace or wrap.

A hook under editor/runtime/schook/<vfs path> is appended to the game's file and replaces functions of it (`StartCommandLineSession`, `StartFrontEndUI`, `CreateResources`,
`StructureUnit.CreateTarmac` ...). When FAF changes such a function, the hook goes on replacing it with a copy of what it used to do. This tool keeps a fingerprint (a hash of the
function's tokens, comments and layout ignored) of every base function a hook depends on in `editor/runtime/schook/BASELINE.txt`, read from the installed game (FAForever/data
`gamedata/*.nx2`, archives of the game's Lua; or a FAForever/fa checkout: FAF_STUDIO_FAF_REPO).

    python scripts/hook_baseline.py check      compare the installed game with BASELINE.txt (exit 1 on a changed or missing function; editor_lint.py prints the same as warnings)
    python scripts/hook_baseline.py update     rewrite BASELINE.txt from the installed game (after reading the changed functions and fixing the hooks)
    python scripts/hook_baseline.py show       list what the hooks depend on and the current fingerprints

What a hook depends on: every `function Name(` it defines that the base file defines too, every `base<Class>.Name(` it calls, and every name in a `-- baseline: A, B` comment line.
Also written: the game build the hooks were read against (`# game 3840`); lua/editor/hookcheck.lua compares it with the running game and warns.
"""
import hashlib
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lua_dialect as L
import studio_paths as P

SCHOOK = os.path.join(P.ROOT, 'editor', 'runtime', 'schook')
MANIFEST = os.path.join(SCHOOK, 'BASELINE.txt')


class Game(object):
    """The game's Lua files by lower case VFS path: from archives in <FAF data>/gamedata or a FAForever/fa checkout."""

    def __init__(self):
        self.index = {}
        self.build = None
        repo = P.FAF_REPO
        if os.path.isdir(repo):
            for d, _, fs in os.walk(repo):
                for f in fs:
                    if f.lower().endswith('.lua'):
                        full = os.path.join(d, f)
                        rel = os.path.relpath(full, repo).replace(os.sep, '/').lower()
                        self.index[rel] = ('file', full)
        gd = os.path.join(P.FAF_DATA, 'gamedata')
        if os.path.isdir(gd):
            for name in sorted(os.listdir(gd)):
                if name.lower().endswith(('.nx2', '.nx4', '.nx5', '.scd')):
                    try:
                        z = zipfile.ZipFile(os.path.join(gd, name))
                    except (zipfile.BadZipFile, OSError):
                        continue
                    for n in z.namelist():
                        if n.lower().endswith('.lua') and n.lower() not in self.index:
                            self.index[n.lower()] = ('zip', os.path.join(gd, name), n)
        self.build = self._build()

    def _build(self):
        """The game build the hooks were read against: VERIFIED in lua/editor/hookcheck.lua (the build number is not in the game's Lua: the exe reports it)."""
        try:
            text = open(os.path.join(P.ROOT, 'editor', 'runtime', 'lua', 'editor', 'hookcheck.lua'), encoding='utf-8').read()
        except OSError:
            return None
        m = re.search(r'^VERIFIED\s*=\s*(\d+)', text, re.M)
        return m.group(1) if m else None

    def read(self, vfs):
        e = self.index.get(vfs.lower().lstrip('/'))
        if not e:
            return None
        if e[0] == 'file':
            return open(e[1], encoding='utf-8', errors='replace').read()
        return zipfile.ZipFile(e[1]).read(e[2]).decode('utf-8', 'replace')

    def available(self):
        return len(self.index) > 0


def fingerprint(text, name):
    """Hash of the tokens of the function `name` in a Lua file (`function name(`, `function X.name(` / `X:name(` or `name = function(`), or None."""
    toks, _ = L.lex(text)
    ends = L.block_ends(toks)
    n = len(toks)
    found = []
    for i, t in enumerate(toks):
        if t.kind == 'kw' and t.val == 'function' and i in ends:
            j = i + 1
            last = None
            while j < n and toks[j].val != '(':
                if toks[j].kind == 'name':
                    last = toks[j].val
                j += 1
            if last == name and j < n and toks[j].val == '(':
                found.append((i, ends[i]))
            elif i >= 2 and toks[i - 1].val == '=' and toks[i - 2].kind == 'name' and toks[i - 2].val == name:
                found.append((i, ends[i]))
    if not found:
        return None
    parts = []
    for a, b in found:
        parts.append(' '.join(x.val for x in toks[a:b + 1] if True))
    return hashlib.sha1('\n'.join(parts).encode('utf-8')).hexdigest()[:16]


def hook_dependencies(text):
    """Names of the base functions a hook file depends on."""
    toks, _ = L.lex(text)
    names = set()
    n = len(toks)
    for i, t in enumerate(toks):
        if t.kind == 'kw' and t.val == 'function' and i + 2 < n and toks[i + 1].kind == 'name' and toks[i + 2].val == '(':
            names.add(toks[i + 1].val)
        if t.kind == 'name' and t.val.startswith('base') and i + 3 < n and toks[i + 1].val == '.' and toks[i + 2].kind == 'name' and toks[i + 3].val == '(':
            names.add(toks[i + 2].val)
    for m in re.finditer(r'--\s*baseline:\s*([\w, ]+)', text):
        for x in m.group(1).split(','):
            if x.strip():
                names.add(x.strip())
    return names


def wanted(game):
    """-> list of (vfs path, function name, fingerprint or None) for every hook file."""
    out = []
    for d, _, fs in os.walk(SCHOOK):
        for f in sorted(fs):
            if not f.endswith('.lua'):
                continue
            path = os.path.join(d, f)
            vfs = os.path.relpath(path, SCHOOK).replace(os.sep, '/')
            hook = open(path, encoding='utf-8', errors='replace').read()
            base = game.read(vfs)
            for name in sorted(hook_dependencies(hook)):
                fp = fingerprint(base, name) if base else None
                if fp is None and base is not None:
                    # a name the hook only defines (a new function of its own) is not a dependency
                    continue
                out.append((vfs, name, fp))
    return out


def read_manifest():
    rows, build = {}, None
    if not os.path.isfile(MANIFEST):
        return rows, build
    for line in open(MANIFEST, encoding='utf-8'):
        line = line.rstrip('\r\n')
        if line.startswith('# game '):
            build = line[len('# game '):].strip()
        elif line and not line.startswith('#'):
            parts = line.split('|')
            if len(parts) == 3:
                rows[(parts[0], parts[1])] = parts[2]
    return rows, build


def compare(game):
    """-> list of (level, text): 'changed' / 'missing' / 'new' against BASELINE.txt."""
    rows, build = read_manifest()
    problems = []
    seen = set()
    for vfs, name, fp in wanted(game):
        seen.add((vfs, name))
        old = rows.get((vfs, name))
        if fp is None:
            problems.append(('missing', '%s: the game has no function `%s` any more (the hook replaces or calls it)' % (vfs, name)))
        elif old is None:
            problems.append(('new', '%s: `%s` is not in BASELINE.txt (python scripts/hook_baseline.py update)' % (vfs, name)))
        elif old != fp:
            problems.append(('changed', '%s: the game\'s `%s` is not the version the hook was written against (read it, fix the hook, then `hook_baseline.py update`)' % (vfs, name)))
    for key in rows:
        if key not in seen:
            problems.append(('new', '%s: `%s` is in BASELINE.txt but no hook depends on it any more' % key))
    return problems, build


def update(game):
    lines = ['# Fingerprints of the game functions the schook hooks replace or wrap (scripts/hook_baseline.py). Written from the installed game.',
             '# game %s' % (game.build or 'unknown')]
    for vfs, name, fp in wanted(game):
        if fp:
            lines.append('%s|%s|%s' % (vfs, name, fp))
    open(MANIFEST, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines) + '\n')
    print('wrote %s: %d functions, game %s' % (MANIFEST, len(lines) - 2, game.build))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'check'
    game = Game()
    if not game.available():
        print('no game Lua found (FAForever data %s / checkout %s): nothing to compare' % (os.path.join(P.FAF_DATA, 'gamedata'), P.FAF_REPO))
        return 0 if cmd == 'check' else 2
    if cmd == 'update':
        update(game)
        return 0
    if cmd == 'show':
        for vfs, name, fp in wanted(game):
            print('%-48s %-28s %s' % (vfs, name, fp))
        return 0
    problems, build = compare(game)
    for level, text in problems:
        print('%s: %s' % (level, text))
    print('hook baselines: %d problems (manifest game build %s, installed %s)' % (len(problems), build, game.build))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
