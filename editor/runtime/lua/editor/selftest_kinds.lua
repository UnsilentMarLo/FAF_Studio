-- Self test of the shader nodes of the terrain graph (graphnodes_kinds.lua: Terrain shader, Ground kinds, Surface roughness, Output: ground kinds) and of the recipe parts they use
-- (recipes.lua Selections / WriteKinds / StatsOf). Run in the live editor:
--   return import('/lua/editor/selftest_kinds.lua').Run()
-- Needs a map with paint masks. Gives the layers FAKE textures through roledetect.Fake (no file is touched), leaves the map flat 25 with clean masks.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Recipes = import('/lua/editor/recipes.lua')
local Detect = import('/lua/editor/roledetect.lua')
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local Nodes = import('/lua/editor/graphnodes.lua')

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

    check('the nodes exist', Nodes.Defs.terrain_shader and Nodes.Defs.ground_kinds and Nodes.Defs.surface_roughness and Nodes.Defs.out_kinds)
    local gk = Nodes.Defs.ground_kinds
    check('Ground kinds has the eight kinds as outputs and the style and the knobs as settings', table.getn(gk.outputs) == 8 and table.getn(gk.params) == 2 + table.getn(Recipes.KnobInfo))
    check('Output: ground kinds is an output node with the eight kinds as inputs', Nodes.Defs.out_kinds.output == 'kinds' and table.getn(Nodes.Defs.out_kinds.inputs) == 8)

    local w, h = nil, nil
    if rawget(_G, 'ed_terrain_info') then w, h = ed_terrain_info() end
    if not (Fields.IsAvailable() and w and w >= 129 and rawget(_G, 'ed_stratum_info') and ed_stratum_info() and rawget(_G, 'ed_field_count')) then
        table.insert(lines, '  (no map with paint masks: the checks on a map are skipped)')
        return Done()
    end
    local Terrain = import('/lua/editor/terrain.lua')
    local Strata = import('/lua/editor/strata.lua')
    local fake0, layers0, preset0 = Detect.Fake, Recipes.State.layers, Recipes.State.preset
    local startFields = ed_field_count()
    pcall(function() GRun.Release() end)
    local gpuWas = rawget(_G, 'ed_gpu_info') and ed_gpu_info(false).enabled
    if rawget(_G, 'ed_gpu_enable') then ed_gpu_enable(false) end
    for i = 1, 8 do Strata.ClearMask(i) end
    Fields.Run(function(S)
        local like = S:Height(1)
        local n1 = S:Op('perlin', { like = like, seed = 7, scale = 80, octaves = 5 })
        local n2 = S:Op('ridged', { like = like, seed = 11, scale = 120, octaves = 4 })
        local hgt = S:Op('add', { a = S:Op('affine', { a = n1, mul = 90, add = -15 }), b = S:Op('affine', { a = n2, mul = 40, add = 0 }) })
        Fields.CommitHeight(hgt, { label = 'selftest kinds terrain', noHistory = true })
    end)
    Terrain.ClearHistory()
    History.Clear()
    Recipes.Invalidate()
    Recipes.State.layers = nil
    Recipes.SelectPreset(1)
    local assign = { [0] = 'grass', [1] = 'rock', [2] = 'sand', [3] = 'dirt', [4] = 'snow', [5] = 'wet', [6] = 'highrock', [7] = 'darkrock' }
    local albedo = {}
    for l, role in assign do albedo[l] = '/fake/' .. role .. '_albedo.dds' end
    Detect.Fake = { albedo = albedo, pixels = {} }

    local function Mean(layer)
        local m
        Fields.Run(function(S)
            local _, _, mean = Fields.Stats(S:Stratum(layer))
            m = mean
        end)
        return m
    end

    -- the shader node
    Graph.New('shader')
    local ts = Graph.Add('terrain_shader', 0, 0)
    GRun.Refresh(true)
    local entry = GRun.Main:Entry(ts.id)
    local o = entry and entry.outs
    local p = Strata.Profile() or {}
    check('Terrain shader: the number of layers is what the shader paints', o and o.layers == Recipes.Cap(), o and o.layers)
    check('Terrain shader: PBR, splat and biplanar follow the profile', o and o.pbr == ((p.class == 'pbr' or p.class == 'splat') and 1 or 0) and o.biplanar == (p.biplanar and 1 or 0))

    -- the graph: heights -> ground kinds -> output
    Graph.New('kinds')
    local t = Graph.Add('terrain', 0, 0)
    local gkn = Graph.Add('ground_kinds', 200, 0)
    local ok = Graph.Connect(t.id, 'out', gkn.id, 'a')
    check('Map heights connects to Ground kinds', ok == true)
    local ko = Graph.Add('out_kinds', 500, 0)
    local wired = 0
    for _, id in Recipes.Order do
        if Graph.Connect(gkn.id, id, ko.id, id) then wired = wired + 1 end
    end
    check('all eight kinds connect to Output: ground kinds', wired == 8, wired)
    local rep = GRun.Refresh(true)
    check('the graph evaluates without errors', rep and next(rep.errors) == nil and not rep.fatal, rep and (rep.fatal or Join({ next(rep.errors) or '' }, '')))
    local rock = GRun.Main and GRun.Main:Value(gkn.id, 'rock')
    local snow = GRun.Main and GRun.Main:Value(gkn.id, 'snow')
    local rockMean, snowMean
    if rock then local _, _, m = Fields.Stats(rock) rockMean = m end
    if snow then local _, _, m = Fields.Stats(snow) snowMean = m end
    check('Ground kinds: rock covers the steep part of the terrain (neither nothing nor everything)', rockMean and rockMean > 0.05 and rockMean < 0.95, rockMean)
    check('Ground kinds: snow is a small part, high up', snowMean and snowMean > 0 and snowMean < (rockMean or 1), snowMean)
    local depth = History.Depth()
    local built, why = GRun.Build()
    check('the graph builds', built ~= nil, why)
    check('the build is one undo step', History.Depth() == depth + 1, History.Depth() - depth)
    check('the kinds were written: a summary of the shares that add up to the map', built and built.kinds and (function()
        local sum = 0
        for _, e in built.kinds do sum = sum + e.share end
        return math.abs(sum - 1) < 0.04
    end)())
    local m1, m2, m3, m4 = Mean(1), Mean(2), Mean(3), Mean(4)
    check('rock (layer 1) is painted, snow (layer 4) too, they are not the same', m1 > 0.02 and m4 > 0.001 and math.abs(m1 - m4) > 0.01, m1 .. ' / ' .. m4)
    -- the same as the recipe does
    GRun.Release()
    local graphMeans = { m1, m2, m3, m4 }
    History.Undo()
    check('undo takes the paint away again', Mean(1) < 0.001 and Mean(4) < 0.001, Mean(1))
    local summary = Recipes.Apply()
    check('the recipe applies', summary ~= nil)
    local rm1, rm2, rm3, rm4 = Mean(1), Mean(2), Mean(3), Mean(4)
    check('the graph paints what the recipe paints (rock, sand, dirt, snow within 4 percent of the map)',
        math.abs(rm1 - m1) < 0.04 and math.abs(rm2 - m2) < 0.04 and math.abs(rm3 - m3) < 0.04 and math.abs(rm4 - m4) < 0.04,
        string.format('graph %.3f %.3f %.3f %.3f recipe %.3f %.3f %.3f %.3f', m1, m2, m3, m4, rm1, rm2, rm3, rm4))
    History.Undo()

    -- a kind without a wire is cleared from its layer; the style changes the result
    Graph.New('kinds2')
    local t2 = Graph.Add('terrain', 0, 0)
    local g2 = Graph.Add('ground_kinds', 200, 0, { style = 'alpine' })
    Graph.Connect(t2.id, 'out', g2.id, 'a')
    local o2 = Graph.Add('out_kinds', 500, 0)
    for _, id in { 'rock', 'snow' } do Graph.Connect(g2.id, id, o2.id, id) end
    GRun.Refresh(true)
    local b2 = GRun.Build()
    check('only rock and snow wired: those are painted, sand and dirt are not', b2 ~= nil and Mean(1) > 0.02 and Mean(2) < 0.001 and Mean(3) < 0.001, Mean(2) .. ' ' .. Mean(3))
    local alpineSnow = Mean(4)
    History.Undo()
    GRun.Release()
    check('the alpine style has more snow than the natural one', alpineSnow > m4 + 0.005, alpineSnow .. ' vs ' .. m4)

    -- roughness
    Graph.New('rough')
    local t3 = Graph.Add('terrain', 0, 0)
    local g3 = Graph.Add('ground_kinds', 200, 0)
    Graph.Connect(t3.id, 'out', g3.id, 'a')
    local sr = Graph.Add('surface_roughness', 500, 0)
    Graph.Connect(g3.id, 'rock', sr.id, 'rock')
    Graph.Connect(g3.id, 'snow', sr.id, 'snow')
    GRun.Refresh(true)
    local rf = GRun.Main and GRun.Main:Value(sr.id, 'out')
    local rmin, rmax
    if rf then rmin, rmax = Fields.Stats(rf) end
    check('Surface roughness: rock makes it rougher than neutral, snow shinier', rmin and rmin < 0.45 and rmax and rmax > 0.55, tostring(rmin) .. ' .. ' .. tostring(rmax))

    -- the erosion masks decide too: a wear mask of 1 everywhere bares rock (erosion influence 0.7 -> at least 0.7)
    Graph.New('erosion')
    local te = Graph.Add('terrain', 0, 0)
    local ge = Graph.Add('ground_kinds', 200, 0, { erosion = 0.7 })
    Graph.Connect(te.id, 'out', ge.id, 'a')
    local one = Graph.Add('const', 0, 200, { value = 1 })
    Graph.Connect(one.id, 'out', ge.id, 'wear')
    GRun.Refresh(true)
    local rk = GRun.Main and GRun.Main:Value(ge.id, 'rock')
    if rk then
        local _, _, rm = Fields.Stats(rk)
        check('Ground kinds: a wear mask bares rock (influence 0.7)', rm >= 0.69, rm)
    else
        check('Ground kinds: a wear mask bares rock (influence 0.7)', false, 'no rock output')
    end

    -- the land nodes: Landforms makes plains and hills, Flatten gentle ground takes the gentle ground out of noise
    Graph.New('land')
    local lfn = Graph.Add('landform', 0, 0, { seed = 3, base = 30, size = 160, coverage = 0.4, height = 20, edge = 20, plains = 1 })
    local fl = Graph.Add('flatten', 200, 0, { below = 12 })
    Graph.Connect(lfn.id, 'out', fl.id, 'a')
    local nz = Graph.Add('perlin', 0, 200, { seed = 5, scale = 60, octaves = 5 })
    local rg = Graph.Add('range', 200, 200, { lo = 30, hi = 42 })
    Graph.Connect(nz.id, 'out', rg.id, 'a')
    local fl2 = Graph.Add('flatten', 400, 200, { below = 12, radius = 40 })
    Graph.Connect(rg.id, 'out', fl2.id, 'a')
    local rep2 = GRun.Refresh(true)
    check('Landforms and Flatten evaluate without errors', rep2 and next(rep2.errors) == nil and not rep2.fatal, rep2 and rep2.fatal)
    local hf = GRun.Main and GRun.Main:Value(lfn.id, 'out')
    local hm = GRun.Main and GRun.Main:Value(lfn.id, 'mask')
    if hf and hm then
        local lo, hi = Fields.Stats(hf)
        local thr = Fields.Op('threshold', { a = hm, value = 0.5 })
        local _, _, hillShare = Fields.Stats(thr)
        Fields.Free(thr)
        check('Landforms: the plains are at the ground height and the hills stand above them', lo > 27 and lo < 31.5 and hi > 38, lo .. ' .. ' .. hi)
        check('Landforms: about the share of hills asked for (40 percent)', hillShare > 0.25 and hillShare < 0.55, hillShare)
    end
    local rough = GRun.Main and GRun.Main:Value(rg.id, 'out')
    local flat = GRun.Main and GRun.Main:Value(fl2.id, 'out')
    if rough and flat then
        local function MeanSlope(f)
            local sl = Fields.Op('slope', { a = f, mode = 'degrees', radius = 1 })
            local _, _, m = Fields.Stats(sl)
            Fields.Free(sl)
            return m
        end
        local before, after = MeanSlope(rough), MeanSlope(flat)
        check('Flatten gentle ground makes the ground flatter (mean slope down by a third at least)', after < before * 0.67, before .. ' -> ' .. after)
    end
    check('the Open valley style and the relief rule exist', Recipes.KnobsFor({ preset = 'valley' }) ~= nil and import('/lua/editor/maskgen.lua').Types.relief ~= nil)

    -- ---- back to how it was ---------------------------------------------------------------------------------------------------------------------
    GRun.Release()
    Graph.New('untitled')
    Detect.Fake = fake0
    Recipes.State.layers = layers0
    Recipes.State.preset = preset0
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()
    for i = 1, 8 do Strata.ClearMask(i) end
    Recipes.Invalidate()
    if gpuWas and rawget(_G, 'ed_gpu_enable') then ed_gpu_enable(true) end
    check('no field leaks', ed_field_count() == startFields, ed_field_count() - startFields)
    return Done()
end
