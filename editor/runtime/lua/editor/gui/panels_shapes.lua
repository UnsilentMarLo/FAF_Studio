-- The Shapes panel: the mask the height and texture brushes use instead of the round falloff (brushes.lua): procedural shapes and the image masks of
-- the brush folders, the angle of the mask and a random turn per stroke. The world preview of the brush shows the shape.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Brushes = import('/lua/editor/brushes.lua')

live = {}

Panels.Register{
    id = 'shapes', title = 'Shapes',
    create = function(group, host)
        local P = { list = nil, shapes = Brushes.List() }
        live.shapes = P

        P.listbox = W.VirtualList(group, {
            extra = true,
            rowH = 20,
            getCount = function() return table.getn(P.shapes) end,
            bind = function(row, index)
                local e = P.shapes[index]
                row.extra:SetText(e.kind == 'image' and 'image' or '')
                W.Fit(row.text, e.label, math.max(Skin.S(40), row.bg.Width() - Skin.S(60)))
                row.text:SetColor(e.id == Brushes.Active and Skin.color.accent or Skin.color.text)
                row.extra:SetColor(Skin.color.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local e = P.shapes[index]
                if e then
                    Brushes.Active = e.id
                    P:Refresh()
                end
            end,
            bgColor = Skin.color.panel,
        })
        P.angle = W.Slider(group, { label = 'Angle', min = 0, max = 359, step = 1, fmt = '%d', compact = true,
            get = function() return Brushes.Angle end, set = function(v) Brushes.Angle = v end })
        P.random = W.Button(group, 'Random turn', 0, 0, Skin.S(100), Skin.S(24), function(self) Brushes.RandomAngle = self.on end, { toggle = true })
        P.rescan = W.Button(group, 'Rescan', 0, 0, Skin.S(70), Skin.S(24), function()
            Brushes.Rescan()
            P.shapes = Brushes.List()
            P:Refresh()
        end)
        P.note = W.Label(group, 'Image masks: greyscale PNG in /brushes', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.listbox:Refresh()
            P.angle:Refresh()
            P.random:SetOn(Brushes.RandomAngle)
        end

        function P:OnResize(w, h)
            local pad = Skin.S(8)
            local foot = Skin.S(110)
            P.listbox:SetRect(pad, pad, w - 2 * pad, math.max(Skin.S(60), h - 2 * pad - foot))
            local y = h - foot + Skin.S(2)
            P.angle:Place(pad, y, w - 2 * pad)
            W.Place(P.random, group, pad, y + Skin.S(52), Skin.S(100), Skin.S(24))
            W.Place(P.rescan, group, pad + Skin.S(108), y + Skin.S(52), Skin.S(70), Skin.S(24))
            W.Place(P.note, group, pad, y + Skin.S(82))
            P:Refresh()
        end
        return P
    end,
}
