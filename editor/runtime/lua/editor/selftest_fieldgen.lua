-- Self test of the Generate section of the Fields panel (fieldgen.lua): relief of exact size, blend modes, strength, mask, protected spots, water level, the difference statistics, and the
-- whole workflow on the open map (non-destructive, one undo step). Run in the live editor:
--   return import('/lua/editor/selftest_fieldgen.lua').Run()
-- Returns a report; the first line is PASS or FAIL. The native ops (fractal, amplitude, terrain_mix, keep_side) have their own stand-alone test, tests/EdLandTest.cpp (scripts/ed_native_tests.py).
-- Pure() runs the part that needs no open map (fake fields only).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Gen = import('/lua/editor/fieldgen.lua')

local function Reporter()
    local R = { lines = {}, failures = {} }
    function R.check(name, ok, detail)
        if ok then
            table.insert(R.lines, '  ok   ' .. name)
        else
            table.insert(R.failures, name)
            table.insert(R.lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    function R.head()
        local head = 'PASS'
        if table.getn(R.failures) > 0 then head = 'FAIL (' .. table.getn(R.failures) .. ')' end
        return head .. '\n' .. table.concat(R.lines, '\n')
    end
    return R
end

local function Copy(t)
    local c = {}
    for k, v in t do c[k] = v end
    return c
end

--- A gently sloping terrain 65 x 65 (heights 20 .. 60 across) and a settings table for tests.
local function Ground(S)
    local ramp = S:Op('gradient', { width = 65, height = 65, angle = 0, lo = 0, hi = 1 })
    return S:Op('affine', { a = ramp, mul = 40, add = 20 })
end

local function Read(f, x, z) return Fields.Get(f, x, z) end

local function MaxDiff(a, b)
    local d = Fields.Run(function(S)
        local _, mx = Fields.Stats(S:Op('abs', { a = S:Op('sub', { a = a, b = b }) }))
        return mx
    end)
    return d
end

function Pure()
    local R = Reporter()
    local check = R.check
    check('field natives present', Fields.IsAvailable())
    if not Fields.IsAvailable() then return R.head() end
    local haveNew = false
    for _, n in Fields.OpNames() do
        if n == 'fractal' then haveNew = true end
    end
    check('the Generate ops are in the engine (fractal, amplitude, terrain_mix, keep_side)', haveNew)
    if not haveNew then return R.head() end

    -- the repeatability checks run on the CPU: the GPU droplet solver adds to shared integer buffers while other droplets read them, so its result varies from run to run (by design,
    -- docs/projects/editor/GPU_COMPUTE.md); the CPU solvers are bit identical for any thread count
    local gpuWas = rawget(_G, 'ed_gpu_info') and ed_gpu_info(false).enabled
    if rawget(_G, 'ed_gpu_enable') then ed_gpu_enable(false) end
    -- presets: every relief has exactly the asked size, no offset, is repeatable and depends on the seed
    for _, def in Gen.Presets do
        local p = Copy(Gen.Settings)
        p.preset = def.id
        p.scale, p.amplitude, p.gullies, p.warp, p.detail = def.scale, def.amplitude, def.gullies, def.warp, def.detail
        p.seed = 3
        Fields.Run(function(S)
            local like = S:New(97, 97, 0)
            local g = Gen.Relief(S, like, p)
            local mn, mx, mean = Fields.Stats(g)
            local top = math.max(math.abs(mn), math.abs(mx))
            check(def.id .. ': the largest change is the amplitude', math.abs(top - p.amplitude) < 0.01 * math.max(1, p.amplitude), top .. ' vs ' .. p.amplitude)
            check(def.id .. ': zero mean (does not lift or sink the map)', math.abs(mean) < 0.01 * math.max(1, p.amplitude), mean)
            local again = Gen.Relief(S, like, p)
            check(def.id .. ': repeatable', Fields.Checksum(g) == Fields.Checksum(again))
            local q = Copy(p)
            q.seed = 4
            check(def.id .. ': the seed changes it', Fields.Checksum(g) ~= Fields.Checksum(Gen.Relief(S, like, q)))
        end)
    end
    -- the thread count changes nothing (erosion included)
    if rawget(_G, 'ed_field_threads') then
        local threads0 = ed_field_threads()
        local sums = {}
        for _, t in { 1, 3, 7 } do
            ed_field_threads(t)
            local p = Copy(Gen.Settings)
            p.preset, p.gullies, p.seed = 'mountains', 0.6, 5
            Fields.Run(function(S)
                local like = S:New(129, 129, 0)
                table.insert(sums, Fields.Checksum(Gen.Relief(S, like, p)))
            end)
        end
        ed_field_threads(threads0)
        check('the relief is the same with 1, 3 and 7 threads', sums[1] == sums[2] and sums[2] == sums[3], table.concat(sums, ' '))
    end
    if rawget(_G, 'ed_gpu_enable') and gpuWas then ed_gpu_enable(true) end
    -- choosing a preset takes its numbers
    Gen.Choose('mountains')
    check('Choose takes the preset values', Gen.Settings.preset == 'mountains' and Gen.Settings.amplitude == 60 and Gen.Settings.scale == 240)
    Gen.Choose('hills')

    -- mixing
    Fields.Run(function(S)
        local H = Ground(S)
        local G = S:Op('affine', { a = S:Op('perlin', { like = H, seed = 2, scale = 20, octaves = 3 }), mul = 20, add = -10 })      -- about +-5
        local function Mix(o) local t = Gen.Combine(S, H, G, o) return t end
        check('strength 0 leaves the terrain bit for bit', Fields.Checksum(Mix({ mode = 'add', strength = 0 })) == Fields.Checksum(H))
        local added = Mix({ mode = 'add', strength = 1 })
        check('add: terrain + relief', MaxDiff(added, S:Op('add', { a = H, b = G })) < 1e-3)
        local half = Mix({ mode = 'add', strength = 0.5 })
        check('strength 0.5 is half the relief', MaxDiff(half, S:Op('add', { a = H, b = S:Op('affine', { a = G, mul = 0.5, add = 0 }) })) < 1e-3)
        local mx, mn = Mix({ mode = 'max', strength = 1 }), Mix({ mode = 'min', strength = 1 })
        check('raise only never lowers', Fields.Stats(S:Op('sub', { a = mx, b = H })) >= -1e-4)
        local _, hiMin = Fields.Stats(S:Op('sub', { a = mn, b = H }))
        check('lower only never raises', hiMin <= 1e-4)
        local _, _, mean0 = Fields.Stats(H)
        local rep = Mix({ mode = 'replace', strength = 1 })
        local _, _, repMean = Fields.Stats(rep)
        local _, _, relMean = Fields.Stats(G)
        check('replace: the average height of the map plus the mean of the relief', math.abs(repMean - (mean0 + relMean)) < 0.05, repMean .. ' vs ' .. (mean0 + relMean))
        local mul = Mix({ mode = 'multiply', strength = 1 })
        check('multiply leaves the lowest ground alone', math.abs(Read(mul, 0, 32) - Read(H, 0, 32)) < 1e-3)

        -- a mask: nothing changes where it is 0
        local mask = S:Op('rect_mask', { like = H, x0 = 32, z0 = 0, x1 = 64, z1 = 64, feather = 8 })
        local masked = Mix({ mode = 'add', strength = 1, mask = mask })
        check('outside the mask nothing changes', Read(masked, 5, 20) == Read(H, 5, 20) and Read(masked, 31, 40) == Read(H, 31, 40))
        check('inside the mask the relief is applied', math.abs(Read(masked, 56, 30) - Read(added, 56, 30)) < 1e-3)
        local edge = Read(masked, 36, 30) - Read(H, 36, 30)
        local full = Read(added, 36, 30) - Read(H, 36, 30)
        check('the mask border is soft', math.abs(edge) <= math.abs(full) + 1e-4)

        -- protected spots: nothing changes inside the radius, the change grows with the distance
        local near = Mix({ mode = 'add', strength = 1, pts = { 32, 32, 8, 1 }, feather = 10 })
        check('protected spot: untouched inside its radius', Read(near, 32, 32) == Read(H, 32, 32) and Read(near, 36, 34) == Read(H, 36, 34))
        check('protected spot: the far ground changes', math.abs(Read(near, 5, 5) - Read(added, 5, 5)) < 1e-3)
        local last, rising = 0, true
        for x = 40, 52 do
            local d = math.abs(Read(near, x, 32) - Read(H, x, 32))
            local want = math.abs(Read(added, x, 32) - Read(H, x, 32))
            if d > want + 1e-3 then rising = false end
            last = d
        end
        check('protected spot: the change never exceeds the full relief', rising, last)
        local ring = math.abs(Read(near, 44, 32) - Read(H, 44, 32))
        check('protected spot: smooth falloff (partly changed on the skirt)', ring < math.abs(Read(added, 44, 32) - Read(H, 44, 32)) + 1e-4)
    end)

    -- water: land stays dry, the sea floor stays under water
    Fields.Run(function(S)
        local H = Ground(S)                                     -- 20 .. 60 across; the water at 40
        local lower = S:New(65, 65, -30)                        -- a relief that digs 30 units everywhere
        local t = Gen.Combine(S, H, lower, { mode = 'add', strength = 1, water = 40, margin = 0.25 })
        local dryOk, wetOk = true, true
        for x = 0, 64, 4 do
            local before, after = Read(H, x, 20), Read(t, x, 20)
            if before >= 40 and after < 40 then dryOk = false end
            if before < 40 and after > 40 then wetOk = false end
        end
        check('keep water: land is not dug under the water', dryOk)
        check('keep water: the sea floor stays under the water', wetOk)
        local up = Gen.Combine(S, H, S:New(65, 65, 30), { mode = 'add', strength = 1, water = 40, margin = 0.25 })
        local seaOk = true
        for x = 0, 64, 4 do
            if Read(H, x, 20) < 40 and Read(up, x, 20) > 40 then seaOk = false end
        end
        check('keep water: the sea floor is not pushed above the water', seaOk)
        local free = Gen.Combine(S, H, lower, { mode = 'add', strength = 1 })
        check('without keep water the same relief digs under the water', Read(free, 40, 20) < 40)
    end)

    -- the difference statistics
    Fields.Run(function(S)
        local H = Ground(S)
        local T = S:Op('add', { a = H, b = S:Op('const', { like = H, value = 0 }) })
        local d0 = Gen.Difference(S, T, H)
        check('difference of equal terrains is 0', d0.max == 0 and d0.share == 0)
        local bump = S:Op('radial', { like = H, radius = 20, cx = 32, cz = 32 })
        local T2 = S:Op('add', { a = H, b = S:Op('affine', { a = S:Op('invert', { a = bump }), mul = 10, add = 0 }) })
        local d = Gen.Difference(S, T2, H)
        check('difference: the maximum is the largest change', d.max > 5 and d.max <= 10.001, d.max)
        check('difference: the share is a fraction of the map', d.share > 0 and d.share < 1, d.share)
        check('difference text', string.find(Gen.Describe(d), 'up to') ~= nil, Gen.Describe(d))
    end)
    return R.head()
end

function Run()
    local pure = Pure()
    local R = Reporter()
    local check = R.check
    local w, h = ed_terrain_info()
    if not w or not rawget(_G, 'ed_terrain_set_rect') then
        return pure .. '\n  skip the tests on the open map (no map)'
    end
    local History = import('/lua/editor/history.lua')
    local Terrain = import('/lua/editor/terrain.lua')
    local startCount = ed_field_count and ed_field_count() or 0

    -- the whole workflow on the map: the generated relief is mixed into the heights, one undo step, the average height does not move
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 40)
    Terrain.ClearHistory()
    local before = Fields.Run(function(S) return Fields.Checksum(S:Height()) end)
    local p = Copy(Gen.Settings)
    p.preset, p.amplitude, p.strength, p.gullies, p.mask, p.keepWater, p.keepFlat = 'hills', 12, 1, 0, 1, false, false      -- (the test map's markers would protect part of it)
    local result, why = Gen.Build(p)
    check('Build makes a result', result ~= nil, why)
    if result then
        check('the preview does not touch the map', Fields.Run(function(S) return Fields.Checksum(S:Height()) end) == before)
        check('the largest change is the amplitude', math.abs(result.stats.max - 12) < 0.1, result.stats.max)
        check('the statistics line is made', string.find(result.text, 'Changes heights by up to') ~= nil, result.text)
        local mean = 0
        Fields.Run(function(S)
            local _, _, m = Fields.Stats(S:Height())
            mean = m
        end)
        local _, _, newMean = Fields.Stats(result.terrain)
        check('the average height stays (zero-mean relief)', math.abs(newMean - mean) < 0.2, newMean .. ' vs ' .. mean)
        local depth, version = Terrain.UndoDepth(), History.Version
        local n = Gen.Commit(result)
        check('commit changes the map', n and n > 1000, tostring(n))
        check('commit is one document step', Terrain.UndoDepth() == depth + 1, tostring(Terrain.UndoDepth()) .. ' vs ' .. depth)
        check('commit is one history entry', History.Version == version + 1, tostring(History.Version) .. ' vs ' .. version)
        local lo, hi = Fields.Run(function(S) local a, b = Fields.Stats(S:Height()) return a, b end)
        check('the map stays within the relief (it was flat 40, the relief 12)', lo >= 27.9 and hi <= 52.1, lo .. ' .. ' .. hi)
        check('undo', History.Undo() ~= false)
        check('undo restores the map exactly', Fields.Run(function(S) return Fields.Checksum(S:Height()) end) == before)
        Gen.Free(result)
    end

    -- strength 0 changes nothing; a half-map mask leaves the other half alone
    local p0 = Copy(p)
    p0.strength = 0
    local r0 = Gen.Build(p0)
    check('strength 0: no change', r0 and r0.stats.max == 0, r0 and r0.stats.max)
    if r0 then
        check('strength 0: nothing to commit', (Gen.Commit(r0) or 0) == 0)
        Gen.Free(r0)
    end
    check('every undo entry was used', Fields.Run(function(S) return Fields.Checksum(S:Height()) end) == before)

    local startFields = ed_field_count and ed_field_count() or 0
    if ed_field_count then check('no field leaks', startFields == startCount, tostring(startCount) .. ' -> ' .. tostring(startFields)) end
    local rest = string.gsub(pure, '^[^\n]*\n?', '')
    local count = table.getn(R.failures)
    for _ in string.gfind(pure, '\n  FAIL ') do count = count + 1 end
    local head = 'PASS'
    if count > 0 then head = 'FAIL (' .. count .. ')' end
    return head .. '\n' .. rest .. '\n' .. table.concat(R.lines, '\n')
end
