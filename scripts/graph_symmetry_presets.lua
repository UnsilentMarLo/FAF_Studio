-- Gives every shipped graph that has a Symmetrize (or Mirror) node the graph-level symmetry of that node (gensym.lua: what the graph writes is made symmetric whatever the nodes after it do),
-- the others follow the map. Writes to <instance>/graphs_upgraded/<id>.lua (install with scripts/graph_preset_install.py). Idempotent.
-- Run: python scripts/editor_inst.py cmd <tag> scripts/graph_symmetry_presets.lua
--
-- Lua 5.0 dialect.
local Graph = import('/lua/editor/graph.lua')
local out = {}
local MIRROR = { x = 'mirror_x', z = 'mirror_z', xz = 'mirror_xz', rot2 = 'rot2', rot4 = 'rot4', diag = 'diag', adiag = 'adiag' }
for _, p in Graph.Presets() do
    local ok = Graph.LoadPreset(p.id)
    if ok then
        local found
        for _, n in Graph.Current.nodes do
            if not found and not n.off then
                if n.type == 'symmetrize' then
                    local m = n.params.mode or 'mirror_x'
                    found = (m == 'rotn') and { mode = 'rotn', n = math.floor((n.params.n or 3) + 0.5) } or m
                elseif n.type == 'mirror' then
                    found = MIRROR[n.params.mode or 'x']
                end
            end
        end
        if found or Graph.Current.symmetry ~= nil then
            Graph.Current.symmetry = found
            ed_write_file('../graphs_upgraded/' .. p.id .. '.lua', Graph.Text())
            table.insert(out, p.id .. ': ' .. (type(found) == 'table' and ('rotn ' .. found.n) or tostring(found)))
        end
    end
end
Graph.New('untitled')
return table.concat(out, '\n')
