-- The start screen: what the editor shows when it is started without a map (a full window page over the shell, which stands ready underneath on a blank map).
--
--   Open()      builds the page (also File > Start screen); Close() / IsOpen()
--
-- Left: the things to do (new map, open, my maps folder, release a map, mod project, recover autosaved map, tutorial, help). Right: new map sizes, recent maps with
-- the preview picture of the .scmap (thumbs.lua) and a tip. "Show at start" is the setting `startScreen` of the user folder (userdata.lua).
--
-- Lua 5.0 dialect.

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Maps = import('/lua/editor/maps.lua')
local Recent = import('/lua/editor/recent.lua')
local Thumbs = import('/lua/editor/thumbs.lua')
local Tips = import('/lua/editor/tips.lua')
local Version = import('/lua/editor/version.lua')
local UserData = import('/lua/editor/userdata.lua')
local Safe = import('/lua/editor/safe.lua')

local current = false

function IsOpen()
    return current ~= false
end

function Close()
    if current then
        local g = current.group
        local content = current.content
        current = false
        g.OnFrame = function() end
        if content then pcall(W.ScrollRelease, content) end
        g:Destroy()
    end
end

local function Maps_()
    return import('/lua/editor/gui/dialogs_map.lua')
end

--- Mod project: a list of the existing projects and a field for a new one; either way the Mod workspace shows.
local function ModProject()
    local Bp = import('/lua/editor/bpedit.lua')
    local c = Skin.color
    local d = Dialog.Open('Mod project', 420, 330)
    local names = Bp.Projects()
    d:Label('Open a project', 14, 32, { color = c.textDim })
    local list = W.VirtualList(d.group, {
        rowH = 22,
        getCount = function() return table.getn(names) end,
        bind = function(row, index)
            row.text:SetText(names[index])
            row.text:SetColor(c.text)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local ok, why = Bp.Open(names[index])
            Dialog.Close()
            if ok then
                Close()
                import('/lua/editor/gui/shell.lua').ShowWorkspace('Mod')
            else
                import('/lua/editor/gui/shell.lua').Say('mod project: ' .. tostring(why))
            end
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(54), Skin.S(404), Skin.S(130))
    if table.getn(names) == 0 then d:Label('No project yet. Create the first one below.', 14, 60, { color = c.textDim, size = 'small' }) end
    d:Label('New project (letters, digits, space, - and _)', 14, 200, { color = c.textDim })
    local field = d:Field(14, 222, 390, 22, { text = '' })
    local say = d:Label('', 14, 296, { color = c.error, size = 'small' })
    d:Button('Create', 14, 256, 90, 28, function()
        local ok, why = Bp.Create(field:GetText())
        if ok then
            Dialog.Close()
            Close()
            import('/lua/editor/gui/shell.lua').ShowWorkspace('Mod')
        else
            say:SetText(tostring(why))
        end
    end)
    d:Button('Cancel', 114, 256, 90, 28, function() Dialog.Close() end)
end

function Open(opts)
    opts = opts or {}
    Close()
    local frame = GetFrame(0)
    local c = Skin.color
    local fw, fh = frame.Width(), frame.Height()
    local g = Group(frame)
    g.panelId = 'startscreen'
    g.Depth:Set(9400)               -- over the shell, under the dialogs (9500)
    g.Left:Set(0) g.Top:Set(0) g.Width:Set(fw) g.Height:Set(fh)
    local bg = Bitmap(g)
    bg.Depth:Set(function() return g.Depth() + 1 end)
    bg:SetSolidColor(c.window)
    bg.Left:Set(0) bg.Top:Set(0) bg.Width:Set(fw) bg.Height:Set(fh)
    bg.HandleEvent = function(self, event) return true end        -- nothing falls through to the editor underneath
    local state = { group = g, cards = {}, tip = 1, seenW = fw, seenH = fh }
    current = state
    -- the page scrolls when the window is too small for it (a big UI scale): everything below is placed in this content group
    local content = W.ScrollContent(g, nil)
    state.content = content

    local M = math.min(Skin.S(40), math.floor(fw / 24))
    local lw = math.min(Skin.S(300), math.floor(fw * 0.32))          -- left column
    local rx = M + lw + math.min(Skin.S(40), M)                      -- right column
    local rw = fw - rx - M

    -- ---- left column --------------------------------------------------------------------------------------------------------------------
    local title = W.Label(content, Version.Name, M, M, { size = 28, maxW = function() return lw end })
    title.Depth:Set(function() return g.Depth() + 20 end)
    local sub = W.Label(content, Version.Text() == Version.Name and '' or string.sub(Version.Text(), string.len(Version.Name) + 2), M, M + Skin.S(40), { color = c.textDim, size = 'small', maxW = function() return lw end })
    sub.Depth:Set(function() return g.Depth() + 20 end)
    W.Label(content, 'Create Supreme Commander maps, missions and mods.', M, M + Skin.S(58), { color = c.textDim, size = 'small', maxW = function() return lw end })

    local y = M + Skin.S(100)
    local bh, gap = Skin.S(34), Skin.S(8)
    local function Btn(text, onClick)
        local b = W.Button(content, text, M, y, lw, bh, onClick)
        y = y + bh + gap
        return b
    end
    Btn('New map...', function() Maps_().NewMap() end)
    Btn('Open map...', function() Maps_().OpenMap() end)
    Btn('Open from my maps folder...', function() Maps_().OpenMap({ userOnly = true }) end)
    Btn('Release a map...', function() Maps_().OpenMap({ title = 'Release which map?', afterOpen = 'file.release' }) end)
    Btn('Mod project...', ModProject)
    local autosave = Maps.AutosavePath()
    if autosave then
        Btn('Recover autosaved map', function()
            Close()
            Maps.Recover()
        end)
    end
    y = y + Skin.S(10)
    Btn('Tutorial', function()
        Close()
        Safe.Try('startscreen:fn139', function() import('/lua/editor/gui/tour.lua').Start() end)
    end)
    Btn('Help  (F1)', function()
        Close()
        Safe.Try('startscreen:fn143', function() import('/lua/editor/gui/commands.lua').Run('help.open') end)
    end)

    local show = W.Button(content, 'Show this screen at start', M, math.max(fh - M - bh, y + gap), lw, bh, function(self)
        UserData.Set('startScreen', self.on and true or false)
        UserData.Flush()
    end, { toggle = true })
    show:SetOn(UserData.Get('startScreen', true) ~= false)

    -- ---- right column -------------------------------------------------------------------------------------------------------------------
    local ry = M
    W.Label(content, 'New map', rx, ry, { color = c.textDim })
    ry = ry + Skin.S(24)
    local tileGap = Skin.S(12)
    local sizes = {}
    for _, s in Maps.Sizes do table.insert(sizes, s) end
    table.insert(sizes, { label = 'Any size...', custom = true })          -- any width and height: the terrain of the next power of two, the playable area cut to the size
    local count = table.getn(sizes)
    -- the tiles wrap into rows when the column is too narrow for their texts
    local perRow = math.max(1, math.min(count, math.floor((rw + tileGap) / (Skin.S(120) + tileGap))))
    local tw = math.floor((rw - tileGap * (perRow - 1)) / perRow)
    local th = Skin.S(64)
    local subtitles = { 'a small, quick map: 1v1, practice', 'the usual 1v1 and 2v2 size', 'big maps for 4+ players', 'huge maps, many players', 'the largest the game supports', 'your width and height, with a playable area' }
    for i, s in sizes do
        local index = i
        local tile = Bitmap(g)
        tile.Depth:Set(function() return g.Depth() + 4 end)
        tile:SetSolidColor(c.button)
        W.Place(tile, content, rx + math.mod(i - 1, perRow) * (tw + tileGap), ry + math.floor((i - 1) / perRow) * (th + tileGap), tw, th)
        tile.HandleEvent = function(self, event)
            if event.Type == 'MouseEnter' then self:SetSolidColor(c.buttonHi) return true
            elseif event.Type == 'MouseExit' then self:SetSolidColor(c.button) return true
            elseif event.Type == 'ButtonPress' then
                if sizes[index].custom then
                    Maps_().NewCustomMap()
                    return true
                end
                if not Maps.TemplateReady(Maps.Sizes[index].template) then
                    Safe.Try('startscreen:fn179', function() import('/lua/editor/gui/shell.lua').Say('the blank map for ' .. Maps.Sizes[index].label .. ' is not installed: run  python scripts/studio.py generate') end)
                    return true
                end
                Maps_().Guard(function() Close() Maps.New(index, 'My map') end)
                return true
            end
            return false
        end
        local l1 = W.Label(tile, s.label, Skin.S(10), Skin.S(10), { color = c.text, maxW = function() return tw - Skin.S(20) end })
        local l2 = W.Label(tile, subtitles[i] or 'blank terrain', Skin.S(10), Skin.S(34), { color = c.textDim, size = 'small', maxW = function() return tw - Skin.S(20) end })
    end
    ry = ry + math.ceil(count / perRow) * (th + tileGap) + Skin.S(16)

    W.Label(content, 'Recent maps', rx, ry, { color = c.textDim })
    ry = ry + Skin.S(24)
    local recent = Recent.List(8)
    local cardW, cardH = Skin.S(150), Skin.S(190)
    local cols = math.max(1, math.floor((rw + Skin.S(12)) / (cardW + Skin.S(12))))
    local tipY = math.max(fh - M - bh - gap - Skin.S(96), ry + Skin.S(24) + Skin.S(40))      -- (under the recent maps; in a window too small for both, the page scrolls)
    local areaBottom = tipY - Skin.S(12)
    if table.getn(recent) == 0 then
        W.Label(content, 'No maps yet. Create a new map above, or open one from the left.', rx, ry + Skin.S(8), { color = c.textDim, size = 'small', maxW = function() return rw end })
    end
    for i, m in recent do
        local col, row = math.mod(i - 1, cols), math.floor((i - 1) / cols)
        local cx, cy = rx + col * (cardW + Skin.S(12)), ry + row * (cardH + Skin.S(12))
        if cy + cardH <= areaBottom then
            local path = m.path
            local card = Bitmap(g)
            card.Depth:Set(function() return g.Depth() + 4 end)
            card:SetSolidColor(c.panelAlt)
            W.Place(card, content, cx, cy, cardW, cardH)
            card.HandleEvent = function(self, event)
                if event.Type == 'MouseEnter' then self:SetSolidColor(c.hover) return true
                elseif event.Type == 'MouseExit' then self:SetSolidColor(c.panelAlt) return true
                elseif event.Type == 'ButtonPress' then
                    Maps_().Guard(function() Close() Maps.Open(path) end)
                    return true
                end
                return false
            end
            local ts = cardW - Skin.S(12)
            local thumb = Bitmap(card)
            thumb.Depth:Set(function() return card.Depth() + 5 end)
            thumb:SetSolidColor(c.panel)
            thumb:DisableHitTest()
            W.Place(thumb, content, cx + Skin.S(6), cy + Skin.S(6), ts, ts)
            local cached = Thumbs.Cached(path)
            if cached then thumb:SetTexture(cached) else table.insert(state.cards, { thumb = thumb, path = path }) end
            local name = W.Label(card, m.name, Skin.S(6), ts + Skin.S(10), { color = c.text })
            W.Fit(name, m.name, cardW - Skin.S(12))
            local folder = W.Label(card, m.folder, Skin.S(6), ts + Skin.S(30), { color = c.textDim, size = 'small' })
            W.Fit(folder, m.folder, cardW - Skin.S(12))
        end
    end

    -- ---- tip and way out ----------------------------------------------------------------------------------------------------------------
    local ty = tipY
    local tipBox = Bitmap(g)
    tipBox.Depth:Set(function() return g.Depth() + 3 end)
    tipBox:SetSolidColor(c.panel)
    W.Place(tipBox, content, rx, ty, rw, Skin.S(96))
    W.Label(content, 'Tip', rx + Skin.S(12), ty + Skin.S(8), { color = c.accent, size = 'small' })
    state.tipLabels = {}
    local function ShowTip()
        for _, l in state.tipLabels do l:Destroy() end
        state.tipLabels = W.Paragraph(content, Tips.Get(state.tip), rx + Skin.S(12), ty + Skin.S(32), rw - Skin.S(24), { color = c.text, size = 'small' }, Skin.S(18), ty + Skin.S(94))
    end
    state.tip = math.mod(math.floor(GetSystemTimeSeconds()), Tips.Count()) + 1
    ShowTip()
    W.Button(content, 'Next tip', rx + rw - Skin.S(96), ty + Skin.S(6), Skin.S(86), Skin.S(24), function()
        state.tip = state.tip + 1
        ShowTip()
    end)
    local go = W.Button(content, opts.afterNoMap and 'Start with a blank map' or 'Close', rx + rw - Skin.S(220), math.max(fh - M - bh, ty + Skin.S(96) + gap), Skin.S(220), bh, function()
        Close()
        Safe.Try('startscreen:fn255', function() import('/lua/editor/gui/feature_start.lua').MaybeTour() end)
    end)

    -- ---- thumbnails arrive one per frame (reading a big .scmap takes a moment) --------------------------------------------------------------
    g:SetNeedsFrameUpdate(true)
    g.OnFrame = function(self, delta)
        -- the window was resized: the screen is laid out for one size, so it is built again once the size has stopped changing (not on every step of a drag)
        local nw, nh = frame.Width(), frame.Height()
        if nw ~= state.seenW or nh ~= state.seenH then
            state.seenW, state.seenH = nw, nh
            state.sizeAt = GetSystemTimeSeconds()
        elseif state.sizeAt and GetSystemTimeSeconds() - state.sizeAt > 0.25 and (nw ~= fw or nh ~= fh) and not state.rebuilding then
            state.rebuilding = true
            ForkThread(function()
                if current == state then Open(opts) end
            end)
            return
        end
        local nextCard = table.remove(state.cards, 1)
        if nextCard then
            local vfs = Thumbs.For(nextCard.path)
            if vfs then nextCard.thumb:SetTexture(vfs) end
        end
    end
    return state
end
