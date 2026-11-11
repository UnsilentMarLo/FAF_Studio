-- The material editor's panels (WP10 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md, docs/projects/editor/WP10_MATERIAL.md). The model is material.lua (upstream's texture graph, bound as ed_tex_*).
--
--   material       the graph: nodes with pictures, wires between their pins, pan with the middle / right button or by dragging the background, drag a node to move it, drag from a pin to
--                  another pin to link (a linked input dragged away is taken off), right click a node or a pin for its menu, "Add node" (or a right click on the background) lists the palette.
--   materialnode   the selected node: what it does, its warning, its parameters (sliders, switches, choices, colours, texture paths).
--   materialout    the result: the Output's Albedo / Normal / Mask or a lit sphere / plane, the preview size, and Apply: bake at a size, write the DDS files, set them as the textures of a
--                  layer (and paint its mask), as one undo step.
--
-- A drawing is a Bitmap per node frame with its title, thumbnail and pin dots as children (a child follows its parent); a wire is a few axis aligned Bitmaps from a pool. The canvas clips
-- its children (Control:SetClipChildren) when the engine has it.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group
local Dragger = import('/lua/maui/dragger.lua').Dragger
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local UI = import('/lua/editor/ui.lua')
local M = import('/lua/editor/material.lua')

live = {}

-- node geometry in logical pixels
local NW, HEAD, ROW, THUMB, PAD = 150, 20, 16, 64, 5
local PORT = 9

view = { x = 24, y = 24 }          -- the canvas' pan, kept across panel instances

local PIN_COLOR = { grey = 'ffb4b4b4', colour = 'ffe6b84a' }
local CAT_COLOR = {
    Noise = '3f4f7fa8', Constants = '3f5a5a5a', Textures = '3f8a5a3a', Map = '3f3f8a5a', Math = '3f7a5f9a', Adjust = '3fa0783a', Blend = '3f3a8a8a', UV = '3f8a8a3a',
    Normal = '3f5a6aa8', Channels = '3fa04f6f', Output = '3f2a8a4a',
}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function Scale() return Skin.S(100) / 100 end

--- Is there a texture graph to show?
local function Ready()
    return M.Available() and M.Doc and true or false
end

local function HasThumb(def)
    return def and not def.output and def.outputs[1] ~= nil
end

local function Rows(def)
    return math.max(table.getn(def.inputs), table.getn(def.outputs), 1)
end

local function NodeH(def)
    return HEAD + PAD + Rows(def) * ROW + (HasThumb(def) and (PAD + THUMB) or 0) + PAD
end

--- Position (logical, graph coordinates) of a pin: side 'in' | 'out', pin 0-based.
local function PinAt(node, def, side, pin)
    local x = node.x + (side == 'out' and NW or 0)
    local y = node.y + HEAD + PAD + pin * ROW + ROW / 2
    return x, y
end

-- ---- the Graph panel --------------------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'material', title = 'Material graph', minW = 380, minH = 260,
    stack = { workspace = 'Generate', with = 'graphcanvas' },
    create = function(group, host)
        local Pn = { views = {}, wires = {}, wireUsed = 0, ghost = {}, ghostUsed = 0, cw = 400, ch = 300, w = false, shownStamp = -1, shownSel = false, picKey = {} }
        live.canvas = Pn
        local c = Skin.color

        local bg = Bitmap(group)
        bg.Depth:Set(function() return group.Depth() + 20 end)
        bg:SetSolidColor('ff14171a')
        if bg.SetClipChildren then pcall(function() bg:SetClipChildren(true) end) end
        Pn.bg = bg

        local function Put(ctl, x, y, w, h)
            ctl.Left:Set(function() return bg.Left() + x end)
            ctl.Top:Set(function() return bg.Top() + y end)
            if w then ctl.Width:Set(w) end
            if h then ctl.Height:Set(h) end
        end

        -- ---- wires (a pool of axis aligned bitmaps) ----------------------------------------------------------------------------------
        local function PoolBit(list, index, depth)
            local b = list[index]
            if not b then
                b = Bitmap(bg)
                b.Depth:Set(function() return bg.Depth() + depth end)
                b:DisableHitTest()
                b.col = false
                list[index] = b
            end
            return b
        end

        local function Seg(list, usedKey, depth, x0, y0, x1, y1, col, th)
            local ax, bx = math.min(x0, x1), math.max(x0, x1)
            local ay, by = math.min(y0, y1), math.max(y0, y1)
            local half = math.floor(th / 2)
            if ax == bx then ax = ax - half bx = ax + th else ay = ay - half by = ay + th end
            Pn[usedKey] = Pn[usedKey] + 1
            local b = PoolBit(list, Pn[usedKey], depth)
            if b.col ~= col then
                b:SetSolidColor(col)
                b.col = col
            end
            Put(b, math.floor(ax), math.floor(ay), math.max(1, math.floor(bx - ax)), math.max(1, math.floor(by - ay)))
            b:Show()
        end

        local function ResetPool(list, usedKey)
            for i = Pn[usedKey] + 1, table.getn(list) do list[i]:Hide() end
        end

        local function Route(x1, y1, x2, y2)
            local z = Scale()
            local gap = 16 * z
            if x2 >= x1 + 2 * gap then
                local xm = math.floor((x1 + x2) / 2)
                return { { x1, y1, xm, y1 }, { xm, y1, xm, y2 }, { xm, y2, x2, y2 } }
            end
            local xa, xb = x1 + gap, x2 - gap
            local ym = math.floor((y1 + y2) / 2)
            if math.abs(y2 - y1) < 6 then ym = y1 + 40 * z end
            return { { x1, y1, xa, y1 }, { xa, y1, xa, ym }, { xa, ym, xb, ym }, { xb, ym, xb, y2 }, { xb, y2, x2, y2 } }
        end

        local function DrawWire(x1, y1, x2, y2, col, th, ghost)
            for _, s in Route(x1, y1, x2, y2) do
                if ghost then
                    Seg(Pn.ghost, 'ghostUsed', 40, s[1], s[2], s[3], s[4], col, th)
                else
                    Seg(Pn.wires, 'wireUsed', 3, s[1], s[2], s[3], s[4], col, th)
                end
            end
        end

        --- Screen position (canvas pixels) of a pin of a node of the snapshot.
        local function ScreenPin(node, side, pin)
            local def = M.TypeOf(node.type)
            local x, y = PinAt(node, def, side, pin)
            local z = Scale()
            return view.x + x * z, view.y + y * z
        end

        -- ---- the drags (functions of the pointer position, the Dragger only forwards) -------------------------------------------------
        local function Begin(event, Move, Release)
            local d = Dragger()
            d.OnMove = function(self, x, y) Move(x, y) end
            d.OnRelease = function(self, x, y) Release(x, y) self:Destroy() end
            d.OnCancel = function(self) Release(nil, nil) self:Destroy() end
            PostDragger(GetFrame(0), event.KeyCode, d)
        end

        function Pn.StartPan(event, onClick)
            local start = { x = event.MouseX, y = event.MouseY, vx = view.x, vy = view.y }
            local moved = false
            Begin(event, function(x, y)
                if math.abs(x - start.x) + math.abs(y - start.y) > 3 then moved = true end
                view.x, view.y = start.vx + (x - start.x), start.vy + (y - start.y)
                Pn:Layout()
            end, function(x, y)
                if x and not moved and onClick then onClick(x, y) end
            end)
        end

        function Pn.StartNodeDrag(event, id)
            M.Doc.sel = id
            Pn:Layout()
            local snap = M.Snap()
            local n = M.Node(id)
            if not n then return end
            local z = Scale()
            local start = { x = event.MouseX, y = event.MouseY, nx = n.x, ny = n.y }
            local before = M.Begin()
            local moved = false
            Begin(event, function(x, y)
                if math.abs(x - start.x) + math.abs(y - start.y) > 2 then moved = true end
                if moved then
                    M.MoveNodes({ { id, start.nx + (x - start.x) / z, start.ny + (y - start.y) / z } })
                    Pn:Layout()
                end
            end, function(x, y)
                if moved then
                    local m = M.Node(id)
                    if m then M.MoveNodes({ { id, math.floor(m.x / 8 + 0.5) * 8, math.floor(m.y / 8 + 0.5) * 8 } }) end
                    M.End('move node', before)
                end
                Pn:Layout()
            end)
        end

        --- The pin of the opposite side nearest to a canvas position, within 14 pixels.
        local function PinHit(mx, my, side)
            local best, bd = nil, Skin.S(14) * Skin.S(14)
            for _, n in M.Snap().nodes do
                local def = M.TypeOf(n.type)
                local list = side == 'in' and def.inputs or def.outputs
                for i = 1, table.getn(list) do
                    local px, py = ScreenPin(n, side, i - 1)
                    local d = (px - mx) * (px - mx) + (py - my) * (py - my)
                    if d < bd then best, bd = { node = n.id, pin = i - 1 }, d end
                end
            end
            return best
        end

        function Pn.StartWire(event, id, side, pin)
            local drag = { from = { node = id, side = side, pin = pin } }
            if side == 'in' then
                local l = M.InputLink(id, pin)
                if l then
                    -- take the wire off this input and carry its other end
                    drag.from = { node = l.fromNode, side = 'out', pin = l.fromPin }
                    drag.detached = { node = id, pin = pin }
                end
            end
            Begin(event, function(x, y)
                local n = M.Node(drag.from.node)
                if not n then return end
                local px, py = ScreenPin(n, drag.from.side, drag.from.pin)
                local mx, my = x - bg.Left(), y - bg.Top()
                Pn.ghostUsed = 0
                if drag.from.side == 'out' then DrawWire(px, py, mx, my, 'ffffffff', 2, true) else DrawWire(mx, my, px, py, 'ffffffff', 2, true) end
                ResetPool(Pn.ghost, 'ghostUsed')
            end, function(x, y)
                Pn.ghostUsed = 0
                ResetPool(Pn.ghost, 'ghostUsed')
                if not x then return end
                local target = PinHit(x - bg.Left(), y - bg.Top(), drag.from.side == 'out' and 'in' or 'out')
                local before = M.Begin()
                local done = false
                if target then
                    local ok, why
                    if drag.from.side == 'out' then
                        ok, why = M.Connect(drag.from.node, drag.from.pin, target.node, target.pin)
                    else
                        ok, why = M.Connect(target.node, target.pin, drag.from.node, drag.from.pin)
                    end
                    if not ok then Say('link: ' .. tostring(why)) end
                    if ok and drag.detached and not (drag.detached.node == target.node and drag.detached.pin == target.pin) then M.Disconnect(drag.detached.node, drag.detached.pin) end
                elseif drag.detached then
                    M.Disconnect(drag.detached.node, drag.detached.pin)
                end
                Pn:Layout()
            end)
        end

        -- ---- the menus -------------------------------------------------------------------------------------------------------------------
        --- The palette as a menu: a submenu per category; `place` = { x, y } in graph coordinates or nil (next to the selected node).
        function Pn.PaletteItems(place)
            local items = {}
            for _, cat in M.Categories() do
                local sub = {}
                for _, t in cat.types do
                    local type = t.name
                    table.insert(sub, { title = t.title, run = function()
                        local x, y
                        if place then x, y = place[1], place[2] else x, y = M.FreeSpot(type) end
                        local id, why = M.AddNode(type, math.floor(x / 8 + 0.5) * 8, math.floor(y / 8 + 0.5) * 8)
                        if not id then Say(tostring(why)) end
                        Pn:Layout()
                    end })
                end
                table.insert(items, { title = cat.name, submenu = sub })
            end
            return items
        end

        function Pn.NodeMenu(id, mx, my)
            M.Doc.sel = id
            Pn:Layout()
            local n = M.Node(id)
            local def = n and M.TypeOf(n.type)
            local items = {}
            table.insert(items, { title = 'Show in the output panel', run = function() live.outMode = 'node' if live.out then live.out:Refresh() end end })
            if def and not def.output then
                table.insert(items, { title = 'Delete', run = function() M.RemoveNode(id) Pn:Layout() end })
            end
            table.insert(items, { title = 'Disconnect inputs', run = function()
                local before = M.Begin()
                for i = 0, table.getn(def.inputs) - 1 do
                    if M.InputLink(id, i) then ed_tex_unlink(M.Doc.id, id, i) end
                end
                M.End('unlink', before)
                Pn:Layout()
            end })
            Menu.Show(GetFrame(0), mx, my, items)
        end

        function Pn.PinMenu(id, side, pin, mx, my)
            local items = {}
            if side == 'in' and M.InputLink(id, pin) then
                table.insert(items, { title = 'Disconnect', run = function() M.Disconnect(id, pin) Pn:Layout() end })
            end
            Menu.Show(GetFrame(0), mx, my, items)
        end

        function Pn.CanvasMenu(mx, my)
            local z = Scale()
            local gx, gy = (mx - bg.Left() - view.x) / z, (my - bg.Top() - view.y) / z
            Menu.Show(GetFrame(0), mx, my, Pn.PaletteItems({ gx, gy }))
        end

        bg.HandleEvent = function(self, event)
            if event.Type == 'ButtonPress' then
                local mods = event.Modifiers or {}
                if mods.Right then
                    Pn.StartPan(event, function(x, y) Pn.CanvasMenu(x, y) end)
                else
                    if not (mods.Middle) then M.Doc.sel = false Pn:Layout() end
                    Pn.StartPan(event)
                end
                return true
            elseif event.Type == 'WheelRotation' then
                view.y = view.y + (event.WheelRotation > 0 and 40 or -40)
                Pn:Layout()
                return true
            end
            return false
        end

        -- ---- node views ------------------------------------------------------------------------------------------------------------------
        local function MakeView(node)
            local def = M.TypeOf(node.type)
            local id = node.id
            local v = { id = id, type = node.type, ins = {}, outs = {}, pic = false }
            v.sel = Bitmap(bg)
            v.sel.Depth:Set(function() return bg.Depth() + 4 end)
            v.sel:SetSolidColor(c.accent)
            v.sel:DisableHitTest()
            v.frame = Bitmap(bg)
            v.frame.Depth:Set(function() return bg.Depth() + 6 end)
            v.frame:SetSolidColor('ff2a2f36')
            v.header = Bitmap(v.frame)
            v.header.Depth:Set(function() return v.frame.Depth() + 1 end)
            v.header:SetSolidColor(CAT_COLOR[def.category] or '3f55607a')
            v.header:DisableHitTest()
            v.title = W.Label(v.frame, def.title, 0, 0, { color = c.text })
            v.title.Depth:Set(function() return v.frame.Depth() + 8 end)
            if HasThumb(def) then
                v.thumbBg = Bitmap(v.frame)
                v.thumbBg.Depth:Set(function() return v.frame.Depth() + 2 end)
                v.thumbBg:SetSolidColor('ff0f1113')
                v.thumbBg:DisableHitTest()
                v.thumb = Bitmap(v.frame)
                v.thumb.Depth:Set(function() return v.frame.Depth() + 3 end)
                v.thumb:SetSolidColor('00000000')
                v.thumb:DisableHitTest()
            end
            v.frame.HandleEvent = function(self, event)
                if event.Type == 'ButtonPress' then
                    local mods = event.Modifiers or {}
                    if mods.Middle then
                        Pn.StartPan(event)
                    elseif mods.Right then
                        Pn.StartPan(event, function(x, y) Pn.NodeMenu(id, x, y) end)
                    else
                        Pn.StartNodeDrag(event, id)
                    end
                    return true
                elseif event.Type == 'WheelRotation' then
                    view.y = view.y + (event.WheelRotation > 0 and 40 or -40)
                    Pn:Layout()
                    return true
                end
                return false
            end
            local function MakePin(side, p, pin)
                local port = { name = p.name, type = p.type }
                port.dot = Bitmap(v.frame)
                port.dot.Depth:Set(function() return v.frame.Depth() + 6 end)
                port.dot:SetSolidColor(PIN_COLOR[p.type] or c.text)
                port.label = W.Label(v.frame, p.name, 0, 0, { color = c.textDim, size = 'small' })
                port.dot.HandleEvent = function(self, event)
                    if event.Type == 'ButtonPress' then
                        local mods = event.Modifiers or {}
                        if mods.Middle then
                            Pn.StartPan(event)
                        elseif mods.Right then
                            Pn.StartPan(event, function(x, y) Pn.PinMenu(id, side, pin, x, y) end)
                        else
                            Pn.StartWire(event, id, side, pin)
                        end
                        return true
                    end
                    return false
                end
                return port
            end
            for i = 1, table.getn(def.inputs) do v.ins[i] = MakePin('in', def.inputs[i], i - 1) end
            for i = 1, table.getn(def.outputs) do v.outs[i] = MakePin('out', def.outputs[i], i - 1) end
            return v
        end

        local function DestroyView(v)
            v.sel:Destroy()
            v.frame:Destroy()
        end

        local function PlaceView(v, node, def)
            local z = Scale()
            local sx, sy = math.floor(view.x + node.x * z), math.floor(view.y + node.y * z)
            local nw, nh = math.floor(NW * z), math.floor(NodeH(def) * z)
            Put(v.frame, sx, sy, nw, nh)
            Put(v.sel, sx - 2, sy - 2, nw + 4, nh + 4)
            local function In(ctl, dx, dy, w, h)
                ctl.Left:Set(function() return v.frame.Left() + dx end)
                ctl.Top:Set(function() return v.frame.Top() + dy end)
                if w then ctl.Width:Set(w) end
                if h then ctl.Height:Set(h) end
            end
            In(v.header, 0, 0, nw, math.floor(HEAD * z))
            W.Fit(v.title, def.title, nw - Skin.S(8))
            In(v.title, Skin.S(4), math.floor((math.floor(HEAD * z) - v.title.Height()) / 2))
            local ps = math.max(5, math.floor(PORT * z))
            local half = math.floor(ps / 2)
            for i, port in v.ins do
                local cy = math.floor((HEAD + PAD + (i - 1) * ROW + ROW / 2) * z)
                In(port.dot, -half, cy - half, ps, ps)
                In(port.label, ps, cy - math.floor(port.label.Height() / 2))
            end
            for i, port in v.outs do
                local cy = math.floor((HEAD + PAD + (i - 1) * ROW + ROW / 2) * z)
                In(port.dot, nw - half - 1, cy - half, ps, ps)
                In(port.label, nw - ps - port.label.Width() - 2, cy - math.floor(port.label.Height() / 2))
            end
            if v.thumb then
                local ty = math.floor((HEAD + PAD + Rows(def) * ROW + PAD) * z)
                local tz = math.floor(THUMB * z)
                local tx = math.floor((nw - tz) / 2)
                In(v.thumbBg, tx, ty, tz, tz)
                In(v.thumb, tx, ty, tz, tz)
            end
        end

        function Pn:Layout()
            if not Ready() then return end
            local snap = M.Snap()
            local present = {}
            for _, n in snap.nodes do
                present[n.id] = true
                local old = self.views[n.id]
                if old and old.type ~= n.type then
                    DestroyView(old)
                    self.views[n.id] = nil
                end
                if not self.views[n.id] then self.views[n.id] = MakeView(n) end
            end
            for id, v in self.views do
                if not present[id] then
                    DestroyView(v)
                    self.views[id] = nil
                end
            end
            for _, n in snap.nodes do
                local v = self.views[n.id]
                PlaceView(v, n, M.TypeOf(n.type))
                if M.Doc.sel == n.id then v.sel:Show() else v.sel:Hide() end
            end
            self.wireUsed = 0
            for _, l in snap.links do
                local a, b = M.Node(l.fromNode), M.Node(l.toNode)
                if a and b then
                    local x1, y1 = ScreenPin(a, 'out', l.fromPin)
                    local x2, y2 = ScreenPin(b, 'in', l.toPin)
                    local def = M.TypeOf(a.type)
                    local col = PIN_COLOR[def.outputs[l.fromPin + 1] and def.outputs[l.fromPin + 1].type or 'grey'] or 'ffb4b4b4'
                    DrawWire(x1, y1, x2, y2, col, 2, false)
                end
            end
            ResetPool(self.wires, 'wireUsed')
            self.shownStamp = M.Doc.stamp
            self.shownSel = M.Doc.sel
        end

        --- The thumbnails and warnings after an evaluation.
        function Pn:Pictures()
            if not Ready() then return end
            for id, v in self.views do
                local n = M.Node(id)
                if n then
                    local info = M.NodeInfo(id)
                    local warn = info and info.warning ~= ''
                    v.title:SetColor(warn and c.warn or c.text)
                    if v.thumb then
                        local pic = M.Picture(id, 0, THUMB)
                        if pic ~= v.pic then
                            v.pic = pic
                            if pic then v.thumb:SetTexture(pic) else v.thumb:SetSolidColor('00000000') end
                        end
                    end
                end
            end
        end

        -- ---- the toolbar -----------------------------------------------------------------------------------------------------------------
        local function Btn(text, w, fn, tip, toggle)
            return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, { tip = tip, toggle = toggle })
        end
        Pn.buttons = {}
        local function Add(b) table.insert(Pn.buttons, b) return b end
        Add(Btn('New', 44, function() M.New('start') Pn:Layout() Pn:Pictures() end, 'Start a new texture graph: a noise through a gradient map into the albedo, its height into the normal map.'))
        Add(Btn('Open...', 56, function()
            local items = {}
            for _, name in M.Files() do
                local file = name
                table.insert(items, { title = file, run = function()
                    local ok, why = M.Open(file)
                    if not ok then Say('open: ' .. tostring(why)) end
                    Pn:Layout()
                end })
            end
            if table.getn(items) == 0 then items = { { title = 'No saved graphs yet', header = true } } end
            Menu.Show(GetFrame(0), Pn.buttons[2].Left(), Pn.buttons[2].Bottom(), items)
        end, 'Open a graph saved in the materials folder.'))
        Add(Btn('Save', 44, function()
            local name = Pn.name:GetText()
            local ok, why = M.Save(name ~= '' and name or nil)
            Say(ok and ('saved materials/' .. M.Doc.name .. M.EXT) or ('save: ' .. tostring(why)))
            Pn.name:SetText(M.Doc.name)
        end, 'Save the graph as materials/<name>.fafgraph.json.'))
        Pn.name = W.TextField(group, 0, 0, Skin.S(110), Skin.S(22), { text = 'untitled', onEnter = function(text) end, tip = 'The graph\'s file name (Save writes it into the materials folder).' })
        Pn.nameBtn = Pn.name
        Add(Btn('Add node', 64, function()
            Menu.Show(GetFrame(0), Pn.buttons[4].Left(), Pn.buttons[4].Bottom(), Pn.PaletteItems(nil))
        end, 'List the node types by category. The new node goes right of the selected node and is linked to it when it can take its output.'))
        Add(Btn('Undo', 44, function() M.Undo() Pn:Layout() end, 'Undo the last edit of the graph.'))
        Add(Btn('Redo', 44, function() M.Redo() Pn:Layout() end, 'Redo what was undone.'))
        Add(Btn('Delete', 52, function() if M.Doc.sel then M.RemoveNode(M.Doc.sel) Pn:Layout() end end, 'Delete the selected node (the output node stays).'))
        Add(Btn('Fit', 36, function() Pn:Fit() end, 'Show the whole graph.'))
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        function Pn:Fit()
            if not Ready() then return end
            local snap = M.Snap()
            local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
            for _, n in snap.nodes do
                x0, y0 = math.min(x0, n.x), math.min(y0, n.y)
                x1, y1 = math.max(x1, n.x + NW), math.max(y1, n.y + NodeH(M.TypeOf(n.type)))
            end
            local z = Scale()
            view.x = math.floor((self.cw - (x1 - x0) * z) / 2 - x0 * z)
            view.y = math.floor((self.ch - (y1 - y0) * z) / 2 - y0 * z)
            self:Layout()
        end

        function Pn:Tick()
            if self.dead or not self.w then return end
            if not Ready() then return end
            if self.shownStamp ~= M.Doc.stamp or self.shownSel ~= M.Doc.sel then self:Layout() end
            self:Pictures()
            if self.nameFor ~= M.Doc then
                self.nameFor = M.Doc
                self.name:SetText(M.Doc.name)
            end
            local text = M.Status ~= '' and M.Status or (M.Doc.name .. (M.Modified() and ' *' or '') .. ': ' .. table.getn(M.Snap().nodes) .. ' nodes' ..
                (M.Doc.lastMillis and string.format(', %d computed in %.0f ms at %d', M.Doc.lastComputed or 0, M.Doc.lastMillis, M.PreviewSize) or ''))
            if text ~= self.statusText then
                self.statusText = text
                W.Fit(self.status, text, self.w - Skin.S(12))
            end
            self.status:SetColor(M.StatusKind == 'error' and c.error or (M.StatusKind == 'warn' and c.warn or c.textDim))
        end

        function Pn:OnResize(w, h)
            self.w, self.h = w, h
            local pad = Skin.S(6)
            local x, y = pad, pad
            local rowH = Skin.S(26)
            for i, b in self.buttons do
                if x > pad and x + b.Width() > w - pad then
                    x = pad
                    y = y + rowH
                end
                W.Place(b, group, x, y, b.Width(), Skin.S(22))
                x = x + b.Width() + Skin.S(4)
                if i == 3 then
                    if x + Skin.S(110) > w - pad then x = pad y = y + rowH end
                    W.Place(self.name.frame, group, x, y, Skin.S(110), Skin.S(22))
                    x = x + Skin.S(114)
                end
            end
            W.Place(self.status, group, pad, y + rowH + Skin.S(2))
            local top = y + rowH + Skin.S(20)
            self.cw, self.ch = w, math.max(Skin.S(80), h - top)
            bg.Left:Set(function() return group.Left() end)
            bg.Top:Set(function() return group.Top() + top end)
            bg.Width:Set(self.cw)
            bg.Height:Set(self.ch)
            if not Ready() then
                if not self.note then
                    self.note = W.Label(group, M.Available() and 'No graph yet: press New.' or 'This engine build has no texture graph natives (ed_tex_*).', pad, top + Skin.S(6), { color = c.textDim })
                end
                if M.Available() and not M.Doc then M.New('start') end
            end
            if Ready() then
                if self.note then self.note:Hide() end
                if not self.fitted then
                    self.fitted = true
                    self:Fit()
                end
                self:Layout()
            end
            self.statusText = nil
        end

        function Pn:Destroy()
            self.dead = true
            if live.canvas == self then live.canvas = nil end
        end

        if M.Available() and not M.Doc then M.New('start') end
        return Pn
    end,
}

-- ---- the node's parameters --------------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'materialnode', title = 'Material node', minW = 240, minH = 200,
    stack = { workspace = 'Generate', with = 'graphinspector' },
    create = function(group, host)
        local P = { w = 300, h = 400, key = false, stamp = -1, ctl = {} }
        live.node = P
        local c = Skin.color
        P.title = W.Label(group, '', 0, 0, { color = c.text })
        P.type = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.warn = W.Label(group, '', 0, 0, { color = c.warn, size = 'small' })
        P.none = W.Label(group, 'Select a node of the graph.', 0, 0, { color = c.textDim })
        P.body = false

        local function Clear()
            if P.body then P.body:Destroy() P.body = false end
            P.sliders = {}
        end

        --- The control of parameter `index` (0-based) of the selected node `id`, placed at y; returns the y after it.
        local function Control(body, id, def, index, y, w)
            local p = def.params[index + 1]
            local function Cur() local n = M.Node(id) return n and n.params[index + 1] end
            local function Set(v, key) M.SetParam(id, index, v, key) end
            local pad = Skin.S(8)
            local kind = p.kind
            if kind == 'float' or kind == 'int' then
                local isInt = kind == 'int'
                local span = p.max - p.min
                local s = W.Slider(body, { label = p.name, min = p.min, max = p.max, step = isInt and 1 or math.max(span / 1000, 0.001), fmt = isInt and '%d' or '%.3g',
                    get = function() local q = Cur() return q and q.v[1] or p.initial[1] end,
                    set = function(v) Set({ v = v }, 'slider') end, tip = p.help ~= '' and p.help or ('The ' .. p.name .. ' of the node.') })
                s:Place(pad, y, w - 2 * pad)
                s:Refresh()
                table.insert(P.sliders, s)
                return y + Skin.S(48)
            elseif kind == 'bool' then
                local b
                b = W.Button(body, p.name, pad, y, w - 2 * pad, Skin.S(22), function()
                    local q = Cur()
                    Set({ v = (q and q.v[1] ~= 0) and 0 or 1 })
                    b:SetOn(not (q and q.v[1] ~= 0))
                end, { toggle = true, tip = p.help ~= '' and p.help or ('Turn ' .. p.name .. ' on or off.') })
                local q = Cur()
                b:SetOn(q and q.v[1] ~= 0 or false)
                return y + Skin.S(28)
            elseif kind == 'choice' then
                W.Label(body, p.name, pad, y + Skin.S(3), { color = c.textDim })
                local q = Cur()
                local b
                b = W.Button(body, p.choices[math.floor((q and q.v[1] or 0) + 1)] or '?', Skin.S(110), y, w - Skin.S(110) - pad, Skin.S(22), function()
                    local items = {}
                    for i = 1, table.getn(p.choices) do
                        local value = i - 1
                        table.insert(items, { title = p.choices[i], run = function() Set({ v = value }) end })
                    end
                    Menu.Show(GetFrame(0), b.Left(), b.Bottom(), items)
                end, { tip = p.help ~= '' and p.help or ('Choose the ' .. p.name .. '.') })
                return y + Skin.S(28)
            elseif kind == 'colour' then
                W.Label(body, p.name, pad, y + Skin.S(3), { color = c.textDim })
                local sw = Bitmap(body)
                sw.Depth:Set(function() return body.Depth() + 6 end)
                W.Place(sw, body, Skin.S(110), y, w - Skin.S(110) - pad, Skin.S(20))
                P.swatch = { bitmap = sw, id = id, index = index }
                local q = Cur()
                local function Paint()
                    local v = (Cur() or { v = p.initial }).v
                    local function B(x) return math.max(0, math.min(255, math.floor(x * 255 + 0.5))) end
                    sw:SetSolidColor(string.format('ff%02x%02x%02x', B(v[1]), B(v[2]), B(v[3])))
                end
                Paint()
                y = y + Skin.S(24)
                for ch = 1, 4 do
                    local channel = ch
                    local s = W.Slider(body, { label = ({ 'Red', 'Green', 'Blue', 'Alpha' })[ch], min = 0, max = 1, step = 0.01, fmt = '%.2f',
                        get = function() local cur = Cur() return cur and cur.v[channel] or 0 end,
                        set = function(v)
                            local cur = Cur()
                            local value = { cur.v[1], cur.v[2], cur.v[3], cur.v[4] }
                            value[channel] = v
                            Set({ v = value }, 'slider')
                            Paint()
                        end, tip = 'The colour\'s ' .. ({ 'red', 'green', 'blue', 'alpha' })[ch] .. ' (0 to 1).' })
                    s:Place(pad, y, w - 2 * pad)
                    s:Refresh()
                    table.insert(P.sliders, s)
                    y = y + Skin.S(48)
                end
                return y
            elseif kind == 'text' then
                W.Label(body, p.name, pad, y + Skin.S(3), { color = c.textDim })
                local q = Cur()
                local field = W.TextField(body, Skin.S(80), y, w - Skin.S(80) - pad, Skin.S(22), { text = q and q.text or '', onEnter = function(text) Set({ text = text }) end,
                    tip = p.help ~= '' and p.help or 'A texture file of the game (a path such as /env/evergreen/layers/rock001_albedo.dds); press Enter.' })
                y = y + Skin.S(26)
                local pick
                pick = W.Button(body, 'Layer textures...', pad, y, Skin.S(130), Skin.S(22), function()
                    local items = {}
                    local Strata = import('/lua/editor/strata.lua')
                    for _, l in Strata.Layers() do
                        for _, which in { 'albedo', 'normal' } do
                            local path = which == 'albedo' and l.albedo or l.normal
                            if path and path ~= '' then
                                local file = path
                                table.insert(items, { title = l.name .. ' ' .. which .. ': ' .. string.gsub(path, '^.*/', ''), run = function() field:SetText(file) Set({ text = file }) end })
                            end
                        end
                    end
                    Menu.Show(GetFrame(0), pick.Left(), pick.Bottom(), items)
                end, { tip = 'Pick one of the open map\'s layer textures.' })
                return y + Skin.S(28)
            end
            return y
        end

        function P:Build()
            Clear()
            local id = Ready() and M.Doc.sel
            local n = id and M.Node(id)
            local def = n and M.TypeOf(n.type)
            self.id = id
            self.key = id and (id .. ':' .. n.type) or false
            if not def then
                self.title:SetText('')
                self.type:SetText('')
                self.warn:SetText('')
                self.none:Show()
                return
            end
            self.none:Hide()
            local pad = Skin.S(8)
            local w = self.w
            self.title:SetText(def.title)
            self.type:SetText(def.category .. ' node')
            local body = Group(group)
            body.Depth:Set(function() return group.Depth() + 4 end)
            body.Left:Set(function() return group.Left() end)
            body.Top:Set(function() return group.Top() + self.bodyTop end)
            body.Width:Set(w)
            body.Height:Set(10)
            self.body = body
            local y = 0
            if def.help ~= '' then
                local labels, bottom = W.Paragraph(body, import('/lua/editor/consolelog.lua').BreakWords(def.help, math.max(12, math.floor((w - 2 * pad) / Skin.S(6)))), pad, y, w - 2 * pad,
                    { color = c.textDim, size = 'small' }, Skin.S(14), y + 12 * Skin.S(14))
                y = bottom + Skin.S(6)
            end
            for i = 0, table.getn(def.params) - 1 do
                y = Control(body, id, def, i, y, w)
            end
        end

        --- The values the sliders show after an undo or an edit made elsewhere.
        function P:Values()
            for _, s in self.sliders or {} do s:Refresh() end
            if self.swatch then
                local n = M.Node(self.swatch.id)
                local def = n and M.TypeOf(n.type)
                local q = n and n.params[self.swatch.index + 1]
                if q then
                    local function B(x) return math.max(0, math.min(255, math.floor(x * 255 + 0.5))) end
                    self.swatch.bitmap:SetSolidColor(string.format('ff%02x%02x%02x', B(q.v[1]), B(q.v[2]), B(q.v[3])))
                end
            end
        end

        function P:Tick()
            if self.dead or not self.w then return end
            if not Ready() then return end
            local id = M.Doc.sel
            local n = id and M.Node(id)
            local key = n and (id .. ':' .. n.type) or false
            if key ~= self.key then
                self:Build()
                self.stamp = M.Doc.stamp
            elseif self.stamp ~= M.Doc.stamp then
                self.stamp = M.Doc.stamp
                self:Values()
            end
            if n then
                local info = M.NodeInfo(id)
                local warning = info and info.warning or ''
                if warning ~= self.warnText then
                    self.warnText = warning
                    W.Fit(self.warn, warning ~= '' and ('Warning: ' .. warning) or '', self.w - Skin.S(16))
                end
            else
                self.warnText = nil
            end
        end

        function P:OnResize(w, h)
            self.w, self.h = w, h
            local pad = Skin.S(8)
            W.Place(self.title, group, pad, pad)
            W.Place(self.type, group, pad, pad + Skin.S(18))
            W.Place(self.warn, group, pad, pad + Skin.S(34))
            W.Place(self.none, group, pad, pad + Skin.S(60))
            self.bodyTop = pad + Skin.S(52)
            self.key = false           -- the controls are laid out again for the new width
        end

        function P:Destroy()
            self.dead = true
            if live.node == self then live.node = nil end
        end

        return P
    end,
}

-- ---- the result and Apply ---------------------------------------------------------------------------------------------------------------------

local MODES = { { 'albedo', 'Albedo' }, { 'normal', 'Normal' }, { 'mask', 'Mask' }, { 'sphere', 'Sphere' }, { 'plane', 'Plane' }, { 'node', 'Node' } }
live.outMode = 'albedo'

Panels.Register{
    id = 'materialout', title = 'Material output', minW = 260, minH = 300,
    stack = { workspace = 'Generate', with = 'graphgallery' },
    create = function(group, host)
        local P = { w = 300, h = 400, pic = false, picKey = false }
        live.out = P
        local c = Skin.color
        local pad = Skin.S(8)

        P.modes = {}
        for _, m in MODES do
            local mode = m[1]
            local b
            b = W.Button(group, m[2], 0, 0, Skin.S(52), Skin.S(22), function() live.outMode = mode P:Refresh() end,
                { toggle = true, tip = ({ albedo = 'The output\'s Albedo: the colours the layer shows.', normal = 'The output\'s Normal map.', mask = 'The output\'s Mask: where the layer is painted on the map.',
                    sphere = 'A lit sphere with the albedo and the normal map.', plane = 'A lit plane with the texture repeated 2 x 2: a seam would show at the middle lines.',
                    node = 'The picture of the selected node.' })[mode] })
            P.modes[mode] = b
        end
        P.frame = Bitmap(group)
        P.frame.Depth:Set(function() return group.Depth() + 5 end)
        P.frame:SetSolidColor('ff0f1113')
        P.picture = Bitmap(group)
        P.picture.Depth:Set(function() return group.Depth() + 6 end)
        P.picture:SetSolidColor('00000000')
        P.picNote = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        P.preview = W.Slider(group, { label = 'Preview size', stops = { 64, 128, 256, 512 }, fmt = '%d', get = function() return M.PreviewSize end,
            set = function(v) M.SetPreviewSize(v) P:Refresh() end, tip = 'The resolution the graph is evaluated at while you edit (a smaller one answers faster). Apply bakes at its own size.' })
        P.turn = W.Slider(group, { label = 'Turn (lit views)', min = 0, max = 6.28, step = 0.05, fmt = '%.2f', get = function() return M.Opts.yaw end,
            set = function(v) M.Opts.yaw = v P:Refresh() end, tip = 'Turns the sphere or the plane.' })
        P.light = W.Slider(group, { label = 'Light (lit views)', min = -3.14, max = 3.14, step = 0.05, fmt = '%.2f', get = function() return M.Opts.light end,
            set = function(v) M.Opts.light = v P:Refresh() end, tip = 'Turns the light around the lit view.' })

        P.head = W.Label(group, 'Apply to a layer', 0, 0, { color = c.text })
        P.layer = W.Slider(group, { label = 'Layer (0 base, 1 to 8 painted)', min = 0, max = 8, step = 1, fmt = '%d', get = function() return M.Opts.stratum end,
            set = function(v) M.Opts.stratum = v P:Refresh() end, tip = 'The texture layer that gets the albedo and the normal map. 0 is the base layer; 1 to 8 are the layers that are painted on the map.' })
        P.size = W.Slider(group, { label = 'Bake size', stops = { 256, 512, 1024, 2048, 4096 }, fmt = '%d', get = function() return M.Opts.size end,
            set = function(v) M.Opts.size = v end, tip = 'The size of the textures Apply writes (pixels a side). The graph is evaluated again at this size.' })
        P.tile = W.Slider(group, { label = 'Tile size (0 keeps the layer\'s)', min = 0, max = 200, step = 1, fmt = '%d', get = function() return M.Opts.tile end,
            set = function(v) M.Opts.tile = v end, tip = 'How many game units the texture repeats over. 0 keeps the layer\'s own tile size (10 when it has none).' })
        P.mask = W.Button(group, 'Paint the layer\'s mask from Mask', 0, 0, Skin.S(220), Skin.S(22), function() M.Opts.mask = not M.Opts.mask P:Refresh() end,
            { toggle = true, tip = 'Also paints the layer\'s mask (the map\'s own mask grid) from the output\'s Mask input. One undo step undoes the textures and the paint together.' })
        P.apply = W.Button(group, 'Apply to layer', 0, 0, Skin.S(120), Skin.S(24), function()
            local ok, why = M.Apply(M.Opts)
            if not ok then Say('apply: ' .. tostring(why)) end
            P:Refresh()
        end, { tip = 'Bakes the graph at the bake size, writes the albedo (BC3) and normal map (BC1) as DDS files and sets them as the layer\'s textures. Undo puts the layer back.' })
        P.mapdata = W.Button(group, 'Refresh map data', 0, 0, Skin.S(130), Skin.S(24), function() M.CaptureTerrain() P:Refresh() end,
            { tip = 'Reads the map\'s heights and layer masks again for the Map Height, Map Mask and Map Slope nodes (they follow the terrain by themselves, but not a mask painted since).' })
        P.layerNote = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.statusLines = {}

        local function ModeButtons() for mode, b in P.modes do b:SetOn(live.outMode == mode) end end

        --- The picture for the mode, a VFS path or nil.
        local function Picture()
            if not Ready() then return nil end
            local size = M.PreviewSize
            local mode = live.outMode
            if mode == 'albedo' then return M.OutputPicture('Albedo', size) end
            if mode == 'normal' then return M.OutputPicture('Normal', size) end
            if mode == 'mask' then return M.OutputPicture('Mask', size) end
            if mode == 'sphere' then return M.LitPicture(0, size, M.Opts.yaw, M.Opts.light) end
            if mode == 'plane' then return M.LitPicture(1, size, M.Opts.yaw, M.Opts.light) end
            local id = M.Doc.sel
            if id and M.TypeOf(M.Node(id).type) and M.TypeOf(M.Node(id).type).outputs[1] then return M.Picture(id, 0, size) end
            return nil
        end

        function P:Refresh()
            if self.dead or not self.w or not Ready() then return end
            ModeButtons()
            self.mask:SetOn(M.Opts.mask)
            self.apply:SetOn(M.Job and true or false)
            for _, s in { self.preview, self.turn, self.light, self.layer, self.size, self.tile } do s:Refresh() end
            local path, why = Picture()
            if path ~= self.pic then
                self.pic = path
                if path then self.picture:SetTexture(path) else self.picture:SetSolidColor('00000000') end
            end
            local note = path and '' or (live.outMode == 'node' and 'Select a node.' or (live.outMode == 'sphere' or live.outMode == 'plane') and 'Link the output\'s Albedo.' or 'Nothing is linked to that output.')
            if note ~= self.noteText then
                self.noteText = note
                self.picNote:SetText(note)
            end
            local albedo, size = ed_stratum_layer(M.Opts.stratum)
            local text = 'Layer ' .. M.Opts.stratum .. ' now: ' .. ((albedo and albedo ~= '') and string.gsub(albedo, '^.*/', '') or 'no texture') .. (size and (', tile ' .. size) or '')
            if text ~= self.layerText then
                self.layerText = text
                W.Fit(self.layerNote, text, self.w - 2 * pad)
            end
            local status = M.Status
            if M.Job then
                local p = M.BakeProgress() or 0
                status = string.format('Baking at %d: %d%%', M.Job.size, math.floor(p * 100))
            end
            local key = status .. '|' .. M.StatusKind .. '|' .. self.w
            if key ~= self.statusKey then
                self.statusKey = key
                for _, l in self.statusLines do l:Destroy() end
                local lines = W.Paragraph(group, import('/lua/editor/consolelog.lua').BreakWords(status, math.max(12, math.floor((self.w - 2 * pad) / Skin.S(6)))), pad, self.statusY or 0, self.w - 2 * pad,
                    { color = M.StatusKind == 'error' and c.error or (M.StatusKind == 'warn' and c.warn or c.textDim), size = 'small' }, Skin.S(14), (self.statusY or 0) + 6 * Skin.S(14))
                self.statusLines = lines
            end
        end

        function P:Tick()
            if self.dead or not self.w then return end
            self:Refresh()
        end

        function P:OnResize(w, h)
            self.w, self.h = w, h
            local x, y = pad, pad
            for _, m in MODES do
                local b = self.modes[m[1]]
                if x + b.Width() > w - pad and x > pad then x = pad y = y + Skin.S(26) end
                W.Place(b, group, x, y, b.Width(), Skin.S(22))
                x = x + b.Width() + Skin.S(3)
            end
            y = y + Skin.S(30)
            local side = math.max(Skin.S(64), math.min(w - 2 * pad, Skin.S(300)))
            W.Place(self.frame, group, pad, y, side, side)
            W.Place(self.picture, group, pad + 1, y + 1, side - 2, side - 2)
            W.Place(self.picNote, group, pad + Skin.S(6), y + Skin.S(6))
            y = y + side + Skin.S(6)
            for _, s in { self.preview, self.turn, self.light } do
                s:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(48)
            end
            y = y + Skin.S(6)
            W.Place(self.head, group, pad, y)
            y = y + Skin.S(22)
            W.Place(self.layerNote, group, pad, y)
            y = y + Skin.S(18)
            for _, s in { self.layer, self.size, self.tile } do
                s:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(48)
            end
            W.Place(self.mask, group, pad, y, math.min(Skin.S(220), w - 2 * pad), Skin.S(22))
            y = y + Skin.S(28)
            W.Place(self.apply, group, pad, y, Skin.S(120), Skin.S(24))
            W.Place(self.mapdata, group, pad + Skin.S(126), y, Skin.S(130), Skin.S(24))
            y = y + Skin.S(30)
            self.statusY = y
            self.statusKey = nil
            self.layerText = nil
            self:Refresh()
        end

        function P:Destroy()
            self.dead = true
            if live.out == self then live.out = nil end
        end

        return P
    end,
}

--- Ticked about four times a second by the shell: the model first, then the panels that show it.
function Refresh()
    if not M.Available() then return end
    local ok, err = pcall(M.Refresh)
    if not ok then LOG('EDITOR material: refresh failed: ' .. tostring(err)) end
    for _, key in { 'canvas', 'node', 'out' } do
        local P = live[key]
        if P and not P.dead and P.w and P.Tick then
            local ok2, err2 = pcall(P.Tick, P)
            if not ok2 then LOG('EDITOR material: panel ' .. key .. ' failed: ' .. tostring(err2)) end
        end
    end
end
