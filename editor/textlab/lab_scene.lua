-- lab scene: LAB = { terrain = 'mountains', theme = 'temperate', recipe = 1, seed = 3, water = true, amp = nil }
local L = rawget(_G, 'LAB') or {}
local Gen = import('/lua/editor/fieldgen.lua')
local TS = import('/lua/editor/texsets.lua')
local R = import('/lua/editor/recipes.lua')
local World = import('/lua/editor/world.lua')
local History = import('/lua/editor/history.lua')
local o = {}
local t0 = GetSystemTimeSeconds()
local function Stage(name) table.insert(o, string.format('[%5.1fs] %s', GetSystemTimeSeconds() - t0, name)) end
ed_gpu_enable(false)
-- 1. flat map, theme, terrain
Stage('start')
if L.terrain then
    Gen.Choose(L.terrain)
    Gen.Settings.seed = L.seed or 3
    if L.amp then Gen.Settings.amplitude = L.amp end
    Gen.Settings.blend = 'replace'
    Gen.Settings.keepFlat = false
    Gen.Settings.keepWater = false
    local r, why = Gen.Build()
    if not r then return 'terrain failed ' .. tostring(why) end
    Gen.Commit(r) Gen.Free(r)
end
if L.graph and L.theme then TS.Apply(L.theme) end          -- the texture set first: applying it clears the paint, and a graph paints
if L.graph then
    -- a premade terrain graph of the Generate workspace, built at full resolution (L.graph = preset id; L.graphs = more ids built one after the other)
    local Graph = import('/lua/editor/graph.lua')
    local GRun = import('/lua/editor/graphrun.lua')
    for _, id in (L.graphs or { L.graph }) do
        local ok, why = Graph.LoadPreset(id)
        if not ok then return 'graph ' .. id .. ' failed: ' .. tostring(why) end
        if L.seed then Graph.Current.seed = L.seed end
        GRun.Refresh(true)
        local r, why2 = GRun.Build()
        if not r then return 'graph ' .. id .. ' did not build: ' .. tostring(why2) end
        table.insert(o, string.format('graph %s: %s samples, %s layers, %.0f ms', id, tostring(r.changed), tostring(r.layers), r.ms or 0))
    end
end
if L.shader then import('/lua/editor/shaders.lua').Set(L.shader) end
Stage('terrain done')
if L.theme then TS.Apply(L.theme) end
R.Invalidate()
if L.water ~= nil then
    local st = R.Stats()
    local lvl = R.HeightAt(st, L.waterShare or 0.12)
    World.Change({ water_on = L.water and 1 or 0, water_elev = lvl, water_deep = lvl - 12, water_abyss = lvl - 30 }, { refresh = true })
    R.Invalidate()
end
Stage('theme + water done')
if L.recipe then
    R.SelectPreset(L.recipe)
    R.State.layers = nil
    local summary, cells = R.Apply()
    if not summary then table.insert(o, 'recipe failed ' .. tostring(cells)) else
        for _, e in summary do table.insert(o, string.format('%-34s %5.1f%%  layer %s', e.label, e.share * 100, tostring(e.layer))) end
    end
end
Stage('recipe done')
if L.post then
    local f = loadstring(L.post)
    local r = f()
    if r then table.insert(o, tostring(r)) end
end
Stage('post done')
if L.sel then
    local MaskGen = import('/lua/editor/maskgen.lua')
    local Fields = import('/lua/editor/fields.lua')
    local roles = R.Roles()
    Fields.Run(function(S)
        local c = MaskGen.NewContext(S, { step = 1 })
        for _, r in roles do
            if not r.base and not r.off and table.getn(r.rules) > 0 then
                local m = MaskGen.Evaluate(c, { rules = r.rules })
                local mn, mx, mean = Fields.Stats(m)
                table.insert(o, string.format('  selection %-9s mean %.3f max %.2f', r.id, mean, mx))
            end
        end
    end)
end
Stage('end')
return table.concat(o, '\n')
