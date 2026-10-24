-- GPU against CPU on the real graphics card, op by op (not named selftest_*: it needs a GPU and is not part of the standard run). Run() -> report text, Details() the table.
--
--   import('/lua/editor/gpu_ab.lua').Run([size])      every op of ed_gpu_info().ops runs once on the CPU (GPU switched off) and once on the GPU (gates off) on the same
--                                                             input; the report gives, per op, whether it ran on the GPU, the largest and the mean difference and the
--                                                             difference in units of the output's standard deviation, plus the two times
--
-- Inputs: a fractal terrain `h` (0..~100 units), a second one `h2`, a 0..1 mask `m`. The first parameter set that makes the CPU op succeed is used (ops have defaults). Ops that need other
-- inputs show as "no inputs". Erosion solvers differ by design (a different algorithm on the GPU): their difference is information, not a failure.
--
-- Lua 5.0 dialect.

local SIZE = 512
local SKIP = { flow = 1024, wetness = 1024 }      -- (their GPU versions need seconds on big fields: test them with Run(1024) by hand)

local SETS = {
    function(h, h2, m) return { a = h } end,
    function(h, h2, m) return { a = h, b = h2 } end,
    function(h, h2, m) return { a = h, mask = m } end,
    function(h, h2, m) return { a = h, b = m } end,
    function(h, h2, m) return { width = SIZE, height = SIZE, seed = 7 } end,
    function(h, h2, m) return { a = h, dx = h2, dz = h2 } end,
}

-- parameters worth giving some ops so that they do real work
local EXTRA = {
    blur = { sigma = 3 }, box = { radius = 4 }, bilateral = { radius = 4, sigma_r = 3 }, blur_dir = { length = 12, angle = 30 },
    dwarp = { amount = 12, scale = 60 }, erode_hydraulic = { iterations = 40 }, erode_droplet = { rounds = 8 }, thermal = { iterations = 20 },
    settle = { iterations = 10 }, morph = { op = 'dilate', radius = 3 }, convolve = { kernel = 'sharpen' }, wetness = {}, flow = {},
}

local function Merge(base, extra)
    for k, v in extra or {} do base[k] = v end
    return base
end

local function Read(f)
    local w, h = ed_field_info(f)
    local out = {}
    local rows = 64
    local z = 0
    while z < h do
        local z1 = math.min(h - 1, z + math.floor(65536 / w) - 1)
        for _, v in ed_field_read(f, 0, z, w - 1, z1) do table.insert(out, v) end
        z = z1 + 1
    end
    return out, w, h
end

local function Diff(fa, fb)
    local a, w, h = Read(fa)
    local b = Read(fb)
    local n = table.getn(a)
    if n ~= table.getn(b) then return nil, nil, 'size differs' end
    local maxd, sum, bad = 0, 0, 0
    for i = 1, n do
        local d = math.abs(a[i] - b[i])
        if d ~= d then bad = bad + 1 d = 0 end
        if d > maxd then maxd = d end
        sum = sum + d
    end
    return maxd, sum / n, bad
end

local function RunOne(name, sets, inputs, extra)
    for _, make in sets do
        local params = Merge(make(inputs.h, inputs.h2, inputs.m), extra)
        local f, err = ed_field_op(name, params)
        if f then return f, params end
    end
    return nil
end

function Details(size)
    SIZE = size or SIZE
    local info = ed_gpu_info(true)
    local names = {}
    for _, n in info.ops do table.insert(names, n) end
    table.sort(names)
    ConExecute('ed_gpu_min_cells 0')
    ed_gpu_enable(true, true)
    local h = ed_field_op('fractal', { width = SIZE, height = SIZE, seed = 3, amplitude = 90 })
    local h2 = ed_field_op('fractal', { width = SIZE, height = SIZE, seed = 11, amplitude = 60 })
    local m = ed_field_op('perlin', { width = SIZE, height = SIZE, seed = 5 })
    local inputs = { h = h, h2 = h2, m = m }
    local rows = {}
    for _, name in names do
        local row = { name = name }
        if (SKIP[name] and SIZE > (SKIP[name])) then
            row.status = 'skipped at this size'
            table.insert(rows, row)
            name = false
        end
        if name then
        local extra = EXTRA[name]
        ed_gpu_enable(false)
        local t0 = ed_field_clock()
        local fc, params = RunOne(name, SETS, inputs, extra)
        row.cpuMs = (ed_field_clock() - t0) * 1000
        if not fc then
            row.status = 'no inputs'
        else
            ed_gpu_enable(true)
            -- first call: creates the kernels (compiling takes the time); the second one is the speed a user sees
            local warm = ed_field_op(name, params)
            if warm then ed_field_free(warm) end
            ed_gpu_stats(true)
            local t1 = ed_field_clock()
            local fg, err = ed_field_op(name, params)
            row.gpuMs = (ed_field_clock() - t1) * 1000
            local st = ed_gpu_stats(false)
            local s = st and st.ops and st.ops[name]
            row.ranGpu = s and s.gpu and s.gpu > 0
            row.fallbacks = s and s.fallbacks or 0
            row.opError = ed_gpu_info(false).lastOpError
            if not fg then
                row.status = 'GPU call failed: ' .. tostring(err)
            else
                local maxd, meand, bad = Diff(fc, fg)
                row.maxd, row.meand, row.bad = maxd, meand, bad
                local _, _, _, sd = ed_field_stats(fc)
                row.sd = sd
                row.status = row.ranGpu and 'ran on GPU' or 'CPU (fell back or gated)'
                ed_field_free(fg)
            end
            ed_field_free(fc)
        end
        table.insert(rows, row)
        end
    end
    ed_gpu_enable(true)
    return rows
end

function Run(size)
    local rows = Details(size)
    local lines = {}
    for _, r in rows do
        local diff = ''
        if r.maxd then
            local rel = (r.sd and r.sd > 0) and (r.meand / r.sd) or 0
            diff = string.format('max %.4g mean %.3g (%.3g sd)%s', r.maxd, r.meand, rel, (r.bad and r.bad > 0) and (' NaN ' .. r.bad) or '')
        end
        table.insert(lines, string.format('%-18s %-24s cpu %7.1f ms  gpu %7.1f ms  %s%s', r.name, r.status, r.cpuMs or 0, r.gpuMs or 0, diff,
            (r.opError and r.opError ~= '') and ('  err: ' .. string.sub(r.opError, 1, 90)) or ''))
    end
    return table.concat(lines, '\n')
end
