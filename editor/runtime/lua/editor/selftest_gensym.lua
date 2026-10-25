-- Self test of symmetric generation (gensym.lua, docs/projects/editor/GEN_SYMMETRY.md): what a graph writes (heights, paint, props) is symmetric whatever the nodes before did.
-- Lua 5.0 dialect.

local Fields = import('/lua/editor/fields.lua')
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local GenSym = import('/lua/editor/gensym.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local MaskGen = import('/lua/editor/maskgen.lua')

--- rms and worst difference between a field and the average of its images under (mode, n) about the middle of the map.
local function Asymmetry(f, S, mode, n)
    local avg = S:Op('symmetrize', { a = f, mode = mode, n = n or 3, combine = 'avg', seam = 0 })
    local d = S:Op('sub', { a = f, b = avg })
    local _, _, ms = Fields.Stats(S:Op('mul', { a = d, b = d }))
    local lo, hi = Fields.Stats(d)
    return math.sqrt(ms), math.max(math.abs(lo), math.abs(hi))
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
    if not Fields.IsAvailable() then return 'FAIL (no field natives)' end
    local w, h = ed_terrain_info()
    if not w or w < 129 then return 'FAIL (no terrain)' end

    -- ---- the setting, the points ------------------------------------------------------------------------------------------------------------
    check('the setting nil follows the map, off is none', GenSym.Key(nil) == 'map' and GenSym.Spec('off') == false)
    local mode0, cx0, cz0 = Symmetry.Mode, Symmetry.CenterX, Symmetry.CenterZ
    Symmetry.Mode = 'off'
    check('following a map with no symmetry gives none', GenSym.Spec('map') == false)
    Symmetry.Mode = 'rot2'
    local sp = GenSym.Spec(nil)
    check('following the map takes its mode and centre', sp and sp.mode == 'rot2' and math.abs(sp.cx - (w - 1) / 2) < 0.01)
    Symmetry.Mode, Symmetry.CenterX, Symmetry.CenterZ = mode0, cx0, cz0
    local s3 = GenSym.Spec({ mode = 'rotn', n = 3 })
    local p3 = GenSym.Points(s3, s3.cx + 30, s3.cz)
    check('a 3-fold turn has three images, 120 degrees apart', table.getn(p3) == 3 and math.abs(p3[2].x - (s3.cx - 15)) < 0.01 and math.abs(p3[2].z - (s3.cz + 30 * 0.8660254)) < 0.01,
          table.getn(p3))
    check('the anti-diagonal image of (x, z) is (-z, -x) about the centre', math.abs(GenSym.Points(GenSym.Spec('adiag'), s3.cx + 10, s3.cz + 4)[2].x - (s3.cx - 4)) < 0.01)
    check('every choice of the menu is a setting', table.getn(GenSym.Choices_) >= 12 and GenSym.Label('rot2') == 'Turn by 180' and GenSym.Label({ mode = 'rotn', n = 6 }) == 'Turn by 60 (6)')

    -- ---- a graph whose result is not symmetric, made symmetric at the output -----------------------------------------------------------------------
    local Strata = import('/lua/editor/strata.lua')
    local hasMasks = ed_stratum_info() and true or false
    local startProps = ed_prop_count()
    GRun.Release()
    MaskGen.ClearPreview()
    if hasMasks then for i = 1, 4 do Strata.ClearMask(i) end end
    local startFields = ed_field_count()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()

    local function HeightGraph(setting)
        Graph.New('symmetry test')
        Graph.Current.symmetry = setting
        local p = Graph.Add('perlin', 0, 0, { scale = 60, octaves = 4 })
        local r = Graph.Add('range', 200, 0, { lo = 10, hi = 50 })
        local o = Graph.Add('out_height', 400, 0)
        Graph.Connect(p.id, 'out', r.id, 'a')
        Graph.Connect(r.id, 'out', o.id, 'a')
        return p, r, o
    end
    local function BuildAndMeasure(mode, n)
        GRun.Refresh(true)
        local r = GRun.Build()
        if not r then return nil end
        return Fields.Run(function(S)
            local rms, worst = Asymmetry(S:Height(1), S, mode, n)
            return { rms = rms, worst = worst }
        end)
    end
    for _, c in { { 'rot2', 'rot2', 0.01 }, { 'mirror_xz', 'mirror_xz', 0.01 }, { 'mirror_x', 'mirror_x', 0.01 }, { 'rot4', 'rot4', 0.05 } } do
        HeightGraph(c[1])
        local m = BuildAndMeasure(c[2])
        check('heights of a noise graph are symmetric under ' .. c[1], m and m.rms <= c[3], m and string.format('rms %.4f worst %.3f', m.rms, m.worst))
        History.Undo()
    end
    HeightGraph({ mode = 'rotn', n = 3 })
    local m3 = BuildAndMeasure('rotn', 3)
    check('heights are symmetric under a 3-fold turn (interpolation only)', m3 and m3.rms <= 0.35, m3 and string.format('rms %.4f worst %.3f', m3.rms, m3.worst))
    History.Undo()
    HeightGraph('off')
    local moff = BuildAndMeasure('rot2')
    check('with the symmetry off the same graph is not symmetric (the test can tell)', moff and moff.rms > 0.5, moff and string.format('rms %.4f', moff.rms))
    History.Undo()
    -- following the map
    Symmetry.Mode, Symmetry.CenterX, Symmetry.CenterZ = 'mirror_x', false, false
    HeightGraph(nil)
    local mmap = BuildAndMeasure('mirror_x')
    check('a graph that follows the map is symmetric by the map\'s symmetry', mmap and mmap.rms <= 0.01, mmap and string.format('rms %.4f', mmap.rms))
    History.Undo()
    Symmetry.Mode = 'off'
    HeightGraph(nil)
    local mnone = BuildAndMeasure('mirror_x')
    check('a graph that follows a map without symmetry is left as it is', mnone and mnone.rms > 0.5, mnone and string.format('rms %.4f', mnone.rms))
    History.Undo()
    Symmetry.Mode, Symmetry.CenterX, Symmetry.CenterZ = mode0, cx0, cz0

    -- ---- a mask on a height output is symmetric too, and the symmetry is in the file ------------------------------------------------------------------
    HeightGraph('rot2')
    local before = Graph.Text()
    check('the symmetry is saved with the graph', string.find(before, "['symmetry'] = 'rot2'", 1, true) ~= nil)
    local g2 = Graph.Normalize(loadstring(before)())
    check('and read back', g2.symmetry == 'rot2')
    Graph.SetSymmetry({ mode = 'rotn', n = 5 })
    check('SetSymmetry is one undo step that Undo takes back', Graph.Current.symmetry.n == 5)
    Graph.Undo()
    check('undo restores the symmetry', Graph.Current.symmetry == 'rot2')

    -- ---- paint and props ---------------------------------------------------------------------------------------------------------------------
    if hasMasks then
        Graph.New('paint test')
        Graph.Current.symmetry = 'rot2'
        local vo = Graph.Add('voronoi', 0, 0, { scale = 50, seed = 3 })
        local ss = Graph.Add('smoothstep', 200, 0, { edge0 = 0.1, edge1 = 0.6 })
        local ol = Graph.Add('out_layer', 400, 0, { layer = 2 })
        Graph.Connect(vo.id, 'out', ss.id, 'a')
        Graph.Connect(ss.id, 'out', ol.id, 'a')
        local sc = Graph.Add('out_scatter', 400, 200, { count = 80, minDist = 8, slopeMax = 90, underWater = true, margin = 4 })
        Graph.SetParam(sc.id, 'entries', { { bp = '/env/common/props/markers/M_Blank_prop.bp', weight = 1 } })
        Graph.Connect(ss.id, 'out', sc.id, 'a')
        GRun.Refresh(true)
        local r, why = GRun.Build()
        if r then
            local m = Fields.Run(function(S)
                local mask = S:Stratum(2)
                local rms, worst = Asymmetry(mask, S, 'rot2')
                local _, _, mean = Fields.Stats(mask)
                return { rms = rms, worst = worst, mean = mean }
            end)
            check('the paint mask of an output is symmetric', m.mean > 0.05 and m.rms <= 0.01, string.format('mean %.3f rms %.4f worst %.3f', m.mean, m.rms, m.worst))
            local c = (w - 1) / 2
            local n, paired = 0, 0
            local list = {}
            for i = startProps + 1, ed_prop_count() do
                local bp, x, y, z = ed_prop_get(i)
                table.insert(list, { x = x, z = z })
            end
            for _, a in list do
                n = n + 1
                for _, b in list do
                    local dx, dz = (2 * c - a.x) - b.x, (2 * c - a.z) - b.z
                    if dx * dx + dz * dz < 1 then paired = paired + 1 break end
                end
            end
            check('every prop has its image under the turn', n >= 20 and paired == n, paired .. ' of ' .. n)
            History.Undo()
        else
            check('the paint and props graph builds', false, tostring(why))
        end
    end

    -- ---- clean up -------------------------------------------------------------------------------------------------------------------------------
    GRun.Release()
    Graph.New('untitled')
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()
    MaskGen.ClearPreview()
    if hasMasks then for i = 1, 4 do Strata.ClearMask(i) end end
    Symmetry.Mode, Symmetry.CenterX, Symmetry.CenterZ = mode0, cx0, cz0
    check('no field leaks', ed_field_count() == startFields, ed_field_count() .. ' vs ' .. startFields)
    check('no prop leaks', ed_prop_count() == startProps)

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
    return 'PASS gensym\n' .. table.concat(shown, '\n')
end
