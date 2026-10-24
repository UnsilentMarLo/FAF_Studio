# GPU compute for the field engine

Foundation (agent GP1, 2026-10): a Direct3D 11 compute backend next to the game's Direct3D 9 renderer, so the field engine's heavy ops (erosion, generators, filters) can run on the graphics card. Later work (GP2: erosion kernels, GP3: generator kernels) adds kernels on top of this foundation and should be able to work from this document without reading the backend code.

> **Nothing here has been run on a GPU.** The author had Linux and g++ only (the same holds for GP2, GP3 and GP4: every later section says what the CPU emulator tests cover and what nobody could verify). What was checked: the kernels compile as C++ and match the CPU ops in a test (CPU emulator, 213 checks in the foundation test; the op tests of GP2 to GP4 have thousands more); the Direct3D 11 code passes `g++ -fsyntax-only` against hand written stub headers (copied from memory, so a typo in a real signature is possible: the first MSVC build is the real compile check); the HLSL text has never been given to the shader compiler. The sections "Verify on your machine" and "Known risks" say what to do first.

## What it is

```
 Lua                    ed_field_op("blur", ...)          ed_gpu_info / ed_gpu_enable / ed_gpu_selftest / ed_gpu_stats
  |                              |
 EdField.cpp  cfunc_Op  ->  field::RunOp  (EdFieldCore.cpp)
                                 |   interceptor (one function pointer)
                                 v
                 gpu::TryRun  (EdGpuOps.cpp)  --- false: the CPU op runs, as before
                                 |   policy: ed_gpu_compute, size >= ed_gpu_min_cells, op registered, GPU free, self test passed
                                 v
                 GpuOpFn  (EdGpuOps.cpp: OpBlurGpu)        parameters -> uploads -> dispatches -> download
                                 |
                 gpu::Executor  (EdGpu.h)  ---- D3D11Executor (EdGpu.cpp, Windows)   or   EmuExecutor (tests/EdGpuEmu.h, CPU)
                                 |
                 gpu/*.hlsl  kernels  ---- EdGpuShaders.generated.h (raw string literals, made by scripts/gen_gpu_shaders.py)
                                      ---- hlsl_cpp_shim.h (the same text compiled as C++ by the tests)
```

Files (engine, `src/sdk/moho/editor`):

| File | Role |
|---|---|
| `EdGpu.h` | The whole device side API, plain C++ (no Direct3D, no Windows): `KernelInfo`, `Resource`, `Executor`, `Backend`, `Lease`, `Field`, `PingPong`, `DispatchGrid`, `RunIterations`. |
| `EdGpu.cpp` | Device independent helpers + the Direct3D 11 implementation (`#if defined(_WIN32)`; elsewhere a backend that is never available, so the tests link on Linux). |
| `EdGpuOps.h/.cpp` | The op registry (`RegisterGpuOp`), policy, `TryRun` (the interceptor), statistics hooks, the self test, and the template op `OpBlurGpu` (ops `blur` and `box`). |
| `EdGpuLua.cpp` | Console variables and the Lua natives. Installs the interceptor at start-up. Finds the adapter of the D3D9 device (main thread only). |
| `EdGpuFieldCommon.h`, `EdGpuFieldIter.cpp`, `EdGpuFieldFilt.cpp`, `EdGpuFieldFlow.cpp` | GP4: GPU versions of 17 more field ops (iterated slides, windows, scans, flow accumulation), see "More field ops (GP4)". Kernels `gpu/field_*.hlsl`, test `tests/EdGpuFieldTest.cpp`. |
| `EdGpuShaders.generated.h` | GENERATED, checked in. Kernel sources + metadata. `python scripts/gen_gpu_shaders.py` rewrites it; `python scripts/studio.py check` fails while it is stale. |
| `gpu/*.hlsl`, `gpu/*.hlsli` | The kernels and their constant buffer structs. `hlsl_prelude.hlsli` (HLSL macros, put in front of every kernel) and `common.hlsli` (helpers). |
| `gpu/hlsl_cpp_shim.h` | TEST ONLY: the C++ twin of the prelude, vector types, HLSL intrinsics, atomics, buffers, textures, the emulator driver. |
| `tests/EdGpuEmu.h`, `tests/EdGpuTest.cpp` | CPU `Executor`/`Backend` and the test (`scripts/ed_native_tests.py`: `EdGpuTest`). |
| `EdFieldCore.h/.cpp` | `SetOpInterceptor`, `RunOpCpu` (no interceptor, no statistics), per-op statistics `OpStats`. Still engine independent. |

Direct3D 11 is loaded at run time (`LoadLibrary("d3d11.dll")`, `dxgi.dll`, `d3dcompiler_47.dll`, else `d3dcompiler_43.dll`), so a machine without them starts the editor and simply has no GPU backend. `d3d11.lib` is also in `AdditionalDependencies` of `main_ed.vcxproj` but nothing references it.

## Behaviour in one page

* **Default**: `ed_gpu_compute 1`, `ed_gpu_min_cells 65536` (256 x 256), `ed_gpu_selftest_first 1`. Ops with a GPU version (`ed_gpu_info().ops` lists them: the foundation's `blur` and `box`, the generators and filters of GP3, the erosion solvers of GP2, the ops of GP4) on fields of at least 65536 samples (an op's own, lower minimum if it has one; GP4 adds a work gate, see below) run on the GPU when a feature level 11_0 hardware adapter exists, else on the CPU, exactly as before.
* **Device**: created lazily on the first use, on the calling thread, on a hardware adapter (never WARP). The adapter the game's D3D9 device runs on is preferred (vendor + device id, looked up on the main thread); otherwise the one with the most dedicated video memory.
* **Self test first**: before the first real op of a session, `RunSelfTest` runs once (four parts using five small kernels, compared with the CPU). A device that fails it is switched off for the session and the op gets its CPU result. `ed_gpu_selftest_first 0` skips it.
* **Any failure falls back to the CPU**: a refused parameter (`Unsupported`), a failed call (`Failed`, counted, reason kept in `ed_gpu_info().lastOpError`), a busy GPU (another thread holds it: the op does not wait), a lost device. The CPU op runs and the caller never sees the difference. A lost device, a timeout or a failed self test switches the backend off for the session (`ed_gpu_enable(true, true)` forgets the failure and creates a new device).
* **Results**: not bit identical to the CPU (the GPU may fuse multiply and add; hardware texture filtering has 8 bit weights). The editor has no replay or multiplayer, so this is fine; the tests accept 1e-5 for the blur.
* **Statistics**: `RunOp` counts CPU runs, the interceptor counts GPU runs and fall-backs per op. The perf report (`/perf`, command `dev.perf`) prints `field ops: gpu: N ops, X ms; cpu: M ops, Y ms; K fell back to the cpu` plus the five largest ops, as the difference since the last report.

## Lua and console surface

| Name | What |
|---|---|
| `ed_gpu_compute` (console variable) | 1/0: the same switch as `ed_gpu_enable`. |
| `ed_gpu_min_cells` | Smaller fields stay on the CPU. |
| `ed_gpu_selftest_first` | 1 = self test before the first GPU op of a session. |
| `ed_gpu_info([probe])` | `{ compiledIn, tried, available, enabled, active, failed, selfTestPassed, adapter, vramMB, maxMB, featureLevel, compiler, textures, lastError, lastOpError, minCells, ops = {...} }`. `probe` (default true) creates the device if that was not tried; the Settings panel and the perf report pass false. |
| `ed_gpu_enable(on[, reset])` | Switch; `reset = true` forgets a failure and the self test result. |
| `ed_gpu_selftest()` | `{ ok, texturesOk, ms, error, parts = { { name, ok, detail, ms } } }`. |
| `ed_gpu_stats([reset])` | `{ enabled, ops = { name = { cpu, cpuMs, gpu, gpuMs, fallbacks } }, cpu, cpuMs, gpu, gpuMs, fallbacks }`. |
| command `dev.gpu` | Command palette (Ctrl+Shift+P): "GPU compute: show the adapter and run the self test". Prints adapter, state, GPU ops and the test parts into the Console panel and the log. |
| Settings panel | A "GPU compute" Off/On row (user setting `gfx_gpu_compute`, default On, applied at start-up by `graphics.lua` `Apply`), two status lines (adapter; state) and a "Test GPU compute" button. |

Lua side: `graphics.lua` (`GpuStatus`, `GpuTest`, `GpuReport`), `gui/panels_settings.lua`, `gui/feature_settings.lua` (`dev.gpu`), `perf.lua`.

## The kernel language

A kernel is `gpu/<name>.hlsl`. It is HLSL, written in a small subset that is also valid C++ once `hlsl_cpp_shim.h` is included, so the test compiles THE SAME FILE with g++/MSVC and runs it for every thread on the CPU. Resources and the entry point are declared with macros; `hlsl_prelude.hlsli` expands them to HLSL (generator), the shim expands them to C++ (tests).

```hlsl
#include "blur_params.hlsli"            // the constant buffer struct (shared with the host, see below)

CBUFFER(BlurParams, P, 0)               // constant buffer b0: one per kernel, a struct instance named P
SRV_BUFFER(float, src, 0)               // StructuredBuffer<float>   t0   (read)
SRV_BUFFER(float, weights, 1)           //                           t1
UAV_BUFFER(float, dst, 0)               // RWStructuredBuffer<float> u0   (write)
// SRV_TEX(tex, 0)  UAV_TEX(img, 0)     // Texture2D<float> / RWTexture2D<float> (R32_FLOAT); SRV slot numbers are shared with buffers
// SAMPLER(linearClamp, 0)              // s0 = linear + clamp, s1 = point + clamp (the host binds these two)
// GROUPSHARED(float, sh, 128)          // groupshared float sh[128]

NUMTHREADS(16, 16, 1)
void CSMain(KERNEL_IDS)                 // dtid = SV_DispatchThreadID, gtid = SV_GroupThreadID, gid = SV_GroupID, gidx = SV_GroupIndex (uint3, uint3, uint3, uint)
{
    if (dtid.x >= P.w || dtid.y >= P.h) return;
    ...
}
```

**Rules** (the generator lints the ones that can be seen in the text: `python scripts/gen_gpu_shaders.py --lint`; the C++ compile catches the rest):

* Types: `float int uint float2 float3 float4 int2.. uint2..`. No `double half bool2 matrix`.
* Float literals end in `f` (`0.5f`). `min/max/clamp` need the same type on both sides (`max(x, 0u)`, not `max(x, 0)` for a uint): mixed types compile in HLSL (silent promotion) and not in C++.
* Vector components `.x .y .z .w` only. No swizzles (`v.xy`): write `float2(v.x, v.y)`. No `.r .g .b .a`: (this also forbids a struct member called `r`).
* No `round()` (HLSL rounds half to even): use `floor(x + 0.5f)`. No `#pragma`, `goto`, `discard`, `sizeof`, `std::`, templates, `[attributes]` other than via `UNROLL` / `LOOP`. `out` / `inout` parameters: `OUT(float) a`, `INOUT(float) b`. Helper functions that live in a `.hlsli` start with `FN` (`FN uint Hash32(uint x)`): `inline` in C++, nothing in HLSL.
* Intrinsics available in both: `saturate lerp frac floor ceil trunc clamp min max abs sqrt rsqrt sin cos tan asin acos atan atan2 exp exp2 log log2 pow fmod sign step smoothstep mad dot length distance normalize cross sincos asuint asint asfloat countbits isnan isinf`, `InterlockedAdd/Min/Max/Or/And/Xor/Exchange/CompareExchange/CompareStore` on `uint`/`int` buffer elements. Float atomics do not exist in cs_5_0 (use `asuint` and `InterlockedCompareExchange`). Add a missing intrinsic to the shim when you need it (a one-line template or macro) and keep the HLSL meaning.
* Texture sampling: `tex.SampleLevel(sampler, float2 uv, 0.0f)`, `tex.Load(int3(x, y, 0))`, `tex[uint2(x, y)]`, `GetDimensions(w, h)`. No `.Sample` (no derivatives in compute).
* Out of range buffer access is silently ignored on a GPU; the emulator counts it (`emu::gOob`) and the test asserts zero. Keep the guard `if (dtid.x >= P.w || dtid.y >= P.h) return;` at the top of every kernel (the dispatch is rounded up to whole thread groups).
* `groupshared` and barriers only with the phase macros: write the body as `PHASES_BEGIN` code `BARRIER(0);` code (the argument is a dummy: HLSL's preprocessor rejects an empty macro parameter list) code ... `PHASES_END`, at the top level of `CSMain` (never inside a loop or an `if`, no `return` anywhere in such a kernel). Every phase is its own scope: a local does NOT live across a `BARRIER()` (compile error in the C++ build, so the rule cannot be broken unnoticed). Unroll tree reductions by hand (`reduce_sum.hlsl`). Prefer kernels without group shared memory: global-memory stencils with ping-pong buffers need no barriers and make the emulator a plain loop. Group shared memory is limited to 32 KB, a group to 1024 threads.
* The emulator starts group shared memory as NaN and unwritten buffers as NaN (`0xFF` bytes): a read of data nobody wrote shows up.

**Constant buffers**: the struct lives in `gpu/<name>_params.hlsli` (or a shared one) with include guards, contains ONLY `uint`, `int`, `float` members, and its member count is a multiple of 4 (pad with `pad0..`): then the HLSL cbuffer and the C++ struct have the same bytes and `sizeof` is a multiple of 16 (the generator checks it; `DispatchGrid` static_asserts it). The host includes the very same file (see the host op below), and the emulator refuses a constant buffer whose size differs from the kernel's struct.

**Slots**: constant buffer b0 only; SRV t0..t15, UAV u0..u7, samplers s0..s1. The generator reads the macros and writes `srvMask / uavMask / srvTexMask / uavTexMask / samplerMask / hasCb` and the thread group size into the generated table; `Executor::Dispatch` (both executors) checks the bindings against them (every used slot bound with the right kind, no resource as SRV and UAV of one dispatch).

## Add a kernel and a GPU op, step by step

Example: a point filter `smoothstep` (CPU op exists in `EdFieldCore.cpp`).

1. **Kernel**: `gpu/smoothstep.hlsl` + `gpu/smoothstep_params.hlsli` (copy `scale_offset.hlsl` / `scale_params.hlsli`). Keep the CPU op's arithmetic order so results match to float tolerance.
2. **Generate**: `python scripts/gen_gpu_shaders.py` (lint + `EdGpuShaders.generated.h`). Fix lint messages. Commit the generated header with the kernel. (`python scripts/studio.py generate` runs it too; `check` fails if it is stale.)
3. **Emulation in the test** (`tests/EdGpuTest.cpp`): add the params header to the list of `.hlsli` included at global scope, and
   ```cpp
   EMU_KERNEL_BEGIN(k_smoothstep)
   #include "moho/editor/gpu/smoothstep.hlsl"
   EMU_KERNEL_END(smoothstep)
   ```
   `TestKernelTable` fails until every generated kernel has such a block (kernels another test binary owns are skipped there: by name prefix `gen_` / `filt_` = EdGpuGenTest, `erosion_` = the erosion tests, `field_` = EdGpuFieldTest; a new family of kernels needs its own prefix in `OwnedByAnotherTest` and a test that emulates it) (and checks that the thread group and slot masks of the HLSL text equal the generated table).
4. **Host op**: a function `OpResult Fn(Executor& ex, const OpArgs& a, Grid& out, std::string& err)` and a registration. Copy `OpBlurGpu` (EdGpuOps.cpp) or put the op in your own file `EdGpuOpsErosion.cpp` (then add it to `main_ed.vcxproj` `ClCompile` and to `EdGpuTest` in `scripts/ed_native_tests.py`). The shape of an op:
   ```cpp
   namespace moho::editor::gpu::hk { using uint = std::uint32_t;
   #include "moho/editor/gpu/smoothstep_params.hlsli" }          // the kernel's constant buffer struct, same file

   OpResult OpSmoothstepGpu(Executor& ex, const OpArgs& a, Grid& out, std::string& err)
   {
     const Grid* src = /* a.in "a" */; if (!src) return OpResult::Unsupported;      // refuse what you do not handle: the CPU op reports bad input itself
     /* more checks: mask inputs, 'like' of another size, parameter ranges -> Unsupported */
     const KernelInfo* k = FindKernel("smoothstep"); if (!k) { err = "kernel missing"; return OpResult::Failed; }
     Field in, res;                                                                  // w*h floats on the device
     if (!UploadGrid(ex, *src, in, err) || !MakeField(ex, src->w, src->h, res, err)) return OpResult::Failed;
     hk::SmoothstepParams p{}; p.w = ...;
     Bindings b; b.Srv(0, in.R()).Uav(0, res.R());
     if (!DispatchGrid(ex, *k, p.w, p.h, p, b, err)) return OpResult::Failed;
     Grid result(src->w, src->h, src->cell, src->ox, src->oz);                      // a LOCAL grid: `out` is only written on success
     if (!DownloadGrid(ex, res, result, err)) return OpResult::Failed;
     out = std::move(result);
     return OpResult::Done;
   }
   struct Registrar { Registrar() { RegisterGpuOp("smoothstep", &OpSmoothstepGpu); } };  const Registrar gRegistrar;   // static initialiser
   ```
   Only register an op that is worth it: upload + download of a 4096 x 4096 field is ~128 MB over the bus (tens of ms), so a point filter is slower on the GPU than on the CPU. Good candidates: iterated ops (erosion, thermal), large stencils (blur), noise with many octaves.
5. **Test the op against the CPU op** (copy `TestBlurKernelsDirect`): set `SetBackendForTest(&emuBackend)`, `Install()`, `GetPolicy().minCells = 0`, `selfTestFirst = false`, run `field::RunOp` and `field::RunOpCpu` with the same `OpArgs`, compare with a tolerance, check `OpStats` shows a GPU call. Add a case for every `Unsupported` branch and for non multiple of 16 sizes and 1 x N / N x 1 fields.
6. **Optional**: add a part to `RunSelfTest` (EdGpuOps.cpp) when the kernel uses a feature the existing parts do not exercise (a new intrinsic, atomics, a texture format).
7. **Run**: `g++ -std=c++20 -O2 -ffp-contract=off -I src/sdk src/sdk/moho/editor/tests/EdGpuTest.cpp src/sdk/moho/editor/EdFieldCore.cpp src/sdk/moho/editor/EdGpuOps.cpp src/sdk/moho/editor/EdGpu.cpp -pthread -o EdGpuTest && ./EdGpuTest` (Linux), or `python scripts/ed_native_tests.py` (MSVC; also tries the real device). `-ffp-contract=off` matters: a fused multiply-add breaks bit equality with the CPU.

### Iterated kernels (erosion): `RunIterations`

Keep the fields on the device for the whole run, ping-pong between two, download once:

```cpp
PingPong h; h.Make(ex, w, h, err); UploadField(ex, h.Src(), grid.v.data(), err);
IterStats st;
bool ok = RunIterations(ex, iterations, /*targetMs*/ 60.0, [&](u32 i, std::string& e) {
    Bindings b; b.Srv(0, h.Src().R()).Uav(0, h.Dst().R());
    if (!DispatchGrid(ex, *kernel, w, h, params, b, e)) return false;   // vary `params` per iteration if needed (it is copied at dispatch time)
    h.Flip();
    return true;
}, err, &st);
```

`RunIterations` runs the first batch as one iteration, waits for it (`Executor::Sync`: flush + event/timestamp query with a time limit), then sizes the next batch so one submission takes about `targetMs` (grows at most 4x per step, never more than the iterations left). One submission far below 2 s keeps Windows from resetting the driver (TDR). A single iteration longer than the target runs as it is (`IterStats::maxSubmitMs` shows it): split such a kernel into row bands with an offset in the constant buffer instead. Droplet style erosion (random walks, atomics on a height field) is non deterministic on a GPU; the editor does not need determinism.

Other helpers: `FillBuffer` (set a buffer to a word: zero counters), `MakeBuffer`/`UploadBuffer` (weights, tables), `MakeTextureFromField` (R32_FLOAT texture copy of a field, for `tex.SampleLevel`), `DispatchGridNoCb`, `GroupsFor`, `Executor::Download` of buffers or textures (a download waits for the device with a limit).

## Threading and failure rules

* **One lock, one lease.** `Lease lease(wait)` takes the backend's mutex and the executor; it is released in the destructor. `TryRun` uses `Lease(false)`: if another thread is using the GPU the op does NOT wait, it runs on the CPU. Natives that were asked explicitly (`ed_gpu_selftest`) use `Lease(true)`. A thread that already holds a lease gets none (no nested use, no deadlock). The immediate context of Direct3D 11 is only touched under the lock, so field ops may run on any thread. `Backend::Info` and `MayWork` use a second small mutex and never wait for the device.
* **Resources must not outlive the Lease** they were made under (they are returned to a pool when destroyed; a pooled buffer is NOT cleared: `Upload` or write before reading; the pool keeps at most 512 MB and drops entries idle for 30 s).
* **Create on first use, on the calling thread.** No threads are started. The D3D9 adapter lookup (`GetCreationParameters` / `GetAdapterIdentifier`) is only done on the main thread (`EdGpuLua.cpp BeforeUse`); on another thread the device is created without the preference.
* **No exceptions through the API**, no unbounded wait: every wait on the device (`Sync`, `Download`) polls an event or timestamp query for at most 6 s, then marks the executor lost. After any failing call `GetDeviceRemovedReason` is checked; a removed or hung device sets `Executor::DeviceLost()`, and the `Lease` destructor (or `TryRun`) then calls `Backend::MarkFailed`: every later `Acquire` returns null, every op takes the CPU path. The failed device objects are deliberately not released (a stuck driver may block `Release`).
* **A failed op leaves `out` untouched**: build the result in a local `Grid` and move it at the end. `TryRun` catches exceptions of the op function and treats them as `Failed`.
* **Ops return** `Done`, `Unsupported` (silent: parameters the GPU version does not handle) or `Failed` (counted as a fall-back; message kept for `ed_gpu_info().lastOpError` and the Settings panel).
* **Log**: the backend logs device creation, shader compiles (with timings) and failures through a sink (`SetLogSink`); `EdGpuLua.cpp` queues the lines and the UI thread writes them to the engine log (`EDITOR GPU compute: ...`), because the engine log is not known to be thread safe.
* **Shader compiler**: HLSL text embedded in the exe, compiled with `D3DCompile` (`cs_5_0`, optimisation level 3, strictness on) the first time a kernel is dispatched, cached in memory for the session by the source hash. Errors (first 2000 characters of the compiler output) are logged and returned as the op's failure reason. **Not done**: an on-disk cache keyed by source hash and compiler version (each editor start compiles the kernels it uses again; the five built-in kernels take well under a second together on a typical driver, est.).

## Testing a kernel without a GPU

The emulator (`gpu/hlsl_cpp_shim.h`, `tests/EdGpuEmu.h`) is the safety net: it checks the maths, the indexing and edge handling, the guards (zero out of range accesses), the barrier structure (phases), the constant buffer layout (size), the binding rules, the op glue (parameter reading, `Unsupported` cases, ping-pong, output placement) and the whole `RunOp -> TryRun -> op -> RunOpCpu` path including fall-back, lost device, busy GPU, self test first and threads. It cannot check: that the HLSL compiles with FXC, the real GPU's float behaviour (fused multiply-add, `pow`/`exp` approximations, denormals), hardware texture filtering precision, driver bugs, memory limits, timing and TDR. Those are what `ed_gpu_selftest()` and a run on real hardware are for.

Test hooks: `SetBackendForTest(&EmuBackend)`; `EmuExecutor::failAtDispatch = n` (the n-th dispatch fails), `lostAtDispatch = n` (fails and reports a lost device), `texturesSupported`, `maxBytes`.

## Verify on your machine (first thing to do)

1. **Build**: `python scripts/studio.py engine build`. The Direct3D 11 code has only been syntax-checked against stub headers: if MSVC reports an error in `EdGpu.cpp` / `EdGpuLua.cpp` it is a typo in a D3D11/DXGI call or a missing header; the message names the line.
2. **Native tests**: `python scripts/ed_native_tests.py`. `EdGpuTest` prints `real GPU backend: ... adapter '<name>' ...` and, if a device was created, the four self test parts with times. A machine without a usable adapter prints `skipped`, which is not a failure; a wrong result on a real device is.
3. **In the editor**: Ctrl+Shift+P, "GPU compute: show the adapter and run the self test" (`dev.gpu`), or Settings, "Test GPU compute". Expected Console lines: `GPU compute: on, available, adapter <name> (N MB), Direct3D feature level 11_0, shader compiler d3dcompiler_47.dll, textures yes`, then `ops with a GPU version: blur, box ...`, then four lines `... ok (x ms)` and `Test passed in N ms.` Send me the lines starting with `EDITOR GPU compute:` from the log if anything differs (compile errors from the HLSL compiler are logged there in full).
4. **Real use**: start with `/perf`, open a map of at least 256 x 256 and run a blur (Terrain graph node `blur`, or the Fields panel). The perf report (every 5 s) must show `field ops: gpu: N ops ...`. Run it again with `ed_gpu_compute 0` (console or Settings) and compare the time (`cpu:` line) and the picture. Expect equal looks; sample values differ in the last bits only.
5. **If anything is wrong**: `ed_gpu_compute 0` (Settings: GPU compute Off) puts everything back on the CPU at once. `ed_gpu_info()` shows `lastError` / `lastOpError`.

## Known risks

* **Unverified on a GPU** (see top). First suspects, in order: an HLSL compile error from FXC (macro expansion of `register(b##slot)`, `PHASES_BEGIN` braces), a typo in a D3D11 call, `CopyResource` from a structured buffer into the raw staging buffer (the DirectX SDK samples do exactly this), `UpdateSubresource` on a structured UAV buffer, R32_FLOAT typed UAV store on old hardware (then `textures` is false and the texture kernels are refused; the self test texture part reports it).
* **TDR (2 s driver reset)**: batches target 60 ms, a single blur dispatch is refused above ~3e10 multiply-adds (the CPU does it). A kernel that is slow per iteration must be split. After a TDR the backend is off for the session (`ed_gpu_enable(true, true)` retries).
* **Driver differences**: float results differ between vendors (fused multiply-add, transcendental precision); the self test tolerance is 1e-3 on values up to 100 for the blur and 0.01 for texture filtering. Typed UAV loads are not used (only feature-level-11.0-mandatory R32 formats).
* **Determinism is not needed** (no replay): do not write tests that demand bit equality with the CPU on the real device; the emulator tests may.
* **Memory**: an op may hold at most `min(video memory / 2, 3 GB)` (at least 256 MB; integrated GPUs use a quarter of the shared memory); larger requests are `Unsupported`/`Failed` and take the CPU path. A Direct3D 11 buffer is limited to 2^27 elements (a 8192 x 8192 float field fits, 16384 x 16384 does not). Pooled buffers stay up to 512 MB for 30 s after use.
* **Two adapters** (laptops): the adapter of the D3D9 device is preferred. If the lookup fails (no device yet, worker thread) the one with the most video memory is used, which may differ from the one that draws the scene; both work, a transfer between them is not needed (nothing is shared with the renderer).
* **First use stall**: creating the device (~50-300 ms, est.) and compiling the kernels happen in the first big op. The self test adds a few small dispatches.
* **Shutdown**: the backend is a function-local static destroyed at exit; a failed backend leaks its objects on purpose. The D3D11 device is independent of the D3D9 device (nothing is shared), so the renderer's device reset (resize, alt-tab) does not affect it.
* **Shim limits**: the emulation is single threaded (no race detection for group shared memory), scalars are float32, `pow` and friends use the C library (the GPU uses its own).

## Generator and filter kernels (GP3)

Agent GP3, 2026-10. GPU versions of the generator and filter ops of the field engine, registered under the SAME op names (the interceptor picks them up). **Verified on the CPU emulator only: no GPU was available** (see "What nobody could verify" below). Files: `EdGpuGen.h` (helpers), `EdGpuGen.cpp` (generators), `EdGpuGenFilt.cpp` (filters), `EdFieldFractal.h` (the option reader of `fractal`, shared by the CPU op and the GPU op), `gpu/gen_*.hlsl` / `gpu/filt_*.hlsl`, `tests/EdGpuGenTest.cpp` (`scripts/ed_native_tests.py`: `EdGpuGenTest`; ~950 checks).

### Ops

CPU times: 4 threads, 2049 x 2049, one machine (a measure of the ranking, not of your machine). Speed-up class: **A** = compute bound, no or one upload (expect 10x to 100x on a discrete card), **B** = iterated or window ops (10x to 50x), **C** = a few operations per sample, transfer bound (1x to 4x, only worth it on big fields: they stay on the CPU below 16 x `ed_gpu_min_cells` = 1048576 samples).

| Op | CPU ms | Class | Not on the GPU (CPU runs) |
|---|---|---|---|
| `fractal` (fbm / billow / ridged, rotate, finest, warp, warp_levels, slope_detail, style, erosion, antialias) | 550 (1010 with warp) | A | bad option values only |
| `perlin` `simplex` `ridged` `billow` | 340 to 400 | A | none |
| `musgrave` (ridged / hybrid / hetero), `fbm_damped` | 490 / 510 | A | none |
| `voronoi`, `cells` (4 metrics, 10 modes, warp), `cracks` (1 to 3 levels) | 180 / 800 / 2200 | A | none |
| `craters`, `dunes`, `island` | 205 / 430 / 340 | A | none |
| `occlusion` | 7260 | A | none |
| `dwarp` (fbm, curl, swirl, ripple, pinch, mask, 3 edge modes) | 510 | A | none |
| `bilateral`, `blur_dir` (mask) | 690 / 345 | B | `blur_dir` with length 0 (a copy) |
| `diffuse` (iterated, mask) | 460 | B | 0 iterations |
| `blur`, `box` (foundation) | 100 / 32 | B | a mask is now handled (one more kernel, `filt_lerpmask`); a mask of another size is ignored like on the CPU |
| `slope` (degrees, gradient), `curvature`, `aspect`, `hillshade` (shade, lit, shadow), `normal_map` (three outputs) | 34 / 12 / 20 / 20 / 74 | C | slope `rating` / `variation`; fields below the size above |
| `amplitude`, `terrace`, `levels`, `remap`, `warp`, `distance` (and the other point filters) | 0 to 250 | not ported | see below. GP4 ported `unsharp`, `edge`, `morph`, `convolve`, `blur_slope`, `stratify`, `rockiness`, `wetness`, `flow` and decided on `symmetrize` (stays on the CPU) |

Why some ops are not ported: `amplitude` and `terrain_mix` spend their time in a statistics pass over host memory (the host already has the data; the GPU would only do the cheap apply pass); `terrace`, `levels`, `remap`, `warp` are one to three operations per sample and the upload and download cost more than they save at any size this editor uses; `symmetrize` is a gather over the same field (no heavy maths). They would pay off the day fields stay resident on the GPU between the ops of a graph (a graph runner change, not a kernel change). `distance` is 114 to 134 ms at 2049 x 2049: a jump flood version is possible but not worth the risk yet. `wetness` and `flow` needed a global sort and a sequential sweep: GP4 solved that with a tiled accumulation (see "More field ops (GP4)"). `thermal`, `thermal_map` and `settle` were not done by GP2 (which ported the two solvers `erode_hydraulic` and `erode_droplet`): GP4 did them.

### How the kernels are built

* **One noise library** (`gpu/gen_noise.hlsli`): the CPU's lattice hash (`Hash2i` = `Hash2`), its 8 and 64 gradient directions (the 64 directions are computed with `sincos`, angle `(k + 0.5) * pi / 32`), the quintic fade, value + analytic derivative (`PerlinD`), simplex, and `Fbm01`. Same arithmetic order as the CPU, so GPU and CPU agree to about 1e-6 (emulator): the GPU result looks exactly like the CPU result. There is no "statistically equal" case: nothing uses a different hash or algorithm.
* **Positions are computed in double on the host.** A float cannot hold `ox + x * cell` for a 4096 sample field. The host (`PutMap`, `PutOctaveMap`) turns, per octave, "sample index -> world position -> octave frame (turn, shift, frequency)" into an affine map `u = u0 + a x + b z` with `u0` split into an exact integer and a fraction. The kernel (`LatticePoint`) adds in float only numbers of the size of the field in lattice units. A field that starts at world (20000, 18000) agrees with the CPU to 1e-6 (test `fractal_far`). Simplex noise gets the skewed map, so the simplex cell and fraction are exact too.
* **Octave tables.** Per op a float table (16 floats per octave: map, amplitude, per kernel extras) and a uint table of seeds are uploaded once (`UploadVec`), no per sample table lookups beyond that.
* **Banded dispatch.** `DispatchBands` splits a big field into row bands of about 2.5e7 octave evaluations and runs them through `RunIterations` (time limited submissions), so a 16384 x 16384 field with 12 octaves cannot trigger the 2 second driver reset even on an integrated GPU.
* **Cheap ops are size gated** (`BigEnough`: `CellsOf(args) >= 16 x ed_gpu_min_cells`), so the knob still controls everything and the tests (`minCells = 0`) see all ops.
* The octave count of generators is at most 16 (the CPU's limit); the CPU `fractal` allowed up to 16 octaves before and still does.

### Quality improvements (both on the CPU op and on the GPU op: same options, same look)

New options of `fractal`, all off by default (saved graphs and golden checksums are bit identical: `EdLandTest` and a checksum comparison before / after the refactor):

* **`style = erosive`, `erosion`** (0 to 16, default 1; ridged noise uses half of it internally): derivative damped fbm. Every octave is divided by `1 + erosion * s^2` where `s` is the slope of the signal of the octaves summed so far (analytic derivatives of the noise, in units of amplitude per feature size). Steep ground keeps its smooth shape, flat ground and crests keep the fine detail: the look of eroded land, without simulating erosion. Rolling (`fbm`) looks right; **ridged + erosive is strong** (large smooth slabs between the sharp crest lines): use `erosion` 0.3 to 0.6 there. Render: `r_styles.png`.
* **`warp_levels = 2`**: the domain warp is read at a place that the first warp already moved (warp of a warp, independent noise channels, 3 octaves each): twisted, folded forms. Render: `r_warp.png`.
* **`antialias = 1`**: octaves with a wavelength between 2 and 4 samples fade out, shorter ones are dropped. A coarse preview is then the low pass of the full resolution result (test: the mean slope of a 65 x 65 preview of a rough terrain is within 2.5 percent of the low pass of the 513 x 513 result; point sampled it is 23 percent too steep). Without it the preview shows fine octaves aliased into extra roughness.
* Already there and now verified on the GPU path: 64 gradient directions and a turn and shift per octave (`rotate`, no lattice seams, no preferred axis), world position invariance (a 33 x 33 grid with cell 4 agrees with a 129 x 129 grid at the same places to 1e-3 in float, bit exact on the CPU), `finest` (smallest wavelength), derivative based `slope_detail`, ridged multifractal weight feedback.
* Lua: the `Terrain noise` graph node has `Style`, `Erosion strength` and `Warp passes` (with tips); `C()` and the inspector's choice buttons take a tip now. The Fields panel presets (`fieldgen.lua`) were NOT switched to the erosive style (that changes the look of every saved Generate setup): it is a one line change per preset once you have compared them on your machine.

### Testing

`tests/EdGpuGenTest.cpp` runs every kernel on the emulator through the real interceptor (`RunOp` -> `TryRun` -> op -> kernel) and compares with `RunOpCpu`:

* every op, every mode / kind / style, with and without masks, rotate, warp; odd sizes (1 x N, N x 1, 1 x 1, 17 x 13, not a multiple of 16); fields far from the origin; the `Unsupported` branches (bad option, 0 iterations, window slope modes, small fields on the default policy);
* agreement: noise ~1e-6, cellular ~1e-5 (a distance tie may pick the neighbour feature point: at most 0.5 percent of the samples for `cells` / `cracks`, measured 0), stencils bit equal;
* no out of range buffer access (`emu::gOob`), no NaN, range 0 to 1;
* quality: lattice ratio, slope isotropy (variance ratio < 1.2), world position invariance, antialiased preview, erosive damping (steep / flat roughness ratio 1.73 classic against 0.98 erosive);
* `EdGpuGenTest --png DIR` writes the fields of the renders; `-v` prints the differences. `EdGpuTest`'s kernel table check skips kernels another test owns (`gen_`, `filt_`, `erosion_`).

### What nobody could verify without a GPU

* That FXC compiles the kernels (the generator lints the language subset; the C++ twin compiles; nothing has seen the HLSL compiler). Likely suspects: the function-defining macros in `filt_common.hlsli` (`DEFINE_BILINEAR_C`), `LOOP while`, `int % int` in `filt_dwarp.hlsl`, loops with a non constant bound containing `break`.
* Real hardware float behaviour: `sin`/`cos`/`exp`/`pow` approximations (the 64 gradient table is computed with `sincos`: a device with a rough `sincos` makes the noise slightly different from the CPU's but still smooth), fused multiply-add (expect 1e-5 level differences), `atan2`.
* Speed: all the speed-up classes above are estimates from operation counts. Register pressure of `gen_fractal` (up to 16 octaves with derivatives) is the one place where a surprise is likely.

### Checklist for the first real GPU A/B

1. `dev.gpu` (Ctrl+Shift+P) passes the self test; the log shows `EDITOR GPU compute:` lines. Then the first big generator compiles its kernel (log line with the compile time): send the compile errors if any.
2. Open the Terrain graph, add `Terrain noise` at 1025 or 2049 samples: `/perf` shows `field ops: gpu: ...`. Switch `ed_gpu_compute 0` and compare the picture (expect the same to the eye; hillshade of the difference should be noise at the 1e-5 level) and the `cpu:` time.
3. Same for: `Eroded noise`, `Multifractal`, `Cells` (plate / border), `Cracks`, `Domain warp`, `Ambient occlusion` (the big one), `Bilateral`, `Diffuse`, `Blur` with a mask, and `Slope` / `Normal map` at 4096.
4. Compare `Terrain noise` with Style `Eroded` on both backends, then try Warp passes 2 and Erosion strength.
5. A 4096 x 4096 `fractal` with 12 octaves and warp 2: the first run must finish without a driver reset (time, no black screen); try an integrated GPU too if the machine has one.
6. Check the statistics line: no op should show `K fell back to the cpu` other than the documented `Unsupported` cases (those are not counted as fall-backs).

## Erosion kernels (GP2)

Ops `erode_hydraulic` and `erode_droplet` have GPU versions (`EdGpuErosion.cpp`, kernels `gpu/erosion_*.hlsl`, test `tests/EdGpuErosionTest.cpp`, the kernels' emulation blocks in `tests/EdGpuErosionKernels.inc`, shared with `EdGpuTest`). They run for fields of at least **4096 samples** (own threshold: `RegisterGpuOp(name, fn, minCells)`; the effective minimum is `min(op minimum, ed_gpu_min_cells)`, so `ed_gpu_min_cells 0` still means "everything"). `erode_stream` stays on the CPU (a priority flood and a sorted drainage network do not parallelise cheaply). The setting around the solve (hardness / rain / protect factors, cell noise filter, conserve, keep_range, max_change, the outputs wear / deposit / flow / water / sediment / accum) is the CPU op's own code, exported from `EdErosion.cpp` (`BuildOpFactors`, `FinishHydroOp`, `FinishDropletOp`, `DropletParamsOf`, `HydroParamsOf`, `FillSteeringSurface`), so a setting means the same on both paths and only the solve differs.

**The GPU hydraulic solver is not the CPU solver on other hardware.** It is the improved solver the user asked for ("better erosion math"): the same settings give a similar but not the same, and on long runs a clearly better, result. The droplet solver is the same algorithm run in parallel (same look, not the same samples).

### Hydraulic solver (`erosion_hydro_{flux,water,apply,transport,settle}`, `erosion_thermal_{a,b}`)

One iteration = flux, water, apply, transport (4 dispatches) + a thermal step (2 dispatches) every `thermal_every` iterations; all passes read and write global memory (ping-pong ground; no group shared memory), `RunIterations` slices them (60 ms submissions).

| Pass | What |
|---|---|
| flux | Eight pipes per cell (4 axis, 4 diagonal; the diagonal gain is a quarter of the axis gain, which is the weight ratio of an isotropic 3 x 3 Laplacian). `F = F * (1 - flux_damp) + gain * (water surface difference)`, never negative, scaled so a cell gives away at most its water (rain included). Open edge: a dry ghost cell continuing the edge cell's slope (as the CPU op); closed: no pipe; pinned ring: no pipes. Persistent flux (momentum) as the CPU solver, but with friction: the CPU solver's flux grows until the "no more water than I have" rule limits it, so every wet cell runs at nearly the same speed whatever its slope (about 0.6 cells per step measured) and erosion becomes a pure slope law = diffusion: gentle terrain melts into a plain. |
| water | `d' = d + rain + inflow - outflow`; speed = vector sum of the unit directions of in- and outflux over the mean depth (floor 0.002), at most `max_speed`; slope = sin of the central difference gradient, limited above `slope_cap` (`s / sqrt(1 + (s / cap)^4)`: grows like `s` up to the cap, a plateau, falling off again on cliffs: **steep faces no longer dominate**), floored at `min_slope`; capacity `capacity * speed^speed_pow * max(0, min(depth_gain, depth / depth_max) * slope - shear_floor)`; dissolve `erosion * rock * (cap - s)` limited to `cut_limit` of the drop to the lowest of the eight neighbours, or settle `deposition * (s - cap)`. Writes the ground change `dT`, not the ground. |
| apply | `T -= (1 - erode_spread) * dT + erode_spread * binomial3x3(dT)` with symmetric weights (an edge or pinned neighbour gives its weight to the centre): mass is conserved exactly, and a groove is 2 - 3 cells wide instead of one (**no cell wide combs**, the lab's `1 cell Laplacian share` drops from 0.080 to 0.060 on mounds and the grid aligned combs of the first version are gone). |
| transport | Sediment moves through the same eight pipes, upwind and conservative: `s' = sn (1 - out / dOld) + sum sn_j flux(j -> i) / dOld_j`; what leaves over an open edge is gone, then evaporation. (Semi-Lagrangian backtracing was considered: with a speed of at most one cell per step it is the same first order upwind scheme but not conservative.) |
| settle | At the end the suspended sediment settles where it is (`settle=1`, as the CPU op). |
| thermal a / b | The CPU `ThermalImpl` ported 1:1 (8 neighbours, talus per axis / diagonal step, share = rate * 0.5 * largest excess / sum of excesses, rate mask from `protect`, pinned sides). The emulator test compares it with the CPU result: largest difference below 2e-4 on 75 x 49 (pinned / open / closed, with and without protect). |

The noise the user asked for: `rain_noise` (default 0.2) multiplies the rain of a cell by `1 + noise * (2 * hash(cell, seed, iteration / 4) - 1)` (`Hash32` of `common.hlsli`), which breaks the symmetry of the flow. **Why the defaults are what they are** (`flux_damp 0.3`, `depth_gain 4`, `erode_spread 0.7`, `slope_cap 0.4`): measured on the lab terrains (scratchpad `gp2/final/`): without friction, 2000 iterations flatten the rough plateau of `mount.raw` into an inclined plane with gullies only on the steepest rim (the CPU result and the first GPU version look the same); `depth_gain` (the capacity keeps growing with the water depth: deeper concentrated flow digs harder, the real positive feedback of channels) makes branching gullies appear on the smooth massif `mtn100.raw`; `erode_spread` removes the grid aligned one cell combs the first version had in its lower slopes; `slope_cap` below about 0.3 keeps the cliffs of `hills.raw` sharp, above 0.5 they get a scalloped lip.

Parameter mapping (CPU parameter -> GPU):

| CPU parameter | GPU behaviour |
|---|---|
| `iterations`, `rain`, `evaporation`, `capacity`, `erosion`, `deposition`, `depth_max`, `min_slope`, `max_speed`, `cut_limit`, `talus`, `thermal`, `thermal_every`, `settle`, `masks` | supported, same meaning (`cut_limit` looks at 8 neighbours, `rain` is multiplied by the noise above) |
| `gain` | supported; clamped to 0.2 (eight pipes: the weights add up to 5 gain; the CPU limit for four pipes is 0.25) |
| `edge` open / closed / pinned | supported (same ghost cell rule; the ring of `pinned` is the CPU op's) |
| `vary`, `vary_scale`, `rain_vary`, `protect`, `seed`, mask input | supported (computed on the CPU by the same code, uploaded as per cell factors) |
| `smooth`, `smooth_passes`, `conserve`, `keep_range`, `max_change`, `output`, extra outputs | supported (CPU code after the download) |
| `cpu_only = 1` | Unsupported: the CPU op runs (the node's / panel's "CPU only (0 / 1)": the A / B switch) |
| bad input (mask of another size, unknown `output`), `iterations <= 0`, field smaller than 4 x 4, `4 * cells > 2^27` elements or more memory than the device budget (about 25 floats per sample) | Unsupported: the CPU op runs and reports its own error |
| GPU only: `flux_damp 0.3`, `depth_gain 4`, `shear_floor 0`, `erode_spread 0.7`, `slope_cap 0.4`, `rain_noise 0.2`, `speed_pow 1`, `speed_floor 0` | the improvements above; sliders "(GPU)" in the Hydraulic panel / node (`speed_pow`, `speed_floor`, `shear_floor` are only reachable from a graph's op parameters) |

### Droplet solver (`erosion_drop`, `erosion_drop_resolve`, `erosion_steer`, `erosion_copy`, `erosion_delta`, `erosion_blend` + `blur_pass`)

One thread per droplet (batches of at most 524288 per dispatch), a hash of (seed, round, droplet number) for everything random (start, release test, `drop_vary` draws, the random turn on flat ground). The droplet is the CPU `RunDroplet` line by line: bilinear gradient of the steering surface, inertia, capacity, `accel`, evaporation, lifetime, dissolving with the cone brush of radius `radius` (weights `R + 0.5 - distance`, mirrored at the map edge, times the rock factor, at most `round_cut` below the steering surface), bilinear deposit never above the spill surface, the rest settles at the end. **The ground is changed by atomics**: `dq`, `wq` (wear), `pq` (deposit) are `RWStructuredBuffer<int>` in 1/65536 world units (`InterlockedAdd`), `fq` (flow) in 1/1024; a droplet sees `start height + dq / 65536`, which other droplets change at the same time, so there is no order and no determinism (the editor does not need it). Every amount goes through the integer first, so the droplet's sediment and the ground always agree (the test: `sum(deposit) - sum(wear) = net change` to 1e-3). `erosion_drop_resolve` adds the integers to the floats at the end of every round.

Between rounds (`rounds` of them): creep = the CPU `Creep` (`d = t - t0`, `whole` binomial 3 x 3 passes with the foundation's `blur_pass` kernel, one more pass blended in for the fraction, `t += rock * (smoothed - d)`), and the steering surface follows the ground (`erosion_steer`: `hs = max(hs + min(now - before, 0), now)`). After the last round: the cell noise filter (`smooth`, `smooth_passes`: the same filter kernels), `thermal` / `thermal_steps` (the thermal kernels), then the CPU `PostProcess` and outputs.

**The one thing that is still on the CPU is the pit filling** of the steering surface (`drain_pits`, a priority flood, Barnes 2014). The GPU op downloads the ground, fills it on the CPU and uploads the result every `steer_every` rounds (default 8; round 0 always) and follows the ground with the incremental `erosion_steer` update in between (so a valley dug through a filled basin's rim stays a valley, but a pit that deposits create is only filled at the next refresh). Cost: 2 transfers and one fill (about as much as the CPU needs per round) per refresh, 4 refreshes at 32 rounds. A parallel flood was not found that is cheap enough (relaxation needs as many iterations as the longest drainage path); if the first real run shows the refresh dominating, raise `steer_every`.

| CPU parameter | GPU behaviour |
|---|---|
| `density`, `lifetime`, `inertia`, `capacity`, `min_slope`, `erode`, `deposit`, `evaporate`, `gravity`, `radius`, `speed`, `water`, `round_cut`, `rounds`, `seed`, `accel`, `drop_vary`, `creep`, `smooth`, `smooth_passes`, `thermal`, `thermal_steps`, `talus` | supported, same meaning |
| `drain_pits` | supported (0: steer on the ground, 1: filled surface, refreshed every `steer_every` rounds, see above) |
| `vary`, `rain_vary` (release probability thinning), `protect`, mask input, `max_change`, `keep_range`, `conserve`, `output`, extra outputs | supported (same code as the CPU op) |
| `cpu_only = 1`, bad input, `density <= 0`, field smaller than 4 x 4, more memory than the device budget (about 26 floats per sample) | Unsupported: the CPU op runs |
| GPU only: `steer_every 8` | see above |

### What the emulator verified

`tests/EdGpuErosionTest.cpp` (243 checks, about 35 s; also `EdGpuTest` compiles the same kernels): the thermal kernels equal the CPU's (max difference < 2e-4, three edge modes, protect factor, 75 x 49); no rain and no slides = no change; mass: closed edges conserve the ground (hydraulic) and `deposit - wear = net change` (droplets); `conserve`, `max_change`, `keep_range`, pinned ring, open edge row consistency; peaks are lowered relative to the low ground; the relief (std) stays (hydraulic 300: 0.90 of the input against 0.63 on the CPU); masks (zeros = nothing changes, half protected = about 0.2 % of the change on the protected half); isotropy (a tilted plane in four directions: largest / smallest mean change 1.13, the CPU op 1.11); fine structure (1 cell Laplacian share of the change: 0.060 against the CPU's 0.116 hydraulic, 0.014 against 0.015 droplets; no grid direction: axes / diagonals 0.79 / 1.27, the CPU op 1.02 / 1.29; creep widens the grooves 5 times); small and non square fields (4 x 4 to 64 x 3, 1 x 50), parameter extremes (every parameter at both ends, every `output`), a 1100 x 1000 field (several droplet batches, 2D dispatches); zero out of range buffer accesses in every run; `Unsupported` and fall-back paths (cpu_only, wrong mask, unknown output, a failing dispatch at three places, a lost device, a too small memory budget).

The lab measures of the earlier erosion work (scratchpad `gp2/`, `drvgpu` runs the same ops on the emulator against the CPU): on the six lab terrains the droplet solver's change has the same size and the same fine structure as the CPU op's (rms of the change within 5 %, participation ratio and cut share equal, 1 cell Laplacian share equal) and the pictures are indistinguishable at the eye (`final/droplet_default*.png`, `final/presets_*.png`: hills, mountain, alpine, desert presets); the hydraulic solver gives gullies where the CPU solver gives none (`final/hydraulic_300*.png`).

### What nobody could verify without a GPU

HLSL compilation of the new kernels (first suspects: `static const int kDirX[8]` tables in `erosion_common.hlsli`, `InterlockedAdd` on `RWStructuredBuffer<int>` elements, 8 UAVs in `erosion_drop_resolve`), speed (the estimates: a hydraulic iteration of a 4096 x 4096 field reads about 2 GB, so 5 - 15 ms; 300 iterations a few seconds), atomic contention in droplets that all run down the same valley, the time of one droplet dispatch with `lifetime 200` (TDR: batches are 524288 droplets), float behaviour of `sqrt` / `cos` / `sin` (random turn) on the card, the memory budget (about 25 floats per sample: 4096 x 4096 is about 1.7 GB, so cards below 4 GB of video memory give `Unsupported` and the CPU runs it), the real cost of the CPU pit filling per refresh at 4k x 4k.

### Known weaknesses of the GPU hydraulic solver (seen on the lab pictures)

* Long runs lay a wide apron of sediment around an isolated mountain (`island.raw`, 300 iterations: a scalloped ring, alluvial fans that reach far over the flat plain) and creases along the divides between mounds (`mound.raw`). The CPU op leaves these places untouched because its water hardly leaves the steep ground. Fewer iterations, `deposition` up, or `slope_cap` down reduce them.
* The coarse preview of the erosion panel (`Erosion.OpParams` with `step > 1`) scales the CPU solver's rates; the GPU solver is not tuned for that scaling (the preview shows the same kind of result, not the same one).
* At the default `slope_cap` a rim that is a one cell step still gets a faint scalloped lip in the 100 step `hills` preset (visible in `final/presets_*.png`).

### Checklist for the first real GPU A/B

1. `python scripts/studio.py engine build`; `python scripts/ed_native_tests.py` must print `EdGpuTest` and `EdGpuErosionTest` without a failure (on Windows both also run the self test on the device); `dev.gpu` in the editor must show `ops with a GPU version: ... erode_droplet, erode_hydraulic ...`. Send the `EDITOR GPU compute:` lines of the log if an erosion kernel does not compile (the first compile happens in the first erosion run: expect 1 - 3 s once per kernel).
2. Load a map of at least 512 x 512, open the Erosion panel, preset Hills, Run. `/perf` must show `gpu: N ops` for `erode_hydraulic` and the time against `CPU only = 1` (the slider at the bottom of the solver's sliders): the same run twice, the second with CPU only.
3. Compare the pictures (hillshade with the light from two sides): the GPU hydraulic result has more gullies on steep and mid slopes, wider grooves, no one cell combs; the cliffs keep their edge; if it looks wrong try `Steep slope limit` 0.25 / 0.6 and `Water friction` 0 (which reproduces the CPU solver's flow). The droplet result must look like the CPU one (not identical).
4. Mass: run with `Keep volume` 0 and look at the Console / mean height before and after (Fields statistics): closed to a few percent of the moved volume on closed edges, a little more with open edges.
5. Stress: 2048 x 2048 and 4096 x 4096 hydraulic with 300 iterations and droplets with density 2 / 32 rounds: no black screen (TDR), the time per iteration, `ed_gpu_info().lastOpError` empty. Watch the droplet's refresh stalls (a pause every 8th round while the CPU fills the surface: raise `steer_every` if it dominates).
6. Memory: a 4096 x 4096 hydraulic run on a card with 4 GB must fall back to the CPU quietly (no error), on 8 GB it runs.
7. Droplets with the mask input and with `vary` / `protect`: the same checks as in the CPU version (protected ground stays).

## More field ops (GP4)

Agent GP4, 2026-10. GPU versions of 17 more field ops, registered under the SAME names (the interceptor picks them up), and a written decision for every other candidate. **Verified on the CPU emulator only: no GPU, no MSVC, no editor was available** (see "What nobody could verify (GP4)" below). Files: `EdGpuFieldCommon.h` (gates and helpers), `EdGpuFieldIter.cpp` (iterated slides: `settle`, `thermal`, `thermal_map`, `erode_rocksoil`, `erode_snow`, `erode_wind`, `erode_glacier`), `EdGpuFieldFilt.cpp` (`morph`, `convolve`, `unsharp`, `edge`, `blur_slope`, `slope_limit`, `rockiness`, `stratify`), `EdGpuFieldFlow.cpp` (`wetness`, `flow`), 26 kernels `gpu/field_*.hlsl` with their `field_*_params.hlsli`, `BlurDevice` (EdGpuOps.cpp: the foundation's Gaussian blur as a building block for ops that need one), `tests/EdGpuFieldTest.cpp` (`scripts/ed_native_tests.py`: `EdGpuFieldTest`, 2211 checks, 3 s), `tests/EdFieldBench.cpp` (the CPU timings below).

### The rule and the decision table

The rule of "Add a kernel and a GPU op" stands: upload and download cost ~8 bytes per sample over the bus (tens of ms at 4096 x 4096), so only **iterated** ops, **large windows** and **global / accumulating** ops go to the GPU; plain point filters stay on the CPU. Every candidate was run once on a fractal terrain (`tests/EdFieldBench.cpp`, 4 threads, the same machine for all rows; a measure of the ranking, not of your machine):

| Op (parameters of the run) | CPU ms at 2049 x 2049 (513 x 513) | Decision | Why |
|---|---|---|---|
| `settle` (20 iterations) | 1196 (75) | **ported** | iterated 8 neighbour stencil + slope fade |
| `thermal` (20), `thermal_map` (30) | 1258 (67), 1714 (106) | **ported** | iterated slides; `thermal` was not on the list, it is the same kernels |
| `erode_rocksoil` (60), `erode_snow` (40), `erode_wind` (30), `erode_glacier` (60) | 4236 (281), 1951 (126), 2259 (150), 2047 (145) | **ported** | iterated stencils; the slowest CPU ops of the field engine apart from `erode_stream` |
| `morph` dilate square r 8 / disc r 16 / open disc r 16 / tophat square r 24 | 64 (5) / 713 (58) / 1608 (113) / 199 (12) | **ported** | a large window is O(radius) or O(radius^2) per sample; gated by the window size |
| `convolve` 5 x 5 / 15 x 15 | 108 (7) / 712 (45) | **ported** | n x n taps per sample; gated by n * n |
| `unsharp` r 4 / r 20, `blur_slope` r 8 | 49 (4) / 73 (5), 63 (11) | **ported** | a Gaussian blur (the foundation's `blur_pass` through `BlurDevice`) and one point pass |
| `edge` sobel / laplace + smooth / dog | 17 (1) / 40 (3) / 73 (5) | **ported for smooth and dog**; a bare sobel / prewitt / laplace only from 16 x `ed_gpu_min_cells` samples | the blurs pay, a bare 3 x 3 stencil is transfer bound (class C of GP3) |
| `slope_limit` lower / both | 96 (5) / 191 (12) | **ported** | CPU: two sequential double precision sweeps per envelope; GPU: the same envelope as separable row and column scans, one thread per line |
| `rockiness` with / without the breakup noise | 220 (13) / 57 (3) | **ported with the noise**; without it only from 16 x min cells | 3 octave Fbm01 per sample is compute bound; the rest is a 3 x 3 gradient and four taps |
| `stratify` with / without the warp | 192 (13) / 45 (3) | **ported with the warp**; without it only from 16 x min cells | same |
| `wetness` (smooth 4) | 1665 (47) | **ported** | global: a sort and a sequential multiple flow direction sweep. New tiled algorithm, see below |
| `flow` (D8) | 922 (25) | **ported** (not on the list; the same machinery) | global: a sort and a sequential pass; the sums are whole numbers, the GPU result is bit equal |
| `erode_stream` (10 iterations) | 29643 (995) | **skipped** | 90 % of every iteration is the drainage routing: the pit breaching (`BreachPits`: a priority flood with approximate buckets of 1/128 height whose pop order decides the result) and the drainage (sort + sequential sweep) cost about 2.1 s of 2.7 s per iteration at 2049 x 2049 (route_every 1, the default), the stencils (incision, valley widening, thermal) only 0.19 s. The drainage could use the new tiled accumulation (about 60 % of the routing) but the breaching would stay on the CPU (and a GPU breach cannot reproduce the CPU's bucket order), so the whole op would gain at most 2x for a hybrid with 3 transfers per iteration. Not worth the risk; see "Open" |
| `slope_area` 2591 (76), `basin_depth` 692 (25) | | **skipped** | both need the pit filled surface (`FillSurface`, the same sequential priority flood); `slope_area` is a quality statistic and `basin_depth` a rarely used mask |
| `reach` | 1100 (48) | **skipped** | Dijkstra with a priority queue and an obstacle course: label correcting relaxation needs as many sweeps as the longest shortest path has steps (2000+ corner to corner), a tiled Dijkstra was not attempted; 1 s on the CPU at 2049 x 2049, a few ms on the previews the editor shows |
| `regions` | 466 (21) | **skipped** | an O(n) flood fill; on the GPU it needs union find, a prefix sum for the raster order labels and region sizes: more machinery than 0.5 s are worth |
| `path_dist` (and `path_along`, `path_u`, `path_mask`, `path_shape`) | 70 for 400 points / 440 for 4000 points reach 200 at 2049 x 2049; 2400 for 8000 points reach 400 at 4097 x 4097 | **skipped** | the cost grows with path length times reach squared and is a few ms on the coarse previews of an interactive path edit; the nearest segment search is double precision with strict `<` ties (a float version picks other segments on near ties); a GPU version needs a spatial bin of the segments |
| `symmetrize` rot4 | 425 (22) | **skipped** | a gather, but in double precision with `atan2`, `fmod` and 1e-9 snapping tolerances that choose the image of a sample: float on the GPU decides near the wedge borders differently |
| `amplitude`, `terrain_mix`, `levels`, `remap`, `terrace`, `color_ramp`, `rect_mask`, `distance` (65 ms), `blur` of a few samples ... | 0 to 65 | **stay on the CPU** | point filters: one to a few operations per sample, the transfer costs more than the maths |

### Gates

Besides the registered per op minimum of samples (16384 for the iterated ops, the policy's 65536 for the others) the filters have a **work gate** (`fops::WorthIt`, `EdGpuFieldCommon.h`): the op runs on the GPU when it does at least 8 "taps" per sample (a tap = one read and one compare or multiply add; calibrated on the CPU: about 0.4 ns with 4 threads) and `samples * taps >= 380 * ed_gpu_min_cells` (about 10 ms of CPU time at the default: a smaller job loses to the one time compile of the kernel and the cost of a submission). Taps per sample: `morph` 2 * (2r + 1) for the square, (2r + 1)^2 for the disc, `convolve` n * n, a Gaussian blur 2 * (2 * ceil(3 sigma) + 1), `slope_limit` 70 (125 for `both`), `rockiness` / `stratify` with noise 100, `wetness` 1000, `flow` 500. Pure 3 x 3 stencils (`edge` without a blur, `rockiness` / `stratify` without noise) need `BigField`: 16 x `ed_gpu_min_cells` samples (the gate of GP3's slope family). `ed_gpu_min_cells 0` switches every gate off (the tests, and "everything on the GPU"). The test `TestGates` pins all of this.

### How the kernels are built

* **Slides** (`field_slide_a/b`, one `Slider` host helper): the CPU's `SlideT` in two passes. Pass A: per cell the excess over the talus to each of the eight neighbours (axis steps `talus * cell`, diagonal `talus * cell * 1.41421356`), the share it gives (`rate * 0.5 * largest excess / sum of the excesses`, rate scaled by an optional mask), the amount it moves (capped by its loose layer when it lies on a rock layer). Pass B: `next = loose - moved + sum of the neighbours' shares * their excess`, optionally adding what arrived / left to `gain` / `lost`. Options as flags in the constant buffer (rock layer, talus map, rate mask, gain, lost); unused slots are bound to one element stand-ins (a stand-in is never both SRV and UAV of one dispatch). `thermal`, `thermal_map`, `erode_rocksoil` (two sliders: soil over rock, the rock layer every `rock_every` steps), `erode_snow`, `erode_wind` (sand on rock) use it; the weathering (`field_weather`), snow fall (`field_snowinit`), wind abrasion and upwind transport (`field_wind_a/b`) are small kernels around it.
* **`erode_glacier`**: two passes per step. Pass A computes the diffusivity and the surface slope and the largest diffusivity of the field for the time step: a maximum per group of 256 cells in group shared memory, then ONE `InterlockedMax` per group on a uint (a non negative float compares like its bits); the buffer for the next step is zeroed by the same kernel (two buffers alternate), so no clearing dispatch is needed. Pass B reads the maximum, forms `dt = min(dt_max, 0.2 cell^2 / max)` and updates ice and bed cut.
* **`morph`**: one kernel per dilation / erosion; the square element is two separable passes (rows, columns), disc / diamond / cross read the window directly (the window maximum and minimum are exact: bit equal). Open / close / gradient / tophat / bothat chain the passes and a subtraction kernel.
* **`convolve`**: taps added in the CPU's order, edges clamp / wrap / mirror like `ParseEdge`.
* **`unsharp`, `edge`, `blur_slope`**: `BlurDevice` (the CPU `GaussBlur` = the `blur` op, same kernel weights and order) plus a point kernel; `edge` smooths first when `smooth` is given and takes two blurs for `dog`.
* **`slope_limit`**: the lower envelope under a surface that rises at most `limit` per step in the four axis directions is the L1 distance transform `min over (x', z') of h + L (|dx| + |dz|)`, which is separable: along every row a forward and a backward scan `c = min(c, previous + L)` (one thread per row), then the same along every column; the upper envelope is the lower envelope of the negated field. The scans run in float (the CPU op in double): the difference to the CPU result was 6e-4 on terrain of 300 units height (about 16 float steps; the op's own margin, 0.03 cells, is 100 times larger, and the test checks the Lipschitz property of the result).
* **`rockiness`, `stratify`**: the noise is the CPU's `Fbm01` through the exact affine position map of `gen_noise.hlsli` (positions computed in double on the host); `stratify` uploads the table of layer boundaries and hardness values (computed on the host exactly as the CPU op) and finds the layer with a 13 step binary search.
* **Tiled flow accumulation** (`wetness`: multiple flow direction, `flow`: D8; kernels `field_wetprep` / `field_flowprep`, `field_wetrank`, `field_wetsweep` / `field_flowsweep`, `field_wetfinal` / `field_flowfinal`). The CPU sorts all cells by height and passes every cell's catchment to its lower neighbours in one sequential pass: a chain of dependencies as long as the longest flow path (measured on fractal terrain: 1122 steps at 2049 x 2049, 807 at 1025; with a pit filled surface 2275 / 1360). A parallel relaxation needs that many full field passes (about 16 reads per sample each: no faster than the CPU). Instead the field is cut into tiles of 32 x 32 samples. `field_wetrank` sorts each tile by height once (one group per tile, every thread counts the higher samples of its tile: a rank sort, 1M comparisons per tile). `field_wetsweep` runs ONE THREAD PER TILE through its 1024 cells in that order (highest first), keeping the flow inside the tile in a private array, and reads what flows in from the neighbouring tiles from the result of the previous sweep. The flow graph has no cycles, so sweep n is exact for every cell whose upstream paths cross at most n - 1 tile borders and the fixed point is the CPU result; the host dispatches sweeps in batches of 6 and reads a `changed` flag until a whole batch changes nothing. Measured on fractal terrain: **54 sweeps at 257 x 257, 60 at 513, 66 at 1025** (the longest river crosses 50 - 60 tile borders; an artificial serpentine channel, the worst case, needs about 60 sweeps at 70 x 70 samples and 420 at 200 x 200: one per tile border it crosses). The CPU sums contributions in another order: `wetness` agrees to 1e-6 relative; D8 sums are whole numbers, `flow` is bit equal. More than 6000 sweeps (never seen) fall back to the CPU. Memory: about 10 fields (`Fits`).
* **Estimated speed-ups** (not measured, from operation counts and the sweep counts above): iterated ops 10x to 50x on a discrete card (the bus cost is one upload and one download for all iterations); `morph` disc, `convolve` 15 x 15: 20x to 100x; the blur based ops and `slope_limit` 3x to 20x (transfer bound); `rockiness` / `stratify` 5x to 15x; `wetness` / `flow` 7x to 15x at 2049 x 2049 (a sweep is one thread per tile with 1024 serial cells, ~0.5 to 3 ms; 60 sweeps), less on 4096 x 4096 where the sweep count roughly doubles and the tile count quadruples.

### What the GPU ops do not handle (the CPU op runs, the same result as before)

| Op | Unsupported branches |
|---|---|
| all | no `a`, a mask / `b` / `like` of another size (the CPU op reports its own error), a bad `mode` / `op` / `shape` / `output` name, a job under the gates above, more memory than the device budget (`Fits`) |
| `settle`, `thermal`, `thermal_map`, `erode_rocksoil`, `erode_wind`, `erode_glacier` | 0 iterations |
| `erode_snow` | 0 iterations (only the snow fall: a point pass) |
| `morph` | a `like` that places the result differently from `a` (the CPU op places gradient / tophat / bothat by `like` and the others by `a`) |
| `convolve` | a kernel that is not n x n with n odd and at most 15 |
| `edge`, `unsharp`, `blur_slope`, `wetness` | a blur wider than one dispatch may be (`BlurAffordable`) |
| `rockiness`, `stratify` | a field whose world origin is beyond 4e6 lattice units (the exact position map) |
| `wetness`, `flow` | a flow accumulation that has not settled after 6000 sweeps |

### What the emulator verified

`tests/EdGpuFieldTest.cpp` (2211 checks) runs every op through the real interceptor (`RunOp -> TryRun -> op -> kernels`) and compares with `RunOpCpu`: **bit equal** for `settle`, `thermal`, `thermal_map`, the four `erode_*`, `morph`, `convolve`, `unsharp`, `edge`, `blur_slope`, `flow`; `rockiness` 2e-6, `wetness` 1.4e-6, `stratify` 4e-5 (5e-4 for a field at world (40000, 36000) with a tilt), `slope_limit` 6e-4 (float scan on 300 unit high terrain). For every op: all modes / shapes / edge modes / outputs / extra outputs, masks and talus maps, odd sizes (1 x N, N x 1, 1 x 1, 2 x 2, not a multiple of 16 or 32), `like` placement, the `Unsupported` branches (each checked to be answered by the CPU with the CPU's result or error), that the result is not the input (no vacuous comparison), the gates on the default policy, and zero out of range buffer accesses in every kernel. The extra tests: serpentine channel and tilted plane for the flow accumulation (many tile borders), the Lipschitz property of `slope_limit`.

### What nobody could verify (GP4)

* **That FXC compiles the kernels** (the generator lints the subset; the C++ twin compiles; nothing has seen the HLSL compiler). First suspects: `float acc[1024]` (a 4 KB private array per thread, dynamically indexed) in `field_wetsweep` / `field_flowsweep` (if FXC refuses or the driver spills badly, make the tile 16 x 16: the constants 32, 5 and 1024 of `field_wet*` / `field_flow*` and `EdGpuFieldFlow.cpp`), `break` inside a `LOOP` there, a 1024 thread group with a 1024 step loop in `field_wetrank`, `PHASES_BEGIN` with `InterlockedMax(.., asuint(..))` in `field_glacier_a`, `int % int` in `field_convolve`, `[unroll]` loops with `continue` in `field_settle`, `field_morph`, `abs` of an int; uint views (`SRV_BUFFER(uint, ..)`) of buffers made by `MakeField` (float structured buffers of stride 4: fine for D3D11, but check).
* **Speed**: every number in "Estimated speed-ups" is an estimate; the one place a surprise is likely is the tile sweep (one thread per tile: 1024 serial cells with 8 `pow` each; occupancy is low by design). If the first real run shows it slow, the cheap fix is `p = 1` style shortcuts (D8, `pf == 1` has no `pow`) and smaller tiles (more threads, more sweeps).
* **Real hardware float behaviour**: `exp` (weathering), `pow` (glacier `erode_pow`, flow weights `pf != 1`), `log`, `atan`, fused multiply add (the emulator tests are `-ffp-contract=off`; expect 1e-5 level differences where the CPU matches bit for bit here).
* **Atomic and driver limits**: one `InterlockedMax` per group in the glacier pass (16k atomics per step at 2049 x 2049), 6 dispatches between two reads of the `changed` flag, the TDR budget of the rank sort (512 tiles per submission, 0.5 G comparisons) on an integrated GPU.

### Checklist for the first real GPU A/B

1. `python scripts/studio.py engine build`, `python scripts/ed_native_tests.py`: `EdGpuFieldTest` must print `2211 checks, 0 failures`. `dev.gpu` must list the new ops (`morph`, `convolve`, ..., `wetness`, `flow`). The first run of each op compiles its kernels (log lines `EDITOR GPU compute:`; send the compiler errors if any).
2. A 2049 x 2049 map, Terrain graph: `Settle`, `Thermal` / `Thermal map`, `Rock and soil`, `Snow`, `Wind`, `Glacier` nodes with `/perf` open: `field ops: gpu: N ops`. Compare the pictures with `ed_gpu_compute 0` (hillshade; expect the same to the eye, 1e-5 level differences in the values).
3. `Wetness` (modes wet / twi / area, with and without smoothing) and `Flow` at 2049 x 2049 and 4097 x 4097: the time against the CPU, no driver reset, `ed_gpu_info().lastOpError` empty. If it says "did not settle", report the map (the sweep count is the thing to look at).
4. `Morph` disc radius 16, `Convolve` 15 x 15, `Unsharp`, `Edge` (dog), `Slope limit` (all three modes: check the result with the pathing rule, no neighbouring pair steeper than `limit - margin`), `Rockiness`, `Stratify` with a warp.
5. Statistics line: only the documented `Unsupported` cases may show up as CPU runs.

### Open

* `erode_stream`: the order of work for a future agent. (1) the drainage on the GPU with the tiled accumulation (`Drainage` = sort + MFD sweep on the pit filled surface; needs the `rain` input and the per cell steepest drop `slope` as a second output); (2) the incision, valley widening and thermal steps on the GPU (stencils, 0.19 s per iteration); (3) the pit breaching: a GPU version has to be a tile-wise priority flood with border exchange like the accumulation (Barnes 2016) and cannot reproduce the CPU's bucket order, so `erode_stream` results would differ in the epsilon gradient inside filled basins (a documented algorithm change); until then the CPU routing stays and a hybrid gains at most 2x.
* `reach`, `regions`, `path_*`: see the table. `slope_area` and `basin_depth` follow `FillSurface`.
* Fields that stay resident on the GPU between the ops of a graph would make the remaining point filters worth porting (GP3's note), and would remove most of the transfer cost of everything above.

## First run on a real card (2026-10-24, AMD Radeon RX 7900 XTX, feature level 11_0)

- **Every kernel failed to compile** on the first run (the self test then reported a difference to the CPU): the HLSL compiler's preprocessor rejects `#define BARRIER()` (error X1500, empty macro parameter list). The macro takes one dummy argument now, `BARRIER(0);`. `python scripts/gpu_fxc_check.py` compiles all 60 kernels with `fxc.exe` of the Windows SDK without the engine (run it after every kernel change; the generator's lint and the C++ emulator cannot see what the HLSL compiler rejects).
- After that: the self test passes (42 ms), `EdGpuTest` / `EdGpuErosionTest` / `EdGpuGenTest` / `EdGpuFieldTest` pass on MSVC, and the per-op A/B (`editor/runtime/lua/editor/gpu_ab.lua`, `return import('/lua/editor/gpu_ab.lua').Run(512)`) shows every op equal to the CPU result to float precision (largest difference 3e-5 for `cracks`) except the two erosion solvers, which differ by design (the GPU hydraulic solver is a pipe model with friction, the droplet solver works on atomics). 2048 and 4096 fields ran without a driver reset.
- **`erode_droplet` changed nothing** when the caller did not ask for the extra outputs (`ed_field_op`, i.e. every graph node and Generate preset; `ed_field_op_multi` worked): `erosion_drop_resolve` was bound with one dummy resource in three UAV slots (wear, deposit, flow) when the masks are off, and Direct3D drops the writes of such a dispatch, the height included. Every unused written slot gets its own dummy now (`Dev::dummy[1..6]`). Rule for new ops: **never bind one resource to two UAV slots of a dispatch**.
- **The droplet solver is not repeatable** (a droplet reads the ground other droplets are changing at the same time; the doc comment of `erosion_drop.hlsl` says so). Consequence: the same Generate seed gives a different mountain on every run while the GPU is on. The self tests with goldens or repeatability checks run on the CPU (`editor_inst.py selftests` switches the GPU off for the run). Decision for the owner: keep (fast) or give `erode_droplet` a `repeatable` switch that the Generate workspace sets, which runs it on the CPU.

## Roadmap

**Done (GP1)**: backend, lease/threading/failure rules, kernel language + generator + lint + emulator, test driver, template op (`blur`, `box`), self test, natives, perf report line, Settings toggle, `dev.gpu`.

**GP2: erosion kernels: DONE for `erode_hydraulic` and `erode_droplet`, see "Erosion kernels"; `thermal`, `thermal_map`, `erode_rocksoil`, `erode_snow`, `erode_wind`, `erode_glacier` and `settle` (`EdFieldEro2.cpp`) were done by GP4 ("More field ops (GP4)"); NOT done: `erode_stream` (pit breaching and drainage routing, see GP4's decision table), a GPU pit filling** (original plan: `EdErosion.cpp`: `RunHydro`, `RunDroplet`, `RunStream`; `EdFieldEro2.cpp`)
* Hydraulic/thermal grid methods are stencils: one kernel per sub-step, ping-pong fields (`PingPong`), `RunIterations` for the step loop, download the final fields once. Multiple outputs of an op (`args.extra`: wear, deposit, flow ...) are extra fields downloaded at the end.
* Flow accumulation / stream power: a sort-free approach per iteration (multi-pass pointer jumping or iterated relaxation) with `uint` buffers; use `FillBuffer` for counters. Droplets: one thread per droplet, atomics (`InterlockedCompareExchange` on `asuint` for float adds), hash from `common.hlsli` (`Hash32`), accept non-determinism.
* Register the GPU versions under the same op names (`hydro`, `droplet`, `stream` ... see `RegisterOp` calls); refuse parameter sets the kernels do not cover with `Unsupported`; compare against the CPU ops on the emulator with a statistical tolerance for droplets (mean/sd of the difference field) and exact tolerance for grid methods.
* Check the TDR budget: iterations x cost; the batch sizing is automatic, but a single iteration on 8k x 8k must stay far below 2 s.

**GP3: generator kernels: DONE, see "Generator and filter kernels"** (original plan: `EdFieldGen.cpp`, `EdFieldLand.cpp`: fractal, perlin, ridged, billow, musgrave, voronoi ...)
* Lattice noise is a function of (cell, seed) only: port the hash (`Hash32` / `HashToUnit` in `common.hlsli` are bit exact in the emulator) and the octave frames (`OctaveFrameOf` table: put it in a `.hlsli` as a `static const float` array, or in a structured buffer uploaded once).
* Generators have no input field: the op output shape comes from `like`/`width`/`height`/`cell`/`ox`/`oz` (copy `MakeOut` logic); only the download is needed, no upload: a generator is the best case for the GPU.
* Warp ops sample a field at displaced positions: `MakeTextureFromField` + `tex.SampleLevel` (linear clamp) gives hardware bilinear; the CPU `SampleWorld` uses double precision positions, so compare with a loose tolerance.
* Keep `Unsupported` for modes not ported; the graph runner keeps working because every failure is a CPU fall-back.

**Later (nobody assigned)**: on-disk shader cache; `Executor::Clear` as a kernel; texture formats other than R32_FLOAT; a shared D3D9/D3D11 resource path to draw GPU fields in the viewport without readback; 
