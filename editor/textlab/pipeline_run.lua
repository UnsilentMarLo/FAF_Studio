-- Pipeline lab, one shader: PL = { shader = 'Terrain202B', k = 2, theme = 'temperate', style = 'erosion' }
-- Rough start terrain -> hydraulic erosion -> Oversample (k x) -> ground kinds (the wear / deposit / flow masks decide) -> every output the shader can use:
-- heights, ground kinds (paint layers, terrain types, roughness mask), map normal map, map lighting ("info texture"), roughness / height atlas, macrotexture, specular texture.
-- Returns lines  key=value  for scripts/pipeline_lab.py. Lua 5.0 dialect.
local PL = rawget(_G, 'PL') or {}
local Shaders = import('/lua/editor/shaders.lua')
local TS = import('/lua/editor/texsets.lua')
local R = import('/lua/editor/recipes.lua')
local MT = import('/lua/editor/maptextures.lua')
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local World = import('/lua/editor/world.lua')
local Strata = import('/lua/editor/strata.lua')
local Fields = import('/lua/editor/fields.lua')
local out = {}
local function say(k, v) table.insert(out, k .. '=' .. tostring(v)) end
local t0 = GetSystemTimeSeconds()
ed_gpu_enable(true)

-- 0. what the previous shader left: its map-wide pictures (cleared in its own slots), the paint
for _, kind in { 'normal', 'light', 'macro', 'specular', 'atlas' } do pcall(MT.Clear, kind, { noPush = true }) end
for i = 1, 8 do pcall(Strata.ClearMask, i) end
import('/lua/editor/history.lua').Clear()

-- 1. the shader, its textures
local ok, why = Shaders.Set(PL.shader)
if not ok then return 'ERROR=' .. tostring(why) end
say('shader', PL.shader)
local profile = Strata.Profile() or {}
say('class', profile.class)
say('painted', profile.painted)
say('l8', profile.l8)
say('range', profile.range)
TS.Apply(PL.theme or 'temperate')
R.Invalidate()
R.State.layers = nil
local spec = Shaders.SpecColor()
if spec then say('spec', string.format('%.3f,%.3f,%.3f,%.3f', spec.spec_r, spec.spec_g, spec.spec_b, spec.spec_a)) end

if not PL.fromMap then World.Change({ water_on = 1, water_elev = 38, water_deep = 26, water_abyss = 8 }, { refresh = true }) end

-- 2. the graph
Graph.New('pipeline ' .. PL.shader)
Graph.Current.seed = PL.seed or 3
local function A(t, x, y, p) return Graph.Add(t, x, y, p) end
local function C(a, ap, b, bp)
    if not Graph.Connect(a.id, ap, b.id, bp) then say('CONNECT_FAILED', a.type .. '.' .. ap .. '->' .. b.type .. '.' .. bp) end
end
local src
if PL.fromMap then
    src = A('terrain', 0, 0, {})                       -- the open map's own heights are the rough start
else
    local sim = A('simplex', 0, 0, { scale = 150, octaves = 5, persistence = 0.5, seed = 1 })
    local bil = A('billow', 0, 150, { scale = 90, octaves = 4, persistence = 0.5, seed = 1 })
    local mix = A('blend', 220, 0, { mode = 'normal', opacity = 0.35 })
    src = A('range', 440, 0, { lo = 20, hi = 95 })
    C(sim, 'out', mix, 'a') C(bil, 'out', mix, 'b') C(mix, 'out', src, 'a')
end
local ero = A('erode_hydraulic', 660, 0, { iterations = 60 })
local ovs = A('oversample', 880, 0, { factor = PL.k or 2, rerun = true })
C(src, 'out', ero, 'a') C(ero, 'out', ovs, 'a')
local kinds = A('ground_kinds', 1100, 0, { style = PL.style or 'erosion' })
C(ovs, 'out', kinds, 'a') C(ovs, 'wear', kinds, 'wear') C(ovs, 'deposit', kinds, 'deposit') C(ovs, 'flow', kinds, 'flow')
local okind = A('out_kinds', 1320, 0, {})
for _, id in R.Order do C(kinds, id, okind, id) end
for _, p in { 'rock2', 'rock3', 'dirt2', 'wet2', 'grass2' } do C(kinds, p, okind, p) end
local oh = A('out_height', 1100, 300, {})
C(ovs, 'out', oh, 'a')
local size = (PL.k or 2) > 1 and 'grid' or 'auto'
local nrm = A('normal_map', 1100, 450, { strength = 1 })
local onrm = A('out_normalmap', 1320, 450, { size = size, assign = true })
C(ovs, 'out', nrm, 'a') C(nrm, 'rgba', onrm, 'normal')
local lt = A('lighting_tex', 1100, 600, { ao = 0.5, quality = '5' })
local olt = A('out_maplight', 1320, 600, { size = size, assign = true })
C(ovs, 'out', lt, 'a') C(lt, 'shadow', olt, 'shadow') C(lt, 'ao', olt, 'ao') C(ovs, 'out', olt, 'height')
A('out_atlas', 1320, 750, { size = '1024' })
A('out_macro', 1320, 850, { size = '1024' })
A('out_specular', 1320, 950, { size = '1024' })
say('graph_ms_setup', string.format('%.0f', (GetSystemTimeSeconds() - t0) * 1000))

-- 3. water, then build
R.Invalidate()
local res, err = GRun.Build()
if not res then return table.concat(out, '\n') .. '\nBUILD_FAILED=' .. tostring(err) end
say('build_ms', string.format('%.0f', res.ms))
say('layers', res.layers)
say('maptextures', res.maptextures)
say('height_changed', res.changed)
if res.warnings then
    for _, w in res.warnings do say('WARNING', tostring(w.code) .. ': ' .. tostring(w.text)) end
end
if res.kinds then
    for _, e in res.kinds do say('kind', string.format('%s %.1f%% layer %s', tostring(e.label), e.share * 100, tostring(e.layer))) end
end
for _, s in res.slow do
    if s.ms > 400 then say('slow', string.format('%s %.0f', tostring(Graph.NodeById(s.id).type), s.ms)) end
end

-- 4. what is in the map now
Fields.Run(function(S)
    for layer = 1, 8 do
        local f = S:Stratum(layer, true)
        local lo, hi, mean = Fields.Stats(f)
        say('mask' .. layer, string.format('%.1f/%.1f/%.1f', lo, hi, mean))
    end
end)
for _, kind in { 'normal', 'light', 'macro', 'specular', 'atlas' } do
    local cur = MT.Current(kind)
    if cur and type(cur.path) == 'string' and cur.path ~= '' then
        local disk = ed_vfs_to_disk(cur.path) or '?'
        say('map_' .. kind, string.format('%s|layer %s|managed %s|empty %s', disk, tostring(cur.slot and cur.slot.layer), tostring(cur.managed), tostring(cur.empty)))
    end
end
for l = 0, 9 do
    local path, tile = ed_stratum_layer(l)
    local npath, ntile = ed_stratum_layer(l + 10)
    say('layer' .. l, string.format('%s tile %s | normal %s tile %s', tostring(path), tostring(tile), tostring(npath), tostring(ntile)))
end
say('total_ms', string.format('%.0f', (GetSystemTimeSeconds() - t0) * 1000))
return table.concat(out, '\n')
