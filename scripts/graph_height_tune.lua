-- Tunes the height amplitude of shipped terrain graphs to the numbers of real maps (docs/projects/editor/GRAPH_TEXTURING.md, "Heights"): per graph, optional parameter presets, then the
-- span (hi - lo) of the listed Height range nodes is scaled until the mean slope of the built result is the target. Writes the result to <instance>/graphs_upgraded/<id>.lua (install with
-- scripts/graph_preset_install.py). Run on a 512 map: python scripts/graph_height_tune.py [--ids a,b]
--
-- TUNE = { { id, set = { { node, key, value }, ... }, ranges = { node ids }, slope = target mean slope in degrees, maxspan = most the heights may span (optional) }, ... }   (a global set by the caller)
--
-- Lua 5.0 dialect.
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local Fields = import('/lua/editor/fields.lua')
local Recipes = import('/lua/editor/recipes.lua')
local T = rawget(_G, 'TUNE') or {}
local out = {}

local function Measure()
    local r
    Fields.Run(function(S)
        local H = S:Height(1)
        local lo, hi = Fields.Stats(H)
        local st = Recipes.StatsOf(S, H)
        local slope = S:Op('slope', { a = H, mode = 'degrees', radius = 1 })
        local _, _, sm = Fields.Stats(slope)
        local _, _, s30 = Fields.Stats(S:Op('threshold', { a = slope, value = 30 }))
        r = { slope = sm, s30 = s30, span = hi - lo, p = st.pct[96] - st.pct[6] }
    end)
    return r
end

local function Build()
    GRun.Refresh(true)
    local r, why = GRun.Build()
    if not r then return nil, why end
    return Measure()
end

for _, e in T do
    local ok, why = Graph.LoadPreset(e.id)
    if not ok then
        table.insert(out, e.id .. ' LOAD FAILED ' .. tostring(why))
    else
        for _, s in e.set or {} do Graph.SetParam(s[1], s[2], s[3]) end
        local base = {}
        for _, id in e.ranges or {} do
            local n = Graph.NodeById(id)
            base[id] = { lo = n.params.lo, hi = n.params.hi }
        end
        local K, line = 1, {}
        local final
        for iter = 1, 6 do
            for id, b in base do Graph.SetParam(id, 'hi', b.lo + (b.hi - b.lo) * K) end
            local m, err = Build()
            if not m then
                table.insert(line, 'BUILD FAILED ' .. tostring(err))
                break
            end
            table.insert(line, string.format('K %.2f slope %.1f', K, m.slope))
            final = m
            if math.abs(m.slope - e.slope) <= e.slope * 0.12 then break end
            local step = math.pow(e.slope / math.max(0.3, m.slope), 0.85)
            K = K * math.max(0.4, math.min(2.5, step))
        end
        -- a landscape with one tall feature (a volcano) has a small mean slope and still too much height: cap the total span
        if final and e.maxspan and final.span > e.maxspan then
            K = K * e.maxspan / final.span
            for id, b in base do Graph.SetParam(id, 'hi', b.lo + (b.hi - b.lo) * K) end
            local m = Build()
            if m then
                final = m
                table.insert(line, string.format('cap: K %.2f slope %.1f span %.0f', K, m.slope, m.span))
            end
        end
        if final then
            ed_write_file('../graphs_upgraded/' .. e.id .. '.lua', Graph.Text())
            table.insert(out, string.format('%s: K %.2f -> mean slope %.1f (target %g), >30 deg %.2f, span %.0f, p5-p95 %.1f   [%s]', e.id, K, final.slope, e.slope, final.s30, final.span, final.p, table.concat(line, '; ')))
        else
            table.insert(out, e.id .. ': ' .. table.concat(line, '; '))
        end
    end
end
Graph.New('untitled')
return table.concat(out, '\n')
