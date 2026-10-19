-- The Assets panel: one browser for everything the editor can place or use: units, props, decals, marker templates, terrain textures, effects and mod projects, as a thumbnail grid or a list,
-- with search, filters by category (faction, tech, layer, type, environment ...), favourites and recently used. A click picks the entry for its tool, a double click uses it (a texture goes
-- to the active terrain layer, an effect plays, a mod project opens), and an entry of a placeable kind can be dragged into the viewport and dropped: it is placed at the pointer, at every
-- symmetry image, as one undo step. The big preview under the grid follows the pointer. Pictures come from assetthumbs.lua (cached on disk, made in the background). Logic: assetcat.lua.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Grid = import('/lua/editor/gui/grid.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Cat = import('/lua/editor/assetcat.lua')
local Fav = import('/lua/editor/favourites.lua')
local Thumbs = import('/lua/editor/assetthumbs.lua')
local UserData = import('/lua/editor/userdata.lua')

live = {}

-- what the panel shows, kept between runs
State = {
    kind = UserData.Get('assets.kind', 'all'),
    list = UserData.Get('assets.list', false),
    size = UserData.Get('assets.size', 64),
    query = '',
    filters = {},
    onlyFav = false,
    recent = false,
}

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function KindLabel(id)
    if id == 'all' then return 'All' end
    for _, k in Cat.Kinds do
        if k.id == id then return k.label end
    end
    return id
end

--- The colour of the tile of an entry without a picture (markers: the template colour; the rest: a colour from the kind).
local KIND_COLORS = { units = 'ff3d6f8a', props = 'ff4f7a46', decals = 'ff7a6a3d', markers = 'ff808080', textures = 'ff6a4f7a', effects = 'ffa0602c', mods = 'ff2c8a7a' }

local function TileColor(entry)
    return entry.color or KIND_COLORS[entry.kind] or 'ff555555'
end

Panels.Register{
    id = 'assets', title = 'Assets', minW = 220,
    stack = { { workspace = 'Objects', with = 'console' }, { workspace = 'Mission', with = 'console' }, { workspace = 'Mod', with = 'console' } },
    create = function(group, host)
        local P = { shown = {}, w = 300, h = 400 }
        live.assets = P
        local c = Skin.color

        -- ---- the list of entries ------------------------------------------------------------------------------------------------------------
        function P:Rebuild()
            local opts = { query = State.query, filters = State.filters, onlyFav = State.onlyFav, recent = State.recent }
            P.shown = Cat.Find(State.kind, opts)
            if P.grid then
                P.grid.selected = nil
                if P.selKey then
                    for i, e in P.shown do
                        if e.kind .. '|' .. e.key == P.selKey then P.grid.selected = i break end
                    end
                end
                P.grid:Refresh()
            end
            P:UpdateCount()
        end

        function P:UpdateCount()
            if P.count then
                local total = table.getn(Cat.Entries(State.kind))
                P.count:SetText(table.getn(P.shown) .. ' of ' .. total)
            end
        end

        -- ---- the controls ------------------------------------------------------------------------------------------------------------------
        P.filterLabel = W.Label(group, 'Find', 0, 0, { color = c.textDim })
        P.filter = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function(text) State.query = text P:Rebuild() end })

        P.kindButtons = {}
        local kinds = { { id = 'all', label = 'All' } }
        for _, k in Cat.Kinds do table.insert(kinds, k) end
        for _, k in kinds do
            local id = k.id
            local b = W.Button(group, k.label, 0, 0, Skin.S(56), Skin.S(22), function()
                State.kind = id
                State.filters = {}
                UserData.Set('assets.kind', id)
                P:Rebuild()
                P:Layout()
            end, { tip = (id == 'all') and 'Show every kind of asset together.' or ('Show only ' .. string.lower(k.label) .. '.') })
            P.kindButtons[id] = b
        end

        P.facetButtons = {}
        for i = 1, 4 do
            local b = W.Button(group, '', 0, 0, Skin.S(100), Skin.S(22), function(self, event)
                local f = P.facets and P.facets[i]
                if not f then return end
                local values = Cat.Values(State.kind, f[1])
                local cur = State.filters[f[1]]
                local at = 0
                for j, v in values do if v == cur then at = j end end
                at = at + 1
                if at > table.getn(values) then State.filters[f[1]] = nil else State.filters[f[1]] = values[at] end
                P:Rebuild()
                P:Layout()
            end, { tip = 'Click to step through the values of this filter; the last step shows all.' })
            P.facetButtons[i] = b
        end

        P.favOnly = W.Button(group, 'Starred', 0, 0, Skin.S(64), Skin.S(22), function(self)
            State.onlyFav = self.on
            P:Rebuild()
        end, { toggle = true, tip = 'Show only the entries you marked with a star.' })
        P.recentBtn = W.Button(group, 'Recent', 0, 0, Skin.S(64), Skin.S(22), function(self)
            State.recent = self.on
            P:Rebuild()
        end, { toggle = true, tip = 'Show what you used last, newest first.' })
        P.viewBtn = W.Button(group, 'List', 0, 0, Skin.S(48), Skin.S(22), function(self)
            State.list = self.on
            UserData.Set('assets.list', State.list)
            P:Layout()
        end, { toggle = true, tip = 'Switch between thumbnails and a list.' })
        P.size = W.Slider(group, { label = 'Thumbnail size', min = 40, max = 110, step = 4, fmt = '%d', compact = true,
            get = function() return State.size end,
            set = function(v) State.size = v UserData.Set('assets.size', v) P:Layout() end })
        P.count = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        P.grid = Grid.Create(group, {
            cellW = State.size, cellH = State.size + 20,
            getCount = function() return table.getn(P.shown) end,
            bind = function(cell, index, selected)
                local e = P.shown[index]
                local tex = Cat.Thumb(e)
                if tex then cell.thumb:SetTexture(tex) else cell.thumb:SetSolidColor(TileColor(e)) end
                cell.mark:SetText(tex and '' or string.upper(string.sub(e.sub ~= '' and e.kind == 'units' and e.sub or e.name, 1, 4)))
                cell.text = e.name
                cell.label:SetColor(Cat.IsActive(e) and c.accent or c.text)
                cell.badge:SetText(Fav.Is(e.kind, e.key) and '*' or '')
            end,
            onHover = function(index)
                P.hover = index and P.shown[index] or nil
                P:ShowPreview(P.hover or P.selected)
            end,
            onSelect = function(index)
                local e = P.shown[index]
                if not e then return end
                P.selected = e
                P.selKey = e.kind .. '|' .. e.key
                Cat.Pick(e)
                P:ShowPreview(e)
                P.grid:Refresh()
            end,
            onActivate = function(index)
                local e = P.shown[index]
                if e then Cat.Activate(e) P.grid:Refresh() end
            end,
            onContext = function(index, x, y)
                local e = P.shown[index]
                if not e then return end
                local items = {
                    { title = Fav.Is(e.kind, e.key) and 'Remove the star' or 'Star it', run = function() Fav.Toggle(e.kind, e.key) P:Rebuild() P:ShowPreview(e) end },
                    { title = Cat.Droppable(e) and 'Pick (then click in the viewport)' or 'Use', run = function() Cat.Activate(e) P.grid:Refresh() end },
                }
                Menu.Show(GetFrame(0), x, y, items)
            end,
            canDrag = function(index) local e = P.shown[index] return e and Cat.Droppable(e) end,
            ghost = function(index)
                local e = P.shown[index]
                return e and (Cat.Thumb(e) or TileColor(e))
            end,
            onDrop = function(index, x, y, frame)
                local e = P.shown[index]
                if not e then return end
                local wx, wz = Cat.WorldAt(x, y, frame)
                if not wx then return end
                local n = Cat.DropAt(e, wx, wz)
                Say((n and n > 0) and ('placed ' .. e.name .. (n > 1 and (' x ' .. n .. ' (symmetry)') or '')) or ('could not place ' .. e.name))
                P.selected = e
                P.selKey = e.kind .. '|' .. e.key
                P:ShowPreview(e)
                P.grid:Refresh()
            end,
        })

        -- the preview strip under the grid
        P.pFrame = Bitmap(group)
        P.pFrame:SetSolidColor(c.panelAlt)
        P.pFrame:DisableHitTest()
        P.pThumb = Bitmap(group)
        P.pThumb:SetSolidColor(c.panelAlt)
        P.pThumb.Depth:Set(function() return group.Depth() + 8 end)
        P.pThumb:DisableHitTest()
        P.pName = W.Label(group, '', 0, 0, { color = c.text })
        P.pSub = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.pTags = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.pPath = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.star = W.Button(group, 'Star', 0, 0, Skin.S(56), Skin.S(22), function()
            local e = P.selected
            if e then Fav.Toggle(e.kind, e.key) P:Rebuild() P:ShowPreview(e) end
        end, { tip = 'Mark the selected entry as a favourite (favourites come first in the list).' })
        P.use = W.Button(group, 'Use', 0, 0, Skin.S(56), Skin.S(22), function()
            local e = P.selected
            if e then Cat.Activate(e) P.grid:Refresh() end
        end, { tip = 'Same as a double click: a texture goes to the active terrain layer, an effect plays, a mod project opens, other entries are picked for their tool.' })

        function P:ShowPreview(e)
            if not e then
                P.pThumb:SetSolidColor(c.panelAlt)
                P.pName:SetText('Nothing selected')
                P.pSub:SetText('')
                P.pTags:SetText('')
                P.pPath:SetText('')
                return
            end
            local tex = Cat.Thumb(e)
            if tex then P.pThumb:SetTexture(tex) else P.pThumb:SetSolidColor(TileColor(e)) end
            local textW = P.textW or Skin.S(120)
            W.Fit(P.pName, e.name, textW)
            W.Fit(P.pSub, KindLabel(e.kind) .. (e.sub ~= '' and ('  -  ' .. e.sub) or ''), textW)
            local tags = {}
            for _, f in Cat.Facets(e.kind) do
                if e.tags[f[1]] then table.insert(tags, e.tags[f[1]]) end
            end
            W.Fit(P.pTags, table.concat(tags, ', '), textW)
            local path = e.source or e.key
            W.Fit(P.pPath, string.gsub(path, '^.*/', ''), textW)
            P.star:SetText(Fav.Is(e.kind, e.key) and 'Unstar' or 'Star')
        end

        -- ---- layout ------------------------------------------------------------------------------------------------------------------------
        -- narrow (a docked column): controls on top, the grid, the preview strip at the bottom; wide (a pop-out or a wide dock): controls at the left, the grid in the middle, the preview at the right
        local function Controls(x0, y0, cw)
            local gap = Skin.S(4)
            local bh = Skin.S(22)
            local y = y0
            W.Place(P.filterLabel, group, x0, y + Skin.S(3))
            W.Place(P.filter.frame, group, x0 + Skin.S(34), y, cw - Skin.S(34), bh)
            P.filter.Width:Set(cw - Skin.S(34) - 2)
            y = y + bh + gap
            local bw = Skin.S(56)
            local perRow = math.max(1, math.floor((cw + gap) / (bw + gap)))
            local x, col = x0, 0
            for _, k in kinds do
                local b = P.kindButtons[k.id]
                if col >= perRow then col = 0 x = x0 y = y + bh + gap end
                W.Place(b, group, x, y, bw, bh)
                b:SetOn(State.kind == k.id)
                x = x + bw + gap
                col = col + 1
            end
            y = y + bh + gap
            P.facets = (State.kind ~= 'all') and Cat.Facets(State.kind) or {}
            local half = math.floor((cw - gap) / 2)
            for i, b in P.facetButtons do
                local f = P.facets[i]
                if f then
                    local cur = State.filters[f[1]]
                    b:SetText(f[2] .. ': ' .. (cur or 'any'))
                    b:SetOn(cur ~= nil)
                    local col2 = math.mod(i - 1, 2)
                    W.Place(b, group, x0 + col2 * (half + gap), y, half, bh)
                    b.Width:Set(half)
                    W.Center(b.label, b, 0, 0, half, bh)
                    b:Show()
                    if col2 == 1 or not P.facets[i + 1] then y = y + bh + gap end
                else
                    b:Hide()
                end
            end
            W.Place(P.favOnly, group, x0, y, Skin.S(64), bh)
            W.Place(P.recentBtn, group, x0 + Skin.S(68), y, Skin.S(64), bh)
            W.Place(P.viewBtn, group, x0 + Skin.S(136), y, Skin.S(48), bh)
            P.favOnly:SetOn(State.onlyFav)
            P.recentBtn:SetOn(State.recent)
            P.viewBtn:SetOn(State.list)
            W.Place(P.count, group, x0 + Skin.S(192), y + Skin.S(4))
            y = y + bh + gap
            P.size:Place(x0, y, cw)
            return y + Skin.S(46)
        end

        local function PlacePreview(x0, y0, pw, vertical, maxSide)
            local bh = Skin.S(22)
            local side = vertical and math.min(pw, Skin.S(150)) or Skin.S(84)
            if maxSide then side = math.max(Skin.S(40), math.min(side, maxSide)) end
            W.Place(P.pFrame, group, x0, y0, pw, vertical and (side + Skin.S(112)) or (side + Skin.S(8)))
            P.pFrame.Width:Set(pw) P.pFrame.Height:Set(vertical and (side + Skin.S(112)) or (side + Skin.S(8)))
            W.Place(P.pThumb, group, x0 + Skin.S(4), y0 + Skin.S(4), side, side)
            P.pThumb.Width:Set(side) P.pThumb.Height:Set(side)
            local tx, ty
            if vertical then tx, ty = x0 + Skin.S(6), y0 + side + Skin.S(10) else tx, ty = x0 + side + Skin.S(12), y0 + Skin.S(4) end
            P.textW = math.max(Skin.S(60), pw - (tx - x0) - Skin.S(6))
            W.Place(P.pName, group, tx, ty)
            W.Place(P.pSub, group, tx, ty + Skin.S(20))
            W.Place(P.pTags, group, tx, ty + Skin.S(36))
            W.Place(P.pPath, group, tx, ty + Skin.S(52))
            W.Place(P.star, group, tx, ty + Skin.S(72), Skin.S(56), bh)
            W.Place(P.use, group, tx + Skin.S(62), ty + Skin.S(72), Skin.S(56), bh)
        end

        --- Short and wide (the bottom dock): everything in two rows above the grid. Returns the y below them.
        local function SliderShown(on)
            local S = P.size
            for _, part in { S.label, S.track, S.fill, S.thumb, S.minus, S.plus, S.field.frame } do
                if on then part:Show() else part:Hide() end
            end
        end

        local function ControlsStrip(w)
            local pad, gap = Skin.S(8), Skin.S(4)
            local bh = Skin.S(22)
            local x, y = pad, pad
            W.Place(P.filterLabel, group, x, y + Skin.S(3))
            W.Place(P.filter.frame, group, x + Skin.S(34), y, Skin.S(160), bh)
            P.filter.Width:Set(Skin.S(160) - 2)
            x = x + Skin.S(34) + Skin.S(160) + Skin.S(8)
            local bw = Skin.S(52)
            for _, k in kinds do
                local b = P.kindButtons[k.id]
                W.Place(b, group, x, y, bw, bh)
                b.Width:Set(bw)
                W.Center(b.label, b, 0, 0, bw, bh)
                b:SetOn(State.kind == k.id)
                x = x + bw + gap
            end
            W.Place(P.count, group, x + Skin.S(4), y + Skin.S(4))
            y = y + bh + gap
            x = pad
            P.facets = (State.kind ~= 'all') and Cat.Facets(State.kind) or {}
            local tail = Skin.S(184) + Skin.S(8)
            local nf = table.getn(P.facets)
            local fw = nf > 0 and math.min(Skin.S(160), math.floor((w - 2 * pad - tail - nf * gap) / nf)) or 0
            for i, b in P.facetButtons do
                local f = P.facets[i]
                if f then
                    local cur = State.filters[f[1]]
                    b:SetText(f[2] .. ': ' .. (cur or 'any'))
                    b:SetOn(cur ~= nil)
                    W.Place(b, group, x, y, fw, bh)
                    b.Width:Set(fw)
                    W.Center(b.label, b, 0, 0, fw, bh)
                    b:Show()
                    x = x + fw + gap
                else
                    b:Hide()
                end
            end
            x = math.max(x, pad)
            W.Place(P.favOnly, group, x, y, Skin.S(64), bh)
            W.Place(P.recentBtn, group, x + Skin.S(68), y, Skin.S(64), bh)
            W.Place(P.viewBtn, group, x + Skin.S(136), y, Skin.S(48), bh)
            P.favOnly:SetOn(State.onlyFav)
            P.recentBtn:SetOn(State.recent)
            P.viewBtn:SetOn(State.list)
            return y + bh + gap
        end

        function P:Layout()
            local w, h = P.w, P.h
            local pad, gap = Skin.S(8), Skin.S(4)
            local wide = w >= Skin.S(620)
            local short = wide and h < Skin.S(330)
            P.wide, P.short = wide, short
            local cell = State.size
            SliderShown(not short)       -- (short and wide: the thumbnails take the height there is)
            if short then
                local y = ControlsStrip(w)
                local pw = Skin.S(200)
                local gridH = math.max(Skin.S(50), h - y - pad)
                cell = math.max(36, math.min(State.size, math.floor(gridH / Skin.S(1)) - 26))
                if State.list then P.grid:SetCellSize(100, 26, true) else P.grid:SetCellSize(cell, cell + 22, false) end
                P.grid:SetRect(pad, y, w - 3 * pad - pw, gridH)
                PlacePreview(w - pad - pw, y, pw, false, gridH - Skin.S(8))
            else
                local cw = wide and Skin.S(224) or (w - 2 * pad)
                local y = Controls(pad, pad, cw)
                if State.list then P.grid:SetCellSize(100, 26, true) else P.grid:SetCellSize(cell, cell + 22, false) end
                if wide then
                    local pw = Skin.S(190)
                    local gx = pad + cw + pad
                    P.grid:SetRect(gx, pad, w - gx - pw - 2 * pad, h - 2 * pad)
                    PlacePreview(w - pad - pw, pad, pw, true)
                else
                    local strip = Skin.S(92)
                    local gridH = math.max(Skin.S(60), h - y - strip - pad)
                    P.grid:SetRect(pad, y, w - 2 * pad, gridH)
                    PlacePreview(pad, y + gridH + Skin.S(6), w - 2 * pad, false)
                end
            end
            P:ShowPreview(P.hover or P.selected)
        end

        function P:Refresh()
            P.grid:Refresh()
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            P:Layout()
        end

        function P:Destroy()
            Thumbs.Unlisten('assets')
        end

        -- pictures that arrive in the background: draw again (at most every 0.2 s: assetthumbs.lua)
        P.onThumbs = function()
            if live.assets == P and P.grid and not P.grid.dragging then P.grid:Refresh() P:ShowPreview(P.hover or P.selected) end
        end
        Thumbs.Listen('assets', P.onThumbs)

        P.filter:SetText(State.query)
        P:Rebuild()
        return P
    end,
}
