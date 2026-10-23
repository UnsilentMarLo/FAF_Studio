-- Timing aid: accumulates the time spent in named sections (the shell's tick, the overlay's frame update ...) and prints a report every 5 seconds while it is on.
--
--   Perf.Enabled                 on / off (starts on with the /perf command line flag; the command "Performance timing: on / off" in the palette switches it)
--   Perf.Time(name, fn, a, b)    calls fn(a, b) and adds its duration to `name`; returns what fn returns. Off: a plain call.
--   Perf.Begin() / Perf.End(name, t0)    the same for code that cannot be wrapped in a function (Begin returns nil when off, End ignores a nil t0)
--   Perf.Tick()                  called once per frame by the shell: prints the report when 5 s have passed
--   Perf.Report()                prints the sections (LOG and the Console panel), largest total first, and starts over; also which backend ran the field ops (GPU compute or CPU)
--
-- The report lines read: name, ms per second of wall time, calls, average ms, worst ms. A section that costs more than ~2 ms per second is worth a look; one whose
-- worst value is above ~30 ms is a visible hitch.
--
-- Lua 5.0 dialect: no `#`, no `%`.

Enabled = false
do
    local has = rawget(_G, 'HasCommandLineArg')
    if has then
        local ok, on = pcall(has, '/perf')
        if ok and on then Enabled = true end
    end
end

local sections = {}      -- name -> { total, calls, max }
local started = false    -- wall clock at the start of the current report period
local frames = 0
local lastHeap = false     -- the heap size (KB) at the last report
local lastGpu = false      -- the per-op counters of ed_gpu_stats at the last report (the report shows the difference)

local function Clock()
    return GetSystemTimeSeconds()
end

local function Add(name, dt)
    local s = sections[name]
    if not s then
        s = { total = 0, calls = 0, max = 0 }
        sections[name] = s
    end
    s.total = s.total + dt
    s.calls = s.calls + 1
    if dt > s.max then s.max = dt end
end

function Begin()
    if not Enabled then return nil end
    return Clock()
end

function End(name, t0)
    if t0 then Add(name, Clock() - t0) end
end

function Time(name, fn, a, b)
    if not Enabled then return fn(a, b) end
    local t0 = Clock()
    local ok, r1, r2 = pcall(fn, a, b)
    Add(name, Clock() - t0)
    if not ok then error(r1, 0) end
    return r1, r2
end

function Set(on)
    Enabled = on and true or false
    sections, started, frames = {}, false, 0
    local line = 'perf: timing ' .. (Enabled and 'on, a report every 5 s' or 'off')
    LOG('EDITOR ' .. line)
    pcall(function()
        if not import('/lua/editor/consolelog.lua').Installed() then import('/lua/editor/gui/model.lua').Log(line) end     -- LOG above already reaches the Console panel
    end)
end

function Toggle()
    Set(not Enabled)
    return Enabled
end

function Report()
    local now = Clock()
    local span = started and (now - started) or 0
    local list = {}
    for name, s in sections do table.insert(list, { name = name, s = s }) end
    table.sort(list, function(a, b) return a.s.total > b.s.total end)
    local Model
    pcall(function() Model = import('/lua/editor/gui/model.lua') end)
    -- the Console panel records LOG itself once consolelog.lua is installed: a second copy through Model.Log would show every line twice
    local captured = false
    pcall(function() captured = import('/lua/editor/consolelog.lua').Installed() end)
    local function Out(text)
        LOG('EDITOR perf: ' .. text)
        if Model and not captured then pcall(Model.Log, text) end
    end
    local fps = (span > 0) and (frames / span) or 0
    Out(string.format('--- %.1f s, %.0f frames/s ---', span, fps))
    -- The Lua heap of this state: a heap that grows and falls back within seconds is garbage made every frame (the collector runs on the same core as the editor);
    -- one that only grows is a leak. (Once per report: not part of any frame.)
    local okHeap, heap = pcall(collectgarbage, 'count')
    if okHeap and type(heap) == 'number' then
        Out(string.format('lua heap: %.1f MB (%+.1f MB since the last report)', heap / 1024, (heap - (lastHeap or heap)) / 1024))
        lastHeap = heap
    end
    local shown = 0
    for _, e in list do
        shown = shown + 1
        if shown > 24 then break end
        local s = e.s
        local perSec = (span > 0) and (s.total * 1000 / span) or 0
        Out(string.format('%-34s %7.2f ms/s %6d calls  avg %6.3f  max %7.2f', e.name, perSec, s.calls, s.total * 1000 / math.max(1, s.calls), s.max * 1000))
    end
    -- what the engine's overlay spent in its last frame (EdOverlay.cpp ed_overlay_perf: slope view and node grids; the native draw is not part of the Lua sections)
    local native = rawget(_G, 'ed_overlay_perf')
    if native then
        local rate, draw, rated, pending, quads, level, projected, grids, gridQuads, gridProjected, groups, leaves, finest, buildMs, buildLeaves, buildSegs, buildProjected, depth, fieldMs, fieldLeaves, fieldQuads, fieldProjected, fieldPyramidMs, fieldFinest, fieldCoarsest = native()
        if rated and (quads > 0 or pending > 0 or gridQuads > 0 or (buildSegs or 0) > 0 or (fieldQuads or 0) > 0) then
            Out(string.format('native slope: rate %.2f ms (%d tiles, %d waiting), draw %.2f ms (%d quads, %d blocks of %d..%d cells, %d nodes projected)', rate, rated, pending, draw, quads, leaves or 0, math.pow(2, finest or 0), math.pow(2, level), projected))
            Out(string.format('native build grid: %.2f ms (%d blocks, %d line segments, %d nodes projected), depth test %s', buildMs or 0, buildLeaves or 0, buildSegs or 0, buildProjected or 0, (depth == 1) and 'on' or 'off'))
            Out(string.format('native grids: %.2f ms (%d quads, %d nodes projected, %d windows)', grids, gridQuads, gridProjected, groups))
            if fieldMs then
                Out(string.format('native field overlay: %.2f ms last frame (%d blocks of %d..%d cells, %d quads, %d nodes projected), last mip chain %.2f ms', fieldMs, fieldLeaves or 0, math.pow(2, fieldFinest or 0), math.pow(2, fieldCoarsest or 0), fieldQuads or 0, fieldProjected or 0, fieldPyramidMs or 0))
            end
        end
    end
    -- what the last frame asked of the renderer (EdRenderStats.cpp ed_render_stats): draw calls, the prim batcher, Maui controls, the shadow cache, the water skip; CPU ms are the
    -- render thread's submission time, not GPU time (see docs/projects/editor/PERFORMANCE.md, "GPU and render")
    local rstats = rawget(_G, 'ed_render_stats')
    if rstats then
        local ok, r = pcall(rstats)
        if ok and r and r.frames and r.frames > 1 then
            Out(string.format('render (last frame): %d draw calls, %d primitives, %d vertices; prim batcher %d flushes / %d quads (overlay %d flushes / %d quads, %.2f ms); CPU: render %.2f ms, ui %.2f, shadow %.2f',
                r.drawCalls, r.primitives, r.vertices, r.batcherFlushes, r.batcherVertices / 4, r.overlayFlushes, r.overlayVertices / 4, r.overlayMs, r.renderMs, r.uiMs, r.shadowMs))
            Out(string.format('ui controls: bitmaps %d drawn, %d off screen, %d transparent; texts %d drawn, %d off screen; borders %d drawn, %d skipped; atlas %d lookups (%d by address, %d added, %d resets)',
                r.uiBitmapsDrawn, r.uiBitmapsCulled, r.uiBitmapsTransparent, r.uiTextsDrawn, r.uiTextsCulled, r.uiBordersDrawn, r.uiBordersCulled, r.atlasLookups, r.atlasFastHits, r.atlasAdds, r.atlasResets))
            Out(string.format('shadow map: %s (scene signature %.2f ms), %d reused / %d drawn since start; water passes: %s (%d frames skipped since start)',
                (r.shadowReused == 1) and 'reused' or ((r.shadowRendered == 1) and 'drawn' or 'off'), r.shadowSceneMs, r.shadowHits, r.shadowMisses, (r.waterSkipped == 1) and 'skipped' or 'on', r.waterSkippedFrames))
        end
    end
    -- the engine's main loop (EdPerf.cpp): where the wall time of a frame goes, and the busiest threads of the process (percent of one core, so 100 = a core at its limit)
    local loop = rawget(_G, 'ed_perf_loop')
    if loop then
        local ok, st = pcall(loop)
        if ok and st and st.fps then
            Out(string.format('engine loop: %.0f fps (cap %s, %s, vsync %s), frame %.2f ms (longest %.1f): logic %.2f, paint and messages %.2f (Present %.2f, render %.2f), limiter wait %.2f, OS wait %.2f',
                st.fps, (st.cap and st.cap > 0) and string.format('%.0f', st.cap) or 'none', tostring(st.state), st.vsync and 'on' or 'off', st.frameMs, st.maxFrameMs, st.mainMs, st.dispatchMs, st.presentMs, st.renderMs, st.waitMs, st.idleMs))
        end
    end
    local threads = rawget(_G, 'ed_perf_threads')
    if threads then
        local ok, list = pcall(threads)
        if ok and list then
            local text, n = '', 0
            for _, t in list do
                n = n + 1
                if n > 6 or t.cpu < 1 then break end
                text = text .. string.format('  %s%s %.0f%%', (t.name ~= '' and t.name) or tostring(t.id), t.main and ' (main)' or '', t.cpu)
            end
            Out('threads, percent of one core:' .. (text ~= '' and text or '  all below 1%'))
        end
    end
    -- which backend ran the field ops since the last report (EdGpuLua.cpp ed_gpu_stats; docs/projects/editor/GPU_COMPUTE.md): gpu = the Direct3D 11 compute backend, cpu = the
    -- processor, "fell back" = the GPU was tried and failed, the processor did it instead (the reason: dev.gpu or the Settings panel)
    local gpuStats = rawget(_G, 'ed_gpu_stats')
    if gpuStats then
        local ok, g = pcall(gpuStats)
        if ok and type(g) == 'table' and g.ops then
            local prev = lastGpu or { ops = {} }
            local tot = { gpu = 0, gpuMs = 0, cpu = 0, cpuMs = 0, fb = 0 }
            local rows = {}
            for name, o in g.ops do
                local p = prev.ops[name] or { gpu = 0, gpuMs = 0, cpu = 0, cpuMs = 0, fallbacks = 0 }
                local d = { name = name, gpu = o.gpu - p.gpu, gpuMs = o.gpuMs - p.gpuMs, cpu = o.cpu - p.cpu, cpuMs = o.cpuMs - p.cpuMs, fb = o.fallbacks - p.fallbacks }
                tot.gpu, tot.gpuMs, tot.cpu, tot.cpuMs, tot.fb = tot.gpu + d.gpu, tot.gpuMs + d.gpuMs, tot.cpu + d.cpu, tot.cpuMs + d.cpuMs, tot.fb + d.fb
                if d.gpu > 0 or d.cpu > 0 or d.fb > 0 then table.insert(rows, d) end
            end
            lastGpu = g
            if table.getn(rows) > 0 then
                table.sort(rows, function(a, b) return (a.gpuMs + a.cpuMs) > (b.gpuMs + b.cpuMs) end)
                Out(string.format('field ops: gpu: %d ops, %.1f ms; cpu: %d ops, %.1f ms; %d fell back to the cpu (GPU compute %s)', tot.gpu, tot.gpuMs, tot.cpu, tot.cpuMs, tot.fb, g.enabled and 'on' or 'off'))
                for i = 1, math.min(5, table.getn(rows)) do
                    local d = rows[i]
                    Out(string.format('  %-14s gpu %3d ops %8.1f ms | cpu %3d ops %8.1f ms%s', d.name, d.gpu, d.gpuMs, d.cpu, d.cpuMs, (d.fb > 0) and string.format(' | %d fell back', d.fb) or ''))
                end
            end
        end
    end
    sections = {}
    started = now
    frames = 0
end

function Tick()
    if not Enabled then return end
    frames = frames + 1
    local now = Clock()
    if not started then started = now return end
    if now - started >= 5 then Report() end
end
