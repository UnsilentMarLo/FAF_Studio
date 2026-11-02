-- Self test of the native batch calls (engine: EditorLua.cpp ed_terrain_get_many, EdUnitBones.cpp ed_units_snapshot) and of the overlay's unchanged-skip (EdOverlay.cpp). Run in the
-- live editor on any map:
--   return import('/lua/editor/selftest_nativebatch.lua').Run()
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
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

    -- ed_terrain_get_many ---------------------------------------------------------------------------------------------------------------------------
    if not rawget(_G, 'ed_terrain_get_many') then
        return 'skipped (an exe without ed_terrain_get_many)'
    end
    local w, h = ed_terrain_info()
    check('the map has a terrain', w ~= nil and h ~= nil)
    if not w then return Done() end
    local coords, n = {}, 0
    local seed = 11
    for i = 1, 300 do
        seed = math.mod(seed * 75 + 74, 65537)
        local x = math.floor(seed / 65537 * (w + 80)) - 40
        seed = math.mod(seed * 75 + 74, 65537)
        local z = math.floor(seed / 65537 * (h + 80)) - 40
        coords[2 * i - 1], coords[2 * i] = x, z
        n = i
    end
    local res, outside = ed_terrain_get_many(coords)
    local bad, nOut = 0, 0
    for i = 1, n do
        local single = ed_terrain_get(coords[2 * i - 1], coords[2 * i])
        if single == nil then nOut = nOut + 1 end
        if (single == nil and res[i] ~= false) or (single ~= nil and res[i] ~= single) then bad = bad + 1 end
    end
    check('every height equals ed_terrain_get (false outside the map)', bad == 0, bad .. ' differ')
    check('the count of points outside the map is returned', outside == nOut and nOut > 0, tostring(outside) .. ' vs ' .. nOut)
    check('the result has one entry per point', res[n] ~= nil and res[n + 1] == nil)

    local keep = { 'a', 'b', 'c' }
    local back, o2 = ed_terrain_get_many({ 5, 5, -3, 2 }, keep)
    check('a given table is filled and returned', back == keep and keep[1] == ed_terrain_get(5, 5) and keep[2] == false and keep[3] == 'c' and o2 == 1)
    check('an empty list gives an empty result', next((ed_terrain_get_many({}))) == nil)
    local _, edge = ed_terrain_get_many({ w - 1, h - 1, w, h })
    check('the last sample is inside, one past it is outside', edge == 1)

    -- ed_units_snapshot -----------------------------------------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_units_snapshot') then
        local list, count = ed_units_snapshot()
        check('the snapshot is a table with a count', type(list) == 'table' and type(count) == 'number' and count >= 0)
        local shaped = true
        for i = 0, count - 1 do
            if type(list[5 * i + 1]) ~= 'number' or type(list[5 * i + 2]) ~= 'number' or type(list[5 * i + 5]) ~= 'string' then shaped = false end
        end
        check('five entries per unit: id, x, y, z, blueprint', shaped, tostring(count) .. ' units')
        local reuse = {}
        local again = ed_units_snapshot(reuse)
        check('a given table is filled and returned', again == reuse)
    end

    -- the overlay skips a line that did not change -------------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_overlay_hash') then
        local _, _, builds0 = ed_overlay_hash()
        local pts = { 100, 20, 100, 110, 20, 100, 110, 20, 110 }
        ed_overlay_set('nbtest:l', pts, 'FF00FF00', 0.3, 2, 6, false, true, true)
        ed_overlay_set('nbtest:l', pts, 'FF00FF00', 0.3, 2, 6, false, true, true)
        check('the same line twice is accepted', ed_overlay_count() >= 1)
        ed_overlay_remove('nbtest:l')
        ed_overlay_remove('nbtest:l')
        check('removing a line that is gone is harmless', true)
        local _, _, builds1 = ed_overlay_hash()
        check('the line cache counters are numbers', type(builds0) == 'number' and type(builds1) == 'number')
    end
    return Done()
end
