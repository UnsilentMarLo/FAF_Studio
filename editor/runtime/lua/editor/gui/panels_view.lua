-- The View panel: overlays that explain the map to the mapper. The build grid and the slope view (the engine's own ratings, slope.lua).

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Grid = import('/lua/editor/grid.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Slope = import('/lua/editor/slope.lua')
local MeshView = import('/lua/editor/meshview.lua')

live = {}

function Refresh()
    for _, inst in live do
        if inst.Refresh then pcall(inst.Refresh, inst) end
    end
end

-- the legend uses the same stops as the native gradient (SlopeColor in EdOverlay.cpp), opaque
local function Gradient(t)
    if t > 1 then return 'ffc018d8' end
    local r, g, b
    if t < 0.5 then
        local f = t / 0.5
        r, g, b = 60 + 180 * f, 200 + 20 * f, 70 - 30 * f
    else
        local f = (t - 0.5) / 0.5
        r, g, b = 240, 220 - 170 * f, 40
    end
    return string.format('ff%02x%02x%02x', math.floor(r), math.floor(g), math.floor(b))
end

Panels.Register{
    id = 'view', title = 'View', rebuildOnResize = true,
    create = function(group, host)
        local P = { items = {} }
        live.view = P

        local function Keep(c) table.insert(P.items, c) return c end
        local pad = Skin.S(10)
        local function Lbl(text) return Keep(W.Label(group, text, 0, 0, { color = Skin.color.textDim })) end
        local function Btn(text, w, h, fn, opts) return Keep(W.Button(group, text, 0, 0, w, h, fn, opts)) end

        -- a mesh terrain map (TerrainSystem = 'mesh'): what the ground shows (the buttons are visible while the map has a mesh)
        P.meshLabel = Lbl('Ground shows')
        P.meshButtons = {}
        P.meshRow = {}
        for _, def in { { 1, 'Mesh', 56 }, { 0, 'Height field', 84 }, { 2, 'Both', 50 } } do
            local mode = def[1]
            P.meshButtons[mode] = Btn(def[2], Skin.S(def[3]), Skin.S(24), function() MeshView.SetMode(mode) P:Refresh() end, { toggle = true })
            table.insert(P.meshRow, { P.meshButtons[mode], Skin.S(def[3]) })
        end

        P.grid = Btn('Build grid', Skin.S(92), Skin.S(24), function() Commands.Run('view.grid') end, { toggle = true })
        P.slope = Btn('Slope', Skin.S(92), Skin.S(24), function() Commands.Run('view.slope') end, { toggle = true })

        -- marker layers: which categories of markers are shown in the world (markerfilter.lua; display only)
        local Filter = import('/lua/editor/markerfilter.lua')
        P.markersLabel = Lbl('Show markers')
        P.layers = {}
        P.layerRow = {}
        for i, loopCat in Filter.CATEGORIES do
            local cat = loopCat      -- closures share the loop variable (nil after the loop): the button needs its own copy
            local b = Btn(cat, Skin.S(96), Skin.S(24), function()
                Filter.Toggle(cat)
                -- 'Paths' covers both kinds: the AI path node markers and the terrain paths of the Paths panel (their splines, points and handles)
                if cat == 'Paths' then
                    pcall(function()
                        import('/lua/editor/pathtool.lua').Show = not Filter.Hidden.Paths
                        import('/lua/editor/paths.lua').Touch()
                    end)
                end
            end, { toggle = true })
            P.layers[cat] = b
            table.insert(P.layerRow, { b, Skin.S(96) })
        end

        -- chains: a hidden layer also hides the chain lines of its markers (chains.lua Draw); this shows only the chain of the selected marker
        P.chainsOnly = Btn('Only the selected chain', Skin.S(170), Skin.S(24), function(self)
            import('/lua/editor/chains.lua').SetOnlySelected(self.on)
        end, { toggle = true })

        P.slopeLabel = Lbl('Slope shows')
        P.path = Btn('Mobile units', Skin.S(92), Skin.S(24), function() Slope.SetKind('path') P:Refresh() end, { toggle = true })
        P.build = Btn('Structures', Skin.S(92), Skin.S(24), function() Slope.SetKind('build') P:Refresh() end, { toggle = true })

        -- structures: which rule the game checks the ground with (see Slope.Rule)
        P.ruleLabel = Lbl('Rule')
        P.ruleRing = Btn('Buildings (ring)', Skin.S(120), Skin.S(24), function() Slope.SetRule('ring') P:Refresh() end, { toggle = true })
        P.ruleArea = Btn('Area (extractors, walls)', Skin.S(168), Skin.S(24), function() Slope.SetRule('area') P:Refresh() end, { toggle = true })

        -- the sizes and limits are discrete sliders over the values real blueprints have (Slope.FOOTPRINT_STOPS / SKIRT_STOPS / BUILD_LIMITS)
        P.foot = W.Slider(group, { label = 'Footprint (cells)', stops = Slope.FOOTPRINT_STOPS, fmt = '%d',
            get = function() return Slope.Footprint end,
            set = function(v) Slope.SetWindow(v) P:Refresh() end })
        P.skirt = W.Slider(group, { label = 'Skirt size (cells)', stops = Slope.SKIRT_STOPS, fmt = '%d',
            get = function() return Slope.Skirt end,
            set = function(v) Slope.SetWindow(v) P:Refresh() end })
        P.limitSlider = W.Slider(group, { label = 'Limit', stops = Slope.BUILD_LIMITS, fmt = '%.1f',
            get = function() return Slope.BuildLimit[Slope.Rule] or 1.0 end,
            set = function(v) Slope.SetLimit(v) P:Refresh() end })

        -- legend: gradient strip, 0 to the limit, then "blocked"
        local steps = 16
        P.legendSquares = {}
        for i = 0, steps - 1 do
            local sq = Keep(Bitmap(group))
            sq:SetSolidColor(Gradient((i + 0.5) / steps))
            sq.Depth:Set(function() return group.Depth() + 6 end)
            table.insert(P.legendSquares, sq)
        end
        P.blocked = Keep(Bitmap(group))
        P.blocked:SetSolidColor(Gradient(2))
        P.blocked.Depth:Set(function() return group.Depth() + 6 end)
        P.legend = Keep(W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' }))
        P.noteLabels = {}
        P.hintLabels = {}
        P.w = Skin.S(220)
        P.noteY = 0

        --- Puts every control where the panel's width allows: button rows wrap, the legend scales to the width.
        function P:Layout(w)
            local iw = math.max(Skin.S(80), w - 2 * pad)
            local y = pad
            local hasMesh = MeshView.Active()
            if hasMesh then
                W.Place(P.meshLabel, group, pad, y + Skin.S(4))
                y = W.Flow(group, P.meshRow, pad, y + Skin.S(24), iw, Skin.S(24), Skin.S(6)) + Skin.S(12)
            else
                W.Place(P.meshLabel, group, -4000, 0)
                for _, it in P.meshRow do W.Place(it[1], group, -4000, 0, it[2], Skin.S(24)) end
            end
            y = W.Flow(group, { { P.grid, Skin.S(92) }, { P.slope, Skin.S(92) } }, pad, y, iw, Skin.S(24), Skin.S(8)) + Skin.S(12)
            W.Place(P.markersLabel, group, pad, y + Skin.S(4))
            y = W.Flow(group, P.layerRow, pad, y + Skin.S(24), iw, Skin.S(24), Skin.S(4)) + Skin.S(6)
            y = W.Flow(group, { { P.chainsOnly, Skin.S(170) } }, pad, y, iw, Skin.S(24), Skin.S(4)) + Skin.S(12)
            W.Place(P.slopeLabel, group, pad, y + Skin.S(4))
            y = W.Flow(group, { { P.path, Skin.S(92) }, { P.build, Skin.S(92) } }, pad, y + Skin.S(24), iw, Skin.S(24), Skin.S(8)) + Skin.S(12)
            if Slope.Kind == 'build' then
                W.Place(P.ruleLabel, group, pad, y + Skin.S(4))
                y = W.Flow(group, { { P.ruleRing, Skin.S(120) }, { P.ruleArea, Skin.S(168) } }, pad, y + Skin.S(24), iw, Skin.S(24), Skin.S(6)) + Skin.S(8)
                P.skirt:Place(pad, y, iw)
                y = y + Skin.S(50)
                P.limitSlider:Place(pad, y, iw)
                y = y + Skin.S(50)
                P.foot:Place(-4000, y, iw)       -- (the sliders and buttons of the other kind are parked off the panel)
            else
                W.Place(P.ruleLabel, group, -4000, y)
                W.Place(P.ruleRing, group, -4000, y, Skin.S(120), Skin.S(24))
                W.Place(P.ruleArea, group, -4000, y, Skin.S(168), Skin.S(24))
                P.foot:Place(pad, y, iw)
                y = y + Skin.S(50)
                P.skirt:Place(-4000, y, iw)
                P.limitSlider:Place(-4000, y, iw)
            end
            y = y + Skin.S(4)
            local steps = table.getn(P.legendSquares)
            local sw = math.max(Skin.S(3), math.min(Skin.S(9), math.floor(iw / (steps + 3))))
            for i, sq in P.legendSquares do W.Place(sq, group, pad + (i - 1) * sw, y, sw, Skin.S(12)) end
            W.Place(P.blocked, group, pad + (steps + 1) * sw, y, sw * 2, Skin.S(12))
            y = y + Skin.S(16)
            W.Place(P.legend, group, pad, y)
            y = y + Skin.S(22)
            P.noteY = y
            P.w = w
        end

        function P:Refresh()
            local hasMesh = MeshView.Active()
            P.meshLabel:SetHidden(not hasMesh)
            for mode, b in P.meshButtons do
                b:SetHidden(not hasMesh)
                b:SetOn(hasMesh and MeshView.Mode() == mode)
            end
            P.grid:SetOn(Grid.Visible)
            P.slope:SetOn(Slope.Visible)
            for cat, b in P.layers or {} do b:SetOn(not Filter.Hidden[cat]) end
            P.chainsOnly:SetOn(import('/lua/editor/chains.lua').OnlySelected)
            P.path:SetOn(Slope.Kind == 'path')
            P.build:SetOn(Slope.Kind == 'build')
            P.ruleRing:SetOn(Slope.Rule == 'ring')
            P.ruleArea:SetOn(Slope.Rule == 'area')
            if P.laidOut ~= (hasMesh and 1 or 0) .. tostring(Slope.Kind) then
                P.laidOut = (hasMesh and 1 or 0) .. tostring(Slope.Kind)
                P:Layout(P.w)
            end
            P.foot:Refresh()
            P.skirt:Refresh()
            P.limitSlider:Refresh()
            P.legend:SetText(string.format('0          %.2f/2          %.2f          blocked', Slope.Limit, Slope.Limit))
            -- the explanation wraps to the panel's width (text does not clip). The labels are made again only when the text or the width changed: they were destroyed and
            -- created anew on every tick (four times a second) while the panel was open.
            local text, hint, note
            if Slope.Kind == 'path' then
                text = 'Height change between neighbouring samples, per cell. Land, amphibious and hover units are blocked above 0.75; a footprint of N x N cells checks an N x N window.'
            elseif Slope.Rule == 'ring' then
                text = 'Buildings are levelled flat when they go up, so the game only looks at the ring of ground one cell outside the skirt, not at the skirt itself. The ring may differ from the height the skirt is levelled to (the last ring sample, rounded up to a whole unit) by at most the structure\'s MaxGroundVariation. The colours show that difference for a skirt of the size above, whose top-left corner is the cell.'
                if Slope.RingMissing() then
                    text = 'This editor build has no ring rule yet, so the area rule is shown. ' .. text
                end
            else
                text = 'Structures that are not levelled (extractors, walls, point defence, radar, naval factories): the game takes the highest minus the lowest ground over the whole skirt and compares it with the structure\'s MaxGroundVariation. The colours show that range for a skirt of the size above, whose top-left corner is the cell.'
            end
            if Slope.Kind == 'build' then
                hint = string.format('Skirt %d x %d cells: %s', Slope.Skirt, Slope.Skirt, Slope.SKIRT_HINTS[Slope.Skirt] or '')
                if Slope.Rule == 'ring' and Slope.RING_LIMIT_HINTS[Slope.Skirt] then
                    hint = hint .. ' Limit usually ' .. Slope.RING_LIMIT_HINTS[Slope.Skirt] .. '.'
                end
                note = 'Walls (50) and extractors (512) ignore slope.'
            end
            local noteKey = tostring(text) .. '|' .. tostring(hint) .. '|' .. tostring(P.w) .. '|' .. tostring(P.noteY)
            if noteKey ~= P.noteKey then
                P.noteKey = noteKey
                for _, l in P.noteLabels do l:Destroy() end
                for _, l in P.hintLabels do l:Destroy() end
                local opts = { color = Skin.color.textDim, size = 'small' }
                local pw = math.max(Skin.S(80), P.w - 2 * pad)
                local y = P.noteY
                P.hintLabels = {}
                if hint then
                    local labels
                    labels, y = W.Paragraph(group, hint, pad, y, pw, { color = Skin.color.text, size = 'small' })
                    P.hintLabels = labels
                    y = y + Skin.S(6)
                end
                local labels
                labels, y = W.Paragraph(group, text, pad, y, pw, opts)
                P.noteLabels = labels
                if note then
                    y = y + Skin.S(6)
                    local more = W.Paragraph(group, note, pad, y, pw, opts)
                    for _, l in more do table.insert(P.noteLabels, l) end
                end
            end
        end
        function P:OnResize(w, h)
            P.w, P.h = w, h
            P:Layout(w)
            P.laidOut = false
            P:Refresh()
        end
        P:Refresh()
        return P
    end,
}

Commands.Register{ id = 'view.slope', title = 'View: slope', keys = 'H', run = function()
    Slope.Visible = not Slope.Visible
    local shell = import('/lua/editor/gui/shell.lua')
    if shell.S and shell.S.slopeButton then shell.S.slopeButton:SetOn(Slope.Visible) end
end }

Commands.Register{ id = 'view.mesh', title = 'View: mesh terrain (mesh maps)', run = function() MeshView.SetMode(1) end }
Commands.Register{ id = 'view.heightfield', title = 'View: height field only (mesh maps)', run = function() MeshView.SetMode(0) end }
Commands.Register{ id = 'view.meshboth', title = 'View: mesh and height field together (mesh maps)', run = function() MeshView.SetMode(2) end }
