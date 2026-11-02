#!/usr/bin/env python
"""Static cross-module check of the editor's Lua (no engine needed): every `Mod.Name` used on a module imported with
`local Mod = import('/lua/editor/....lua')` (or `import('...').Name` directly) must be defined by that module.

    python scripts/editor_lint.py [--root editor/runtime/lua] [--verbose]

Why: Moho module tables are strict, so a call to a function the module does not export raises at runtime ("access to nonexistent global variable") only when that
line runs: ui.lua's `Say` was a local while 40 callers used it (found 2026-10-19).

A module defines a name by
  - a top-level `function Name`, `Name = ...`, `Name, Other = ...` or `Name.field = ...`,
  - `function Name(...)` at any depth (inside a `do` block or a function: no `local`, so it is a module global),
  - `Name = ...` at any depth when `Name` is not declared `local` / as a parameter / as a loop variable anywhere in the file (an assignment to an undeclared name is a module global).
Not followed: re-exports through another module, names created with rawset / setmetatable, `_G[...]`.
An alias that the importing file also uses as another local (`local c = import(...)` at the top, `local c = {}` in a function) is ambiguous and skipped (--verbose lists them).
Anything that still is a false positive goes into ALLOW below with the reason.
Exit code 0 = nothing missing, 1 = missing names (listed with file:line), 2 = setup problem.

Also (scripts/lua_dialect.py, `--no-dialect` skips it): the Lua 5.0 / LuaPlus dialect lint of every file under editor/runtime (`^`, `#`, `%`, `...`, string.match, goto, a module variable set
to nil, unbalanced blocks, text templates that hold Lua source) and the rules of the hooks (editor/runtime/schook/** and mods/*/hook/**: only `do ... end` at the top level, the path is a game
file, the old function is called with all arguments). Warnings (`loopclosure`, `hook-args`) are counted and listed with `--warnings`; errors fail the run.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

IMPORT_LOCAL = re.compile(r"^\s*local\s+([A-Za-z_]\w*)\s*=\s*import\(\s*'(/lua/editor/[^']+\.lua)'\s*\)\s*$")
IMPORT_INLINE = re.compile(r"import\(\s*'(/lua/editor/[^']+\.lua)'\s*\)\.([A-Za-z_]\w*)")
DEF_FUNC = re.compile(r"^function\s+([A-Za-z_]\w*)\s*\(")
DEF_FUNC_ANY = re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\(")
DEF_ASSIGN = re.compile(r"^([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*=[^=]")
DEF_ASSIGN_ANY = re.compile(r"^\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*=[^=]")
DEF_FIELD = re.compile(r"^([A-Za-z_]\w*)[.\[]")
DECL_LOCAL_FUNC = re.compile(r"\blocal\s+function\s+([A-Za-z_]\w*)")
DECL_LOCAL = re.compile(r"\blocal\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)")
DECL_FOR = re.compile(r"\bfor\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+(?:in|=)\b")
DECL_PARAMS = re.compile(r"\bfunction\s*[\w.:]*\s*\(([^)]*)\)")
KEYWORDS = {'local', 'function', 'if', 'for', 'while', 'return', 'end', 'do', 'then', 'else', 'elseif', 'repeat', 'until', 'break', 'continue', 'and', 'or', 'not', 'nil', 'true', 'false', 'in'}

# (file relative to the lua root with / separators, module path, name): reason. Reviewed false positives only; keep this list empty if the rules above cover it.
ALLOW = {}


def strip_comment(line):
    i = line.find('--')
    if i < 0:
        return line
    q = line[:i]
    if q.count("'") % 2 == 0 and q.count('"') % 2 == 0:
        return q
    return line


def code_lines(text):
    out = []
    in_block = False
    for raw in text.splitlines():
        line = raw.rstrip('\r')
        if in_block:
            if ']]' in line:
                in_block = False
            continue
        if line.lstrip().startswith('--[['):
            if ']]' not in line:
                in_block = True
            continue
        out.append(strip_comment(line))
    return out


def definitions(path, cache={}):
    if path in cache:
        return cache[path]
    try:
        text = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        cache[path] = None
        return None
    lines = code_lines(text)
    declared = set()                      # local / parameter / loop-variable names anywhere in the file
    for line in lines:
        for m in DECL_LOCAL_FUNC.finditer(line):
            declared.add(m.group(1))
        for m in DECL_LOCAL.finditer(line):
            declared.update(n.strip() for n in m.group(1).split(','))
        for m in DECL_FOR.finditer(line):
            declared.update(n.strip() for n in m.group(1).split(','))
        for m in DECL_PARAMS.finditer(line):
            declared.update(n.strip() for n in m.group(1).split(','))
    names = set()
    for line in lines:
        m = DEF_FUNC.match(line) or DEF_FUNC_ANY.match(line)
        if m:
            names.add(m.group(1))
            continue
        indented = line[:1] in (' ', '\t')
        if indented:
            m = DEF_ASSIGN_ANY.match(line)
            if m:
                for n in m.group(1).split(','):
                    n = n.strip()
                    if n and n not in KEYWORDS and n not in declared:
                        names.add(n)
            continue
        if line == '' or line.startswith(('local ', '--', 'end', ')')):
            continue
        m = DEF_ASSIGN.match(line)
        if m:
            for n in m.group(1).split(','):
                n = n.strip()
                if n and n not in KEYWORDS:
                    names.add(n)
            continue
        m = DEF_FIELD.match(line)
        if m and m.group(1) not in KEYWORDS:
            names.add(m.group(1))
    cache[path] = names
    return names


def ambiguous_aliases(lines, aliases):
    """Aliases that the file also declares as another local / parameter / loop variable."""
    out = set()
    for alias in aliases:
        a = re.escape(alias)
        pats = [re.compile(r'\blocal\s+(?:[A-Za-z_]\w*\s*,\s*)*' + a + r'\b(?!\s*=\s*import)'),
                re.compile(r'\bfor\s+(?:[A-Za-z_]\w*\s*,\s*)?' + a + r'\s+(?:in|=)\b'),
                re.compile(r'\bfunction\s*[\w.:]*\s*\([^)]*\b' + a + r'\b[^)]*\)')]
        for line in lines:
            if IMPORT_LOCAL.match(line):
                continue
            code = strip_comment(line)
            if any(p.search(code) for p in pats):
                out.add(alias)
                break
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default=None)
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--no-dialect', action='store_true', help='skip the dialect and hook lint')
    ap.add_argument('--warnings', action='store_true', help='list the dialect warnings too')
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    root = a.root or os.path.join(os.path.dirname(here), 'editor', 'runtime', 'lua')
    if not os.path.isdir(root):
        print('no such folder: %s' % root)
        return 2
    files = []
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.lua'):
                files.append(os.path.join(d, f))
    problems, checked, skipped = [], 0, 0
    for path in sorted(files):
        try:
            text = open(path, encoding='utf-8', errors='replace').read().replace('\r\n', '\n')
        except OSError:
            continue
        lines = text.split('\n')
        aliases = {}
        for line in lines:
            m = IMPORT_LOCAL.match(line)
            if m:
                aliases[m.group(1)] = m.group(2)
        amb = ambiguous_aliases(lines, list(aliases))
        for name in amb:
            if a.verbose:
                print('skipped ambiguous alias %s in %s' % (name, os.path.relpath(path, root)))
            skipped += 1
            aliases.pop(name, None)
        rel = os.path.relpath(path, root).replace(os.sep, '/')
        for i, raw in enumerate(lines):
            line = strip_comment(raw)
            uses = [(m.group(1), m.group(2)) for m in IMPORT_INLINE.finditer(line)]
            bare = re.sub(r"'[^']*'|\"[^\"]*\"", "''", line)       # names inside strings are not uses
            for alias, target in aliases.items():
                for m in re.finditer(r'(?<![\w.:])' + re.escape(alias) + r'\.([A-Za-z_]\w*)', bare):
                    if re.match(r'\s*=(?!=)', bare[m.end():]):
                        continue                                       # Mod.Field = value sets a field: no read of a missing name
                    uses.append((target, m.group(1)))
            for target, name in uses:
                tpath = os.path.join(root, target[len('/lua/'):])
                defs = definitions(tpath)
                if defs is None:
                    continue
                checked += 1
                if name not in defs and (rel, target, name) not in ALLOW:
                    problems.append((os.path.relpath(path, root), i + 1, target, name))
    seen, out = set(), []
    for p in problems:
        key = (p[0], p[2], p[3])
        if key not in seen:
            seen.add(key)
            out.append(p)
    for f, ln, target, name in out:
        print('%s:%d  %s has no `%s`' % (f, ln, target, name))
    print('%d uses checked, %d names missing, %d ambiguous aliases skipped, %d allow-listed' % (checked, len(out), skipped, len(ALLOW)))
    rc = 1 if out else 0
    if not a.no_dialect:
        import lua_dialect
        import hook_baseline
        game = hook_baseline.Game()
        have = game.available()
        errors, warnings, nfiles = lua_dialect.run(os.path.dirname(os.path.normpath(root)), (lambda rel: ('lua/' + rel[4:]).lower() in game.index if rel.lower().startswith('lua/') else rel.lower() in game.index) if have else None)
        if have:
            problems, build = hook_baseline.compare(game)
            for level, text in problems:
                warnings.append('schook/BASELINE.txt  hook-baseline  %s: %s' % (level, text))
        for e in errors:
            print(e)
        if a.warnings:
            for w in warnings:
                print('warning: ' + w)
        print('dialect: %d files, %d errors, %d warnings%s (hook paths and base functions checked against the installed game: %s)' % (
            nfiles, len(errors), len(warnings), '' if a.warnings or not warnings else ' (--warnings lists them)', 'yes' if have else 'no game Lua found, structure only'))
        if errors:
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
