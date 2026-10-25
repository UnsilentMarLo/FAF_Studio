-- Gives the shipped terrain graphs the shader aware texturing tail (docs/projects/editor/GRAPH_TEXTURING.md): the texture layer outputs a graph had (a few Output: ground kind nodes with hand made
-- masks) are replaced by Ground kinds -> Output: ground kinds, fed from the heights the graph writes, with the style that fits the landscape. A graph that has no texture output gets the tail too
-- (a landscape without paint is the grey default). Masks that only fed the old outputs are removed.
--
-- Run it in a test instance (python scripts/editor_inst.py cmd <tag> scripts/graph_preset_upgrade.lua); the graphs are written to <instance>/graphs_upgraded/<id>.lua, and
-- python scripts/graph_preset_install.py copies them over editor/runtime/lua/editor/graphpresets/ (keeping the comment line of each file). Safe to run again: a graph that has Output: ground kinds is left alone.
--
-- Lua 5.0 dialect.

local Graph = import('/lua/editor/graph.lua')
local Index = import('/lua/editor/graphpresets/index.lua')
local Recipes = import('/lua/editor/recipes.lua')

-- the style (Stratum recipes style id) of each landscape
local STYLE = {
    mountains = 'alpine', island = 'coast', canyon = 'desert', hills = 'valley', desert = 'desert', river_valley = 'valley', symmetric = 'valley', archipelago = 'coast',
    crater = 'valley', badlands = 'desert', plains = 'valley', two_players = 'valley',
    lib_duel_turn = 'valley', lib_duel_river = 'valley', lib_ffa4_corners = 'valley', lib_ffa4_diag = 'valley', lib_hex6 = 'valley', lib_two_islands = 'coast',
    lib_archipelago_fair = 'coast', lib_canyon_river = 'desert', lib_highlands = 'alpine', lib_desert_dunes = 'desert', lib_tropics = 'coast', lib_alpine = 'alpine',
    lib_badlands = 'desert', lib_moon = 'rocky', lib_volcano = 'rocky', lib_tundra = 'arctic', lib_rift_valley = 'valley', lib_mesa_fortress = 'desert', lib_wetlands = 'coast',
}
-- Flatten gentle ground before the output: { slope limit (degrees), smoothing distance (units), strength } (open ground with crisp features, see GRAPH_TEXTURING.md)
local FLATTEN = {
    hills = { 12, 40, 0.9 }, river_valley = { 12, 40, 0.9 }, symmetric = { 12, 40, 0.9 }, plains = { 8, 50, 0.9 }, two_players = { 12, 40, 0.9 },
    lib_duel_turn = { 12, 40, 0.9 }, lib_duel_river = { 12, 40, 0.9 }, lib_ffa4_corners = { 12, 40, 0.9 }, lib_hex6 = { 12, 40, 0.9 },
    lib_tropics = { 14, 30, 0.7 }, lib_tundra = { 10, 50, 0.9 }, lib_wetlands = { 8, 60, 0.9 }, island = { 14, 30, 0.7 },
}
local SKIP = { pathable = true, pathing = true, texturing = true, lib_colour_pass = true }

local function NodeOf(id) return Graph.NodeById(id) end

--- The node ids that lead into an output node (everything else is dead weight after the old outputs went).
local function Reachable()
    local def = import('/lua/editor/graphnodes.lua').Defs
    local need = {}
    local stack = {}
    for _, n in Graph.Current.nodes do
        local d = def[n.type]
        if d and d.output then
            need[n.id] = true
            table.insert(stack, n.id)
        end
    end
    while table.getn(stack) > 0 do
        local id = table.remove(stack)
        for _, w in Graph.Current.wires do
            if w[3] == id and not need[w[1]] then
                need[w[1]] = true
                table.insert(stack, w[1])
            end
        end
    end
    return need
end

local report = {}
local depth = 0
for _, p in Index.List do
    local id = p.id
    if not SKIP[id] then
        local ok = Graph.LoadPreset(id)
        local g = Graph.Current
        local oh, hasKinds = nil, false
        for _, n in g.nodes do
            if n.type == 'out_height' and not oh then oh = n end
            if n.type == 'out_kinds' then hasKinds = true end
        end
        local changed = false
        local notes = {}
        if not ok then
            table.insert(report, id .. ': does not load')
        elseif not oh then
            table.insert(report, id .. ': no height output, left alone')
        else
            local srcId, srcPort
            for _, w in g.wires do
                if w[3] == oh.id and w[4] == 'a' then srcId, srcPort = w[1], w[2] end
            end
            if not srcId then
                table.insert(report, id .. ': the height output has no wire, left alone')
            else
                -- 1. the texturing tail
                if not hasKinds then
                    local old = {}
                    for _, n in g.nodes do
                        if n.type == 'out_role' or n.type == 'out_layer' then table.insert(old, n.id) end
                    end
                    -- what fed the old outputs (the masks that were made for them) ...
                    local fed = {}
                    local stack = {}
                    for _, oid in old do table.insert(stack, oid) end
                    while table.getn(stack) > 0 do
                        local nid = table.remove(stack)
                        for _, w in g.wires do
                            if w[3] == nid and not fed[w[1]] then
                                fed[w[1]] = true
                                table.insert(stack, w[1])
                            end
                        end
                    end
                    if table.getn(old) > 0 then Graph.Remove(old) end
                    -- ... goes too when nothing else needs it (a view node of the graph that was not for the paint stays)
                    local need = Reachable()
                    local dead = {}
                    for _, n in g.nodes do
                        if fed[n.id] and not need[n.id] then table.insert(dead, n.id) end
                    end
                    if table.getn(dead) > 0 then Graph.Remove(dead) end
                    local gk = Graph.Add('ground_kinds', oh.x, oh.y + 190, { style = STYLE[id] or 'temperate' })
                    local ok2 = Graph.Add('out_kinds', oh.x + 330, oh.y + 190, {})
                    Graph.Connect(srcId, srcPort, gk.id, 'a')
                    for _, role in Recipes.Order do Graph.Connect(gk.id, role, ok2.id, role) end
                    table.insert(notes, string.format('tail added (%d old outputs, %d dead nodes)', table.getn(old), table.getn(dead)))
                    changed = true
                else
                    -- 2. the style of the landscape
                    for _, n in g.nodes do
                        if n.type == 'ground_kinds' and STYLE[id] and n.params.style ~= STYLE[id] then
                            Graph.SetParam(n.id, 'style', STYLE[id])
                            table.insert(notes, 'style ' .. STYLE[id])
                            changed = true
                        end
                    end
                end
                -- 3. flatten the gentle ground
                local want = FLATTEN[id]
                local hasFlat = false
                for _, n in g.nodes do
                    if n.type == 'flatten' then hasFlat = true end
                end
                if want and not hasFlat then
                    local f = Graph.Add('flatten', oh.x - 40, oh.y - 150, { below = want[1], radius = want[2], strength = want[3] })
                    -- between the node that feeds the height output and the output
                    for _, w in g.wires do
                        if w[3] == oh.id and w[4] == 'a' then srcId, srcPort = w[1], w[2] end
                    end
                    Graph.Connect(srcId, srcPort, f.id, 'a')
                    Graph.Connect(f.id, 'out', oh.id, 'a')
                    -- the ground kinds read the flattened ground too
                    for _, n in g.nodes do
                        if n.type == 'ground_kinds' then Graph.Connect(f.id, 'out', n.id, 'a') end
                    end
                    table.insert(notes, 'flatten ' .. want[1] .. ' / ' .. want[2])
                    changed = true
                end
                if changed then
                    ed_write_file('../graphs_upgraded/' .. id .. '.lua', Graph.Text())
                    table.insert(report, id .. ': ' .. table.concat(notes, ', '))
                else
                    table.insert(report, id .. ': nothing to do')
                end
            end
        end
    end
end
Graph.New('untitled')
return table.concat(report, '\n')
