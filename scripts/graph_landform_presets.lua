-- Builds the graphs of the shipped set that are made from Landforms (docs/projects/editor/GRAPH_TEXTURING.md, "What a good map has") and writes them to <instance>/graphs_upgraded/.
-- Run: python scripts/editor_inst.py cmd <tag> scripts/graph_landform_presets.lua, then python scripts/graph_preset_install.py (add the graphs to graphpresets/index.lua by hand the first time).
--
-- Lua 5.0 dialect.

local Graph = import('/lua/editor/graph.lua')
local Recipes = import('/lua/editor/recipes.lua')
local failed = {}
local function Connect(a, ap, b, bp)
    local ok = Graph.Connect(a, ap, b, bp)
    if not ok then table.insert(failed, a .. '.' .. ap .. '->' .. b .. '.' .. bp) end
    return ok
end
local function Col(c) return c * 224 end
local function Row(r) return r * 152 end

local function Tail(from, style, x, y, erosion)
    local gk = Graph.Add('ground_kinds', x, y, { style = style })
    Connect(from.id, 'out', gk.id, 'a')
    if erosion then
        Connect(erosion.id, 'wear', gk.id, 'wear')
        Connect(erosion.id, 'deposit', gk.id, 'deposit')
        Connect(erosion.id, 'flow', gk.id, 'flow')
    end
    local ok = Graph.Add('out_kinds', x + 330, y, {})
    for _, role in Recipes.Order do Connect(gk.id, role, ok.id, role) end
end

-- 1. an open valley: bare plains, green hill clusters with cliffs
Graph.New('Open valley (plains, hills and cliffs)')
Graph.Current.seed = 7
local lf = Graph.Add('landform', Col(0), Row(0), { seed = 7, base = 28, size = 240, coverage = 0.35, height = 18, edge = 22, top = 0.5, detail = 0.6, plains = 1.2 })
local er = Graph.Add('erode_droplet', Col(1), Row(0), { density = 1.2, lifetime = 50, radius = 3, drop_vary = 0.7, thermal = 0.35, thermal_steps = 2, talus = 0.8, vary = 0.3, rain_vary = 0.4, protect = 0.5, max_change = 6 })
Connect(lf.id, 'out', er.id, 'a')
-- a second, gentler pass settles sediment in the basins (the reference runs three erosions: coarse gullies, then the combined terrain at high resolution)
local er2 = Graph.Add('erode_hydraulic', Col(2), Row(0), { iterations = 60, rain = 0.006, deposition = 0.08, thermal = 0.25, talus = 0.9 })
Connect(er.id, 'out', er2.id, 'a')
local oh = Graph.Add('out_height', Col(3), Row(0), {})
Connect(er2.id, 'out', oh.id, 'a')
Tail(er2, 'valley', Col(3), Row(1), er2)
-- forests on the hills: the hill mask (Landforms), broken into clumps by a noise, drives a scatter of pine and oak groups
local hm = Graph.Add('smoothstep', Col(1), Row(2), { edge0 = 0.45, edge1 = 0.8 })
Connect(lf.id, 'mask', hm.id, 'a')
local cl = Graph.Add('simplex', Col(1), Row(3), { seed = 11, scale = 70, octaves = 3 })
local cs = Graph.Add('smoothstep', Col(2), Row(3), { edge0 = 0.45, edge1 = 0.7 })
Connect(cl.id, 'out', cs.id, 'a')
local dens = Graph.Add('mul', Col(3), Row(2), {})
Connect(hm.id, 'out', dens.id, 'a')
Connect(cs.id, 'out', dens.id, 'b')
local sc = Graph.Add('out_scatter', Col(4), Row(2), { count = 1400, minDist = 7, fill = 0.9, slopeMax = 28, scaleMin = 80, scaleMax = 130,
    entries = { { bp = '/env/Evergreen/Props/Trees/Groups/Pine06_Big_GroupA_prop.bp', weight = 3 }, { bp = '/env/Evergreen/Props/Trees/Groups/Pine06_Big_GroupB_prop.bp', weight = 3 },
                { bp = '/env/Evergreen/Props/Trees/Groups/Pine06_GroupA_prop.bp', weight = 2 }, { bp = '/env/Evergreen/Props/Trees/Groups/Pine06_GroupB_prop.bp', weight = 2 },
                { bp = '/env/Evergreen/Props/Trees/Groups/Oak01_Group1_prop.bp', weight = 1 }, { bp = '/env/Evergreen/Props/Trees/Pine06_Big_prop.bp', weight = 2 } } })
Connect(dens.id, 'out', sc.id, 'a')
ed_write_file('../graphs_upgraded/valley.lua', Graph.Text())

-- 2. the drawn layout becomes terrain, the way the reference is made: File Input (the layout) -> Blur -> Terrace -> Combiner with a noise that only lives on the slopes -> Erosion -> a second
--    erosion on the whole ground -> masks for the paint from the erosion. Draw the layout first (Layout workspace: templates or by hand).
Graph.New('Layout to terrain (drawn layout, terraces, noise on the slopes, erosion)')
Graph.Current.seed = 5
local ly = Graph.Add('layout_height', Col(0), Row(0), { weather = 0 })
local bl = Graph.Add('blur', Col(1), Row(0), { radius = 5 })
Connect(ly.id, 'out', bl.id, 'a')
local tr = Graph.Add('terrace', Col(2), Row(0), { steps = 4, sharpness = 0.55, lo = 20, hi = 110 })
Connect(bl.id, 'out', tr.id, 'a')
local mx = Graph.Add('blend', Col(3), Row(0), { mode = 'normal', opacity = 0.5 })
Connect(bl.id, 'out', mx.id, 'a')
Connect(tr.id, 'out', mx.id, 'b')
local sl = Graph.Add('slope', Col(3), Row(1), { mode = 'degrees' })
Connect(mx.id, 'out', sl.id, 'a')
local sm = Graph.Add('smoothstep', Col(4), Row(1), { edge0 = 8, edge1 = 30 })
Connect(sl.id, 'out', sm.id, 'a')
local rn = Graph.Add('ridged', Col(3), Row(2), { seed = 9, scale = 50, octaves = 4 })
local ra = Graph.Add('affine', Col(4), Row(2), { mul = 7, add = -3.5 })
Connect(rn.id, 'out', ra.id, 'a')
local nm = Graph.Add('mul', Col(5), Row(1), {})
Connect(ra.id, 'out', nm.id, 'a')
Connect(sm.id, 'out', nm.id, 'b')
local ad = Graph.Add('add', Col(5), Row(0), {})
Connect(mx.id, 'out', ad.id, 'a')
Connect(nm.id, 'out', ad.id, 'b')
local e1 = Graph.Add('erode_droplet', Col(6), Row(0), { density = 1.4, lifetime = 55, radius = 3, drop_vary = 0.7, thermal = 0.35, thermal_steps = 2, talus = 0.8, vary = 0.3, rain_vary = 0.4, protect = 0.5, max_change = 6 })
Connect(ad.id, 'out', e1.id, 'a')
local sb = Graph.Add('blur', Col(7), Row(0), { radius = 2 })
Connect(e1.id, 'out', sb.id, 'a')
local e2 = Graph.Add('erode_hydraulic', Col(8), Row(0), { iterations = 60, rain = 0.006, deposition = 0.08, thermal = 0.25, talus = 0.9 })
Connect(sb.id, 'out', e2.id, 'a')
local ho = Graph.Add('out_height', Col(9), Row(0), {})
Connect(e2.id, 'out', ho.id, 'a')
Tail(e2, 'valley', Col(9), Row(1), e2)
ed_write_file('../graphs_upgraded/layout_terrain.lua', Graph.Text())
Graph.New('untitled')
return 'ok, failed connections: ' .. table.concat(failed, ' ')
