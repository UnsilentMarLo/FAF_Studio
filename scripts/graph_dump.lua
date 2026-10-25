-- Compact dump of shipped graphs: nodes (id, type, params) and wires. DUMP = { 'id', ... }.  Run: python scripts/editor_inst.py cmd <tag> scripts/graph_dump.lua --chars 20000
-- Lua 5.0 dialect.
local Graph = import('/lua/editor/graph.lua')
local ids = rawget(_G, 'DUMP') or {}
local out = {}
local function Val(v)
    if type(v) == 'table' then return '{..}' end
    if type(v) == 'number' then return string.format('%g', v) end
    return tostring(v)
end
for _, id in ids do
    local ok, why = Graph.LoadPreset(id)
    table.insert(out, '== ' .. id .. (ok and '' or (' FAILED ' .. tostring(why))))
    if ok then
        local g = Graph.Current
        for _, n in g.nodes do
            local ps = {}
            for k, v in n.params or {} do table.insert(ps, k .. '=' .. Val(v)) end
            table.sort(ps)
            table.insert(out, string.format('%d %s %s', n.id, n.type, table.concat(ps, ' ')))
        end
        local ws = {}
        for _, w in g.wires do table.insert(ws, w[1] .. '.' .. w[2] .. '>' .. w[3] .. '.' .. w[4]) end
        table.insert(out, 'wires ' .. table.concat(ws, ' '))
    end
end
Graph.New('untitled')
return table.concat(out, '\n')
