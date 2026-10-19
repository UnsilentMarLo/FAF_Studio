#!/usr/bin/env python
"""Gives the editor build its own identity: copies run_x64/bin/main_x64_la_p2.exe to FAFStudio.exe (the process name in Task Manager / tasklist) and replaces, in that copy only,
the icon (editor/runtime/branding/fafstudio.ico) and the version information (FileDescription / ProductName "FAF Studio", which is what Task Manager and the taskbar group show).
The original exe is never touched. Run after every engine build (C:/tmp/build_deploy.ps1 does):

    python scripts/brand_exe.py [--src NAME] [--dst NAME] [--version 0.1.0.0]

If FAFStudio.exe is running (locked) the copy is skipped with a message: running instances keep their build until restarted (scripts/editor_inst.py start).
"""
import argparse
import ctypes
import os
import shutil
import struct
import subprocess
import sys
from ctypes import wintypes

HERE = os.path.dirname(os.path.abspath(__file__))


def main_checkout():
    out = subprocess.run(['git', '-C', os.path.dirname(HERE), 'worktree', 'list', '--porcelain'], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith('worktree '):
            return os.path.normpath(line[len('worktree '):].strip())
    return os.path.dirname(HERE)


RT_ICON, RT_GROUP_ICON, RT_VERSION = 3, 14, 16
k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.LoadLibraryExW.restype = wintypes.HMODULE
k32.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD]
k32.BeginUpdateResourceW.restype = wintypes.HANDLE
k32.BeginUpdateResourceW.argtypes = [wintypes.LPCWSTR, wintypes.BOOL]
k32.UpdateResourceW.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, wintypes.WORD, ctypes.c_void_p, wintypes.DWORD]
k32.EndUpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.BOOL]
k32.FreeLibrary.argtypes = [wintypes.HMODULE]
EnumNameProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
EnumLangProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p, wintypes.WORD, ctypes.c_void_p)
k32.EnumResourceNamesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, EnumNameProc, ctypes.c_void_p]
k32.EnumResourceLanguagesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p, EnumLangProc, ctypes.c_void_p]


_keep = []


def res_name(name):
    """A resource name for UpdateResource: an integer id or a wide string (kept alive)."""
    if isinstance(name, int):
        return ctypes.c_void_p(name)
    buf = ctypes.create_unicode_buffer(name)
    _keep.append(buf)
    return ctypes.cast(buf, ctypes.c_void_p)


def enum_resources(path, rtype):
    """-> list of (name pointer value, language) of one resource type (names that are strings are kept as pointers that die with the library: only integer ids are used)."""
    h = k32.LoadLibraryExW(path, None, 0x2)      # LOAD_LIBRARY_AS_DATAFILE
    if not h:
        raise SystemExit('cannot load ' + path)
    found = []

    def on_name(_h, _t, name, _p):
        n = name if name is not None else 0
        ident = n if n < 65536 else ctypes.wstring_at(n)       # an integer id, or the resource's string name (the FA icon is a named one)
        langs = []

        def on_lang(_h2, _t2, _n2, lang, _p2):
            langs.append(lang)
            return True
        k32.EnumResourceLanguagesW(h, ctypes.c_void_p(rtype), ctypes.c_void_p(n), EnumLangProc(on_lang), None)
        for lang in langs or [1033]:
            found.append((ident, lang))
        return True
    k32.EnumResourceNamesW(h, ctypes.c_void_p(rtype), EnumNameProc(on_name), None)
    k32.FreeLibrary(h)
    return found


def read_ico(path):
    d = open(path, 'rb').read()
    _, kind, count = struct.unpack_from('<HHH', d, 0)
    images = []
    for i in range(count):
        w, h, colors, _res, planes, bits, size, offset = struct.unpack_from('<BBBBHHII', d, 6 + 16 * i)
        images.append((w, h, colors, planes, bits, d[offset:offset + size]))
    return images


def group_icon(images, first_id):
    data = struct.pack('<HHH', 0, 1, len(images))
    for i, (w, h, colors, planes, bits, blob) in enumerate(images):
        data += struct.pack('<BBBBHHIH', w, h, colors, 0, planes, bits, len(blob), first_id + i)
    return data


def pad4(b):
    return b + b'\0' * ((4 - len(b) % 4) % 4)


def ver_block(key, value=b'', wtype=1, children=b'', vlen=0):
    """One VS_VERSIONINFO node: wLength, wValueLength (characters for text, bytes for binary), wType, key, padding, value, padding, children."""
    key_b = (key + '\0').encode('utf-16le')
    body = struct.pack('<HH', vlen, wtype) + key_b
    body += b'\0' * ((-(2 + len(body))) % 4) + value
    if children:
        body += b'\0' * ((-(2 + len(body))) % 4) + children
    return struct.pack('<H', 2 + len(body)) + body


def version_blob(version, strings):
    parts = [int(x) for x in version.split('.')] + [0, 0, 0, 0]
    ms, ls = (parts[0] << 16) | parts[1], (parts[2] << 16) | parts[3]
    fixed = struct.pack('<IIIIIIIIIIIII', 0xFEEF04BD, 0x00010000, ms, ls, ms, ls, 0x3F, 0, 0x00040004, 1, 0, 0, 0)
    entries = b''
    for k, v in strings.items():
        value = (v + '\0').encode('utf-16le')
        entries += pad4(ver_block(k, value, 1, b'', len(value) // 2))
    table = ver_block('040904B0', b'', 1, entries, 0)
    sfi = ver_block('StringFileInfo', b'', 1, table, 0)
    var = ver_block('Translation', struct.pack('<HH', 0x0409, 0x04B0), 0, b'', 4)
    vfi = ver_block('VarFileInfo', b'', 1, var, 0)
    return ver_block('VS_VERSION_INFO', fixed, 0, pad4(sfi) + vfi, len(fixed))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--src', default='main_x64_la_p2.exe')
    ap.add_argument('--dst', default='FAFStudio.exe')
    ap.add_argument('--version', default='0.1.0.0')
    a = ap.parse_args()
    root = main_checkout()
    sys.path.insert(0, HERE)
    import studio_paths as P
    bindir = P.ENGINE_BIN
    src, dst = os.path.join(bindir, a.src), os.path.join(bindir, a.dst)
    ico = os.path.join(HERE, '..', 'editor', 'runtime', 'branding', 'fafstudio.ico')
    if not os.path.exists(ico):
        ico = os.path.join(root, 'editor', 'runtime', 'branding', 'fafstudio.ico')
    if not os.path.exists(src):
        raise SystemExit('no ' + src)
    tmp = dst + '.new'
    shutil.copy2(src, tmp)
    groups = enum_resources(tmp, RT_GROUP_ICON)
    versions = enum_resources(tmp, RT_VERSION)
    images = read_ico(ico)
    lang = groups[0][1] if groups else 1033
    h = k32.BeginUpdateResourceW(tmp, False)
    if not h:
        raise SystemExit('BeginUpdateResource failed (%d)' % ctypes.get_last_error())
    ok = True
    first_id = 3000
    for i, im in enumerate(images):
        blob = im[5]
        ok &= bool(k32.UpdateResourceW(h, ctypes.c_void_p(RT_ICON), ctypes.c_void_p(first_id + i), lang, blob, len(blob)))
    gdata = group_icon(images, first_id)
    for name, glang in (groups or [(1, lang)]):
        ok &= bool(k32.UpdateResourceW(h, ctypes.c_void_p(RT_GROUP_ICON), res_name(name), glang, gdata, len(gdata)))
    strings = {
        'CompanyName': 'FAF Studio', 'FileDescription': 'FAF Studio', 'FileVersion': a.version, 'InternalName': 'FAFStudio',
        'LegalCopyright': '', 'OriginalFilename': a.dst, 'ProductName': 'FAF Studio', 'ProductVersion': a.version,
    }
    vdata = version_blob(a.version, strings)
    for name, vlang in (versions or [(1, 1033)]):
        ok &= bool(k32.UpdateResourceW(h, ctypes.c_void_p(RT_VERSION), res_name(name), vlang, vdata, len(vdata)))
    if not k32.EndUpdateResourceW(h, not ok):
        raise SystemExit('EndUpdateResource failed (%d)' % ctypes.get_last_error())
    if not ok:
        os.remove(tmp)
        raise SystemExit('updating the resources failed')
    try:
        if os.path.exists(dst):
            os.remove(dst)
        os.replace(tmp, dst)
    except PermissionError:
        print('%s is running or locked: left as it is (the new build is at %s)' % (dst, tmp))
        return
    print('wrote', dst, '(%d icon sizes, version %s)' % (len(images), a.version))


if __name__ == '__main__':
    main()
