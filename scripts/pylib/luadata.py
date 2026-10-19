"""Reader and writer for the Lua *data* files of a map (`_scenario.lua`, `_save.lua`) and blueprints (`.bp`).

These files are Lua chunks made of assignments and table constructors, with wrapper calls such as `VECTOR3(1, 2, 3)`,
`STRING('x')`, `GROUP { ... }`. This is a small parser for exactly that subset (no functions, no control flow). Values:

    nil / True / False / int / float / str  -> Python None / bool / int / float / str
    table constructor                       -> LuaTable (ordered `items`: list of [key, value], key None = positional)
    NAME(args) / NAME{...} / NAME'str'      -> LuaCall(name, args, style)
    bare identifier                         -> LuaName(name)

Numbers keep their float/int type (`4` vs `4.0`). `dumps` writes back in the layout of the original map editor.
`to_py` / `from_py` convert to plain dict/list for JSON and back.
"""
import re

__all__ = ["LuaTable", "LuaCall", "LuaName", "LuaError", "parse", "parse_chunk", "dumps", "dump_chunk", "to_py"]


class LuaError(ValueError):
    pass


class LuaName:
    __slots__ = ("name",)

    def __init__(self, name):
        self.name = name

    def __repr__(self):
        return f"LuaName({self.name})"

    def __eq__(self, o):
        return isinstance(o, LuaName) and o.name == self.name


class LuaCall:
    """Function call used as a value. style: '(' for NAME(...), '{' for NAME{...}, "'" for NAME'string'."""
    __slots__ = ("name", "args", "style")

    def __init__(self, name, args, style="("):
        self.name, self.args, self.style = name, args, style

    def __repr__(self):
        return f"LuaCall({self.name}, {self.args!r})"


class LuaTable:
    """Ordered table. items: list of [key, value]; key is None for positional entries."""
    __slots__ = ("items",)

    def __init__(self, items=None):
        self.items = items if items is not None else []

    def __repr__(self):
        return f"LuaTable({self.items!r})"

    # lookup / mutation by key (string or number); positional entries are not addressed by key
    def get(self, key, default=None):
        for k, v in self.items:
            if k is not None and k == key:
                return v
        return default

    def set(self, key, value):
        for it in self.items:
            if it[0] is not None and it[0] == key:
                it[1] = value
                return
        self.items.append([key, value])

    def delete(self, key):
        self.items = [it for it in self.items if not (it[0] is not None and it[0] == key)]

    def keys(self):
        return [k for k, _ in self.items if k is not None]

    def array(self):
        return [v for k, v in self.items if k is None]

    def __contains__(self, key):
        return any(k is not None and k == key for k, _ in self.items)

    def __iter__(self):
        return iter(self.items)

    def __len__(self):
        return len(self.items)


_TOKEN = re.compile(r"""
    (?P<ws>[ \t\r\n]+)
  | (?P<bcomment>--\[(?P<beq>=*)\[)
  | (?P<comment>--[^\n]*)
  | (?P<bstring>\[(?P<seq>=*)\[)
  | (?P<number>0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z_0-9]*)
  | (?P<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')
  | (?P<op>\.\.\.|\.\.|==|~=|!=|<=|>=|[{}()\[\];,=.+\-*/%^#<>:])
""", re.X)

_ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}


def _unescape(s):
    if "\\" not in s:
        return s
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\" or i + 1 >= len(s):
            out.append(c)
            i += 1
            continue
        n = s[i + 1]
        if n in _ESC:
            out.append(_ESC[n])
            i += 2
        elif n.isdigit():
            j = i + 1
            while j < len(s) and j < i + 4 and s[j].isdigit():
                j += 1
            out.append(chr(int(s[i + 1:j])))
            i = j
        elif n == "\n":
            out.append("\n")
            i += 2
        else:
            out.append(n)
            i += 2
    return "".join(out)


def _tokens(text):
    pos, n = 0, len(text)
    toks = []
    while pos < n:
        m = _TOKEN.match(text, pos)
        if not m:
            raise LuaError(f"unexpected character {text[pos]!r} at {_line(text, pos)}")
        kind = m.lastgroup
        if kind in ("beq",):
            kind = "bcomment"
        if m.group("ws"):
            pos = m.end()
            continue
        if m.group("bcomment") is not None:
            close = "]" + m.group("beq") + "]"
            end = text.find(close, m.end())
            if end < 0:
                raise LuaError("unterminated block comment")
            pos = end + len(close)
            continue
        if m.group("comment") is not None:
            pos = m.end()
            continue
        if m.group("bstring") is not None:
            close = "]" + m.group("seq") + "]"
            end = text.find(close, m.end())
            if end < 0:
                raise LuaError("unterminated long string")
            body = text[m.end():end]
            if body.startswith("\n"):
                body = body[1:]
            toks.append(("string", body, pos))
            pos = end + len(close)
            continue
        if m.group("number") is not None:
            s = m.group("number")
            if s[:2].lower() == "0x":
                v = int(s, 16)
            elif re.fullmatch(r"\d+", s):
                v = int(s)
            else:
                v = float(s)
            toks.append(("number", v, pos))
        elif m.group("name") is not None:
            toks.append(("name", m.group("name"), pos))
        elif m.group("string") is not None:
            toks.append(("string", _unescape(m.group("string")[1:-1]), pos))
        else:
            toks.append(("op", m.group("op"), pos))
        pos = m.end()
    toks.append(("eof", None, n))
    return toks


def _line(text, pos):
    return f"line {text.count(chr(10), 0, pos) + 1}"


class _Parser:
    def __init__(self, text):
        self.text = text
        self.t = _tokens(text)
        self.i = 0

    def peek(self):
        return self.t[self.i]

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def error(self, msg):
        tok = self.peek()
        raise LuaError(f"{msg} at {_line(self.text, tok[2])} (near {tok[1]!r})")

    def accept(self, op):
        k, v, _ = self.peek()
        if k == "op" and v == op:
            self.i += 1
            return True
        return False

    def expect(self, op):
        if not self.accept(op):
            self.error(f"expected {op!r}")

    # chunk: list of (target, value) with target a list of keys ("a", "b") for a.b = v; `local` is ignored
    def chunk(self):
        out = []
        while self.peek()[0] != "eof":
            k, v, _ = self.peek()
            if k == "name" and v == "local":
                self.i += 1
                continue
            if k == "name" and v == "return":
                self.i += 1
                out.append((["return"], self.expr()))
                self.accept(";")
                continue
            if k == "name":
                target = [self.next()[1]]
                while self.accept("."):
                    target.append(self.next()[1])
                if self.accept("="):
                    out.append((target, self.expr()))
                else:
                    # a bare call statement such as `UnitBlueprint { ... }` or `version(3)`: keep it as a call value
                    self.i -= 2 * (len(target) - 1) + 1
                    out.append((["__call__"], self.expr()))
                self.accept(";")
                continue
            self.error("unexpected token")
        return out

    def expr(self):
        left = self.unary()
        while True:
            k, v, _ = self.peek()
            if k == "op" and v in ("+", "-", "*", "/", "..", "%"):
                self.i += 1
                right = self.unary()
                if v == "..":
                    if isinstance(left, str) and isinstance(right, (str, int, float)):
                        left = left + (right if isinstance(right, str) else _num(right))
                        continue
                    self.error("cannot fold concatenation")
                if isinstance(left, (int, float)) and isinstance(right, (int, float)):
                    left = {"+": left + right, "-": left - right, "*": left * right,
                            "/": (left / right if right else 0), "%": (left % right if right else 0)}[v]
                    continue
                self.error("cannot fold arithmetic")
            return left

    def unary(self):
        if self.accept("-"):
            v = self.unary()
            if isinstance(v, (int, float)):
                return -v
            self.error("cannot negate")
        k, v, _ = self.peek()
        if k == "number":
            self.i += 1
            return v
        if k == "string":
            self.i += 1
            return v
        if k == "op" and v == "{":
            return self.table()
        if k == "op" and v == "(":
            self.i += 1
            e = self.expr()
            self.expect(")")
            return e
        if k == "name":
            self.i += 1
            if v == "nil":
                return None
            if v == "true":
                return True
            if v == "false":
                return False
            name = v
            while self.accept("."):          # dotted references like math.pi
                name += "." + self.next()[1]
            k2, v2, _ = self.peek()
            if k2 == "op" and v2 == "(":
                self.i += 1
                args = []
                if not self.accept(")"):
                    while True:
                        args.append(self.expr())
                        if self.accept(")"):
                            break
                        self.expect(",")
                return LuaCall(name, args, "(")
            if k2 == "op" and v2 == "{":
                return LuaCall(name, [self.table()], "{")
            if k2 == "string":
                self.i += 1
                return LuaCall(name, [v2], "'")
            return LuaName(name)
        self.error("expected a value")

    def table(self):
        self.expect("{")
        t = LuaTable()
        while not self.accept("}"):
            k, v, _ = self.peek()
            if k == "op" and v == "[":
                self.i += 1
                key = self.expr()
                self.expect("]")
                self.expect("=")
                t.items.append([key, self.expr()])
            elif k == "name" and self.t[self.i + 1][0] == "op" and self.t[self.i + 1][1] == "=":
                self.i += 2
                t.items.append([v, self.expr()])
            else:
                t.items.append([None, self.expr()])
            if not (self.accept(",") or self.accept(";")):
                self.expect("}")
                break
        return t


def _num(v):
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            return "0"
        if v == int(v) and abs(v) < 1e15:
            return str(int(v))
        return repr(v)
    return str(v)


def parse_chunk(text):
    """Parse a data file into [(target_path_list, value), ...] in file order."""
    if text.startswith("\ufeff"):
        text = text[1:]
    return _Parser(text).chunk()


def parse(text):
    """Parse a data file into a dict of top-level assignments: {'Scenario': LuaTable, ...} (dotted targets joined by '.').
    Bare calls (UnitBlueprint { ... }) are stored under '__call__' as a list."""
    out = {}
    for target, value in parse_chunk(text):
        if target == ["__call__"]:
            out.setdefault("__call__", []).append(value)
        else:
            out[".".join(target)] = value
    return out


# ---------------------------------------------------------------------------------------------------------------------
_IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*$")
_RESERVED = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil",
             "not", "or", "repeat", "return", "then", "true", "until", "while"}


def _str(s):
    esc = s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return "'" + esc + "'"


def _key(k):
    if isinstance(k, str):
        if _IDENT.match(k) and k not in _RESERVED:
            return k
        return f"[{_str(k)}]"
    return f"[{_value_inline(k)}]"


def _value_inline(v):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, str):
        return _str(v)
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return _num(v)
    if isinstance(v, LuaName):
        return v.name
    raise LuaError(f"cannot write {v!r} inline")


def _fmt_float(v):
    return _num(v)


def dumps(value, indent=0, style="faf", key_style=None):
    """Serialise one value. style 'faf': keys as ['name'] (the map editor's layout), 'plain': bare identifiers."""
    pad = "    " * indent
    if isinstance(value, LuaTable):
        if not value.items:
            return "{}" if style == "plain" else "{\n" + pad + "}"
        inner = []
        for k, v in value.items:
            sv = dumps(v, indent + 1, style)
            if k is None:
                inner.append(f"{pad}    {sv},")
            elif style == "faf" and isinstance(k, str):
                inner.append(f"{pad}    [{_str(k)}] = {sv},")
            else:
                inner.append(f"{pad}    {_key(k)} = {sv},")
        return "{\n" + "\n".join(inner) + "\n" + pad + "}"
    if isinstance(value, LuaCall):
        if value.style == "{" and value.args and isinstance(value.args[0], LuaTable):
            return value.name + " " + dumps(value.args[0], indent, style)
        if value.style == "'" and value.args and isinstance(value.args[0], str):
            return value.name + _str(value.args[0])
        args = ", ".join(dumps(a, indent, style) if isinstance(a, (LuaTable, LuaCall)) else
                         (_fmt_float(a) if isinstance(a, float) else _value_inline(a)) for a in value.args)
        return f"{value.name}( {args} )" if style == "faf" else f"{value.name}({args})"
    if isinstance(value, float):
        return _fmt_float(value)
    return _value_inline(value)


def dump_chunk(assignments, style="faf"):
    """assignments: list of (name, value) -> text."""
    return "".join(f"{name} = {dumps(v, 0, style)}\n" for name, v in assignments)


def to_py(v):
    """LuaTable -> dict when all keys are named, list when all positional, else {'$array': [...], '$hash': {...}}.
    LuaCall -> {'$call': name, 'args': [...]}."""
    if isinstance(v, LuaTable):
        if all(k is not None for k, _ in v.items):
            return {k: to_py(x) for k, x in v.items}
        if all(k is None for k, _ in v.items):
            return [to_py(x) for _, x in v.items]
        return {"$array": [to_py(x) for k, x in v.items if k is None],
                "$hash": {k: to_py(x) for k, x in v.items if k is not None}}
    if isinstance(v, LuaCall):
        return {"$call": v.name, "args": [to_py(a) for a in v.args]}
    if isinstance(v, LuaName):
        return {"$name": v.name}
    return v


def from_py(v):
    """Inverse of to_py: dict / list / scalars from JSON -> LuaTable / LuaCall / LuaName."""
    if isinstance(v, dict):
        if "$call" in v:
            name = v["$call"]
            args = [from_py(a) for a in v.get("args", [])]
            style = "{" if name in ("GROUP", "Group") and len(args) == 1 and isinstance(args[0], LuaTable) else "("
            return LuaCall(name, args, style)
        if "$name" in v:
            return LuaName(v["$name"])
        if "$array" in v or "$hash" in v:
            t = LuaTable([[None, from_py(x)] for x in v.get("$array", [])])
            for k, x in v.get("$hash", {}).items():
                t.items.append([k, from_py(x)])
            return t
        return LuaTable([[k, from_py(x)] for k, x in v.items()])
    if isinstance(v, list):
        return LuaTable([[None, from_py(x)] for x in v])
    return v
