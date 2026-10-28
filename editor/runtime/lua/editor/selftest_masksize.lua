-- Self test of the paint mask size (ed_stratum_limits / ed_stratum_set_size, strata.lua MaskSizes / SetMaskSize). Run in the live editor on a map with paint masks:
--   return import('/lua/editor/selftest_masksize.lua').Run()
-- Paints known patches, grows and shrinks the masks and reads the paint back; puts the size back at the end.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Strata = import('/lua/editor/strata.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
end

--- The value at (fx, fz) as a fraction of the mask (0..1) and the mean of the whole mask.
local function Sample(stratum, fx, fz)
    local w, h = ed_stratum_info()
    local x, z = math.floor(fx * (w - 1) + 0.5), math.floor(fz * (h - 1) + 0.5)
    local v = ed_stratum_read(stratum, x, z, x, z)
    return v and v[1]
end

local function Mean(stratum)
    local w, h = ed_stratum_info()
    local v = ed_stratum_read(stratum, 0, 0, w - 1, h - 1)
    if not v then return nil end
    local sum = 0
    for i = 1, w * h do sum = sum + v[i] end
    return sum / (w * h)
end

local function Patch(stratum, fx0, fz0, fx1, fz1, value)
    local w, h = ed_stratum_info()
    local x0, z0, x1, z1 = math.floor(fx0 * w), math.floor(fz0 * h), math.floor(fx1 * w) - 1, math.floor(fz1 * h) - 1
    local t, n = {}, 0
    for z = z0, z1 do
        for x = x0, x1 do n = n + 1 t[n] = value end
    end
    ed_stratum_write(stratum, x0, z0, x1, z1, t)
end

function Run()
    local failures, lines = {}, {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    local function Done()
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
        return 'PASS (' .. table.getn(lines) .. ' checks)\n' .. Join(lines, '\n')
    end

    if not rawget(_G, 'ed_stratum_set_size') or not ed_stratum_info() then
        return 'skipped (no map with paint masks, or an exe without ed_stratum_set_size)'
    end
    local w0, h0 = ed_stratum_info()
    local minW, minH, maxW, maxH = Strata.MaskLimits()
    check('the limits are known: half the map up to the cap', minW and maxW and minW <= w0 and w0 <= maxW and minH <= h0 and h0 <= maxH, tostring(minW) .. ' ' .. tostring(maxW))
    local sizes = Strata.MaskSizes()
    check('the offered sizes ascend from the smallest the map allows to the biggest', sizes[1] == minW and sizes[table.getn(sizes)] == maxW and table.getn(sizes) >= 2, Join(sizes, ','))
    for i = 2, table.getn(sizes) do
        if sizes[i] <= sizes[i - 1] then check('the sizes ascend', false, Join(sizes, ',')) break end
    end

    -- known paint: a quarter of the map in two strata
    Patch(0, 0.0, 0.0, 0.5, 0.5, 200)
    Patch(0, 0.5, 0.5, 1.0, 1.0, 60)
    Patch(5, 0.25, 0.25, 0.75, 0.75, 255)
    local mean0, mean5 = Mean(0), Mean(5)
    local target = sizes[table.getn(sizes)]
    if target == w0 then target = sizes[1] end

    -- another size
    local ok, why = Strata.SetMaskSize(target)
    check('the masks get another size', ok == true, why)
    local w1, h1 = ed_stratum_info()
    check('ed_stratum_info follows the new size', w1 == target and h1 == target, tostring(w1) .. 'x' .. tostring(h1))
    check('the paint is where it was (a patch inside, ground outside)', Sample(0, 0.2, 0.2) == 200 and Sample(0, 0.8, 0.8) == 60 and Sample(0, 0.8, 0.2) == 0 and Sample(5, 0.5, 0.5) == 255 and Sample(5, 0.1, 0.1) == 0,
        tostring(Sample(0, 0.2, 0.2)) .. ' ' .. tostring(Sample(0, 0.8, 0.8)) .. ' ' .. tostring(Sample(5, 0.5, 0.5)))
    local m0, m5 = Mean(0), Mean(5)
    check('the mean paint is kept (within 1 level)', m0 and m5 and math.abs(m0 - mean0) < 1 and math.abs(m5 - mean5) < 1, tostring(m0) .. ' ' .. tostring(mean0))
    local count = ed_stratum_write(0, 0, 0, 1, 1, { 1, 2, 3, 4 })
    check('writing after the change works (the texture has the new size)', count == 4, tostring(count))
    Patch(0, 0.0, 0.0, 0.5, 0.5, 200)

    -- and back
    local ok2, why2 = Strata.SetMaskSize(w0)
    check('and back to the first size', ok2 == true, why2)
    local w2 = ed_stratum_info()
    check('the size is the first again', w2 == w0, tostring(w2))
    check('the paint survived the round trip', Sample(0, 0.2, 0.2) == 200 and Sample(5, 0.5, 0.5) == 255 and Sample(0, 0.8, 0.2) == 0)
    local r0 = Mean(0)
    check('the mean is kept after the round trip (within 1 level)', r0 and math.abs(r0 - mean0) < 1, tostring(r0) .. ' ' .. tostring(mean0))

    -- limits
    local okSmall, whySmall = Strata.SetMaskSize(minW - 1)
    check('a size below half the map is refused', okSmall == nil and whySmall ~= nil and ed_stratum_info() == w0, tostring(whySmall))
    local okBig, whyBig = Strata.SetMaskSize(maxW + 1)
    check('a size above the cap is refused', okBig == nil and whyBig ~= nil and ed_stratum_info() == w0, tostring(whyBig))
    check('the same size is a plain yes', Strata.SetMaskSize(w0) == true)

    -- clean up the patches
    for i = 1, 8 do Strata.ClearMask(i) end
    return Done()
end
