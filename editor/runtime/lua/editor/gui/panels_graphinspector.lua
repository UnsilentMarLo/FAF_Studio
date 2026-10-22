-- The Graph inspector: the parameters of the selected node as sliders (field + slider + minus / plus), choices, switches, a curve editor and the list of props of a scatter output, the
-- values the node produced (lowest, highest, mean), its error and the time it took. Edits go through graph.lua (undoable; one slider drag is one undo entry); the Graph panel
-- re-evaluates and shows the result. Docs: docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
local GRun = import('/lua/editor/graphrun.lua')
local Fields = import('/lua/editor/fields.lua')

live = {}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local lastTick = 0

--- A parameter changed: the canvas re-evaluates now, unless the last evaluation was so recent (or slow) that a slider drag would only queue them up; the periodic tick catches up.
local function Changed()
    local now = rawget(_G, 'GetSystemTimeSeconds') and GetSystemTimeSeconds() or 0
    local rep = GRun.Report
    local wait = math.max(0.08, 2 * ((rep and rep.ms or 0) / 1000))
    if now - lastTick < wait then return end
    lastTick = now
    local ok, canvas = pcall(import, '/lua/editor/gui/panels_graph.lua')
    if ok and canvas.live and canvas.live.canvas then canvas.live.canvas:Tick() end
end

local function ShortName(path)
    return (string.gsub(path or '', '^.*/', ''))
end

local function DestroySlider(s)
    for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do part:Destroy() end
    s.field:Destroy()
    if s.field.frame then s.field.frame:Destroy() end
end

Panels.Register{
    id = 'graphinspector', title = 'Inspector', minW = 250, minH = 200,
    create = function(group, host)
        local Pn = { items = {}, sliders = {}, key = false, propSel = 1 }
        live.inspector = Pn
        local c = Skin.color

        local function Add(ctl) table.insert(Pn.items, ctl) return ctl end
        local function Btn(text, w, fn, opts) return Add(W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts)) end

        Pn.title = W.Label(group, '', 0, 0, { color = c.text })
        Pn.empty = W.Label(group, 'Select a node in the Graph to edit it.', 0, 0, { color = c.textDim })

        function Pn:Clear()
            for _, s in self.sliders do DestroySlider(s) end
            self.sliders = {}
            for _, ctl in self.items do
                if ctl.Destroy then ctl:Destroy() end
            end
            self.items = {}
            if self.curve then self.curve:Destroy() self.curve = nil end
            if self.list then self.list:Destroy() self.list = nil end
            for _, l in (self.lines or {}) do l:Destroy() end
            self.lines = {}
        end

        local function Node()
            local sel = Graph.SelectedList()
            if table.getn(sel) ~= 1 then return nil, table.getn(sel) end
            return Graph.NodeById(sel[1]), 1
        end

        local function Signature()
            local sel = Graph.SelectedList()
            local key = ''
            for _, id in sel do key = key .. id .. ',' end
            if sel[1] then
                local n = Graph.NodeById(sel[1])
                if n then
                    key = key .. '|' .. n.type .. (n.off and 'off' or '')
                    -- the note of a map texture output depends on the map's shader and on Use it on the map
                    local d = Nodes.Defs[n.type]
                    if d and d.mapTexture then
                        key = key .. '|' .. (rawget(_G, 'ed_stratum_shader') and tostring(ed_stratum_shader()) or '') .. (n.params.assign == false and 'f' or 'a')
                    end
                    for _, w in Graph.Current.wires do
                        if w[3] == n.id then key = key .. '|' .. w[4] .. '<' .. w[1] end
                    end
                end
            end
            return key
        end

        function Pn:Build()
            self:Clear()
            W.BeginLayout(group)
            local pad = Skin.S(8)
            local w = self.w or 300
            local y = pad
            local node, count = Node()
            if not node then
                self.title:SetText('')
                local text = 'Select a node in the Graph to edit it.'
                if count and count > 1 then text = count .. ' nodes selected. Copy, Paste, Duplicate and Delete work on all of them.'
                elseif Graph.SelWire then text = 'A wire is selected. Press Delete to remove it.' end
                W.Place(self.empty, group, pad, y)
                W.Fit(self.empty, text, w - 2 * pad)
                W.EndLayout(group)
                return
            end
            self.empty:SetText('')
            local def = Nodes.Defs[node.type]
            W.Fit(self.title, def.label .. '   #' .. node.id, w - 2 * pad)
            W.Place(self.title, group, pad, y)
            y = y + Skin.S(22)
            -- the description, word wrapped
            local lines = W.Paragraph(group, def.desc or '', pad, y, w - 2 * pad, { color = c.textDim, size = 'small' }, Skin.S(14))
            self.lines = lines
            y = y + table.getn(lines) * Skin.S(14) + Skin.S(6)
            -- an output that fills a map-wide shader texture says what the map's shader does with it (maptextures.lua), in the warning colour BEFORE a build when the shader does not read it and
            -- Use it on the map is on (Build then skips the texture), with a button that opens the shader browser
            if def.mapTexture then
                local okMT, MT = pcall(import, '/lua/editor/maptextures.lua')
                if okMT and MT then
                    local cur = MT.Current(def.mapTexture)
                    local un = MT.Unsupported(def.mapTexture)
                    local assign = node.params.assign ~= false
                    local text, col = cur.why, c.warn
                    if cur.slot then
                        text = (cur.shader ~= '' and cur.shader or 'The shader') .. ' reads it from the ' .. cur.slot.where .. ' (' .. cur.slot.layout .. ').'
                        col = c.accent
                    elseif un and assign then
                        text = un.text
                    elseif un then
                        text = (cur.shader ~= '' and cur.shader or 'The shader') .. ' does not use it. Use it on the map is off, so Build only writes the file.'
                        col = c.textDim
                    end
                    local more = W.Paragraph(group, text or '', pad, y, w - 2 * pad, { color = col, size = 'small' }, Skin.S(14))
                    for _, l in more do table.insert(self.lines, l) end
                    y = y + table.getn(more) * Skin.S(14) + Skin.S(6)
                    if un and assign then
                        local sw = Btn('Switch shader...', 130, function()
                            import('/lua/editor/gui/shaderbrowser.lua').Open(function(id)
                                Say('terrain shader: ' .. id)
                                Pn.key = false
                                Pn:Refresh()
                            end)
                        end, { tip = 'Open the shader browser to choose a terrain shader that reads this map-wide texture (Terrain000 or a later one).' })
                        W.Place(sw, group, pad, y, Skin.S(130), Skin.S(22))
                        y = y + Skin.S(28)
                    end
                end
            end
            -- name, bypass
            local nameLabel = Add(W.Label(group, 'Name', 0, 0, { color = c.textDim, size = 'small' }))
            W.Place(nameLabel, group, pad, y + 4)
            local nameField = W.TextField(group, 0, 0, w - 2 * pad - Skin.S(40), Skin.S(22), {
                text = node.label or '',
                onEnter = function(text)
                    Graph.SetLabel(node.id, text)
                    Changed()
                end })
            Add(nameField)
            table.insert(self.items, nameField.frame)
            W.Place(nameField.frame, group, pad + Skin.S(40), y, w - 2 * pad - Skin.S(40), Skin.S(22))
            y = y + Skin.S(28)
            local bypass = Btn('Bypass', 64, function(b)
                Graph.SetOff(node.id, b.on)
                Changed()
            end, { toggle = true })
            bypass:SetOn(node.off and true or false)
            W.Place(bypass, group, pad, y, Skin.S(64), Skin.S(22))
            local show = Btn('Show as mask', 100, function()
                local canvas = import('/lua/editor/gui/panels_graph.lua')
                if canvas.live.canvas then
                    canvas.live.canvas.bMask:SetOn(true)
                    canvas.state.mask = true
                    canvas.live.canvas.maskSig = nil
                    local ok, err = GRun.ShowMask(node.id)
                    if not ok then Say(tostring(err)) end
                end
            end)
            W.Place(show, group, pad + Skin.S(70), y, Skin.S(100), Skin.S(22))
            y = y + Skin.S(30)
            -- node presets (erosion)
            if def.presets then
                local bx = pad
                for _, pr in def.presets do
                    local p = pr
                    local b = Btn(p.label, 90, function()
                        Graph.SetParams(node.id, p.values, 'preset ' .. p.label)
                        Changed()
                        self:Build()
                    end)
                    if bx + Skin.S(90) > w - pad then bx = pad y = y + Skin.S(26) end
                    W.Place(b, group, bx, y, Skin.S(90), Skin.S(22))
                    bx = bx + Skin.S(94)
                end
                y = y + Skin.S(30)
            end
            -- parameters
            local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(210) + pad)))
            local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
            local sliderCount = 0
            local function Flush()
                if sliderCount > 0 then y = y + math.ceil(sliderCount / cols) * Skin.S(46) + Skin.S(2) end
                sliderCount = 0
            end
            for _, p in def.params do
                local param = p
                local wired = Graph.WireInto(node.id, param.key)
                if param.kind == 'number' then
                    local label = param.label .. (wired and '  (wired)' or '')
                    local s = W.Slider(group, { label = label, compact = true, min = param.min, max = param.max, step = param.step, fmt = param.fmt, tip = param.tip,
                        get = function()
                            local n = Graph.NodeById(node.id)
                            local v = n and n.params[param.key]
                            if v == nil then v = param.default end
                            return v
                        end,
                        set = function(v)
                            Graph.SetParam(node.id, param.key, v, true)
                            Changed()
                        end })
                    table.insert(self.sliders, s)
                    s:Place(pad + math.mod(sliderCount, cols) * (colW + pad), y + math.floor(sliderCount / cols) * Skin.S(46), colW)
                    sliderCount = sliderCount + 1
                else
                    Flush()
                    if param.kind == 'choice' then
                        local function Text()
                            local n = Graph.NodeById(node.id)
                            local v = n.params[param.key]
                            for i, id in param.ids do
                                if id == v then return param.label .. ': ' .. param.labels[i] end
                            end
                            return param.label .. ': ' .. tostring(v)
                        end
                        local b
                        b = Btn(Text(), 200, function()
                            local n = Graph.NodeById(node.id)
                            local at = 1
                            for i, id in param.ids do
                                if id == n.params[param.key] then at = i end
                            end
                            local back = rawget(_G, 'IsKeyDown') and IsKeyDown(16)
                            at = back and (at - 1) or (at + 1)
                            if at > table.getn(param.ids) then at = 1 end
                            if at < 1 then at = table.getn(param.ids) end
                            Graph.SetParam(node.id, param.key, param.ids[at])
                            b:SetText(Text())
                            Changed()
                        end)
                        W.Place(b, group, pad, y, w - 2 * pad, Skin.S(22))
                        y = y + Skin.S(26)
                    elseif param.kind == 'bool' then
                        local b = Btn(param.label, 200, function(self2)
                            Graph.SetParam(node.id, param.key, self2.on and true or false)
                            Changed()
                        end, { toggle = true })
                        b:SetOn(node.params[param.key] and true or false)
                        W.Place(b, group, pad, y, w - 2 * pad, Skin.S(22))
                        y = y + Skin.S(26)
                    elseif param.kind == 'text' then
                        local lab = Add(W.Label(group, param.label, 0, 0, { color = c.textDim }))
                        W.Place(lab, group, pad, y)
                        y = y + Skin.S(18)
                        local field = W.TextField(group, 0, 0, w - 2 * pad, Skin.S(22), {
                            text = node.params[param.key] or '',
                            onEnter = function(text)
                                Graph.SetParam(node.id, param.key, text)
                                Changed()
                            end })
                        Add(field)
                        W.Place(field.frame, group, pad, y, w - 2 * pad, Skin.S(22))
                        y = y + Skin.S(28)
                        table.insert(self.items, field.frame)
                    elseif param.kind == 'curve' then
                        local CurveW = import('/lua/editor/gui/curvewidget.lua')
                        local curve = CurveW.Curve(group, {
                            leftText = 'in 0', rightText = 'in 1', fixedLabels = true,
                            get = function()
                                local n = Graph.NodeById(node.id)
                                return n.params[param.key], n.params.smooth ~= false, false
                            end,
                            set = function(points)
                                Graph.SetParam(node.id, param.key, points, true)
                                Changed()
                            end,
                        })
                        local ch = math.min(Skin.S(200), w - 2 * pad)
                        curve:Place(pad, y, math.min(w - 2 * pad, Skin.S(260)), ch)
                        self.curve = curve
                        y = y + ch + Skin.S(8)
                    elseif param.kind == 'props' then
                        y = self:BuildProps(node, param, y, pad, w)
                    end
                end
            end
            Flush()
            y = y + Skin.S(4)
            -- what the node produced
            self.infoY = y
            self.info = self.info or {}
            for i = 1, 6 do
                if not self.info[i] then self.info[i] = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' }) end
                W.Place(self.info[i], group, pad, y + (i - 1) * Skin.S(15))
            end
            self.shownNode = node.id
            self.sig = false
            W.EndLayout(group)
            self:UpdateInfo()
        end

        --- The list of props / decals of a scatter output.
        function Pn:BuildProps(node, param, y, pad, w)
            local Props = import('/lua/editor/props.lua')
            local Decals = import('/lua/editor/decals.lua')
            local lab = Add(W.Label(group, 'Blueprints to scatter (pick one in the Props or Decals panel, then Add)', 0, 0, { color = c.textDim, size = 'small' }))
            W.Place(lab, group, pad, y)
            y = y + Skin.S(18)
            local function Entries()
                local n = Graph.NodeById(node.id)
                n.params[param.key] = n.params[param.key] or {}
                return n.params[param.key]
            end
            self.list = W.VirtualList(group, {
                rowH = 18,
                getCount = function() return table.getn(Entries()) end,
                bind = function(row, index)
                    local e = Entries()[index]
                    W.Fit(row.text, string.format('%s   weight %g', ShortName(e.bp), e.weight or 1), math.max(Skin.S(40), row.bg.Width() - Skin.S(12)))
                    row.text:SetColor(index == self.propSel and c.accent or c.text)
                    local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                    row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                    row.text.Top:Set(function() return row.bg.Top() + ty end)
                end,
                bgColor = c.panelAlt,
                onSelect = function(index)
                    self.propSel = index
                    self.list:Refresh()
                end,
            })
            self.list:SetRect(pad, y, w - 2 * pad, Skin.S(18 * 4))
            y = y + Skin.S(18 * 4) + Skin.S(6)
            local bAdd = Btn('Add selected', 100, function()
                local n = Graph.NodeById(node.id)
                local decals = n.params.kind == 'decals'
                local pick = decals and Decals.Active or Props.Active
                if not pick then
                    Say(decals and 'select a decal in the Decals panel first' or 'select a prop in the Props panel first')
                    return
                end
                local entries = Graph.CopyValue(Entries())
                table.insert(entries, { bp = pick, weight = 1 })
                Graph.SetParam(node.id, param.key, entries)
                self.propSel = table.getn(entries)
                self.list:Refresh()
                Changed()
            end)
            W.Place(bAdd, group, pad, y, Skin.S(100), Skin.S(22))
            local bDel = Btn('Remove', 64, function()
                local entries = Graph.CopyValue(Entries())
                if entries[self.propSel] then table.remove(entries, self.propSel) end
                Graph.SetParam(node.id, param.key, entries)
                self.propSel = math.max(1, math.min(self.propSel, table.getn(entries)))
                self.list:Refresh()
                Changed()
            end)
            W.Place(bDel, group, pad + Skin.S(106), y, Skin.S(64), Skin.S(22))
            y = y + Skin.S(28)
            local s = W.Slider(group, { label = 'Weight of the selected entry', compact = true, min = 0, max = 20, step = 0.5, fmt = '%.1f',
                get = function()
                    local e = Entries()[self.propSel]
                    return e and e.weight or 1
                end,
                set = function(v)
                    local entries = Graph.CopyValue(Entries())
                    if entries[self.propSel] then entries[self.propSel].weight = v end
                    Graph.SetParam(node.id, param.key, entries, true)
                    self.list:Refresh()
                    Changed()
                end })
            table.insert(self.sliders, s)
            s:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(48)
            return y
        end

        --- The numbers about the node's result.
        function Pn:UpdateInfo()
            local id = self.shownNode
            if not id or not self.info then return end
            local run = GRun.Main
            local e = run and run:Entry(id)
            local lines = {}
            if e and e.err then
                table.insert(lines, (e.upstream and 'waiting: ' or 'error: ') .. tostring(e.err))
            elseif e and e.outs then
                local n = Graph.NodeById(id)
                local def = Nodes.Defs[n.type]
                for _, o in def.outputs do
                    local v = e.outs[o.name]
                    if v ~= nil then
                        if o.type == 'height' or o.type == 'mask' then
                            local mn, mx, mean = Fields.Stats(v)
                            table.insert(lines, string.format('%s: %.4g .. %.4g   mean %.4g', o.name, mn, mx, mean))
                        elseif o.type == 'number' then
                            table.insert(lines, string.format('%s = %.5g', o.name, v))
                        end
                    end
                end
                if e.ms then table.insert(lines, string.format('%.1f ms at 1/%d resolution', e.ms, run.step)) end
            end
            for i = 1, 6 do
                local l = self.info[i]
                if l then
                    W.Fit(l, lines[i] or '', (self.w or 300) - Skin.S(16))
                    l:SetColor((e and e.err and i == 1) and c.error or c.textDim)
                end
            end
        end

        function Pn:Refresh()
            local sig = Signature()
            if sig ~= self.key then
                self.key = sig
                self:Build()
                return
            end
            for _, s in self.sliders do s:Refresh() end
            local rev = GRun.Main and GRun.Main.ver or 0
            local now = Graph.DataRevision .. ':' .. rev
            if now ~= self.infoSig then
                self.infoSig = now
                self:UpdateInfo()
            end
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            self.key = false
            self:Refresh()
        end

        function Pn:Destroy()
            self.dead = true
        end

        return Pn
    end,
}

function Refresh()
    local Pn = live.inspector
    if Pn and not Pn.dead and Pn.w then Pn:Refresh() end
end
