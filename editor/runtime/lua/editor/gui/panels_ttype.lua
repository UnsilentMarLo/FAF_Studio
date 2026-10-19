-- The Terrain type panel: the entries of /lua/TerrainTypes.lua (colour swatch, name, type code), the one the Terrain type tool paints with, its
-- description / blocking / style, and a switch that shows the grid on the map. See terraintype.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local TT = import('/lua/editor/terraintype.lua')

live = {}

Panels.Register{
    id = 'ttype', title = 'Terrain type',
    create = function(group, host)
        local P = { types = TT.Types() }
        live.ttype = P

        P.list = W.VirtualList(group, {
            extra = true,
            thumb = true,
            rowH = 22,
            getCount = function() return table.getn(P.types) end,
            bind = function(row, index)
                local t = P.types[index]
                local active = (t.code == TT.Active)
                row.thumb:SetSolidColor('FF' .. TT.ColorOf(t.code))
                row.extra:SetText(tostring(t.code))
                local tx = row.bg.Height() + Skin.S(4)
                W.Fit(row.text, t.name .. (t.blocking and '  (blocks)' or ''), math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(44)))
                row.text:SetColor(active and Skin.color.accent or Skin.color.text)
                row.extra:SetColor(Skin.color.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + tx end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local ew = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - ew - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local t = P.types[index]
                if not t then return end
                TT.Active = t.code
                local tool
                for _, x in UI.Tools do if x.id == UI.State.tool then tool = x end end
                if not tool or tool.id ~= 'ttype' then UI.SelectTool('ttype') end
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })

        P.show = W.Button(group, 'Show on map', 0, 0, Skin.S(110), Skin.S(24), function(self)
            TT.Visible = self.on
            TT.Revision = TT.Revision + 1
        end, { toggle = true })
        P.title = W.Label(group, '', 0, 0, { color = Skin.color.text })
        P.info = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.hint = W.Label(group, 'Drag to paint, Shift = default type.', 0, 0, { color = Skin.color.textDim, size = 'small' })

        local function Active()
            for _, t in P.types do
                if t.code == TT.Active then return t end
            end
        end

        function P:Refresh()
            P.list:Refresh()
            P.show:SetOn(TT.Visible)
            local t = Active()
            P.title:SetText(t and (t.name .. '  (code ' .. t.code .. ')') or '')
            local text = ''
            if t then
                text = (t.blocking and 'Blocks movement.  ' or '') .. 'Style: ' .. t.style
            end
            P.info:SetText(text)
        end

        function P:OnResize(w, h)
            local pad = Skin.S(8)
            local foot = Skin.S(100)
            P.list:SetRect(pad, pad, w - 2 * pad, math.max(Skin.S(66), h - 2 * pad - foot))
            local y = h - foot + Skin.S(2)
            W.Place(P.show, group, pad, y, Skin.S(110), Skin.S(24))
            W.Place(P.title, group, pad, y + Skin.S(30))
            W.Place(P.info, group, pad, y + Skin.S(50))
            W.Place(P.hint, group, pad, y + Skin.S(68))
            P:Refresh()
        end
        return P
    end,
}
