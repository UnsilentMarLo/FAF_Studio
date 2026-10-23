#!/usr/bin/env python3
"""Turns the GPU compute kernels (engine: src/sdk/moho/editor/gpu/*.hlsl) into the header the editor compiles in (EdGpuShaders.generated.h), and lints them.

    python scripts/gen_gpu_shaders.py            # write moho/editor/EdGpuShaders.generated.h
    python scripts/gen_gpu_shaders.py --check    # exit 1 if the header is stale or a kernel breaks the language rules (studio.py check runs this)
    python scripts/gen_gpu_shaders.py --lint     # only the language rules
    python scripts/gen_gpu_shaders.py --sdk DIR  # another engine src/sdk folder (default: studio_paths.SDK)

What it does (docs/projects/editor/GPU_COMPUTE.md):
  * every gpu/<name>.hlsl is a kernel: hlsl_prelude.hlsli (the HLSL side of the kernel macros) + the file with its `#include "x.hlsli"` lines inlined = the source D3DCompile gets;
  * the metadata the host needs is read from the macros (NUMTHREADS, CBUFFER, SRV_BUFFER, UAV_BUFFER, SRV_TEX, UAV_TEX, SAMPLER, GROUPSHARED) and written next to the source;
  * the lint keeps the kernels inside the subset that is valid HLSL and C++ at once (tests/EdGpuTest.cpp compiles every kernel as C++ through gpu/hlsl_cpp_shim.h): see FORBIDDEN.
The header has raw string literals, split in pieces below the 16380 byte limit of one MSVC string literal.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

PRELUDE = "hlsl_prelude.hlsli"
SHIM_ONLY = {"hlsl_cpp_shim.h"}
OUT_NAME = "EdGpuShaders.generated.h"
PIECE = 8000                       # bytes per raw string piece (MSVC: 16380 per literal, 65535 for the concatenation)
MAX_SOURCE = 60000

# (regex, why) applied to the source without comments; a match is an error.
FORBIDDEN = [
    (r"(?<=[\w\)\]])\.[xyzw]{2,4}\b", "multi-component swizzle: build the vector with float2(v.x, v.y)"),
    (r"(?<=[\w\)\]])\.[rgba]{1,4}\b", "r g b a components: use x y z w"),
    (r"\bround\s*\(", "round(): HLSL rounds half to even, C++ half away from zero; use floor(x + 0.5f)"),
    (r"\b(cbuffer|tbuffer|register|groupshared|numthreads)\b", "write the kernel with the macros (CBUFFER, GROUPSHARED, NUMTHREADS ...), not the raw HLSL keyword"),
    (r"\b(StructuredBuffer|RWStructuredBuffer|ByteAddressBuffer|RWByteAddressBuffer|RWBuffer|Texture2D|RWTexture2D|Texture3D|RWTexture3D|SamplerState|ConstantBuffer)\b", "use SRV_BUFFER / UAV_BUFFER / SRV_TEX / UAV_TEX / SAMPLER"),
    (r"\bBuffer\s*<", "typed buffers are not in the subset: use SRV_BUFFER"),
    (r"\bSV_\w+", "system value semantics are in KERNEL_IDS"),
    (r"\b(GroupMemoryBarrier\w*|DeviceMemoryBarrier\w*|AllMemoryBarrier\w*)\b", "use BARRIER() inside PHASES_BEGIN / PHASES_END"),
    (r"\[\s*(unroll|loop|branch|flatten|call|fastopt|allow_uav_condition)\b", "use UNROLL / LOOP (other attributes are not in the subset)"),
    (r"\b(out|inout)\b", "use OUT(T) / INOUT(T)"),
    (r"\b(double|half|min16\w+|min10float|bool[234]|float[234]x[234]|matrix|vector)\b", "type not in the subset (float, int, uint, float2-4, int2-4, uint2-4 only)"),
    (r"\bmul\s*\(", "matrices are not in the subset"),
    (r"#\s*pragma\b", "#pragma is not allowed"),
    (r"\b(goto|discard|clip|inline|typedef|using|template|namespace|class|new|delete|sizeof|printf|assert)\b", "construct not in the subset"),
    (r"\bstd\s*::", "std:: is C++ only"),
    (r"\.(Sample|SampleBias|SampleGrad|SampleCmp|Gather)\s*\(", "compute shaders have no derivatives: use SampleLevel"),
    (r"(?<![\w.])(?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?(?![\dfFeE.\w])", "float literal without f suffix (1.0 -> 1.0f); C++ would compute it in double"),
    (r"(?<![\w.])\d+[eE][+-]?\d+(?![\dfF\w])", "float literal without f suffix"),
    (r"\blocal\b|\bunsigned\b|\bsigned\b|\bchar\b|\bshort\b|\blong\b", "use int / uint / float"),
]
CB_TYPES = ("uint", "int", "float")


def sdk_dir(argv):
    if "--sdk" in argv:
        return os.path.abspath(argv[argv.index("--sdk") + 1])
    import studio_paths as P
    return P.SDK


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8").replace("\r\n", "\n")


class Gen:
    def __init__(self, sdk):
        self.dir = os.path.join(sdk, "moho", "editor", "gpu")
        self.out = os.path.join(sdk, "moho", "editor", OUT_NAME)
        self.errors = []

    def err(self, where, msg):
        self.errors.append("%s: %s" % (where, msg))

    def flatten(self, name, seen):
        """The file with its quoted #include lines replaced by the (flattened) included files; each file once per kernel."""
        path = os.path.join(self.dir, name)
        if not os.path.isfile(path):
            self.err(name, "file not found")
            return ""
        if name in seen:
            return ""
        seen.add(name)
        out = []
        for line in read(path).split("\n"):
            m = re.match(r'^\s*#\s*include\s+"([^"]+)"\s*$', line)
            if m:
                inc = m.group(1)
                if inc == PRELUDE or inc in SHIM_ONLY or "/" in inc or "\\" in inc:
                    self.err(name, "#include of %s: only plain file names of gpu/*.hlsli" % inc)
                    continue
                out.append("// ---- begin %s" % inc)
                out.append(self.flatten(inc, seen).rstrip("\n"))
                out.append("// ---- end %s" % inc)
            elif re.match(r"^\s*#\s*include\b", line):
                self.err(name, "only #include \"file.hlsli\" is allowed")
            else:
                out.append(line)
        return "\n".join(out) + "\n"

    def lint_text(self, name, text):
        code = strip_comments(text)
        for rx, why in FORBIDDEN:
            for m in re.finditer(rx, code):
                line = code.count("\n", 0, m.start()) + 1
                self.err("%s:%d" % (name, line), "'%s': %s" % (m.group(0).strip(), why))

    def lint_phases(self, name, code):
        uses = "PHASES_BEGIN" in code
        bars = len(re.findall(r"\bBARRIER\s*\(\s*\)", code))
        if bars and not uses:
            self.err(name, "BARRIER() without PHASES_BEGIN / PHASES_END")
        if uses:
            if not re.search(r"\bPHASES_END\b", code):
                self.err(name, "PHASES_BEGIN without PHASES_END")
            if re.search(r"\breturn\b", code):
                self.err(name, "a kernel with PHASES_BEGIN must not return early (every thread has to reach every BARRIER)")
            # BARRIER at the top level of the body: brace depth 1 inside CSMain
            m = re.search(r"void\s+CSMain\s*\([^)]*\)\s*\{", code)
            if m:
                depth = 1
                i = m.end()
                while i < len(code) and depth > 0:
                    c = code[i]
                    if c == "{":
                        depth += 1
                    elif c == "}":
                        depth -= 1
                    elif code.startswith("BARRIER", i) and depth != 1:
                        self.err(name, "BARRIER() inside a block or loop (line %d): it has to stand at the top level of CSMain" % (code.count("\n", 0, i) + 1))
                    i += 1

    def kernel(self, name):
        """-> dict(name, source, tx, ty, tz, srv, uav, samplers, cb) or None when the kernel is broken."""
        seen = set()
        body = self.flatten(name + ".hlsl", seen)
        code = strip_comments(body)
        self.lint_text(name + ".hlsl", read(os.path.join(self.dir, name + ".hlsl")))     # the file itself (line numbers); the .hlsli files are linted on their own
        self.lint_phases(name + ".hlsl", code)
        info = {"name": name}
        m = re.findall(r"NUMTHREADS\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)", code)
        if len(m) != 1:
            self.err(name, "exactly one NUMTHREADS(x, y, z) is needed")
            return None
        tx, ty, tz = (int(v) for v in m[0])
        if tx * ty * tz > 1024 or tz > 64 or min(tx, ty, tz) < 1:
            self.err(name, "thread group %dx%dx%d is outside what cs_5_0 allows (at most 1024 threads, z at most 64)" % (tx, ty, tz))
        info.update(tx=tx, ty=ty, tz=tz)
        if len(re.findall(r"void\s+CSMain\s*\(\s*KERNEL_IDS\s*\)", code)) != 1:
            self.err(name, "exactly one `void CSMain(KERNEL_IDS)` is needed")
        srv, uav, smp = {}, {}, {}
        for kind, table in (("SRV_BUFFER", srv), ("UAV_BUFFER", uav)):
            for t, n, s in re.findall(kind + r"\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\d+)\s*\)", code):
                table.setdefault(int(s), []).append(n)
        for kind, table in (("SRV_TEX", srv), ("UAV_TEX", uav), ("SAMPLER", smp)):
            for n, s in re.findall(kind + r"\s*\(\s*(\w+)\s*,\s*(\d+)\s*\)", code):
                table.setdefault(int(s), []).append(n)
        for label, table, limit in (("SRV", srv, 16), ("UAV", uav, 8), ("SAMPLER", smp, 2)):
            for s, names in table.items():
                if s >= limit:
                    self.err(name, "%s slot %d is out of range (0..%d)" % (label, s, limit - 1))
                if len(names) > 1:
                    self.err(name, "%s slot %d is used twice (%s); buffers and textures share the slot numbers" % (label, s, ", ".join(names)))
        info["srv"] = sum(1 << s for s in srv if s < 16)
        info["uav"] = sum(1 << s for s in uav if s < 8)
        info["srvtex"] = sum(1 << int(s) for _, s in re.findall(r"SRV_TEX\s*\(\s*(\w+)\s*,\s*(\d+)\s*\)", code) if int(s) < 16)
        info["uavtex"] = sum(1 << int(s) for _, s in re.findall(r"UAV_TEX\s*\(\s*(\w+)\s*,\s*(\d+)\s*\)", code) if int(s) < 8)
        info["smp"] = sum(1 << s for s in smp if s < 2)
        cbs = re.findall(r"CBUFFER\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\d+)\s*\)", code)
        if len(cbs) > 1 or any(int(c[2]) != 0 for c in cbs):
            self.err(name, "at most one CBUFFER, in slot 0")
        info["cb"] = 1 if cbs else 0
        if cbs:
            sm = re.search(r"struct\s+" + cbs[0][0] + r"\s*\{([^}]*)\}\s*;", code)
            if not sm:
                self.err(name, "struct %s of the CBUFFER is not defined in the kernel or its includes" % cbs[0][0])
            else:
                members = [x.strip() for x in sm.group(1).split(";") if x.strip()]
                for mem in members:
                    if not re.match(r"^(%s)\s+\w+$" % "|".join(CB_TYPES), mem):
                        self.err(name, "constant buffer struct %s: member '%s' (only uint / int / float scalars, so the C++ and HLSL layouts are the same)" % (cbs[0][0], mem))
                if len(members) % 4 != 0:
                    self.err(name, "constant buffer struct %s has %d members: pad it to a multiple of 4 (16 bytes)" % (cbs[0][0], len(members)))
        shared = 0
        for t, n, cnt in re.findall(r"GROUPSHARED\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*([^)]+)\)", code):
            try:
                shared += 4 * int(eval(cnt, {"__builtins__": {}}, {}))
            except Exception:
                self.err(name, "GROUPSHARED size '%s' is not a constant" % cnt)
        if shared > 32768:
            self.err(name, "group shared memory %d bytes (cs_5_0 allows 32768)" % shared)
        src = read(os.path.join(self.dir, PRELUDE)) + "\n" + body
        if len(src.encode("utf-8")) > MAX_SOURCE:
            self.err(name, "source is %d bytes (limit %d for one string literal)" % (len(src), MAX_SOURCE))
        if ')HLSL"' in src:
            self.err(name, "contains the raw string terminator")
        h = 1469598103934665603
        for b in src.encode("utf-8"):
            h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        info["hash"] = h
        info["source"] = src
        return info

    def kernels(self):
        if not os.path.isdir(self.dir):
            self.err(self.dir, "gpu folder not found")
            return []
        for f in sorted(os.listdir(self.dir)):
            if f.endswith(".hlsli") and f != PRELUDE:
                self.lint_text(f, read(os.path.join(self.dir, f)))
        out = []
        for f in sorted(os.listdir(self.dir)):
            if f.endswith(".hlsl"):
                k = self.kernel(f[:-5])
                if k:
                    out.append(k)
        return out

    def header(self, kernels):
        o = ["// GENERATED by scripts/gen_gpu_shaders.py from moho/editor/gpu/*.hlsl and hlsl_prelude.hlsli: do not edit (python scripts/gen_gpu_shaders.py rewrites it,",
             "// `python scripts/studio.py check` fails while it is stale).",
             "#pragma once",
             "",
             '#include "moho/editor/EdGpu.h"',
             "",
             "namespace moho::editor::gpu::shaders",
             "{"]
        for k in kernels:
            o.append("  // %s: %dx%dx%d threads" % (k["name"], k["tx"], k["ty"], k["tz"]))
            o.append("  inline constexpr char kSource_%s[] =" % k["name"])
            lines = k["source"].split("\n")
            pieces, cur, size = [], [], 0
            for ln in lines:
                if size + len(ln.encode("utf-8")) + 1 > PIECE and cur:
                    pieces.append("\n".join(cur) + "\n")
                    cur, size = [], 0
                cur.append(ln)
                size += len(ln.encode("utf-8")) + 1
            pieces.append("\n".join(cur))
            for i, p in enumerate(pieces):
                o.append('    R"HLSL(%s)HLSL"%s' % (p, ";" if i == len(pieces) - 1 else ""))
            o.append("")
        o.append("  inline const KernelInfo kKernels[] = {")
        for k in kernels:
            o.append('    {"%s", kSource_%s, "CSMain", %du, %du, %du, 0x%Xu, 0x%Xu, 0x%Xu, 0x%Xu, 0x%Xu, %du, 0x%016XULL},'
                     % (k["name"], k["name"], k["tx"], k["ty"], k["tz"], k["srv"], k["uav"], k["srvtex"], k["uavtex"], k["smp"], k["cb"], k["hash"]))
        o.append("  };")
        o.append("  inline constexpr int kKernelCount = %d;" % len(kernels))
        o.append("} // namespace moho::editor::gpu::shaders")
        o.append("")
        return "\n".join(o)


def main(argv):
    sdk = sdk_dir(argv)
    if not os.path.isdir(os.path.join(sdk, "moho", "editor")):
        print("skipped gen_gpu_shaders.py (no engine sources at %s: python scripts/studio.py engine setup)" % sdk)
        return 0
    g = Gen(sdk)
    kernels = g.kernels()
    if g.errors:
        print("gpu kernel lint: %d problem(s)" % len(g.errors))
        for e in g.errors:
            print("  " + e)
        return 1
    if "--lint" in argv:
        print("gpu kernels: %d kernel(s) ok" % len(kernels))
        return 0
    text = g.header(kernels)
    if "--check" in argv:
        current = read(g.out) if os.path.exists(g.out) else ""
        if current != text:
            print("stale: run python scripts/gen_gpu_shaders.py (%s)" % g.out)
            return 1
        print("gpu shaders up to date (%d kernels)" % len(kernels))
        return 0
    with open(g.out, "wb") as f:
        f.write(text.encode("utf-8"))
    print("wrote %s (%d kernels, %d bytes)" % (g.out, len(kernels), len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
