-- Terrain self test: run in the live editor through the /edcmd channel:
--   return import('/lua/editor/selftest_terrain.lua').Run()
-- Returns a report string; the first line is PASS or FAIL.

function Run()
    local T = import('/lua/editor/terrain.lua')
    local failures = {}
    local lines = {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end

    local w, h = ed_terrain_info()
    check('terrain present', w ~= nil and w >= 65 and h >= 65, tostring(w) .. 'x' .. tostring(h))
    if not w then
        return 'FAIL\n' .. table.concat(lines, '\n')
    end

    -- known flat start
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    T.ClearHistory()
    local base, n = T.Checksum(10, 10, 60, 60)
    check('flat checksum', base == 25 * 128 * n, tostring(base) .. ' / ' .. tostring(n))

    -- raise stroke
    T.Brush.mode = 'raise'
    T.Brush.radius = 10
    T.Brush.strength = 6
    local changed = T.Line(20, 30, 50, 30)
    local raised = T.Checksum(10, 10, 60, 60)
    check('raise changes samples', changed > 0 and raised > base, tostring(changed))
    check('peak above plain', ed_terrain_get(35, 30) > 25 + 5, tostring(ed_terrain_get(35, 30)))
    check('far field untouched', ed_terrain_get(200, 200) == 25)

    -- undo restores exactly, redo restores the edit
    check('undo ok', T.Undo() == true)
    check('undo restores', T.Checksum(10, 10, 60, 60) == base)
    check('redo ok', T.Redo() == true)
    check('redo restores', T.Checksum(10, 10, 60, 60) == raised)

    -- flatten pulls a bump back toward its level
    T.Brush.mode = 'flatten'
    T.Brush.strength = 1
    T.Brush.level = 25
    T.Line(20, 30, 50, 30)
    local flattened = T.Checksum(10, 10, 60, 60)
    check('flatten reduces', flattened < raised, tostring(flattened) .. ' < ' .. tostring(raised))

    -- smooth keeps mean roughly, lowers variance proxy (max)
    T.Brush.mode = 'raise'
    T.Brush.level = nil
    T.Brush.strength = 12
    T.BeginStroke()
    T.Dab(100, 100)
    T.EndStroke()
    local peakBefore = ed_terrain_get(100, 100)
    T.Brush.mode = 'smooth'
    T.Brush.strength = 1
    T.Brush.radius = 12
    for i = 1, 4 do
        T.BeginStroke()
        T.Dab(100, 100)
        T.EndStroke()
    end
    check('smooth lowers a spike', ed_terrain_get(100, 100) < peakBefore, tostring(ed_terrain_get(100, 100)) .. ' < ' .. tostring(peakBefore))

    -- noise is deterministic per stroke id and bounded
    T.Brush.mode = 'noise'
    T.Brush.strength = 2
    T.Brush.radius = 8
    T.BeginStroke()
    local nchanged = T.Dab(160, 160)
    T.EndStroke()
    check('noise changes samples', nchanged > 0, tostring(nchanged))
    T.Undo()
    check('noise undo', ed_terrain_get(160, 160) == 25, tostring(ed_terrain_get(160, 160)))

    -- clamps at the edge
    T.Brush.mode = 'raise'
    T.Brush.radius = 10
    T.Brush.strength = 4
    T.BeginStroke()
    T.Dab(0, 0)
    T.EndStroke()
    check('corner dab ok', ed_terrain_get(0, 0) > 25)
    T.Undo()
    check('corner undo', ed_terrain_get(0, 0) == 25)

    -- the native dab (ed_terrain_brush) gives the Lua loop's heights: the same strokes with T.NativeBrush on and off, compared word for word (up to one word of float rounding)
    if rawget(_G, 'ed_terrain_brush') then
        local savedBrush = { mode = T.Brush.mode, radius = T.Brush.radius, strength = T.Brush.strength, falloff = T.Brush.falloff, level = T.Brush.level }
        local function Run(mode, native)
            ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
            ed_terrain_raise(95, 95, 12, 6)
            ed_terrain_raise(110, 102, 9, -4)
            ed_terrain_raise(104, 118, 15, 5)
            T.ClearHistory()
            T.NativeBrush = native
            T.Brush.mode = mode
            T.Brush.radius = 13.5
            T.Brush.strength = (mode == 'smooth') and 6 or 2.5
            T.Brush.falloff = 0.7
            T.Brush.level = nil
            T.SetNextStrokeId(1000)
            T.BeginStroke()
            local total = T.Dab(100.3, 100.6) + T.Dab(108, 104.25) + T.Dab(106.5, 112)
            T.EndStroke()
            local words = ed_terrain_read_rect(70, 70, 140, 140)
            T.NativeBrush = true
            return words, total
        end
        for _, mode in { 'raise', 'lower', 'plateau', 'flatten', 'smooth', 'noise' } do
            local lua, luaChanged = Run(mode, false)
            local nat, natChanged = Run(mode, true)
            local differ, worst = 0, 0
            for i = 1, 71 * 71 do
                local d = math.abs(lua[i] - nat[i])
                if d > 0 then differ = differ + 1 end
                if d > worst then worst = d end
            end
            check('native ' .. mode .. ' dab = the Lua loop', worst <= 1 and differ <= 20 and luaChanged > 0 and natChanged > 0,
                  differ .. ' words differ, worst ' .. worst .. ', changed lua ' .. tostring(luaChanged) .. ' native ' .. tostring(natChanged))
        end
        T.NativeBrush = true
        T.Brush.mode, T.Brush.radius, T.Brush.strength, T.Brush.falloff, T.Brush.level = savedBrush.mode, savedBrush.radius, savedBrush.strength, savedBrush.falloff, savedBrush.level
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        T.ClearHistory()
    end

    local head = 'PASS'
    if table.getn(failures) > 0 then
        head = 'FAIL (' .. table.getn(failures) .. ')'
    end
    return head .. '\n' .. table.concat(lines, '\n')
end
