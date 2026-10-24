-- Self test of the map layout (layout.lua), its graph nodes (graphnodes_layout.lua) and the start / resource generator (layoutmarkers.lua). Run in the live editor:
--   return import('/lua/editor/selftest_layout.lua').Run()
-- Needs a map (the terrain is made flat again at the end, and the markers the test placed are removed).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Layout = import('/lua/editor/layout.lua')
local LM = import('/lua/editor/layoutmarkers.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Map = import('/lua/editor/map.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
end

local function Count(t)
    local n = 0
    for _ in t do n = n + 1 end
    return n
end

local function Sum(layer)
    local s = 0
    for k = 1, table.getn(layer.data) do s = s + layer.data[k] end
    return s
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

    local symWas = Symmetry.Mode
    Symmetry.SetMode('off')
    local docWas = Layout.Plain()

    -- ---- the document ----------------------------------------------------------------------------------------------------------------------------------
    Layout.New({})
    check('a new document has six layers', Layout.Count() == 6 and Layout.Layer(1).kind == 'hills' and Layout.Layer(6).kind == 'base')
    local added = Layout.AddLayer('hills')
    check('a second layer of a kind is numbered', Layout.Layer(added).name == 'Hills 2' and Layout.Count() == 7)
    Layout.MoveLayer(added, -1)
    check('layers move', Layout.Layer(6).name == 'Hills 2' and Layout.Layer(7).kind == 'base')
    Layout.RemoveLayer(6)
    check('layers are removed', Layout.Count() == 6)
    check('a kind that does not exist is refused', Layout.AddLayer('nonsense') == nil)

    -- ---- painting ------------------------------------------------------------------------------------------------------------------------------------------
    local res = Layout.Doc.res
    local hills = Layout.Layer(1)
    Layout.BeginStroke(1)
    Layout.Dab(1, 30, 30, 6, 1, 1, false)
    check('a dab paints the cell under it fully', hills.data[30 * res + 30 + 1] == 1 and hills.data[1] == 0)
    local painted = Sum(hills)
    check('a dab covers about a disc', painted > 100 and painted < 130, painted)
    Layout.Dab(1, 30, 30, 6, 1, 1, true)
    check('the eraser takes it away again', Sum(hills) < 0.5)
    Layout.Dab(1, 60, 60, 5, 0.5, 0.5, false)
    check('a weaker brush paints partial values', hills.data[60 * res + 60 + 1] == 0.5)
    local had = Layout.EndStroke('test')
    check('a stroke makes one undo entry', had == true)
    History.Undo()
    check('undo of a stroke puts the cells back', Sum(hills) == 0)
    History.Redo()
    check('redo of a stroke paints them again', Sum(hills) > 10)
    Layout.Fill(1, 0)
    Layout.Line(1, 10, 10, 50, 10, 2, 1, 1, false)
    check('a line paints along its way', hills.data[10 * res + 30 + 1] == 1 and hills.data[40 * res + 30 + 1] == 0)
    Layout.Fill(1, 0)
    local nrect = Layout.FillRect(1, 10, 10, 20, 20, 1, false)
    check('a rectangle fills its cells', nrect == 100 and hills.data[15 * res + 15 + 1] == 1 and hills.data[25 * res + 25 + 1] == 0, nrect)
    Layout.Fill(1, 0)
    local nell = Layout.FillEllipse(1, 10, 10, 30, 20, 1, false)
    check('an ellipse fills less than its rectangle', nell > 120 and nell < 170, nell)
    Layout.Fill(1, 0)
    local npoly = Layout.FillPolygon(1, { { 10, 10 }, { 30, 10 }, { 10, 30 } }, 1, false)
    check('a polygon fills a triangle', npoly > 180 and npoly < 220, npoly)
    Layout.Fill(1, 0)

    -- ---- symmetry ------------------------------------------------------------------------------------------------------------------------------------------
    Symmetry.SetMode('mirror_x')
    Layout.Dab(1, 20, 40, 3, 1, 1, false)
    check('mirror x: the dab has its image on the other side', hills.data[40 * res + 20 + 1] == 1 and hills.data[40 * res + (res - 21) + 1] == 1)
    Layout.Fill(1, 0)
    Symmetry.SetMode('rot2')
    Layout.FillRect(1, 10, 10, 20, 20, 1, false)
    check('rotate 180: a rectangle has its turned copy', hills.data[15 * res + 15 + 1] == 1 and hills.data[(res - 16) * res + (res - 16) + 1] == 1 and hills.data[15 * res + (res - 16) + 1] == 0)
    Layout.Fill(1, 0)
    Symmetry.SetMode('off')

    -- ---- templates ------------------------------------------------------------------------------------------------------------------------------------
    local expected = { duel = 2, four = 4, river = 4, islands = 2 }
    for _, t in Layout.Templates do
        Layout.New({})
        History.Clear()
        local ok, why = Layout.ApplyTemplate(t.id)
        local bases = table.getn(Layout.BaseCentres())
        check('template ' .. t.id .. ': drawn under ' .. t.symmetry .. ' with ' .. tostring(expected[t.id]) .. ' bases', ok == true and Symmetry.Mode == t.symmetry and bases == expected[t.id], tostring(why) .. ' bases ' .. bases)
        local drawn = 0
        for _, L in Layout.Doc.layers do
            if Sum(L) > 0 then drawn = drawn + 1 end
        end
        check('template ' .. t.id .. ': several layers carry a drawing', drawn >= 3, drawn)
        History.Undo()
        check('template ' .. t.id .. ': undo gives the empty drawing back', Layout.Plain() == nil)
    end
    check('the islands template puts the water layer first', (function()
        Layout.ApplyTemplate('islands')
        return Layout.Layer(1).kind == 'water'
    end)())
    Symmetry.SetMode('off')
    Layout.New({})
    History.Clear()

    -- ---- saved with the map --------------------------------------------------------------------------------------------------------------------------------
    Layout.Dab(1, 40, 40, 8, 0.7, 1, false)
    Layout.Dab(4, 100, 90, 6, 1, 1, false)
    Layout.Doc.base, Layout.Doc.water, Layout.Doc.seed = 31, 17, 77
    Layout.Layer(1).p.height = 21
    local plain = Layout.Plain()
    local before1, before4 = Sum(Layout.Layer(1)), Sum(Layout.Layer(4))
    Layout.New({})
    check('a fresh document is empty', Layout.Plain() == nil)
    Layout.Load(plain)
    check('the saved form loads back: cells, settings and layers', math.abs(Sum(Layout.Layer(1)) - before1) < 0.05 and math.abs(Sum(Layout.Layer(4)) - before4) < 0.05 and Layout.Doc.base == 31
        and Layout.Doc.water == 17 and Layout.Doc.seed == 77 and Layout.Layer(1).p.height == 21 and Layout.Count() == 6)
    check('the sidecar text names the layout', string.find(Layout.SidecarText(), 'Layout', 1, true) ~= nil)

    local w = rawget(_G, 'ed_terrain_info') and ed_terrain_info()
    if not w or not Fields.IsAvailable() then
        table.insert(lines, '  (no map: the generator checks are skipped)')
        Symmetry.SetMode(symWas)
        if docWas then Layout.Load(docWas) else Layout.New({}) end
        return Done()
    end
    local size = w - 1
    local startFields = ed_field_count()
    local gpuWas = rawget(_G, 'ed_gpu_info') and ed_gpu_info(false).enabled
    if rawget(_G, 'ed_gpu_enable') then ed_gpu_enable(false) end
    History.Clear()

    -- ---- the generator -------------------------------------------------------------------------------------------------------------------------------------
    local function Terrain(x, z) return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) end
    local k = size / res
    Layout.New({})
    Layout.Doc.base, Layout.Doc.water = 25, 18
    Layout.Doc.weather = 0
    local mountains, plateau, water, base = 2, 3, 4, 6
    Layout.FillEllipse(1, 10, 10, 40, 40, 1, false)                       -- hills
    Layout.FillRect(mountains, 70, 10, 100, 40, 1, false)                 -- mountains
    Layout.FillRect(plateau, 10, 70, 40, 100, 1, false)                   -- plateau
    Layout.FillRect(water, 70, 70, 100, 100, 1, false)                    -- water
    Layout.Dab(base, 118, 118, 4, 1, 1, false)                            -- a base
    local n, why = Layout.Generate({})
    check('the layout generates terrain', n ~= nil and n > 0, tostring(why))
    local flat = Terrain(60 * k, 60 * k)
    local hillsH = Terrain(25 * k, 25 * k)
    local mountH = Terrain(85 * k, 25 * k)
    local plateauH = Terrain(25 * k, 85 * k)
    local waterH = Terrain(85 * k, 85 * k)
    local baseH = Terrain(118 * k, 118 * k)
    check('unpainted ground stays at the ground height', math.abs(flat - 25) < 0.5, flat)
    check('hills rise above the ground', hillsH > flat + 5, hillsH)
    check('mountains rise higher than hills', mountH > hillsH + 10, mountH .. ' vs ' .. hillsH)
    check('a plateau is a flat top at its height', plateauH > flat + 25 and plateauH < flat + 50, plateauH)
    check('water is dug below the water level', waterH < 18 - 5, waterH)
    check('a base is levelled at the ground height', math.abs(baseH - 25) < 1, baseH)
    check('the water level of the map follows the layout', math.abs(import('/lua/editor/world.lua').Value('water_elev') - 18) < 0.01)
    History.Undo()
    check('undo gives the old terrain back', math.abs(Terrain(25 * k, 25 * k) - hillsH) > 3)
    History.Redo()

    -- ---- masks for the generator nodes -----------------------------------------------------------------------------------------------------------------------
    Layout.Doc.layers[2].p.soft = 4                                      -- a soft edge wider than the drawn rectangle would blur its centre on a small map
    local maskIn, maskOut
    Fields.Run(function(S)
        local like = S:Height(1)
        local m = Layout.LayerMask(S, like, 2)
        maskIn = Fields.Sample(m, 85 * k, 25 * k)
        maskOut = Fields.Sample(m, 25 * k, 85 * k)
    end)
    check('a layer mask is 1 where it is drawn and 0 away from it', maskIn > 0.95 and maskOut < 0.02, maskIn .. ' / ' .. maskOut)
    check('the bases are found from the drawing', table.getn(Layout.BaseCentres()) == 1 and math.abs(Layout.BaseCentres()[1].x - 118.5 * k) < 3, table.getn(Layout.BaseCentres()))

    local Graph = import('/lua/editor/graph.lua')
    local GRun = import('/lua/editor/graphrun.lua')
    local Nodes = import('/lua/editor/graphnodes.lua')
    check('the graph nodes exist', Nodes.Defs.layout_height and Nodes.Defs.layout_mask and Nodes.Defs.layout_bases)
    Graph.New('layout nodes')
    local nh = Graph.Add('layout_height', 0, 0)
    local nm = Graph.Add('layout_mask', 0, 150)
    Graph.SetParam(nm.id, 'layer', 2)
    local nb = Graph.Add('layout_bases', 0, 300)
    GRun.Refresh()
    local hf, mf = GRun.Main:Value(nh.id, 'out'), GRun.Main:Value(nm.id, 'out')
    check('Map layout: heights makes the heights of the layout', hf ~= nil and Fields.Sample(hf, 25 * k, 25 * k) > Fields.Sample(hf, 60 * k, 60 * k) + 5)
    check('Map layout: layer mask is 1 on the drawn layer', mf ~= nil and Fields.Sample(mf, 85 * k, 25 * k) > 0.95 and Fields.Sample(mf, 25 * k, 85 * k) < 0.05)
    check('Map layout: bases says how many bases are drawn', GRun.Main:Value(nb.id, 'count') == 1, tostring(GRun.Main:Value(nb.id, 'count')))
    Graph.New('empty')
    GRun.Refresh()
    pcall(GRun.Release)

    -- ---- starts and resources ------------------------------------------------------------------------------------------------------------------------------
    ed_terrain_set_rect(0, 0, w - 1, w - 1, 25)                            -- flat ground for the placement checks
    pcall(function() import('/lua/editor/terrain.lua').ClearHistory() end)
    History.Clear()
    import('/lua/editor/world.lua').Change({ water_on = 0 }, { refresh = true })
    local S = LM.Settings
    local saved = {}
    for key, v in S do saved[key] = v end
    S.starts, S.pattern, S.count, S.radius, S.rotation = 'pattern', 'ring', 4, 0.6, 0
    S.mass, S.massMin, S.massMax, S.massShape, S.facing = 6, 20, 34, 'ring', 'centre'
    S.hydro, S.hydroMin, S.hydroMax, S.extra, S.middle = 1, 40, 50, 0, 0
    S.spacing, S.maxSlope, S.seed, S.clear = 7, 30, 3, true
    local starts = LM.Starts()
    local half = size / 2
    local okRing = table.getn(starts) == 4
    for _, st in starts do
        local d = math.sqrt((st.x - half) * (st.x - half) + (st.z - half) * (st.z - half))
        if math.abs(d - 0.6 * half) > 1 then okRing = false end
    end
    check('a ring pattern puts the starts around the middle at the distance', okRing)
    S.pattern = 'corners'
    check('the corner pattern gives four corners', table.getn(LM.Starts()) == 4)
    S.pattern = 'sides'
    check('the two sides pattern gives two starts', table.getn(LM.Starts()) == 2)
    S.pattern = 'ring'
    local plan = LM.Plan()
    check('the plan has the mass and hydrocarbon asked for', plan.masses == 24 and plan.hydros == 4 and plan.failed == 0, plan.text)
    local far, near = 0, 1e9
    local tooClose = false
    for i, a in plan.items do
        local st = plan.starts[a.start]
        local d = math.sqrt((a.x - st.x) * (a.x - st.x) + (a.z - st.z) * (a.z - st.z))
        if a.kind == 'Mass' then
            far = math.max(far, d)
            near = math.min(near, d)
        end
        for j = i + 1, table.getn(plan.items) do
            local b = plan.items[j]
            local dx, dz = a.x - b.x, a.z - b.z
            if dx * dx + dz * dz < (S.spacing - 0.01) * (S.spacing - 0.01) then tooClose = true end
        end
    end
    check('every mass lies in the distance range (a little slack for the build grid and the search)', near > 20 - 8 and far < 34 + 8, near .. ' .. ' .. far)
    check('no two markers are closer than the spacing', not tooClose)
    local again = LM.Plan()
    local same = table.getn(again.items) == table.getn(plan.items)
    if same then
        for i, a in plan.items do
            if a.x ~= again.items[i].x or a.z ~= again.items[i].z then same = false end
        end
    end
    check('the plan is the same every time (same seed)', same)
    S.massShape, S.mass = 'arc', 5
    S.arc = 120
    local arcPlan = LM.Plan()
    local facing = 0
    local ok = true
    for _, a in arcPlan.items do
        if a.kind == 'Mass' then
            local st = arcPlan.starts[a.start]
            local toCentre = math.atan2(half - st.z, half - st.x)
            local ang = math.atan2(a.z - st.z, a.x - st.x)
            local diff = math.abs(math.mod(ang - toCentre + 3 * 3.14159265, 2 * 3.14159265) - 3.14159265)
            if diff > math.rad(60 + 25) then ok = false end
        end
    end
    check('an arc of 120 degrees faces the middle of the map', ok and arcPlan.masses >= 18)
    S.massShape = 'cluster'
    local cluster = LM.Plan()
    check('a cluster places its mass near each other', cluster.masses >= 18)
    S.massShape, S.mass = 'ring', 6

    local markersBefore = Count(Map.Doc.save.MasterChain._MASTERCHAIN_.Markers)
    local made, err = LM.Place()
    check('Place puts the starts and the resources into the map', made ~= nil and made.starts == 4 and made.mass == 24 and made.hydro == 4, tostring(err))
    local after = Count(Map.Doc.save.MasterChain._MASTERCHAIN_.Markers)
    check('the markers are in the map', after - markersBefore >= 32 - 4, after - markersBefore)
    local armies = import('/lua/editor/armies.lua').Names()
    check('the start markers are ARMY_1 .. ARMY_4', table.getn(armies) == 4 and armies[1] == 'ARMY_1' and armies[4] == 'ARMY_4')
    LM.Place()
    local again2 = Count(Map.Doc.save.MasterChain._MASTERCHAIN_.Markers)
    check('placing again replaces what was made (no doubling)', again2 == after, again2 .. ' vs ' .. after)
    History.Undo()
    check('one undo takes the whole second placement back', Count(Map.Doc.save.MasterChain._MASTERCHAIN_.Markers) == after)
    History.Undo()
    check('and one more the first', Count(Map.Doc.save.MasterChain._MASTERCHAIN_.Markers) == markersBefore, Count(Map.Doc.save.MasterChain._MASTERCHAIN_.Markers) .. ' vs ' .. markersBefore)

    -- ---- back to how it was ------------------------------------------------------------------------------------------------------------------------------------
    for key, v in saved do S[key] = v end
    Symmetry.SetMode(symWas)
    ed_terrain_set_rect(0, 0, w - 1, w - 1, 25)
    pcall(function() import('/lua/editor/terrain.lua').ClearHistory() end)
    History.Clear()
    LM.ClearPlan()
    pcall(function() import('/lua/editor/graphrun.lua').Release() end)
    pcall(function() import('/lua/editor/graphrun.lua').DropBuildCache() end)
    if docWas then Layout.Load(docWas) else Layout.New({}) end
    if gpuWas and rawget(_G, 'ed_gpu_enable') then ed_gpu_enable(true) end
    check('no field leaks', ed_field_count() == startFields, ed_field_count() - startFields)
    return Done()
end
