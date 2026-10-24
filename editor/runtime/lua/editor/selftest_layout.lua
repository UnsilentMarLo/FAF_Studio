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
    -- what other tests (or an open graph) keep alive is let go first: it is not ours to count
    pcall(function() import('/lua/editor/graphrun.lua').Release() end)
    pcall(function() import('/lua/editor/maskgen.lua').ClearPreview() end)
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

    -- ---- the generated terrain is symmetric about the symmetry centre ------------------------------------------------------------------------------------------
    local cxWas, czWas = Symmetry.CenterX, Symmetry.CenterZ
    local Playable = import('/lua/editor/playable.lua')
    local depth0 = History.Depth()
    Layout.New({})
    Layout.Doc.base, Layout.Doc.water, Layout.Doc.weather = 25, 18, 0
    Symmetry.SetMode('rot2')
    Layout.CentreSymmetry()
    Layout.FillEllipse(1, 12, 20, 44, 70, 1, false)
    Layout.FillRect(2, 20, 90, 40, 110, 1, false)
    local ng = Layout.Generate({})
    local worst = 0
    for _, q in { { 30, 40 }, { 38, 60 }, { 25, 100 }, { 40, 95 }, { 20, 30 } } do
        local x, z = q[1] * k, q[2] * k
        worst = math.max(worst, math.abs(Terrain(x, z) - Terrain(size - x, size - z)))
    end
    check('a layout under rot2 makes terrain that is symmetric about the centre (noise relief included)', ng ~= nil and worst < 0.02, worst)
    Symmetry.SetMode('mirror_x')
    Layout.CentreSymmetry()
    Layout.Generate({})
    worst = 0
    for _, q in { { 30, 40 }, { 38, 60 }, { 25, 100 }, { 40, 95 } } do
        local x, z = q[1] * k, q[2] * k
        worst = math.max(worst, math.abs(Terrain(x, z) - Terrain(size - x, z)))
    end
    check('and under mirror x', worst < 0.02, worst)
    while History.Depth() > depth0 do History.Undo() end

    -- ---- a playable area that is not square ----------------------------------------------------------------------------------------------------------------
    local setOk = Playable.Set(0, 0, size, math.floor(size / 2))
    check('the test map takes a playable area of 2 : 1', setOk == true)
    Layout.New({})
    local d = Layout.Doc
    check('the canvas has the shape of the playable area', d.rw == 128 and d.rh == 64 and math.abs(d.cell - size / 128) < 1e-6 and table.getn(d.layers[1].data) == 128 * 64, d.rw .. ' x ' .. d.rh)
    local wx, wz = Layout.ToWorld(10, 20)
    local bx, bz = Layout.ToCell(wx, wz)
    check('world units and canvas cells convert both ways', math.abs(wx - (d.ox + 10 * d.cell)) < 1e-6 and math.abs(bx - 10) < 1e-6 and math.abs(bz - 20) < 1e-6)
    Symmetry.SetMode('rot2')
    Layout.CentreSymmetry()
    local _, scz = Symmetry.Centre()
    check('the symmetry centre follows the middle of the area', Layout.SymmetryCentred() and math.abs(scz - size / 4) < 0.6, scz)
    Layout.Dab(1, 20, 10, 3, 1, 1, false)
    local hl = Layout.Layer(1)
    check('rot2 on a canvas that is not square: the turned copy lies about the middle of the canvas', hl.data[10 * 128 + 20 + 1] == 1 and hl.data[53 * 128 + 107 + 1] == 1 and hl.data[10 * 128 + 107 + 1] == 0)
    Layout.Fill(1, 0)
    Symmetry.SetMode('off')
    Layout.FillRect(1, 20, 10, 50, 40, 1, false)
    Layout.FillRect(2, 80, 20, 110, 30, 1, false)
    Layout.Doc.layers[2].p.soft = 4
    Layout.Doc.weather = 0
    local ng2 = Layout.Generate({})
    local hh, mh, off = Terrain(35 * d.cell + d.ox, 25 * d.cell + d.oz), Terrain(95 * d.cell + d.ox, 25 * d.cell + d.oz), Terrain(60 * d.cell, 45 * d.cell)
    check('the drawing lands on its place in the playable area', ng2 ~= nil and hh > off + 5 and mh > hh + 5, hh .. ' / ' .. mh .. ' / ' .. off)
    local mIn, mOut
    Fields.Run(function(S2)
        local m = Layout.LayerMask(S2, S2:Height(1), 2)
        mIn = Fields.Sample(m, 95 * d.cell + d.ox, 25 * d.cell + d.oz)
        mOut = Fields.Sample(m, 95 * d.cell + d.ox, 55 * d.cell + d.oz)
    end)
    check('a layer mask of the area lines up with the world', mIn > 0.9 and mOut < 0.05, mIn .. ' / ' .. mOut)
    Layout.Fill(1, 0)
    Layout.Dab(6, 100, 50, 4, 1, 1, false)
    local bc = Layout.BaseCentres()
    check('base centres are world positions of the area', table.getn(bc) == 1 and math.abs(bc[1].x - (d.ox + 100.5 * d.cell)) < d.cell and math.abs(bc[1].z - (d.oz + 50.5 * d.cell)) < d.cell)
    Layout.Fill(6, 0)
    S.starts, S.pattern, S.count, S.radius, S.rotation = 'pattern', 'sides', 2, 0.6, 0
    local sides = LM.Starts()
    check('a pattern is stretched over the area (two sides lie along the long axis)', table.getn(sides) == 2 and math.abs(sides[1].z - size / 4) < 0.5 and math.abs(math.abs(sides[1].x - size / 2) - 0.6 * size / 2) < 0.5,
        table.getn(sides) > 0 and (sides[1].x .. ', ' .. sides[1].z) or 'none')
    S.pattern, S.count = 'ring', 4
    ed_terrain_set_rect(0, 0, w - 1, w - 1, 25)
    pcall(function() import('/lua/editor/terrain.lua').ClearHistory() end)
    S.mass, S.massMin, S.massMax, S.massShape, S.hydro, S.extra, S.middle = 4, 20, 30, 'ring', 1, 0, 2
    local plan2 = LM.Plan()
    local inside = true
    for _, it in plan2.items do
        if it.z > size / 2 - 4 or it.z < 4 then inside = false end
    end
    for _, st in plan2.starts do
        if st.z > size / 2 or st.z < 0 then inside = false end
    end
    check('the plan stays inside the playable area', inside and table.getn(plan2.starts) == 4 and plan2.masses >= 14, plan2.text)
    LM.ClearPlan()

    -- the drawing follows a resized area: empty ones silently, drawn ones by Fit
    Layout.New({})
    Layout.FillRect(1, 20, 10, 40, 30, 1, false)
    local oldCell = Layout.Doc.cell
    local oldX, oldZ = Layout.ToWorld(30, 20)
    check('a drawing that covers the area is not stale', not Layout.Stale())
    Playable.Set(0, 0, size, size)
    check('a resized area makes the drawing stale', Layout.Stale() == true)
    check('a drawn layout is not moved by itself', Layout.Sync() == false and Layout.Doc.rh == 64)
    check('Fit to the area refits the canvas', Layout.Refit() == true and Layout.Doc.rw == 128 and Layout.Doc.rh == 128 and not Layout.Stale())
    local nx, nz = Layout.ToCell(oldX, oldZ)
    check('what was drawn stays at the same place on the map', Layout.Layer(1).data[math.floor(nz) * 128 + math.floor(nx) + 1] > 0.9, nx .. ', ' .. nz)
    History.Undo()
    check('undo of Fit gives the old shape back', Layout.Doc.rh == 64 and math.abs(Layout.Doc.cell - oldCell) < 1e-6 and Layout.Layer(1).data[20 * 128 + 30 + 1] == 1)
    History.Redo()
    local keep = Layout.Plain()
    Layout.New({})
    Layout.Load(keep)
    check('the shape of the canvas is saved with the drawing', Layout.Doc.rw == 128 and Layout.Doc.rh == 128 and math.abs(Layout.Doc.cell - 2) < 1e-6 and Layout.Layer(1).data[math.floor(nz) * 128 + math.floor(nx) + 1] > 0.9)
    local oldFile = { res = 128, base = 25, water = 20, seed = 1, weather = 0, layers = { { kind = 'hills', name = 'Hills', visible = true, p = {}, data = '255x4,0x16380' } } }
    Layout.Load(oldFile)
    check('a file from before (no shape) loads as the whole map', Layout.Doc.rw == 128 and Layout.Doc.rh == 128 and Layout.Doc.ox == 0 and math.abs(Layout.Doc.cell - size / 128) < 1e-6 and Layout.Layer(1).data[1] == 1)
    Layout.New({})
    Playable.Set(0, 0, size, math.floor(size / 2))
    check('an empty drawing follows the area by itself', Layout.Stale() and Layout.Sync() == true and Layout.Doc.rh == 64 and not Layout.Stale())
    while History.Depth() > depth0 do History.Undo() end
    Layout.New({})
    check('the area is back as it was', not Layout.Stale() and Layout.Doc.rw == 128 and Layout.Doc.rh == 128)

    -- ---- colour and pictures -----------------------------------------------------------------------------------------------------------------------------------------
    Layout.SetColor(1, 10, 300, -5)
    check('the colour of a layer is clamped and kept', Layout.Layer(1).color[1] == 10 and Layout.Layer(1).color[2] == 255 and Layout.Layer(1).color[3] == 0)
    local px = Layout.Pixels({})
    Layout.FillRect(1, 0, 0, 5, 5, 1, false)
    px = Layout.Pixels({})
    check('the canvas draws the layer in its own colour', math.abs(px[1] - (28 + (10 - 28) * 0.85)) < 1.5 and px[2] > 200, px[1] .. ' ' .. px[2])
    local round = Layout.Plain()
    Layout.New({})
    Layout.Load(round)
    check('the colour is saved with the layer', Layout.Layer(1).color[1] == 10 and Layout.Layer(1).color[2] == 255)

    -- a picture of 8 x 4: the left half white, the right half black (written with the image writer, read back by the importer)
    if rawget(_G, 'ed_img_write') and rawget(_G, 'ed_img_read') and rawget(_G, 'ed_field_from_table') then
        local vals = {}
        for zz = 0, 3 do
            for xx = 0, 7 do vals[zz * 8 + xx + 1] = (xx < 4) and 1 or 0 end
        end
        local pic = ed_field_from_table(8, 4, vals)
        local path = '../fieldtmp/layout_selftest.png'
        local wrote = ed_img_write(path, pic, { bits = 8, lo = 0, hi = 1 })
        Fields.Free(pic)
        check('the test picture is written', wrote == true)
        if wrote then
            Layout.New({})
            local L1 = Layout.Layer(1)
            local changed, why2 = Layout.ImportImage(1, path, { fit = 'fill' })
            check('a picture is drawn into the layer: white where it is white', changed ~= nil and L1.data[32 * 128 + 10 + 1] > 0.95 and L1.data[32 * 128 + 120 + 1] < 0.05, tostring(why2))
            History.Undo()
            check('importing a picture is one undo step', Sum(L1) == 0)
            History.Redo()
            Layout.ImportImage(1, path, { fit = 'fill', invert = true })
            check('invert draws the dark side', L1.data[32 * 128 + 10 + 1] < 0.05 and L1.data[32 * 128 + 120 + 1] > 0.95)
            Layout.ImportImage(1, path, { fit = 'fill', flipX = true })
            check('flip X mirrors the picture', L1.data[32 * 128 + 10 + 1] < 0.05 and L1.data[32 * 128 + 120 + 1] > 0.95)
            Layout.Fill(1, 0)
            Layout.ImportImage(1, path, { fit = 'fill', hard = true })
            local soft = false
            for kk = 1, table.getn(L1.data) do
                if L1.data[kk] > 0.02 and L1.data[kk] < 0.98 then soft = true break end
            end
            check('hard edge leaves only 0 and 1', not soft)
            Layout.Fill(1, 0)
            Layout.FillRect(1, 100, 100, 110, 110, 0.5, false)
            Layout.ImportImage(1, path, { fit = 'fill', add = true })
            check('add keeps what was drawn', L1.data[105 * 128 + 105 + 1] == math.floor(0.5 * 255 + 0.5) / 255 or L1.data[105 * 128 + 105 + 1] >= 0.5)
            local refused, why3 = Layout.ImportImage(1, '../fieldtmp/does_not_exist.png', {})
            check('a picture that is not there is refused with a message', refused == nil and why3 ~= nil)
            pcall(ed_file_delete, path)
        end
    else
        table.insert(lines, '  (no image natives: the picture import is skipped)')
    end
    Symmetry.CenterX, Symmetry.CenterZ = cxWas, czWas

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
