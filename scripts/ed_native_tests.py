#!/usr/bin/env python3
"""Builds and runs the engine-independent native editor tests (moho/editor/tests/*.cpp) with MSVC.

    python scripts/ed_native_tests.py
"""
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_paths as P  # noqa: E402
SDK = P.SDK
OUT = os.path.join(P.ENGINE_DIR, "native_tests")
VCVARS = r"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"

# test name -> engine sources it links (paths under src/sdk)
TESTS = {"MapDocumentTest": ["moho/editor/MapDocument.cpp"], "EdFieldTest": ["moho/editor/EdFieldCore.cpp"],
         "EdSymTest": ["moho/editor/EdFieldCore.cpp", "moho/editor/EdFieldSc.cpp"],
         "EdErosionTest": ["moho/editor/EdFieldCore.cpp", "moho/editor/EdErosion.cpp"],
         "EdLandTest": ["moho/editor/EdFieldCore.cpp", "moho/editor/EdFieldGen.cpp", "moho/editor/EdFieldLand.cpp"],
         "EdBrushTest": ["moho/editor/MapDocument.cpp"], "MeshLodDepthTest": [], "EdTerrainTypeTest": [], "EdOverlayGeomTest": [], "EdOverlaySlopeTest": [], "EdOverlayNodesTest": [], "EdOverlayDrapeTest": [], "EdOverlayLodTest": [], "EdOverlayFieldTest": [], "EdDdsDecodeTest": [], "EdTexConvTest": [], "EdDirtyRectTest": [], "EdPerfPolicyTest": [], "EdRenderOptTest": [],
         "EdNormalMapParTest": ["moho/editor/EdFieldCore.cpp", "moho/render/textures/DXTCodec.cpp"],
         # GPU compute foundation: the kernels run as C++ through gpu/hlsl_cpp_shim.h on a CPU emulator; on Windows the test also tries the real Direct3D 11 device (docs/projects/editor/GPU_COMPUTE.md)
         "EdGpuTest": ["moho/editor/EdFieldCore.cpp", "moho/editor/EdGpuOps.cpp", "moho/editor/EdGpu.cpp"],
         # GPU erosion ops (hydraulic, droplet) on the emulator: properties, not sample values (docs/projects/editor/GPU_COMPUTE.md, "Erosion kernels")
         "EdGpuErosionTest": ["moho/editor/EdFieldCore.cpp", "moho/editor/EdErosion.cpp", "moho/editor/EdGpuOps.cpp", "moho/editor/EdGpu.cpp", "moho/editor/EdGpuErosion.cpp"],
         # GPU generator and filter kernels (gpu/gen_*, gpu/filt_*) on the CPU emulator, against the CPU ops (docs/projects/editor/GPU_COMPUTE.md, "Generator and filter kernels")
         "EdGpuGenTest": ["moho/editor/EdFieldCore.cpp", "moho/editor/EdFieldLand.cpp", "moho/editor/EdFieldGen.cpp", "moho/editor/EdFieldFilt.cpp", "moho/editor/EdGpuOps.cpp", "moho/editor/EdGpu.cpp", "moho/editor/EdGpuGen.cpp", "moho/editor/EdGpuGenFilt.cpp"]}
# command line arguments per test (paths under the repository root, or under $ED_EDITOR_ROOT: the git worktree of a feature branch); extra arguments of this script are passed on to every test
ARGS = {"EdFieldTest": ["editor/runtime/lua/editor/selftest_fields_cases.lua"],
        "EdErosionTest": ["editor/runtime/lua/editor/selftest_erosion_cases.lua"]}


def main():
    os.makedirs(OUT, exist_ok=True)
    failed = 0
    for name, sources in TESTS.items():
        exe = os.path.join(OUT, name + ".exe")
        test_src = os.path.join(SDK, "moho", "editor", "tests", name + ".cpp")
        srcs = " ".join('"%s"' % os.path.join(SDK, s) for s in sources)
        cmd = ('call "%s" >nul 2>&1 && cl /nologo /std:c++20 /EHsc /O2 /W3 /I"%s" "%s" %s /Fe:"%s"'
               % (VCVARS, SDK, test_src, srcs, exe))
        r = subprocess.run(cmd, shell=True, cwd=OUT, capture_output=True, text=True, encoding="cp850", errors="replace")
        if r.returncode != 0:
            print(r.stdout[-3000:], r.stderr[-1000:])
            print("BUILD FAILED:", name)
            failed += 1
            continue
        r = subprocess.run([exe] + [os.path.join(os.environ.get("ED_EDITOR_ROOT", ROOT), a) for a in ARGS.get(name, [])] + sys.argv[1:], capture_output=True, text=True, encoding="cp850", errors="replace")
        print(r.stdout.strip())
        if r.returncode != 0:
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
