-- Mission dialogs: the node palette (add a node to a stage or into a trigger), the node editor, the base / attack editors (Bases panel) and the pickers they use for
-- armies, groups, chains, areas, markers, units, bases and variables. All editors are built by Form: a list of parameters (the same kinds as the node catalogue) plus
-- get / set callbacks. One dialog is open at a time, so a picker closes the editor and opens it again with the chosen value.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local M = import('/lua/editor/mission.lua')
local B = import('/lua/editor/mbase.lua')
local Army = import('/lua/editor/armysetup.lua')

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = Copy(v) end
    return c
end

--- A list of names to choose from: done(name) with the choice, or nothing when the dialog is closed another way.
function PickName(title, names, current, done)
    -- a long list is browsed by category (prefix / first letter), not scrolled (browser.lua)
    if table.getn(names) >= 24 then
        import('/lua/editor/gui/browser.lua').OpenNames{ title = title, names = names, current = current, done = done }
        return
    end
    local d = Dialog.Open(title, 380, 380)
    local c = Skin.color
    local state = { shown = names }
    local list
    local field = d:Field(14, 30, 352, 22, {
        onChange = function(text)
            local f = string.lower(text or '')
            state.shown = {}
            for _, n in names do
                if f == '' or string.find(string.lower(n), f, 1, true) then table.insert(state.shown, n) end
            end
            list:Refresh()
        end,
        onEscape = function() Dialog.Close() end,
    })
    list = W.VirtualList(d.group, {
        rowH = 22,
        getCount = function() return table.getn(state.shown) end,
        bind = function(row, index)
            local n = state.shown[index]
            W.Fit(row.text, n, math.max(Skin.S(40), row.bg.Width() - Skin.S(16)))
            row.text:SetColor(n == current and c.accent or c.text)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local n = state.shown[index]
            if n then Dialog.Close() done(n) end
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(58), Skin.S(364), Skin.S(316))
    if table.getn(names) == 0 then d:Label('Nothing to choose from yet.', 14, 70, { color = c.textDim }) end
    field:AcquireFocus()
end

--- Several names from a list: a click toggles one; done(list) when Done is pressed.
function PickMulti(title, names, current, done)
    local d = Dialog.Open(title, 380, 420)
    local c = Skin.color
    local chosen = {}
    for _, n in current or {} do chosen[n] = true end
    local list
    list = W.VirtualList(d.group, {
        rowH = 22,
        getCount = function() return table.getn(names) end,
        bind = function(row, index)
            local n = names[index]
            W.Fit(row.text, (chosen[n] and '[x]  ' or '[   ]  ') .. n, math.max(Skin.S(40), row.bg.Width() - Skin.S(16)))
            row.text:SetColor(chosen[n] and c.accent or c.text)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local n = names[index]
            if n then chosen[n] = not chosen[n] list:Refresh() end
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(30), Skin.S(364), Skin.S(340))
    if table.getn(names) == 0 then d:Label('Nothing to choose from yet.', 14, 42, { color = c.textDim }) end
    d:Button('Done', 14, 384, 100, 26, function()
        local result = {}
        for _, n in names do if chosen[n] then table.insert(result, n) end end
        Dialog.Close()
        done(result)
    end)
    d:Button('Cancel', 124, 384, 100, 26, function() Dialog.Close() end)
end

--- Asks for a name (letters, digits, _): done(name) when confirmed.
function NameDialog(title, hint, done)
    local d = Dialog.Open(title, 360, 130)
    d:Label(hint, 14, 34, { color = Skin.color.textDim, size = 'small' })
    local field = d:Field(14, 56, 330, 22, { text = '' })
    d:Button('OK', 14, 92, 90, 28, function()
        local name = field:GetText()
        Dialog.Close()
        if name and name ~= '' then done(name) end
    end)
    d:Button('Cancel', 114, 92, 90, 28, function() Dialog.Close() end)
    field:AcquireFocus()
end

--- The group the Unit tool puts units into: the groups of the army, or a new one.
function PickGroup(army, done)
    local Units = import('/lua/editor/units.lua')
    local names = Units.Groups(army)
    table.insert(names, '(new group...)')
    PickName('Unit group of ' .. tostring(army), names, Units.Group, function(name)
        if name == '(new group...)' then
            NameDialog('New unit group', 'Name (letters, digits, _), e.g. WAVE1', function(n)
                if string.find(n, '[^%w_]') then Say('group names take letters, digits and _ only') return end
                done(n)
            end)
        else
            done(name)
        end
    end)
end

local function Summary(node)
    local t = M.NodeType(node.type)
    if not t then return tostring(node.type) end
    local parts = {}
    for _, p in t.params do
        local v = node[p.key]
        if v ~= nil and v ~= '' and p.kind ~= 'bool' and type(v) ~= 'table' and table.getn(parts) < 3 then table.insert(parts, tostring(v)) end
    end
    local text = t.title .. (table.getn(parts) > 0 and (': ' .. table.concat(parts, ' / ')) or '')
    if t.container then text = text .. '  (' .. table.getn(node.children or {}) .. ')' end
    return text
end
NodeSummary = Summary

-- ---- the generic parameter form ------------------------------------------------------------------------------------------------------------------

local PICKERS = {
    army = function() return Army.Names() end,
    chain = function() return M.ChainNames() end,
    area = function() return M.AreaNames() end,
    marker = function() return M.MarkerNames() end,
    base = function() return M.BaseNames() end,
    dialogue = function() return M.DialogueNames() end,
    platoon = function() return import('/lua/editor/platoons.lua').PlatoonNames() end,
    orders = function() return import('/lua/editor/platoons.lua').OrderNames() end,
}

local function RowHeight(p)
    if p.kind == 'diff3' then return 56 end
    if p.kind == 'number' or p.kind == 'text' then return 50 end
    return 32
end

local function AddSlider(d, opts, x, y, w)
    local slider = W.Slider(d.group, opts)
    slider:Place(Skin.S(x), Skin.S(y), Skin.S(w))
    for _, c2 in { slider.label, slider.track, slider.fill, slider.thumb } do d:Raise(c2) end
    d:Raise(slider.field) d:Raise(slider.field.frame)
    return slider
end

local function MultiText(list)
    local n = table.getn(list or {})
    if n == 0 then return '(none)' end
    local text = table.concat(list, ', ')
    if string.len(text) > 28 then text = n .. ' chosen' end
    return text
end

--- A dialog with a field per parameter. o = { title, params, get(key) -> value, set(key, value, merge), names(p) -> list or nil (pickers that depend on other values),
--- reopen() (called after a picker), onClose(), extra = { { text, width, fn }, ... } (more buttons beside Done), width }.
function Form(o)
    local width = o.width or 520
    local height = 56
    for _, p in o.params do height = height + RowHeight(p) end
    height = height + 40
    local d = Dialog.Open(o.title, width, height)
    local c = Skin.color
    local y = 34
    local x2 = width - 220
    local inner = width - 28
    for _, loopParam in o.params do
        local p = loopParam      -- the pickers below run later: a closure over the loop variable itself sees nil once the loop is over
        local key = p.key
        local current = o.get(key)
        if p.kind == 'text' then
            d:Label(p.label, 14, y, { color = c.textDim, size = 'small' })
            d:Field(14, y + 18, inner, 22, { text = tostring(current or ''), onChange = function(text) o.set(key, text, true) end })
        elseif p.kind == 'number' then
            AddSlider(d, { label = p.label, min = p.min or 0, max = p.max or 100, step = (p.max or 100) <= 100 and 1 or 5, fmt = '%d', compact = true,
                get = function() return tonumber(o.get(key)) or p.default or 0 end,
                set = function(v) o.set(key, v, true) end }, 14, y, 300)
        elseif p.kind == 'diff3' then
            local each = math.floor((inner - 12) / 3)
            local names = { 'easy', 'normal', 'hard' }
            d:Label(p.label, 14, y - 4, { color = c.textDim, size = 'small' })
            for i = 1, 3 do
                AddSlider(d, { label = names[i], min = p.min or 0, max = p.max or 100, step = (p.max or 100) <= 100 and 1 or 5, fmt = '%d', compact = true,
                    get = function() local v = o.get(key) return tonumber(type(v) == 'table' and v[i]) or (p.default and p.default[i]) or 0 end,
                    set = function(val)
                        local v = Copy(o.get(key))
                        if type(v) ~= 'table' then v = Copy(p.default) or { 0, 0, 0 } end
                        v[i] = val
                        o.set(key, v, true)
                    end }, 14 + (i - 1) * (each + 6), y + 14, each)
            end
        elseif p.kind == 'bool' then
            d:Label(p.label, 14, y + 4, { color = c.text })
            local b
            b = d:Button(current and 'Yes' or 'No', x2, y, 80, 24, function(self)
                o.set(key, self.on and true or false)
                self:SetText(self.on and 'Yes' or 'No')
            end, { toggle = true })
            b:SetOn(current and true or false)
        elseif p.kind == 'choice' then
            d:Label(p.label, 14, y + 4, { color = c.text })
            d:Button(tostring(current or p.default or p.choices[1]), x2, y, 200, 24, function(self)
                local cur, at = o.get(key) or p.default or p.choices[1], 1
                for i, ch in p.choices do if ch == cur then at = i end end
                local nextValue = p.choices[math.mod(at, table.getn(p.choices)) + 1]
                o.set(key, nextValue)
                self:SetText(tostring(nextValue))
            end)
        elseif p.kind == 'multi' then
            d:Label(p.label, 14, y + 4, { color = c.text })
            d:Button(MultiText(current), x2, y, 200, 24, function()
                local names = o.names and o.names(p)
                if not names and type(p.choices) == 'table' then names = p.choices end
                PickMulti('Choose: ' .. string.lower(p.label), names or {}, o.get(key), function(list)
                    o.set(key, list)
                    o.reopen()
                end)
            end)
        elseif p.kind == 'var' and p.defines then
            d:Label(p.label, 14, y + 4, { color = c.text })
            d:Field(x2, y + 1, 200, 22, { text = tostring(current or ''), onChange = function(text) o.set(key, text, true) end })
        else
            -- a name from the map: army, group (of the node's army), chain, area, marker, unit, base, var (set earlier)
            d:Label(p.label, 14, y + 4, { color = c.text })
            d:Button((current and current ~= '') and tostring(current) or '(choose)', x2, y, 200, 24, function()
                local names = o.names and o.names(p)
                if not names and PICKERS[p.kind] then names = PICKERS[p.kind]() end
                names = names or {}
                if p.optional then
                    local withNone = { '(none)' }
                    for _, n in names do table.insert(withNone, n) end
                    names = withNone
                end
                PickName('Choose ' .. string.lower(p.label), names, current, function(name)
                    o.set(key, name == '(none)' and '' or name)
                    o.reopen()
                end)
            end)
        end
        y = y + RowHeight(p)
    end
    d:Button('Done', 14, height - 36, 100, 26, function() Dialog.Close() if o.onClose then o.onClose() end end)
    local bx = 124
    for _, e in o.extra or {} do
        d:Button(e[1], bx, height - 36, e[2] or 110, 26, e[3])
        bx = bx + (e[2] or 110) + 6
    end
end

-- ---- nodes ----------------------------------------------------------------------------------------------------------------------------------------

--- The palette: every node type of the catalogue; the chosen one is added to `section` of the stage (into the container node at `parent`, when given) and opened in the editor.
--- `after(path)` is told where it went.
function AddNode(stage, section, after, parent)
    local d = Dialog.Open('Add a node to ' .. (parent and 'the trigger' or section), 460, 440)
    local c = Skin.color
    local all = {}
    for _, t in M.Catalogue do
        if not (t.family == 'objective' and section ~= 'ready') then table.insert(all, t) end
    end
    local list = W.VirtualList(d.group, {
        rowH = 24, extra = true,
        getCount = function() return table.getn(all) end,
        bind = function(row, index)
            local t = all[index]
            W.Fit(row.text, t.title, math.max(Skin.S(40), row.bg.Width() - Skin.S(110)))
            row.text:SetColor(t.container and c.accent or c.text)
            row.extra:SetText(t.family)
            row.extra:SetColor((t.family == 'objective' or t.family == 'trigger') and c.accent or c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local t = all[index]
            if not t then return end
            local ok, path = M.AddNode(stage, section, t.id, nil, parent)
            Dialog.Close()
            if not ok then Say('mission: ' .. tostring(path)) return end
            if after then after(path) end
            if table.getn(t.params) > 0 then EditNode(stage, section, path, function() if after then after(path) end end) end
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(30), Skin.S(444), Skin.S(370))
    d:Button('Cancel', 360, 408, 90, 26, function() Dialog.Close() end)
end

--- Every parameter of a node. Text parameters are fields (applied while typing, one undo step per field), numbers sliders, choices cycle on click,
--- names open a picker.
function EditNode(stage, section, path, onClose)
    local function Node()
        local _, _, n = M.LocateNode(stage, section, path)
        return n
    end
    local node = Node()
    local t = node and M.NodeType(node.type)
    if not t then return end
    Form{
        title = t.title .. '  (stage ' .. stage .. ', ' .. section .. ')',
        params = t.params,
        get = function(key) local n = Node() return n and n[key] end,
        set = function(key, value, merge) M.SetParam(stage, section, path, key, value, merge) end,
        names = function(p)
            local n = Node() or {}
            if p.kind == 'group' then return M.GroupNames(n.army or '') end
            if p.kind == 'unit' then return M.UnitNames(n.army or '') end
            if p.kind == 'builder' then return import('/lua/editor/platoons.lua').BuilderNames(n.army or '') end
            if p.kind == 'marker' and p.mtype then return M.MarkerNames(p.mtype) end
            if p.kind == 'var' then return M.DefinedVars(stage, section, path, p.vtype) end
            return nil
        end,
        reopen = function() EditNode(stage, section, path, onClose) end,
        onClose = onClose,
    }
end

-- ---- bases ----------------------------------------------------------------------------------------------------------------------------------------

--- "Define base from an area": army, area and name in three steps; the units of the army inside the area become the base.
function DefineBase(done)
    PickName('Army of the base', Army.Names(), nil, function(army)
        PickName('Area that holds the base', M.AreaNames(), nil, function(area)
            NameDialog('Base name', 'Letters, digits, _ (e.g. NorthBase)', function(name)
                local ok, why = B.DefineFromArea(name, army, area)
                if not ok then Say('base: ' .. tostring(why)) return end
                Say('base ' .. name .. ' defined: ' .. tostring(why) .. ' units in its group')
                if done then done(name) end
            end)
        end)
    end)
end

--- A base with no units yet (engineers build it, or groups are added later).
function NewBase(done)
    PickName('Army of the base', Army.Names(), nil, function(army)
        NameDialog('Base name', 'Letters, digits, _ (e.g. EastExpansion)', function(name)
            local ok, why = B.AddBase(name, army)
            if not ok then Say('base: ' .. tostring(why)) return end
            if done then done(name) end
        end)
    end)
end

--- The groups a base builds, with their priorities.
function BaseGroups(i, onClose)
    local base = B.Bases()[i]
    if not base then return end
    local d = Dialog.Open('Build groups of base ' .. tostring(base.name), 440, 330)
    local c = Skin.color
    local state = { sel = 1 }
    local slider
    local list
    local function Groups() return (B.Bases()[i] or {}).groups or {} end
    list = W.VirtualList(d.group, {
        rowH = 22, extra = true,
        getCount = function() return table.getn(Groups()) end,
        bind = function(row, index)
            local g = Groups()[index]
            if not g then return end
            W.Fit(row.text, g.name, math.max(Skin.S(40), row.bg.Width() - Skin.S(90)))
            row.text:SetColor(index == state.sel and c.accent or c.text)
            row.extra:SetText('priority ' .. tostring(g.priority))
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index) state.sel = index list:Refresh() slider:Refresh() end,
    })
    list:SetRect(Skin.S(8), Skin.S(30), Skin.S(424), Skin.S(140))
    slider = AddSlider(d, { label = 'Priority of the selected group (higher is built first; 0 = not spawned at the start)', min = 0, max = 200, step = 5, fmt = '%d', compact = true,
        get = function() local g = Groups()[state.sel] return g and tonumber(g.priority) or 0 end,
        set = function(v) if Groups()[state.sel] then B.SetGroupPriority(i, state.sel, v, true) list:Refresh() end end }, 14, 180, 400)
    d:Button('Add group...', 14, 250, 110, 26, function()
        local names = {}
        for _, n in M.GroupNames(base.army or '') do
            local have = false
            for _, g in Groups() do if g.name == n then have = true end end
            if not have then table.insert(names, n) end
        end
        PickName('Add a group of ' .. tostring(base.army), names, nil, function(name)
            B.AddGroup(i, name, 100)
            BaseGroups(i, onClose)
        end)
    end)
    d:Button('Remove', 134, 250, 90, 26, function()
        if Groups()[state.sel] then B.RemoveGroup(i, state.sel) state.sel = math.max(1, state.sel - 1) list:Refresh() slider:Refresh() end
    end)
    d:Button('Done', 14, 292, 100, 26, function() Dialog.Close() if onClose then onClose() end end)
end

--- The attacks (OpAI) of a base.
function BaseAttacks(i, onClose)
    local base = B.Bases()[i]
    if not base then return end
    local d = Dialog.Open('Attacks of base ' .. tostring(base.name), 480, 330)
    local c = Skin.color
    local state = { sel = 1 }
    local list
    local function Ops() return (B.Bases()[i] or {}).opai or {} end
    list = W.VirtualList(d.group, {
        rowH = 22, extra = true,
        getCount = function() return table.getn(Ops()) end,
        bind = function(row, index)
            local o = Ops()[index]
            if not o then return end
            W.Fit(row.text, tostring(o.name) .. ': ' .. MultiText(o.children), math.max(Skin.S(40), row.bg.Width() - Skin.S(150)))
            row.text:SetColor(index == state.sel and c.accent or c.text)
            row.extra:SetText(tostring(o.ptype))
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index) state.sel = index list:Refresh() end,
    })
    list:SetRect(Skin.S(8), Skin.S(30), Skin.S(464), Skin.S(190))
    d:Button('Add', 14, 232, 80, 26, function()
        local ok, at = B.AddOpAI(i)
        if ok then Dialog.Close() AttackEdit(i, at, function() BaseAttacks(i, onClose) end) end
    end)
    d:Button('Edit...', 104, 232, 80, 26, function()
        if Ops()[state.sel] then Dialog.Close() AttackEdit(i, state.sel, function() BaseAttacks(i, onClose) end) end
    end)
    d:Button('Remove', 194, 232, 80, 26, function()
        if Ops()[state.sel] then B.RemoveOpAI(i, state.sel) state.sel = math.max(1, state.sel - 1) list:Refresh() end
    end)
    d:Button('Done', 14, 290, 100, 26, function() Dialog.Close() if onClose then onClose() end end)
end

--- One attack: family, platoon kinds, size per difficulty, orders, priority, locking; the conditions in a second form.
function AttackEdit(i, oi, onClose)
    local function Op() local b = B.Bases()[i] return b and b.opai[oi] end
    if not Op() then return end
    local function Names(p)
        if p.choices == 'children' then return B.ChildKinds(Op().ptype) end
        if p.choices == 'chains' then return M.ChainNames() end
        return nil
    end
    local function Params(list)
        local out = {}
        for _, p in list do
            local q = {}
            for k, v in p do q[k] = v end
            if q.choices == 'children' or q.choices == 'chains' then q.choices = nil end
            table.insert(out, q)
        end
        return out
    end
    Form{
        title = 'Attack ' .. tostring(Op().name),
        params = Params(B.OpAIBasics),
        get = function(key) local o = Op() return o and o[key] end,
        set = function(key, value, merge) B.SetOpAI(i, oi, key, value, merge) end,
        names = function(p)
            if p.key == 'children' then return B.ChildKinds(Op().ptype) end
            if p.key == 'chains' then return M.ChainNames() end
            return nil
        end,
        reopen = function() AttackEdit(i, oi, onClose) end,
        onClose = onClose,
        extra = { { 'Conditions...', 120, function() Dialog.Close() AttackConditions(i, oi, onClose) end } },
    }
end

function AttackConditions(i, oi, onClose)
    local function Op() local b = B.Bases()[i] return b and b.opai[oi] end
    if not Op() then return end
    Form{
        title = 'Conditions of attack ' .. tostring(Op().name),
        params = B.OpAIConditions,
        get = function(key) local o = Op() return o and o[key] end,
        set = function(key, value, merge) B.SetOpAI(i, oi, key, value, merge) end,
        reopen = function() AttackConditions(i, oi, onClose) end,
        onClose = function() AttackEdit(i, oi, onClose) end,
    }
end

--- A base: army, marker, radius, difficulty groups, start mode, engineers; groups, attacks and details in their own dialogs.
function BaseEdit(i, onClose)
    local function Base() return B.Bases()[i] end
    if not Base() then return end
    local function Again() BaseEdit(i, onClose) end
    Form{
        title = 'Base ' .. tostring(Base().name),
        params = B.BaseBasics,
        get = function(key) local b = Base() return b and b[key] end,
        set = function(key, value, merge) B.SetField(i, key, value, merge) end,
        reopen = Again,
        onClose = onClose,
        extra = {
            { 'Groups...', 100, function() Dialog.Close() BaseGroups(i, Again) end },
            { 'Attacks...', 100, function() Dialog.Close() BaseAttacks(i, Again) end },
            { 'Details...', 100, function() Dialog.Close() BaseDetails(i, Again) end },
        },
    }
end

function BaseDetails(i, onClose)
    local function Base() return B.Bases()[i] end
    if not Base() then return end
    Form{
        title = 'Details of base ' .. tostring(Base().name),
        params = B.BaseDetails,
        get = function(key) local b = Base() return b and b[key] end,
        set = function(key, value, merge) B.SetField(i, key, value, merge) end,
        reopen = function() BaseDetails(i, onClose) end,
        onClose = onClose,
    }
end

-- ---- dialogues (Strings panel) ------------------------------------------------------------------------------------------------------------------------

local LINE_PARAMS = {
    { key = 'text', label = 'Text', kind = 'text' },
    { key = 'speaker', label = 'Speaker (shown before the text, optional)', kind = 'text' },
    { key = 'seconds', label = 'Shown for (seconds)', kind = 'number', default = 5, min = 1, max = 60 },
    { key = 'bank', label = 'Voice-over sound bank (optional, e.g. XGG)', kind = 'text' },
    { key = 'cue', label = 'Voice-over cue (optional)', kind = 'text' },
    { key = 'vid', label = 'Video of /movies (optional, e.g. UEF_Commander.sfd)', kind = 'text' },
    { key = 'faction', label = 'Portrait faction (optional: UEF, Aeon, Cybran, Seraphim)', kind = 'text' },
}

--- One line of a dialogue.
function LineEdit(i, li, onClose)
    local function Line() local d = M.Data.dialogues and M.Data.dialogues[i] return d and d.lines[li] end
    if not Line() then return end
    Form{
        title = 'Dialogue line ' .. li,
        params = LINE_PARAMS,
        get = function(key) local l = Line() return l and l[key] end,
        set = function(key, value, merge) M.SetLine(i, li, key, value, merge) end,
        reopen = function() LineEdit(i, li, onClose) end,
        onClose = onClose,
    }
end

--- The lines of a dialogue: add, edit, remove, reorder.
function DialogueLines(i, onClose)
    local d0 = M.Data.dialogues and M.Data.dialogues[i]
    if not d0 then return end
    local d = Dialog.Open('Dialogue ' .. tostring(d0.name), 500, 340)
    local c = Skin.color
    local state = { sel = 1 }
    local list
    local function Lines() local dd = M.Data.dialogues and M.Data.dialogues[i] return dd and dd.lines or {} end
    list = W.VirtualList(d.group, {
        rowH = 22, extra = true,
        getCount = function() return table.getn(Lines()) end,
        bind = function(row, index)
            local l = Lines()[index]
            if not l then return end
            local text = ((l.speaker and l.speaker ~= '') and (l.speaker .. ': ') or '') .. tostring(l.text or '')
            W.Fit(row.text, text, math.max(Skin.S(40), row.bg.Width() - Skin.S(70)))
            row.text:SetColor(index == state.sel and c.accent or c.text)
            row.extra:SetText(tostring(l.seconds) .. ' s')
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index) state.sel = index list:Refresh() end,
    })
    list:SetRect(Skin.S(8), Skin.S(30), Skin.S(484), Skin.S(220))
    local function Reopen() DialogueLines(i, onClose) end
    d:Button('Add line', 14, 262, 84, 26, function()
        local ok, at = M.AddLine(i, 'Text')
        if ok then Dialog.Close() LineEdit(i, at, Reopen) end
    end)
    d:Button('Edit...', 106, 262, 70, 26, function()
        if Lines()[state.sel] then Dialog.Close() LineEdit(i, state.sel, Reopen) end
    end)
    d:Button('Remove', 184, 262, 70, 26, function()
        if Lines()[state.sel] then M.RemoveLine(i, state.sel) state.sel = math.max(1, state.sel - 1) list:Refresh() end
    end)
    d:Button('Up', 262, 262, 44, 26, function() if M.MoveLine(i, state.sel, -1) then state.sel = state.sel - 1 list:Refresh() end end)
    d:Button('Down', 312, 262, 54, 26, function() if M.MoveLine(i, state.sel, 1) then state.sel = state.sel + 1 list:Refresh() end end)
    d:Button('Done', 14, 302, 100, 26, function() Dialog.Close() if onClose then onClose() end end)
end
