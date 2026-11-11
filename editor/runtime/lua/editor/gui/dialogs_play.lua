-- The Play setup dialog (File > Play setup..., the Play setup button of the tool panel): who plays a test run and how. The logic and the saved profiles are lua/editor/playsetup.lua.
--
--   Open()            the dialog for the open map; changes are remembered when it closes (the last setup, and the map's own when "Keep for this map" is on)
--
-- A setup that only needs the editing session (you in the first slot as UEF, nobody else, no fog) plays at once; anything else makes Play open the saved copy in a new session.
-- Lua 5.0 dialect.

local Dialog = import('/lua/editor/gui/dialog.lua')
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local PS = import('/lua/editor/playsetup.lua')

local function Tip(key)
    return function()
        local ok, text = pcall(function() return import('/lua/editor/tooltips.lua').ForWidget('dialog', key) end)
        return ok and text or nil
    end
end

local function Copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = Copy(v) end
    return c
end

local SHORT_LIST = 8       -- up to this many mods are switches in the dialog, more are picked in the browser

--- The menu items for picking an AI type: the game's own types first, then one submenu per AI mod (this game has dozens of types: one flat menu would not fit the screen).
--- `pick(key)` is called with the chosen key; `current` (a key) gets the check mark.
local function AiItems(pick, current)
    local items, groups, order = {}, {}, {}
    local separated = false
    for _, t in PS.AiTypes() do
        local key = t.key
        local item = { title = t.name, checked = (key == current), run = function() pick(key) end }
        if t.mod == '' then
            table.insert(items, item)
        else
            if not groups[t.mod] then
                groups[t.mod] = {}
                table.insert(order, t.mod)
            end
            table.insert(groups[t.mod], item)
        end
    end
    for _, uid in order do
        local title = uid
        for _, m in PS.Mods() do
            if m.uid == uid then title = m.name end
        end
        local list = groups[uid]
        if table.getn(list) > 0 then
            if table.getn(items) > 0 and not separated then
                separated = true
                table.insert(items, { separator = true })
            end
            table.insert(items, { title = title .. ' (AI mod)', submenu = list })
        end
    end
    return items
end

local ROLE_TEXT = { you = 'You', ai = 'AI', empty = '-' }
local NEXT_ROLE = { you = 'ai', ai = 'empty', empty = 'you' }

local function TeamText(t) return (t and t > 0) and ('Team ' .. t) or 'No team' end

function Open()
    local c = Skin.color
    local n = PS.SlotCount()
    local S = { setup = PS.Current(), keep = PS.KeepsOwn(), n = n, profile = '' }
    local rows = {}            -- per slot: { role, ai, team, faction } buttons
    local modButtons = {}
    local sliders = {}
    local profileButton, nameField, fogButton, victoryButton, prebuiltButton, keepButton, problems, status
    local campaign = PS.IsCampaign()

    local height = 340 + math.min(n, 12) * 30 + math.min(table.getn(PS.Mods()), SHORT_LIST) * 28
    local d = Dialog.Open('Play setup: who plays the test run', 560, math.min(height, 760), function() PS.Remember(S.setup, S.keep) end)

    local function Say(text, color)
        status:SetText(text or '')
        status:SetColor(color or c.textDim)
    end

    local function Refresh()
        for i = 1, n do
            local slot, r = S.setup.slots[i], rows[i]
            r.role:SetText(ROLE_TEXT[slot.role])
            r.role:SetOn(slot.role == 'you')
            r.ai:SetText(slot.role == 'ai' and PS.AiName(slot.ai) or '-')
            r.team:SetText(TeamText(slot.team))
            r.faction:SetText(PS.FactionName(slot.faction))
        end
        fogButton:SetOn(S.setup.fog)
        fogButton:SetText(S.setup.fog and 'Fog of war: on' or 'Fog of war: off')
        prebuiltButton:SetOn(S.setup.prebuilt)
        prebuiltButton:SetText(S.setup.prebuilt and 'Pre-built bases: on' or 'Pre-built bases: off')
        keepButton:SetOn(S.keep)
        for _, sl in sliders do sl:Refresh() end
        local vname = S.setup.victory
        for _, v in PS.VICTORY do
            if v.key == S.setup.victory then vname = v.name end
        end
        victoryButton:SetText('Victory: ' .. vname)
        for uid, b in modButtons do
            local on = false
            for _, u in S.setup.mods do
                if u == uid then on = true end
            end
            b:SetOn(on)
        end
        profileButton:SetText('Profile: ' .. (S.profile ~= '' and S.profile or '(custom)'))
        local list = PS.Problems(S.setup)
        problems:SetText(list[1] and ('! ' .. list[1]) or '')
        local used = PS.UsedMods(S.setup)
        if PS.NeedsReload(S.setup) then
            Say('Play opens the saved map in a new session (' .. (table.getn(used) > 0 and (table.getn(used) .. ' mod(s), ') or '') .. 'about 10-20 s); Stop brings the editor back.')
        else
            Say('Plays at once in this session: you as UEF in the first slot, nobody else.')
        end
    end

    local function Custom()
        S.profile = ''
    end

    local function Slide(label, x, y, opts)
        opts.label = label
        opts.compact = true
        opts.tip = Tip(string.lower(label))
        local sl = W.Slider(d.group, opts)
        sl:Place(Skin.S(x), Skin.S(y), Skin.S(math.min(250, d:Span(x, 14))))
        for _, ctl in { sl.label, sl.track, sl.fill, sl.thumb, sl.minus, sl.plus } do d:Raise(ctl) end
        d:Raise(sl.field) d:Raise(sl.field.frame)
        table.insert(sliders, sl)
        return sl
    end

    local y = 36
    if campaign then
        d:Text('This map is a campaign mission: it plays with its own armies and brains, the setup below does not apply.', 14, y, { color = c.error })
        y = y + 44
    end

    -- ---- profiles
    profileButton = d:Button('Profile: (custom)', 14, y, 330, 24, function(self)
        local items = {}
        local names = PS.Profiles()
        for i, name in names do
            local picked = name
            if i == table.getn(PS.BUILTIN) + 1 then table.insert(items, { separator = true }) end
            table.insert(items, { title = picked, checked = (picked == S.profile), run = function()
                local setup = PS.GetProfile(picked, n)
                if setup then
                    S.setup = setup
                    S.profile = picked
                    nameField:SetText(PS.IsBuiltin(picked) and '' or picked)
                    Refresh()
                end
            end })
        end
        Menu.Show(GetFrame(0), self.Left(), self.Top() + self.Height(), items)
    end, { tip = Tip('play profile') })
    y = y + 30
    d:Label('Name', 14, y + 3, { color = c.textDim })
    nameField = d:Field(60, y, 190, 22, { text = '', tip = Tip('play profile name') })
    d:Button('Save', 256, y, 70, 22, function()
        local ok, why = PS.SaveProfile(nameField:GetText(), S.setup)
        if ok then
            S.profile = nameField:GetText()
            Refresh()
            Say('saved the profile "' .. S.profile .. '"', c.text)
        else
            Say(why, c.error)
        end
    end, { tip = Tip('save profile') })
    d:Button('Delete', 332, y, 70, 22, function()
        local name = nameField:GetText()
        local ok, why = PS.DeleteProfile(name)
        if ok then
            if S.profile == name then S.profile = '' end
            Refresh()
            Say('deleted the profile "' .. name .. '"', c.text)
        else
            Say(why, c.error)
        end
    end, { tip = Tip('delete profile') })
    y = y + 34

    -- ---- slots
    d:Label('Slots (' .. n .. ' start position' .. (n == 1 and '' or 's') .. ' on this map)', 14, y, { color = c.textDim })
    d:Button('Same AI for all', 330, y - 3, 130, 22, function(self)
        local items = AiItems(function(picked)
            for i = 1, n do
                if S.setup.slots[i].role == 'ai' then S.setup.slots[i].ai = picked end
            end
            Custom()
            Refresh()
        end, nil)
        Menu.Show(GetFrame(0), self.Left(), self.Top() + self.Height(), items)
    end, { tip = Tip('same ai for all') })
    y = y + 24
    for i = 1, n do
        local index = i
        d:Label('Slot ' .. i, 14, y + 3, { color = c.text })
        local r = {}
        r.role = d:Button('-', 66, y, 56, 24, function()
            local slot = S.setup.slots[index]
            local nextRole = NEXT_ROLE[slot.role]
            if nextRole == 'you' then
                for j = 1, n do
                    if S.setup.slots[j].role == 'you' then S.setup.slots[j].role = 'empty' end
                end
            end
            slot.role = nextRole
            Custom()
            Refresh()
        end, { tip = Tip('slot role') })
        r.ai = d:Button('-', 128, y, 206, 24, function(self)
            local slot = S.setup.slots[index]
            if slot.role ~= 'ai' then return end
            local items = AiItems(function(picked)
                slot.ai = picked
                Custom()
                Refresh()
            end, slot.ai)
            Menu.Show(GetFrame(0), self.Left(), self.Top() + self.Height(), items)
        end, { tip = Tip('slot ai type') })
        r.team = d:Button('No team', 340, y, 70, 24, function()
            local slot = S.setup.slots[index]
            slot.team = math.mod((slot.team or 0) + 1, math.min(n, PS.MAX_TEAM) + 1)
            Custom()
            Refresh()
        end, { tip = Tip('slot team') })
        r.faction = d:Button('Random', 416, y, 80, 24, function()
            local slot = S.setup.slots[index]
            local keys = { '' }
            for _, f in PS.Factions() do table.insert(keys, f.key) end
            local at = 1
            for k, key in keys do
                if key == slot.faction then at = k end
            end
            slot.faction = keys[math.mod(at, table.getn(keys)) + 1]
            Custom()
            Refresh()
        end, { tip = Tip('slot faction') })
        rows[i] = r
        y = y + 28
    end
    y = y + 8

    -- ---- the game's options
    fogButton = d:Button('Fog of war: off', 14, y, 160, 24, function()
        S.setup.fog = not S.setup.fog
        Custom()
        Refresh()
    end, { tip = Tip('fog of war') })
    prebuiltButton = d:Button('Pre-built bases: off', 180, y, 170, 24, function()
        S.setup.prebuilt = not S.setup.prebuilt
        Custom()
        Refresh()
    end, { tip = Tip('pre-built bases') })
    keepButton = d:Button('Keep for this map', 356, y, 140, 24, function()
        S.keep = not S.keep
        Refresh()
    end, { tip = Tip('keep for this map') })
    y = y + 32
    victoryButton = d:Button('Victory: Sandbox', 14, y, 482, 24, function(self)
        local items = {}
        for _, v in PS.VICTORY do
            local picked = v.key
            table.insert(items, { title = v.name, checked = (picked == S.setup.victory), run = function()
                S.setup.victory = picked
                Custom()
                Refresh()
            end })
        end
        Menu.Show(GetFrame(0), self.Left(), self.Top() + self.Height(), items)
    end, { tip = Tip('victory condition') })
    y = y + 32
    Slide('Unit cap', 14, y, { stops = PS.UNIT_CAPS, fmt = '%d',
        get = function() return S.setup.unitCap end, set = function(v) S.setup.unitCap = v Custom() end })
    Slide('AI cheat multiplier', 270, y, { min = 0.5, max = 5.9, step = 0.1, fmt = '%.1f',
        get = function() return S.setup.cheat end, set = function(v) S.setup.cheat = v Custom() end })
    y = y + 54

    -- ---- mods: a few are switches; a long list (this game has dozens) is picked in the browser and the chosen ones are listed to be removed
    local mods = PS.Mods()
    local byUid = {}
    for _, m in mods do byUid[m.uid] = m end
    local function SetMods(list)
        table.sort(list)
        S.setup.mods = list
        S.profile = ''
        PS.Remember(S.setup, S.keep)
        Open()
    end
    d:Label('Mods to play with (AI mods come along with their AI)', 14, y, { color = c.textDim })
    y = y + 22
    if table.getn(mods) == 0 then
        d:Label('no other sim mods are installed', 14, y, { color = c.textDim, size = 'small' })
        y = y + 22
    elseif table.getn(mods) <= SHORT_LIST then
        for _, m in mods do
            local uid = m.uid
            modButtons[uid] = d:Button(m.name, 14, y, 482, 24, function()
                local list = {}
                local had = false
                for _, u in S.setup.mods do
                    if u == uid then had = true else table.insert(list, u) end
                end
                if not had then table.insert(list, uid) end
                table.sort(list)
                S.setup.mods = list
                Custom()
                Refresh()
            end, { tip = Tip('play mod') })
            y = y + 28
        end
    else
        d:Button('Add a mod...', 14, y, 160, 24, function()
            local names, uidOf = {}, {}
            for _, m in mods do
                local shown = m.name
                if uidOf[shown] then shown = shown .. ' (' .. m.uid .. ')' end
                uidOf[shown] = m.uid
                table.insert(names, shown)
            end
            PS.Remember(S.setup, S.keep)
            import('/lua/editor/gui/browser.lua').OpenNames{ title = 'Add a mod to the test run', names = names, done = function(name)
                local list = {}
                local have = false
                for _, u in S.setup.mods do
                    table.insert(list, u)
                    if u == uidOf[name] then have = true end
                end
                if uidOf[name] and not have then table.insert(list, uidOf[name]) end
                SetMods(list)
            end }
        end, { tip = Tip('add a mod') })
        y = y + 28
        local chosen = 0
        for _, uid in S.setup.mods do
            local gone = uid
            local entry = byUid[uid]
            chosen = chosen + 1
            d:Button('Remove: ' .. (entry and entry.name or uid), 14, y, 482, 24, function()
                local list = {}
                for _, u in S.setup.mods do
                    if u ~= gone then table.insert(list, u) end
                end
                SetMods(list)
            end, { tip = Tip('remove a mod') })
            y = y + 28
        end
        if chosen == 0 then
            d:Label('no mods chosen', 14, y, { color = c.textDim, size = 'small' })
            y = y + 22
        end
    end
    y = y + 6

    problems = d:Label('', 14, y, { color = c.error, size = 'small' })
    status = d:Label('', 14, y + 18, { color = c.textDim, size = 'small' })
    y = y + 44
    d:Button('Play', 14, y, 110, 28, function()
        PS.Remember(S.setup, S.keep)
        Dialog.Close()
        import('/lua/editor/ui.lua').Play()
    end, { tip = Tip('play now') })
    d:Button('Close', 130, y, 110, 28, function() Dialog.Close() end, { tip = Tip('close play setup') })
    Refresh()
    return d
end
