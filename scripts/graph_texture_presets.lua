-- Builds the two texturing graphs of the shipped set with the graph API (docs/projects/editor/GRAPH_TEXTURING.md) and writes them to <instance>/graphs_upgraded/:
--   texturing        Map heights -> Ground kinds -> Output: ground kinds (+ the Terrain shader node to look at what the shader paints)
--   lib_colour_pass  the same plus the pictures the shaders need (roughness mask, macrotexture, specular, roughness / height atlas) and the colour map
-- Run: python scripts/editor_inst.py cmd <tag> scripts/graph_texture_presets.lua, then python scripts/graph_preset_install.py.
--
-- Lua 5.0 dialect.

local Graph = import('/lua/editor/graph.lua')
local failed = {}
local RawConnect = Graph.Connect
local function Connect(a, ap, b, bp)
    local ok = RawConnect(a, ap, b, bp)
    if not ok then table.insert(failed, a .. '.' .. ap .. '->' .. b .. '.' .. bp) end
    return ok
end
local Recipes = import('/lua/editor/recipes.lua')

local function Col(c) return c * 224 end
local function Row(r) return r * 152 end

local function Kinds(g, from, style, x, y)
    local gk = Graph.Add('ground_kinds', x, y, { style = style })
    Connect(from.id, 'out', gk.id, 'a')
    local ok = Graph.Add('out_kinds', x + 330, y, {})
    for _, role in Recipes.Order do Connect(gk.id, role, ok.id, role) end
    return gk, ok
end

-- 1. texturing
Graph.New('Texture the existing terrain (ground kinds for any shader)')
Graph.Current.seed = 1
local t = Graph.Add('terrain', Col(0), Row(0))
Kinds(Graph.Current, t, 'temperate', Col(1), Row(0))
Graph.Add('terrain_shader', Col(0), Row(2))
ed_write_file('../graphs_upgraded/texturing.lua', Graph.Text())

-- 2. the colour pass
Graph.New('Texture, roughness and colour pass (no height change)')
Graph.Current.seed = 40
t = Graph.Add('terrain', Col(0), Row(0))
local gk, ok = Kinds(Graph.Current, t, 'temperate', Col(1), Row(0))
-- the roughness the shader reads (PBR shaders): from the kinds, written to layer 8
local sr = Graph.Add('surface_roughness', Col(3), Row(2), {})
for _, role in { 'grass', 'dirt', 'wet', 'sand', 'rock', 'darkrock', 'highrock', 'snow' } do Connect(gk.id, role, sr.id, role) end
local orough = Graph.Add('out_roughness', Col(4), Row(2), {})
Connect(sr.id, 'out', orough.id, 'a')
-- the pictures made from the paint that the older and the PBR shaders read
Graph.Add('out_macro', Col(3), Row(4), {})
Graph.Add('out_specular', Col(3), Row(5), {})
Graph.Add('out_atlas', Col(3), Row(6), {})
-- the colour map: the heights, normalised, through the terrain colour ramp
local nz = Graph.Add('normalize', Col(1), Row(3), { lo = 0, hi = 1 })
Connect(t.id, 'out', nz.id, 'a')
local cr = Graph.Add('color_ramp', Col(2), Row(3), { ramp = 'terrain' })
Connect(nz.id, 'out', cr.id, 'a')
local cm = Graph.Add('out_colormap', Col(3), Row(3), { path = 'graphs/library_colormap.dds', size = 512 })
Connect(cr.id, 'rgba', cm.id, 'rgba')
-- the map-wide pictures of the shader (the Combine block of the reference: Normal Map Maker, Select Roughness): the normal map and the baked light (shadow and occlusion)
local nm = Graph.Add('normal_map', Col(1), Row(7), {})
Connect(t.id, 'out', nm.id, 'a')
local onm = Graph.Add('out_normalmap', Col(2), Row(7), {})
Connect(nm.id, 'rgba', onm.id, 'normal')
local lt = Graph.Add('lighting_tex', Col(1), Row(8), {})
Connect(t.id, 'out', lt.id, 'a')
local oml = Graph.Add('out_maplight', Col(2), Row(8), {})
Connect(lt.id, 'shadow', oml.id, 'shadow')
Connect(lt.id, 'ao', oml.id, 'ao')
ed_write_file('../graphs_upgraded/lib_colour_pass.lua', Graph.Text())
Graph.New('untitled')
return 'ok, failed connections: ' .. table.concat(failed, ' ')
