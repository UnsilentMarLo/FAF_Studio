-- The Decals panel: filter field and list of decal albedo textures (thumbnail, group, name). The brush settings (radius, size, variance, density, spacing, view
-- distance, random heading, matching normals, eraser filter) are in the Properties panel while a decal tool is active. Tools: Decal brush / Erase decals
-- (Objects workspace). See decals.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Fav = import('/lua/editor/favourites.lua')
local Decals = import('/lua/editor/decals.lua')

live = {}

Panels.Register{
    id = 'decals', title = 'Decals',
    create = function(group, host)
        local P = { shown = {} }
        live.decals = P

        local function Rebuild()
            local filter = string.lower(P.filter and P.filter:GetText() or '')
            P.shown = {}
            for _, e in Decals.Catalog() do
                if filter == '' or string.find(string.lower(e.name), filter, 1, true) or string.find(e.group, filter, 1, true) then
                    table.insert(P.shown, e)
                end
            end
            P.shown = Fav.Arrange('decals', P.shown, function(e) return e.path end, P.onlyFav)
            if P.list then P.list:Refresh() end
        end

        P.filter = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function() Rebuild() end })
        P.filterLabel = W.Label(group, 'Find', 0, 0, { color = Skin.color.textDim })
        -- favourites: Star toggles the active entry, Starred only hides the rest (favourites.lua)
        P.star = W.Button(group, 'Star', 0, 0, Skin.S(44), Skin.S(22), function()
            local key = Decals.Active
            if key then Fav.Toggle('decals', key) Rebuild() P:Refresh() end
        end)
        P.favOnly = W.Button(group, 'Starred only', 0, 0, Skin.S(96), Skin.S(22), function(self) P.onlyFav = self.on Rebuild() end, { toggle = true })

        P.list = W.VirtualList(group, {
            extra = true,
            thumb = true,
            rowH = 26,
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index)
                local e = P.shown[index]
                local active = (e.path == Decals.Active)
                row.thumb:SetTexture(e.path)
                row.extra:SetText(e.group)
                local tx = row.bg.Height() + Skin.S(4)
                local ew = math.min(row.extra.Width(), Skin.S(80))
                W.Fit(row.text, (Fav.Is('decals', e.path) and '* ' or '') .. e.name, math.max(Skin.S(40), row.bg.Width() - tx - ew - Skin.S(20)))
                row.text:SetColor(active and Skin.color.accent or Skin.color.text)
                row.extra:SetColor(Skin.color.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + tx end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local e = P.shown[index]
                if not e then return end
                Decals.Active = e.path
                local tool
                for _, t in UI.Tools do if t.id == UI.State.tool then tool = t end end
                if not tool or (tool.id ~= 'decal' and tool.id ~= 'decal_erase' and tool.id ~= 'decal_place') then UI.SelectTool('decal') end
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })
        P.name = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.count = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.list:Refresh()
            local n = Decals.Active and string.gsub(Decals.Active, '^.*/', '') or 'none selected'
            P.name:SetText('Placing: ' .. tostring(n))
            P.count:SetText(table.getn(P.shown) .. ' of ' .. table.getn(Decals.Catalog()))
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
