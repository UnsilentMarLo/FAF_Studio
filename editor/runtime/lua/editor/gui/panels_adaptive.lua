-- The adaptive map panels (model: adaptive.lua; natives: upstream's adaptive text model, moho/editor/EdUpAdaptiveLua.cpp):
--
--   "Adaptive map"   the setup as a list: the files, max players, which resources spawn with which army, the option tables' groups, the crazyrush lists, and what becomes of the
--                    selected unit (its group, the lobby settings that bring it into a game, its wreck's value). Buttons act on the chosen row and on the markers / units selected in the world.
--   "Lobby options"  the setup by what the player picks (the same panel in a window: View > Adaptive map window): every lobby option in the lobby's order with its choices and what
--                    each puts on the map (+ 2 mexes, wrecks of a level, the groups the script makes); add / remove / rename choices, make one the default, delete the option.
--
-- Each change is written at once as one undo step and goes into `_tables.lua` / `_options.lua` with the map (adaptive.lua).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Adaptive = import('/lua/editor/adaptive.lua')
local History = import('/lua/editor/history.lua')

live = {}

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Count(t) return table.getn(t or {}) end

local function Plural(n, one, many)
    return n .. ' ' .. (n == 1 and one or many)
end

local function SelectMarkers(names)
    local Tools = import('/lua/editor/tools.lua')
    local list = {}
    for _, n in names do table.insert(list, { kind = 'marker', name = n }) end
    Tools.SelectMany(list, false)
end

local function Join(a, b)
    local out = {}
    for _, v in a do table.insert(out, v) end
    for _, v in b do table.insert(out, v) end
    return out
end

local function Join2(list, sep)
    local out = ''
    for i, v in list do out = out .. (i > 1 and sep or '') .. tostring(v) end
    return out
end

-- ---- the shared list-and-buttons panel ------------------------------------------------------------------------------------------------------------------
-- cfg: { id, rowsFn() -> rows, stampFn() -> text, buttons = { { label, tip, kinds = { kind = true }, run = function(P, row) } }, status = function(P, row) -> text }
-- A row: { text, extra, kind, data, color }.

local function BuildList(group, host, cfg)
    local P = { rows = {}, sel = 1, stamp = false, buttons = {} }
    local c = Skin.color
    P.list = W.VirtualList(group, {
        extra = true, rowH = 22,
        getCount = function() return Count(P.rows) end,
        bind = function(row, index)
            local r = P.rows[index]
            if not r then return end
            local color = r.color or ((r.kind == 'header') and c.textDim or (index == P.sel and c.accent or c.text))
            W.Fit(row.text, r.text, math.max(Skin.S(30), row.bg.Width() - Skin.S(90)))
            row.text:SetColor(color)
            row.extra:SetText(r.extra or '')
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local r = P.rows[index]
            if r and r.kind ~= 'header' then P.sel = index end
            P:Refresh(true)
        end,
        bgColor = c.panel,
    })
    for _, def in cfg.buttons do
        local d = def
        local len = string.len(d.label)
        local b = W.Button(group, d.label, 0, 0, math.max(Skin.S(54), Skin.S(7) * len + Skin.S(16)), Skin.S(22), function()
            local row = P.rows[P.sel]
            local ok, a, b2 = pcall(d.run, P, row)
            if not ok then Say('adaptive: ' .. tostring(a)) elseif a == false then Say('adaptive: ' .. tostring(b2)) end
            P:Refresh(true)
        end, { tip = d.tip })
        table.insert(P.buttons, { button = b, def = d, w = math.max(Skin.S(54), Skin.S(7) * len + Skin.S(16)) })
    end
    P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

    local function Rebuild()
        P.rows = cfg.rowsFn(P)
        if P.sel > Count(P.rows) then P.sel = Count(P.rows) end
        if P.sel < 1 then P.sel = 1 end
        local r = P.rows[P.sel]
        if r and r.kind == 'header' then
            for i = P.sel, Count(P.rows) do
                if P.rows[i].kind ~= 'header' then P.sel = i break end
            end
        end
    end

    function P:Refresh(force)
        local stamp = cfg.stampFn()
        if force or stamp ~= P.stamp then
            P.stamp = stamp
            Rebuild()
            P.list:Refresh()
        end
        local row = P.rows[P.sel]
        for _, b in P.buttons do
            local show = row and b.def.kinds[row.kind] and (not b.def.visible or b.def.visible(row))
            b.shown = show and true or false
        end
        if P.w then P:Layout() end
        local text = cfg.status and cfg.status(P, row) or ''
        W.Fit(P.status, text, (P.w or 300) - Skin.S(16))
    end

    function P:Layout()
        local w, h = P.w, P.h
        local pad = Skin.S(8)
        local items = {}
        for _, b in P.buttons do
            if b.shown then table.insert(items, { b.button, b.w }) else W.Place(b.button, group, -20000, -20000, b.w, Skin.S(22)) end
        end
        local rowsH = Count(items) > 0 and (W.Flow(group, items, 0, 0, w - 2 * pad, Skin.S(22), Skin.S(4), true)) or Skin.S(22)
        local foot = rowsH + Skin.S(30)
        local listH = math.max(Skin.S(60), h - 2 * pad - foot)
        P.list:SetRect(pad, pad, w - 2 * pad, listH)
        local y = math.max(h - foot + Skin.S(4), pad + listH + Skin.S(6))
        if Count(items) > 0 then W.Flow(group, items, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) end
        W.Place(P.status, group, pad, y + rowsH + Skin.S(4))
    end

    function P:OnResize(w, h)
        P.w, P.h = w, h
        P:Refresh(true)
    end
    return P
end

-- ---- the Adaptive map panel -----------------------------------------------------------------------------------------------------------------------------

local function MarkerNames(sel)
    return Join(sel.mass, sel.hydro)
end

local function UnitRows(rows, c)
    local Units = import('/lua/editor/units.lua')
    local sel = Units.Selection
    if Count(sel) == 0 then return end
    local first = sel[1]
    local info = Adaptive.FateOf(first.army, first.name)
    table.insert(rows, { text = 'THE SELECTED UNIT' .. (Count(sel) > 1 and (' (first of ' .. Count(sel) .. ')') or ''), kind = 'header' })
    if not info then
        table.insert(rows, { text = 'the unit is not in the map', kind = 'unit', color = c.warn })
        return
    end
    table.insert(rows, { text = first.name .. ' (' .. tostring(info.unit.bp) .. ') of ' .. first.army, extra = Join2(info.group, '/'), kind = 'unit', data = info })
    local color = (info.fate.kind == 'never') and c.warn or c.ok
    table.insert(rows, { text = info.fate.text, kind = 'unit', data = info, color = color })
    if info.rule then
        for _, line in info.rule.lines do table.insert(rows, { text = '  ' .. line, kind = 'unit', data = info }) end
    end
    if info.wreck then
        local text = info.wreck.exists and string.format('wreck: %d mass, %d energy', info.wreck.mass + 0.5, info.wreck.energy + 0.5) or 'it leaves no wreck'
        table.insert(rows, { text = text, kind = 'unit', data = info })
    end
end

local function AdaptiveRows(P)
    local c = Skin.color
    local rows = {}
    UnitRows(rows, c)       -- what becomes of the selected unit comes first: the list below it is long
    local files = Adaptive.Files()
    if not files.adaptive then
        table.insert(rows, { text = 'FILES', kind = 'header' })
        table.insert(rows, { text = 'Not adaptive yet', kind = 'make', color = c.warn })
        table.insert(rows, { text = 'Adaptive maps spawn each player\'s resources only with that player and let the lobby add groups. The script (_script.lua) comes from an adaptive map.', kind = 'note' })
        return rows
    end
    local tables, why = Adaptive.Tables()
    table.insert(rows, { text = 'FILES', kind = 'header' })
    table.insert(rows, { text = 'Tables: ' .. tostring(files.tablesPath), kind = 'file', color = tables and c.ok or c.error })
    if not tables then
        table.insert(rows, { text = '_tables.lua does not read: ' .. tostring(why), kind = 'file', color = c.error })
        return rows
    end
    if files.scriptReads then
        table.insert(rows, { text = 'The script reads them', kind = 'file', color = c.ok })
    else
        table.insert(rows, { text = 'The script does not read the tables yet (put an adaptive _script.lua in the map folder)', kind = 'file', color = c.warn })
    end
    table.insert(rows, { text = files.hasOptions and ('Lobby options: ' .. tostring(files.optionsPath)) or 'No _options.lua: the lobby shows no options', kind = 'file',
                         color = files.hasOptions and c.ok or c.warn })
    table.insert(rows, { text = 'PLAYERS', kind = 'header' })
    table.insert(rows, { text = 'Max players on the map', extra = tostring(tables.maxPlayers), kind = 'players' })
    table.insert(rows, { text = 'SPAWN WITH AN ARMY', kind = 'header' })
    local armies = math.max(tables.maxPlayers, Count(tables.mexArmy), Count(tables.hydroArmy))
    for a = 1, armies do
        table.insert(rows, { text = 'ARMY_' .. a, extra = Count(tables.mexArmy[a]) .. ' mass, ' .. Count(tables.hydroArmy[a]) .. ' hydro', kind = 'army', data = a })
    end
    table.insert(rows, { text = 'Spawn in every game', extra = 'takes the selected out of all lists', kind = 'always' })
    table.insert(rows, { text = 'OPTION TABLES (lobby groups)', kind = 'header' })
    for _, info in ed_adaptive_known_tables() do
        local groups = nil
        for _, opt in tables.options do
            if opt.name == info.name then groups = opt.groups end
        end
        table.insert(rows, { text = info.label .. (info.hydro and ' (hydro)' or ''), extra = groups and Plural(Count(groups), 'group', 'groups') or 'not used', kind = 'table', data = info })
        for g = 1, Count(groups) do
            table.insert(rows, { text = '    group ' .. g, extra = Plural(Count(groups[g]), 'resource', 'resources'), kind = 'group', data = { table = info.name, group = g, names = groups[g] } })
        end
    end
    table.insert(rows, { text = 'CRAZYRUSH', kind = 'header' })
    table.insert(rows, { text = 'Forward mexes', extra = Plural(Count(tables.forwardCrazyrush), 'mex', 'mexes'), kind = 'crazy', data = 'forward' })
    table.insert(rows, { text = 'The one core mex', extra = Plural(Count(tables.crazyrushOne), 'mex', 'mexes'), kind = 'crazy', data = 'one' })
    table.insert(rows, { text = 'LOBBY OPTIONS', kind = 'header' })
    table.insert(rows, { text = 'Edit the lobby options...', extra = Plural(Count(Adaptive.Options()), 'option', 'options'), kind = 'window' })
    return rows
end

local function SelectionStamp()
    local Tools = import('/lua/editor/tools.lua')
    local Units = import('/lua/editor/units.lua')
    local keys = ''
    for _, it in Tools.Items do keys = keys .. it.name .. ',' end
    for _, s in Units.Selection do keys = keys .. s.army .. s.name .. ';' end
    return keys
end

local function OpenOptionsWindow()
    local Shell = import('/lua/editor/gui/shell.lua')
    Shell.OpenPanelWindow('adaptive_options', 560, 520)
end

local function SetTable(fn, label)
    local ok, why = fn()
    if ok == false then Say(label .. ': ' .. tostring(why)) return false end
    return true
end

local function TargetsMenu(P, row, anchor)
    local info = row.data
    if not info then return end
    local army = info.unit.army
    local names = {}
    for _, s in import('/lua/editor/units.lua').Selection do
        if s.army == army then table.insert(names, s.name) end
    end
    local items = {}
    for _, t in Adaptive.SpawnTargets(army) do
        local target = t
        local path = Join2(target.path, '/')
        local title = path .. '  -  ' .. tostring(target.when)
        if target.optionsChange and target.optionsChange ~= '' then title = title .. ' (adds ' .. target.optionsChange .. ')' end
        table.insert(items, { title = title, run = function()
            local n = Adaptive.MoveToTarget(army, names, target)
            Say(n .. ' unit(s) moved to ' .. path)
            P:Refresh(true)
        end })
    end
    if Count(items) == 0 then
        Say('the script creates no group for ' .. army)
        return
    end
    Menu.Show(GetFrame(0), anchor.Left(), anchor.Top() - Skin.S(8), items)
end

local ADAPTIVE_BUTTONS = {
    { label = 'Make this map adaptive', tip = 'Give the map a _tables.lua (one list per start slot) and AdaptiveMap = true. The _script.lua comes from an adaptive map.',
      kinds = { make = true }, run = function() return Adaptive.MakeAdaptive() end },
    { label = '-', tip = 'One player less (never fewer than the map\'s start slots).', kinds = { players = true }, run = function()
        local t = Adaptive.Tables()
        return Adaptive.SetMaxPlayers(math.max(Count(import('/lua/editor/armies.lua').Names()), t.maxPlayers - 1)) end },
    { label = '+', tip = 'One player more (at most 16).', kinds = { players = true }, run = function()
        local t = Adaptive.Tables()
        return Adaptive.SetMaxPlayers(t.maxPlayers + 1) end },
    { label = 'Add selected', tip = 'The selected mass / hydrocarbon markers spawn only with this army (or belong to this group).', kinds = { army = true, group = true },
      run = function(P, row)
        local names = MarkerNames(Adaptive.SelectedMarkers())
        if Count(names) == 0 then return false, 'select mass or hydrocarbon markers in the world first' end
        if row.kind == 'army' then return Adaptive.AssignToArmy(row.data, names) end
        return Adaptive.AddToGroup(row.data.table, row.data.group, names)
    end },
    { label = 'Select', tip = 'Select the resource markers of this list in the world.', kinds = { army = true, group = true, crazy = true, table = true }, run = function(P, row)
        local t = Adaptive.Tables()
        local names = {}
        if row.kind == 'army' then names = Join(t.mexArmy[row.data] or {}, t.hydroArmy[row.data] or {})
        elseif row.kind == 'group' then names = row.data.names
        elseif row.kind == 'crazy' then names = row.data == 'one' and t.crazyrushOne or t.forwardCrazyrush
        else
            for _, opt in t.options do
                if opt.name == row.data.name then for _, g in opt.groups do names = Join(names, g) end end
            end
        end
        SelectMarkers(names)
    end },
    { label = 'Remove group', tip = 'Delete this group: its resources spawn in every game; the lobby option loses one choice.', kinds = { group = true },
      run = function(P, row) return Adaptive.RemoveGroup(row.data.table, row.data.group) end },
    { label = 'New group from selected', tip = 'A new group of this option table made of the selected markers; the lobby option gets one more choice.', kinds = { table = true },
      run = function(P, row)
        local names = MarkerNames(Adaptive.SelectedMarkers())
        if Count(names) == 0 then return false, 'select mass or hydrocarbon markers in the world first' end
        local t = Adaptive.Tables()
        local n = 0
        for _, opt in t.options do
            if opt.name == row.data.name then n = Count(opt.groups) end
        end
        return Adaptive.AddToGroup(row.data.name, n + 1, names)
    end },
    { label = 'Remove table', tip = 'The table\'s resources spawn in every game again; its lobby option is removed.', kinds = { table = true },
      visible = function(row)
        local t = Adaptive.Tables()
        for _, opt in (t and t.options) or {} do
            if opt.name == row.data.name then return true end
        end
        return false
      end,
      run = function(P, row) return Adaptive.RemoveTable(row.data.name) end },
    { label = 'Spawn always', tip = 'Take the selected mass / hydrocarbon markers out of every list: they spawn in every game.', kinds = { always = true },
      run = function() return Adaptive.RemoveFromTables(MarkerNames(Adaptive.SelectedMarkers())) end },
    { label = 'Add selected mexes', tip = 'Add the selected mass markers to this crazyrush list.', kinds = { crazy = true }, run = function(P, row)
        if Count(Adaptive.SelectedMarkers().mass) == 0 then return false, 'select mass markers in the world first' end
        return Adaptive.CrazyrushAdd(row.data, Adaptive.SelectedMarkers().mass) end },
    { label = 'Remove selected mexes', tip = 'Take the selected mass markers out of this crazyrush list.', kinds = { crazy = true }, run = function(P, row)
        return Adaptive.CrazyrushRemove(row.data, Adaptive.SelectedMarkers().mass) end },
    { label = 'Edit lobby options...', tip = 'Open the Lobby options window: every option the lobby shows, its choices and what each puts on the map.', kinds = { window = true },
      run = function() OpenOptionsWindow() end },
    { label = 'Move to...', tip = 'Put the selected units of this army into a group the script creates, with the lobby setting that brings it in (one undo step).',
      kinds = { unit = true }, run = function(P, row) TargetsMenu(P, row, P.buttons[Count(P.buttons)].button) end },
}

Panels.Register{
    id = 'adaptive', title = 'Adaptive map',
    stack = { { workspace = 'Objects', with = 'markers' } },
    create = function(group, host)
        local P = BuildList(group, host, {
            id = 'adaptive',
            rowsFn = AdaptiveRows,
            stampFn = function()
                return Adaptive.Revision .. ':' .. History.Version .. ':' .. tostring(Adaptive.IsAdaptive()) .. ':' .. SelectionStamp() .. ':' .. import('/lua/editor/units.lua').Stamp()
            end,
            buttons = ADAPTIVE_BUTTONS,
            status = function(P, row)
                local sel = Adaptive.SelectedMarkers()
                local text = string.format('Selected: %d mass, %d hydro markers', Count(sel.mass), Count(sel.hydro))
                return text
            end,
        })
        live.adaptive = P
        return P
    end,
}

-- ---- the Lobby options window ---------------------------------------------------------------------------------------------------------------------------

local wreckMass = {}       -- unit blueprint id -> mass of its wreck (0 = none)

local KIND_TEXT = { mexes = 'mexes', hydros = 'hydros', levels = 'levels', other = 'script' }

--- What a choice (value index `v`, 1-based) of an option puts on the map, as one phrase.
local function ChoiceEffect(option, lobby, v)
    local value = lobby.values[v]
    if option.kind == 'mexes' or option.kind == 'hydros' then
        local g = ed_adaptive_table_group(value)
        if g == 0 then return 'none' end
        local t = Adaptive.Tables()
        local groups
        for _, opt in (t and t.options) or {} do
            if opt.name == option.table then groups = opt.groups end
        end
        if not groups or not groups[g] then return 'group ' .. g .. ' (not in the tables)' end
        local all = 0
        for i = 1, g do all = all + Count(groups[i]) end
        return '+ ' .. Plural(Count(groups[g]), option.kind == 'mexes' and 'mex' or 'hydro', option.kind == 'mexes' and 'mexes' or 'hydros') .. ' (' .. all .. ' in all)'
    elseif option.kind == 'levels' then
        local name = ed_adaptive_level_group(option.loop, value)
        if name == '' then return 'none' end
        local units, mass = 0, 0
        for _, u in import('/lua/editor/units.lua').CachedAll() do
            local root = string.gsub(u.group, '/.*$', '')
            if root == name then
                units = units + 1
                if option.loop.wreck and rawget(_G, 'ed_wreck_value') then
                    if wreckMass[u.bp] == nil then
                        local ok, w = pcall(ed_wreck_value, u.bp, false)
                        wreckMass[u.bp] = (ok and w and w.exists) and w.mass or 0
                    end
                    mass = mass + wreckMass[u.bp]
                end
            end
        end
        if units == 0 then return name .. ' (no units yet)' end
        return '+ ' .. Plural(units, option.loop.wreck and 'wreck' or 'unit', option.loop.wreck and 'wrecks' or 'units') .. (mass > 0 and string.format(', %d mass', mass + 0.5) or '')
    end
    local made = ed_adaptive_groups_made(Adaptive.Script(), Adaptive.OptionsText(), option.key, v)
    if Count(made) == 0 then return 'nothing' end
    local names = {}
    for _, m in made do table.insert(names, m.group .. (m.wreck and ' (wrecks)' or (m.unit and ' (units)' or '')) .. (m.maybe and '?' or '')) end
    return Join2(names, ', ')
end

local function OptionsRows(P)
    local c = Skin.color
    local rows = {}
    if not Adaptive.IsAdaptive() and Count(Adaptive.LobbyOptions()) == 0 and Count(Adaptive.Options()) == 0 then
        table.insert(rows, { text = 'This map has no lobby options (no _options.lua) and its script reads none.', kind = 'note' })
        return rows
    end
    local lobbyList = Adaptive.LobbyOptions()
    for i, opt in Adaptive.Options() do
        local lobby = opt.lobby > 0 and lobbyList[opt.lobby] or nil
        table.insert(rows, { text = opt.title, extra = KIND_TEXT[opt.kind] .. (lobby and '' or ', not in the lobby'), kind = 'option', data = { option = opt, lobby = lobby },
                             color = (not lobby) and c.warn or nil })
        if i == P.openOption and lobby then
            for v, value in lobby.values do
                table.insert(rows, { text = '    ' .. (v == lobby.defaultIndex and '* ' or '  ') .. value.text, extra = ChoiceEffect(opt, lobby, v), kind = 'choice',
                                     data = { option = opt, lobby = lobby, index = v } })
            end
        end
    end
    return rows
end

local function RenameDialog(P, row)
    local d = row.data
    local value = d.lobby.values[d.index]
    local dlg = Dialog.Open('Rename the choice', 360, 130)
    dlg:Label('Text of the choice in the lobby', 14, 34, { color = Skin.color.textDim, size = 'small' })
    local field = dlg:Field(14, 56, 330, 22, { text = value.text })
    local function Make()
        local text = field:GetText()
        Dialog.Close()
        if text ~= '' then
            local copy = {}
            for k, v in d.lobby do copy[k] = v end
            copy.values = {}
            for i, v in d.lobby.values do
                if i == d.index then
                    local nv = {}
                    for k, x in v do nv[k] = x end
                    nv.text = text
                    copy.values[i] = nv
                else
                    copy.values[i] = v
                end
            end
            Adaptive.PutOption(copy, 'rename a lobby choice')
        end
        P:Refresh(true)
    end
    dlg:Button('Rename', 14, 92, 90, 28, Make, { tip = 'Change the text the lobby shows for this choice.' })
    dlg:Button('Cancel', 114, 92, 90, 28, function() Dialog.Close() end)
    field.OnEnterPressed = function(self, text) Make() return true end
    field:AcquireFocus()
end

local function ChoiceMarkers(d)
    local t = Adaptive.Tables()
    local names = {}
    if d.option.kind == 'mexes' or d.option.kind == 'hydros' then
        local g = ed_adaptive_table_group(d.lobby.values[d.index])
        for _, opt in (t and t.options) or {} do
            if opt.name == d.option.table and opt.groups[g] then names = opt.groups[g] end
        end
    end
    return names
end

local OPTION_BUTTONS = {
    { label = 'Open', tip = 'Show the choices of this option and what each puts on the map.', kinds = { option = true }, visible = function(row) return row.data.lobby ~= nil end,
      run = function(P, row)
        for i, opt in Adaptive.Options() do
            if opt.key == row.data.option.key then P.openOption = (P.openOption == i) and false or i end
        end
    end },
    { label = 'Add to the lobby', tip = 'The lobby does not offer this option yet: write it (disabled, then one choice per group or level).', kinds = { option = true },
      visible = function(row) return row.data.lobby == nil end,
      run = function(P, row)
        local o = row.data.option
        if o.kind == 'mexes' or o.kind == 'hydros' then return Adaptive.SyncTableOption(o.table) end
        local choice = { key = o.key, label = o.title, help = '', defaultIndex = 1, values = {} }
        choice.values[1] = ed_adaptive_next_level({ key = o.key, values = {} }, 'disabled')
        return Adaptive.PutOption(choice, 'add the lobby option ' .. o.key)
    end },
    { label = 'Add choice', tip = 'Mexes / hydros: a new group of the selected markers. Levels: the next level (its group is made from selected units in the Adaptive map panel). Other: one more choice.',
      kinds = { option = true, choice = true }, visible = function(row) return row.data.lobby ~= nil end,
      run = function(P, row)
        local o, lobby = row.data.option, row.data.lobby
        if o.kind == 'mexes' or o.kind == 'hydros' then
            local names = MarkerNames(Adaptive.SelectedMarkers())
            if Count(names) == 0 then return false, 'select mass or hydrocarbon markers in the world first' end
            local t = Adaptive.Tables()
            local n = 0
            for _, opt in (t and t.options) or {} do
                if opt.name == o.table then n = Count(opt.groups) end
            end
            return Adaptive.AddToGroup(o.table, n + 1, names)
        end
        return Adaptive.AddChoice(lobby, (o.kind == 'levels') and ('level ' .. Count(lobby.values)) or ('choice ' .. (Count(lobby.values) + 1)))
    end },
    { label = 'Make default', tip = 'The lobby starts with this choice.', kinds = { choice = true }, run = function(P, row)
        local d = row.data
        local copy = {}
        for k, v in d.lobby do copy[k] = v end
        copy.defaultIndex = d.index
        return Adaptive.PutOption(copy, 'default of ' .. tostring(d.lobby.key))
    end },
    { label = 'Rename', tip = 'Change the text the lobby shows for this choice.', kinds = { choice = true }, run = function(P, row) RenameDialog(P, row) end },
    { label = 'Select', tip = 'Select the resource markers this choice adds, in the world.', kinds = { choice = true }, run = function(P, row)
        SelectMarkers(ChoiceMarkers(row.data))
    end },
    { label = 'Remove choice', tip = 'Delete this choice. For a mex / hydro option its group is deleted too (its resources spawn in every game).', kinds = { choice = true },
      run = function(P, row)
        local d = row.data
        if d.option.kind == 'mexes' or d.option.kind == 'hydros' then
            local g = ed_adaptive_table_group(d.lobby.values[d.index])
            if g == 0 then return false, 'the "none" choice stays' end
            return Adaptive.RemoveGroup(d.option.table, g)
        end
        return Adaptive.RemoveChoice(d.lobby, d.index)
    end },
    { label = 'Delete option', tip = 'Delete the option from the lobby. For a mex / hydro option the table goes too: its resources spawn in every game.', kinds = { option = true },
      visible = function(row) return row.data.lobby ~= nil end,
      run = function(P, row)
        local o = row.data.option
        if o.kind == 'mexes' or o.kind == 'hydros' then return Adaptive.RemoveTable(o.table) end
        return Adaptive.RemoveOption(o.key)
    end },
}

Panels.Register{
    id = 'adaptive_options', title = 'Lobby options',
    create = function(group, host)
        local P = BuildList(group, host, {
            id = 'adaptive_options',
            rowsFn = OptionsRows,
            stampFn = function() return Adaptive.Revision .. ':' .. History.Version .. ':' .. tostring(live.adaptive_options and live.adaptive_options.openOption) end,
            buttons = OPTION_BUTTONS,
            status = function(P, row)
                if row and row.kind == 'choice' then return row.data.lobby.help ~= '' and row.data.lobby.help or ('Option ' .. tostring(row.data.lobby.key)) end
                if row and row.kind == 'option' and row.data.lobby then return row.data.lobby.help ~= '' and row.data.lobby.help or ('Option ' .. tostring(row.data.lobby.key)) end
                return 'Click an option to see its choices. * marks the default.'
            end,
        })
        P.openOption = false
        live.adaptive_options = P
        return P
    end,
}

--- Called by the shell about four times a second.
function Refresh()
    for _, id in { 'adaptive', 'adaptive_options' } do
        local P = live[id]
        if P and P.w then pcall(P.Refresh, P) end
    end
end
