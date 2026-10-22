-- Self test of the symmetry detection (symmetry.lua Detect) on synthetic maps: start positions, resource markers and heights that are symmetric under each mode, an offset axis,
-- maps that are not symmetric, flat maps. Needs no map: run in the live editor or any Lua state with the module system:
--   return import('/lua/editor/selftest_symdetect.lua').Run()
-- Returns a report; the first line is PASS or FAIL (Run(true) lists every check).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Sym = import('/lua/editor/symmetry.lua')

local SIZE = 257          -- samples (a 5 km map): the last sample is 256, the middle 128

-- a bump-and-ridge landscape that is not symmetric by itself
local BUMPS = {}
do
    local seed = 12345
    local function Rand()
        seed = math.mod(seed * 1103 + 12345, 32749)
        return seed / 32749
    end
    for i = 1, 14 do
        table.insert(BUMPS, { x = Rand() * 256, z = Rand() * 256, a = 6 + Rand() * 20, s = 10 + Rand() * 22 })
    end
end

local function Base(x, z)
    local h = 20
    for _, b in BUMPS do
        local dx, dz = x - b.x, z - b.z
        h = h + b.a * math.exp(-(dx * dx + dz * dz) / (2 * b.s * b.s))
    end
    return h
end

--- The landscape made symmetric under `mode` about (cx, cz): the sum of the base landscape over the images of the point.
local function Symmetric(mode, cx, cz)
    return function(x, z)
        local h = 0
        for _, q in Sym.PointsFor(mode, cx, cz, x, z) do
            h = h + Base(q.x, q.z)
        end
        return h
    end
end

local function Flat() return 25 end

local function Images(mode, cx, cz, list)
    local out = {}
    for _, p in list do
        for _, q in Sym.PointsFor(mode, cx, cz, p[1], p[2]) do
            table.insert(out, { q.x, q.z, p[3] })
        end
    end
    return out
end

local function Split(items)
    local starts, marks = {}, {}
    for _, it in items do
        if it[3] == 'start' then table.insert(starts, { it[1], it[2] }) else table.insert(marks, { it[1], it[2], it[3] }) end
    end
    return starts, marks
end

function Run(verbose)
    local failures, lines = {}, {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    local function Detect(starts, marks, height)
        return Sym.Detect({ w = SIZE, h = SIZE, starts = starts, marks = marks, height = height })
    end

    local seeds = {
        mirror_x = { { 40, 100, 'start' }, { 60, 40, 'Mass' }, { 90, 190, 'Mass' }, { 30, 160, 'Mass' }, { 100, 120, 'Hydrocarbon' }, { 70, 220, 'Mass' } },
        mirror_z = { { 100, 40, 'start' }, { 40, 60, 'Mass' }, { 190, 90, 'Mass' }, { 160, 30, 'Mass' }, { 120, 100, 'Hydrocarbon' }, { 220, 70, 'Mass' } },
        mirror_xz = { { 40, 40, 'start' }, { 60, 90, 'Mass' }, { 90, 30, 'Mass' }, { 110, 110, 'Hydrocarbon' }, { 20, 100, 'Mass' } },
        rot2 = { { 50, 60, 'start' }, { 60, 40, 'Mass' }, { 90, 190, 'Mass' }, { 30, 160, 'Mass' }, { 100, 120, 'Hydrocarbon' } },
        rot4 = { { 40, 70, 'start' }, { 60, 40, 'Mass' }, { 90, 100, 'Mass' }, { 30, 120, 'Hydrocarbon' } },
        diag = { { 40, 120, 'start' }, { 60, 40, 'Mass' }, { 90, 190, 'Mass' }, { 30, 160, 'Mass' }, { 100, 20, 'Hydrocarbon' } },
        diag_both = { { 40, 90, 'start' }, { 60, 40, 'Mass' }, { 100, 70, 'Mass' }, { 30, 120, 'Hydrocarbon' } },
    }
    local c = 128

    -- ---- every mode is found, with markers and heights ---------------------------------------------------------------------------------------------------
    for mode, seed in seeds do
        local items = Images(mode, c, c, seed)
        local starts, marks = Split(items)
        local best, cands = Detect(starts, marks, Symmetric(mode, c, c))
        check(mode .. ': found from markers and heights', best ~= nil and best.mode == mode, best and best.mode or ('nothing; ' .. table.getn(cands) .. ' candidates'))
        check(mode .. ': centre in the middle', best ~= nil and math.abs(best.cx - c) < 0.5 and math.abs(best.cz - c) < 0.5)
        -- flat ground: the markers alone decide
        local bestFlat = Detect(starts, marks, Flat)
        check(mode .. ': found from markers on flat ground', bestFlat ~= nil and bestFlat.mode == mode, bestFlat and bestFlat.mode or 'nothing')
    end

    -- ---- heights alone (no start positions) -----------------------------------------------------------------------------------------------------------------
    for _, mode in { 'mirror_x', 'rot2', 'diag', 'mirror_xz' } do
        local best = Detect({}, {}, Symmetric(mode, c, c))
        check(mode .. ': found from the heights alone', best ~= nil and best.mode == mode, best and best.mode or 'nothing')
    end

    -- ---- an axis a little off the middle ----------------------------------------------------------------------------------------------------------------------
    do
        local shifted = 129.4
        local items = Images('mirror_x', shifted, c, seeds.mirror_x)
        local starts, marks = Split(items)
        local best = Detect(starts, marks, Symmetric('mirror_x', shifted, c))
        check('an axis 1.4 units off the middle is found', best ~= nil and best.mode == 'mirror_x', best and best.mode or 'nothing')
        check('... and its centre is measured', best ~= nil and math.abs(best.cx - shifted) < 0.6, best and best.cx)
    end

    -- ---- near misses: the markers are a little off ---------------------------------------------------------------------------------------------------------
    do
        local items = Images('rot2', c, c, seeds.rot2)
        for i, it in items do
            it[1] = it[1] + math.mod(i * 7, 5) * 0.2 - 0.4          -- up to 0.4 units of noise
            it[2] = it[2] + math.mod(i * 3, 5) * 0.2 - 0.4
        end
        local starts, marks = Split(items)
        local best = Detect(starts, marks, Symmetric('rot2', c, c))
        check('markers that are 0.4 units off still fit', best ~= nil and best.mode == 'rot2', best and best.mode or 'nothing')
    end

    -- ---- what must not be detected ---------------------------------------------------------------------------------------------------------------------------
    do
        local starts = { { 30, 40 }, { 200, 90 }, { 90, 220 } }
        local marks = { { 50, 60, 'Mass' }, { 120, 200, 'Mass' }, { 210, 30, 'Mass' }, { 170, 170, 'Hydrocarbon' } }
        check('random markers on a random landscape: nothing', Detect(starts, marks, Base) == nil)
        check('random markers on flat ground: nothing', Detect(starts, marks, Flat) == nil)
        check('no markers on a random landscape: nothing', Detect({}, {}, Base) == nil)
        check('no markers on flat ground: nothing', Detect({}, {}, Flat) == nil)
        check('one start position on flat ground: nothing', Detect({ { 60, 60 } }, {}, Flat) == nil)
        check('symmetric resource markers without starts on flat ground: nothing', Detect({}, { { 50, 60, 'Mass' }, { 206, 60, 'Mass' }, { 50, 200, 'Mass' }, { 206, 200, 'Mass' } }, Flat) == nil)
        -- symmetric start positions on a landscape that is not symmetric: the heights speak against it
        local s2, m2 = Split(Images('mirror_x', c, c, seeds.mirror_x))
        check('symmetric markers on a landscape that is not: nothing', Detect(s2, m2, Base) == nil)
        -- a start position without a partner
        local s3, m3 = Split(Images('mirror_x', c, c, seeds.mirror_x))
        table.insert(s3, { 128, 30 })
        table.insert(s3, { 60, 250 })
        check('a start position without a partner rules the mode out', Detect(s3, m3, Symmetric('mirror_x', c, c)) == nil)
    end

    -- ---- the larger group wins when the evidence is the same -------------------------------------------------------------------------------------------------
    do
        local starts = { { 40, 128 }, { 216, 128 } }         -- on the axis z = 128: also symmetric top / bottom
        local best = Detect(starts, {}, Symmetric('mirror_xz', c, c))
        check('two starts on the axis, heights symmetric both ways: mirror both', best ~= nil and best.mode == 'mirror_xz', best and best.mode or 'nothing')
        local flatBest = Detect(starts, {}, Flat)
        check('two starts on the axis, flat ground: the smaller group', flatBest ~= nil and flatBest.mode ~= 'mirror_xz' and flatBest.mode ~= 'rot4' and flatBest.mode ~= 'diag_both', flatBest and flatBest.mode or 'nothing')
    end

    -- ---- many markers stay cheap ------------------------------------------------------------------------------------------------------------------------------
    do
        local seed = {}
        for i = 1, 40 do table.insert(seed, { 10 + math.mod(i * 37, 100), 10 + math.mod(i * 53, 230), 'Mass' }) end
        table.insert(seed, { 40, 100, 'start' })
        local starts, marks = Split(Images('mirror_x', c, c, seed))
        local reads = 0
        local best = Sym.Detect({ w = SIZE, h = SIZE, starts = starts, marks = marks, height = function(x, z) reads = reads + 1 return Symmetric('mirror_x', c, c)(x, z) end })
        check('a map with 80 resource markers is found', best ~= nil and best.mode == 'mirror_x', best and best.mode or 'nothing')
        check('at most a few thousand height reads', reads <= 3500, tostring(reads))
    end

    -- ---- a non-square map: no rotation by 90 degrees, the centre is the middle of the real map -----------------------------------------------------------
    do
        local best = Sym.Detect({ w = 257, h = 129, starts = { { 40, 40 }, { 216, 88 } }, marks = {}, height = Flat })
        check('a non-square map: a half turn about its own middle', best ~= nil and best.mode == 'rot2' and math.abs(best.cz - 64) < 0.5 and math.abs(best.cx - 128) < 0.5, best and (best.mode .. ' ' .. best.cx .. ' ' .. best.cz) or 'nothing')
        local quarter = Sym.Detect({ w = 257, h = 129, starts = { { 40, 40 }, { 216, 88 }, { 88, 216 }, { 40, 88 } }, marks = {}, height = Flat })
        check('a non-square map is never a quarter turn or a diagonal', quarter == nil or (quarter.mode ~= 'rot4' and quarter.mode ~= 'diag' and quarter.mode ~= 'diag_both'), quarter and quarter.mode)
    end

    local shown = lines
    if not verbose then
        shown = {}
        for _, l in lines do
            if string.sub(l, 1, 6) ~= '  ok  ' then table.insert(shown, l) end
        end
        table.insert(shown, '  ' .. (table.getn(lines) - table.getn(shown)) .. ' checks ok')
    end
    if table.getn(failures) > 0 then
        return 'FAIL (' .. table.getn(failures) .. ': ' .. table.concat(failures, ', ') .. ')\n' .. table.concat(shown, '\n')
    end
    return 'PASS\n' .. table.concat(shown, '\n')
end
