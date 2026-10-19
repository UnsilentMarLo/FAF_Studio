"""Helpers that post synthetic mouse and key messages to the running test engine (no real cursor movement)."""
import ctypes, ctypes.wintypes as wt, subprocess, sys, time
user32=ctypes.windll.user32
def pid():
    return int(subprocess.run(['powershell','-NoProfile','-Command',"(Get-Process main_x64*).Id"],capture_output=True,text=True).stdout.split()[0])
def windows(p):
    res=[]
    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def each(h,_):
        o=wt.DWORD(); user32.GetWindowThreadProcessId(h,ctypes.byref(o))
        if o.value==p and user32.IsWindowVisible(h):
            buf=ctypes.create_unicode_buffer(80); user32.GetWindowTextW(h,buf,80)
            r=wt.RECT(); user32.GetClientRect(h,ctypes.byref(r)); res.append((r.right*r.bottom,h,buf.value))
        return True
    user32.EnumWindows(each,0); return sorted(res,reverse=True)
def lp(x,y): return ((y&0xFFFF)<<16)|(x&0xFFFF)
def main_view():
    top=windows(pid())[0][1]
    kids=[]
    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def ec(h,_):
        kids.append(h); return True
    user32.EnumChildWindows(top,ec,0)
    return kids[0] if kids else top
def client_to_screen(h,x,y):
    pt=wt.POINT(x,y); user32.ClientToScreen(h,ctypes.byref(pt)); return pt.x,pt.y
def move(h,x,y): user32.PostMessageW(h,0x200,0,lp(x,y)); time.sleep(0.15)
def click(h,x,y):
    move(h,x,y); user32.PostMessageW(h,0x201,1,lp(x,y)); time.sleep(0.12); user32.PostMessageW(h,0x202,0,lp(x,y)); time.sleep(0.2)
def wheel(h,x,y,delta):
    sx,sy=client_to_screen(h,x,y); move(h,x,y)
    user32.PostMessageW(h,0x20A,((delta&0xFFFF)<<16),lp(sx,sy)); time.sleep(0.25)


def drag(h, x0, y0, x1, y1, steps=12):
    """Left-button drag with intermediate moves (the engine's Dragger follows the posted motion)."""
    move(h, x0, y0)
    user32.PostMessageW(h, 0x201, 1, lp(x0, y0)); time.sleep(0.15)
    for i in range(1, steps + 1):
        x = x0 + (x1 - x0) * i // steps
        y = y0 + (y1 - y0) * i // steps
        user32.PostMessageW(h, 0x200, 1, lp(x, y)); time.sleep(0.04)
    time.sleep(0.15)
    user32.PostMessageW(h, 0x202, 0, lp(x1, y1)); time.sleep(0.3)


def chars(h, text):
    for ch in text:
        user32.PostMessageW(h, 0x102, ord(ch), 1); time.sleep(0.12)


def key(h, vk):
    user32.PostMessageW(h, 0x100, vk, 1); time.sleep(0.05); user32.PostMessageW(h, 0x101, vk, 1); time.sleep(0.2)
