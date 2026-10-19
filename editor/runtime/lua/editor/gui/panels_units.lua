-- The Units panel: filter field, the list of unit blueprints (id, description, faction) and the army the Unit tool places for (a button that steps through the armies of
-- the map). Tools: Unit tool / Select units (Objects workspace). See units.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Fav = import('/lua/editor/favourites.lua')
local Units = import('/lua/editor/units.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Cat = import('/lua/editor/assetcat.lua')

live = {}

Panels.Register{
    id = 'units', title = 'Units',
    create = function(group, host)
        local P = { shown = {}, f = {} }
        live.units = P

        -- the categories of a unit (faction, tech, layer, type: assetcat.lua), by id
        local tagsById = {}
        for _, e in Cat.Entries('units') do tagsById[e.key] = e.tags end

        local function Rebuild()
            local filter = string.lower(P.filter and P.filter:GetText() or '')
            P.shown = {}
            for _, e in Units.Catalog() do
                local pass = true
                for facet, value in P.f do
                    local tags = tagsById[e.id]
                    if not tags or tags[facet] ~= value then pass = false break end
                end
                if pass and (filter == '' or string.find(string.lower(e.id), filter, 1, true) or string.find(string.lower(e.desc), filter, 1, true)
                   or string.find(string.lower(e.name), filter, 1, true) or string.find(string.lower(e.faction), filter, 1, true)) then
                    table.insert(P.shown, e)
                end
            end
            P.shown = Fav.Arrange('units', P.shown, function(e) return e.id end, P.onlyFav)
            if P.list then P.list:Refresh() end
        end

        P.filter = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function() Rebuild() end })
        P.filterLabel = W.Label(group, 'Find', 0, 0, { color = Skin.color.textDim })
        -- favourites: Star toggles the active entry, Starred only hides the rest (favourites.lua)
        P.star = W.Button(group, 'Star', 0, 0, Skin.S(44), Skin.S(22), function()
            local key = Units.Active
            if key then Fav.Toggle('units', key) Rebuild() P:Refresh() end
        end)
        -- categories: a button per facet opens a menu of its values (the list is long: narrow it by faction, tech level, type) and Browse... opens the full browser
        P.fb = {}
        for i, def in { { 'faction', 'Faction' }, { 'tech', 'Tech' }, { 'type', 'Type' } } do
            local facet, label = def[1], def[2]
            P.fb[i] = W.Button(group, label, 0, 0, Skin.S(i == 2 and 66 or 86), Skin.S(22), function(self)
                local items = { { title = 'All ' .. string.lower(label) .. 's', checked = (P.f[facet] == nil), run = function() P.f[facet] = nil Rebuild() P:Refresh() end } }
                for _, v in Cat.Values('units', facet) do
                    local value = v
                    table.insert(items, { title = value, checked = (P.f[facet] == value), run = function() P.f[facet] = value Rebuild() P:Refresh() end })
                end
                Menu.Show(GetFrame(0), self.Left(), self.Bottom(), items)
            end, { tip = 'Narrow the list to one ' .. string.lower(label) .. ' (click again to choose another or to show all).' })
        end
        P.browse = W.Button(group, 'Browse...', 0, 0, Skin.S(86), Skin.S(22), function()
            import('/lua/editor/gui/browser.lua').OpenUnits{ title = 'Choose a unit to place', current = Units.Active, done = function(id)
                Units.Active = id
                if UI.State.tool ~= 'unit' then UI.SelectTool('unit') end
                P:Refresh()
            end }
        end, { tip = 'Open the unit browser: categories, pictures and search in one window.' })
        P.favOnly = W.Button(group, 'Starred only', 0, 0, Skin.S(96), Skin.S(22), function(self) P.onlyFav = self.on Rebuild() end, { toggle = true })

        P.list = W.VirtualList(group, {
            extra = true,
            thumb = true,           -- the unit's icon (the game's /textures/ui/common/icons/units/<id>_icon.dds)
            rowH = 26,
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index)
                local e = P.shown[index]
                local active = (e.id == Units.Active)
                row.extra:SetText(e.faction)
                row.thumb:SetTexture('/textures/ui/common/icons/units/' .. string.upper(e.id) .. '_icon.dds')
                local tx = row.bg.Height() + Skin.S(4)
                local ew = math.min(row.extra.Width(), Skin.S(60))
                local label = (Fav.Is('units', e.id) and '* ' or '') .. e.id .. '  ' .. (e.desc ~= '' and e.desc or e.name)
                W.Fit(row.text, label, math.max(Skin.S(40), row.bg.Width() - tx - ew - Skin.S(20)))
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
                Units.Active = e.id
                local tool
                for _, t in UI.Tools do if t.id == UI.State.tool then tool = t end end
                if not tool or tool.id ~= 'unit' then UI.SelectTool('unit') end
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })
        P.army = W.Button(group, '', 0, 0, Skin.S(150), Skin.S(24), function()
            local names = Units.Armies()
            local next = names[1]
            for i, n in names do
                if n == Units.ArmyName then next = names[i + 1] or names[1] end
            end
            Units.ArmyName = next or Units.ArmyName
            P:Refresh()
        end, { tip = 'The army the Unit tool places for. Click to step to the next army of the map.' })
        P.group = W.Button(group, '', 0, 0, Skin.S(150), Skin.S(24), function()
            import('/lua/editor/gui/dialogs_mission.lua').PickGroup(Units.ArmyName, function(name) Units.Group = name P:Refresh() end)
        end, { tip = 'The unit group the Unit tool puts units into: INITIAL units are there when the map starts, other groups are for the mission script.' })
        P.move = W.Button(group, 'Selection to group', 0, 0, Skin.S(140), Skin.S(24), function()
            if table.getn(Units.Selection) == 0 then pcall(function() UI.Say('select units first (Select units tool)') end) return end
            Units.SetGroup(Units.Group)
            P:Refresh()
        end)
        P.name = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.list:Refresh()
            for i, def in { { 'faction', 'Faction' }, { 'tech', 'Tech' }, { 'type', 'Type' } } do
                P.fb[i]:SetText(P.f[def[1]] and tostring(P.f[def[1]]) or def[2])
                P.fb[i]:SetOn(P.f[def[1]] ~= nil)
            end
            P.army:SetText('Army: ' .. tostring(Units.ArmyName))
            P.group:SetText('Group: ' .. tostring(Units.Group))
            W.Fit(P.name, 'Placing: ' .. tostring(Units.Active or 'none selected') .. '  (' .. table.getn(P.shown) .. ' units listed)', (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local y = pad
            W.Place(P.filterLabel, group, pad, y + Skin.S(3))
            W.Place(P.filter.frame, group, pad + Skin.S(34), y, w - 2 * pad - Skin.S(34), Skin.S(22))
            P.filter.Width:Set(w - 2 * pad - Skin.S(34) - 2)
            y = y + Skin.S(28)
            y = W.Flow(group, { { P.fb[1], Skin.S(86) }, { P.fb[2], Skin.S(66) }, { P.fb[3], Skin.S(86) }, { P.browse, Skin.S(86) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(6)
            y = W.Flow(group, { { P.star, Skin.S(44) }, { P.favOnly, Skin.S(96) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(6)) + Skin.S(6)
            -- army and group side by side when the panel is wide enough, else one button per row (a docked panel is ~200 px wide)
            local bw = w - 2 * pad
            local wide = bw >= Skin.S(306)
            local foot = wide and Skin.S(84) or Skin.S(112)
            local listH = math.max(Skin.S(60), h - y - foot - pad)
            P.list:SetRect(pad, y, w - 2 * pad, listH)
            local fy = math.max(h - foot, y + listH + pad)      -- a short panel scrolls instead of laying the controls over each other
            if wide then
                W.Place(P.army, group, pad, fy, Skin.S(150), Skin.S(24))
                W.Place(P.group, group, pad + Skin.S(156), fy, Skin.S(150), Skin.S(24))
                W.Place(P.move, group, pad, fy + Skin.S(28), Skin.S(140), Skin.S(24))
                W.Place(P.name, group, pad, fy + Skin.S(56))
            else
                for i, b in { P.army, P.group, P.move } do
                    W.Place(b, group, pad, fy + (i - 1) * Skin.S(28), bw, Skin.S(24))
                    b.Width:Set(bw)
                    W.Center(b.label, b, 0, 0, bw, Skin.S(24))
                end
                W.Place(P.name, group, pad, fy + Skin.S(84))
            end
            P:Refresh()
        end
        Rebuild()
        return P
    end,
}
