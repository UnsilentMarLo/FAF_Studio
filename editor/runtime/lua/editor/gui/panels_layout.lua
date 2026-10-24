-- The panels of the Layout workspace (docs/projects/editor/MAP_LAYOUT.md):
--
--   Layout canvas   the drawing board: layers painted with a brush, an eraser, lines, rectangles, ellipses and a lasso; symmetry follows the editor's symmetry; the picture shows the layers (or
--                   the height picture the generator would make) with the start positions and resources of the plan on top.
--   Layout layers   the layer list (visible, select, move, delete), the settings of the selected layer by kind, the ground height, water level, seed and weathering, and the buttons that
--                   turn the drawing into terrain.
--   Start positions and resources   layoutmarkers.lua: where the starts are (the ones there, the bases drawn, a pattern) and the mass and hydrocarbon around them by shape and distance.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Dragger = import('/lua/maui/dragger.lua').Dragger
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Layout = import('/lua/editor/layout.lua')
local LM = import('/lua/editor/layoutmarkers.lua')
local Fields = import('/lua/editor/fields.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Throttle = import('/lua/editor/throttle.lua')
local Map = import('/lua/editor/map.lua')

live = {}

--- Module level (the controls come and go).
state = { tool = 'brush', size = 5, hard = 0.6, strength = 1, view = 'layers', solo = false, markers = true, paintGround = false, status = '' }

TOOLS = {
    { id = 'brush', label = 'Brush', tip = 'Paint with a round brush. Right button erases. The hardness is how much of the radius is full strength; strength below 1 paints partial heights.' },
    { id = 'eraser', label = 'Eraser', tip = 'Take paint away with a round brush.' },
    { id = 'line', label = 'Line', tip = 'Drag a line of the brush width: rivers, ridges, roads.' },
    { id = 'rect', label = 'Rectangle', tip = 'Drag a filled rectangle. Right button erases.' },
    { id = 'ellipse', label = 'Ellipse', tip = 'Drag a filled ellipse inside the rectangle you drag. Right button erases.' },
    { id = 'lasso', label = 'Lasso', tip = 'Draw an outline freehand; the inside is filled when you let go. Right button erases.' },
}

local function Say(text)
    state.status = text
    pcall(function() UI.Say(text) end)
end

local PREVIEW_PREFIX = '/fieldtmp/'

-- ---- the canvas -------------------------------------------------------------------------------------------------------------------------------------------

local function Dot(px, x, z, size, r, g, b)
    Layout.Mark(px, x, z, size, r, g, b)
end

local function LineCells(px, x0, z0, x1, z1, r, g, b)
    local rw, rh = Layout.Doc.rw, Layout.Doc.rh
    local steps = math.max(math.abs(x1 - x0), math.abs(z1 - z0))
    steps = math.max(1, math.ceil(steps))
    for s = 0, steps do
        local t = s / steps
        local x, z = math.floor(x0 + (x1 - x0) * t), math.floor(z0 + (z1 - z0) * t)
        if x >= 0 and z >= 0 and x < rw and z < rh then
            local o = (z * rw + x) * 4
            px[o + 1], px[o + 2], px[o + 3] = r, g, b
        end
    end
end

--- The start positions and resources on the picture: the map's own markers (when state.markers) and the plan that has not been placed yet.
local function DrawMarkers(px)
    if state.markers and Map.Doc then
        for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
            if m.position then
                local x, z = Layout.ToCell(m.position[1], m.position[3])
                if string.find(name, '^ARMY_') then Dot(px, x, z, 5, 255, 255, 255)
                elseif m.type == 'Mass' then Dot(px, x, z, 2, 255, 220, 60)
                elseif m.type == 'Hydrocarbon' then Dot(px, x, z, 3, 90, 255, 120) end
            end
        end
    end
    local plan = LM.LastPlan()
    if plan then
        for _, st in plan.starts do
            local x, z = Layout.ToCell(st.x, st.z)
            Dot(px, x, z, 5, 255, 90, 90)
        end
        for _, it in plan.items do
            local x, z = Layout.ToCell(it.x, it.z)
            if it.kind == 'Mass' then Dot(px, x, z, 2, 255, 160, 30) else Dot(px, x, z, 3, 40, 220, 90) end
        end
    end
end

Panels.Register{
    id = 'layoutcanvas', title = 'Layout canvas', minW = 300, minH = 300,
    create = function(group, host)
        local P = { buttons = {}, s = 256, drag = false, w = 400, h = 400 }
        live.canvas = P
        local c = Skin.color

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        for _, t in TOOLS do
            local id = t.id
            local b = Btn(t.label, 70, function() state.tool = id P:Refresh() end, { toggle = true, tip = t.tip })
            P.buttons[id] = b
        end
        P.size = W.Slider(group, { label = 'Brush size (cells)', min = 1, max = 40, step = 0.5, fmt = '%.1f', compact = true, get = function() return state.size end, set = function(v) state.size = v end, tip = 'The radius of the brush in cells of the drawing (also the width of a line).' })
        P.hard = W.Slider(group, { label = 'Brush hardness', min = 0, max = 1, step = 0.05, fmt = '%.2f', compact = true, get = function() return state.hard end, set = function(v) state.hard = v end, tip = 'How much of the brush radius is full strength; the rest fades out. 1 is a hard edged disc.' })
        P.strength = W.Slider(group, { label = 'Brush strength', min = 0.05, max = 1, step = 0.05, fmt = '%.2f', compact = true, get = function() return state.strength end, set = function(v) state.strength = v end, tip = 'How much the brush paints (1 = fully). Less than 1 paints partial values: lower hills, a weaker mountain.' })
        P.sym = Btn('Symmetry: off', 190, function()
            local at = 1
            for i, m in Symmetry.Modes do
                if m.id == Symmetry.Mode then at = i end
            end
            Symmetry.SetMode(Symmetry.Modes[math.mod(at, table.getn(Symmetry.Modes)) + 1].id)
            P:Refresh()
        end, { tip = 'The symmetry of the editor (the same as the other tools): every stroke is drawn on its images too. Click to change it.' })
        P.view = Btn('Show: layers', 110, function()
            state.view = (state.view == 'layers') and 'height' or 'layers'
            P:Render()
            P:Refresh()
        end, { toggle = true, tip = 'Switch the picture between the layers and the heights the generator would make (a coloured picture, nothing is written).' })
        P.mk = Btn('Markers', 80, function(self) state.markers = self.on P:Render() end, { toggle = true, tip = 'Show the start positions and resources of the map and the plan of the generator on the picture.' })
        P.fit = Btn('Fit to the area', 110, function()
            local changed = Layout.Refit()
            Say(changed and 'the drawing now covers the playable area (what was drawn stays where it is on the map; one undo step)' or 'the drawing already covers the playable area')
            P:Refresh()
        end, { tip = 'Make the canvas cover the playable area of the map (its size and shape, also after the area was resized): what is drawn stays at the same place on the map, one undo step.' })
        P.centre = Btn('Centre symmetry', 120, function()
            Layout.CentreSymmetry()
            Say('the symmetry centre is the middle of the drawing')
            P:Refresh()
        end, { tip = 'Put the centre of the editor symmetry in the middle of the canvas (the playable area): mirrors and turns then fit the area, also when the area is not in the middle of the terrain.' })
        P.info = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        P.img = Bitmap(group)
        P.img:SetSolidColor(c.panelAlt)
        P.img.Depth:Set(function() return group.Depth() + 5 end)

        local lastName = false
        local function Show(px, w, h)
            local vfs = Fields.PreviewPixels(px, w, h)
            if vfs then
                P.img:SetTexture(vfs)
                if lastName and rawget(_G, 'ed_file_delete') then pcall(ed_file_delete, '../fieldtmp/' .. lastName) end
                lastName = string.gsub(vfs, '^/fieldtmp/', '')
            end
        end

        --- Draws the picture now.
        function P:Render()
            local doc = Layout.Doc
            if not doc then return end
            -- an empty drawing follows the playable area; another shape (a template, undo of a fit) changes the aspect of the picture
            if Layout.Sync() or P.geo ~= (doc.rw .. 'x' .. doc.rh) then
                P:OnResize(P.w, P.h)
                return
            end
            local px, w, h
            if state.view == 'height' then
                px, w, h = Layout.Preview(doc.res)
                if not px then
                    Say('no height picture: ' .. tostring(w))
                    px, w, h = Layout.Pixels({})
                end
            else
                px, w, h = Layout.Pixels({ only = state.solo and doc.sel or nil })
            end
            DrawMarkers(px)
            -- the shape being dragged
            local d = P.drag
            if d then
                if d.tool == 'line' then
                    LineCells(px, d.x0, d.z0, d.x1, d.z1, 255, 255, 255)
                elseif d.tool == 'rect' or d.tool == 'ellipse' then
                    local a, b, c1, d1 = math.min(d.x0, d.x1), math.max(d.x0, d.x1), math.min(d.z0, d.z1), math.max(d.z0, d.z1)
                    if d.tool == 'rect' then
                        LineCells(px, a, c1, b, c1, 255, 255, 255) LineCells(px, b, c1, b, d1, 255, 255, 255)
                        LineCells(px, b, d1, a, d1, 255, 255, 255) LineCells(px, a, d1, a, c1, 255, 255, 255)
                    else
                        local cx, cz, rx, rz = (a + b) / 2, (c1 + d1) / 2, (b - a) / 2, (d1 - c1) / 2
                        local prevx, prevz
                        for s = 0, 48 do
                            local ang = s / 48 * 6.2832
                            local x, z = cx + rx * math.cos(ang), cz + rz * math.sin(ang)
                            if prevx then LineCells(px, prevx, prevz, x, z, 255, 255, 255) end
                            prevx, prevz = x, z
                        end
                    end
                elseif d.tool == 'lasso' then
                    for i = 2, table.getn(d.pts) do LineCells(px, d.pts[i - 1][1], d.pts[i - 1][2], d.pts[i][1], d.pts[i][2], 255, 255, 255) end
                end
            end
            Show(px, w, h)
            P.dirty = false
        end

        local function ToCanvas(mx, my)
            local doc = Layout.Doc
            local cx = (mx - P.img.Left()) / math.max(1, P.img.Width()) * doc.rw
            local cz = (my - P.img.Top()) / math.max(1, P.img.Height()) * doc.rh
            return math.max(0, math.min(doc.rw, cx)), math.max(0, math.min(doc.rh, cz))
        end

        local function Pump()
            Throttle.Defer('layoutcanvas', function() if live.canvas == P then P:Render() end end, state.view == 'height' and 350 or 70)
        end

        P.img.HandleEvent = function(self, event)
            if event.Type ~= 'ButtonPress' then return false end
            local doc = Layout.Doc
            local mods = event.Modifiers or {}
            local erase = (mods.Right and true) or state.tool == 'eraser'
            local index = doc.sel
            local L = doc.layers[index]
            if not L then return true end
            if not L.visible then Say('the layer ' .. L.name .. ' is hidden: show it to draw on it') return true end
            local tool = state.tool
            local cx, cz = ToCanvas(event.MouseX, event.MouseY)
            Layout.BeginStroke(index)
            local last = { cx, cz }
            if tool == 'brush' or tool == 'eraser' then
                Layout.Dab(index, cx, cz, state.size, state.hard, state.strength, erase)
            end
            P.drag = (tool == 'line' or tool == 'rect' or tool == 'ellipse') and { tool = tool, x0 = cx, z0 = cz, x1 = cx, z1 = cz }
                     or (tool == 'lasso' and { tool = tool, pts = { { cx, cz } } }) or false
            local dragger = Dragger()
            dragger.OnMove = function(d, x, y)
                local nx, nz = ToCanvas(x, y)
                if tool == 'brush' or tool == 'eraser' then
                    Layout.Line(index, last[1], last[2], nx, nz, state.size, state.hard, state.strength, erase)
                    last = { nx, nz }
                elseif P.drag then
                    if tool == 'lasso' then table.insert(P.drag.pts, { nx, nz }) else P.drag.x1, P.drag.z1 = nx, nz end
                end
                P.dirty = true
                Pump()
            end
            local function Finish(d, label)
                d:Destroy()
                local sh = P.drag
                P.drag = false
                if sh then
                    if sh.tool == 'line' then Layout.Line(index, sh.x0, sh.z0, sh.x1, sh.z1, state.size, state.hard, state.strength, erase)
                    elseif sh.tool == 'rect' then Layout.FillRect(index, sh.x0, sh.z0, sh.x1, sh.z1, state.strength, erase)
                    elseif sh.tool == 'ellipse' then Layout.FillEllipse(index, sh.x0, sh.z0, sh.x1, sh.z1, state.strength, erase)
                    elseif sh.tool == 'lasso' then Layout.FillPolygon(index, sh.pts, state.strength, erase) end
                end
                Layout.EndStroke((erase and 'erase on ' or 'draw on ') .. L.name)
                Layout.Changed()
                P:Render()
            end
            dragger.OnRelease = function(d, x, y) Finish(d) end
            dragger.OnCancel = function(d) Finish(d) end
            PostDragger(GetFrame(0), event.KeyCode, dragger)
            P:Render()
            return true
        end

        --- Re-reads the settings into the controls.
        function P:Refresh()
            for id, b in P.buttons do b:SetOn(state.tool == id) end
            local label = 'off'
            for _, m in Symmetry.Modes do
                if m.id == Symmetry.Mode then label = m.label end
            end
            P.sym:SetText('Symmetry: ' .. label)
            P.view:SetText(state.view == 'layers' and 'Show: layers' or 'Show: heights')
            P.view:SetOn(state.view == 'height')
            P.mk:SetOn(state.markers)
            for _, s in { P.size, P.hard, P.strength } do s:Refresh() end
            local doc = Layout.Doc
            local L = doc and doc.layers[doc.sel]
            local note = ''
            if doc and Layout.Stale() then note = '   The playable area changed: Fit to the area.'
            elseif doc and Symmetry.Mode ~= 'off' and not Layout.SymmetryCentred() then note = '   The symmetry centre is not the middle of the canvas: Centre symmetry.'
            elseif doc and doc.rw ~= doc.rh and (Symmetry.Mode == 'diag' or Symmetry.Mode == 'diag_both' or Symmetry.Mode == 'rot4') then note = '   This symmetry needs a square area.' end
            W.Fit(P.info, L and ('Drawing on: ' .. L.name .. '   (' .. doc.rw .. ' x ' .. doc.rh .. ' cells, a cell is ' .. string.format('%.1f', doc.cell) .. ' units)' .. note) or '', P.w - 20)
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            local y = pad
            local items = {}
            for _, t in TOOLS do table.insert(items, { P.buttons[t.id], Skin.S(70) }) end
            y = W.Flow(group, items, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
            local sw = math.floor((w - 4 * pad) / 3)
            P.size:Place(pad, y, sw)
            P.hard:Place(pad * 2 + sw, y, sw)
            P.strength:Place(pad * 3 + sw * 2, y, sw)
            y = y + Skin.S(50)
            y = W.Flow(group, { { P.sym, Skin.S(190) }, { P.centre, Skin.S(120) }, { P.view, Skin.S(110) }, { P.mk, Skin.S(80) }, { P.fit, Skin.S(110) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
            W.Place(P.info, group, pad, y)
            y = y + Skin.S(18)
            local doc = Layout.Doc
            P.geo = doc.rw .. 'x' .. doc.rh
            local availW, availH = math.max(Skin.S(100), w - 2 * pad), math.max(Skin.S(100), h - y - pad)
            local scale = math.min(availW / doc.rw, availH / doc.rh)
            local iw, ih = math.max(Skin.S(60), math.floor(doc.rw * scale)), math.max(Skin.S(60), math.floor(doc.rh * scale))
            P.s = iw
            W.Place(P.img, group, pad + math.floor((availW - iw) / 2), y, iw, ih)
            P:Refresh()
            P:Render()
        end

        Layout.Listen(function() if live.canvas == P then P.dirty = true Pump() end end)
        return P
    end,
}

-- ---- the layers --------------------------------------------------------------------------------------------------------------------------------------------

local KEYTIP = {
    height = 'How far the layer lifts the ground above the ground height, in world units, where it is fully drawn.',
    soft = 'How wide the transition from the drawn edge to the plain ground is, in world units (a layer is blurred by this).',
    rough = 'How much noise relief the layer adds on top of its height, in world units.',
    scale = 'The size of the noise features of the layer in world units: small values make a busy surface, large ones broad swells.',
    edge = 'How wide the edge of the plateau is: small values make a steep cliff.',
    depth = 'How deep the layer digs, in world units (water: below the water level of the layout).',
    level = 'The height the ground is levelled to, relative to the ground height of the layout.',
}

local COLORS = {
    { 118, 196, 92 }, { 78, 150, 70 }, { 226, 226, 236 }, { 160, 160, 176 }, { 224, 172, 88 }, { 196, 196, 120 }, { 160, 98, 62 }, { 110, 70, 50 },
    { 72, 140, 232 }, { 60, 200, 220 }, { 242, 72, 72 }, { 250, 140, 60 }, { 244, 220, 70 }, { 204, 92, 224 }, { 240, 130, 190 }, { 40, 40, 48 },
}

--- What the Import picture button does (module level: the controls come and go).
imp = { channel = 'gray', invert = false, stretch = false, hard = false, add = false, contain = false, flipX = false, flipZ = false }
local CHANNELS = { 'gray', 'r', 'g', 'b', 'a' }
local CHANNEL_NAMES = { gray = 'Brightness', r = 'Red', g = 'Green', b = 'Blue', a = 'Alpha' }

local function DestroySlider(s)
    for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do part:Destroy() end
    s.field:Destroy()
    if s.field.frame then s.field.frame:Destroy() end
end

local function Rebuild()
    local P = live.layers
    if P and P.Build then P:Build() end
end

Panels.Register{
    id = 'layoutlayers', title = 'Layout layers', minW = 260, minH = 300,
    create = function(group, host)
        local P = { items = {}, sliders = {}, w = 300, key = false }
        live.layers = P
        local c = Skin.color

        local function Add(ctl) table.insert(P.items, ctl) return ctl end
        local function Btn(text, w, fn, opts) return Add(W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts)) end

        function P:Clear()
            for _, s in P.sliders do DestroySlider(s) end
            P.sliders = {}
            for _, s in (P.csliders or {}) do DestroySlider(s) end
            P.csliders = {}
            for _, ctl in P.items do
                if ctl.Destroy then ctl:Destroy() end
            end
            P.items = {}
            if P.nameField then
                P.nameField:Destroy()
                if P.nameField.frame then P.nameField.frame:Destroy() end
                P.nameField = nil
            end
        end

        --- Builds every control for the layers now in the document (called when layers or the selection change).
        function P:Build()
            P:Clear()
            local doc = Layout.Doc
            if not doc then return end
            P.rows = {}
            P.lay = {}
            W.BeginLayout(group)
            for i, L in doc.layers do
                local idx = i
                local layer = L                       -- closures share the loop variable (nil after the loop)
                local row = {}
                row.eye = Btn(layer.visible and 'On' or 'Off', 34, function() layer.visible = not layer.visible Layout.Changed() Rebuild() end, { tip = 'Show or hide this layer on the canvas (a hidden layer still counts in the generator).' })
                row.name = Btn(L.name, 110, function() Layout.Select(idx) end, { toggle = true, tip = 'Choose this layer to draw on and to edit its settings.' })
                row.name:SetOn(idx == doc.sel)
                row.up = Btn('Up', 30, function() Layout.MoveLayer(idx, 1) end, { tip = 'Move the layer up: layers are applied from the bottom to the top.' })
                row.down = Btn('Dn', 30, function() Layout.MoveLayer(idx, -1) end, { tip = 'Move the layer down.' })
                row.del = Btn('X', 24, function()
                    Layout.RemoveLayer(idx)
                end, { tip = 'Delete the layer and what is drawn on it.' })
                table.insert(P.rows, row)
            end
            P.add = {}
            for _, kind in Layout.KindOrder do
                local k = kind
                table.insert(P.add, Btn('+ ' .. Layout.Kinds[k].label, 96, function() Layout.AddLayer(k) end, { tip = 'Add a layer of this kind: ' .. Layout.Kinds[k].tip }))
            end
            local L = doc.layers[doc.sel]
            P.kindLabel = Add(W.Label(group, '', 0, 0, { color = c.text }))
            P.kindTip = Add(W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' }))
            if L then
                for _, info in Layout.Kinds[L.kind].params do
                    local key = info.key
                    local s = W.Slider(group, { label = info.label, min = info.min, max = info.max, step = info.step, fmt = info.fmt, get = function() return doc.layers[doc.sel] and doc.layers[doc.sel].p[key] or info.default end,
                                                set = function(v) local l = doc.layers[doc.sel] if l then l.p[key] = v Layout.Changed() end end, tip = KEYTIP[key] })
                    table.insert(P.sliders, s)
                end
            end
            P.solo = Btn('Only this layer', 110, function(self) state.solo = self.on local cv = live.canvas if cv then cv:Render() end end, { toggle = true, tip = 'Show only the selected layer on the canvas.' })
            P.solo:SetOn(state.solo)
            P.clear = Btn('Clear', 60, function() local i = doc.sel Layout.Edit(i, 'clear layer', function() Layout.Fill(i, 0) end) end, { tip = 'Remove everything drawn on the selected layer.' })
            P.fill = Btn('Fill', 50, function() local i = doc.sel Layout.Edit(i, 'fill layer', function() Layout.Fill(i, 1) end) end, { tip = 'Fill the whole selected layer.' })
            P.smooth = Btn('Smooth', 66, function() local i = doc.sel Layout.Edit(i, 'smooth layer', function() Layout.Smooth(i) end) end, { tip = 'Soften what is drawn on the selected layer (one pass).' })
            P.invert = Btn('Invert', 60, function() local i = doc.sel Layout.Edit(i, 'invert layer', function() Layout.Invert(i) end) end, { tip = 'Draw what is empty and empty what is drawn on the selected layer.' })
            -- the colour of the layer on the canvas: a palette and a mixer
            P.colorLabel = Add(W.Label(group, 'Colour on the canvas', 0, 0, { color = c.text }))
            P.swatches = {}
            for _, col in COLORS do
                local rgb = col
                local b = Btn('', 22, function()
                    if doc.layers[doc.sel] then Layout.SetColor(doc.sel, rgb[1], rgb[2], rgb[3]) end
                    P:RefreshColour()
                end, { tip = 'Use this colour for the selected layer on the canvas (it only changes the picture, not the terrain).' })
                b.Refresh = function(self) self:SetSolidColor('ff' .. string.format('%02x%02x%02x', rgb[1], rgb[2], rgb[3])) end
                b:Refresh()
                b.rgb = rgb
                table.insert(P.swatches, b)
            end
            P.csliders = {}
            for k, name in { 'Red', 'Green', 'Blue' } do
                local ch = k
                local s2 = W.Slider(group, { label = name, min = 0, max = 255, step = 1, fmt = '%d', compact = true,
                    get = function() local l = doc.layers[doc.sel] return l and l.color[ch] or 0 end,
                    set = function(v)
                        local l = doc.layers[doc.sel]
                        if not l then return end
                        local col = { l.color[1], l.color[2], l.color[3] }
                        col[ch] = v
                        Layout.SetColor(doc.sel, col[1], col[2], col[3])
                    end, tip = 'One channel of the colour of the selected layer on the canvas.' })
                table.insert(P.csliders, s2)
            end
            function P:RefreshColour()
                local l = doc.layers[doc.sel]
                for _, b in P.swatches do
                    local same = l and l.color[1] == b.rgb[1] and l.color[2] == b.rgb[2] and l.color[3] == b.rgb[3]
                    b:SetText(same and 'x' or '')
                end
                for _, s2 in P.csliders do s2:Refresh() end
            end
            -- a picture becomes the content of the selected layer
            P.imgLabel = Add(W.Label(group, 'Picture into this layer', 0, 0, { color = c.text }))
            P.imgBtn = Btn('Import picture...', 130, function()
                if not rawget(_G, 'ed_file_dialog') then Say('no file dialog in this build') return end
                local path = ed_file_dialog(false, 'Import a picture into the layer', import('/lua/editor/interop.lua').FILTER, '')
                if not path or path == '' then return end
                local n, why = Layout.ImportImage(doc.sel, path, { channel = imp.channel, invert = imp.invert, stretch = imp.stretch, hard = imp.hard, add = imp.add,
                                                                    fit = imp.contain and 'contain' or 'fill', flipX = imp.flipX, flipZ = imp.flipZ })
                Say(n and ('picture drawn into the layer (' .. n .. ' cells changed; one undo step)') or ('not imported: ' .. tostring(why)))
                local cv = live.canvas
                if cv then cv:Render() end
            end, { tip = 'Choose a picture (PNG, TIFF, BMP, JPEG or a raw heightmap): its brightness becomes what is drawn on the selected layer, fitted over the canvas. One undo step.' })
            P.imgOpts = {}
            local function Opt(text, w, key, tip)
                local b = Btn(text, w, function(self) imp[key] = self.on end, { toggle = true, tip = tip })
                b:SetOn(imp[key])
                table.insert(P.imgOpts, { b, Skin.S(w) })
            end
            P.channel = Btn('', 120, function()
                for i, ch in CHANNELS do
                    if ch == imp.channel then imp.channel = CHANNELS[math.mod(i, table.getn(CHANNELS)) + 1] break end
                end
                P.channel:SetText('Reads: ' .. CHANNEL_NAMES[imp.channel])
            end, { tip = 'Which channel of the picture is read: its brightness, or only its red, green, blue or alpha channel.' })
            P.channel:SetText('Reads: ' .. CHANNEL_NAMES[imp.channel])
            table.insert(P.imgOpts, { P.channel, Skin.S(120) })
            Opt('Invert', 60, 'invert', 'Draw the dark parts of the picture instead of the bright ones.')
            Opt('Stretch', 66, 'stretch', 'Make the darkest value of the picture 0 and the brightest 1 (a heightmap that does not use the whole range).')
            Opt('Hard edge', 80, 'hard', 'Everything above one half becomes fully drawn, the rest is empty (a black and white picture becomes a clean shape).')
            Opt('Keep aspect', 90, 'contain', 'Fit the whole picture inside the canvas with its own proportions (otherwise it is stretched over the whole canvas).')
            Opt('Add', 46, 'add', 'Keep what is drawn already and add the picture (the larger value wins) instead of replacing the layer.')
            Opt('Flip X', 60, 'flipX', 'Mirror the picture left to right.')
            Opt('Flip Z', 60, 'flipZ', 'Mirror the picture top to bottom.')
            P:RefreshColour()
            local function Doc(label, key, min, max, step, fmt, tip)
                local s = W.Slider(group, { label = label, min = min, max = max, step = step, fmt = fmt, get = function() return doc[key] end, set = function(v) doc[key] = v Layout.Changed() end, tip = tip })
                table.insert(P.sliders, s)
                return s
            end
            P.docSliders = { Doc('Ground height (units)', 'base', 0, 120, 1, '%d', 'The height of the plain ground where nothing is drawn; hills, mountains and plateaus rise from it.'),
                             Doc('Water level (units)', 'water', 0, 120, 1, '%d', 'The height of the water surface: written to the map when a water layer is drawn.'),
                             Doc('Seed', 'seed', 0, 9999, 1, '%d', 'The seed of the noise relief: another number, another surface on the same drawing.'),
                             Doc('Weathering (gullies)', 'weather', 0, 1, 0.05, '%.2f', 'Droplet erosion on top of the layout (gullies and drainage lines). 0 leaves the surface as it is.') }
            P.gen = Btn('Generate terrain', 130, function()
                local n, why = Layout.Generate({})
                if n then
                    Say('terrain made from the layout: ' .. n .. ' samples changed (one undo step)')
                    if state.paintGround then
                        local R = import('/lua/editor/recipes.lua')
                        local summary, cells = R.Apply()
                        Say(summary and ('terrain and ground paint made from the layout (' .. cells .. ' cells painted)') or ('terrain made; ground paint: ' .. tostring(cells)))
                    end
                    pcall(function() import('/lua/editor/gui/panels_maptextures.lua').Refresh() end)
                else
                    Say('not made: ' .. tostring(why))
                end
                local cv = live.canvas
                if cv then cv:Render() end
            end, { tip = 'Turn the layout into the heights of the map (and the water level when a water layer is drawn): one undo step. The ground you have now is replaced.' })
            P.templates = {}
            for _, t in Layout.Templates do
                local id = t.id
                table.insert(P.templates, Btn(t.label, 84, function()
                    Layout.ApplyTemplate(id)
                    Say('template ' .. t.label .. ' drawn (the symmetry is ' .. tostring(Symmetry.Mode) .. '; one undo step)')
                    local cv = live.canvas
                    if cv then cv:Refresh() end
                end, { tip = 'Start from a drawing: ' .. t.tip .. ' This replaces what is drawn now (undo brings it back).' }))
            end
            P.paint = Btn('Paint the ground too', 140, function(self) state.paintGround = self.on end, { toggle = true, tip = 'After the terrain, apply the stratum recipe of the Stratum recipes panel (textures by slope, height and water).' })
            P.paint:SetOn(state.paintGround)
            P.status = Add(W.Label(group, state.status or '', 0, 0, { color = c.textDim, size = 'small' }))
            W.EndLayout(group)
            P.key = doc.rev
            P:Layout()
        end

        --- Places the controls for the width we have.
        function P:Layout()
            local doc = Layout.Doc
            if not doc or not P.rows then return end
            local pad = Skin.S(8)
            local w = P.w
            local y = pad
            y = W.Flow(group, { { P.gen, Skin.S(130) }, { P.paint, Skin.S(140) } }, pad, y, w - 2 * pad, Skin.S(24), Skin.S(4)) + Skin.S(2)
            W.Place(P.status, group, pad, y)
            W.Fit(P.status, state.status or '', w - 2 * pad)
            y = y + Skin.S(22)
            local tl = {}
            for _, b in P.templates do table.insert(tl, { b, Skin.S(84) }) end
            y = W.Flow(group, tl, pad, y, w - 2 * pad, Skin.S(22), Skin.S(3)) + Skin.S(8)
            for _, row in P.rows do
                y = W.Flow(group, { { row.eye, Skin.S(34) }, { row.name, Skin.S(110) }, { row.up, Skin.S(30) }, { row.down, Skin.S(30) }, { row.del, Skin.S(24) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(3)) + Skin.S(4)
            end
            local items = {}
            for _, b in P.add do table.insert(items, { b, Skin.S(96) }) end
            y = W.Flow(group, items, pad, y + Skin.S(4), w - 2 * pad, Skin.S(22), Skin.S(3)) + Skin.S(8)
            local L = doc.layers[doc.sel]
            if L then
                P.kindLabel:SetText(Layout.Kinds[L.kind].label .. ' layer')
                W.Place(P.kindLabel, group, pad, y)
                y = y + Skin.S(20)
                W.Fit(P.kindTip, Layout.Kinds[L.kind].tip, w - 2 * pad)
                W.Place(P.kindTip, group, pad, y)
                y = y + Skin.S(20)
                P.nameField = W.TextField(group, pad, y, Skin.S(160), Skin.S(22), { text = L.name, tip = 'The name of the layer (the graph node Map layout: layer mask finds a layer by its number in this list).' })
                P.nameField.OnEnterPressed = function(self, text)
                    local l = doc.layers[doc.sel]
                    if l and text ~= '' then l.name = text Layout.Changed() end
                    return true
                end
                y = y + Skin.S(28)
                for _, s in P.sliders do
                    if s ~= P.docSliders[1] and s ~= P.docSliders[2] and s ~= P.docSliders[3] and s ~= P.docSliders[4] then
                        s:Place(pad, y, w - 2 * pad)
                        y = y + Skin.S(50)
                    end
                end
            end
            y = W.Flow(group, { { P.solo, Skin.S(110) }, { P.clear, Skin.S(60) }, { P.fill, Skin.S(50) }, { P.smooth, Skin.S(66) }, { P.invert, Skin.S(60) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(3)) + Skin.S(10)
            W.Place(P.colorLabel, group, pad, y)
            y = y + Skin.S(20)
            local sw = {}
            for _, b in P.swatches do table.insert(sw, { b, Skin.S(22) }) end
            y = W.Flow(group, sw, pad, y, w - 2 * pad, Skin.S(22), Skin.S(3)) + Skin.S(4)
            local cw = math.floor((w - 4 * pad) / 3)
            for k, s2 in P.csliders do s2:Place(pad * k + cw * (k - 1), y, cw) end
            y = y + Skin.S(50)
            W.Place(P.imgLabel, group, pad, y)
            y = y + Skin.S(20)
            y = W.Flow(group, { { P.imgBtn, Skin.S(130) } }, pad, y, w - 2 * pad, Skin.S(24), Skin.S(3)) + Skin.S(3)
            y = W.Flow(group, P.imgOpts, pad, y, w - 2 * pad, Skin.S(22), Skin.S(3)) + Skin.S(10)
            for _, s in P.docSliders do
                s:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(50)
            end
        end

        function P:OnResize(w, h)
            P.w = w
            P:Build()
        end

        -- the layers or the selection changed: build again (a stroke only changes the cells: the controls stay)
        local lastLayers, lastSel = false, false
        Layout.Listen(function()
            if live.layers ~= P then return end
            local doc = Layout.Doc
            local sig = table.getn(doc.layers) .. ':' .. doc.sel
            for _, l in doc.layers do sig = sig .. '|' .. l.name .. (l.visible and '+' or '-') .. l.kind end
            if sig ~= P.sig or P.docRef ~= doc then
                P.sig = sig
                P.docRef = doc
                P:Build()
            end
        end)
        return P
    end,
}

-- ---- starts and resources ------------------------------------------------------------------------------------------------------------------------------

local MarkerRows = {
    { 'Starts', nil },
    { 'Players (pattern)', 'count', 1, 16, 1, '%d' , 'How many start positions the pattern makes.' },
    { 'Distance from the middle (share)', 'radius', 0.15, 0.95, 0.01, '%.2f' , 'How far from the middle the pattern puts the starts, as a share of the half map size.' },
    { 'Rotation (degrees)', 'rotation', 0, 360, 5, '%d' , 'Turns the whole pattern around the middle of the map.' },
    { 'Mass at each start', nil },
    { 'Mass per start', 'mass', 0, 16, 1, '%d' , 'How many Mass markers each start gets in the shape below.' },
    { 'Mass nearest (units)', 'massMin', 6, 120, 1, '%d' , 'The nearest distance of the mass from its start, in world units.' },
    { 'Mass farthest (units)', 'massMax', 8, 160, 1, '%d' , 'The farthest distance of the mass from its start, in world units.' },
    { 'Arc width (degrees)', 'arc', 30, 360, 5, '%d' , 'The width of the fan of the arc shape, in degrees.' },
    { 'Hydrocarbon', nil },
    { 'Hydrocarbon per start', 'hydro', 0, 4, 1, '%d' , 'How many Hydrocarbon markers each start gets.' },
    { 'Hydrocarbon nearest (units)', 'hydroMin', 10, 160, 1, '%d' , 'The nearest distance of the hydrocarbon from its start.' },
    { 'Hydrocarbon farthest (units)', 'hydroMax', 12, 200, 1, '%d' , 'The farthest distance of the hydrocarbon from its start.' },
    { 'Expansions and the middle', nil },
    { 'Extra mass per start', 'extra', 0, 16, 1, '%d' , 'Extra mass per start further out (the expansions), in the extra shape.' },
    { 'Extra nearest (units)', 'extraMin', 30, 300, 1, '%d' , 'The nearest distance of the extra mass from its start.' },
    { 'Extra farthest (units)', 'extraMax', 40, 400, 1, '%d' , 'The farthest distance of the extra mass from its start.' },
    { 'Mass in the middle', 'middle', 0, 16, 1, '%d' , 'Mass in a cluster at the middle of the map.' },
    { 'Rules', nil },
    { 'Spacing between markers (units)', 'spacing', 3, 30, 1, '%d' , 'The least distance between two markers; a spot closer than this to another marker is searched around.' },
    { 'Steepest ground (degrees)', 'maxSlope', 5, 60, 1, '%d' , 'The steepest ground a marker may stand on, in degrees.' },
    { 'Seed', 'seed', 0, 9999, 1, '%d' , 'The seed of the small variations of the plan.' },
}

local function Cycle(list, value)
    for i, v in list do
        if v == value then return list[math.mod(i, table.getn(list)) + 1] end
    end
    return list[1]
end

local function Nice(id)
    return string.upper(string.sub(id, 1, 1)) .. string.sub(id, 2)
end

Panels.Register{
    id = 'layoutmarkers', title = 'Start positions and resources', minW = 260, minH = 300,
    create = function(group, host)
        local P = { sliders = {}, labels = {}, buttons = {}, w = 300 }
        live.markers = P
        local c = Skin.color
        local S = LM.Settings

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        P.starts = Btn('', 190, function() S.starts = Cycle(LM.StartModes, S.starts) P:Refresh() end,
            { tip = 'Where the start positions come from: the start markers the map has, the bases drawn on Base layers of the layout, or a pattern (ring, corners, two sides, a line).' })
        P.pattern = Btn('', 130, function() S.pattern = Cycle(LM.Patterns, S.pattern) P:Refresh() end, { tip = 'The pattern of the start positions (used when the starts come from a pattern).' })
        P.shape = Btn('', 140, function() S.massShape = Cycle(LM.Shapes, S.massShape) P:Refresh() end,
            { tip = 'The shape of the mass around each start: ring (evenly around), arc (a fan facing the middle of the map), cluster (a blob), line (a row), pairs (two side by side).' })
        P.eshape = Btn('', 150, function() S.extraShape = Cycle(LM.Shapes, S.extraShape) P:Refresh() end, { tip = 'The shape of the extra mass further out.' })
        P.facing = Btn('', 150, function() S.facing = (S.facing == 'centre') and 'away' or 'centre' P:Refresh() end,
            { tip = 'Which way the arcs, clusters and rows face: towards the middle of the map or away from it.' })
        P.replace = Btn('Replace the starts', 130, function(self) S.replaceStarts = self.on end, { toggle = true, tip = 'When the starts come from a pattern or the bases: remove the start markers that are there first.' })
        P.clear = Btn('Remove the old ones', 140, function(self) S.clear = self.on end, { toggle = true, tip = 'Remove the Mass and Hydrocarbon markers this generator placed before, then place new ones.' })
        P.preview = Btn('Preview', 80, function()
            local plan = LM.Plan()
            Say('plan: ' .. plan.text .. ' (white and orange marks on the layout canvas; nothing is placed yet)')
            P:Refresh()
            local cv = live.canvas
            if cv then cv:Render() end
        end, { tip = 'Work out where everything would go and show it on the layout canvas, without placing anything.' })
        P.place = Btn('Place markers', 110, function()
            local made, why = LM.Place()
            if made then
                Say('placed ' .. made.starts .. ' starts, ' .. made.mass .. ' mass, ' .. made.hydro .. ' hydrocarbon' .. (made.failed > 0 and (' (' .. made.failed .. ' did not fit)') or '') .. ' (one undo step)')
            else
                Say('not placed: ' .. tostring(why))
            end
            P:Refresh()
            local cv = live.canvas
            if cv then cv:Render() end
        end, { tip = 'Place the starts and the resources into the map: one undo step.' })
        P.drop = Btn('Drop the preview', 110, function() LM.ClearPlan() local cv = live.canvas if cv then cv:Render() end end, { tip = 'Remove the marks of the plan from the canvas.' })
        P.text = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        for _, r in MarkerRows do
            if r[2] == nil then
                table.insert(P.labels, { label = W.Label(group, r[1], 0, 0, { color = c.text }), row = r })
            else
                local key = r[2]
                local s = W.Slider(group, { label = r[1], min = r[3], max = r[4], step = r[5], fmt = r[6], get = function() return S[key] end, set = function(v) S[key] = v end, tip = r[7] })
                table.insert(P.sliders, { s = s, row = r })
            end
        end

        function P:Refresh()
            P.starts:SetText('Starts from: ' .. (S.starts == 'existing' and 'the start markers' or (S.starts == 'base' and 'the drawn bases' or 'a pattern')))
            P.pattern:SetText('Pattern: ' .. Nice(S.pattern))
            P.shape:SetText('Mass shape: ' .. Nice(S.massShape))
            P.eshape:SetText('Extra shape: ' .. Nice(S.extraShape))
            P.facing:SetText('Facing: ' .. (S.facing == 'centre' and 'the middle' or 'away'))
            P.replace:SetOn(S.replaceStarts)
            P.clear:SetOn(S.clear)
            local plan = LM.LastPlan()
            W.Fit(P.text, plan and ('plan: ' .. plan.text) or (state.status or ''), P.w - 20)
            for _, e in P.sliders do e.s:Refresh() end
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local y = pad
            local li, si = 1, 1
            y = W.Flow(group, { { P.starts, Skin.S(190) }, { P.pattern, Skin.S(130) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
            for _, r in MarkerRows do
                if r[2] == nil then
                    local l = P.labels[li]
                    li = li + 1
                    W.Place(l.label, group, pad, y)
                    y = y + Skin.S(22)
                    if r[1] == 'Mass at each start' then
                        y = W.Flow(group, { { P.shape, Skin.S(140) }, { P.facing, Skin.S(150) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
                    elseif r[1] == 'Expansions and the middle' then
                        y = W.Flow(group, { { P.eshape, Skin.S(150) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
                    end
                else
                    local e = P.sliders[si]
                    si = si + 1
                    e.s:Place(pad, y, w - 2 * pad)
                    y = y + Skin.S(50)
                end
            end
            y = W.Flow(group, { { P.replace, Skin.S(130) }, { P.clear, Skin.S(140) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(6)
            y = W.Flow(group, { { P.preview, Skin.S(80) }, { P.place, Skin.S(110) }, { P.drop, Skin.S(110) } }, pad, y, w - 2 * pad, Skin.S(24), Skin.S(4)) + Skin.S(6)
            W.Place(P.text, group, pad, y)
            P:Refresh()
        end

        return P
    end,
}

function Refresh()
    for _, inst in live do
        if inst.Refresh then pcall(inst.Refresh, inst) end
    end
end
