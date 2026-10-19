-- The Stamps panel: the library of stamp shapes (procedural shapes and greyscale pictures of the brush folders and of your own: Import copies PNG / TIF / BMP / DDS files into the editor's
-- user folder) with previews, and the settings of the two stamp tools (stamp.lua): the height stamp (add / subtract / max / min / replace, height, strength, falloff) and the texture stamp
-- (paints the active layer with the picture as its mask), both with rotation (and a random turn per dab), size and position jitter and spacing. Symmetry applies to both; a stroke is one undo step.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Grid = import('/lua/editor/gui/grid.lua')
local UI = import('/lua/editor/ui.lua')
local Brushes = import('/lua/editor/brushes.lua')
local Stamp = import('/lua/editor/stamp.lua')
local Thumbs = import('/lua/editor/assetthumbs.lua')
local UserData = import('/lua/editor/userdata.lua')

live = {}

do
    local saved = UserData.Get('stamp', nil)
    if type(saved) == 'table' then Stamp.Restore(saved) end
end

local function Save()
    UserData.Set('stamp', Stamp.Snapshot())
end

local SLIDERS = {
    { 'height', 'Height of a white pixel (units)', 0, 200, 0.5, '%.1f' },
    { 'strength', 'Strength (percent)', 0, 100, 1, '%d' },
    { 'falloff', 'Edge falloff (percent of the radius)', 0, 100, 1, '%d' },
    { 'rotation', 'Rotation (degrees)', 0, 359, 1, '%d' },
    { 'scaleJitter', 'Size jitter (percent)', 0, 90, 1, '%d' },
    { 'posJitter', 'Position jitter (percent of the radius)', 0, 100, 1, '%d' },
    { 'spacing', 'Spacing (percent of the width)', 10, 400, 5, '%d' },
}

Panels.Register{
    id = 'stamps', title = 'Stamps', minW = 240, minH = 320, stack = { workspace = 'Terrain', with = 'shapes' },
    create = function(group, host)
        local P = { shown = {}, query = '' }
        live.stamps = P
        local c = Skin.color

        function P:Rebuild()
            local q = string.lower(P.query or '')
            P.shown = {}
            for _, e in Brushes.List() do
                if q == '' or string.find(string.lower(e.label), q, 1, true) then table.insert(P.shown, e) end
            end
            if P.grid then P.grid:Refresh() end
        end

        local function Thumb(e)
            local source = e.path
            return Thumbs.Request('shapes', e.id, source)
        end

        P.filterLabel = W.Label(group, 'Find', 0, 0, { color = c.textDim })
        P.filter = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function(text) P.query = text P:Rebuild() end })
        P.grid = Grid.Create(group, {
            cellW = 56, cellH = 74,
            getCount = function() return table.getn(P.shown) end,
            bind = function(cell, index)
                local e = P.shown[index]
                local tex = Thumb(e)
                if tex then cell.thumb:SetTexture(tex) else cell.thumb:SetSolidColor(c.panelAlt) end
                cell.text = e.label
                cell.label:SetColor(e.id == Stamp.S.shape and c.accent or c.text)
                cell.badge:SetText(e.kind == 'image' and 'img' or '')
                cell.mark:SetText('')
            end,
            onSelect = function(index)
                local e = P.shown[index]
                if e then Stamp.S.shape = e.id Save() P:Refresh() end
            end,
            onActivate = function(index)
                local e = P.shown[index]
                if e then
                    Stamp.S.shape = e.id
                    Save()
                    UI.SelectTool('stamp')
                    P:Refresh()
                end
            end,
        })
        P.preview = Bitmap(group)
        P.preview:SetSolidColor(c.panelAlt)
        P.preview:DisableHitTest()
        P.previewName = W.Label(group, '', 0, 0, { color = c.text })
        P.previewKind = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        P.bImport = W.Button(group, 'Import...', 0, 0, Skin.S(80), Skin.S(22), function()
            local files = ed_files_dialog and ed_files_dialog('Import stamp pictures', 'Pictures (*.png;*.tif;*.tiff;*.bmp;*.dds)|*.png;*.tif;*.tiff;*.bmp;*.dds')
            if files and table.getn(files) > 0 then
                local n = Brushes.Import(files)
                pcall(function() UI.Say('imported ' .. n .. ' stamp picture(s)') end)
                P:Rebuild()
            end
        end, { tip = 'Copy greyscale pictures (PNG, TIF, BMP, DDS) into your stamp library.' })
        P.bRescan = W.Button(group, 'Rescan', 0, 0, Skin.S(70), Skin.S(22), function()
            Brushes.Rescan()
            P:Rebuild()
        end, { tip = 'Look for new picture files in the brush folders.' })
        P.bHeight = W.Button(group, 'Height stamp', 0, 0, Skin.S(110), Skin.S(24), function() UI.SelectTool('stamp') end,
            { tip = 'Press the stamp into the ground: the picture is a height map.' })
        P.bPaint = W.Button(group, 'Texture stamp', 0, 0, Skin.S(110), Skin.S(24), function() UI.SelectTool('stamp_paint') end,
            { tip = 'Paint the active layer through the picture (Layers and Texture brush panels).' })

        P.modes = {}
        for _, m in Stamp.MODES do
            local id = m.id
            P.modes[id] = W.Button(group, m.label, 0, 0, Skin.S(60), Skin.S(22), function() Stamp.S.mode = id Save() P:Refresh() end,
                { tip = (id == 'add' and 'The stamp is added to the ground.') or (id == 'subtract' and 'The stamp is cut out of the ground.')
                    or (id == 'max' and 'The ground rises to the stamp where that is higher.') or (id == 'min' and 'The ground sinks to the stamp where that is lower.')
                    or 'The stamp replaces the ground inside it.' })
        end
        P.sliders = {}
        for _, s in SLIDERS do
            local key = s[1]
            table.insert(P.sliders, W.Slider(group, { label = s[2], compact = true, min = s[3], max = s[4], step = s[5], fmt = s[6],
                get = function() return Stamp.S[key] end,
                set = function(v) Stamp.S[key] = v Save() end }))
        end
        P.bRandom = W.Button(group, 'Random turn per dab', 0, 0, Skin.S(140), Skin.S(22), function(self) Stamp.S.randomRotation = self.on Save() end,
            { toggle = true, tip = 'Every dab turns the picture by a random angle.' })
        P.bBase = W.Button(group, 'Base: each dab', 0, 0, Skin.S(120), Skin.S(22), function(self)
            Stamp.S.baseMode = self.on and 'stroke' or 'dab'
            self:SetText(self.on and 'Base: stroke start' or 'Base: each dab')
            Save()
        end, { toggle = true, tip = 'Max, Min and Replace measure from the ground under every dab, or under the first dab of the stroke.' })
        P.note = W.Label(group, 'Radius: Brush panel. Symmetry mirrors the picture too.', 0, 0, { color = c.textDim, size = 'small' })

        function P:Refresh()
            local e = Brushes.Entry(Stamp.S.shape)
            if e then
                local tex = Thumb(e)
                if tex then P.preview:SetTexture(tex) else P.preview:SetSolidColor(c.panelAlt) end
                W.Fit(P.previewName, e.label, (P.w or 240) - Skin.S(100))
                P.previewKind:SetText(e.kind == 'image' and 'picture' or (e.kind == 'round' and 'round disc' or 'procedural'))
            end
            for id, b in P.modes do b:SetOn(Stamp.S.mode == id) end
            P.bRandom:SetOn(Stamp.S.randomRotation)
            P.bBase:SetOn(Stamp.S.baseMode == 'stroke')
            P.bBase:SetText(Stamp.S.baseMode == 'stroke' and 'Base: stroke start' or 'Base: each dab')
            for _, s in P.sliders do s:Refresh() end
            P.grid:Refresh()
        end

        function P:OnResize(w, h)
            P.w = w
            local pad, gap = Skin.S(8), Skin.S(4)
            local bh = Skin.S(22)
            local y = pad
            W.Place(P.filterLabel, group, pad, y + Skin.S(3))
            W.Place(P.filter.frame, group, pad + Skin.S(34), y, w - 2 * pad - Skin.S(34), bh)
            P.filter.Width:Set(w - 2 * pad - Skin.S(34) - 2)
            y = y + bh + gap
            P.grid:SetRect(pad, y, w - 2 * pad, Skin.S(160))
            y = y + Skin.S(160) + gap
            W.Place(P.bImport, group, pad, y, Skin.S(80), bh)
            W.Place(P.bRescan, group, pad + Skin.S(84), y, Skin.S(70), bh)
            y = y + bh + gap + Skin.S(4)
            -- the chosen shape, big
            W.Place(P.preview, group, pad, y, Skin.S(72), Skin.S(72))
            P.preview.Width:Set(Skin.S(72)) P.preview.Height:Set(Skin.S(72))
            W.Place(P.previewName, group, pad + Skin.S(80), y + Skin.S(4))
            W.Place(P.previewKind, group, pad + Skin.S(80), y + Skin.S(24))
            y = y + Skin.S(78)
            local half = math.floor((w - 2 * pad - gap) / 2)
            W.Place(P.bHeight, group, pad, y, half, Skin.S(24))
            P.bHeight.Width:Set(half) W.Center(P.bHeight.label, P.bHeight, 0, 0, half, Skin.S(24))
            W.Place(P.bPaint, group, pad + half + gap, y, half, Skin.S(24))
            P.bPaint.Width:Set(half) W.Center(P.bPaint.label, P.bPaint, 0, 0, half, Skin.S(24))
            y = y + Skin.S(28)
            W.Place(P.note, group, pad, y + Skin.S(2))
            y = y + Skin.S(20)
            -- modes: a row of five (wraps in a narrow panel)
            local mw = Skin.S(60)
            local perRow = math.max(1, math.floor((w - 2 * pad + gap) / (mw + gap)))
            local col, x = 0, pad
            for _, m in Stamp.MODES do
                if col >= perRow then col = 0 x = pad y = y + bh + gap end
                W.Place(P.modes[m.id], group, x, y, mw, bh)
                x = x + mw + gap
                col = col + 1
            end
            y = y + bh + gap + Skin.S(4)
            for _, s in P.sliders do
                s:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(46)
            end
            W.Place(P.bRandom, group, pad, y, Skin.S(140), bh)
            W.Place(P.bBase, group, pad + Skin.S(146), y, Skin.S(120), bh)
            P:Rebuild()
            P:Refresh()
        end

        P.onThumbs = function()
            if live.stamps == P then P:Refresh() end
        end
        Thumbs.Listen('stamps', P.onThumbs)
        function P:Destroy() Thumbs.Unlisten('stamps') end
        P:Rebuild()
        return P
    end,
}
