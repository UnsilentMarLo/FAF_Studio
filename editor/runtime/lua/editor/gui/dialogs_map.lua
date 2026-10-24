-- The map dialogs: New map (size, name), Open map (every map the game knows, with a filter), Map info (name, description, author).
--
--   NewMap() / NewCustomMap() / OpenMap() / MapInfo()      open the dialog; the File menu commands and the start screen call these
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Maps = import('/lua/editor/maps.lua')

--- Runs `proceed()` now when the open map has no unsaved changes; otherwise asks first: Save (then proceed, unless the save was cancelled or failed),
--- Discard (proceed) or Cancel. Opening or creating a map restarts the session, so unsaved work would be gone.
function Guard(proceed)
    if not Maps.Dirty() then proceed() return end
    local d = Dialog.Open('Unsaved changes', 420, 120)
    d:Label('The open map has unsaved changes. What do you want to do?', 14, 38, { color = Skin.color.text })
    d:Button('Save', 14, 78, 100, 26, function()
        Dialog.Close()
        if Maps.Save() then proceed() end
    end)
    d:Button('Discard', 124, 78, 100, 26, function()
        Dialog.Close()
        pcall(function() import('/lua/editor/crash.lua').ClearAutosave() end)
        proceed()
    end)
    d:Button('Cancel', 234, 78, 100, 26, function() Dialog.Close() end)
end

-- ---- new map ------------------------------------------------------------------------------------------------------------------------

function NewMap()
    local d = Dialog.Open('New map', 460, 250)
    local c = Skin.color
    local state = { size = 1, custom = false }
    local buttons = {}
    d:Label('Size', 14, 36, { color = c.textDim })
    local count = table.getn(Maps.Sizes)
    local bw = math.floor((460 - 28 - (count - 1) * 6) / count)
    local say
    local function Show()
        for j, b in buttons do b:SetOn(not state.custom and j == state.size) end
        if buttons.custom then buttons.custom:SetOn(state.custom) end
    end
    for i, s in Maps.Sizes do
        local index = i
        buttons[i] = d:Button(string.gsub(s.label, ' km$', ''), 14 + (i - 1) * (bw + 6), 58, bw, 28, function()
            state.size, state.custom = index, false
            Show()
        end, { toggle = true, tip = s.label .. ' (' .. s.samples .. ' x ' .. s.samples .. ' samples).' })
    end
    buttons.custom = d:Button('Any size...', 14, 94, 120, 24, function()
        Dialog.Close()
        NewCustomMap()
    end, { tip = 'Any width and height from 1 to 80 km: the terrain of the next power of two with the playable area cut to your size.' })
    say = d:Label('', 14, 126, { color = c.error, size = 'small' })
    d:Label('Name', 14, 156, { color = c.textDim })
    local name = d:Field(70, 152, 376, 22, { text = 'My map' })
    local function Create()
        local text = name:GetText()
        if text == '' then text = 'My map' end
        if not Maps.TemplateReady(Maps.Sizes[state.size].template) then
            say:SetText('the blank map for this size is not installed: run  python scripts/studio.py generate')
            return
        end
        Dialog.Close()
        Guard(function() Maps.New(state.size, text) end)
    end
    d:Button('Create', 14, 206, 100, 26, Create)
    d:Button('Cancel', 124, 206, 100, 26, function() Dialog.Close() end)
    name.OnEnterPressed = function(self, text) Create() return true end
    Show()
    buttons[1]:SetOn(true)
    name:AcquireFocus()
end

--- The size of any map: width and height in kilometres, the terrain it needs, the playable area in it (maps.lua CustomPlan).
function NewCustomMap()
    local d = Dialog.Open('New map of any size', 540, 420)
    local c = Skin.color
    local O = { w = 10, h = 10, square = true }
    local sliders = {}
    local info1, info2, info3, say
    local boxOuter, boxInner
    local squareButton
    local BOX = 120

    local function Redraw()
        local plan, why = Maps.CustomPlan(O.w, O.h)
        if not plan then
            info1:SetText(tostring(why)) info1:SetColor(c.error)
            info2:SetText('') info3:SetText('')
            return
        end
        info1:SetText(string.format('Playable area  %d x %d units  (%.1f x %.1f km)', plan.w, plan.h, plan.w / Maps.SAMPLES_PER_KM, plan.h / Maps.SAMPLES_PER_KM))
        info1:SetColor(c.text)
        info2:SetText(string.format('Terrain  %d x %d samples  (%.0f km), the playable area uses %d%% of it', plan.terrain, plan.terrain, plan.terrain / Maps.SAMPLES_PER_KM, math.floor(plan.used * 100 + 0.5)))
        local ready = Maps.TemplateReady(plan.template)
        if not ready then
            info3:SetText('the blank map for this terrain is not installed: run  python scripts/studio.py generate') info3:SetColor(c.error)
        elseif plan.whole then
            info3:SetText('No playable area is needed: the size is the terrain.') info3:SetColor(c.textDim)
        elseif plan.used < 0.4 then
            info3:SetText('Much of the terrain stays unused: a size close to a power of two (5, 10, 20, 40 km) costs less memory.') info3:SetColor(c.textDim)
        else
            info3:SetText('The playable area is in the middle of the terrain, the start position in the middle of the area.') info3:SetColor(c.textDim)
        end
        -- the picture: the terrain square and the playable area in it
        local ow, oh = math.floor(Skin.S(BOX) * plan.w / plan.terrain), math.floor(Skin.S(BOX) * plan.h / plan.terrain)
        local ox = math.floor((Skin.S(BOX) - ow) / 2)
        local oz = math.floor((Skin.S(BOX) - oh) / 2)
        boxInner.Left:Set(boxOuter.Left() + ox) boxInner.Top:Set(boxOuter.Top() + oz)
        boxInner.Width:Set(math.max(2, ow)) boxInner.Height:Set(math.max(2, oh))
        if squareButton then squareButton:SetOn(O.square) end
    end

    local function Set(key, v)
        O[key] = v
        if O.square then
            O.w, O.h = v, v
            for _, sl in sliders do sl:Refresh() end
        end
        Redraw()
    end
    local function Row(label, key, x, y)
        local sl = W.Slider(d.group, { label = label, min = Maps.MIN_KM, max = Maps.MAX_KM, step = 0.1, curve = 2, fmt = '%.1f', compact = true,
            get = function() return O[key] end, set = function(v) Set(key, v) end })
        sl:Place(Skin.S(x), Skin.S(y), Skin.S(230))
        for _, ctl in { sl.label, sl.track, sl.fill, sl.thumb, sl.minus, sl.plus } do d:Raise(ctl) end
        d:Raise(sl.field) d:Raise(sl.field.frame)
        table.insert(sliders, sl)
        return sl
    end

    d:Label('Width and height in kilometres (1 km = 51.2 units)', 14, 36, { color = c.textDim })
    Row('Width (km)', 'w', 14, 58)
    Row('Height (km)', 'h', 14, 112)
    squareButton = d:Button('Keep it square', 14, 168, 150, 24, function(self)
        O.square = not O.square
        if O.square then Set('w', O.w) end
        Redraw()
    end, { toggle = true, tip = 'Width and height change together.' })
    d:Label('Sizes', 14, 204, { color = c.textDim })
    local presets = { { 5, 5 }, { 7.5, 7.5 }, { 10, 10 }, { 15, 15 }, { 20, 20 }, { 30, 30 }, { 40, 40 }, { 5, 10 }, { 10, 20 }, { 10, 15 } }
    for i, p in presets do
        local pw, ph = p[1], p[2]
        local col, row = math.mod(i - 1, 5), math.floor((i - 1) / 5)
        local label = (pw == ph) and (pw .. ' km') or (pw .. ' x ' .. ph)
        d:Button(label, 14 + col * 62, 224 + row * 28, 58, 24, function()
            O.square = (pw == ph)
            O.w, O.h = pw, ph
            for _, sl in sliders do sl:Refresh() end
            Redraw()
        end, { tip = 'Width ' .. pw .. ' km, height ' .. ph .. ' km.' })
    end
    -- the picture of the terrain with the playable area
    d:Label('Terrain / playable area', 340, 36, { color = c.textDim })
    local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
    boxOuter = Bitmap(d.group)
    d:Raise(boxOuter)
    boxOuter:SetSolidColor(c.panel)
    boxOuter.Left:Set(d.group.Left() + Skin.S(360)) boxOuter.Top:Set(d.group.Top() + Skin.S(60))
    boxOuter.Width:Set(Skin.S(BOX)) boxOuter.Height:Set(Skin.S(BOX))
    boxOuter:DisableHitTest()
    boxInner = Bitmap(d.group)
    boxInner.Depth:Set(function() return d.group.Depth() + 8 end)
    boxInner:SetSolidColor(c.accent)
    boxInner:DisableHitTest()
    boxInner.Left:Set(boxOuter.Left()) boxInner.Top:Set(boxOuter.Top())
    boxInner.Width:Set(Skin.S(BOX)) boxInner.Height:Set(Skin.S(BOX))

    info1 = d:Label('', 14, 296, { color = c.text })
    info2 = d:Label('', 14, 316, { color = c.textDim, size = 'small' })
    info3 = d:Label('', 14, 334, { color = c.textDim, size = 'small' })
    d:Label('Name', 14, 360, { color = c.textDim })
    local name = d:Field(70, 356, 300, 22, { text = 'My map' })
    say = d:Label('', 14, 386, { color = c.error, size = 'small' })
    local function Create()
        local text = name:GetText()
        if text == '' then text = 'My map' end
        local plan, why = Maps.CustomPlan(O.w, O.h)
        if not plan then say:SetText(tostring(why)) return end
        if not Maps.TemplateReady(plan.template) then
            say:SetText('the blank map for this terrain is not installed: run  python scripts/studio.py generate')
            return
        end
        Dialog.Close()
        Guard(function()
            pcall(function() import('/lua/editor/gui/startscreen.lua').Close() end)
            local ok, err = Maps.NewCustom(O.w, O.h, text)
            if not ok then pcall(function() import('/lua/editor/gui/shell.lua').Say('new map: ' .. tostring(err)) end) end
        end)
    end
    d:Button('Create', 380, 356, 70, 26, Create)
    d:Button('Cancel', 456, 356, 70, 26, function() Dialog.Close() end)
    name.OnEnterPressed = function(self, text) Create() return true end
    Redraw()
    name:AcquireFocus()
end

-- ---- open map -----------------------------------------------------------------------------------------------------------------------

--- opts: userOnly (only the maps of the user's maps folder), title, afterOpen (a command id to run once the map is open: the start screen's "Release a map")
function OpenMap(opts)
    opts = opts or {}
    local d = Dialog.Open(opts.title or (opts.userOnly and 'Open from my maps folder' or 'Open map'), 560, 470)
    local c = Skin.color
    -- the editor's own folders (_autosave, _modreload, play test copies) are not maps to open: File > Recover autosave has the first
    local all = {}
    for _, m in (opts.userOnly and Maps.ListUser() or Maps.List()) do
        if string.sub(m.folder, 1, 1) ~= '_' then table.insert(all, m) end
    end
    local state = { shown = all }
    local list
    local field = d:Field(14, 30, 530, 22, {
        onChange = function(text)
            local f = string.lower(text or '')
            state.shown = {}
            for _, m in all do
                if f == '' or string.find(string.lower(m.name), f, 1, true) or string.find(string.lower(m.folder), f, 1, true) then
                    table.insert(state.shown, m)
                end
            end
            list:Refresh()
        end,
        onEscape = function() Dialog.Close() end,
    })
    d:Label(table.getn(all) .. ' maps' .. ((opts.userOnly and table.getn(all) == 0) and '   (the folder the game loads your own maps from has none yet)' or ''), 14, 446, { color = c.textDim, size = 'small' })
    list = W.VirtualList(d.group, {
        rowH = 22,
        extra = true,
        getCount = function() return table.getn(state.shown) end,
        bind = function(row, index)
            local m = state.shown[index]
            row.extra:SetText(m.folder)
            local ew = math.min(row.extra.Width(), Skin.S(220))
            W.Fit(row.text, m.name, math.max(Skin.S(40), row.bg.Width() - ew - Skin.S(30)))
            row.text:SetColor(c.text)
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local m = state.shown[index]
            if m then
                Dialog.Close()
                Guard(function()
                    if opts.afterOpen then
                        local UserData = import('/lua/editor/userdata.lua')
                        UserData.Set('after', opts.afterOpen)
                        UserData.Flush()
                    end
                    Maps.Open(m.path)
                end)
            end
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(58), Skin.S(544), Skin.S(380))
    field:AcquireFocus()
end

-- ---- map info -----------------------------------------------------------------------------------------------------------------------

function MapInfo()
    local info = Maps.Info()
    local d = Dialog.Open('Map info', 480, 360)
    local c = Skin.color
    d:Label('Name', 14, 42, { color = c.textDim })
    local name = d:Field(100, 38, 360, 22, { text = info.name })
    d:Label('Author', 14, 76, { color = c.textDim })
    local author = d:Field(100, 72, 360, 22, { text = info.author })
    d:Label('Description', 14, 110, { color = c.textDim })
    local desc = d:Field(100, 106, 360, 22, { text = info.description })
    local sz = info.size
    d:Label('Size', 14, 144, { color = c.textDim })
    d:Label(sz and (tostring(sz[1]) .. ' x ' .. tostring(sz[2]) .. ' world units') or '', 100, 144, { color = c.text })
    -- the map type: skirmish maps get the normal skirmish AI; a campaign map gives its AI armies the campaign brain (mission bases and attacks need it)
    local mapType = info.type
    d:Label('Type', 14, 174, { color = c.textDim })
    d:Button(tostring(mapType), 100, 170, 160, 24, function(self)
        mapType = (mapType == 'campaign') and 'skirmish' or 'campaign'
        self:SetText(mapType)
    end)
    -- scenario data the lobby reads: players (start positions), version, no-rush radius, whether the armies start on the start positions
    local starts = 0
    local doc = import('/lua/editor/map.lua').Doc
    for name, _ in doc and doc.save.MasterChain._MASTERCHAIN_.Markers or {} do
        if string.find(name, '^ARMY_%d+$') then starts = starts + 1 end
    end
    d:Label('Players', 14, 208, { color = c.textDim })
    d:Label(starts .. ' start positions (the Start position tool)', 100, 208, { color = c.text })
    d:Label('Version', 14, 238, { color = c.textDim })
    local version = d:Field(100, 234, 80, 22, { text = tostring(info.version) })
    d:Label('No-rush radius', 14, 268, { color = c.textDim })
    local norush = d:Field(100, 264, 80, 22, { text = tostring(info.norush) })
    d:Label('(units around each start position where enemies may not build in the first minutes; 0 = none)', 190, 268, { color = c.textDim, size = 'small' })
    local startsOn = info.starts
    d:Label('Armies start', 14, 298, { color = c.textDim })
    d:Button(startsOn and 'on the start positions' or 'anywhere', 100, 294, 200, 24, function(self)
        startsOn = not startsOn
        self:SetText(startsOn and 'on the start positions' or 'anywhere')
    end)
    d:Button('Apply', 14, 326, 100, 26, function()
        Maps.SetInfo({ name = name:GetText(), author = author:GetText(), description = desc:GetText(), type = mapType,
                       version = tonumber(version:GetText()), norush = tonumber(norush:GetText()), starts = startsOn })
        Dialog.Close()
    end)
    d:Button('Cancel', 124, 326, 100, 26, function() Dialog.Close() end)
    name:AcquireFocus()
end

--- Which factions each start slot offers in the game lobby (lobbyslots.lua): a row per slot, one toggle per faction.
function LobbySlots()
    local Slots = import('/lua/editor/lobbyslots.lua')
    local doc = import('/lua/editor/map.lua').Doc
    local n = 0
    for name, _ in doc and doc.save.MasterChain._MASTERCHAIN_.Markers or {} do
        if string.find(name, '^ARMY_%d+$') then n = n + 1 end
    end
    if n == 0 then
        local d = Dialog.Open('Lobby slots', 420, 110)
        d:Label('The map has no start positions yet. Use the Start position tool.', 14, 42, { color = Skin.color.text })
        d:Button('Close', 14, 74, 100, 26, function() Dialog.Close() end)
        return
    end
    local rows = math.min(n, 16)
    local d = Dialog.Open('Lobby slots: factions per start position', 460, 100 + rows * 28)
    local c = Skin.color
    d:Label('Click a faction to remove it from the slot. A slot with all four factions is unrestricted.', 14, 40, { color = c.textDim, size = 'small' })
    local state = {}
    local names = { uef = 'UEF', aeon = 'Aeon', cybran = 'Cybran', seraphim = 'Seraphim' }
    for slot = 1, rows do
        state[slot] = {}
        for _, k in Slots.Get(slot) do state[slot][k] = true end
        d:Label('Slot ' .. slot, 14, 72 + (slot - 1) * 28, { color = c.text })
        for i, key in Slots.Keys do
            local label = function() return (state[slot][key] and '[x] ' or '[  ] ') .. names[key] end
            d:Button(label(), 90 + (i - 1) * 90, 68 + (slot - 1) * 28, 86, 24, function(self)
                state[slot][key] = not state[slot][key]
                self:SetText(label())
            end)
        end
    end
    d:Button('Apply', 14, 80 + rows * 28, 100, 26, function()
        for slot = 1, rows do
            local list = {}
            for _, key in Slots.Keys do if state[slot][key] then table.insert(list, key) end end
            Slots.Set(slot, list)
        end
        Dialog.Close()
    end)
    d:Button('Cancel', 124, 80 + rows * 28, 100, 26, function() Dialog.Close() end)
end
