-- Erosion suite self test (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T3). Run in the live editor:
--   return import('/lua/editor/selftest_erosion.lua').Run()
-- Returns a report; the first line is PASS or FAIL. The golden checksums of the solvers are in selftest_erosion_cases.lua (shared with the native test EdErosionTest.cpp).
-- Bench() measures the speed on the map size of the editor.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Erosion = import('/lua/editor/erosion.lua')
local EroBrush = import('/lua/editor/erosionbrush.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Brushes = import('/lua/editor/brushes.lua')

local function Split(s, sep)
    local out, pos = {}, 1
    while true do
        local i = string.find(s, sep, pos, true)
        if not i then
            table.insert(out, string.sub(s, pos))
            break
        end
        table.insert(out, string.sub(s, pos, i - 1))
        pos = i + 1
    end
    return out
end

local function ParseParams(text)
    local p = {}
    if text == '' then return p end
    for _, kv in Split(text, ',') do
        local eq = string.find(kv, '=', 1, true)
        if eq then
            local key, val = string.sub(kv, 1, eq - 1), string.sub(kv, eq + 1)
            if tonumber(val) then p[key] = tonumber(val) else p[key] = val end
        end
    end
    return p
end

--- The fixtures of the cases file: H (a 65 x 65 mountain field), R (erodibility), F (a flat plate).
local function Fixtures(S)
    local fix = {}
    local r = S:Op('ridged', { width = 65, height = 65, seed = 11, scale = 26, octaves = 3, persistence = 0.4 })
    local p = S:Op('perlin', { width = 65, height = 65, seed = 111, scale = 13, octaves = 3 })
    local rr = S:Op('affine', { a = r, mul = 55, add = 0 })
    local pp = S:Op('affine', { a = p, mul = 8, add = 0 })
    fix.H = S:Op('add', { a = rr, b = pp })
    fix.R = S:Op('perlin', { width = 65, height = 65, seed = 4, scale = 14, octaves = 3 })
    fix.F = S:Op('const', { width = 33, height = 33, value = 10 })
    return fix
end

local function CaseChecksum(S, fix, case)
    local p = ParseParams(case[3])
    if case[4] ~= '' then
        for _, kv in Split(case[4], ',') do
            local eq = string.find(kv, '=', 1, true)
            p[string.sub(kv, 1, eq - 1)] = fix[string.sub(kv, eq + 1)]
        end
    end
    if (case[2] == 'erode_hydraulic' or case[2] == 'erode_droplet') and p.cpu_only == nil then p.cpu_only = 1 end      -- the goldens are CPU results; the fixtures are big enough for the GPU solver, which is not bit identical
    local f, err = Fields.TryOp(case[2], p)
    if not f then return nil, err end
    S:Add(f)
    return Fields.Checksum(f)
end

local function Join(list)
    local out = {}
    for i, v in list do out[i] = tostring(v) end
    return table.concat(out, ',')
end

local function MapSum()
    local w, h = ed_terrain_info()
    return Fields.Run(function(S) return Fields.Checksum(S:Height()) end), w, h
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

    check('erosion ops present', Fields.IsAvailable() and ed_field_op_multi ~= nil)
    if not (Fields.IsAvailable() and ed_field_op_multi) then return 'FAIL (1)\n' .. table.concat(lines, '\n') end
    local w, h = ed_terrain_info()
    check('terrain present', w ~= nil and w >= 65, tostring(w))
    if not w then return 'FAIL\n' .. table.concat(lines, '\n') end
    local startCount = ed_field_count()
    local threads0 = ed_field_threads()

    -- golden checksums of every solver output, at several thread counts
    local Cases = import('/lua/editor/selftest_erosion_cases.lua').Cases
    local cases = {}
    for _, rawLine in Split(Cases, '\n') do
        local line = (string.gsub(rawLine, '\r', ''))
        if line ~= '' and string.sub(line, 1, 1) ~= '#' then
            local f = Split(line, '|')
            if table.getn(f) >= 5 then table.insert(cases, f) end
        end
    end
    check('cases loaded', table.getn(cases) >= 15, table.getn(cases))
    for _, threads in { 1, 3, threads0 } do
        ed_field_threads(threads)
        local bad = {}
        Fields.Run(function(S)
            local fix = Fixtures(S)
            for _, c in cases do
                local sum, err = CaseChecksum(S, fix, c)
                if sum ~= c[5] then table.insert(bad, c[1] .. ' (' .. tostring(sum or err) .. ' / ' .. c[5] .. ')') end
            end
        end)
        check('golden checksums, ' .. threads .. ' thread(s)', table.getn(bad) == 0, table.concat(bad, '; '))
    end
    ed_field_threads(threads0)

    -- multi output: the main field and the masks come from one run and agree with the single output runs
    Fields.Run(function(S)
        local fix = Fixtures(S)
        local main, extra = ed_field_op_multi('erode_hydraulic', { a = fix.H, iterations = 40 })
        S:Add(main)
        for _, f in extra do S:Add(f) end
        check('multi output names', extra.wear and extra.deposit and extra.flow and extra.accum and extra.water and extra.sediment)
        local amn, amx = Fields.Stats(extra.accum)
        check('accumulation mask is 0..1', amn >= 0 and amx <= 1 and amx > 0.3, tostring(amn) .. ' .. ' .. tostring(amx))
        local single = S:Op('erode_hydraulic', { a = fix.H, iterations = 40, output = 'wear' })
        check('multi output wear = single output wear', Fields.Checksum(extra.wear) == Fields.Checksum(single))
        local mn = Fields.Stats(extra.wear)
        check('wear is never negative', mn >= 0)
        check('bad output name is an error', Fields.TryOp('erode_hydraulic', { a = fix.H, output = 'nonsense' }) == nil)
    end)

    -- Apply: heights and masks as ONE history entry, undo / redo exact
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    Fields.Run(function(S)
        local n = S:Op('ridged', { seed = 5, scale = math.max(24, w / 3), octaves = 4 })
        local hgt = S:Op('affine', { a = n, mul = 50, add = 10 })
        Fields.CommitHeight(hgt, { label = 'selftest terrain' })
    end)
    local start = MapSum()
    local layerBefore = Fields.Run(function(S) return Fields.Checksum(S:Stratum(3, true)) end)
    Erosion.UsePreset('hills')
    Erosion.state.masks.wear.on = true
    Erosion.state.masks.wear.layer = 3
    Erosion.state.masks.accum.on = true
    Erosion.state.masks.accum.layer = 4
    local v0 = History.Version
    local changed, entry = Erosion.Apply('hydraulic', Erosion.ValuesOf('hydraulic'), { label = 'selftest erosion' })
    check('apply changes the terrain', changed and changed > 100, tostring(changed))
    check('apply is one history entry', History.Version == v0 + 1, tostring(History.Version) .. ' vs ' .. v0)
    local eroded = MapSum()
    check('terrain differs after apply', eroded ~= start)
    local layerAfter = Fields.Run(function(S) return Fields.Checksum(S:Stratum(3, true)) end)
    check('wear mask was written to layer 3', layerAfter ~= layerBefore)
    History.Undo()
    check('undo restores the terrain', MapSum() == start)
    check('undo restores the mask', Fields.Run(function(S) return Fields.Checksum(S:Stratum(3, true)) end) == layerBefore)
    History.Redo()
    check('redo restores the eroded terrain', MapSum() == eroded)
    History.Undo()
    if entry and entry.release then entry.release() end
    Erosion.state.masks.wear.on = false
    Erosion.state.masks.accum.on = false

    -- preview on the terrain and revert
    do
        local step = Erosion.PreviewStep()
        local result = Erosion.Run('droplet', Erosion.ValuesOf('droplet'), { step = step, seed = 3 })
        local depth = Terrain.UndoDepth()
        local hist = History.Version
        local n = Erosion.ShowPreview(result)
        check('preview writes the terrain', n > 100, tostring(n))
        check('preview is not a history entry', History.Version == hist)
        check('preview changed the map', MapSum() ~= start)
        check('revert takes the preview back', Erosion.Revert() and MapSum() == start)
        check('revert leaves no step', Terrain.UndoDepth() == depth)
        Erosion.Free(result)
    end

    -- the brush: one stroke = one undo step, deterministic, local, symmetric to nothing else
    if EroBrush.IsAvailable() then
        local savedBrush = { mode = Terrain.Brush.mode, radius = Terrain.Brush.radius, strength = Terrain.Brush.strength, falloff = Terrain.Brush.falloff }
        local cx, cz = math.floor(w / 2), math.floor(h / 2)
        local function Stroke(mode)
            Terrain.Brush.mode = mode
            Terrain.Brush.radius = 14
            Terrain.Brush.strength = 3
            Terrain.Brush.falloff = 1
            local total = 0
            Terrain.BeginStroke()
            for i = 0, 8 do total = total + Terrain.Dab(cx - 12 + i * 3, cz) end
            Terrain.EndStroke()
            return total
        end
        for _, mode in { 'erode', 'rain', 'deposit' } do
            local depth = Terrain.UndoDepth()
            local n = Stroke(mode)
            local after = MapSum()
            check(mode .. ' brush changes the terrain', n > 0 and after ~= start, tostring(n))
            check(mode .. ' stroke is one undo step', Terrain.UndoDepth() == depth + 1, tostring(Terrain.UndoDepth()) .. ' vs ' .. depth)
            -- repeat: same stroke from the same state gives the same result
            Terrain.Undo()
            check(mode .. ' undo restores exactly', MapSum() == start)
            Stroke(mode)
            check(mode .. ' stroke is deterministic', MapSum() == after)
            Terrain.Undo()
        end
        -- symmetry: one stroke, both sides change, still one undo step
        do
            local depth = Terrain.UndoDepth()
            local plain = Stroke('erode')
            Terrain.Undo()
            Symmetry.Mode = 'mirror_x'
            local both = Stroke('erode')
            local one = Terrain.UndoDepth() == depth + 1
            Terrain.Undo()
            Symmetry.Mode = 'off'
            check('symmetric erode stroke changes both sides', both > plain * 1.5, tostring(both) .. ' vs ' .. tostring(plain))
            check('symmetric erode stroke is one undo step', one)
            check('symmetric stroke undone', MapSum() == start)
        end
        -- a shaped brush (weights computed in Lua)
        do
            Brushes.Active = 'square'
            local n = Stroke('erode')
            check('shaped erode brush changes the terrain', n > 0)
            Brushes.Active = 'round'
            Terrain.Undo()
            check('shaped stroke undone', MapSum() == start)
        end
        -- locality: nothing changes far outside the brush window
        local function Corners()
            return Fields.Run(function(S)
                local f = S:Height()
                return Join(Fields.Read(f, 0, 0, 7, 7)) .. '|' .. Join(Fields.Read(f, w - 8, h - 8, w - 1, h - 1))
            end)
        end
        local cornersBefore = Corners()
        Stroke('erode')
        check('erode brush leaves the map corners alone', Corners() == cornersBefore)
        Terrain.Undo()
        Terrain.Brush.mode, Terrain.Brush.radius, Terrain.Brush.strength, Terrain.Brush.falloff = savedBrush.mode, savedBrush.radius, savedBrush.strength, savedBrush.falloff
    else
        table.insert(lines, '  skip brush tests (no natives)')
    end

    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    ed_field_threads(threads0)
    local endCount = ed_field_count()
    check('no field leaks', endCount <= startCount, tostring(startCount) .. ' -> ' .. tostring(endCount))

    local head = 'PASS'
    if table.getn(failures) > 0 then head = 'FAIL (' .. table.getn(failures) .. ')' end
    return head .. '\n' .. table.concat(lines, '\n')
end

--- Speed of the solvers on the map: seconds with the pool's threads, and `which` = 1 .. 4 picks one case (the editor's command channel answers within a minute); threads = 1 runs it on one thread.
local BENCH = {
    { 'hydraulic 300 iterations', 'erode_hydraulic', { iterations = 300 } },
    { 'hydraulic 1000 iterations', 'erode_hydraulic', { iterations = 1000 } },
    { 'droplets 1 per cell', 'erode_droplet', { density = 1 } },
    { 'stream power 10 iterations', 'erode_stream', { iterations = 10 } },
    { 'hydraulic 100 it, no masks', 'erode_hydraulic', { iterations = 100, masks = 0 } },
}

function Bench(which, threads)
    local out = {}
    local threads0 = ed_field_threads()
    ed_field_threads(threads or threads0)
    local w, h = ed_terrain_info()
    Fields.Run(function(S)
        local n = S:Op('ridged', { width = w, height = h, seed = 3, scale = w * 0.4, octaves = 5 })
        local hgt = S:Op('affine', { a = n, mul = 55, add = 8 })
        table.insert(out, 'threads ' .. ed_field_threads() .. ', ' .. w .. ' x ' .. h .. ':')
        for i, case in BENCH do
            local c = case
            if not which or which == i then
                local p = {}
                for k, v in c[3] do p[k] = v end
                p.a = hgt
                local t = Fields.Timed(c[1], function()
                    local main, extra = ed_field_op_multi(c[2], p)
                    S:Add(main)
                    for _, f in extra do S:Add(f) end
                end)
                table.insert(out, string.format('  %-28s %8.0f ms', c[1], t * 1000))
            end
        end
    end)
    ed_field_threads(threads0)
    return table.concat(out, '\n')
end
