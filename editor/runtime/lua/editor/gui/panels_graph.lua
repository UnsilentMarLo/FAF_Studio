-- The Graph panel: the node canvas of the terrain graph (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5; model graph.lua, evaluation graphrun.lua, nodes graphnodes.lua).
--
-- Drawing in Maui (spike result, see the design document): a node is a Bitmap frame with its header, title, thumbnail picture and port dots as children (a child follows its parent, so moving a
-- node moves one control); a wire is a few axis aligned Bitmaps (an elbow: out, across, in) from a pool, so nothing is rotated and nothing is drawn per pixel. Maui does not clip, so
-- every piece is cut to the canvas rectangle here: a node that is only partly visible shows a cut frame without its contents. Pan: middle or right button drag; zoom: wheel (about the
-- pointer); left drag on the background: box select; left drag on a node: move the selection; drag from a port dot to another port: wire; drag a wired input away: take the wire off.
--
-- All drag logic is in Pn.Drag*(x, y) functions that the Dragger only forwards to, so the model-level self test can run them without a mouse.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Dragger = import('/lua/maui/dragger.lua').Dragger
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
local GRun = import('/lua/editor/graphrun.lua')
local Fields = import('/lua/editor/fields.lua')

live = {}

-- node geometry in logical pixels at zoom 1
local NW, HEAD, ROW, THUMB, PAD, STAT = 160, 22, 17, 72, 6, 18       -- STAT: the status line under the ports (a 'small' text is 14-15 px tall)
local PORT = 9
local MINZ, MAXZ = 0.35, 1.6

state = { onTerrain = false, mask = false, text = '', lastShow = 0, shownRevision = -1, report = false }

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function Now()
    if rawget(_G, 'GetSystemTimeSeconds') then return GetSystemTimeSeconds() end
    return 0
end

-- ---- geometry ---------------------------------------------------------------------------------------------------------------------------------------

local function VisibleOutputs(type)
    local list = {}
    for _, p in Nodes.Outputs(type) do
        if not p.hidden then table.insert(list, p) end
    end
    return list
end

local function Rows(node)
    return math.max(table.getn(Nodes.Inputs(node.type)), table.getn(VisibleOutputs(node.type)), 4)
end

--- Height of the body between the header and the status strip: the port rows, or the thumbnail when that is taller (it is 72 px, four rows are 68).
local function BodyH(node)
    return math.max(Rows(node) * ROW, THUMB)
end

local function NodeH(node)
    if node.type == 'frame' then return node.params.h or 320 end
    return HEAD + PAD + BodyH(node) + STAT
end

local function NodeW(node)
    if node.type == 'frame' then return node.params.w or 480 end
    return NW
end

local function IsFrame(node) return node.type == 'frame' end

--- Position of a port in canvas pixels (relative to the canvas corner) at the current view.
local function PortAt(view, node, side, index)
    local z = view.zoom
    local x = view.x + node.x * z + (side == 'out' and NW * z or 0)
    local y = view.y + node.y * z + (HEAD + PAD + (index - 1) * ROW + ROW / 2) * z
    return x, y
end

local function PortIndex(node, side, name)
    local list = (side == 'out') and VisibleOutputs(node.type) or Nodes.Inputs(node.type)
    for i, p in list do
        if p.name == name then return i end
    end
    return nil
end

local function Color(c) return c end

-- ---- the panel --------------------------------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'graphcanvas', title = 'Graph', minW = 360, minH = 260,
    create = function(group, host)
        local Pn = { views = {}, wires = {}, wireUsed = 0, ghost = {}, ghostUsed = 0, cw = 400, ch = 300, toolbarH = 34, layoutRev = -1, thumbVer = {} }
        live.canvas = Pn
        local c = Skin.color

        -- ---- the canvas --------------------------------------------------------------------------------------------------------------
        local bg = Bitmap(group)
        bg.Depth:Set(function() return group.Depth() + 20 end)
        bg:SetSolidColor('ff14171a')
        Pn.bg = bg

        -- GetMouseScreenPos() is {0, nan} while the pointer is over a panel (the session only tracks the cursor over the world view), so "the pointer is over the canvas" is
        -- tracked from the enter / exit events of the canvas controls (a set: the order of the exit of one control and the enter of the next does not matter).
        Pn.hover = {}
        local function Watch(ctl, event)
            local t = event.Type
            if t == 'MouseEnter' or t == 'MouseMotion' then
                Pn.hover[ctl] = true
                if event.MouseX then Pn.pointer = { event.MouseX, event.MouseY } end
            elseif t == 'MouseExit' then
                Pn.hover[ctl] = nil
            end
        end

        local function View()
            local g = Graph.Current
            g.view = g.view or { x = 0, y = 0, zoom = 1 }
            return g.view
        end
        Pn.View = View

        local function Put(ctl, x, y, w, h)
            ctl.Left:Set(function() return bg.Left() + x end)
            ctl.Top:Set(function() return bg.Top() + y end)
            if w then ctl.Width:Set(w) end
            if h then ctl.Height:Set(h) end
        end

        local function Gone(ctl)
            ctl.Left:Set(-20000)
            ctl.Top:Set(-20000)
        end

        --- A bitmap of the pool.
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

        --- A wire piece (axis aligned) cut to the canvas.
        local function Seg(list, usedKey, depth, x0, y0, x1, y1, col, th)
            local ax, bx = math.min(x0, x1), math.max(x0, x1)
            local ay, by = math.min(y0, y1), math.max(y0, y1)
            local half = math.floor(th / 2)
            if ax == bx then ax = ax - half bx = ax + th else ay = ay - half by = ay + th end
            if bx < 0 or by < 0 or ax > Pn.cw or ay > Pn.ch then return end
            ax, ay = math.max(0, ax), math.max(0, ay)
            bx, by = math.min(Pn.cw, bx), math.min(Pn.ch, by)
            if bx <= ax or by <= ay then return end
            Pn[usedKey] = Pn[usedKey] + 1
            local b = PoolBit(list, Pn[usedKey], depth)
            if b.col ~= col then
                b:SetSolidColor(col)
                b.col = col
            end
            Put(b, math.floor(ax), math.floor(ay), math.floor(bx - ax), math.floor(by - ay))
            b:Show()
        end

        local function ResetPool(list, usedKey)
            for i = Pn[usedKey] + 1, table.getn(list) do list[i]:Hide() end
        end

        -- an elbow from an output (x1, y1) to an input (x2, y2): the pieces as {x0, y0, x1, y1}
        local function Route(x1, y1, x2, y2, z)
            local gap = 18 * z
            if x2 >= x1 + 2 * gap then
                local xm = math.floor((x1 + x2) / 2)
                return { { x1, y1, xm, y1 }, { xm, y1, xm, y2 }, { xm, y2, x2, y2 } }
            end
            local xa, xb = x1 + gap, x2 - gap
            local ym = math.floor((y1 + y2) / 2)
            if math.abs(y2 - y1) < 6 then ym = y1 + 40 * z end
            return { { x1, y1, xa, y1 }, { xa, y1, xa, ym }, { xa, ym, xb, ym }, { xb, ym, xb, y2 }, { xb, y2, x2, y2 } }
        end
        Pn.Route = Route

        local function DrawWire(x1, y1, x2, y2, col, th, ghost)
            local z = View().zoom
            for _, s in Route(x1, y1, x2, y2, z) do
                if ghost then
                    Seg(Pn.ghost, 'ghostUsed', 40, s[1], s[2], s[3], s[4], col, th)
                else
                    Seg(Pn.wires, 'wireUsed', 3, s[1], s[2], s[3], s[4], col, th)
                end
            end
        end

        -- ---- node views --------------------------------------------------------------------------------------------------------------
        local function LabelColor(type) return Nodes.PortColor[type] or c.text end

        local function MakeFrameView(node)
            local v = { id = node.id, type = node.type, frame = true, parts = {}, state = 'new', shownKey = false }
            v.sel = Bitmap(bg)
            v.sel.Depth:Set(function() return bg.Depth() + 1 end)
            v.sel:SetSolidColor(c.accent)
            v.sel:DisableHitTest()
            v.body = Bitmap(bg)
            v.body.Depth:Set(function() return bg.Depth() + 2 end)
            v.body:DisableHitTest()
            v.header = Bitmap(v.body)
            v.header.Depth:Set(function() return bg.Depth() + 3 end)
            local nodeId = node.id
            v.header.HandleEvent = function(self, event)
                Watch(self, event)
                if event.Type == 'ButtonPress' then
                    local mods = event.Modifiers or {}
                    if mods.Middle or mods.Right then Pn.StartPan(event) else Pn.StartNodeDrag(event, nodeId) end
                    return true
                elseif event.Type == 'WheelRotation' then
                    Pn.Wheel(event)
                    return true
                end
                return false
            end
            v.title = W.Label(v.header, '', 0, 0, { color = c.text })
            v.title.Depth:Set(function() return bg.Depth() + 8 end)
            return v
        end

        local function MakeView(node)
            if node.type == 'frame' then return MakeFrameView(node) end
            local def = Nodes.Defs[node.type]
            local v = { id = node.id, type = node.type, parts = {}, ins = {}, outs = {}, state = 'new', zoomDone = -1, rows = -1, lastLabel = false, shownKey = false }
            v.sel = Bitmap(bg)
            v.sel.Depth:Set(function() return bg.Depth() + 4 end)
            v.sel:SetSolidColor(c.accent)
            v.sel:DisableHitTest()
            v.frame = Bitmap(bg)
            v.frame.Depth:Set(function() return bg.Depth() + 6 end)
            v.frame:SetSolidColor('ff2a2f36')
            v.header = Bitmap(v.frame)
            v.header.Depth:Set(function() return v.frame.Depth() + 1 end)
            v.header:SetSolidColor(Nodes.CatColor[def and def.cat or 'shape'] or '3f55607a')
            v.header:DisableHitTest()
            v.thumbBg = Bitmap(v.frame)
            v.thumbBg.Depth:Set(function() return v.frame.Depth() + 2 end)
            v.thumbBg:SetSolidColor('ff0f1113')
            v.thumbBg:DisableHitTest()
            v.thumb = Bitmap(v.frame)
            v.thumb.Depth:Set(function() return v.frame.Depth() + 3 end)
            v.thumb:SetSolidColor('00000000')
            v.thumb:DisableHitTest()
            v.title = W.Label(v.frame, '', 0, 0, { color = c.text })
            v.status = W.Label(v.frame, '', 0, 0, { color = c.textDim, size = 'small' })
            table.insert(v.parts, v.header) table.insert(v.parts, v.thumbBg) table.insert(v.parts, v.thumb)
            table.insert(v.parts, v.title) table.insert(v.parts, v.status)
            local nodeId = node.id
            v.frame.HandleEvent = function(self, event)
                Watch(self, event)
                if event.Type == 'ButtonPress' then
                    local mods = event.Modifiers or {}
                    if mods.Middle or mods.Right then
                        Pn.StartPan(event, mods.Right and function(x, y) Pn.ContextMenu('node', nodeId, x, y) end or nil)
                    else
                        Pn.StartNodeDrag(event, nodeId)
                    end
                    return true
                elseif event.Type == 'WheelRotation' then
                    Pn.Wheel(event)
                    return true
                end
                return false
            end
            -- ports
            local function MakePort(side, p, index)
                local port = { name = p.name, type = p.type }
                port.dot = Bitmap(v.frame)
                port.dot.Depth:Set(function() return v.frame.Depth() + 6 end)
                port.dot:SetSolidColor(LabelColor(p.type))
                port.label = W.Label(v.frame, p.name, 0, 0, { color = c.textDim, size = 'small' })
                port.dot.HandleEvent = function(self, event)
                    Watch(self, event)
                    if event.Type == 'ButtonPress' then
                        local mods = event.Modifiers or {}
                        if mods.Middle or mods.Right then
                            Pn.StartPan(event, mods.Right and function(x, y) Pn.ContextMenu('port', nodeId, x, y, { side = side, name = p.name }) end or nil)
                        else
                            Pn.StartWire(event, nodeId, side, p.name)
                        end
                        return true
                    end
                    return false
                end
                table.insert(v.parts, port.dot)
                table.insert(v.parts, port.label)
                return port
            end
            for i, p in Nodes.Inputs(node.type) do v.ins[i] = MakePort('in', p, i) end
            for i, p in VisibleOutputs(node.type) do v.outs[i] = MakePort('out', p, i) end
            return v
        end

        local function DestroyView(v)
            Pn.hover[v.frame == true and v.header or v.frame] = nil
            if v.ins then
                for _, port in v.ins do Pn.hover[port.dot] = nil end
                for _, port in v.outs do Pn.hover[port.dot] = nil end
            end
            v.sel:Destroy()
            if v.frame == true then v.body:Destroy() else v.frame:Destroy() end      -- the children go with it
        end

        --- Places the children of a node at the zoom (relative to the frame).
        local function Geometry(v, node, z)
            local def = Nodes.Defs[node.type]
            v.geo = {}                 -- every part's offset and size inside the node: a node cut by the canvas edge places them itself (ShowCut)
            v.isLabel = {}
            local function In(ctl, dx, dy, w, h)
                ctl.Left:Set(function() return v.frame.Left() + dx end)
                ctl.Top:Set(function() return v.frame.Top() + dy end)
                if w then ctl.Width:Set(w) end
                if h then ctl.Height:Set(h) end
                v.geo[ctl] = { dx, dy, w, h }
            end
            local nw = math.floor(NW * z)
            In(v.header, 0, 0, nw, math.floor(HEAD * z))
            local half = math.floor(PORT * z / 2)
            local ps = math.max(5, math.floor(PORT * z))
            -- The thumbnail sits between the port labels: it starts right of the longest input label and ends left of the longest output label (the labels are fixed-size text, so
            -- at zoom 1 a name like "edge0" is wider than the gap beside a centred thumbnail). It shrinks when the labels leave less than THUMB; the labels are hidden below zoom 0.75.
            local inW, outW = 0, 0
            if z >= 0.75 then
                for _, port in v.ins do inW = math.max(inW, port.label.Width()) end
                for _, port in v.outs do outW = math.max(outW, port.label.Width()) end
            end
            local gap = Skin.S(3)
            local lo = (inW > 0) and (ps + inW + gap) or 0
            local hi = (outW > 0) and (nw - ps - outW - gap) or nw
            local tz = math.max(Skin.S(16), math.min(math.floor(THUMB * z), hi - lo))
            local tx = math.max(lo, math.min(math.floor((nw - tz) / 2), hi - tz))
            local ty = math.floor((HEAD + PAD) * z)
            In(v.thumbBg, tx, ty, tz, tz)
            In(v.thumb, tx, ty, tz, tz)
            v.title:SetText(node.label or (def and def.label) or node.type)
            W.Fit(v.title, node.label or (def and def.label) or node.type, nw - Skin.S(10))
            In(v.title, Skin.S(5), math.floor((math.floor(HEAD * z) - v.title.Height()) / 2))
            -- the status line is centred in the strip below the ports and the thumbnail, inside the frame (it used to start inside the thumbnail's rows and ran over the bottom edge)
            local stripTop = math.floor((HEAD + PAD + BodyH(node)) * z)
            In(v.status, Skin.S(5), stripTop + math.max(0, math.floor((math.floor(STAT * z) - v.status.Height()) / 2)))
            for i, port in v.ins do
                local cy = math.floor((HEAD + PAD + (i - 1) * ROW + ROW / 2) * z)
                In(port.dot, -half, cy - half, ps, ps)
                In(port.label, ps, cy - math.floor(port.label.Height() / 2))
                v.isLabel[port.label] = true
            end
            for i, port in v.outs do
                local cy = math.floor((HEAD + PAD + (i - 1) * ROW + ROW / 2) * z)
                In(port.dot, nw - half - 1, cy - half, ps, ps)
                In(port.label, nw - ps - port.label.Width() - 2, cy - math.floor(port.label.Height() / 2))
                v.isLabel[port.label] = true
            end
            v.zoomDone = z
            v.rows = Rows(node)
        end

        local function ShowParts(v, on)
            for _, ctl in v.parts do
                if on then ctl:Show() else ctl:Hide() end
            end
        end

        -- ---- layout ------------------------------------------------------------------------------------------------------------------
        function Pn:Layout()
            local g = Graph.Current
            local view = View()
            local z = view.zoom
            self.layoutRev = Graph.Revision
            -- views of nodes that exist
            local present = {}
            for _, n in g.nodes do
                present[n.id] = true
                -- a loaded graph (preset, file, Undo of a clear) reuses ids with other node types: the old view has the wrong header colour, ports and title
                local old = self.views[n.id]
                if old and old.type ~= n.type then
                    DestroyView(old)
                    self.views[n.id] = nil
                    self.thumbVer[n.id] = nil
                end
                if not self.views[n.id] then self.views[n.id] = MakeView(n) end
            end
            for id, v in self.views do
                if not present[id] then
                    DestroyView(v)
                    self.views[id] = nil
                end
            end
            local lod = z >= 0.75
            for _, n in g.nodes do
                local v = self.views[n.id]
                local sx, sy = math.floor(view.x + n.x * z), math.floor(view.y + n.y * z)
                local sw, sh = math.floor(NodeW(n) * z), math.floor(NodeH(n) * z)
                if v.frame == true then
                    self:LayoutFrame(v, n, sx, sy, sw, sh, z)
                else
                self:LayoutNode(v, n, sx, sy, sw, sh, z, lod)
                end
            end
            self:DrawWires()
        end

        --- A frame: a translucent body with a title bar; cut to the canvas, the title only when the bar is fully visible.
        function Pn:LayoutFrame(v, n, sx, sy, sw, sh, z)
            local x0, y0, x1, y1 = math.max(0, sx), math.max(0, sy), math.min(self.cw, sx + sw), math.min(self.ch, sy + sh)
            if x1 <= x0 or y1 <= y0 then
                Gone(v.body)
                Gone(v.sel)
                v.header:Hide()
                v.title:Hide()
                return
            end
            local color = n.params.color or 'blue'
            if v.color ~= color then
                v.color = color
                v.body:SetSolidColor(Nodes.FrameColor[color] or Nodes.FrameColor.blue)
                v.header:SetSolidColor(Nodes.FrameHeader[color] or Nodes.FrameHeader.blue)
            end
            Put(v.body, x0, y0, x1 - x0, y1 - y0)
            local hh = math.floor(HEAD * z)
            local hx0, hy0 = math.max(0, sx), math.max(0, sy)
            local hx1, hy1 = math.min(self.cw, sx + sw), math.min(self.ch, sy + hh)
            if hy1 > hy0 and hx1 > hx0 then
                Put(v.header, hx0, hy0, hx1 - hx0, hy1 - hy0)
                v.header:Show()
            else
                v.header:Hide()
            end
            local text = n.params.title or ''
            if v.titleText ~= text .. '|' .. sw then
                v.titleText = text .. '|' .. sw
                W.Fit(v.title, text, math.max(10, math.min(sw, 480) - Skin.S(12)))
            end
            if sx >= 0 and sy >= 0 and hy1 == sy + hh and sx + Skin.S(6) + v.title.Width() <= self.cw then
                v.title.Left:Set(function() return bg.Left() + sx + Skin.S(6) end)
                v.title.Top:Set(function() return bg.Top() + sy + math.floor((hh - v.title.Height()) / 2) end)
                v.title:Show()
            else
                v.title:Hide()
            end
            if Graph.Sel[n.id] then
                Put(v.sel, x0 - 2, y0 - 2, x1 - x0 + 4, y1 - y0 + 4)
                v.sel:Show()
            else
                Gone(v.sel)
            end
        end

        --- A node the canvas edge cuts: its parts that fit are shown where they belong, the solid ones (header, picture background) cut to the canvas, the picture cropped with its texture
        --- coordinates; text and port dots that would cross the edge are hidden (Maui does not clip, so they would be drawn over the toolbar).
        function Pn:ShowCut(v, sx, sy, lod)
            local cw, ch = self.cw, self.ch
            for ctl, gm in v.geo do
                local w, h = gm[3] or ctl.Width(), gm[4] or ctl.Height()
                local ax, ay = sx + gm[1], sy + gm[2]
                local inside = ax >= 0 and ay >= 0 and ax + w <= cw and ay + h <= ch
                if not lod and (ctl == v.status or v.isLabel[ctl]) then
                    ctl:Hide()
                elseif ctl == v.header or ctl == v.thumbBg or ctl == v.thumb then
                    local x0, y0, x1, y1 = math.max(0, ax), math.max(0, ay), math.min(cw, ax + w), math.min(ch, ay + h)
                    if x1 <= x0 or y1 <= y0 or (ctl == v.thumb and not inside and v.noUV) then
                        ctl:Hide()
                    else
                        Put(ctl, x0, y0, x1 - x0, y1 - y0)
                        if ctl == v.thumb then
                            local ok = not v.noUV and pcall(function() ctl:SetUV((x0 - ax) / w, (y0 - ay) / h, (x1 - ax) / w, (y1 - ay) / h) end)
                            if ok then v.uvSet = true elseif not inside then v.noUV = true ctl:Hide() return end
                        end
                        ctl:Show()
                    end
                elseif inside then
                    Put(ctl, ax, ay)
                    ctl:Show()
                else
                    ctl:Hide()
                end
            end
        end

        --- Puts the picture back to its whole texture and the parts to their places inside the frame (after a cut).
        function Pn:EndCut(v)
            if v.uvSet then
                pcall(function() v.thumb:SetUV(0, 0, 1, 1) end)
                v.uvSet = false
            end
            v.zoomDone = -1
        end

        function Pn:LayoutNode(v, n, sx, sy, sw, sh, z, lod)
            do
                local state
                if sx + sw < 0 or sy + sh < 0 or sx > self.cw or sy > self.ch then
                    state = 'off'
                elseif sx >= 0 and sy >= 0 and sx + sw <= self.cw and sy + sh <= self.ch then
                    state = lod and 'full' or 'low'
                else
                    state = 'cut'
                end
                if v.state == 'cut' and state ~= 'cut' then self:EndCut(v) end
                if v.zoomDone ~= z or v.rows ~= Rows(n) or (v.lastLabel or '') ~= (n.label or '') then
                    Geometry(v, n, z)
                    v.lastLabel = n.label or ''
                end
                if state == 'off' then
                    Gone(v.frame)
                    Gone(v.sel)
                else
                    local x0, y0, x1, y1 = sx, sy, sx + sw, sy + sh
                    if state == 'cut' then
                        x0, y0, x1, y1 = math.max(0, x0), math.max(0, y0), math.min(self.cw, x1), math.min(self.ch, y1)
                    end
                    Put(v.frame, x0, y0, x1 - x0, y1 - y0)
                    if Graph.Sel[n.id] then
                        Put(v.sel, x0 - 2, y0 - 2, x1 - x0 + 4, y1 - y0 + 4)
                        v.sel:Show()
                    else
                        Gone(v.sel)
                    end
                end
                if state == 'cut' then
                    self:ShowCut(v, sx, sy, lod)
                    v.title:SetColor(c.text)
                elseif state ~= v.state then
                    ShowParts(v, state ~= 'off')
                end
                v.state = state
                if state == 'full' or state == 'low' then
                    v.title:SetColor(c.text)
                    if state == 'low' then
                        v.status:Hide()
                        for _, p in v.ins do p.label:Hide() end
                        for _, p in v.outs do p.label:Hide() end
                    end
                end
            end
        end

        function Pn:DrawWires()
            local g = Graph.Current
            local view = View()
            self.wireUsed = 0
            local selNode = nil
            for id, _ in Graph.Sel do selNode = id end
            for i, w in g.wires do
                local a, b = Graph.NodeById(w[1]), Graph.NodeById(w[3])
                if a and b then
                    local oi = PortIndex(a, 'out', w[2])
                    local ii = PortIndex(b, 'in', w[4])
                    if oi and ii then
                        local x1, y1 = PortAt(view, a, 'out', oi)
                        local x2, y2 = PortAt(view, b, 'in', ii)
                        local t = Nodes.OutputPort(a.type, w[2])
                        local col = Nodes.PortColor[t and t.type or 'height'] or c.text
                        local th = 2
                        if Graph.SelWire == i then col = 'ffffffff' th = 3
                        elseif Graph.Sel[w[1]] or Graph.Sel[w[3]] then th = 3 end
                        DrawWire(x1, y1, x2, y2, col, th, false)
                    end
                end
            end
            ResetPool(self.wires, 'wireUsed')
        end

        function Pn:Hide()
        end

        -- ---- the status of the nodes (pictures, errors, timing) --------------------------------------------------------------------
        function Pn:UpdateNodes()
            local run = GRun.Main
            local zoom = View().zoom
            for id, v in self.views do
              if v.frame ~= true then
                local n = Graph.NodeById(id)
                local e = run and run:Entry(id)
                local key = Graph.DataRevision .. ':' .. (e and ((e.ver or '') .. (e.err or '')) or '-') .. ':' .. zoom
                if n and key ~= v.shownKey then
                    v.shownKey = key
                    local def = Nodes.Defs[n.type]
                    local text, col = def and Nodes.Describe(n) or '', c.textDim
                    local fill = 'ff2a2f36'
                    if n.off then text = 'bypassed' end
                    if e and e.err then
                        text = e.upstream and 'waiting for an input' or e.err
                        col = e.upstream and c.warn or c.error
                        fill = e.upstream and 'ff2f2f2a' or 'ff3d2626'
                        v.thumb:SetSolidColor('00000000')
                    elseif e then
                        if e.thumb and e.ver ~= self.thumbVer[id] then
                            v.thumb:SetTexture(e.thumb)
                            self.thumbVer[id] = e.ver
                        end
                        if def and def.outputs[1] and def.outputs[1].type == 'number' and e.outs and e.outs.out ~= nil then
                            text = string.format('= %.4g', e.outs.out)
                        end
                    else
                        v.thumb:SetSolidColor('00000000')
                    end
                    v.frame:SetSolidColor(fill)
                    W.Fit(v.status, text, math.floor(NW * zoom) - Skin.S(10))
                    v.status:SetColor(col)
                end
              end
            end
        end

        -- ---- pan, zoom, fit ----------------------------------------------------------------------------------------------------------
        function Pn:SetView(x, y, zoom)
            local view = View()
            view.x, view.y = x, y
            if zoom then view.zoom = zoom end
            Graph.Revision = Graph.Revision + 1
            self:Layout()
        end

        function Pn.Wheel(event)
            local view = View()
            local mx = (event.MouseX or GetMouseScreenPos()[1]) - bg.Left()
            local my = (event.MouseY or GetMouseScreenPos()[2]) - bg.Top()
            local factor = event.WheelRotation > 0 and 1.15 or (1 / 1.15)
            local z = math.max(MINZ, math.min(MAXZ, view.zoom * factor))
            local k = z / view.zoom
            -- the point under the pointer stays
            Pn:SetView(mx - (mx - view.x) * k, my - (my - view.y) * k, z)
        end

        function Pn:Fit()
            local g = Graph.Current
            if table.getn(g.nodes) == 0 then
                self:SetView(self.cw / 2 - NW / 2, self.ch / 2 - 60, 1)
                return
            end
            local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
            for _, n in g.nodes do
                x0, y0 = math.min(x0, n.x), math.min(y0, n.y)
                x1, y1 = math.max(x1, n.x + NodeW(n)), math.max(y1, n.y + NodeH(n))
            end
            local bw, bh = x1 - x0, y1 - y0
            local z = math.max(MINZ, math.min(1, math.min((self.cw - 40) / bw, (self.ch - 40) / bh)))
            self:SetView((self.cw - bw * z) / 2 - x0 * z, (self.ch - bh * z) / 2 - y0 * z, z)
        end

        -- ---- drags (functions of the pointer position: the Dragger forwards, a test calls them) ------------------------------------------
        local function Begin(event, Move, Release)
            local d = Dragger()
            d.OnMove = function(self, x, y) Move(x, y) end
            d.OnRelease = function(self, x, y) Release(x, y) self:Destroy() end
            d.OnCancel = function(self) Release(nil, nil) self:Destroy() end
            PostDragger(GetFrame(0), event.KeyCode, d)
        end

        --- Pan with the middle or right button. `onClick(x, y)` is called when the button is released without the pointer having moved (a right click: the context menu).
        function Pn.StartPan(event, onClick)
            local view = View()
            local startX, startY, moved = event.MouseX, event.MouseY, false
            Pn.DragPanBegin(event.MouseX, event.MouseY)
            Begin(event, function(x, y)
                if math.abs(x - startX) + math.abs(y - startY) > 3 then moved = true end
                Pn.DragPan(x, y)
            end, function(x, y)
                if x and not moved and onClick then onClick(x, y) end
            end)
        end
        function Pn.DragPanBegin(x, y)
            local view = View()
            Pn.pan = { x = x, y = y, vx = view.x, vy = view.y }
        end
        function Pn.DragPan(x, y)
            local p = Pn.pan
            if not p then return end
            Pn:SetView(p.vx + (x - p.x), p.vy + (y - p.y))
        end

        -- ---- context menus (right click without a drag) ------------------------------------------------------------------------------------
        local ContextMenu = import('/lua/editor/gui/menu.lua')

        --- Graph coordinates of a screen position (for "Paste here").
        local function GraphPoint(mx, my)
            local v = View()
            return (mx - bg.Left() - v.x) / v.zoom, (my - bg.Top() - v.y) / v.zoom
        end

        --- The menu of what was right clicked: kind 'node' (id), 'port' (id, port = { side, name }), 'wire' (index in `id`) or 'canvas'. The clicked node joins the selection first, so
        --- the commands act on what the user sees highlighted.
        function Pn.ContextMenu(kind, id, mx, my, port)
            local items = {}
            local function Add(title, run, opts)
                local item = { title = title, run = function() run() Pn:Tick(true) end }
                if opts then for k, v in opts do item[k] = v end end
                table.insert(items, item)
            end
            local function Sep() table.insert(items, { separator = true }) end
            if kind == 'node' then
                if not Graph.Sel[id] then
                    Graph.SelectOne(id, false)
                    Pn:Layout()
                end
                local ids = Graph.SelectedList()
                local count = table.getn(ids)
                local node = Graph.NodeById(id)
                local many = count > 1
                Add(many and ('Show node as mask') or 'Show as mask', function()
                    Graph.SelectOne(id, false)
                    state.mask = true
                    if Pn.bMask then Pn.bMask:SetOn(true) end
                end, { tip = 'Show the result of this node on the terrain as a mask (the Mask view button).', enabled = not IsFrame(node) })
                Sep()
                Add(many and ('Duplicate ' .. count .. ' nodes') or 'Duplicate', function() Graph.Duplicate(ids) end, { tip = 'Copies the selected nodes with the wires between them, a little to the side.' })
                Add('Copy', function() Graph.CopyNodes(ids) end, { tip = 'Puts the selected nodes on the graph clipboard; Paste here (right click on the canvas) places them.' })
                Add(node.off and (many and 'Enable the nodes' or 'Enable') or (many and 'Bypass the nodes' or 'Bypass'), function()
                    local off = not node.off
                    for _, nid in ids do Graph.SetOff(nid, off) end
                end, { tip = 'A bypassed node passes nothing on and is skipped by the evaluation; enable it again to use it.', enabled = not IsFrame(node), checked = node.off and true or false })
                Add('Disconnect all wires', function()
                    local set = {}
                    for _, nid in ids do set[nid] = true end
                    Graph.Edit('disconnect nodes', function()
                        local wires = Graph.Current.wires
                        for i = table.getn(wires), 1, -1 do
                            if set[wires[i][1]] or set[wires[i][3]] then table.remove(wires, i) end
                        end
                    end)
                end, { tip = 'Removes every wire into and out of the selected nodes.' })
                Sep()
                Add(many and ('Delete ' .. count .. ' nodes') or 'Delete', function() Graph.Remove(ids) end, { tip = 'Deletes the selected nodes and their wires (Undo brings them back).' })
            elseif kind == 'port' then
                if port.side == 'in' then
                    Add('Disconnect this input', function() Graph.Disconnect(id, port.name) end, { enabled = Graph.WireInto(id, port.name) ~= nil, why = 'nothing is wired here' })
                else
                    Add('Disconnect this output', function()
                        Graph.Edit('disconnect output', function()
                            local wires = Graph.Current.wires
                            for i = table.getn(wires), 1, -1 do
                                if wires[i][1] == id and wires[i][2] == port.name then table.remove(wires, i) end
                            end
                        end)
                    end)
                end
            elseif kind == 'wire' then
                Add('Delete wire', function() Graph.RemoveWire(id) end)
            else
                local gx, gy = GraphPoint(mx, my)
                Add('Paste here', function() Graph.Paste(gx, gy) end, { enabled = Graph.Clipboard and true or false, why = 'nothing copied' })
                Add('Select all', function()
                    local all = {}
                    for _, n in Graph.Current.nodes do table.insert(all, n.id) end
                    Graph.Select(all, false)
                end)
                Add('Fit the view to the graph', function() Pn:Fit() end)
                Sep()
                Add('Add a node ...', function() pcall(function() import('/lua/editor/gui/shell.lua').FocusPanel('graphpalette') end) end, { tip = 'Opens the node palette: a click on a node there adds it to the graph.' })
            end
            ContextMenu.Show(GetFrame(0), mx, my, items)
        end

        function Pn.StartNodeDrag(event, id)
            local mods = event.Modifiers or {}
            Pn.DragNodeBegin(event.MouseX, event.MouseY, id, mods.Shift or mods.Ctrl)
            Begin(event, function(x, y) Pn.DragNode(x, y) end, function(x, y) Pn.DragNodeEnd() end)
        end
        function Pn.DragNodeBegin(x, y, id, additive)
            if additive then
                Graph.SelectOne(id, true)
            elseif not Graph.Sel[id] then
                Graph.SelectOne(id, false)
            else
                Graph.SelWire = false
            end
            local start = {}
            for sid, _ in Graph.Sel do
                local n = Graph.NodeById(sid)
                if n then start[sid] = { n.x, n.y } end
            end
            -- a frame carries the nodes whose middle lies inside it
            for sid, _ in Graph.Sel do
                local f = Graph.NodeById(sid)
                if f and IsFrame(f) then
                    for _, n in Graph.Current.nodes do
                        if not IsFrame(n) and not start[n.id] then
                            local mx, my = n.x + NW / 2, n.y + NodeH(n) / 2
                            if mx >= f.x and mx <= f.x + NodeW(f) and my >= f.y and my <= f.y + NodeH(f) then start[n.id] = { n.x, n.y } end
                        end
                    end
                end
            end
            Pn.nodeDrag = { x = x, y = y, start = start, before = Graph.Begin(), moved = false }
            Pn:Layout()
        end
        function Pn.DragNode(x, y)
            local d = Pn.nodeDrag
            if not d then return end
            local z = View().zoom
            local dx, dy = (x - d.x) / z, (y - d.y) / z
            if math.abs(x - d.x) + math.abs(y - d.y) > 2 then d.moved = true end
            for id, p in d.start do
                local n = Graph.NodeById(id)
                if n then n.x, n.y = p[1] + dx, p[2] + dy end
            end
            Graph.Revision = Graph.Revision + 1
            Pn:Layout()
        end
        function Pn.DragNodeEnd()
            local d = Pn.nodeDrag
            Pn.nodeDrag = nil
            if not d then return end
            if d.moved then
                -- grid snap: a tidy canvas
                for id, _ in d.start do
                    local n = Graph.NodeById(id)
                    if n then n.x, n.y = math.floor(n.x / 8 + 0.5) * 8, math.floor(n.y / 8 + 0.5) * 8 end
                end
                Graph.End('move nodes', d.before, nil, false)
            end
            Pn:Layout()
        end

        -- box select
        function Pn.StartBox(event, additive)
            Pn.DragBoxBegin(event.MouseX, event.MouseY, additive)
            Begin(event, function(x, y) Pn.DragBox(x, y) end, function(x, y) Pn.DragBoxEnd(x, y) end)
        end
        function Pn.DragBoxBegin(x, y, additive)
            Pn.box = { x = x - bg.Left(), y = y - bg.Top(), x2 = x - bg.Left(), y2 = y - bg.Top(), additive = additive }
            if not Pn.boxBit then
                -- a clear fill and a one pixel frame in the accent colour, above everything on the canvas (the old fill alone was 19 % opaque and hardly seen)
                Pn.boxBit = Bitmap(bg)
                Pn.boxBit.Depth:Set(function() return bg.Depth() + 400 end)
                Pn.boxBit:SetSolidColor('4040b7d4')
                Pn.boxBit:DisableHitTest()
                Pn.boxEdges = {}
                for i = 1, 4 do
                    local e = Bitmap(bg)
                    e.Depth:Set(function() return bg.Depth() + 401 end)
                    e:SetSolidColor('ff40b7d4')
                    e:DisableHitTest()
                    Gone(e)
                    Pn.boxEdges[i] = e
                end
            end
        end
        function Pn.DragBox(x, y)
            local b = Pn.box
            if not b then return end
            b.x2, b.y2 = math.max(0, math.min(Pn.cw, x - bg.Left())), math.max(0, math.min(Pn.ch, y - bg.Top()))
            local bx, by, bw, bh = math.min(b.x, b.x2), math.min(b.y, b.y2), math.max(2, math.abs(b.x2 - b.x)), math.max(2, math.abs(b.y2 - b.y))
            Put(Pn.boxBit, bx, by, bw, bh)
            Pn.boxBit:Show()
            local e = Pn.boxEdges
            if e then
                Put(e[1], bx, by, bw, 1)
                Put(e[2], bx, by + bh - 1, bw, 1)
                Put(e[3], bx, by, 1, bh)
                Put(e[4], bx + bw - 1, by, 1, bh)
                for i = 1, 4 do e[i]:Show() end
            end
        end
        function Pn.DragBoxEnd(x, y)
            local b = Pn.box
            Pn.box = nil
            if Pn.boxBit then Gone(Pn.boxBit) Pn.boxBit:Hide() end
            for _, e in Pn.boxEdges or {} do Gone(e) e:Hide() end
            if not b then return end
            if x then Pn.DragBox(x, y) end
            local view = View()
            local z = view.zoom
            local bx0, bx1 = math.min(b.x, b.x2), math.max(b.x, b.x2)
            local by0, by1 = math.min(b.y, b.y2), math.max(b.y, b.y2)
            local ids = {}
            if bx1 - bx0 < 3 and by1 - by0 < 3 then
                if not b.additive then Graph.ClearSelection() end
                Pn:Layout()
                return
            end
            for _, n in Graph.Current.nodes do
                local sx, sy = view.x + n.x * z, view.y + n.y * z
                local sw, sh = NodeW(n) * z, NodeH(n) * z
                if IsFrame(n) then
                    -- a frame is picked only when the box holds it completely
                    if sx >= bx0 and sx + sw <= bx1 and sy >= by0 and sy + sh <= by1 then table.insert(ids, n.id) end
                elseif sx < bx1 and sx + sw > bx0 and sy < by1 and sy + sh > by0 then
                    table.insert(ids, n.id)
                end
            end
            Graph.Select(ids, b.additive)
            Pn:Layout()
        end

        -- wires
        local function PortHit(x, y, wantSide)
            local view = View()
            local best, bd = nil, (PORT * 1.6) * (PORT * 1.6)
            for _, n in Graph.Current.nodes do
                for _, side in { 'in', 'out' } do
                    if not wantSide or wantSide == side then
                        local list = (side == 'out') and VisibleOutputs(n.type) or Nodes.Inputs(n.type)
                        for i, p in list do
                            local px, py = PortAt(view, n, side, i)
                            local d = (px - x) * (px - x) + (py - y) * (py - y)
                            if d <= bd then best, bd = { id = n.id, side = side, port = p.name }, d end
                        end
                    end
                end
            end
            return best
        end
        Pn.PortHit = PortHit

        function Pn.StartWire(event, id, side, port)
            Pn.DragWireBegin(event.MouseX, event.MouseY, id, side, port)
            Begin(event, function(x, y) Pn.DragWire(x, y) end, function(x, y) Pn.DragWireEnd(x, y) end)
        end
        function Pn.DragWireBegin(x, y, id, side, port)
            local drag = { from = { id = id, side = side, port = port } }
            if side == 'in' then
                local w = Graph.WireInto(id, port)
                if w then
                    -- take the wire off this input and carry its other end
                    drag.from = { id = w[1], side = 'out', port = w[2] }
                    drag.detached = { id = id, port = port }
                end
            end
            Pn.wireDrag = drag
            Graph.SelectOne(nil)
        end
        function Pn.DragWire(x, y)
            local d = Pn.wireDrag
            if not d then return end
            local view = View()
            local n = Graph.NodeById(d.from.id)
            if not n then return end
            local mx, my = x - bg.Left(), y - bg.Top()
            local i = PortIndex(n, d.from.side, d.from.port)
            if not i then return end
            local px, py = PortAt(view, n, d.from.side, i)
            Pn.ghostUsed = 0
            local col = 'ffffffff'
            if d.from.side == 'out' then DrawWire(px, py, mx, my, col, 2, true) else DrawWire(mx, my, px, py, col, 2, true) end
            ResetPool(Pn.ghost, 'ghostUsed')
        end
        function Pn.DragWireEnd(x, y)
            local d = Pn.wireDrag
            Pn.wireDrag = nil
            Pn.ghostUsed = 0
            ResetPool(Pn.ghost, 'ghostUsed')
            if not d or not x then return end
            local target = PortHit(x - bg.Left(), y - bg.Top(), d.from.side == 'out' and 'in' or 'out')
            if target then
                local ok, msg
                if d.from.side == 'out' then
                    ok, msg = Graph.Connect(d.from.id, d.from.port, target.id, target.port)
                else
                    ok, msg = Graph.Connect(target.id, target.port, d.from.id, d.from.port)
                end
                if not ok then Say(msg) end
                if ok and d.detached and not (d.detached.id == target.id and d.detached.port == target.port) then
                    Graph.Disconnect(d.detached.id, d.detached.port)
                end
            elseif d.detached then
                Graph.Disconnect(d.detached.id, d.detached.port)
            end
            Pn:Layout()
            Pn:Tick()
        end

        -- picking a wire
        function Pn.HitWire(x, y)
            local view = View()
            local best, bd = nil, 36
            for i, w in Graph.Current.wires do
                local a, b = Graph.NodeById(w[1]), Graph.NodeById(w[3])
                local oi = a and PortIndex(a, 'out', w[2])
                local ii = b and PortIndex(b, 'in', w[4])
                if oi and ii then
                    local x1, y1 = PortAt(view, a, 'out', oi)
                    local x2, y2 = PortAt(view, b, 'in', ii)
                    for _, s in Route(x1, y1, x2, y2, view.zoom) do
                        local ax, ay, bx, by = math.min(s[1], s[3]), math.min(s[2], s[4]), math.max(s[1], s[3]), math.max(s[2], s[4])
                        local dx = math.max(ax - x, 0, x - bx)
                        local dy = math.max(ay - y, 0, y - by)
                        local d = dx * dx + dy * dy
                        if d < bd then best, bd = i, d end
                    end
                end
            end
            return best
        end

        bg.HandleEvent = function(self, event)
            Watch(self, event)
            if event.Type == 'ButtonPress' then
                local mods = event.Modifiers or {}
                if mods.Middle or mods.Right then
                    Pn.StartPan(event, mods.Right and function(x, y)
                        local wi = Pn.HitWire(x - bg.Left(), y - bg.Top())
                        if wi then Pn.ContextMenu('wire', wi, x, y) else Pn.ContextMenu('canvas', nil, x, y) end
                    end or nil)
                else
                    local wi = Pn.HitWire(event.MouseX - bg.Left(), event.MouseY - bg.Top())
                    if wi then
                        Graph.Sel = {}
                        Graph.SelWire = wi
                        Graph.Revision = Graph.Revision + 1
                        Pn:Layout()
                    else
                        Pn.StartBox(event, mods.Shift or mods.Ctrl)
                    end
                end
                return true
            elseif event.Type == 'WheelRotation' then
                Pn.Wheel(event)
                return true
            end
            return false
        end

        -- ---- toolbar -----------------------------------------------------------------------------------------------------------------
        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end
        Pn.buttons = {}
        local function Add(b) table.insert(Pn.buttons, b) return b end

        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        Add(Btn('Build', 54, function()
            local r, err = GRun.Build()
            if r then
                local slow = ''
                for i, s in r.slow do
                    if i <= 2 then
                        local n = Graph.NodeById(s.id)
                        slow = slow .. string.format('  %s %.0f ms', n and (Nodes.Defs[n.type] and Nodes.Defs[n.type].label or n.type) or '?', s.ms)
                    end
                end
                state.text = string.format('built in %.0f ms: %d height samples, %d layers, %d types, %d props (one undo step)%s', r.ms, r.changed, r.layers, r.types, r.props, slow)
                if r.mapNote then state.text = state.text .. r.mapNote end
            else
                state.text = 'not built: ' .. tostring(err)
            end
            Say(state.text)
            Pn:Tick(true)
        end))
        Pn.bTerrain = Add(Btn('On terrain', 80, function(self)
            state.onTerrain = self.on
            if self.on then
                local n, err = GRun.ShowOnTerrain()
                state.text = n and ('preview on the terrain: ' .. n .. ' samples') or ('no preview: ' .. tostring(err))
                state.shownRevision = Graph.DataRevision
            else
                GRun.RevertTerrain()
                state.text = 'preview removed'
            end
            Pn:Tick(true)
        end, { toggle = true }))
        Add(Btn('Revert', 54, function()
            GRun.RevertTerrain()
            state.onTerrain = false
            Pn.bTerrain:SetOn(false)
            state.text = 'preview removed'
            Pn:Tick(true)
        end))
        Pn.bMask = Add(Btn('Mask view', 74, function(self)
            state.mask = self.on
            if not self.on then GRun.HideMask() end
            Pn:Tick(true)
        end, { toggle = true }))
        Add(Btn('Undo', 44, function() Graph.Undo() Pn:Tick(true) end))
        Add(Btn('Redo', 44, function() Graph.Redo() Pn:Tick(true) end))
        Add(Btn('Fit', 34, function() Pn:Fit() end))
        Pn.bDetail = Add(Btn('Detail ' .. GRun.PreviewCap, 80, function(self)
            local caps, nextCap = GRun.PreviewCaps, nil
            for i = 1, table.getn(caps) do
                if caps[i] == GRun.PreviewCap then nextCap = caps[i + 1] or caps[1] end
            end
            GRun.SetPreviewCap(nextCap or caps[1])
            self:SetText('Detail ' .. GRun.PreviewCap)
            Pn.thumbVer = {}
            state.text = 'preview detail ' .. GRun.PreviewCap .. ' samples a side'
            Pn:Tick(true)
        end))
        Add(Btn('Variations', 74, function()
            local shell = import('/lua/editor/gui/shell.lua')
            shell.FocusPanel('graphgallery')
            local ok, gal = pcall(import, '/lua/editor/gui/panels_graphgallery.lua')
            if ok and gal.Make then gal.Make() end
        end))
        Pn.seedLabel = W.Label(group, 'seed 0000', 0, 0, { color = c.text })
        Pn.seedW = Pn.seedLabel.Width()     -- the toolbar reserves the width of the widest seed text: a seed that grows from 'seed 4' to 'seed 9999' used to run into the Seed + button
        Add(Btn('Seed -', 50, function() Graph.SetSeed(Graph.Current.seed - 1) Pn:Tick(true) end)).seedAfter = true
        Add(Btn('Seed +', 50, function() Graph.SetSeed(Graph.Current.seed + 1) Pn:Tick(true) end))
        Add(Btn('Random', 56, function() Graph.SetSeed(math.random(0, 9999)) Pn:Tick(true) end))
        Add(Btn('Clear', 44, function()
            Graph.Edit('clear graph', function()
                Graph.Current.nodes = {}
                Graph.Current.wires = {}
                Graph.Sel = {}
            end)
            Pn:Tick(true)
        end))

        -- ---- ticking -----------------------------------------------------------------------------------------------------------------
        function Pn:UpdateStatus()
            local g = Graph.Current
            self.seedLabel:SetText('seed ' .. g.seed)
            local rep = GRun.Report
            local line = state.text
            if line == '' and rep then
                if rep.fatal then
                    line = rep.fatal
                else
                    local errs = 0
                    for _ in rep.errors do errs = errs + 1 end
                    line = string.format('%s: %d nodes, %d run, %d cached, %.0f ms (1/%d resolution)%s', g.name, table.getn(g.nodes), rep.evaluated, rep.cached, rep.ms, GRun.Main and GRun.Main.step or 1,
                        errs > 0 and ('   ' .. errs .. ' with errors') or '')
                end
            end
            W.Fit(self.status, line, math.max(Skin.S(60), self.w - Skin.S(16)))
        end

        --- Evaluates when the graph changed, refreshes the pictures, the live terrain preview and the mask view.
        function Pn:Tick(force)
            if self.dead then return end
            local rep = GRun.Refresh()
            if rep then
                state.report = rep
                if state.onTerrain and Now() - state.lastShow > 0.25 then
                    state.lastShow = Now()
                    local n, err = GRun.ShowOnTerrain()
                    if not n then state.text = 'no preview: ' .. tostring(err) end
                end
            end
            if rep or force or self.layoutRev ~= Graph.Revision then
                if self.layoutRev ~= Graph.Revision or force then self:Layout() end
                self:UpdateNodes()
                self:UpdateStatus()
            end
            -- every tick, not only when the layout changed: a click on a node lays out at once and the next tick would see nothing new
            if state.mask then
                local sel = Graph.SelectedList()
                if sel[1] then
                    local sig = sel[1] .. ':' .. (GRun.Main and GRun.Main.ver or 0)
                    if sig ~= self.maskSig then
                        self.maskSig = sig
                        local ok, err = GRun.ShowMask(sel[1])
                        if not ok then state.text = tostring(err) self:UpdateStatus() end
                    end
                end
            end
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(6)
            local x, y = pad, pad
            local rowH = Skin.S(26)
            local items = {}
            for _, b in self.buttons do
                table.insert(items, b)
                if b.seedAfter then table.insert(items, self.seedLabel) end
            end
            for _, it in items do
                local iw = (it == self.seedLabel) and self.seedW or it.Width()
                if x > pad and x + iw > w - pad then
                    x = pad
                    y = y + rowH
                end
                if it == self.seedLabel then
                    W.Place(it, group, x, y + Skin.S(4))
                else
                    W.Place(it, group, x, y, iw, Skin.S(22))
                end
                x = x + iw + Skin.S(4)
            end
            W.Place(self.status, group, pad, y + rowH + 2)
            local top = y + rowH + Skin.S(22)
            self.toolbarH = top
            self.cw, self.ch = w, math.max(Skin.S(80), h - top)
            bg.Left:Set(function() return group.Left() end)
            bg.Top:Set(function() return group.Top() + top end)
            bg.Width:Set(self.cw)
            bg.Height:Set(self.ch)
            local view = View()
            if view.x == 0 and view.y == 0 and table.getn(Graph.Current.nodes) > 0 and not self.fitted then
                self.fitted = true
                self:Fit()
            end
            self:Layout()
            self:UpdateNodes()
            self:UpdateStatus()
        end

        function Pn:Destroy()
            self.dead = true
            state.onTerrain = false
            state.mask = false
            state.text = ''
            GRun.RevertTerrain()
            GRun.HideMask()
        end

        return Pn
    end,
}

--- Ticked about four times a second by the shell.
function Refresh()
    local Pn = live.canvas
    if Pn and not Pn.dead and Pn.w then Pn:Tick() end
end

--- Canvas position (graph coordinates) at the middle of the visible canvas.
function ViewCentre()
    local Pn = live.canvas
    local view = Graph.Current.view or { x = 0, y = 0, zoom = 1 }
    if not Pn then return 100, 100 end
    return (Pn.cw / 2 - view.x) / view.zoom - NW / 2, (Pn.ch / 2 - view.y) / view.zoom - 40
end

--- The nearest free place for a new node of `type` wanted at (x, y): below the wanted place (then to the right) until no node or frame body is in the way. Frames are no obstacle
--- (nodes lie on them on purpose).
function FreeSpot(x, y, type)
    local probe = { type = type, params = {} }
    local w, h = NodeW(probe), NodeH(probe)
    local function Free(px, py)
        for _, n in Graph.Current.nodes do
            if not IsFrame(n) then
                if px < n.x + NodeW(n) + 8 and px + w + 8 > n.x and py < n.y + NodeH(n) + 8 and py + h + 8 > n.y then return false end
            end
        end
        return true
    end
    for col = 0, 6 do
        for row = 0, 12 do
            local px, py = x + col * (w + 24), y + row * (h + 16)
            if Free(px, py) then return px, py end
        end
    end
    return x, y
end

--- Pans the canvas (not the zoom) just far enough that `node` lies completely in view; a node bigger than the canvas gets its top left corner in view.
function Reveal(node)
    local Pn = live.canvas
    if not Pn or Pn.dead or not Pn.cw or not node then return end
    local view = Graph.Current.view or { x = 0, y = 0, zoom = 1 }
    local z = view.zoom
    local m = 16
    local x0, y0 = view.x + node.x * z, view.y + node.y * z
    local x1, y1 = x0 + NodeW(node) * z, y0 + NodeH(node) * z
    local dx, dy = 0, 0
    if x1 > Pn.cw - m then dx = Pn.cw - m - x1 end
    if y1 > Pn.ch - m then dy = Pn.ch - m - y1 end
    if x0 + dx < m then dx = m - x0 end
    if y0 + dy < m then dy = m - y0 end
    if dx ~= 0 or dy ~= 0 then Pn:SetView(view.x + dx, view.y + dy) end
end

--- Is the pointer over the canvas?
function PointerInside()
    local Pn = live.canvas
    if not Pn or Pn.dead or not Pn.bg then return false end
    return next(Pn.hover) ~= nil
end
