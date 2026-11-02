-- Speed report of the whole terrain stack on the open map (stage T7). Run in the live editor on a 1025 map (File > New map > 1024):
--   return import('/lua/editor/bench_t7.lua').Run()          everything (the command channel answers within about a minute: use `Part(n)` for single parts)
--   Part(1) field ops at the map size    Part(2) erosion solvers    Part(3) a 30 node graph: preview, parameter change, Build    Part(4) previews and commits
-- Numbers are milliseconds with the editor's thread count. Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')

local function Ms(fn)
    local t0 = ed_field_clock()
    fn()
    return (ed_field_clock() - t0) * 1000
end

local function Line(out, label, ms) table.insert(out, string.format('  %-36s %9.1f ms', label, ms)) end

--- Part 1: the field ops (core, T3 and T7) on a grid of the map's size.
local function Ops(out, w, h)
    table.insert(out, 'field ops ' .. w .. ' x ' .. h .. ', ' .. ed_field_threads() .. ' threads:')
    Fields.Run(function(S)
        local base = S:Op('ridged', { width = w, height = h, seed = 3, scale = w * 0.18, octaves = 6 })
        local a = S:Op('affine', { a = base, mul = 60, add = 10 })
        local b = S:Op('perlin', { width = w, height = h, seed = 9, scale = 100, octaves = 3 })
        local list = {
            { 'perlin 5 octaves', 'perlin', { like = a, seed = 3, scale = 120, octaves = 5 } },
            { 'simplex 5 octaves', 'simplex', { like = a, seed = 3, scale = 120, octaves = 5 } },
            { 'voronoi', 'voronoi', { like = a, seed = 3, scale = 60 } },
            { 'blur sigma 4', 'blur', { a = a, radius = 4 } },
            { 'blur sigma 30', 'blur', { a = a, radius = 30 } },
            { 'slope', 'slope', { a = a } },
            { 'slope rating', 'slope', { a = a, mode = 'rating', window = 2 } },
            { 'curvature', 'curvature', { a = a } },
            { 'distance', 'distance', { a = a, threshold = 40 } },
            { 'warp by noise', 'warp', { a = a, dx = b, dz = b, strength = 30 } },
            { 'flow (D8)', 'flow', { a = a } },
            { 'thermal 50 it', 'thermal', { a = a, iterations = 50, talus = 0.6 } },
            { 'musgrave ridged', 'musgrave', { like = a, seed = 3, scale = 120, octaves = 6 } },
            { 'fbm_damped 8 oct', 'fbm_damped', { like = a, seed = 3, scale = 120, octaves = 8 } },
            { 'cells plate + warp', 'cells', { like = a, seed = 3, scale = 60, mode = 'plate', warp = 20 } },
            { 'cracks 2 levels', 'cracks', { like = a, seed = 3, scale = 80 } },
            { 'dwarp fbm', 'dwarp', { a = a, strength = 40, size = 100 } },
            { 'bilateral r=6', 'bilateral', { a = a, radius = 6, sigma_r = 2 } },
            { 'diffuse 50 it', 'diffuse', { a = a, iterations = 50, kappa = 0.4 } },
            { 'morph open disc r=5', 'morph', { a = a, op = 'open', radius = 5, shape = 'disc' } },
            { 'occlusion 12 dirs', 'occlusion', { a = a, radius = 30 } },
            { 'hillshade + shadows', 'hillshade', { a = a, shadows = 1 } },
            { 'wetness', 'wetness', { a = a } },
            { 'thermal_map 50 it', 'thermal_map', { a = a, b = b, iterations = 50 } },
            { 'rocksoil 50 it', 'erode_rocksoil', { a = a, iterations = 50 } },
            { 'snow 40 it', 'erode_snow', { a = a, snowline = 40, iterations = 40 } },
            { 'wind 40 it', 'erode_wind', { a = a, iterations = 40 } },
            { 'glacier 100 it', 'erode_glacier', { a = a, iterations = 100, ela = 30 } },
            { 'settle 20 it', 'settle', { a = a, iterations = 20 } },
        }
        for _, item in list do
            local e = item
            local ms = Ms(function()
                local main, extra = ed_field_op_multi(e[2], e[3])
                if not main then error(e[1] .. ': ' .. tostring(extra)) end
                S:Add(main)
                if extra then for _, f in extra do S:Add(f) end end
            end)
            Line(out, e[1], ms)
        end
    end)
end

--- Part 2: the erosion solvers.
local function Erosion(out, w, h)
    table.insert(out, 'erosion solvers ' .. w .. ' x ' .. h .. ':')
    Fields.Run(function(S)
        local n = S:Op('ridged', { width = w, height = h, seed = 3, scale = w * 0.4, octaves = 5 })
        local hgt = S:Op('affine', { a = n, mul = 55, add = 8 })
        local list = {
            { 'hydraulic 100 it (no masks)', 'erode_hydraulic', { iterations = 100, masks = 0 } },
            { 'hydraulic 500 it', 'erode_hydraulic', { iterations = 500 } },
            { 'droplets 1 per cell', 'erode_droplet', { density = 1 } },
            { 'stream power 10 it', 'erode_stream', { iterations = 10 } },
        }
        for _, item in list do
            local e = item
            local p = { a = hgt }
            for k, v in e[3] do p[k] = v end
            local ms = Ms(function()
                local main, extra = ed_field_op_multi(e[2], p)
                S:Add(main)
                if extra then for _, f in extra do S:Add(f) end end
            end)
            Line(out, e[1], ms)
        end
    end)
end

--- A graph of 30 nodes: noise, warp, erosion, masks, three outputs.
local function MakeGraph()
    Graph.New('bench30')
    local function A(t, p) return Graph.Add(t, 0, 0, p) end
    local function C(from, port, to, inp) Graph.Connect(from.id, port, to.id, inp) end
    local n1 = A('ridged', { scale = 380 })
    local n2 = A('perlin', { scale = 160, octaves = 5 })
    local n3 = A('musgrave', { scale = 300 })
    local mix1 = A('blend', { mode = 'normal', opacity = 0.4 })
    C(n1, 'out', mix1, 'a') C(n2, 'out', mix1, 'b')
    local mix2 = A('blend', { mode = 'overlay', opacity = 0.5 })
    C(mix1, 'out', mix2, 'a') C(n3, 'out', mix2, 'b')
    local dw = A('dwarp', { strength = 50, size = 140 })
    C(mix2, 'out', dw, 'a')
    local rg = A('range', { lo = 8, hi = 70 })
    C(dw, 'out', rg, 'a')
    local th = A('thermal', { iterations = 30 })
    C(rg, 'out', th, 'a')
    local er = A('erode_hydraulic', { iterations = 120 })
    C(th, 'out', er, 'a')
    local bl = A('bilateral', { radius = 4, sigma_r = 1.5 })
    C(er, 'out', bl, 'a')
    local rs = A('erode_rocksoil', { iterations = 30 })
    C(bl, 'out', rs, 'a')
    local sl = A('settle', { iterations = 15 })
    C(rs, 'out', sl, 'a')
    local oh = A('out_height')
    C(sl, 'out', oh, 'a')
    -- masks
    local slope = A('slope', { mode = 'degrees' })
    C(sl, 'out', slope, 'a')
    local cliff = A('range_mask', { lo = 28, hi = 80, soft = 8 })
    C(slope, 'out', cliff, 'a')
    local cav = A('occlusion', { radius = 30 })
    C(sl, 'out', cav, 'a')
    local wet = A('wetness', {})
    C(sl, 'out', wet, 'a')
    local rock = A('rockiness', {})
    C(sl, 'out', rock, 'a')
    local grass = A('range_mask', { lo = 15, hi = 50, soft = 10 })
    C(sl, 'out', grass, 'a')
    local comb = A('mul', {})
    C(grass, 'out', comb, 'a') C(wet, 'out', comb, 'b')
    local sn = A('erode_snow', { snowline = 55, iterations = 20 })
    C(sl, 'out', sn, 'a')
    local l1 = A('out_layer', { layer = 2 })
    C(cliff, 'out', l1, 'a')
    local l2 = A('out_layer', { layer = 3 })
    C(comb, 'out', l2, 'a')
    local l3 = A('out_layer', { layer = 4 })
    C(sn, 'cover', l3, 'a')
    local l4 = A('out_layer', { layer = 5 })
    C(rock, 'out', l4, 'a')
    local sm = A('blur', { radius = 3 })
    C(cav, 'out', sm, 'a')
    local l5 = A('out_layer', { layer = 6 })
    C(sm, 'out', l5, 'a')
    return Graph.Current, n1, sl, sm
end

--- Part 3: the graph.
local function GraphBench(out, w, h)
    table.insert(out, 'graph of 30 nodes on ' .. w .. ' x ' .. h .. ':')
    GRun.Release()
    local graph, n1, late, lateMask = MakeGraph()
    table.insert(out, '  (' .. table.getn(graph.nodes) .. ' nodes)')
    local rep
    Line(out, 'first preview (1/' .. GRun.PreviewStep() .. ', thumbnails)', Ms(function() rep = GRun.Refresh(true) end))
    local errs = 0
    for _, _ in rep.errors do errs = errs + 1 end
    if errs > 0 then
        for id, msg in rep.errors do table.insert(out, '  ERROR node ' .. id .. ': ' .. tostring(msg)) end
    end
    Line(out, 'preview again (all cached)', Ms(function() GRun.Refresh() end))
    Graph.SetParam(n1.id, 'scale', 350)
    Line(out, 'preview after the first noise changed', Ms(function() GRun.Refresh() end))
    local res, msg
    GRun.DropBuildCache()
    Line(out, 'Build, nothing cached (one undo step)', Ms(function() res, msg = GRun.Build() end))
    if not res then table.insert(out, '  Build failed: ' .. tostring(msg)) end
    local samples, mb, nodes = GRun.BuildCacheInfo()
    table.insert(out, string.format('  (Build cache: %d nodes, %.0f MB)', nodes, mb))
    Line(out, 'undo of the Build', Ms(function() History.Undo() end))
    Graph.SetParam(lateMask.id, 'radius', 5)
    Line(out, 'Build after the last node changed', Ms(function() res, msg = GRun.Build() end))
    History.Undo()
    Graph.SetParam(late.id, 'iterations', 25)
    Line(out, 'Build after the sediment node changed', Ms(function() res, msg = GRun.Build() end))
    History.Undo()
    Graph.SetParam(n1.id, 'scale', 330)
    Line(out, 'Build after the first noise changed', Ms(function() res, msg = GRun.Build() end))
    History.Undo()
    GRun.Release()
end

--- Part 4: previews and commits.
local function PreviewBench(out, w, h)
    table.insert(out, 'previews and commits on ' .. w .. ' x ' .. h .. ':')
    Fields.Run(function(S)
        local n = S:Op('ridged', { width = w, height = h, seed = 3, scale = w * 0.4, octaves = 5 })
        local hgt = S:Op('affine', { a = n, mul = 55, add = 8 })
        Line(out, 'map heights -> field', Ms(function() S:Height(1) end))
        Line(out, 'preview 128 x 128 (colour)', Ms(function() Fields.Preview(hgt, 128, { ramp = 'terrain' }) end))
        Line(out, 'stats', Ms(function() Fields.Stats(hgt) end))
        local depth = History.Depth()
        Line(out, 'commit heights (one undo step)', Ms(function() Fields.Apply{ height = hgt, masks = {}, label = 'bench' } end))
        if History.Depth() > depth then Line(out, 'undo of the commit', Ms(function() History.Undo() end)) end
    end)
end

local PARTS = { Ops, Erosion, GraphBench, PreviewBench }

function Part(n)
    local w, h = ed_terrain_info()
    local out = {}
    PARTS[n](out, w, h)
    return table.concat(out, '\n')
end

function Run()
    local w, h = ed_terrain_info()
    local out = {}
    for i = 1, table.getn(PARTS) do
        local ok, err = pcall(PARTS[i], out, w, h)
        if not ok then table.insert(out, 'part ' .. i .. ' failed: ' .. tostring(err)) end
    end
    return table.concat(out, '\n')
end
