-- The Symmetry panel: one mode for every tool that places something (height and texture brushes, markers, areas), and the point the copies are
-- made about. See symmetry.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Sym = import('/lua/editor/symmetry.lua')

live = {}

Panels.Register{
    id = 'symmetry', title = 'Symmetry',
    create = function(group, host)
        local P = { buttons = {} }
        live.symmetry = P

        for _, m in Sym.Modes do
            local mode = m.id
            local b = W.Button(group, m.label, 0, 0, Skin.S(150), Skin.S(24), function()
                Sym.Mode = mode
                P:Refresh()
            end, { toggle = true })
            table.insert(P.buttons, { id = mode, b = b })
        end

        local function MapMax()
            return ((ed_terrain_info and ed_terrain_info()) or 256) - 1
        end
        P.cx = W.Slider(group, { label = 'Centre X', min = 0, max = 1024, step = 1, fmt = '%d',
            get = function() local x = Sym.Centre() return x end,
            set = function(v) Sym.CenterX = v end })
        P.cz = W.Slider(group, { label = 'Centre Z', min = 0, max = 1024, step = 1, fmt = '%d',
            get = function() local _, z = Sym.Centre() return z end,
            set = function(v) Sym.CenterZ = v end })
        P.reset = W.Button(group, 'Centre of the map', 0, 0, Skin.S(150), Skin.S(24), function()
            Sym.CenterX, Sym.CenterZ = false, false
            P:Refresh()
        end)
        P.armyMap = W.Button(group, 'Units to the mirrored army', 0, 0, Skin.S(150), Skin.S(24), function(self)
            local H = import('/lua/editor/mirrorhalf.lua')
            H.ArmyMode = (H.ArmyMode == 'map') and 'keep' or 'map'
            P:Refresh()
        end, { toggle = true })
        P.half = W.Button(group, 'Mirror the whole half...', 0, 0, Skin.S(150), Skin.S(24), function()
            import('/lua/editor/gui/dialogs_mirror.lua').Open()
        end)
        P.note = W.Label(group, 'Applies to brushes, texture brush, markers, areas, props, decals and units.', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            for _, e in P.buttons do e.b:SetOn(Sym.Mode == e.id) end
            P.cx:Refresh()
            P.cz:Refresh()
            P.armyMap:SetOn(import('/lua/editor/mirrorhalf.lua').ArmyMode == 'map')
        end

        function P:OnResize(w, h)
            local pad = Skin.S(10)
            local y = pad
            local cols = (w >= Skin.S(340)) and 2 or 1
            local bw = math.floor((w - 2 * pad - (cols - 1) * Skin.S(6)) / cols)
            local n = 0
            for _, e in P.buttons do
                local col = math.mod(n, cols)
                local row = math.floor(n / cols)
                W.Place(e.b, group, pad + col * (bw + Skin.S(6)), pad + row * Skin.S(28), bw, Skin.S(24))
                n = n + 1
            end
            y = pad + math.ceil(n / cols) * Skin.S(28) + Skin.S(6)
            P.cx:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(52)
            P.cz:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(52)
            W.Place(P.reset, group, pad, y, Skin.S(150), Skin.S(24))
            W.Place(P.armyMap, group, pad, y + Skin.S(30), Skin.S(150), Skin.S(24))
            W.Place(P.half, group, pad + Skin.S(156), y + Skin.S(30), Skin.S(150), Skin.S(24))
            W.Place(P.note, group, pad, y + Skin.S(62))
            P:Refresh()
        end
        return P
    end,
}
