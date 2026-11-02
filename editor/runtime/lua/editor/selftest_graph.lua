-- Self test of the terrain graph (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5): the catalogue, the graph model (wires, type checks, loops, undo, copy / paste, files, the map's sidecar),
-- the evaluation (determinism, the per node cache and what it invalidates, preview against full resolution, errors, number wires), the outputs (one undo step, exact undo, a repeated build,
-- the live preview on the terrain and its revert, props), the variations and the mask view, and every sample graph. Run in the live editor:
--   return import('/lua/editor/selftest_graph.lua').Run()
-- Returns a report; the first line is PASS or FAIL. Works on the open map (flat 25 afterwards, masks cleared).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
local GRun = import('/lua/editor/graphrun.lua')
local MaskGen = import('/lua/editor/maskgen.lua')

local function Sum()
    local f = Fields.Height(1)
    local s = Fields.Checksum(f)
    Fields.Free(f)
    return s
end

local function LayerMax(layer)
    return Fields.Run(function(S)
        local mn, mx, mean = Fields.Stats(S:Stratum(layer, true))
        return mx
    end)
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
    local startProps = ed_prop_count()
    local Strata = import('/lua/editor/strata.lua')
    local hasMasks = ed_stratum_info() and true or false
    if hasMasks then for i = 1, 8 do Strata.ClearMask(i) end end
    GRun.Release()
    MaskGen.ClearPreview()
    -- counted after the live holders are let go: an open Generate workspace keeps the evaluation cache and a mask preview alive (10 fields), the clean up below frees them
    -- and "no field leaks" failed whenever the test ran with a graph on screen
    local startFields = ed_field_count()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()
    local flat = Sum()

    -- ---- the catalogue -----------------------------------------------------------------------------------------------------------------------
    local count = 0
    local bad = {}
    for id, d in Nodes.Defs do
        count = count + 1
        local okDef = type(d.eval) == 'function' and d.label and d.cat and (table.getn(d.outputs) >= 1 or d.frame)
        local keys = {}
        for _, p in d.params do
            if keys[p.key] then okDef = false end
            keys[p.key] = true
            if p.kind == 'number' and not (p.min < p.max and p.default >= p.min and p.default <= p.max) then okDef = false table.insert(bad, id .. '.' .. p.key) end
            if p.kind == 'choice' then
                local found = false
                for _, x in p.ids do if x == p.default then found = true end end
                if not found then okDef = false table.insert(bad, id .. '.' .. p.key) end
            end
        end
        local names = {}
        for _, p in d.ports do
            if names[p.name] then okDef = false end
            names[p.name] = true
        end
        for _, o in d.outputs do
            if names[o.name] then okDef = false end
            names[o.name] = true
        end
        if not okDef then table.insert(bad, id) end
    end
    check('every node definition is well formed (' .. count .. ' nodes)', table.getn(bad) == 0, table.concat(bad, ', '))
    check('palette search finds erosion nodes', table.getn(Nodes.Search('erosion')) >= 4)
    check('palette search finds nothing for nonsense', table.getn(Nodes.Search('xyzzyx')) == 0)
    local inCats = 0
    for _, cat in Nodes.Cats do inCats = inCats + table.getn(Nodes.InCat(cat.id)) end
    check('every node is in a palette category', inCats == count, inCats .. ' vs ' .. count)

    -- ---- the model ---------------------------------------------------------------------------------------------------------------------------
    Graph.New('t')
    local a = Graph.Add('perlin', 0, 0)
    local b = Graph.Add('range', 200, 0)
    local c = Graph.Add('out_height', 400, 0)
    local d = Graph.Add('blur', 200, 150)
    local num = Graph.Add('number', 0, 300)
    check('nodes get unique ids', a.id ~= b.id and b.id ~= c.id and c.id ~= d.id)
    check('connect output to input', Graph.Connect(a.id, 'out', b.id, 'a') == true)
    check('connect again', Graph.Connect(b.id, 'out', c.id, 'a') == true)
    check('a field does not fit a number port', Graph.Connect(a.id, 'out', b.id, 'lo') == false)
    check('a number fits a number port', Graph.Connect(num.id, 'out', b.id, 'lo') == true)
    check('a number does not fit a field input', Graph.Connect(num.id, 'out', b.id, 'a') == false)
    check('no input of that name', Graph.Connect(a.id, 'out', b.id, 'zzz') == false)
    check('a node cannot feed itself', Graph.Connect(b.id, 'out', b.id, 'a') == false)
    check('a loop is refused', Graph.Connect(c.id, 'view', a.id, 'scale') == false and Graph.Connect(b.id, 'out', a.id, 'scale') == false)
    Graph.Connect(a.id, 'out', d.id, 'a')
    Graph.Connect(d.id, 'out', c.id, 'a')                      -- replaces the wire from b
    check('an input takes one wire', Graph.WireInto(c.id, 'a')[1] == d.id and table.getn(Graph.Current.wires) == 4)
    local order = Graph.Order()
    local pos = {}
    for i, id in order do pos[id] = i end
    check('evaluation order puts inputs first', pos[a.id] < pos[d.id] and pos[d.id] < pos[c.id] and pos[num.id] < pos[b.id])
    Graph.Disconnect(c.id, 'a')
    check('disconnect', Graph.WireInto(c.id, 'a') == nil)
    local problems = Graph.Validate()
    local mentions = false
    for _, p in problems do if p.id == c.id then mentions = true end end
    check('validate reports the unconnected output', mentions)
    Graph.Connect(d.id, 'out', c.id, 'a')

    local before = Graph.Text()
    Graph.SetParam(a.id, 'scale', 70, true)
    Graph.SetParam(a.id, 'scale', 80, true)
    Graph.SetParam(a.id, 'scale', 90, true)
    local undoCount = Graph.UndoDepth()
    Graph.Undo()
    check('one slider drag is one undo entry', Graph.NodeById(a.id).params.scale == 120 and Graph.UndoDepth() == undoCount - 1, Graph.NodeById(a.id).params.scale)
    Graph.Redo()
    check('redo', Graph.NodeById(a.id).params.scale == 90)
    Graph.Undo()
    check('undo restores the whole graph', Graph.Text() == before)

    Graph.SetLabel(b.id, 'my range')
    local text = Graph.Text()
    local data = Graph.FromText(text)
    local g2 = Graph.Normalize(data)
    check('text round trip', Graph.Text(g2) == text)
    check('labels are kept', Graph.NodeById(b.id).label == 'my range' and g2.nodes[2].label == 'my range')

    local sidecar = Graph.SidecarText()
    local env = {}
    local chunk = loadstring(sidecar, '=sidecar')
    setfenv(chunk, env)
    chunk()
    check('sidecar round trip', type(env.Graph) == 'table' and Graph.Text(Graph.Normalize(env.Graph)) == text)

    Graph.Select({ a.id, d.id }, false)
    Graph.CopyNodes(Graph.Sel)
    local nodesBefore = table.getn(Graph.Current.nodes)
    local made = Graph.Paste(500, 400)
    check('paste adds the copied nodes and their wire', table.getn(made) == 2 and table.getn(Graph.Current.nodes) == nodesBefore + 2 and Graph.WireInto(made[2], 'a') ~= nil and Graph.WireInto(made[2], 'a')[1] == made[1])
    local dup = Graph.Duplicate(Graph.Sel)
    check('duplicate', table.getn(dup) == 2 and table.getn(Graph.Current.nodes) == nodesBefore + 4)
    Graph.Undo() Graph.Undo()
    check('paste and duplicate undo', table.getn(Graph.Current.nodes) == nodesBefore)
    local wiresBefore = table.getn(Graph.Current.wires)
    Graph.Remove({ b.id })
    check('removing a node removes its wires', Graph.NodeById(b.id) == nil and table.getn(Graph.Current.wires) < wiresBefore)
    Graph.Undo()
    check('undo of a removal brings node and wires back', Graph.NodeById(b.id) ~= nil and table.getn(Graph.Current.wires) == wiresBefore)

    local saved = Graph.Save('selftest_graph')
    local names = Graph.Files()
    local listed = false
    for _, n in names do if n == 'selftest_graph' then listed = true end end
    check('save and list a graph file', saved and listed)
    Graph.Edit('wipe', function() Graph.Current.nodes = {} Graph.Current.wires = {} end)
    local loaded = Graph.LoadFile('selftest_graph')
    check('open a graph file', loaded and table.getn(Graph.Current.nodes) == nodesBefore)

    -- a graph file with a loop (hand made): validate reports it, evaluation does not hang
    local loopData = { nodes = { { id = 1, type = 'blur', x = 0, y = 0, params = {} }, { id = 2, type = 'blur', x = 0, y = 0, params = {} } }, wires = { { 1, 'out', 2, 'a' }, { 2, 'out', 1, 'a' } } }
    Graph.Replace(loopData, 'loop')
    local loopReported = false
    for _, p in Graph.Validate() do if not p.id then loopReported = true end end
    check('a loop in a file is reported', loopReported)
    local okLoop = pcall(function() GRun.Refresh(true) end)
    check('a loop does not break evaluation', okLoop)

    -- ---- evaluation --------------------------------------------------------------------------------------------------------------------------
    Graph.New('eval')
    local p1 = Graph.Add('perlin', 0, 0, { scale = 60, octaves = 4 })
    local r1 = Graph.Add('range', 200, 0, { lo = 10, hi = 50 })
    local bl = Graph.Add('blur', 400, 0, { radius = 3 })
    local oh = Graph.Add('out_height', 600, 0)
    local vo = Graph.Add('voronoi', 0, 200, { scale = 50 })
    local ss = Graph.Add('smoothstep', 200, 200, { edge0 = 0.1, edge1 = 0.6 })
    local ol = Graph.Add('out_layer', 400, 200, { layer = 2 })
    Graph.Connect(p1.id, 'out', r1.id, 'a')
    Graph.Connect(r1.id, 'out', bl.id, 'a')
    Graph.Connect(bl.id, 'out', oh.id, 'a')
    Graph.Connect(vo.id, 'out', ss.id, 'a')
    Graph.Connect(ss.id, 'out', ol.id, 'a')
    local rep = GRun.Refresh(true)
    check('first evaluation runs every node', rep.evaluated == 7 and rep.cached == 0 and next(rep.errors) == nil, rep.evaluated .. ' / ' .. rep.cached)
    rep = GRun.Refresh(true)
    check('second evaluation is all cached', rep.evaluated == 0 and rep.cached == 7, rep.evaluated .. ' / ' .. rep.cached)
    Graph.SetParam(bl.id, 'radius', 5)
    rep = GRun.Refresh()
    check('a changed node re-runs itself and what is downstream only', rep.evaluated == 2 and rep.cached == 5, rep.evaluated .. ' / ' .. rep.cached)
    Graph.SetParam(r1.id, 'hi', 60)
    rep = GRun.Refresh()
    check('a change upstream re-runs the chain below it', rep.evaluated == 3 and rep.cached == 4, rep.evaluated .. ' / ' .. rep.cached)
    Graph.SetParam(r1.id, 'hi', 50)
    Graph.SetParam(bl.id, 'radius', 3)
    rep = GRun.Refresh()
    check('putting the values back re-runs (new versions) but works', rep.evaluated == 3, rep.evaluated)
    Graph.SetSeed(5)
    rep = GRun.Refresh()
    check('the graph seed re-runs only the seeded nodes and what depends on them', rep.evaluated == 7, rep.evaluated)
    -- an unseeded source stays cached when the seed changes
    local cst = Graph.Add('const', 0, 400, { value = 4 })
    GRun.Refresh()
    Graph.SetSeed(6)
    rep = GRun.Refresh()
    local constEntry = GRun.Main:Entry(cst.id)
    check('a node without a seed ignores the graph seed', rep.cached >= 1 and constEntry and constEntry.ver ~= nil)
    Graph.Remove({ cst.id })
    Graph.SetSeed(1)

    -- determinism: a fresh run gives the same fields as the cached one
    GRun.Refresh(true)
    local fresh = GRun.NewRun{ step = GRun.GetMain().step, thumbs = false }
    fresh:Evaluate()
    local same = true
    for _, n in Graph.Current.nodes do
        local x, y = GRun.Main:Value(n.id, 'view') or GRun.Main:Value(n.id, 'out'), fresh:Value(n.id, 'view') or fresh:Value(n.id, 'out')
        if x and y and Fields.Checksum(x) ~= Fields.Checksum(y) then same = false end
    end
    fresh:Free()
    check('evaluation is deterministic (fresh run = cached run, every node)', same)

    -- preview against full resolution: noise depends on the world position only
    local small = GRun.NewRun{ step = 4, thumbs = false, only = { [p1.id] = true, [r1.id] = true } }
    small:Evaluate()
    local big = GRun.NewRun{ step = 1, thumbs = false, only = { [p1.id] = true, [r1.id] = true } }
    big:Evaluate()
    local fs, fb = small:Value(r1.id, 'out'), big:Value(r1.id, 'out')
    local match = true
    for _, ij in { { 3, 5 }, { 10, 20 }, { 30, 30 }, { 50, 7 } } do
        -- the two runs place the sample positions with different float rounding (differences of about 1e-5 on heights of 30): equal to a thousandth of a unit is the same noise
        if math.abs(Fields.Get(fs, ij[1], ij[2]) - Fields.Get(fb, ij[1] * 4, ij[2] * 4)) > 0.001 then match = false end
    end
    local sw = Fields.Info(fs)
    small:Free()
    big:Free()
    check('the 1/4 resolution preview samples the same noise as the full run', match and sw < w)

    -- the Symmetrize node: fresh nodes get a soft seam, the master part is clamped to the parts the symmetry has, the result is symmetric and a turn has no hard cut at the borders
    do
        local sy = Graph.Add('symmetrize', 600, 400, { mode = 'rot4' })
        check('a fresh Symmetrize node has a soft seam by default', sy.params.seam == 24, tostring(sy.params.seam))
        check('Symmetrize wedge counts', Nodes.SymWedges('rot4') == 4 and Nodes.SymWedges('rot2') == 2 and Nodes.SymWedges('mirror_x') == 2 and Nodes.SymWedges('mirror_xz') == 4
              and Nodes.SymWedges('diag_both') == 4 and Nodes.SymWedges('rotn', 5) == 5)
        Graph.Connect(p1.id, 'out', sy.id, 'a')
        Graph.SetParam(sy.id, 'side', 3)
        GRun.Refresh()
        local f3 = GRun.Main:Value(sy.id, 'out')
        local c3 = f3 and Fields.Checksum(f3)
        Graph.SetParam(sy.id, 'side', 9)
        GRun.Refresh()
        local f9 = GRun.Main:Value(sy.id, 'out')
        check('a master part past the last one is brought back to the last (side 9 of 4 = side 3)', c3 ~= nil and f9 ~= nil and Fields.Checksum(f9) == c3)
        check('the canvas text names the part', string.find(Nodes.Describe(Graph.NodeById(sy.id)), 'part 3 of 4', 1, true) ~= nil, Nodes.Describe(Graph.NodeById(sy.id)))
        Graph.SetParam(sy.id, 'side', 0)
        Graph.SetParam(sy.id, 'seam', 0)
        GRun.Refresh()
        local fh = GRun.Main:Value(sy.id, 'out')
        local fw, fhh = Fields.Info(fh)
        local okSym = true
        if fw == fhh then
            for _, xz in { { 3, 5 }, { 10, 20 }, { 30, 7 }, { 40, 41 } } do
                local x, z = xz[1], xz[2]
                local v = Fields.Get(fh, x, z)
                okSym = okSym and v == Fields.Get(fh, fw - 1 - z, x) and v == Fields.Get(fh, fw - 1 - x, fw - 1 - z) and v == Fields.Get(fh, z, fw - 1 - x)
            end
        end
        check('Turn by 90 is symmetric under quarter turns', okSym)
        local sumH = Fields.Checksum(fh)      -- (the next Refresh frees the handle)
        Graph.SetParam(sy.id, 'seam', 24)
        GRun.Refresh()
        local fs2 = GRun.Main:Value(sy.id, 'out')
        check('the soft seam changes the borders', fs2 ~= nil and Fields.Checksum(fs2) ~= sumH)
        Graph.Remove({ sy.id })
        GRun.Refresh()
    end

    -- errors
    local th = Graph.Add('thermal', 0, 500)
    Graph.Connect(th.id, 'out', oh.id, 'mask')
    rep = GRun.Refresh()
    local own = rep.errors[th.id]
    check('a missing input is an error of that node', own and string.find(own, 'not connected', 1, true))
    local ohEntry = GRun.Main:Entry(oh.id)
    check('the node downstream waits (no value)', ohEntry and ohEntry.err and ohEntry.upstream)
    local built, why = GRun.Build()
    check('build refuses a graph with an error and says which node', built == nil and why and string.find(why, 'Thermal', 1, true), why)
    Graph.Remove({ th.id })

    -- number wires
    local nb = Graph.Add('number', 600, 400, { value = 33 })
    local cs = Graph.Add('const', 800, 400, { value = 1 })
    Graph.Connect(nb.id, 'out', cs.id, 'value')
    GRun.Refresh()
    local cf = GRun.Main:Value(cs.id, 'out')
    local mn, mx = Fields.Stats(cf)
    check('a number wire drives a parameter', mn == 33 and mx == 33, mn)
    Graph.SetOff(cs.id, true)
    GRun.Refresh()
    local e2 = GRun.Main:Entry(cs.id)
    check('a bypassed generator gives zero', e2 and e2.outs and Fields.Stats(e2.outs.out) == 0)
    Graph.Remove({ nb.id, cs.id })

    -- ---- outputs: build, undo, redo ------------------------------------------------------------------------------------------------------------
    GRun.Refresh(true)
    local depth0 = History.Depth()
    local r, err = GRun.Build()
    check('build works', r ~= nil, err)
    local built1 = Sum()
    check('build changes the heights and one layer, as ONE undo step', r and r.changed > 0 and r.layers == 1 and History.Depth() == depth0 + 1, r and (r.changed .. ' ' .. r.layers .. ' ' .. (History.Depth() - depth0)))
    check('the layer mask was written', (not hasMasks) or LayerMax(2) > 0.5)
    local r2 = GRun.Build()
    check('a second build starts from the same ground (same terrain, no new entry)', Sum() == built1 and History.Depth() == depth0 + 1)
    History.Undo()
    check('undo restores the heights exactly', Sum() == flat)
    check('undo restores the layer', (not hasMasks) or LayerMax(2) == 0)
    History.Redo()
    check('redo builds again, bit for bit', Sum() == built1)
    History.Undo()

    -- the preview on the terrain
    local n, perr = GRun.ShowOnTerrain()
    check('the preview shows on the terrain', n and n > 0 and Sum() ~= flat and GRun.TerrainShown(), perr)
    check('the preview is not a history entry', History.Depth() == depth0)
    local was = History.Undo()
    check('undo with a preview showing only takes the preview off', was == 'preview' and Sum() == flat and not GRun.TerrainShown(), tostring(was))
    GRun.ShowOnTerrain()
    check('revert puts the ground back exactly', GRun.RevertTerrain() and Sum() == flat)
    GRun.ShowOnTerrain()
    local rb = GRun.Build()
    check('build after a preview starts from the untouched ground', rb ~= nil and Sum() == built1)
    History.Undo()

    -- add mode
    Graph.SetParam(oh.id, 'mode', 'add')
    GRun.Build()
    local added = Sum()
    local fmin, fmax = Fields.Run(function(S) local f = S:Height(1) local a, b = Fields.Stats(f) return a, b end)
    check('add mode adds to the ground (25 + 10..60)', fmin >= 25 + 9 and fmax <= 25 + 61 and fmax > fmin, fmin .. ' ' .. fmax)
    History.Undo()
    Graph.SetParam(oh.id, 'mode', 'replace')

    -- a mask on the height output limits the effect
    local half = Graph.Add('gradient', 600, 500, { angle = 0, lo = 0, hi = 1 })
    local cut = Graph.Add('threshold', 800, 500, { value = 0.5 })
    Graph.Connect(half.id, 'out', cut.id, 'a')
    Graph.Connect(cut.id, 'out', oh.id, 'mask')
    local rm = GRun.Build()
    local left, right = Fields.Run(function(S)
        local f = S:Height(1)
        return Fields.Get(f, 20, 100), Fields.Get(f, w - 20, 100)
    end)
    check('a mask on the height output keeps the unmasked half as it was', left == 25 and right ~= 25, tostring(left) .. ' ' .. tostring(right))
    History.Undo()
    Graph.Remove({ half.id, cut.id })

    -- ---- props --------------------------------------------------------------------------------------------------------------------------------
    local sc = Graph.Add('out_scatter', 800, 0, { count = 60, minDist = 8, slopeMax = 90, underWater = true, margin = 4 })
    Graph.SetParam(sc.id, 'entries', { { bp = '/env/common/props/markers/M_Blank_prop.bp', weight = 1 } })
    Graph.Connect(ss.id, 'out', sc.id, 'a')
    depth0 = History.Depth()
    local rp = GRun.Build()
    check('props scatter as part of the build', rp and rp.props >= 20 and ed_prop_count() == startProps + rp.props, rp and rp.props)
    check('heights, layer and props are ONE undo step', History.Depth() == depth0 + 1)
    History.Undo()
    check('one undo removes the props too', ed_prop_count() == startProps and Sum() == flat, ed_prop_count() .. ' vs ' .. startProps)
    Graph.Remove({ sc.id })

    -- ---- variations and the mask view ---------------------------------------------------------------------------------------------------------------
    local gal = GRun.Gallery(1, 3, 48)
    local pics = 0
    for _, g in gal do if g.path then pics = pics + 1 end end
    check('the gallery makes a picture per seed', table.getn(gal) == 3 and pics == 3 and gal[1].seed == 1 and gal[3].seed == 3, pics)
    local ra = GRun.NewRun{ step = 4, thumbs = false, seed = 1 }
    ra:Evaluate()
    local rb2 = GRun.NewRun{ step = 4, thumbs = false, seed = 2 }
    rb2:Evaluate()
    local rc = GRun.NewRun{ step = 4, thumbs = false, seed = 1 }
    rc:Evaluate()
    local ca, cb, cc = Fields.Checksum(ra:Value(oh.id, 'view')), Fields.Checksum(rb2:Value(oh.id, 'view')), Fields.Checksum(rc:Value(oh.id, 'view'))
    ra:Free() rb2:Free() rc:Free()
    check('another seed gives another terrain, the same seed the same', ca ~= cb and ca == cc)
    GRun.Refresh(true)
    local okMask = GRun.ShowMask(ss.id)
    check('mask view shows a node output', okMask and MaskGen.Preview.field and GRun.MaskShown())
    GRun.HideMask()
    check('mask view off', not MaskGen.Preview.field and not GRun.MaskShown())

    -- ---- every node type ----------------------------------------------------------------------------------------------------------------------
    local used = {}
    local realOp = Fields.Op
    Fields.Op = function(name, p)
        used[name] = true
        return realOp(name, p)
    end
    local realMulti = Fields.OpMulti                                 -- the T7 nodes with extra outputs (and the colour ramp) go through this
    Fields.OpMulti = function(name, p)
        used[name] = true
        return realMulti(name, p)
    end
    Graph.New('all')
    local srcH = Graph.Add('perlin', 0, 0)
    local srcR = Graph.Add('range', 0, 0, { lo = 20, hi = 80 })
    Graph.Connect(srcH.id, 'out', srcR.id, 'a')
    local srcPath = Graph.Add('path_line', 0, 0)
    local srcNum = Graph.Add('number', 0, 0)
    local srcColor = Graph.Add('color_ramp', 0, 0)                      -- the source of the `color` ports (stage T7)
    Graph.Connect(srcR.id, 'out', srcColor.id, 'a')
    local expectError = { image = true, path_drawn = true, out_scatter = false, external_terrain = true }       -- (no file chosen)
    local nodeErrors = {}
    local tested = 0
    for id, def in Nodes.Defs do
        if id ~= 'perlin' and id ~= 'range' and id ~= 'number' and id ~= 'path_line' then
            local node = Graph.Add(id, 0, 0)
            local ok = true
            for _, port in def.inputs do
                local src
                if port.type == 'points' then src = { srcPath.id, 'out' }
                elseif port.type == 'number' then src = { srcNum.id, 'out' }
                elseif port.type == 'color' then src = { srcColor.id, 'rgba' }
                else src = { srcR.id, 'out' } end
                if not Graph.Connect(src[1], src[2], node.id, port.name) then ok = false end
            end
            check('wiring the inputs of ' .. id, ok)
            tested = tested + 1
        end
    end
    for _, what in { 'along', 'u', 'signed' } do                       -- the other outputs of the path distance node (path_along, path_u)
        local nd = Graph.Add('path_dist', 0, 0, { what = what })
        Graph.Connect(srcPath.id, 'out', nd.id, 'pts')
    end
    local repAll = GRun.Refresh(true)
    for nid, msg in repAll.errors do
        local n = Graph.NodeById(nid)
        if not expectError[n.type] then table.insert(nodeErrors, n.type .. ': ' .. msg) end
    end
    check('every node type evaluates with default parameters (' .. tested .. ' tested)', table.getn(nodeErrors) == 0, table.concat(nodeErrors, ' | '))
    Fields.Op = realOp
    Fields.OpMulti = realMulti
    used.erode_hydraulic, used.erode_droplet, used.erode_stream = true, true, true
    local dishonest = {}
    local exempt = { crop = true, path_paste = true, resize = true, amplitude = true, keep_side = true, terrain_mix = true, downsample = true }      -- downsample: graphrun.lua Run:Conform (a node that writes into the map's grid gets the oversampled fields averaged down)
    for op, _ in Nodes.Covers do
        if not used[op] and not exempt[op] then table.insert(dishonest, op) end
    end
    check('every op a node claims to cover is really used by a node (Nodes.Covers)', table.getn(dishonest) == 0, table.concat(dishonest, ', '))
    local unreachable, rawOnly = {}, {}
    for _, op in Fields.OpNames() do
        if not Nodes.Covers[op] then
            if Nodes.Defs['raw_' .. op] then table.insert(rawOnly, op) else table.insert(unreachable, op) end
        end
    end
    check('every op of the field engine is in the palette (a dedicated node, or a generic one made from the engine catalogue)', table.getn(unreachable) == 0, table.concat(unreachable, ', '))
    if table.getn(rawOnly) > 0 then table.insert(lines, '  note ops with a generic node only (give them a dedicated one): ' .. table.concat(rawOnly, ', ')) end
    -- the generic node: the same result as the dedicated one
    Graph.New('raw')
    local rs = Graph.Add('perlin', 0, 0, { scale = 40 })
    local rr = Graph.Add('range', 0, 0, { lo = 10, hi = 60 })
    Graph.Connect(rs.id, 'out', rr.id, 'a')
    local gdef = Nodes.MakeRaw('blur')
    local gb = Graph.Add('raw_blur', 0, 0, { args = 'radius=3.5' })
    local db = Graph.Add('blur', 0, 0, { radius = 3.5 })
    Graph.Connect(rr.id, 'out', gb.id, 'a')
    Graph.Connect(rr.id, 'out', db.id, 'a')
    Nodes.MakeRaw('gradient')
    local gn = Graph.Add('raw_gradient', 0, 0, { args = 'angle=30,lo=0.1,hi=0.9' })
    local gd = Graph.Add('gradient', 0, 0, { angle = 30, lo = 0.1, hi = 0.9 })
    GRun.Refresh(true)
    local ga, gb2 = GRun.Main:Value(gb.id, 'out'), GRun.Main:Value(db.id, 'out')
    check('a generic engine node gives the same field as the dedicated node (blur, wired input)', ga and gb2 and Fields.Checksum(ga) == Fields.Checksum(gb2))
    local g1, g2 = GRun.Main:Value(gn.id, 'out'), GRun.Main:Value(gd.id, 'out')
    check('a generic node without a wired input takes the graph grid (gradient)', gdef ~= nil and g1 and g2 and Fields.Checksum(g1) == Fields.Checksum(g2))
    local pa = Nodes.ParseArgs('a=1.5,mode=x,pts=1:2;3:4,flag=0')
    check('generic node parameters parse (numbers, words, lists)', pa.a == 1.5 and pa.mode == 'x' and table.getn(pa.pts) == 4 and pa.pts[3] == 3 and pa.flag == 0)
    Graph.New('untitled')
    Graph.New('untitled')
    GRun.Release()

    -- ---- the canvas (drag logic without a mouse) --------------------------------------------------------------------------------------------
    local okShell, shell = pcall(import, '/lua/editor/gui/shell.lua')
    local previousWorkspace = okShell and shell.S and shell.S.current
    if okShell and previousWorkspace then
        pcall(shell.ShowWorkspace, 'Generate')
        local canvasMod = import('/lua/editor/gui/panels_graph.lua')
        local Pn = canvasMod.live.canvas
        check('the Generate workspace shows the canvas', Pn ~= nil and not Pn.dead and Pn.cw > 100)
        if Pn and Pn.cw > 100 then
            Graph.New('canvas')
            local n1 = Graph.Add('perlin', 40, 40)
            local n2 = Graph.Add('range', 360, 40)
            local n3 = Graph.Add('out_height', 680, 40)
            local n4 = Graph.Add('voronoi', 40, 240)
            Graph.Connect(n1.id, 'out', n2.id, 'a')
            Pn:SetView(10, 10, 1)
            Pn:Tick(true)
            local nviews = 0
            for _ in Pn.views do nviews = nviews + 1 end
            check('every node has a view', nviews == 4, nviews)
            -- move a node
            local undo0 = Graph.UndoDepth()
            Pn.DragNodeBegin(100, 100, n2.id, false)
            Pn.DragNode(100 + 53, 100 + 21)
            Pn.DragNode(100 + 77, 100 + 41)
            Pn.DragNodeEnd()
            check('dragging a node moves it (snapped to the 8 grid) as one undo entry', Graph.NodeById(n2.id).x == 440 and Graph.NodeById(n2.id).y == 80 and Graph.UndoDepth() == undo0 + 1, Graph.NodeById(n2.id).x .. ',' .. Graph.NodeById(n2.id).y)
            Graph.Undo()
            check('undo of a move', Graph.NodeById(n2.id).x == 360 and Graph.NodeById(n2.id).y == 40)
            -- wire from the output of range to the input of out_height by a drag
            local ox, oy = Pn.bg.Left(), Pn.bg.Top()
            local view = Graph.Current.view
            local function PortXY(node, side, index)
                local row = 22 + 6 + (index - 1) * 17 + 8.5
                return ox + view.x + node.x * view.zoom + (side == 'out' and 160 * view.zoom or 0), oy + view.y + (node.y + row) * view.zoom
            end
            local fx, fy = PortXY(Graph.NodeById(n2.id), 'out', 1)
            local tx, ty = PortXY(Graph.NodeById(n3.id), 'in', 1)
            Pn.DragWireBegin(fx, fy, n2.id, 'out', 'out')
            Pn.DragWire(tx - 30, ty)
            Pn.DragWireEnd(tx + 1, ty + 1)
            check('dragging from an output to an input wires them', Graph.WireInto(n3.id, 'a') ~= nil and Graph.WireInto(n3.id, 'a')[1] == n2.id)
            -- take the wire off by dragging the input away
            Pn.DragWireBegin(tx, ty, n3.id, 'in', 'a')
            Pn.DragWireEnd(tx + 100, ty + 150)
            check('dragging a wired input into the empty takes the wire off', Graph.WireInto(n3.id, 'a') == nil)
            -- a wrong connection is refused
            local sx, sy = PortXY(Graph.NodeById(n4.id), 'out', 1)
            Pn.DragWireBegin(sx, sy, n4.id, 'out', 'out')
            local bx, by = PortXY(Graph.NodeById(n1.id), 'in', 1)
            Pn.DragWireEnd(bx, by)
            check('dropping on a port that does not fit connects nothing', Graph.WireInto(n1.id, 'scale') == nil)
            -- box select
            Graph.ClearSelection()
            Pn.DragBoxBegin(ox + 20, oy + 20, false)
            Pn.DragBox(ox + 450, oy + 200)
            Pn.DragBoxEnd(ox + 450, oy + 200)
            check('box select takes the nodes it touches', Graph.Sel[n1.id] and Graph.Sel[n2.id] and not Graph.Sel[n3.id] and not Graph.Sel[n4.id])
            Pn.DragBoxBegin(ox + 600, oy + 20, true)
            Pn.DragBox(ox + 900, oy + 200)
            Pn.DragBoxEnd(ox + 900, oy + 200)
            check('shift box select adds', Graph.Sel[n1.id] and Graph.Sel[n3.id])
            -- moving a selection moves all of it
            Pn.DragNodeBegin(0, 0, n1.id, false)
            check('pressing a selected node keeps the selection', Graph.Sel[n1.id] and Graph.Sel[n3.id])
            Pn.DragNode(16, 8)
            Pn.DragNodeEnd()
            check('the whole selection moves together', Graph.NodeById(n3.id).y == 48 and Graph.NodeById(n1.id).y == 48, Graph.NodeById(n3.id).y)
            Graph.Undo()
            -- zoom keeps the point under the pointer, pan moves the view
            Pn:SetView(10, 10, 1)
            local mx, my = ox + 300, oy + 200
            local gx0 = (300 - Graph.Current.view.x) / Graph.Current.view.zoom
            Pn.Wheel({ MouseX = mx, MouseY = my, WheelRotation = 1 })
            local gx1 = (300 - Graph.Current.view.x) / Graph.Current.view.zoom
            check('the wheel zooms about the pointer', Graph.Current.view.zoom > 1.1 and math.abs(gx1 - gx0) < 0.01, Graph.Current.view.zoom)
            local vx0 = Graph.Current.view.x
            Pn.DragPanBegin(100, 100)
            Pn.DragPan(130, 90)
            check('panning moves the view', Graph.Current.view.x == vx0 + 30)
            Pn:Fit()
            check('fit shows every node', Graph.Current.view.zoom <= 1)
            -- the text of a node (title, status line, port names) never reaches past the node's right edge: not on the first layout, after a parameter change, a zoom and a resize
            do
                local def = Nodes.Defs['erode_droplet']
                local pkey, pmax
                if def then
                    for _, p in def.params do
                        if not pkey and p.kind == 'number' and not p.seed then pkey, pmax = p.key, p.max end
                    end
                end
                local ea = Graph.Add('erode_droplet', 40, 40)
                if ea then ea.label = 'A hydraulic erosion node with a very long title' end
                local eb = Graph.Add('out_height', 360, 40)
                if not ea or not eb then return 'FAIL (could not add the nodes of the text-fit check)' end
                local overs = {}
                local function Overflow(when)
                    local bad = {}
                    for id, vw in Pn.views do
                        if vw.frame ~= true and vw.state ~= 'off' and vw.state ~= 'new' then
                            local right = vw.frame.Left() + vw.frame.Width()
                            local list = { vw.title, vw.status }
                            for _, port in vw.ins do table.insert(list, port.label) end
                            for _, port in vw.outs do table.insert(list, port.label) end
                            for _, ctl in list do
                                if not ctl:IsHidden() and ctl.Left() + ctl.Width() > right + 1 then
                                    table.insert(bad, id .. ':' .. ctl:GetText())
                                end
                            end
                        end
                    end
                    if table.getn(bad) > 0 then table.insert(overs, when .. ' [' .. table.concat(bad, ' | ') .. ']') end
                end
                Pn:SetView(10, 10, 1)
                Pn:Layout()
                Overflow('first layout')
                Pn:Tick(true)
                Overflow('after the status text arrived')
                if pkey then
                    Graph.SetParam(ea.id, pkey, pmax)
                    Pn:Tick(true)
                    Overflow('after a parameter change')
                end
                for _, z in { 0.8, 1.6, 1 } do
                    Pn:SetView(10, 10, z)          -- only lays out, as the wheel and Fit do
                    Overflow('after a zoom to ' .. z)
                end
                local w0, h0 = Pn.w, Pn.h
                Pn:OnResize(math.floor(w0 * 0.6), h0)
                Overflow('after a resize')
                Pn:OnResize(w0, h0)
                Overflow('after the resize back')
                check('node text stays inside its node (first layout, parameter change, zoom, resize)', table.getn(overs) == 0, table.concat(overs, '; '))
                Graph.Remove({ ea.id, eb.id })
                Pn:SetView(10, 10, 1)
                Pn:Tick(true)
            end
            -- a click on a wire finds it
            Pn:SetView(10, 10, 1)
            Graph.Connect(n1.id, 'out', n2.id, 'a')
            Pn:Layout()
            view = Graph.Current.view
            local fx2, fy2 = PortXY(Graph.NodeById(n1.id), 'out', 1)
            local wi = Pn.HitWire(fx2 - ox + 14, fy2 - oy)
            check('a wire is found by a click near it', wi == 1, tostring(wi))
            -- a frame carries the nodes inside it
            local fr = Graph.Add('frame', 0, 0, { w = 400, h = 300, title = 'Group' })
            Graph.ClearSelection()
            Pn:Layout()
            local n1x, n2x, n3x = Graph.NodeById(n1.id).x, Graph.NodeById(n2.id).x, Graph.NodeById(n3.id).x
            Pn.DragNodeBegin(0, 0, fr.id, false)
            Pn.DragNode(48, 0)
            Pn.DragNodeEnd()
            check('a frame moves the nodes inside it, not the ones outside', Graph.NodeById(n1.id).x == n1x + 48 and Graph.NodeById(n3.id).x == n3x, Graph.NodeById(n1.id).x .. ' ' .. Graph.NodeById(n3.id).x)
            local v = Pn.views[fr.id]
            check('a frame has a view and no ports', v ~= nil and v.frame == true and table.getn(Nodes.Inputs('frame')) == 0)
            Graph.Remove({ fr.id })
            Graph.Place({ [n1.id] = { n1x, Graph.NodeById(n1.id).y }, [n2.id] = { n2x, Graph.NodeById(n2.id).y } })
            -- the inspector builds for every node type
            local insp = import('/lua/editor/gui/panels_graphinspector.lua').live.inspector
            local failed = {}
            if insp then
                for id2, _ in Nodes.Defs do
                    local nn = Graph.Add(id2, 0, 600)
                    Graph.SelectOne(nn.id)
                    local okb, errb = pcall(function() insp.key = false insp:Refresh() end)
                    if not okb then table.insert(failed, id2 .. ': ' .. tostring(errb)) end
                    Graph.Remove({ nn.id })
                end
            end
            check('the inspector builds for every node type', insp ~= nil and table.getn(failed) == 0, table.concat(failed, ' | '))
            if insp then
                local sn = Graph.Add('out_scatter', 0, 600)
                Graph.SetParam(sn.id, 'entries', { { bp = '/env/common/props/markers/M_Blank_prop.bp', weight = 2 }, { bp = '/env/x/props/rock.bp', weight = 1 } })
                Graph.SelectOne(sn.id)
                local okp, errp = pcall(function() insp.key = false insp:Refresh() insp.list:Refresh() insp.propSel = 2 insp.list:Refresh() end)
                check('the inspector shows the props list of a scatter output', okp and insp.list ~= nil, errp)
                Graph.Remove({ sn.id })
                Graph.ClearSelection()
                insp.key = false
                insp:Refresh()
            end
            Graph.ClearSelection()
            -- the palette adds a node and wires it to the selected one
            local pal = import('/lua/editor/gui/panels_graphpalette.lua')
            Graph.SelectOne(n2.id)
            local added = pal.AddNode('blur')
            check('the palette adds a node next to the selection, wired to it', added and Graph.WireInto(added.id, 'a') ~= nil and Graph.WireInto(added.id, 'a')[1] == n2.id and added.x > Graph.NodeById(n2.id).x)
            -- live preview on the terrain follows the graph
            Graph.Remove({ added.id })
            Graph.Connect(n2.id, 'out', n3.id, 'a')
            canvasMod.state.onTerrain = true
            canvasMod.state.lastShow = 0
            Pn:Tick(true)
            Graph.SetParam(n2.id, 'hi', 70)
            canvasMod.state.lastShow = 0
            Pn:Tick()
            check('live preview puts the graph on the terrain', GRun.TerrainShown() and Sum() ~= flat)
            canvasMod.state.onTerrain = false
            GRun.RevertTerrain()
            check('revert takes it off', Sum() == flat)
            -- the status text wraps inside the panel (at most 3 lines, the full text is in the Console) and the canvas gives up exactly its height
            canvasMod.state.text = 'built'
            Pn:Tick(true)
            local ch1, h1 = Pn.ch, Pn.statusH
            canvasMod.state.text = 'not built: ' .. string.rep('a very long failure text ', 30) .. 'C:\\some\\long\\path\\' .. string.rep('x', 200) .. '\nstack traceback:\n\tgraphrun.lua:767: in function f'
            Pn:Tick(true)
            local nl = table.getn(Pn.statusLines)
            check('a long status text wraps into 2 or 3 lines', nl >= 2 and nl <= 3, nl)
            local widest = 0
            for _, l in Pn.statusLines do widest = math.max(widest, l.Width()) end
            check('the status lines stay inside the panel', widest <= Pn.w, widest .. ' > ' .. Pn.w)
            check('the canvas is shorter by what the status needs', Pn.statusH > h1 and Pn.ch < ch1 and Pn.toolbarH >= Pn.statusY + Pn.statusH, Pn.ch .. ' ' .. ch1)
            canvasMod.state.warnText, canvasMod.state.shaderWarn = canvasMod.state.text, true
            Pn:Tick(true)
            check('a shader warning in the status adds the Switch shader button', Pn.bSwitch and true or false)
            canvasMod.state.warnText, canvasMod.state.shaderWarn, canvasMod.state.text = nil, false, ''
            Pn:Tick(true)
            check('and a new text takes the button away', not Pn.bSwitch)
            Graph.New('untitled')
            Pn:Tick(true)
        end
        pcall(shell.ShowWorkspace, previousWorkspace)
    else
        table.insert(lines, '  skip canvas checks (no shell)')
    end

    -- ---- the sample graphs -------------------------------------------------------------------------------------------------------------------
    local presets = Graph.Presets()
    check('there is a dozen sample graphs', table.getn(presets) >= 12, table.getn(presets))
    -- the graph that starts from the Interop panel's heightmap needs one: a gradient image for the length of the loop
    local Interop = import('/lua/editor/interop.lua')
    local keep = { file = Interop.Settings.file, min = Interop.Settings.min, max = Interop.Settings.max, align = Interop.Settings.align }
    do
        local gf = Fields.Op('gradient', { width = w, height = h, angle = 0, lo = 0, hi = 1 })
        local wrote = ed_img_write('../interoptmp/graph_sample.tif', gf, { bits = 32 })
        Fields.Free(gf)
        if wrote then
            local st = Interop.Settings
            st.file, st.min, st.max, st.align = '../interoptmp/graph_sample.tif', 0, 40, 'corner'
        end
    end
    for _, p in presets do
        local ok, err = Graph.LoadPreset(p.id)
        if not ok then
            check('sample graph ' .. p.id .. ' loads', false, err)
        else
            local problems2 = Graph.Validate()
            local rep2 = GRun.Refresh(true)
            local errs = {}
            for nid, msg in rep2.errors do table.insert(errs, nid .. ': ' .. msg) end
            local d0 = History.Depth()
            local res, why2 = GRun.Build()
            local good = table.getn(problems2) == 0 and table.getn(errs) == 0 and res ~= nil
            check('sample graph ' .. p.id .. ' is valid, evaluates and builds', good, table.concat(errs, ' | ') .. ' ' .. tostring(why2) .. ' ' .. table.getn(problems2))
            if res and res.changed > 0 then
                local one = (History.Depth() == d0 + 1)
                History.Undo()
                check('sample graph ' .. p.id .. ' builds as one undo step and undoes exactly', one and Sum() == flat)
            end
            if hasMasks then for i = 1, 8 do Strata.ClearMask(i) end end
            ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
            Terrain.ClearHistory()
            History.Clear()
        end
    end

    -- ---- another graph starts from the ground the first one made (the texture pass after the terrain graph) ---------------------------------------------------
    do
        GRun.Release()
        Terrain.ClearHistory()
        History.Clear()
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        Graph.New('first')
        local k1 = Graph.Add('const', 0, 0, { value = 77 })
        local o1 = Graph.Add('out_height', 200, 0)
        Graph.Connect(k1.id, 'out', o1.id, 'a')
        GRun.Refresh(true)
        local rb1 = GRun.Build()
        check('the first graph builds a terrain of 77', rb1 ~= nil and math.abs(ed_terrain_get(40, 40) - 77) < 0.5, tostring(ed_terrain_get(40, 40)))
        Graph.New('second')
        local t2 = Graph.Add('terrain', 0, 0)
        GRun.Refresh(true)
        local v2 = GRun.Main and GRun.Main:Value(t2.id, 'out')
        local seen = v2 and Fields.Sample(v2, 40, 40) or -1
        check('another graph reads the ground the first graph made, not the ground from before it', math.abs(seen - 77) < 0.5, tostring(seen))
        local o2 = Graph.Add('out_height', 200, 0)
        Graph.Connect(t2.id, 'out', o2.id, 'a')
        Graph.New('first')
        local k3 = Graph.Add('const', 0, 0, { value = 55 })
        local o3 = Graph.Add('out_height', 200, 0)
        Graph.Connect(k3.id, 'out', o3.id, 'a')
        GRun.Refresh(true)
        GRun.Build()
        GRun.Build()
        check('a second build of the same graph still starts from the same ground', math.abs(ed_terrain_get(40, 40) - 55) < 0.5)
        History.Undo()
        History.Undo()
    end

    for k, v in keep do Interop.Settings[k] = v end
    Interop.FreeCache()
    -- ---- clean up -------------------------------------------------------------------------------------------------------------------------------
    GRun.Release()
    Graph.New('untitled')
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()
    MaskGen.ClearPreview()
    if hasMasks then for i = 1, 8 do Strata.ClearMask(i) end end
    check('no field leaks', ed_field_count() <= startFields, ed_field_count() .. ' vs ' .. startFields)
    check('no prop leaks', ed_prop_count() == startProps)

    local shown = lines
    if not verbose then       -- only what failed (the command channel cuts long answers); Run(true) lists every check
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
