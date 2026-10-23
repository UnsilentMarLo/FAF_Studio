# GPU compute for the field engine

Foundation (agent GP1, 2026-10): a Direct3D 11 compute backend next to the game's Direct3D 9 renderer, so the field engine's heavy ops (erosion, generators, filters) can run on the graphics card. Later work (GP2: erosion kernels, GP3: generator kernels) adds kernels on top of this foundation and should be able to work from this document without reading the backend code.

> **Nothing here has been run on a GPU.** The author had Linux and g++ only. What was checked: the kernels compile as C++ and match the CPU ops in a test (CPU emulator, 213 checks); the Direct3D 11 code passes `g++ -fsyntax-only` against hand written stub headers (copied from memory, so a typo in a real signature is possible: the first MSVC build is the real compile check); the HLSL text has never been given to the shader compiler. The sections "Verify on your machine" and "Known risks" say what to do first.

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
| `EdGpuShaders.generated.h` | GENERATED, checked in. Kernel sources + metadata. `python scripts/gen_gpu_shaders.py` rewrites it; `python scripts/studio.py check` fails while it is stale. |
| `gpu/*.hlsl`, `gpu/*.hlsli` | The kernels and their constant buffer structs. `hlsl_prelude.hlsli` (HLSL macros, put in front of every kernel) and `common.hlsli` (helpers). |
| `gpu/hlsl_cpp_shim.h` | TEST ONLY: the C++ twin of the prelude, vector types, HLSL intrinsics, atomics, buffers, textures, the emulator driver. |
| `tests/EdGpuEmu.h`, `tests/EdGpuTest.cpp` | CPU `Executor`/`Backend` and the test (`scripts/ed_native_tests.py`: `EdGpuTest`). |
| `EdFieldCore.h/.cpp` | `SetOpInterceptor`, `RunOpCpu` (no interceptor, no statistics), per-op statistics `OpStats`. Still engine independent. |

Direct3D 11 is loaded at run time (`LoadLibrary("d3d11.dll")`, `dxgi.dll`, `d3dcompiler_47.dll`, else `d3dcompiler_43.dll`), so a machine without them starts the editor and simply has no GPU backend. `d3d11.lib` is also in `AdditionalDependencies` of `main_ed.vcxproj` but nothing references it.

## Behaviour in one page

* **Default**: `ed_gpu_compute 1`, `ed_gpu_min_cells 65536` (256 x 256), `ed_gpu_selftest_first 1`. Ops with a GPU version (today `blur` and `box`) on fields of at least 65536 samples run on the GPU when a feature level 11_0 hardware adapter exists, else on the CPU, exactly as before.
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
* `groupshared` and barriers only with the phase macros: write the body as `PHASES_BEGIN` code `BARRIER();` code ... `PHASES_END`, at the top level of `CSMain` (never inside a loop or an `if`, no `return` anywhere in such a kernel). Every phase is its own scope: a local does NOT live across a `BARRIER()` (compile error in the C++ build, so the rule cannot be broken unnoticed). Unroll tree reductions by hand (`reduce_sum.hlsl`). Prefer kernels without group shared memory: global-memory stencils with ping-pong buffers need no barriers and make the emulator a plain loop. Group shared memory is limited to 32 KB, a group to 1024 threads.
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
   `TestKernelTable` fails until every generated kernel has such a block (and checks that the thread group and slot masks of the HLSL text equal the generated table).
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

## Roadmap

**Done (GP1)**: backend, lease/threading/failure rules, kernel language + generator + lint + emulator, test driver, template op (`blur`, `box`), self test, natives, perf report line, Settings toggle, `dev.gpu`.

**GP2: erosion kernels** (`EdErosion.cpp`: `RunHydro`, `RunDroplet`, `RunStream`; `EdFieldEro2.cpp`)
* Hydraulic/thermal grid methods are stencils: one kernel per sub-step, ping-pong fields (`PingPong`), `RunIterations` for the step loop, download the final fields once. Multiple outputs of an op (`args.extra`: wear, deposit, flow ...) are extra fields downloaded at the end.
* Flow accumulation / stream power: a sort-free approach per iteration (multi-pass pointer jumping or iterated relaxation) with `uint` buffers; use `FillBuffer` for counters. Droplets: one thread per droplet, atomics (`InterlockedCompareExchange` on `asuint` for float adds), hash from `common.hlsli` (`Hash32`), accept non-determinism.
* Register the GPU versions under the same op names (`hydro`, `droplet`, `stream` ... see `RegisterOp` calls); refuse parameter sets the kernels do not cover with `Unsupported`; compare against the CPU ops on the emulator with a statistical tolerance for droplets (mean/sd of the difference field) and exact tolerance for grid methods.
* Check the TDR budget: iterations x cost; the batch sizing is automatic, but a single iteration on 8k x 8k must stay far below 2 s.

**GP3: generator kernels** (`EdFieldGen.cpp`, `EdFieldLand.cpp`: fractal, perlin, ridged, billow, musgrave, voronoi ...)
* Lattice noise is a function of (cell, seed) only: port the hash (`Hash32` / `HashToUnit` in `common.hlsli` are bit exact in the emulator) and the octave frames (`OctaveFrameOf` table: put it in a `.hlsli` as a `static const float` array, or in a structured buffer uploaded once).
* Generators have no input field: the op output shape comes from `like`/`width`/`height`/`cell`/`ox`/`oz` (copy `MakeOut` logic); only the download is needed, no upload: a generator is the best case for the GPU.
* Warp ops sample a field at displaced positions: `MakeTextureFromField` + `tex.SampleLevel` (linear clamp) gives hardware bilinear; the CPU `SampleWorld` uses double precision positions, so compare with a loose tolerance.
* Keep `Unsupported` for modes not ported; the graph runner keeps working because every failure is a CPU fall-back.

**Later (nobody assigned)**: on-disk shader cache; `Executor::Clear` as a kernel; texture formats other than R32_FLOAT; a shared D3D9/D3D11 resource path to draw GPU fields in the viewport without readback; per-op `minCells`.
