#!/usr/bin/env python3
"""Posts real mouse and keyboard messages to the window of a test editor instance (scripts/editor_inst.py tags), so a feature can be driven the way a user does (no cursor movement, no focus needed).

    python scripts/ed_input.py <tag> click X Y [--right]       X, Y are pixels of the editor window (the coordinates of `editor_inst.py shot`)
    python scripts/ed_input.py <tag> move X Y                   hover only (the pointer moves, no button)
    python scripts/ed_input.py <tag> drag X0 Y0 X1 Y1
    python scripts/ed_input.py <tag> wheel X Y DELTA            DELTA +120 up / -120 down
    python scripts/ed_input.py <tag> type "text"                characters to the focused field
    python scripts/ed_input.py <tag> key ENTER|ESC|TAB|DELETE|BACK|CTRL+Z|CTRL+Y|F5 ...

A click is a mouse move, a button press and a release (the hover state of the widgets follows the move). Several actions can be chained with `then`:
    python scripts/ed_input.py env click 100 50 then wait 0.5 then click 200 80
"""
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import editor_inst  # noqa: E402

user32 = ctypes.windll.user32
VK = {"ENTER": 0x0D, "ESC": 0x1B, "TAB": 0x09, "DELETE": 0x2E, "BACK": 0x08, "F5": 0x74, "Z": 0x5A, "Y": 0x59, "C": 0x43, "V": 0x56, "A": 0x41, "S": 0x53}


def lp(x, y):
    return ((y & 0xFFFF) << 16) | (x & 0xFFFF)


def target(tag):
    pid = editor_inst.read_pid(tag)
    if not editor_inst.alive(pid):
        raise SystemExit("instance %s is not running" % tag)
    top = editor_inst.window_of(pid)
    kids = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def each(h, _):
        kids.append(h)
        return True

    user32.EnumChildWindows(top, each, 0)
    return kids[0] if kids else top


def move(h, x, y):
    user32.PostMessageW(h, 0x200, 0, lp(x, y))
    time.sleep(0.15)


def click(h, x, y, right=False):
    move(h, x, y)
    down, up, flag = (0x204, 0x205, 2) if right else (0x201, 0x202, 1)
    user32.PostMessageW(h, down, flag, lp(x, y))
    time.sleep(0.12)
    user32.PostMessageW(h, up, 0, lp(x, y))
    time.sleep(0.25)


def drag(h, x0, y0, x1, y1, steps=12):
    move(h, x0, y0)
    user32.PostMessageW(h, 0x201, 1, lp(x0, y0))
    time.sleep(0.15)
    for i in range(1, steps + 1):
        user32.PostMessageW(h, 0x200, 1, lp(x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps))
        time.sleep(0.04)
    time.sleep(0.15)
    user32.PostMessageW(h, 0x202, 0, lp(x1, y1))
    time.sleep(0.3)


def wheel(h, x, y, delta):
    pt = wt.POINT(x, y)
    user32.ClientToScreen(h, ctypes.byref(pt))
    move(h, x, y)
    user32.PostMessageW(h, 0x20A, (delta & 0xFFFF) << 16, lp(pt.x, pt.y))
    time.sleep(0.3)


def chars(h, text):
    for ch in text:
        user32.PostMessageW(h, 0x102, ord(ch), 1)
        time.sleep(0.1)


def key(h, name):
    parts = name.upper().split("+")
    ctrl = "CTRL" in parts[:-1]
    vk = VK.get(parts[-1]) or ord(parts[-1][0])
    if ctrl:
        user32.PostMessageW(h, 0x100, 0x11, 1)
    user32.PostMessageW(h, 0x100, vk, 1)
    time.sleep(0.05)
    user32.PostMessageW(h, 0x101, vk, 1)
    if ctrl:
        user32.PostMessageW(h, 0x101, 0x11, 1)
    time.sleep(0.25)


def dpi_scale(h):
    """The editor reads mouse messages in logical pixels: on a display scaled to 125 % a message at X lands on X * 1.25 of the screenshot. ED_INPUT_SCALE overrides (1 = raw)."""
    env = os.environ.get("ED_INPUT_SCALE")
    if env:
        return float(env)
    try:
        return user32.GetDpiForWindow(user32.GetAncestor(h, 2)) / 96.0
    except Exception:
        return 1.0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    h = target(argv[0])
    k = dpi_scale(h)

    def sc(v):
        return int(round(int(v) / k))
    rest = argv[1:]
    actions, cur = [], []
    for token in rest:
        if token == "then":
            actions.append(cur)
            cur = []
        else:
            cur.append(token)
    actions.append(cur)
    for act in actions:
        verb = act[0]
        if verb == "click":
            click(h, sc(act[1]), sc(act[2]), "--right" in act)
        elif verb == "move":
            move(h, sc(act[1]), sc(act[2]))
        elif verb == "drag":
            drag(h, sc(act[1]), sc(act[2]), sc(act[3]), sc(act[4]))
        elif verb == "wheel":
            wheel(h, sc(act[1]), sc(act[2]), int(act[3]))
        elif verb == "type":
            chars(h, act[1])
        elif verb == "key":
            key(h, act[1])
        elif verb == "wait":
            time.sleep(float(act[1]))
        else:
            raise SystemExit("unknown action " + verb)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
