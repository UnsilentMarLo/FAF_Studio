-- The map dialogs: New map (size, name), Open map (every map the game knows, with a filter), Map info (name, description, author).
--
--   NewMap() / OpenMap() / MapInfo()      open the dialog; the File menu commands call these
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
    local say, widthField, heightField
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
    buttons.custom = d:Button('Custom', 14, 94, 90, 24, function()
        state.custom = true
        Show()
        widthField:AcquireFocus()
    end, { toggle = true, tip = 'Type the size in kilometres. Fractions are fine (2.5). The terrain supports 2.5, 5, 10, 20, 40 and 80 km.' })
    d:Label('Width', 116, 98, { color = c.textDim })
    widthField = d:Field(166, 94, 60, 22, { text = '10' })
    d:Label('Height', 238, 98, { color = c.textDim })
    heightField = d:Field(292, 94, 60, 22, { text = '10' })
    d:Label('km', 360, 98, { color = c.textDim })
    say = d:Label('', 14, 126, { color = c.error, size = 'small' })
    d:Label('Name', 14, 156, { color = c.textDim })
    local name = d:Field(70, 152, 376, 22, { text = 'My map' })
    local function Create()
        local text = name:GetText()
        if text == '' then text = 'My map' end
        if state.custom then
            local w, h = tonumber(widthField:GetText()), tonumber(heightField:GetText())
            if not w or not h then say:SetText('type the width and the height in kilometres, for example 2.5') return end
            if math.abs(w - h) > 0.0001 then say:SetText('the blank maps are square: width and height must be equal') return end
            local index, why = Maps.SizeForKm(w)
            if not index then say:SetText(tostring(why)) return end
            local ready = (index == 0) and '/maps/editor_blank_128/editor_blank_128_scenario.lua' or Maps.Sizes[index].template
            if not Maps.TemplateReady(ready) then
                say:SetText('the blank map for this size is not installed: run  python scripts/studio.py generate')
                return
            end
            Dialog.Close()
            Guard(function() Maps.NewKm(w, text) end)
            return
        end
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
