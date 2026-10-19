"""Walk the stack of a thread of a running process with dbghelp and the build's PDB.  usage: stackwalk.py <pid> [tid ...]"""
import ctypes, ctypes.wintypes as wt, sys, os

pid = int(sys.argv[1])
tids = [int(t) for t in sys.argv[2:]]
dbg = ctypes.WinDLL(r'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\dbghelp.dll')
k32 = ctypes.WinDLL('kernel32', use_last_error=True)

PROCESS_ALL = 0x1F0FFF
THREAD_ALL = 0x1F03FF
hp = k32.OpenProcess(PROCESS_ALL, False, pid)
k32.OpenThread.restype = wt.HANDLE

dbg.SymSetOptions(0x2 | 0x4 | 0x10000000 | 0x200)   # UNDNAME | DEFERRED_LOADS | ...
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))
import studio_paths as P
pdbdir = os.path.join(P.ENGINE_SRC, 'output', 'main', 'x64', 'Release')
dbg.SymInitialize(hp, pdbdir.encode(), True)

# image base of the exe
mods = (ctypes.c_void_p * 1024)()
need = wt.DWORD()
ctypes.WinDLL('psapi').EnumProcessModulesEx(hp, mods, ctypes.sizeof(mods), ctypes.byref(need), 3)
base = mods[0]
name = ctypes.create_unicode_buffer(260)
ctypes.WinDLL('psapi').GetModuleFileNameExW(hp, base, name, 260)
print('module', name.value, hex(base))
dbg.SymLoadModuleExW.restype = ctypes.c_uint64
# the pdb is named main_x64_la.pdb, the image main_x64_la_p2.exe: load explicitly with the pdb's base name
sz = os.path.getsize(name.value)
loaded = dbg.SymLoadModuleExW(hp, None, ctypes.c_wchar_p(name.value), ctypes.c_wchar_p('main_x64_la'), ctypes.c_uint64(base), sz, None, 0)
print('loaded', hex(loaded))


class CONTEXT(ctypes.Structure):
    _fields_ = [('P1Home', ctypes.c_uint64), ('P2Home', ctypes.c_uint64), ('P3Home', ctypes.c_uint64), ('P4Home', ctypes.c_uint64),
                ('P5Home', ctypes.c_uint64), ('P6Home', ctypes.c_uint64), ('ContextFlags', wt.DWORD), ('MxCsr', wt.DWORD),
                ('SegCs', wt.WORD), ('SegDs', wt.WORD), ('SegEs', wt.WORD), ('SegFs', wt.WORD), ('SegGs', wt.WORD), ('SegSs', wt.WORD),
                ('EFlags', wt.DWORD), ('Dr0', ctypes.c_uint64), ('Dr1', ctypes.c_uint64), ('Dr2', ctypes.c_uint64), ('Dr3', ctypes.c_uint64),
                ('Dr6', ctypes.c_uint64), ('Dr7', ctypes.c_uint64),
                ('Rax', ctypes.c_uint64), ('Rcx', ctypes.c_uint64), ('Rdx', ctypes.c_uint64), ('Rbx', ctypes.c_uint64),
                ('Rsp', ctypes.c_uint64), ('Rbp', ctypes.c_uint64), ('Rsi', ctypes.c_uint64), ('Rdi', ctypes.c_uint64),
                ('R8', ctypes.c_uint64), ('R9', ctypes.c_uint64), ('R10', ctypes.c_uint64), ('R11', ctypes.c_uint64),
                ('R12', ctypes.c_uint64), ('R13', ctypes.c_uint64), ('R14', ctypes.c_uint64), ('R15', ctypes.c_uint64),
                ('Rip', ctypes.c_uint64), ('Fp', ctypes.c_byte * 512), ('Vec', ctypes.c_byte * 416), ('VCtl', ctypes.c_uint64 * 5)]


class ADDR(ctypes.Structure):
    _fields_ = [('Offset', ctypes.c_uint64), ('Segment', wt.WORD), ('Mode', wt.DWORD)]


class STACKFRAME(ctypes.Structure):
    _fields_ = [('AddrPC', ADDR), ('AddrReturn', ADDR), ('AddrFrame', ADDR), ('AddrStack', ADDR), ('AddrBStore', ADDR),
                ('FuncTableEntry', ctypes.c_void_p), ('Params', ctypes.c_uint64 * 4), ('Far', wt.BOOL), ('Virtual', wt.BOOL),
                ('Reserved', ctypes.c_uint64 * 3), ('KdHelp', ctypes.c_byte * 264)]


class SYMBOL(ctypes.Structure):
    _fields_ = [('SizeOfStruct', wt.ULONG), ('TypeIndex', wt.ULONG), ('Reserved', ctypes.c_uint64 * 2), ('Index', wt.ULONG), ('Size', wt.ULONG),
                ('ModBase', ctypes.c_uint64), ('Flags', wt.ULONG), ('Value', ctypes.c_uint64), ('Address', ctypes.c_uint64),
                ('Register', wt.ULONG), ('Scope', wt.ULONG), ('Tag', wt.ULONG), ('NameLen', wt.ULONG), ('MaxNameLen', wt.ULONG),
                ('Name', ctypes.c_char * 400)]


def sym(addr):
    s = SYMBOL()
    s.SizeOfStruct = 88
    s.MaxNameLen = 400
    disp = ctypes.c_uint64()
    if dbg.SymFromAddr(hp, ctypes.c_uint64(addr), ctypes.byref(disp), ctypes.byref(s)):
        return '%s+0x%x' % (s.Name.decode(errors='replace'), disp.value)
    return '?'


dbg.SymFunctionTableAccess64.restype = ctypes.c_void_p
dbg.SymGetModuleBase64.restype = ctypes.c_uint64
for tid in tids:
    ht = k32.OpenThread(THREAD_ALL, False, tid)
    k32.SuspendThread(ht)
    ctx = CONTEXT()
    ctx.ContextFlags = 0x10000F
    ok = k32.GetThreadContext(ht, ctypes.byref(ctx))
    print('--- thread', tid, 'ctx', ok)
    f = STACKFRAME()
    f.AddrPC.Offset, f.AddrPC.Mode = ctx.Rip, 3
    f.AddrFrame.Offset, f.AddrFrame.Mode = ctx.Rbp, 3
    f.AddrStack.Offset, f.AddrStack.Mode = ctx.Rsp, 3
    for i in range(40):
        if not dbg.StackWalk64(0x8664, hp, ht, ctypes.byref(f), ctypes.byref(ctx), None, dbg.SymFunctionTableAccess64, dbg.SymGetModuleBase64, None):
            break
        if f.AddrPC.Offset == 0:
            break
        print('  %2d %016x %s' % (i, f.AddrPC.Offset, sym(f.AddrPC.Offset)))
    k32.ResumeThread(ht)
