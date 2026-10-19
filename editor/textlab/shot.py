"""Capture the client area of a running engine window (PrintWindow, PW_RENDERFULLCONTENT) to a PNG.

    python editor/textlab/shot.py <out.png> --pid N [--crop x0,y0,x1,y1] [--zoom K] [--nth 2]

Own copy of the capture used by scripts/meshmaps/screenshot.py (which matches ForgedAlliance.exe by name only).
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import struct
import sys
import zlib

user32, gdi32 = ctypes.windll.user32, ctypes.windll.gdi32


def windows_of(pid):
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def each(hwnd, _):
        owner = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            r = wt.RECT()
            user32.GetClientRect(hwnd, ctypes.byref(r))
            found.append((r.right * r.bottom, hwnd, r.right, r.bottom))
        return True
    user32.EnumWindows(each, 0)
    return sorted(found, reverse=True)


def capture(hwnd, w, h):
    wdc = user32.GetDC(hwnd)
    mdc = gdi32.CreateCompatibleDC(wdc)
    bmp = gdi32.CreateCompatibleBitmap(wdc, w, h)
    gdi32.SelectObject(mdc, bmp)
    ok = user32.PrintWindow(hwnd, mdc, 1 | 2)
    header = struct.pack("<IiiHHIIiiII", 40, w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(w * h * 4)
    got = gdi32.GetDIBits(mdc, bmp, 0, h, buf, header, 0)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(hwnd, wdc)
    return buf.raw if ok and got else None


def write_png(path, w, h, bgra, crop=None, zoom=1):
    x0, y0, x1, y1 = crop if crop else (0, 0, w, h)
    rows = bytearray()
    for y in range(y0, y1):
        row = bgra[(y * w + x0) * 4:(y * w + x1) * 4]
        rgb = bytearray((x1 - x0) * 3)
        rgb[0::3], rgb[1::3], rgb[2::3] = row[2::4], row[1::4], row[0::4]
        if zoom > 1:
            wide = bytearray()
            for i in range(x1 - x0):
                wide += bytes(rgb[i * 3:i * 3 + 3]) * zoom
            rgb = wide
        for _ in range(zoom):
            rows.append(0)
            rows += rgb
    ow, oh = (x1 - x0) * zoom, (y1 - y0) * zoom

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ow, oh, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--crop")
    ap.add_argument("--zoom", type=int, default=1)
    ap.add_argument("--nth", type=int, default=1, help="1 = the biggest window of the process (the editor), 2 = the next one (a pop-out window) ...")
    a = ap.parse_args()
    wins = windows_of(a.pid)
    if not wins:
        print("no window")
        return 1
    if a.nth > len(wins):
        print("no window number", a.nth)
        return 1
    _, hwnd, w, h = wins[a.nth - 1]
    data = capture(hwnd, w, h)
    if data is None:
        print("capture failed")
        return 2
    crop = tuple(int(v) for v in a.crop.split(",")) if a.crop else None
    write_png(a.out, w, h, data, crop, a.zoom)
    print("wrote", a.out, w, h)
    return 0


if __name__ == "__main__":
    sys.exit(main())
