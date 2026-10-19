-- Node part of the stage T7 self test (called by selftest_t7.lua with its `check`): the 33 new graph nodes, the colour value, the colour output file, preview against full resolution for the
-- generators, the cache and determinism of the new nodes, and (once they exist) every sample graph of the library. Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
local GRun = import('/lua/editor/graphrun.lua')
local GraphColor = import('/lua/editor/graphcolor.lua')

NEW_NODES = { 'musgrave', 'fbm_damped', 'cells', 'craters', 'dunes', 'cracks', 'island', 'hills', 'mountains', 'mesas', 'dwarp', 'bilateral', 'diffuse', 'unsharp', 'edge', 'morph', 'convolve',
              'blur_dir', 'blur_slope', 'stratify', 'thermal_map', 'erode_rocksoil', 'erode_snow', 'erode_wind', 'erode_glacier', 'settle', 'occlusion', 'hillshade', 'wetness', 'rockiness',
              'color_ramp', 'out_colormap', 'map_share' }

function Run(check)
    local w, h = ed_terrain_info()
    if not w or w < 129 then
        check('node tests need a map of at least 129 samples', false, tostring(w))
        return
    end
    local startFields = ed_field_count()
    GRun.Release()

    -- ---- the catalogue ---------------------------------------------------------------------------------------------------------------------------
    local missing = {}
    for _, id in NEW_NODES do
        if not Nodes.Defs[id] then table.insert(missing, id) end
    end
    check('all ' .. table.getn(NEW_NODES) .. ' T7 nodes are in the catalogue', table.getn(missing) == 0, table.concat(missing, ' '))
    local genericOnly = {}
    for _, op in Fields.OpNames() do
        if Nodes.Defs['raw_' .. op] and Nodes.Covers[op] == nil then table.insert(genericOnly, op) end
    end
    check('no T7 op is left with a generic node only', table.getn(genericOnly) == 0, table.concat(genericOnly, ' '))
    local noWire = {}
    for _, id in NEW_NODES do
        local d = Nodes.Defs[id]
        if d and d.cat ~= 'gen' and d.cat ~= 'numbers' and d.cat ~= 'color' and d.cat ~= 'outputs' and table.getn(d.inputs) == 0 then table.insert(noWire, id) end
    end
    check('every filter node has an input', table.getn(noWire) == 0, table.concat(noWire, ' '))
    check('the colour category exists', Nodes.CatColor and Nodes.CatColor.color ~= nil and Nodes.PortColor.color ~= nil)

    -- ---- parameters follow the number setting rule (a range, a step, a format) -------------------------------------------------------------------
    local badParams = {}
    for _, id in NEW_NODES do
        local d = Nodes.Defs[id]
        if d then
            for _, p in d.params do
                if p.kind == 'number' then
                    if not (p.min and p.max and p.step and p.fmt and p.default ~= nil) or p.min >= p.max or p.default < p.min or p.default > p.max then
                        table.insert(badParams, id .. '.' .. p.key)
                    end
                end
            end
        end
    end
    check('every number parameter has a valid range, step, format and default', table.getn(badParams) == 0, table.concat(badParams, ' '))

    -- ---- colour ramps ---------------------------------------------------------------------------------------------------------------------------------
    local T7 = import('/lua/editor/graphnodes_t7.lua')
    local okRamp, flat = pcall(T7.RampStops, 'custom', '0:#000000;1:#ff8040', false, 1)
    check('a custom ramp parses', okRamp and table.getn(flat) == 10 and flat[6] == 1 and flat[7] == 1 and math.abs(flat[8] - 0.5019608) < 1e-5, okRamp and table.getn(flat) or tostring(flat))
    local okBad = pcall(T7.RampStops, 'custom', 'nonsense', false, 1)
    check('a broken custom ramp is refused', not okBad)
    local okRev, rev = pcall(T7.RampStops, 'grey', '', true, 1)
    check('a reversed ramp starts with the last colour', okRev and rev[1] == 0 and rev[2] == 1 and rev[6] == 1 and rev[7] == 0, okRev and rev[2] or tostring(rev))

    -- ---- every new node evaluates, in a graph with real inputs -------------------------------------------------------------------------------------------
    Graph.New('t7nodes')
    local src = Graph.Add('mountains', 0, 0, { scale = 200 })
    local hgt = Graph.Add('range', 0, 0, { lo = 10, hi = 70 })
    Graph.Connect(src.id, 'out', hgt.id, 'a')
    local flat = Graph.Add('const', 0, 0, { value = 30 })
    local made = {}
    for _, id in NEW_NODES do
        local d = Nodes.Defs[id]
        if d and id ~= 'out_colormap' and id ~= 'mountains' then
            local n = Graph.Add(id, 0, 0)
            made[id] = n
            for _, port in d.inputs do
                if port.type == 'height' or port.type == 'mask' then
                    if not port.opt then Graph.Connect(hgt.id, 'out', n.id, port.name) end
                end
            end
        end
    end
    local rep = GRun.Refresh(true)
    local errs = {}
    for nid, msg in rep.errors do
        local n = Graph.NodeById(nid)
        table.insert(errs, n.type .. ': ' .. msg)
    end
    check('every new node evaluates with its default parameters', table.getn(errs) == 0, table.concat(errs, ' | '))
    -- the extra outputs exist and are fields of the map's shape
    local gw, gh = nil, nil
    local main = GRun.GetMain()
    local outsOk, outsBad = 0, {}
    for id, n in made do
        local d = Nodes.Defs[id]
        local e = main and main:Entry(n.id)
        if e and e.outs then
            for _, o in d.outputs do
                local v = e.outs[o.name]
                if o.hidden then
                elseif v == nil then
                    table.insert(outsBad, id .. '.' .. o.name)
                else
                    outsOk = outsOk + 1
                end
            end
        end
    end
    check('every output port of the new nodes has a value (' .. outsOk .. ' ports)', table.getn(outsBad) == 0, table.concat(outsBad, ' '))

    -- erosion nodes: the main output is the terrain, the extras are what they say
    local function Out(id, port)
        local e = main and main:Entry(made[id].id)
        return e and e.outs and e.outs[port]
    end
    if made.erode_rocksoil and Out('erode_rocksoil', 'soil') then
        local mn, mx = Fields.Stats(Out('erode_rocksoil', 'soil'))
        local rmn, rmx = Fields.Stats(Out('erode_rocksoil', 'rock'))
        check('rock and soil: soil >= 0 and rock exposure in 0..1', mn >= 0 and rmn >= 0 and rmx <= 1, mn .. ' ' .. rmn .. ' ' .. rmx)
    end
    if made.erode_snow and Out('erode_snow', 'cover') then
        local mn, mx = Fields.Stats(Out('erode_snow', 'cover'))
        check('snow cover is a 0..1 mask', mn >= 0 and mx <= 1)
    end
    if made.erode_glacier and Out('erode_glacier', 'ice') then
        local mn = Fields.Stats(Out('erode_glacier', 'ice'))
        check('glacier ice is never negative', mn >= 0)
    end

    -- the colour node: four channels, a thumbnail, rgba of the right type
    local cr = made.color_ramp
    local cre = main and main:Entry(cr.id)
    local rgba = cre and cre.outs and cre.outs.rgba
    check('colour ramp gives an rgba value of four fields', type(rgba) == 'table' and rgba.r and rgba.g and rgba.b and rgba.a and rgba.r == cre.outs.red)
    local thumbRun = GRun.NewRun{ step = 4, thumbs = true, only = { [hgt.id] = true, [src.id] = true, [cr.id] = true } }
    thumbRun:Evaluate()
    local te = thumbRun:Entry(cr.id)
    check('the colour ramp node has a thumbnail', te and te.thumb ~= nil, te and tostring(te.thumb))
    thumbRun:Free()

    -- ---- generators: the preview samples the same world as the full run ---------------------------------------------------------------------------------------
    local same = {}
    for _, id in { 'musgrave', 'fbm_damped', 'cells', 'craters', 'dunes', 'cracks', 'island', 'hills', 'mesas' } do
        local n = made[id]
        if n then
            local small = GRun.NewRun{ step = 4, thumbs = false, only = { [n.id] = true } }
            small:Evaluate()
            local big = GRun.NewRun{ step = 1, thumbs = false, only = { [n.id] = true } }
            big:Evaluate()
            local fs, fb = small:Value(n.id, 'out'), big:Value(n.id, 'out')
            local match = fs ~= nil and fb ~= nil
            if match then
                for _, ij in { { 3, 5 }, { 10, 20 }, { 30, 30 }, { 50, 7 } } do
                    local a, b = Fields.Get(fs, ij[1], ij[2]), Fields.Get(fb, ij[1] * 4, ij[2] * 4)
                    if math.abs(a - b) > 1e-4 then match = false end
                end
            end
            if not match then table.insert(same, id) end
            small:Free()
            big:Free()
        end
    end
    check('the 1/4 resolution preview of the generators samples the same world as the full run', table.getn(same) == 0, table.concat(same, ' '))

    -- ---- the cache: a parameter of one new node re-runs it and what is below it only --------------------------------------------------------------------------------
    local g2 = Graph.New('t7cache')
    local a = Graph.Add('musgrave', 0, 0)
    local b = Graph.Add('bilateral', 0, 0)
    local c = Graph.Add('hillshade', 0, 0)
    Graph.Connect(a.id, 'out', b.id, 'a')
    Graph.Connect(b.id, 'out', c.id, 'a')
    local r1 = GRun.Refresh(true)
    local r2 = GRun.Refresh(true)
    check('a second evaluation of new nodes is all cached', r1.evaluated == 3 and r2.evaluated == 0 and r2.cached == 3, r1.evaluated .. ' / ' .. r2.evaluated)
    Graph.SetParam(b.id, 'radius', 9)
    local r3 = GRun.Refresh()
    check('a changed new node re-runs itself and what is downstream', r3.evaluated == 2 and r3.cached == 1, r3.evaluated .. ' / ' .. r3.cached)

    -- ---- the colour image: Build writes a DDS file ----------------------------------------------------------------------------------------------------------
    local path = '../fieldtmp/t7_colormap_test.dds'
    Graph.New('t7color')
    local pn = Graph.Add('perlin', 0, 0, { scale = 80 })
    local cn = Graph.Add('color_ramp', 0, 0, { ramp = 'terrain' })
    local on = Graph.Add('out_colormap', 0, 0, { path = path, size = 64 })
    Graph.Connect(pn.id, 'out', cn.id, 'a')
    local okc = Graph.Connect(cn.id, 'rgba', on.id, 'rgba')
    check('a colour wire connects (rgba to rgba)', okc)
    local badWire = Graph.Connect(pn.id, 'out', on.id, 'rgba')
    check('a height cannot feed a colour input', not badWire)
    local result, msg = GRun.Build()
    check('Build writes the colour image', result ~= nil and result.colormaps == 1, tostring(msg))
    if rawget(_G, 'ed_dds_read') then
        local px, pw, ph = ed_dds_read(path)
        check('the colour image is a 64 x 64 DDS with colour', px ~= nil and pw == 64 and ph == 64, tostring(pw))
        if px then
            local varied = false
            for i = 1, 4000, 4 do
                if px[i] ~= px[i + 1] or px[i + 1] ~= px[i + 2] then varied = true end
            end
            check('the colour image is not grey', varied)
        end
    end

    -- ---- the library: 20 graphs, a thumbnail and a README line each (the graphs themselves are built, undone and checked by selftest_graph with the other samples) --------------------
    local Lib = import('/lua/editor/graphlib.lua')
    local list = Lib.List()
    check('the library has 20 graphs', table.getn(list) >= 20, table.getn(list))
    local noThumb, noNote, noSC = {}, {}, {}
    local SC = { pad_flatten = true, symmetrize = true, slope_limit = true, unit_slope = true, regions = true, reach = true, points_mask = true, rect_mask = true, path_shape = true, path_mask = true, path_line = true }
    for _, p in list do
        if not Lib.ThumbPath(p.id) then table.insert(noThumb, p.id) end
        if not p.note or string.len(p.note) < 40 then table.insert(noNote, p.id) end
        local ok = Graph.LoadPreset(p.id)
        local uses = false
        if ok then
            for _, n in Graph.Current.nodes do
                if SC[n.type] then uses = true end
            end
        end
        if not uses then table.insert(noSC, p.id) end
    end
    check('every library graph has a shipped thumbnail', table.getn(noThumb) == 0, table.concat(noThumb, ' '))
    check('every library graph has a README line', table.getn(noNote) == 0, table.concat(noNote, ' '))
    check('at least 15 of the 20 library graphs use SC specific nodes (the others are terrain style graphs)', table.getn(noSC) <= 5, table.concat(noSC, ' '))
    Graph.New('t7done')

    GRun.Release()
    Graph.New('t7done')
    check('no field leaks in the node tests', ed_field_count() == startFields, ed_field_count() - startFields)
end
