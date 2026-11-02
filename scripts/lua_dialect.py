"""Lua 5.0 / Moho LuaPlus dialect lint and the rules of the schook hooks (used by editor_lint.py, run by `studio.py check`).

A small Lua lexer (strings, long strings, comments) so that nothing inside a string or a comment is ever flagged. Rules:

Dialect (every .lua file under editor/runtime):
  caret         `^` (write math.pow)                              not an operator in the dialect
  hash          `#` outside a string / comment (the length operator is table.getn; in LuaPlus `#` starts a comment: `#t` silently cuts the line). A `#` that is the first
                character of a line is an old style comment and is allowed
  percent       `%` operator (math.mod)
  vararg        `...` as an expression (read the `arg` table); allowed only in a parameter list
  api           string.match / :match( / gmatch (write string.find / string.gfind), goto and ::labels::, select() (the arg table), table.unpack / pack
  modulenil     a module level `Name = nil` (a module variable must exist: use false, `nil` creates nothing and the strict globals raise on the first read)
  balance       `end` / `until` that do not match the blocks (a cheap syntax check)
  loopclosure   (warning) a function made inside a `for` body that reads the loop variable: closures share it, copy it to a local first
Templates: a string literal that holds Lua source (it has a newline and `function` / `local` / `then`) is lexed again and only the identifier rules (`api`, `hash` followed by a name)
apply (the mission emitter's text templates; the generated output itself is tested by the mission selftests).

Hooks (editor/runtime/schook/** and mods/*/hook/**, appended to the base file as one chunk):
  hook-toplevel nothing at the file's top level except `do ... end` blocks (no `local`, no statement: a top-level `local` of the base file's chunk collides and counts against its
                limit of 200 locals)
  hook-path     the path below schook/ is the VFS path of the file it extends; with the game's Lua at hand (FAForever data gamedata/*.nx2, or a FAForever/fa checkout: FAF_STUDIO_FAF_REPO) the file has to exist there
  hook-args     (warning) `local old = X` ... `function X(a, b, c)` whose call of `old(...)` passes fewer arguments than X takes

Allow list: ALLOW below, (relative path, rule, line) -> reason. Keep it short; fix the code first.
"""
import os
import re

KEYWORDS = {'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while'}

# (path relative to editor/runtime with /, rule, line): reason
ALLOW = {}

RULE_TEXT = {
    'caret': '`^` is not an operator in this dialect (write math.pow)',
    'hash': '`#` outside a string: not the length operator here (table.getn), in LuaPlus it starts a comment',
    'percent': '`%` is not an operator here (write math.mod)',
    'vararg': '`...` used as an expression (read the `arg` table)',
    'api': 'not in Lua 5.0 / LuaPlus',
    'modulenil': 'a module variable set to nil does not exist (use false)',
    'balance': 'block structure does not balance',
    'hook-toplevel': 'a hook file may only contain do ... end blocks at its top level',
    'hook-path': 'the schook path is not a game file',
    'hook-args': 'the old function is called with fewer arguments than the new one takes',
    'loopclosure': 'a function in a for loop reads the loop variable (closures share it: copy it to a local)',
}
WARNINGS = {'loopclosure', 'hook-args'}


class Tok(object):
    __slots__ = ('kind', 'val', 'line', 'col', 'bol')

    def __init__(self, kind, val, line, col, bol):
        self.kind, self.val, self.line, self.col, self.bol = kind, val, line, col, bol

    def __repr__(self):
        return '%s(%r)@%d' % (self.kind, self.val, self.line)


def _long_bracket(text, i):
    """text[i] == '[': the level of a long bracket opening ([[ -> 0, [=[ -> 1) or -1."""
    j = i + 1
    while j < len(text) and text[j] == '=':
        j += 1
    if j < len(text) and text[j] == '[':
        return j - i - 1
    return -1


def lex(text):
    toks = []
    i, n, line = 0, len(text), 1
    line_start = 0
    first_on_line = True
    errors = []
    while i < n:
        c = text[i]
        if c == '\n':
            line += 1
            i += 1
            line_start = i
            first_on_line = True
            continue
        if c in ' \t\r\f\v':
            i += 1
            continue
        col = i - line_start
        bol = first_on_line
        first_on_line = False
        if c == '-' and text.startswith('--', i):
            j = i + 2
            if j < n and text[j] == '[':
                lvl = _long_bracket(text, j)
                if lvl >= 0:
                    close = ']' + '=' * lvl + ']'
                    k = text.find(close, j)
                    if k < 0:
                        k = n
                    line += text.count('\n', i, k)
                    i = k + len(close)
                    continue
            k = text.find('\n', i)
            i = n if k < 0 else k
            continue
        if c == '#' and bol:                      # an old style comment line
            k = text.find('\n', i)
            i = n if k < 0 else k
            continue
        if c in '\'"':
            q = c
            j = i + 1
            buf = []
            while j < n and text[j] != q:
                if text[j] == '\\' and j + 1 < n:
                    nxt = text[j + 1]
                    if nxt == 'n':
                        buf.append('\n')
                    elif nxt == '\n':
                        buf.append('\n')
                        line += 1
                    elif nxt in '0123456789':
                        k = j + 1
                        d = ''
                        while k < n and k < j + 4 and text[k].isdigit():
                            d += text[k]
                            k += 1
                        buf.append(chr(min(int(d), 255)))
                        j = k
                        continue
                    else:
                        buf.append({'t': '\t', 'r': '\r'}.get(nxt, nxt))
                    j += 2
                    continue
                if text[j] == '\n':
                    errors.append((line, 'unfinished string'))
                    break
                buf.append(text[j])
                j += 1
            toks.append(Tok('str', ''.join(buf), line, col, bol))
            i = j + 1
            continue
        if c == '[':
            lvl = _long_bracket(text, i)
            if lvl >= 0:
                close = ']' + '=' * lvl + ']'
                k = text.find(close, i)
                if k < 0:
                    k = n
                body = text[i + lvl + 2:k]
                toks.append(Tok('str', body, line, col, bol))
                line += text.count('\n', i, k)
                i = k + len(close)
                continue
        if c.isalpha() or c == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            w = text[i:j]
            toks.append(Tok('kw' if w in KEYWORDS else 'name', w, line, col, bol))
            i = j
            continue
        if c.isdigit() or (c == '.' and i + 1 < n and text[i + 1].isdigit()):
            m = re.compile(r'0[xX][0-9a-fA-F]+|\d*\.?\d*(?:[eE][+-]?\d+)?').match(text, i)
            j = m.end() if m and m.end() > i else i + 1
            toks.append(Tok('num', text[i:j], line, col, bol))
            i = j
            continue
        for op in ('...', '..', '==', '~=', '<=', '>=', '!=', '::'):
            if text.startswith(op, i):
                toks.append(Tok('op', op, line, col, bol))
                i += len(op)
                break
        else:
            toks.append(Tok('op', c, line, col, bol))
            i += 1
    return toks, errors


# ---- the rules -----------------------------------------------------------------------------------------------------------------------------------------

BAD_DOTTED = {('string', 'match'), ('string', 'gmatch'), ('table', 'unpack'), ('table', 'pack')}
BAD_METHOD = {'match', 'gmatch'}


def api_hits(toks):
    """Identifier rules (also applied to templates). -> list of (line, rule, detail)"""
    out = []
    for i, t in enumerate(toks):
        if t.kind == 'kw' or t.kind == 'name':
            if t.val == 'goto' and t.kind == 'name':
                nxt = toks[i + 1] if i + 1 < len(toks) else None
                if nxt and nxt.kind == 'name':
                    out.append((t.line, 'api', 'goto'))
            if t.val == 'select' and i + 1 < len(toks) and toks[i + 1].val == '(' and not (i > 0 and toks[i - 1].val in ('.', ':')):
                out.append((t.line, 'api', 'select()'))
            if i + 2 < len(toks) and toks[i + 1].val == '.' and (t.val, toks[i + 2].val) in BAD_DOTTED:
                out.append((t.line, 'api', '%s.%s' % (t.val, toks[i + 2].val)))
            if i > 0 and toks[i - 1].val == ':' and toks[i - 1].kind == 'op' and t.val in BAD_METHOD and i + 1 < len(toks) and toks[i + 1].val in ('(',):
                out.append((t.line, 'api', ':%s(' % t.val))
        if t.kind == 'op' and t.val == '::':
            out.append((t.line, 'api', '::label::'))
    return out


def operator_hits(toks):
    out = []
    in_params = 0                 # inside the parameter list of a `function`
    depth_paren = 0
    pending_function = False
    for i, t in enumerate(toks):
        if t.kind == 'kw' and t.val == 'function':
            pending_function = True
        elif t.kind == 'op' and t.val == '(':
            if pending_function:
                in_params = 1
                pending_function = False
            elif in_params:
                in_params += 1
        elif t.kind == 'op' and t.val == ')':
            if in_params:
                in_params -= 1
        elif t.kind == 'kw' or (t.kind == 'op' and t.val in ('{', '=')):
            pending_function = False
        if t.kind != 'op':
            continue
        if t.val == '^':
            out.append((t.line, 'caret', ''))
        elif t.val == '%':
            out.append((t.line, 'percent', ''))
        elif t.val == '#':
            out.append((t.line, 'hash', ''))
        elif t.val == '...' and not in_params:
            out.append((t.line, 'vararg', ''))
    return out


OPEN = {'function', 'if', 'for', 'while', 'repeat'}


def balance_and_toplevel(toks, is_hook):
    """Block structure: -> (balance problems, hook top level problems). Depth 0 is the file's top level."""
    problems, top = [], []
    stack = []                # ('function'|'if'|'for'|'while'|'do'|'repeat', line)
    pending_do = []           # `for` / `while` headers waiting for their `do`
    for i, t in enumerate(toks):
        if t.kind != 'kw':
            if not stack and is_hook and not (t.kind == 'op' and t.val == ';'):
                top.append((t.line, 'hook-toplevel', 'code outside a do ... end block'))
            continue
        v = t.val
        if not stack and is_hook and v != 'do':
            top.append((t.line, 'hook-toplevel', 'code outside a do ... end block (`%s`)' % v))
        if v in ('for', 'while'):
            stack.append((v, t.line))
            pending_do.append(len(stack))
        elif v == 'do':
            if pending_do and pending_do[-1] == len(stack):
                pending_do.pop()                      # the do of a for / while header
            else:
                stack.append(('do', t.line))
        elif v in ('function', 'if'):
            stack.append((v, t.line))
        elif v == 'repeat':
            stack.append((v, t.line))
        elif v == 'end':
            if not stack or stack[-1][0] == 'repeat':
                problems.append((t.line, 'balance', 'unmatched `end`'))
            else:
                stack.pop()
        elif v == 'until':
            if stack and stack[-1][0] == 'repeat':
                stack.pop()
            else:
                problems.append((t.line, 'balance', 'unmatched `until`'))
    for kind, line in stack:
        problems.append((line, 'balance', '`%s` is never closed' % kind))
    return problems, top


def module_nil(toks):
    """`Name = nil` at the file's top level (depth 0)."""
    out = []
    depth_stack = 0
    pending_do = []
    for i, t in enumerate(toks):
        if t.kind == 'kw':
            v = t.val
            if v in ('for', 'while'):
                depth_stack += 1
                pending_do.append(depth_stack)
            elif v == 'do':
                if pending_do and pending_do[-1] == depth_stack:
                    pending_do.pop()
                else:
                    depth_stack += 1
            elif v in ('function', 'if', 'repeat'):
                depth_stack += 1
            elif v in ('end', 'until'):
                depth_stack -= 1
        if depth_stack == 0 and t.kind == 'name' and t.bol and i + 2 < len(toks) and toks[i + 1].val == '=' and toks[i + 2].val == 'nil':
            nxt = toks[i + 3] if i + 3 < len(toks) else None
            if nxt is None or nxt.bol:
                out.append((t.line, 'modulenil', t.val))
    return out


def block_ends(toks):
    """opener token index -> index of its closing `end` / `until` (for / while: the index of the `for` / `while` token; the header's `do` is skipped)."""
    ends, stack, pending = {}, [], []
    for i, t in enumerate(toks):
        if t.kind != 'kw':
            continue
        v = t.val
        if v in ('for', 'while'):
            stack.append(i)
            pending.append(len(stack))
        elif v == 'do':
            if pending and pending[-1] == len(stack):
                pending.pop()
            else:
                stack.append(i)
        elif v in ('function', 'if', 'repeat'):
            stack.append(i)
        elif v in ('end', 'until'):
            if stack:
                ends[stack.pop()] = i
    return ends


SYNC_CALLS = {'pcall', 'sort', 'foreach', 'gsub', 'Try', 'Call', 'Wrap', 'xpcall'}


def loop_closures(toks):
    """(warning) a `function` made inside a `for` body that reads the loop variable (a closure keeps the variable, not its value; copy it to a local first)."""
    out = []
    ends = block_ends(toks)
    n = len(toks)
    for i, t in enumerate(toks):
        if not (t.kind == 'kw' and t.val == 'for' and i in ends):
            continue
        names = []
        j = i + 1
        while j < n and not (toks[j].val in ('in', '=') and toks[j].kind in ('kw', 'op')):
            if toks[j].kind == 'name' and toks[j].val != '_':
                names.append(toks[j].val)
            j += 1
        while j < n and not (toks[j].kind == 'kw' and toks[j].val == 'do'):
            j += 1
        body = range(j + 1, ends[i])
        copies = set()
        for k in body:
            tk = toks[k]
            if tk.kind == 'kw' and tk.val == 'local' and k + 3 < n and toks[k + 1].kind == 'name' and toks[k + 2].val == '=' and toks[k + 3].val == toks[k + 1].val:
                copies.add(toks[k + 1].val)
            if tk.kind == 'kw' and tk.val == 'function' and k in ends:
                if k >= 2 and toks[k - 1].val == '(' and toks[k - 2].val in SYNC_CALLS:
                    continue                                  # run at once: the variable still has its value
                params = set()
                m = k + 1
                while m < n and toks[m].val != ')':
                    if toks[m].kind == 'name':
                        params.add(toks[m].val)
                    m += 1
                for m in range(k + 1, ends[k]):
                    tm = toks[m]
                    if tm.kind == 'name' and tm.val in names and tm.val not in copies and tm.val not in params and toks[m - 1].val not in ('.', ':'):
                        if not (m + 1 < n and toks[m + 1].val == '=' ):
                            out.append((tk.line, 'loopclosure', tm.val))
                            break
    seen, uniq = set(), []
    for o in out:
        if (o[0], o[2]) not in seen:
            seen.add((o[0], o[2]))
            uniq.append(o)
    return uniq


LUAISH = re.compile(r'\bfunction\b|\blocal\b|\bthen\b|\bend\b')


def template_hits(toks):
    """String literals that hold Lua source: the identifier rules and `#name` apply to them."""
    out = []
    for t in toks:
        if t.kind == 'str' and ('\n' in t.val) and LUAISH.search(t.val) and len(t.val) > 40:
            sub, _ = lex(t.val)
            for line, rule, detail in api_hits(sub):
                out.append((t.line, rule, 'in a text template: ' + detail))
            for k, s in enumerate(sub):
                if s.kind == 'op' and s.val == '#' and k + 1 < len(sub) and sub[k + 1].kind in ('name', 'op') and sub[k + 1].val not in ('', ' '):
                    if sub[k + 1].kind == 'name' or sub[k + 1].val == '(':
                        out.append((t.line, 'hash', 'in a text template'))
    return out


def hook_args(toks):
    """(warning) hooks: `local old = X` + `function X(a, b, c)` + a call `old(x, y)` with fewer arguments than the new function takes."""
    out = []
    olds = {}
    n = len(toks)
    for i, t in enumerate(toks):
        if t.kind == 'kw' and t.val == 'local' and i + 3 < n and toks[i + 1].kind == 'name' and toks[i + 2].val == '=' and toks[i + 3].kind == 'name' \
                and not (i + 4 < n and toks[i + 4].val in ('.', '(', ':')):
            olds[toks[i + 1].val] = toks[i + 3].val
    for i, t in enumerate(toks):
        if t.kind == 'kw' and t.val == 'function' and i + 3 < n and toks[i + 1].kind == 'name' and toks[i + 2].val == '(':
            name = toks[i + 1].val
            j = i + 3
            params = 0
            vararg = False
            while j < n and toks[j].val != ')':
                if toks[j].kind == 'name':
                    params += 1
                if toks[j].val == '...':
                    vararg = True
                j += 1
            if vararg:
                continue
            old = [k for k, v in olds.items() if v == name]
            # calls of the old function inside this function's body (up to the next top-level `function`): count the arguments
            for k in range(j, min(n, j + 400)):
                if toks[k].kind == 'kw' and toks[k].val == 'function' and k > j + 1 and toks[k - 1].val != '=':
                    pass
                if toks[k].kind == 'name' and toks[k].val in old and k + 1 < n and toks[k + 1].val == '(':
                    depth, args, m, any_tok = 1, 0, k + 2, False
                    while m < n and depth > 0:
                        if toks[m].val in ('(', '{') and toks[m].kind == 'op':
                            depth += 1
                        elif toks[m].val in (')', '}') and toks[m].kind == 'op':
                            depth -= 1
                        elif toks[m].val == ',' and depth == 1:
                            args += 1
                        if depth > 0:
                            any_tok = True
                        m += 1
                    count = (args + 1) if any_tok else 0
                    if count < params and not any(toks[q].val == 'unpack' for q in range(k, m)):
                        out.append((toks[k].line, 'hook-args', '%s takes %d, the call passes %d' % (name, params, count)))
    return out


# ---- the files -----------------------------------------------------------------------------------------------------------------------------------------

def check_file(rel, text, is_hook):
    toks, lex_errors = lex(text)
    hits = []
    for line, msg in lex_errors:
        hits.append((line, 'balance', msg))
    hits += operator_hits(toks)
    hits += api_hits(toks)
    hits += template_hits(toks)
    bal, top = balance_and_toplevel(toks, is_hook)
    hits += bal
    hits += top
    if not is_hook:
        hits += module_nil(toks)
    hits += loop_closures(toks)
    if is_hook:
        hits += hook_args(toks)
    out = []
    for line, rule, detail in hits:
        if (rel, rule, line) in ALLOW or (rel, rule, 0) in ALLOW:
            continue
        out.append((line, rule, detail))
    return sorted(set(out))


def hook_path_problem(rel_below_schook, exists):
    """The path below schook/ has to be a game file. `exists(vfs path)` -> True / False, or None when no game files are at hand (then only the structure is checked)."""
    first = rel_below_schook.split('/')[0].lower()
    if first not in ('lua', 'units', 'projectiles', 'effects', 'env', 'textures', 'meshes', 'loc', 'ui', 'props', 'modules', 'schook'):
        return 'the first folder `%s` is not a game folder (the path below schook/ is the VFS path of the file)' % first
    if exists is not None:
        found = exists(rel_below_schook)
        if found is False:
            return '%s is not a file of the installed game (the path below schook/ is the VFS path of the file it extends)' % rel_below_schook
    return None


def run(runtime_root, exists=None, verbose=False):
    """-> (errors, warnings, files) where errors / warnings are lists of 'path:line  rule  text'."""
    errors, warnings = [], []
    nfiles = 0
    for d, dirs, fs in os.walk(runtime_root):
        dirs[:] = [x for x in dirs if x not in ('data', 'override', 'branding', 'brushes', 'maps')]
        for f in sorted(fs):
            if not f.endswith('.lua'):
                continue
            path = os.path.join(d, f)
            rel = os.path.relpath(path, runtime_root).replace(os.sep, '/')
            try:
                text = open(path, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            nfiles += 1
            is_hook = rel.startswith('schook/') or '/hook/' in rel
            for line, rule, detail in check_file(rel, text, is_hook):
                msg = '%s:%d  %s  %s%s' % (rel, line, rule, RULE_TEXT.get(rule, ''), (' [' + detail + ']') if detail else '')
                (warnings if rule in WARNINGS else errors).append(msg)
            if rel.startswith('schook/'):
                why = hook_path_problem(rel[len('schook/'):], exists)
                if why:
                    errors.append('%s:1  hook-path  %s' % (rel, why))
    return errors, warnings, nfiles
