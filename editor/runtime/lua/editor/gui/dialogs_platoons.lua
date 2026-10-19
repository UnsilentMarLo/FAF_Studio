-- The platoon builder dialog (Platoons panel > Builders > Edit): platoon template, type, priority, instance count, time-out, location, "requires construction", the AI function (file and
-- function) and the build conditions (file, function, arguments). Every change is one undo step (platoons.lua). Logic: platoons.lua.
--
--   EditBuilder(army, name, onClose)
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local PL = import('/lua/editor/platoons.lua')

local function Cycle(list, current)
    for i, v in list do
        if v == current then return list[math.mod(i, table.getn(list)) + 1] end
    end
    return list[1]
end

local function Condition(army, name, index, done)
    local b = PL.Builders(army)[name]
    local c = b and b.BuildConditions and b.BuildConditions[index]
    if not c then return end
    local d = Dialog.Open('Build condition ' .. index .. ' of ' .. name, 520, 230)
    local col = Skin.color
    d:Label('File', 14, 40, { color = col.textDim })
    local file = d:Field(110, 36, 396, 22, { text = tostring(c[1] or '') })
    d:Label('Function', 14, 74, { color = col.textDim })
    local fn = d:Field(110, 70, 396, 22, { text = tostring(c[2] or '') })
    d:Label('Arguments', 14, 108, { color = col.textDim })
    local args = d:Field(110, 104, 396, 22, { text = PL.ArgsToText(c[3]) })
    d:Label('Arguments are separated by commas, e.g. MAIN, 4 (the condition function gets them after the AI brain).', 14, 136, { color = col.textDim, size = 'small' })
    d:Button('OK', 14, 190, 90, 28, function()
        if file:GetText() ~= tostring(c[1] or '') then PL.SetCondition(army, name, index, 'file', file:GetText()) end
        if fn:GetText() ~= tostring(c[2] or '') then PL.SetCondition(army, name, index, 'fn', fn:GetText()) end
        if args:GetText() ~= PL.ArgsToText(c[3]) then PL.SetCondition(army, name, index, 'args', args:GetText()) end
        Dialog.Close()
        done()
    end)
    d:Button('Cancel', 114, 190, 90, 28, function() Dialog.Close() done() end)
    fn:AcquireFocus()
end

function EditBuilder(army, name, onClose)
    local b = function() return PL.Builders(army) and PL.Builders(army)[name] end
    if not b() then return end
    local d = Dialog.Open('Platoon builder ' .. name .. '  (army ' .. army .. ')', 560, 520, onClose)
    local c = Skin.color
    local state = { cond = 1 }
    local list

    local function Reopen() EditBuilder(army, name, onClose) end

    -- template
    d:Label('Platoon template', 14, 44, { color = c.textDim })
    local template = d:Button(tostring(b().PlatoonTemplate ~= '' and b().PlatoonTemplate or '(choose)'), 140, 40, 400, 24, function(self)
        local D = import('/lua/editor/gui/dialogs_mission.lua')
        D.PickName('Platoon template', PL.PlatoonNames(), b().PlatoonTemplate, function(t)
            PL.SetBuilder(army, name, 'PlatoonTemplate', t)
            Reopen()
        end)
    end)
    d:Label('Platoon type', 14, 76, { color = c.textDim })
    d:Button(tostring(b().PlatoonType or 'Any'), 140, 72, 130, 24, function(self)
        PL.SetBuilder(army, name, 'PlatoonType', Cycle(PL.PLATOON_TYPES, b().PlatoonType or 'Any'))
        self:SetText(tostring(b().PlatoonType))
    end)
    d:Label('Builds from a factory', 290, 76, { color = c.textDim })
    d:Button(b().RequiresConstruction and 'yes' or 'no (forms from existing units)', 420, 72, 120, 24, function(self)
        PL.SetBuilder(army, name, 'RequiresConstruction', not b().RequiresConstruction)
        self:SetText(b().RequiresConstruction and 'yes' or 'no (forms from existing units)')
    end)

    local function Slider(label, key, min, max, step, x, y, w, curve)
        local s = W.Slider(d.group, { label = label, min = min, max = max, step = step, fmt = '%d', compact = true, curve = curve,
            get = function() return tonumber(b()[key]) or min end,
            set = function(v) PL.SetBuilder(army, name, key, v, true) end })
        s:Place(Skin.S(x), Skin.S(y), Skin.S(w))
        for _, ctl in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do d:Raise(ctl) end
        d:Raise(s.field) d:Raise(s.field.frame)
        return s
    end
    Slider('Priority (higher forms first)', 'Priority', 0, 1000, 1, 14, 108, 250, 2)
    Slider('Instances at the same time', 'InstanceCount', 1, 20, 1, 290, 108, 250)
    Slider('Time-out in seconds (-1 = automatic)', 'BuildTimeOut', -1, 600, 1, 14, 158, 250)

    d:Label('Location', 290, 164, { color = c.textDim })
    local loc = d:Field(350, 160, 190, 22, { text = tostring(b().LocationType or 'MAIN'),
        onEnter = function(text) PL.SetBuilder(army, name, 'LocationType', text) end })

    -- AI function
    local ai = b().PlatoonAIFunction or { '', '' }
    d:Label('Platoon AI', 14, 212, { color = c.textDim })
    local aiFile = d:Field(100, 208, 280, 22, { text = tostring(ai[1] or ''), onEnter = function(text) PL.SetBuilder(army, name, 'AIFile', text) end })
    local aiFn = d:Field(388, 208, 152, 22, { text = tostring(ai[2] or ''), onEnter = function(text) PL.SetBuilder(army, name, 'AIFunction', text) end })
    d:Label('file (e.g. /lua/ScenarioPlatoonAI.lua) and function', 100, 232, { color = c.textDim, size = 'small' })

    -- build conditions
    d:Label('Build conditions', 14, 262, { color = c.textDim })
    list = W.VirtualList(d.group, {
        extra = true, rowH = 22,
        getCount = function() return table.getn(b().BuildConditions or {}) end,
        bind = function(row, index)
            local cond = (b().BuildConditions or {})[index]
            if not cond then return end
            local file = string.gsub(tostring(cond[1] or ''), '^.*/', '')
            W.Fit(row.text, index .. '   ' .. file .. ' : ' .. tostring(cond[2]), math.max(Skin.S(40), row.bg.Width() - Skin.S(130)))
            row.text:SetColor(index == state.cond and c.accent or c.text)
            row.extra:SetText(PL.ArgsToText(cond[3]))
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index) state.cond = index list:Refresh() end,
        bgColor = c.panelAlt,
    })
    list:SetRect(Skin.S(14), Skin.S(284), Skin.S(526), Skin.S(130))
    d:Button('Add...', 14, 422, 80, 26, function()
        local n = PL.AddCondition(army, name, '/lua/editor/miscbuildconditions.lua', '', '')
        state.cond = n
        Condition(army, name, n, Reopen)
    end)
    d:Button('Edit...', 104, 422, 80, 26, function()
        if (b().BuildConditions or {})[state.cond] then Condition(army, name, state.cond, Reopen) end
    end)
    d:Button('Remove', 194, 422, 80, 26, function()
        if PL.RemoveCondition(army, name, state.cond) then state.cond = math.max(1, state.cond - 1) end
        list:Refresh()
    end)
    d:Label('Priority and conditions decide when the campaign AI forms the platoon; an AI function runs on it once it exists.', 14, 456, { color = c.textDim, size = 'small' })
    d:Button('Done', 14, 482, 100, 28, function()
        local cur = b()
        local curAi = cur and cur.PlatoonAIFunction or {}
        if cur and loc:GetText() ~= tostring(cur.LocationType or 'MAIN') then PL.SetBuilder(army, name, 'LocationType', loc:GetText()) end
        if cur and aiFile:GetText() ~= tostring(curAi[1] or '') then PL.SetBuilder(army, name, 'AIFile', aiFile:GetText()) end
        if cur and aiFn:GetText() ~= tostring(curAi[2] or '') then PL.SetBuilder(army, name, 'AIFunction', aiFn:GetText()) end
        Dialog.Close()
    end)
end
