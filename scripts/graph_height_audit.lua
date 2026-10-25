-- Builds every terrain graph of the shipped set on the open map and prints how tall and how steep the result is (min / max / land percentiles of the heights, share of steep ground),
-- so graphs that make needles or flat country show up. Run in a test instance with a 512 map: python scripts/graph_height_audit.py
-- AUDIT = { ids = {...} } optional.
--
-- Lua 5.0 dialect.
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local Fields = import('/lua/editor/fields.lua')
local Recipes = import('/lua/editor/recipes.lua')
local A = rawget(_G, 'AUDIT') or {}
local skip = { texturing = true, lib_colour_pass = true }
local ids = A.ids
if not ids then
    ids = {}
    for _, p in Graph.Presets() do
        local id = p.id or p
        if not skip[id] then table.insert(ids, id) end
    end
end
local out = { 'id\tmin\tmax\tspan\tp5\tp50\tp95\tp95-p5\tmeanslope\t>5\t>30' }
for _, id in ids do
    local ok, why = Graph.LoadPreset(id)
    if not ok then
        table.insert(out, id .. '\tLOAD FAILED ' .. tostring(why))
    else
        if A.seed then Graph.Current.seed = A.seed end
        GRun.Refresh(true)
        local r, why2 = GRun.Build()
        if not r then
            table.insert(out, id .. '\tBUILD FAILED ' .. tostring(why2))
        else
            Fields.Run(function(S)
                local H = S:Height(1)
                local lo, hi = Fields.Stats(H)
                local st = Recipes.StatsOf(S, H)
                local pct = st.pct
                local slope = S:Op('slope', { a = H, mode = 'degrees', radius = 1 })
                local _, _, sm = Fields.Stats(slope)
                local _, _, s5 = Fields.Stats(S:Op('threshold', { a = slope, value = 5 }))
                local _, _, s30 = Fields.Stats(S:Op('threshold', { a = slope, value = 30 }))
                table.insert(out, string.format('%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.2f\t%.2f', id, lo, hi, hi - lo, pct[6], pct[51], pct[96], pct[96] - pct[6], sm, s5, s30))
            end)
        end
    end
end
Graph.New('untitled')
return table.concat(out, '\n')
