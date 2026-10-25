-- Builds the graph of the shipped set that starts from a terrain made in Gaea / World Machine and writes it to <instance>/graphs_upgraded/external_terrain.lua
-- (install with scripts/graph_preset_install.py). Run: python scripts/editor_inst.py cmd <tag> scripts/graph_interop_presets.lua
--
-- Lua 5.0 dialect.
local Graph = import('/lua/editor/graph.lua')
local Recipes = import('/lua/editor/recipes.lua')
local failed = {}
local function Connect(a, ap, b, bp)
    if not Graph.Connect(a, ap, b, bp) then table.insert(failed, a .. '.' .. ap .. '->' .. b .. '.' .. bp) end
end

Graph.New('Gaea / World Machine terrain (heights, erosion masks, ground kinds)')
Graph.Current.seed = 1
Graph.Current.symmetry = 'off'           -- an imported terrain is not symmetric: the graph does not copy a part over the rest unless asked (Symmetry button)
local ext = Graph.Add('external_terrain', 0, 0, {})
local oh = Graph.Add('out_height', 224, 0, {})
Connect(ext.id, 'out', oh.id, 'a')
local gk = Graph.Add('ground_kinds', 224, 152, { style = 'temperate' })
Connect(ext.id, 'out', gk.id, 'a')
local y = 304
for _, port in { 'wear', 'deposit', 'flow' } do
    local m = Graph.Add('external_mask', 0, y, { name = port, optional = true })
    Connect(m.id, 'out', gk.id, port)
    y = y + 152
end
local ok = Graph.Add('out_kinds', 554, 152, {})
for _, role in Recipes.Order do Connect(gk.id, role, ok.id, role) end
ed_write_file('../graphs_upgraded/external_terrain.lua', Graph.Text())
Graph.New('untitled')
return 'ok, failed connections: ' .. table.concat(failed, ' ')
