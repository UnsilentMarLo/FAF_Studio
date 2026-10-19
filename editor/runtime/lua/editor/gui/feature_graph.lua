-- The terrain graph's commands and its claim on the editing keys. A self-registering feature module (gui/feature_*.lua are imported by the shell). While the pointer is over the Graph canvas,
-- Copy, Paste, Duplicate, Delete, Undo and Redo act on the graph (nodes, wires, the graph's own undo stack), not on the map. Docs: docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Canvas()
    local ok, mod = pcall(import, '/lua/editor/gui/panels_graph.lua')
    if ok then return mod end
    return nil
end

local function Active()
    local mod = Canvas()
    return mod and mod.PointerInside() and true or false
end

local function Tick()
    local mod = Canvas()
    if mod and mod.live.canvas then mod.live.canvas:Tick(true) end
end

Commands.Intercept(function(id)
    if id ~= 'edit.copy' and id ~= 'edit.cut' and id ~= 'edit.paste' and id ~= 'edit.duplicate' and id ~= 'edit.delete' and id ~= 'edit.undo' and id ~= 'edit.redo' then return false end
    if not Active() then return false end
    if id == 'edit.copy' then
        Graph.CopyNodes(Graph.Sel)
        Say('copied ' .. table.getn(Graph.SelectedList()) .. ' nodes')
    elseif id == 'edit.cut' then
        Graph.CopyNodes(Graph.Sel)
        Graph.Remove(Graph.Sel)
    elseif id == 'edit.paste' then
        local mod = Canvas()
        local pos = mod and mod.live.canvas and mod.live.canvas.pointer     -- GetMouseScreenPos is not tracked over panels
        local view = Graph.Current.view
        local x, y = mod.ViewCentre()
        if pos and mod.live.canvas then
            x = (pos[1] - mod.live.canvas.bg.Left() - view.x) / view.zoom
            y = (pos[2] - mod.live.canvas.bg.Top() - view.y) / view.zoom
        end
        Graph.Paste(x, y)
    elseif id == 'edit.duplicate' then
        Graph.Duplicate(Graph.Sel)
    elseif id == 'edit.delete' then
        if Graph.SelWire then
            Graph.RemoveWire(Graph.SelWire)
        elseif next(Graph.Sel) ~= nil then
            Graph.Remove(Graph.Sel)
        end
    elseif id == 'edit.undo' then
        if not Graph.Undo() then Say('nothing to undo in the graph') end
    elseif id == 'edit.redo' then
        if not Graph.Redo() then Say('nothing to redo in the graph') end
    end
    Tick()
    return true
end)

Commands.Register{ id = 'graph.build', title = 'Graph: build (heights, layers, types, props: one undo step)', run = function()
    local r, err = GRun.Build()
    Say(r and string.format('graph built in %.0f ms', r.ms) or ('graph not built: ' .. tostring(err)))
    Tick()
end }
Commands.Register{ id = 'graph.preview', title = 'Graph: show the preview on the terrain', run = function()
    local n, err = GRun.ShowOnTerrain()
    Say(n and ('graph preview on the terrain: ' .. n .. ' samples') or ('no preview: ' .. tostring(err)))
end }
Commands.Register{ id = 'graph.revert', title = 'Graph: take the preview off the terrain', run = function() GRun.RevertTerrain() end }
Commands.Register{ id = 'graph.fit', title = 'Graph: fit the canvas to the nodes', run = function()
    local mod = Canvas()
    if mod and mod.live.canvas then mod.live.canvas:Fit() end
end }
