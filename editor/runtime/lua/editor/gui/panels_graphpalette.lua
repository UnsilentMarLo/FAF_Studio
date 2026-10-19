-- The node palette of the terrain graph: every node type of graphnodes.lua by category with a search field (label, id, keywords), and the graph library (sample graphs shipped with the
-- editor and the ones you saved). A click on a node type adds it to the canvas; when one node is selected the new node is placed to its right and the selected node's first output is wired
-- to the new node's first input, so a chain is built by clicking. Docs: docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap

live = {}
state = { tab = 'nodes', search = '', name = 'my graph', text = '', offset = 0, thumb = false, note = '' }

local function Say(text)
    pcall(function() UI.Say(text) end)
end

--- Adds a node of `type` to the graph: next to the selected node (and wired to it), else at the middle of the visible canvas. Returns the node.
function AddNode(type)
    local def = Nodes.Defs[type]
    if not def then return nil end
    local sel = Graph.SelectedList()
    local from = (table.getn(sel) == 1) and Graph.NodeById(sel[1]) or nil
    local canvas = import('/lua/editor/gui/panels_graph.lua')
    local x, y
    if from then
        x, y = from.x + 200, from.y
    else
        x, y = canvas.ViewCentre()
        state.offset = math.mod(state.offset + 1, 6)
        x, y = x + state.offset * 24, y + state.offset * 24
    end
    x, y = canvas.FreeSpot(math.floor(x / 8 + 0.5) * 8, math.floor(y / 8 + 0.5) * 8, type)      -- never on top of a node (a click on stacked nodes picks the lower one)
    local node = Graph.Add(type, x, y)
    if not node then return nil end
    if from then
        local outs = {}
        for _, p in Nodes.Outputs(from.type) do
            if not p.hidden then table.insert(outs, p) end
        end
        local firstIn = Nodes.Inputs(type)[1]
        if outs[1] and firstIn and not firstIn.param then
            local ok = Graph.CanConnect(from.id, outs[1].name, node.id, firstIn.name)
            if ok and not Graph.WireInto(node.id, firstIn.name) then Graph.Connect(from.id, outs[1].name, node.id, firstIn.name) end
        end
    end
    Graph.SelectOne(node.id)
    canvas.Reveal(node)                                                                  -- a node added off screen would look like a click that did nothing
    if canvas.live.canvas then canvas.live.canvas:Tick(true) end
    return node
end

Panels.Register{
    id = 'graphpalette', title = 'Nodes', minW = 200, minH = 200,
    create = function(group, host)
        local Pn = { items = {} }
        live.palette = Pn
        local c = Skin.color
        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        Pn.bNodes = Btn('Nodes', 60, function() state.tab = 'nodes' Pn:OnResize(Pn.w, Pn.h) end, { toggle = false })
        Pn.bGraphs = Btn('Graphs', 60, function() state.tab = 'graphs' Pn:OnResize(Pn.w, Pn.h) end, { toggle = false })
        Pn.search = W.TextField(group, 0, 0, 100, Skin.S(22), {
            text = state.search,
            onChange = function(text)
                state.search = text
                Pn:Rebuild(true)
            end,
        })
        Pn.nameLabel = W.Label(group, 'Name', 0, 0, { color = c.textDim, size = 'small' })
        Pn.nameField = W.TextField(group, 0, 0, 100, Skin.S(22), { text = state.name, onChange = function(text) state.name = text end })
        Pn.bSave = Btn('Save', 54, function()
            local name = state.name
            if name == '' then state.text = 'give the graph a name' else
                local ok = Graph.Save(name)
                state.text = ok and ('saved graphs/' .. name .. '.lua') or 'saving failed'
            end
            Pn:Rebuild()
        end)
        Pn.bNew = Btn('New', 44, function()
            Graph.Edit('new graph', function()
                Graph.Current.nodes = {}
                Graph.Current.wires = {}
                Graph.Sel = {}
            end)
            state.text = 'empty graph (Undo brings the old one back)'
            Pn:Rebuild()
        end)
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        -- the thumbnail and the README line of the library graph that was loaded last (stage T7)
        Pn.picFrame = Bitmap(group)
        Pn.picFrame.Depth:Set(function() return group.Depth() + 5 end)
        Pn.picFrame:SetSolidColor(c.line)
        Pn.pic = Bitmap(Pn.picFrame)
        Pn.pic.Depth:Set(function() return Pn.picFrame.Depth() + 1 end)
        Pn.pic:SetSolidColor('00000000')
        Pn.pic:DisableHitTest()
        -- a first position for both (all four edges): an unset pair is a circular LazyVar the engine evaluates before the first layout
        Pn.picFrame.Left:Set(-20000) Pn.picFrame.Top:Set(-20000) Pn.picFrame.Width:Set(1) Pn.picFrame.Height:Set(1)
        Pn.pic.Left:Set(-20000) Pn.pic.Top:Set(-20000) Pn.pic.Width:Set(1) Pn.pic.Height:Set(1)
        Pn.noteLines = {}

        Pn.items = {}
        Pn.list = W.VirtualList(group, {
            rowH = 20,
            getCount = function() return table.getn(Pn.items) end,
            bind = function(row, index)
                local it = Pn.items[index]
                local text = it.text
                local col = c.text
                if it.kind == 'cat' then
                    col = c.accent
                elseif it.kind == 'node' then
                    text = '   ' .. text
                    if it.tip then row.text:SetText(text) end
                elseif it.kind == 'file' then
                    text = '   ' .. text
                end
                W.Fit(row.text, text, math.max(Skin.S(40), row.bg.Width() - Skin.S(12)))
                row.text:SetColor(col)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            bgColor = c.panelAlt,
            onSelect = function(index)
                local it = Pn.items[index]
                if not it then return end
                if it.kind == 'node' then
                    local n = AddNode(it.id)
                    state.text = n and ('added ' .. Nodes.Defs[it.id].label .. ' - ' .. (Nodes.Defs[it.id].desc or '')) or ''
                elseif it.kind == 'preset' then
                    Pn:LoadPreset(it)
                elseif it.kind == 'file' then
                    local ok, err = Graph.LoadFile(it.id)
                    state.text = ok and ('opened graphs/' .. it.id .. '.lua') or ('failed: ' .. tostring(err))
                    state.name = it.id
                    Pn.nameField:SetText(it.id)
                    Pn:AfterLoad()
                end
                Pn:Refresh()
            end,
        })

        --- Loads a sample / library graph (a list item { id, text, note, library }): the thumbnail and the README line of a library graph stay in the panel.
        function Pn:LoadPreset(it)
            local ok, err = Graph.LoadPreset(it.id)
            state.text = ok and ('loaded ' .. it.text .. ' (Undo brings the old graph back)') or ('failed: ' .. tostring(err))
            state.thumb, state.note = false, it.note or ''
            local path = nil
            if ok and it.library then
                path = import('/lua/editor/graphlib.lua').ThumbPath(it.id)
                if path then state.thumb = path end
            end
            Pn:OnResize(Pn.w, Pn.h)
            if path then pcall(function() Pn.pic:SetTexture(path) end) end
            state.name = it.text
            Pn.nameField:SetText(it.text)
            Pn:AfterLoad()
            return ok
        end

        function Pn:AfterLoad()
            local canvas = import('/lua/editor/gui/panels_graph.lua')
            local cv = canvas.live.canvas
            if cv then
                cv:Fit()
                cv:Tick(true)
            end
        end

        function Pn:Rebuild(keepScroll)
            local list = {}
            if state.tab == 'nodes' then
                if state.search ~= '' then
                    for _, id in Nodes.Search(state.search) do
                        table.insert(list, { kind = 'node', id = id, text = Nodes.Defs[id].label, tip = true })
                    end
                else
                    for _, cat in Nodes.Cats do
                        table.insert(list, { kind = 'cat', text = cat.label })
                        for _, id in Nodes.InCat(cat.id) do
                            table.insert(list, { kind = 'node', id = id, text = Nodes.Defs[id].label })
                        end
                    end
                end
            else
                table.insert(list, { kind = 'cat', text = 'Library: ready maps (SC pads, symmetry, pathing)' })
                for _, p in Graph.Presets() do
                    if p.library then table.insert(list, { kind = 'preset', id = p.id, text = p.name, note = p.note, library = true }) end
                end
                table.insert(list, { kind = 'cat', text = 'Sample graphs' })
                for _, p in Graph.Presets() do
                    if not p.library then table.insert(list, { kind = 'preset', id = p.id, text = p.name, note = p.note }) end
                end
                table.insert(list, { kind = 'cat', text = 'Saved graphs' })
                for _, name in Graph.Files() do table.insert(list, { kind = 'file', id = name, text = name }) end
            end
            self.items = list
            self.list:Refresh()
            self:Refresh()
        end

        function Pn:Refresh()
            self.bNodes:SetOn(state.tab == 'nodes')
            self.bGraphs:SetOn(state.tab == 'graphs')
            W.Fit(self.status, state.text, (self.w or 260) - Skin.S(16))
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            W.Place(self.bNodes, group, pad, y, Skin.S(60), Skin.S(22))
            W.Place(self.bGraphs, group, pad + Skin.S(64), y, Skin.S(60), Skin.S(22))
            y = y + Skin.S(28)
            if state.tab == 'nodes' then
                W.Place(self.search.frame, group, pad, y, w - 2 * pad, Skin.S(22))
                self.search.Width:Set(w - 2 * pad - 2)
                self.search.frame.Left:Set(function() return group.Left() + pad end)
                y = y + Skin.S(28)
            else
                self.search.frame.Left:Set(-20000)
            end
            if state.tab == 'graphs' then
                W.Place(self.nameLabel, group, pad, y + 4)
                W.Place(self.nameField.frame, group, pad + Skin.S(40), y, w - 2 * pad - Skin.S(40) - Skin.S(104), Skin.S(22))
                self.nameField.Width:Set(w - 2 * pad - Skin.S(40) - Skin.S(104) - 2)
                self.nameField:SetText(state.name)         -- an Edit clips its text to the width it had when the text was set: set it again at the final width
                W.Place(self.bSave, group, w - pad - Skin.S(100), y, Skin.S(54), Skin.S(22))
                W.Place(self.bNew, group, w - pad - Skin.S(44), y, Skin.S(44), Skin.S(22))
                y = y + Skin.S(28)
            else
                self.nameLabel.Left:Set(-20000)
                self.nameField.frame.Left:Set(-20000)
                self.bSave.Left:Set(-20000)
                self.bNew.Left:Set(-20000)
            end
            W.Place(self.status, group, pad, y)
            y = y + Skin.S(18)
            if state.tab == 'graphs' and state.thumb then
                local size = Skin.S(112)
                local py = y                                            -- the layout functions run later, when y has moved on
                self.picFrame.Left:Set(function() return group.Left() + pad end)
                self.picFrame.Top:Set(function() return group.Top() + py end)
                self.picFrame.Width:Set(size + 2)
                self.picFrame.Height:Set(size + 2)
                self.pic.Left:Set(function() return Pn.picFrame.Left() + 1 end)
                self.pic.Top:Set(function() return Pn.picFrame.Top() + 1 end)
                self.pic.Width:Set(size)
                self.pic.Height:Set(size)
                for _, l in self.noteLines do l:Destroy() end
                self.noteLines = W.Paragraph(group, state.note, pad + size + Skin.S(8), y, math.max(Skin.S(60), w - 2 * pad - size - Skin.S(8)), { color = c.textDim, size = 'small' }, Skin.S(14), y + size)
                y = y + size + Skin.S(8)
            else
                self.picFrame.Left:Set(-20000)
                for _, l in self.noteLines do l:Destroy() end
                self.noteLines = {}
            end
            self.list:SetRect(pad, y, w - 2 * pad, math.max(Skin.S(60), h - y - pad))
            self:Rebuild()
        end

        function Pn:Destroy()
            self.dead = true
        end

        return Pn
    end,
}
