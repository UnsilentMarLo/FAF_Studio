-- The Props panel: a filter field and the list of prop blueprints (group and name). The brush settings (radius, density, spacing, scale range, random heading,
-- eraser filter) are in the Properties panel while a prop tool is active. Tools: Prop brush / Erase props / Select props (Objects workspace). See props.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Fav = import('/lua/editor/favourites.lua')
local Props = import('/lua/editor/props.lua')

live = {}

Panels.Register{
    id = 'props', title = 'Props',
    create = function(group, host)
        local P = { shown = {} }
        live.props = P

        local function Rebuild()
            local filter = string.lower(P.filter and P.filter:GetText() or '')
            P.shown = {}
            for _, e in Props.Catalog() do
                if filter == '' or string.find(string.lower(e.name), filter, 1, true) or string.find(e.group, filter, 1, true) then
                    table.insert(P.shown, e)
                end
            end
            P.shown = Fav.Arrange('props', P.shown, function(e) return e.path end, P.onlyFav)
            if P.list then P.list:Refresh() end
        end

        P.filter = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function() Rebuild() end })
        P.filterLabel = W.Label(group, 'Find', 0, 0, { color = Skin.color.textDim })
        -- favourites: Star toggles the active entry, Starred only hides the rest (favourites.lua)
        P.star = W.Button(group, 'Star', 0, 0, Skin.S(44), Skin.S(22), function()
            local key = Props.Active
            if key then Fav.Toggle('props', key) Rebuild() P:Refresh() end
        end)
        P.favOnly = W.Button(group, 'Starred only', 0, 0, Skin.S(96), Skin.S(22), function(self) P.onlyFav = self.on Rebuild() end, { toggle = true })

        P.list = W.VirtualList(group, {
            extra = true,
            rowH = 20,
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index)
                local e = P.shown[index]
                local active = (e.path == Props.Active)
                row.extra:SetText(e.group)
                local ew = math.min(row.extra.Width(), Skin.S(80))
                W.Fit(row.text, (Fav.Is('props', e.path) and '* ' or '') .. e.name, math.max(Skin.S(40), row.bg.Width() - ew - Skin.S(24)))
                row.text:SetColor(active and Skin.color.accent or Skin.color.text)
                row.extra:SetColor(Skin.color.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local e = P.shown[index]
                if not e then return end
                Props.Active = e.path
                local tool
                for _, t in UI.Tools do if t.id == UI.State.tool then tool = t end end
                if not tool or (tool.id ~= 'prop' and tool.id ~= 'prop_erase') then UI.SelectTool('prop') end
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })
        P.name = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.count = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.list:Refresh()
            local n = Props.Active and string.gsub(Props.Active, '^.*/', '') or 'none selected'
            P.name:SetText('Placing: ' .. tostring(n))
            P.count:SetText(table.getn(P.shown) .. ' of ' .. table.getn(Props.Catalog()))
        end

        function P:OnResize(w, h)
            local pad = Skin.S(8)
            local y = pad
            W.Place(P.filterLabel, group, pad, y + Skin.S(3))
            W.Place(P.filter.frame, group, pad + Skin.S(34), y, w - 2 * pad - Skin.S(34), Skin.S(22))
            P.filter.Width:Set(w - 2 * pad - Skin.S(34) - 2)
            y = y + Skin.S(28)
            W.Place(P.star, group, pad, y, Skin.S(44), Skin.S(22))
            W.Place(P.favOnly, group, pad + Skin.S(50), y, Skin.S(96), Skin.S(22))
            y = y + Skin.S(28)
            local foot = Skin.S(40)
            P.list:SetRect(pad, y, w - 2 * pad, math.max(Skin.S(60), h - y - foot - pad))
            W.Place(P.name, group, pad, h - foot + Skin.S(2))
            W.Place(P.count, group, pad, h - foot + Skin.S(20))
            P:Refresh()
        end
        Rebuild()
        return P
    end,
}
