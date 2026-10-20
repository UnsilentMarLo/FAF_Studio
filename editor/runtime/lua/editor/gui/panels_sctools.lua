-- The SC terrain panel (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T6): base pads and resource rings, symmetry of the whole map, the pathable slope limit and ramp check, the map
-- skeleton generator, and water coupled masks. One panel with a section switch; every number is a field + slider + minus / plus. The logic lives in sctools.lua and skeleton.lua; the
-- native ops in EdFieldSc.cpp. The checks are in the Terrain checks panel (panels_terrainchecks.lua).
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local SC = import('/lua/editor/sctools.lua')
local Sk = import('/lua/editor/skeleton.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Fields = import('/lua/editor/fields.lua')

live = {}
pending = false
section = 'pads'
selWater = false
lines = {}          -- result lines of the last ramp check
thumb = { path = false, text = '' }

local SECTIONS = { { 'pads', 'Pads' }, { 'symmetry', 'Symmetry' }, { 'slope', 'Slope limit' }, { 'skeleton', 'Skeleton' }, { 'water', 'Water' } }

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Destroy(c)
    if not c then return end
    if c.minus and c.plus then
        for _, part in { c.label, c.track, c.fill, c.thumb, c.minus, c.plus } do part:Destroy() end
        c.field:Destroy()
        if c.field.frame then c.field.frame:Destroy() end
    else
        c:Destroy()
    end
end

--- Runs fn and reports an error into the panel's status line.
local function Guard(Pn, fn)
    local ok, err = pcall(fn)
    if not ok then SC.Message = 'failed: ' .. tostring(err) Say(SC.Message) end
    if Pn then Pn:Refresh() end
end

Panels.Register{
    id = 'sctools', title = 'SC terrain', minW = 260, minH = 200, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = {}
        live.sctools = Pn
        Pn.group = group
        local c = Skin.color
        Pn.blocks = {}      -- layout: { kind = 'flow' | 'grid' | 'label' | 'pic' | 'gap', items = {...} }
        Pn.all = {}         -- every control of the section, for Destroy
        Pn.sliders = {}
        Pn.toggles = {}     -- id -> { button, isOn = function }

        local function Btn(text, w, fn, opts)
            local b = W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), function(self) fn(self) end, opts)
            table.insert(Pn.all, b)
            return b
        end
        local function Lbl(text, opts)
            local l = W.Label(group, text, 0, 0, opts or { color = c.text })
            table.insert(Pn.all, l)
            return l
        end
        local function Sld(label, min, max, step, fmt, get, set, tip)
            local s = W.Slider(group, { label = label, compact = true, min = min, max = max, step = step, fmt = fmt, get = get, tip = tip,
                set = function(v) set(v) Pn:Refresh() end })
            table.insert(Pn.all, s)
            table.insert(Pn.sliders, s)
            return s
        end
        --- A toggle button wired to a boolean in a table.
        local function Tog(text, w, tbl, key, after)
            local b = Btn(text, w, function(self) tbl[key] = self.on if after then after() end Pn:Refresh() end, { toggle = true })
            b:SetOn(tbl[key] and true or false)
            Pn.toggles[b] = function() return tbl[key] and true or false end
            return b
        end
        --- A group of exclusive buttons for tbl[key] with the given { value, label } list.
        local function Choice(tbl, key, options, w, after)
            local list = {}
            for _, o in options do
                local val = o[1]
                local b
                b = Btn(o[2], w, function() tbl[key] = val if after then after() end Pn:Refresh() end, { toggle = true })
                Pn.toggles[b] = function() return tbl[key] == val end
                table.insert(list, b)
            end
            return list
        end

        local function Block(kind, items) table.insert(Pn.blocks, { kind = kind, items = items }) end

        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.title = W.Label(group, '', 0, 0, { color = c.text })
        Pn.pic = Bitmap(group)
        Pn.frame = Bitmap(group)
        Pn.frame:SetSolidColor(c.panelAlt)
        Pn.frame.Depth:Set(function() return group.Depth() + 4 end)
        Pn.pic.Depth:Set(function() return group.Depth() + 6 end)
        Pn.pic:DisableHitTest()
        Pn.secButtons = {}
        for _, e in SECTIONS do
            local id = e[1]
            local b = W.Button(group, e[2], 0, 0, Skin.S(78), Skin.S(22), function() section = id Pn:Rebuild() end, { toggle = true })
            table.insert(Pn.secButtons, { id = id, button = b })
        end

        -- ---- the sections ------------------------------------------------------------------------------------------------------------------------

        local function BuildPads()
            local S = SC.Settings
            Pn.info = Lbl('', { color = c.textDim, size = 'small' })
            Block('label', { Pn.info })
            Block('flow', { Tog('Start pads', 80, S, 'startPads'), Tog('Mass pads', 80, S, 'massPads'), Tog('Hydro pads', 80, S, 'hydroPads'), Tog('Ring', 50, S, 'ring'), Tog('Cluster', 66, S, 'cluster'), Tog('Auto', 56, S, 'auto') })
            Block('label', { Lbl('Pad height') })
            Block('flow', Choice(S, 'level', { { 0, 'Mean' }, { 1, 'Lowest' }, { 2, 'Highest' } }, 74))
            Block('grid', {
                Sld('Start pad half size', 2, 24, 1, '%d', function() return S.startHalf end, function(v) S.startHalf = v end),
                Sld('Start pad skirt', 0, 40, 1, '%d', function() return S.startSkirt end, function(v) S.startSkirt = v end),
                Sld('Mass pad half size', 1, 10, 0.5, '%.1f', function() return S.massHalf end, function(v) S.massHalf = v end),
                Sld('Mass pad skirt', 0, 16, 1, '%d', function() return S.massSkirt end, function(v) S.massSkirt = v end),
                Sld('Hydro pad half size', 1, 12, 0.5, '%.1f', function() return S.hydroHalf end, function(v) S.hydroHalf = v end),
                Sld('Hydro pad skirt', 0, 16, 1, '%d', function() return S.hydroSkirt end, function(v) S.hydroSkirt = v end),
                Sld('Ring radius (units)', 5, 100, 1, '%d', function() return S.ringRadius end, function(v) S.ringRadius = v end,
                    'Distance of the ring of mass and hydro pads from the start position, in map units.'),
                Sld('Cluster distance (units)', 3, 80, 1, '%d', function() return S.clusterDist end, function(v) S.clusterDist = v end),
                Sld('Strength', 0, 1, 0.05, '%.2f', function() return S.strength end, function(v) S.strength = v end),
            })
            Block('flow', {
                Btn('Apply pads', 90, function() Guard(Pn, function() local n, err = SC.Apply() if n == false then SC.Message = tostring(err) end end) end),
                Btn('Remove pads', 96, function() Guard(Pn, function() local n, err = SC.Remove() if n == false then SC.Message = tostring(err) end end) end),
            })
        end

        local function BuildSymmetry()
            local S = SC.Sym
            Pn.info = Lbl('', { color = c.textDim, size = 'small' })
            Block('label', { Pn.info })
            local modes = {}
            for _, m in Symmetry.Modes do table.insert(modes, { m.id, m.label }) end
            local mb = {}
            for _, m in Symmetry.Modes do
                local id = m.id
                local b = Btn(m.label, 126, function() Symmetry.SetMode(id) S.master = 1 Pn:Rebuild() end, { toggle = true })
                Pn.toggles[b] = function() return Symmetry.Mode == id end
                table.insert(mb, b)
            end
            Block('label', { Lbl('Symmetry (the one the marker tools use)') })
            Block('flow', mb)
            local parts = SC.Parts()
            if table.getn(parts) > 0 then
                Block('label', { Lbl('Keep (the rest is made from it)') })
                local pb = {}
                for i, name in parts do
                    local idx = i
                    local b = Btn(name, 150, function() S.master = idx Pn:Refresh() end, { toggle = true })
                    Pn.toggles[b] = function() return S.master == idx end
                    table.insert(pb, b)
                end
                Block('flow', pb)
            end
            Block('label', { Lbl('Combine') })
            Block('flow', Choice(S, 'combine', { { 'copy', 'Copy' }, { 'avg', 'Average' }, { 'max', 'Highest' }, { 'min', 'Lowest' } }, 74))
            Block('grid', { Sld('Soft seam (units)', 0, 40, 1, '%d', function() return S.seam end, function(v) S.seam = v end) })
            Block('label', { Lbl('What to symmetrise') })
            local tb = { Tog('Heights', 70, S, 'height'), Tog('Terrain types', 100, S, 'types') }
            for i = 1, 8 do tb[table.getn(tb) + 1] = Tog('L' .. i, 36, S.layers, i) end
            Block('flow', tb)
            Block('flow', {
                Btn('Symmetrise map', 110, function() Guard(Pn, function() local n, err = SC.Symmetrize() if n == false then SC.Message = tostring(err) end end) end),
                Btn('Check markers', 100, function()
                    Guard(Pn, function()
                        local list = SC.MarkerCheck()
                        Pn.markerText = string.format('%d marker(s) without a symmetric partner', table.getn(list))
                        if list[1] then Pn.markerText = Pn.markerText .. ' (first: ' .. list[1].name .. ')' end
                    end)
                end),
            })
            Pn.markerLine = Lbl('', { color = c.textDim, size = 'small' })
            Block('label', { Pn.markerLine })
        end

        local function RampText(rep, title)
            lines = {}
            if not rep then table.insert(lines, 'select a path in the Paths tool first') return end
            table.insert(lines, string.format('%s: length %.0f, grade max %.2f, mean %.2f, %.0f%% over the limit, height %.1f .. %.1f', title, rep.length, rep.maxGrade, rep.meanGrade, rep.over * 100, rep.minH, rep.maxH))
            for i = 1, math.min(3, table.getn(rep.runs)) do
                local r = rep.runs[i]
                table.insert(lines, string.format('  steep stretch at %.0f, %.0f: grade %.2f over %.0f units', r.x, r.z, r.grade, r.s1 - r.s0))
            end
        end

        local function BuildSlope()
            local S = SC.Slope
            Block('label', { Lbl('Mode') })
            Block('flow', Choice(S, 'mode', { { 'lower', 'Cut peaks' }, { 'raise', 'Fill valleys' }, { 'both', 'Both' } }, 90))
            Block('grid', {
                Sld('Limit (rise per run; 0.75 blocks land)', 0.1, 2, 0.01, '%.2f', function() return S.limit end, function(v) S.limit = v end),
                Sld('Safety margin', 0, 0.2, 0.01, '%.2f', function() return S.margin end, function(v) S.margin = v end),
                Sld('Cut / fill balance (0 fill .. 1 cut)', 0, 1, 0.05, '%.2f', function() return S.balance end, function(v) S.balance = v end),
                Sld('Strength', 0, 1, 0.05, '%.2f', function() return S.strength end, function(v) S.strength = v end),
                Sld('Only inside texture layer (0 = everywhere)', 0, 8, 1, '%d', function() return S.layer end, function(v) S.layer = v end),
                Sld('Layer edge softness', 0, 12, 1, '%d', function() return S.soft end, function(v) S.soft = v end),
                Sld('Unit class shown (1 small .. 4 experimental)', 1, 4, 1, '%d', function() return S.class end, function(v) S.class = v end),
            })
            Block('pic', {})
            Pn.report = Lbl('', { color = c.textDim, size = 'small' })
            Block('label', { Pn.report })
            Block('flow', {
                Btn('Update report', 100, function() Guard(Pn, function() SC.SlopeReport() thumb.path = SC.SlopeThumb(128) Pn:ShowThumb() end) end),
                Btn('Apply slope limit', 120, function() Guard(Pn, function() SC.SlopeApply() thumb.path = SC.SlopeThumb(128) Pn:ShowThumb() end) end),
            })
            Block('label', { Lbl('Ramp check (the grade along a route)') })
            Block('flow', {
                Btn('Check selected path', 140, function()
                    Guard(Pn, function()
                        local Paths = import('/lua/editor/paths.lua')
                        local p = Paths.Current and Paths.ById(Paths.Current)
                        RampText(p and SC.RampPath(p.id, {}) or nil, p and (p.name or p.id) or '')
                    end)
                end),
            })
            Pn.rampLines = {}
            for i = 1, 4 do
                local l = Lbl('', { color = c.textDim, size = 'small' })
                table.insert(Pn.rampLines, l)
                Block('label', { l })
            end
        end

        local function BuildSkeleton()
            local S = Sk.Settings
            local styles, topo = {}, {}
            for _, st in Sk.Styles do table.insert(styles, { st.id, st.label }) end
            for _, t in Sk.Topologies do table.insert(topo, { t, string.upper(string.sub(t, 1, 1)) .. string.sub(t, 2) }) end
            Block('label', { Lbl('Lane style') })
            Block('flow', Choice(S, 'style', styles, 112, function() Pn:Rebuild() end))
            Block('label', { Lbl('Connections') })
            Block('flow', Choice(S, 'topology', topo, 70))
            local sl = {
                Sld('Lanes per connection', 1, 3, 1, '%d', function() return S.lanes end, function(v) S.lanes = v end),
                Sld('Lane half width', 3, 24, 1, '%d', function() return S.laneWidth end, function(v) S.laneWidth = v end),
                Sld('Lane falloff', 0, 24, 1, '%d', function() return S.laneFalloff end, function(v) S.laneFalloff = v end),
                Sld('Lane grade limit', 0.1, 0.75, 0.01, '%.2f', function() return S.laneGrade end, function(v) S.laneGrade = v end),
                Sld('Bend (units)', 0, 60, 1, '%d', function() return S.bend end, function(v) S.bend = v end),
            }
            if S.style == 'ridge' then
                table.insert(sl, Sld('Ridge height', 2, 30, 1, '%d', function() return S.ridgeHeight end, function(v) S.ridgeHeight = v end))
                table.insert(sl, Sld('Ridge half width', 2, 14, 1, '%d', function() return S.ridgeWidth end, function(v) S.ridgeWidth = v end))
                table.insert(sl, Sld('Gap lane - ridge', 0, 14, 1, '%d', function() return S.ridgeGap end, function(v) S.ridgeGap = v end))
            elseif S.style == 'ramps' then
                table.insert(sl, Sld('Plateau height', 2, 20, 1, '%d', function() return S.plateau end, function(v) S.plateau = v end))
                table.insert(sl, Sld('Plateau half size', 8, 40, 1, '%d', function() return S.plateauHalf end, function(v) S.plateauHalf = v end))
                table.insert(sl, Sld('Ramp half width', 2, 14, 1, '%d', function() return S.rampWidth end, function(v) S.rampWidth = v end))
                table.insert(sl, Sld('Choke half width', 1, 14, 1, '%d', function() return S.chokeWidth end, function(v) S.chokeWidth = v end))
            elseif S.style == 'islands' then
                table.insert(sl, Sld('Island radius', 12, 60, 1, '%d', function() return S.islandRadius end, function(v) S.islandRadius = v end))
                table.insert(sl, Sld('Moat width', 6, 40, 1, '%d', function() return S.moatWidth end, function(v) S.moatWidth = v end))
                table.insert(sl, Sld('Moat depth below the water', 1, 12, 1, '%d', function() return S.moatDepth end, function(v) S.moatDepth = v end))
                table.insert(sl, Sld('Causeway half width', 2, 12, 1, '%d', function() return S.bridgeWidth end, function(v) S.bridgeWidth = v end))
            end
            table.insert(sl, Sld('Hub plaza half size', 3, 24, 1, '%d', function() return S.hubHalf end, function(v) S.hubHalf = v end))
            Block('grid', sl)
            Block('flow', { Tog('Base pads', 80, S, 'pads'), Tog('Smooth lanes', 100, S, 'smooth') })
            Block('flow', {
                Btn('Generate', 80, function() Guard(Pn, function() local n, err = Sk.Generate() if n == false then Sk.Message = tostring(err) end end) end),
                Btn('Apply all', 80, function() Guard(Pn, function() local n, err = Sk.ApplyAll() if n == false then Sk.Message = tostring(err) end end) end),
                Btn('Remove', 70, function() Guard(Pn, function() Sk.Clear() end) end),
            })
            Pn.skInfo = Lbl('', { color = c.textDim, size = 'small' })
            Block('label', { Pn.skInfo })
        end

        local function BuildWater()
            Pn.wInfo = Lbl('', { color = c.textDim, size = 'small' })
            Block('label', { Pn.wInfo })
            local add = {}
            for _, kind in SC.Water.Order do
                local k = kind
                table.insert(add, Btn('+ ' .. SC.Water.Kinds[k].label, 104, function()
                    local d = SC.Water.Add(k, math.min(8, table.getn(SC.Water.Defs) + 1))
                    selWater = d.id
                    Pn:Rebuild()
                end))
            end
            Block('flow', add)
            local sel = selWater and SC.Water.ById(selWater)
            if not sel and SC.Water.Defs[1] then sel = SC.Water.Defs[1] selWater = sel.id end
            Block('flow', { Tog('Live (re-evaluate when the water level changes)', 300, SC.Water, 'live') })
            if sel then
                local names = {}
                for _, d in SC.Water.Defs do
                    local id = d.id
                    local b = Btn((SC.Water.Kinds[d.kind] and SC.Water.Kinds[d.kind].label or d.kind) .. ' > L' .. d.layer, 110, function() selWater = id Pn:Rebuild() end, { toggle = true })
                    Pn.toggles[b] = function() return selWater == id end
                    table.insert(names, b)
                end
                Block('flow', names)
                local sl = {
                    Sld('Texture layer', 1, 8, 1, '%d', function() return sel.layer end, function(v) sel.layer = v end),
                    Sld('Strength', 0, 1, 0.05, '%.2f', function() return sel.strength end, function(v) sel.strength = v end),
                    Sld('Edge softness (units)', 0, 10, 0.25, '%.2f', function() return sel.soft end, function(v) sel.soft = v end),
                }
                if sel.kind == 'beach' or sel.kind == 'shore' then table.insert(sl, Sld('Width (units)', 0.5, 20, 0.5, '%.1f', function() return sel.width end, function(v) sel.width = v end)) end
                if sel.kind == 'beach' then table.insert(sl, Sld('Steepest beach (degrees)', 5, 60, 1, '%d', function() return sel.slope end, function(v) sel.slope = v end)) end
                if sel.kind == 'shallows' or sel.kind == 'deep' then table.insert(sl, Sld('Depth (units)', 0.5, 30, 0.5, '%.1f', function() return sel.depth end, function(v) sel.depth = v end)) end
                Block('grid', sl)
                Block('pic', {})
                Pn.wCover = Lbl('', { color = c.textDim, size = 'small' })
                Block('label', { Pn.wCover })
                Block('flow', {
                    Btn('Preview', 66, function() Guard(Pn, function() local cover, pic = SC.Water.Preview(sel, 128) thumb.path = pic thumb.text = cover and string.format('covers %.1f%% of the map', cover * 100) or 'no water in this map' Pn:ShowThumb() end) end),
                    Btn('Apply', 60, function() Guard(Pn, function() local n, err = SC.Water.Apply(sel) if n == false then SC.Message = tostring(err) end end) end),
                    Btn('Remove result', 100, function() Guard(Pn, function() SC.Water.Unapply(sel) end) end),
                    Btn('Delete', 60, function() Guard(Pn, function() SC.Water.Unapply(sel) SC.Water.Remove(sel.id) selWater = false Pn:Rebuild() end) end),
                })
            end
        end

        --- Rebuilds the section on the next tick (a button must not destroy itself inside its own click handler).
        function Pn:Rebuild()
            pending = true
        end

        --- (Re)builds the controls of the current section.
        function Pn:Build()
            for _, ctl in self.all do Destroy(ctl) end
            self.all, self.sliders, self.toggles, self.blocks = {}, {}, {}, {}
            self.info, self.report, self.skInfo, self.wInfo, self.wCover, self.markerLine, self.rampLines = nil, nil, nil, nil, nil, nil, nil
            if section == 'pads' then BuildPads()
            elseif section == 'symmetry' then BuildSymmetry()
            elseif section == 'slope' then BuildSlope()
            elseif section == 'skeleton' then BuildSkeleton()
            else BuildWater() end
            self:Refresh()
        end

        function Pn:ShowThumb()
            if thumb.path then
                self.pic:SetTexture(thumb.path)
                self.pic:Show()
            else
                self.pic:Hide()
            end
        end

        function Pn:Refresh()
            local maxW = (self.w or 300) - Skin.S(16)
            W.Fit(self.status, SC.Message ~= '' and SC.Message or '', maxW)
            W.Fit(self.title, 'SC terrain tools: ' .. section, maxW)
            for _, e in self.secButtons do e.button:SetOn(e.id == section) end
            for b, isOn in self.toggles do b:SetOn(isOn()) end
            for _, s in self.sliders do s:Refresh() end
            if self.info then
                local n = SC.PadCounts()
                local text = string.format('%d start(s), %d mass, %d hydro in %d shared height group(s)%s', n.start, n.mass, n.hydro, n.groups, n.extra > 0 and (', ' .. n.extra .. ' plaza(s)') or '')
                if SC.PadResult then text = text .. (SC.Stale() and '  -  markers moved: apply again' or '  -  applied') end
                W.Fit(self.info, text, maxW)
            end
            if self.markerLine then W.Fit(self.markerLine, self.markerText or '', maxW) end
            if self.report then W.Fit(self.report, SC.Slope.report ~= '' and SC.Slope.report or 'press Update report', maxW) end
            if self.rampLines then
                for i, l in self.rampLines do W.Fit(l, lines[i] or '', maxW) end
            end
            if self.skInfo then W.Fit(self.skInfo, Sk.Message ~= '' and Sk.Message or (Sk.Settings.count .. ' skeleton path(s)'), maxW) end
            if self.wInfo then
                local level = SC.WaterLevel()
                local text = level and string.format('water level %.2f', level) or 'this map has no water (World panel)'
                local old = SC.Water.OutOfDate()
                if old > 0 then text = text .. string.format('  -  %d mask(s) at another level: Apply', old) end
                W.Fit(self.wInfo, text, maxW)
            end
            if self.wCover then W.Fit(self.wCover, thumb.text or '', maxW) end
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            W.BeginLayout(group)
            local function Flow(buttons)
                local bx = pad
                for _, b in buttons do
                    local bw = b.Width()
                    if bx > pad and bx + bw > w - pad then
                        bx = pad
                        y = y + Skin.S(26)
                    end
                    W.Place(b, group, bx, y, bw, Skin.S(22))
                    bx = bx + bw + Skin.S(4)
                end
                y = y + Skin.S(26)
            end
            local secs = {}
            for _, e in self.secButtons do table.insert(secs, e.button) end
            Flow(secs)
            W.Place(self.title, group, pad, y)
            y = y + Skin.S(20)
            W.Place(self.status, group, pad, y)
            y = y + Skin.S(20)
            self.frame:Hide()
            for _, blk in self.blocks do
                if blk.kind == 'flow' then
                    Flow(blk.items)
                elseif blk.kind == 'label' then
                    for _, l in blk.items do
                        W.Place(l, group, pad, y)
                        y = y + Skin.S(20)
                    end
                elseif blk.kind == 'grid' then
                    local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(190) + pad)))
                    local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
                    local i, rows = 0, 0
                    for _, sl in blk.items do
                        local col = math.mod(i, cols)
                        local row = math.floor(i / cols)
                        sl:Place(pad + col * (colW + pad), y + row * Skin.S(46), colW)
                        rows = row + 1
                        i = i + 1
                    end
                    y = y + rows * Skin.S(46) + Skin.S(4)
                elseif blk.kind == 'pic' then
                    local size = Skin.S(128)
                    self.frame:Show()
                    W.Place(self.frame, group, pad, y, size, size)
                    W.Place(self.pic, group, pad, y, size, size)
                    y = y + size + Skin.S(6)
                end
            end
            W.EndLayout(group)
            self:ShowThumb()
            if not self:HasPic() then self.frame:Hide() self.pic:Hide() end
            self:Refresh()
        end

        function Pn:HasPic()
            for _, blk in self.blocks do
                if blk.kind == 'pic' then return true end
            end
            return false
        end

        function Pn:Destroy()
            live.sctools = nil
        end

        Pn:Build()
        return Pn
    end,
}

local lastRev = -1

--- Module level tick (the shell calls it every frame): the pads follow moved markers (Auto), water masks follow the water level (Live).
function Refresh()
    SC.Tick()
    SC.Water.Tick()
    local Pn = live.sctools
    if pending then
        pending = false
        if Pn then
            Pn:Build()
            Pn:OnResize(Pn.w, Pn.h)
        end
    end
    if Pn then
        local rev = SC.Revision + Sk.Settings.count
        if rev ~= lastRev then
            lastRev = rev
            Pn:Refresh()
        end
    end
end

--- Frees what the panel holds (a module reload or leaving the editor).
function Release()
    SC.Reset()
end
