-- The Statistics panel: what is in the map and how mass points, hydrocarbon points and reclaim are shared between the start positions (mapstats.lua). Read-only; Refresh
-- recounts (props and decals are not watched, so it is a button).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Stats = import('/lua/editor/mapstats.lua')

live = {}

Panels.Register{
    id = 'stats', title = 'Statistics',
    stack = { { workspace = 'Objects', with = 'view' }, { workspace = 'Mission', with = 'view' }, { workspace = 'Review', with = 'view' } },
    create = function(group, host)
        local P = { rows = {} }
        live.stats = P
        local c = Skin.color

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(P.rows) end,
            bind = function(row, index)
                local r = P.rows[index]
                if not r then return end
                W.Fit(row.text, r.text, math.max(Skin.S(30), math.floor(row.bg.Width() * 0.5)))
                row.text:SetColor(r.header and c.accent or c.text)
                row.extra:SetText(r.value or '')
                row.extra:SetColor(c.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            bgColor = c.panel,
        })
        P.refresh = W.Button(group, 'Refresh', 0, 0, Skin.S(70), Skin.S(22), function() P:Refresh() end)

        function P:Refresh()
            local ok, stats = pcall(Stats.Compute)
            P.rows = ok and Stats.Rows(stats) or { { text = 'could not count: ' .. tostring(stats), header = true } }
            P.list:Refresh()
        end

        function P:OnResize(w, h)
            local pad = Skin.S(8)
            W.Place(P.refresh, group, pad, pad, Skin.S(70), Skin.S(22))
            P.list:SetRect(pad, pad + Skin.S(26), w - 2 * pad, math.max(Skin.S(44), h - Skin.S(26) - 2 * pad))
            P:Refresh()
        end
        return P
    end,
}

-- no automatic refresh (counting thousands of props is not done every quarter second)
NoAutoRefresh = true
