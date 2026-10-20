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

        P.slopeLabel = Lbl('Slope shows')
        P.path = Btn('Mobile units', Skin.S(92), Skin.S(24), function() Slope.SetKind('path') P:Refresh() end, { toggle = true })
        P.build = Btn('Structures', Skin.S(92), Skin.S(24), function() Slope.SetKind('build') P:Refresh() end, { toggle = true })

        P.footLabel = Lbl('Footprint')
        P.size = Keep(W.Label(group, '', 0, 0, {}))
        P.footMinus = Btn('-', Skin.S(26), Skin.S(22), function() Slope.SetWindow(Slope.Window - 1) P:Refresh() end)
        P.footPlus = Btn('+', Skin.S(26), Skin.S(22), function() Slope.SetWindow(Slope.Window + 1) P:Refresh() end)

        P.limitLabel = Lbl('Limit')
        P.limit = Keep(W.Label(group, '', 0, 0, {}))
        P.limitButton = Btn('Next', Skin.S(58), Skin.S(22), function() Slope.NextBuildLimit() P:Refresh() end)

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
            y = W.Flow(group, P.layerRow, pad, y + Skin.S(24), iw, Skin.S(24), Skin.S(4)) + Skin.S(12)
            W.Place(P.slopeLabel, group, pad, y + Skin.S(4))
            y = W.Flow(group, { { P.path, Skin.S(92) }, { P.build, Skin.S(92) } }, pad, y + Skin.S(24), iw, Skin.S(24), Skin.S(8)) + Skin.S(12)
            W.Place(P.footLabel, group, pad, y + Skin.S(4))
            W.Place(P.size, group, pad + Skin.S(66), y + Skin.S(4))
            local bx = math.max(pad + Skin.S(124), w - pad - Skin.S(58))
            W.Place(P.footMinus, group, math.min(bx, pad + iw - Skin.S(58)), y, Skin.S(26), Skin.S(22))
            W.Place(P.footPlus, group, math.min(bx, pad + iw - Skin.S(58)) + Skin.S(32), y, Skin.S(26), Skin.S(22))
            y = y + Skin.S(30)
            W.Place(P.limitLabel, group, pad, y + Skin.S(4))
            W.Place(P.limit, group, pad + Skin.S(66), y + Skin.S(4))
            W.Place(P.limitButton, group, (Slope.Kind == 'build') and math.min(math.max(pad + Skin.S(124), w - pad - Skin.S(58)), pad + iw - Skin.S(58)) or -4000, y, Skin.S(58), Skin.S(22))   -- the mobile-unit limit is fixed (0.75)
            y = y + Skin.S(34)
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
            for cat, b in P.layers or {} do b:SetOn(not Filter.Hidden[cat]) end            P.path:SetOn(Slope.Kind == 'path')
            P.build:SetOn(Slope.Kind == 'build')
            P.size:SetText(string.format('%d x %d cells', Slope.Window, Slope.Window))
            P.limit:SetText(string.format('%.2f', Slope.Limit))
            if P.laidOut ~= (hasMesh and 1 or 0) .. tostring(Slope.Kind) then
                P.laidOut = (hasMesh and 1 or 0) .. tostring(Slope.Kind)
                P:Layout(P.w)
            end
            P.legend:SetText(string.format('0          %.2f/2          %.2f          blocked', Slope.Limit, Slope.Limit))
            -- the explanation wraps to the panel's width (text does not clip)
            for _, l in P.noteLabels do l:Destroy() end
            local text
            if Slope.Kind == 'path' then
                text = 'Height change between neighbouring samples, per cell. Land, amphibious and hover units are blocked above 0.75; a footprint of N x N cells checks an N x N window.'
            else
                text = 'Height range over the skirt must stay within the structure\'s MaxGroundVariation: 1.1 for most structures, 1.0 when unspecified; mass extractors and hydrocarbon plants allow 512 (no slope rule).'
            end
            P.noteLabels = W.Paragraph(group, text, pad, P.noteY, math.max(Skin.S(80), P.w - 2 * pad), { color = Skin.color.textDim, size = 'small' })
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
