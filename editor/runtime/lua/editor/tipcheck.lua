-- The tooltip check: every interactive widget of the editor has a tooltip text. Used by scripts/editor_nightly.py (step `tips`) and selftest_assets.lua.
--
--   Panel(panelId) -> widgets checked, list of "panel > label (kind)" without a tooltip     the panel is shown and its buttons, sliders and text fields (and those of the dialogs
--                                                      its buttons open, as the click sweep presses them) are asked for their TipText()
--   Tools() / Panels() / Workspaces() -> list of ids without text                              the tool buttons, the panel tabs and the workspace buttons
--   Menus() -> items checked, list of "menu > title" without text                              every menu-bar menu and context menu item (commands: tooltips.lua ForCommand)
--   Commands() -> list of command ids that a menu shows and that have no text (also in Menus)
--
-- Lua 5.0 dialect.

local ClickSweep = import('/lua/editor/clicksweep.lua')
local Tips = import('/lua/editor/tooltips.lua')

--   Visit            nil, or a function(entries, where) called with the widgets of each dialog / shell part Dialogs() and Shell() open (layoutcheck.lua)
Visit = false

local function Label(entry)
    local t = entry.text
    if t == nil then
        local ok, text = pcall(function() return entry.button and entry.button.label:GetText() end)
        t = ok and text or '?'
    end
    return tostring(t)
end

--- Asks one tracked entry for its tooltip; returns true | false (none) | nil (not a widget to check: stale or destroyed).
local function Has(entry)
    local obj = entry.button or entry.slider or entry.field
    if not obj or not obj.TipText then return nil end
    if entry.button then
        local ok, parent = pcall(function() return entry.button:GetParent() end)
        if not ok or parent == nil then return nil end        -- a button of a panel part that was rebuilt meanwhile
    end
    local ok, text = pcall(function() return obj:TipText() end)
    return ok and text ~= nil and text ~= ''
end

--- The widgets of a panel and of its dialogs.
function Panel(panelId)
    local seen, missing, n = {}, {}, 0
    local function Collect(entries, where)
        for _, e in entries do
            local kind = (e.button and 'button') or (e.slider and 'slider') or (e.field and 'field') or '?'
            local has = Has(e)
            if has ~= nil then
                n = n + 1
                if not has then
                    local key = where .. ' > ' .. Label(e) .. ' (' .. kind .. ')'
                    if not seen[key] then
                        seen[key] = true
                        table.insert(missing, key)
                    end
                end
            end
        end
    end
    ClickSweep.Collect = Collect
    local ok, count, errors = pcall(ClickSweep.Run, panelId)
    ClickSweep.Collect = false
    if not ok then table.insert(missing, panelId .. ': ' .. tostring(count)) end
    return n, missing
end

function Tools()
    local UI = import('/lua/editor/ui.lua')
    local list = {}
    for _, t in UI.Tools do
        if not Tips.ForTool(t.id) then table.insert(list, t.id) end
    end
    return list
end

function Panels()
    local list = {}
    for _, def in import('/lua/editor/gui/panels.lua').All() do
        if not Tips.ForPanel(def.id) then table.insert(list, def.id) end
    end
    return list
end

function Workspaces()
    local list = {}
    for _, name in import('/lua/editor/gui/workspace.lua').Presets() do
        if not Tips.ForWorkspace(name) then table.insert(list, name) end
    end
    return list
end

local function Title(it)
    local title = it.title
    if type(title) == 'function' then
        local ok, t = pcall(title)
        title = ok and t or '?'
    end
    local Commands = import('/lua/editor/gui/commands.lua')
    if not title and it.command and Commands.registry[it.command] then title = Commands.registry[it.command].title end
    return tostring(title)
end

local function Items(where, items, depth, out)
    for _, it in items do
        if not it.separator and not it.header then
            local title = Title(it)
            local sub = it.submenu
            if type(sub) == 'function' then
                local ok, r = pcall(sub)
                sub = ok and r or nil
            end
            if sub and table.getn(sub) > 0 then
                if depth < 4 then Items(where .. ' > ' .. title, sub, depth + 1, out) end
            else
                out.count = out.count + 1
                local text = it.tip
                if not text and it.command then text = Tips.ForCommand(it.command) end
                if not text then text = Tips.ForMenuItem({ title = title }) end
                if not text or text == '' then table.insert(out.missing, where .. ' > ' .. title .. (it.command and (' [' .. it.command .. ']') or '')) end
            end
        end
    end
end

function Menus()
    local Menu = import('/lua/editor/gui/menu.lua')
    import('/lua/editor/gui/menus.lua')
    local out = { count = 0, missing = {} }
    for _, t in Menu.Titles do Items(t, Menu.Build('menubar.' .. t), 0, out) end
    Items('world', Menu.Build('context.world', { wx = 100, wz = 100, height = 25 }), 0, out)
    Items('marker', Menu.Build('context.object', { kind = 'marker', name = 'ARMY_1' }), 0, out)
    Items('area', Menu.Build('context.object', { kind = 'area', name = 'NONE' }), 0, out)
    return out.count, out.missing
end

--- The widgets of the dialogs the menus open (the panels' dialogs are checked by Panel). Each dialog is opened, its widgets are recorded and it is closed again. -> widgets checked, list of "dialog > label (kind)".
function Dialogs()
    local W = import('/lua/editor/gui/widgets.lua')
    local Dialog = import('/lua/editor/gui/dialog.lua')
    local DM = import('/lua/editor/gui/dialogs_map.lua')
    local DT = import('/lua/editor/gui/dialogs_terrain.lua')
    local DX = import('/lua/editor/gui/dialogs_mission.lua')
    local list = {
        { 'New map', function() DM.NewMap() end },
        { 'Open map', function() DM.OpenMap({}) end },
        { 'Map info', function() DM.MapInfo() end },
        { 'Generate terrain', function() DT.Generate() end },
        { 'Flatten the map', function() DT.FlattenMap() end },
        { 'Playable area', function() DT.PlayableArea() end },
        { 'Pick a type', function() DT.PickType('Pick', '', function() end) end },
        { 'Pick a name', function() DX.PickName('Pick', { 'A', 'B' }, 'A', function() end) end },
        { 'Pick several', function() DX.PickMulti('Pick', { 'A', 'B' }, {}, function() end) end },
        { 'Name', function() DX.NameDialog('Name', 'a name', function() end) end },
        { 'Find and replace', function() import('/lua/editor/gui/feature_parity.lua').FindDialog() end },
        { 'Release map', function() import('/lua/editor/gui/feature_release.lua').ReleaseDialog() end },
        { 'Import mesh', function() import('/lua/editor/gui/dialogs_meshimport.lua').Open() end },
    }
    local missing, n = {}, 0
    for _, d in list do
        local entries = {}
        W.tracking = entries
        local ok, err = pcall(d[2])
        W.tracking = false
        if Visit then pcall(Visit, entries, d[1]) end
        if not ok then
            table.insert(missing, d[1] .. ': could not be opened: ' .. string.sub(tostring(err), 1, 120))
        else
            for _, e in entries do
                local has = Has(e)
                if has ~= nil then
                    n = n + 1
                    if not has then
                        local kind = (e.button and 'button') or (e.slider and 'slider') or 'field'
                        table.insert(missing, d[1] .. ' > ' .. Label(e) .. ' (' .. kind .. ')')
                    end
                end
            end
        end
        pcall(Dialog.Close)
    end
    return n, missing
end

--- The top bar, the play bar, the start screen and the tour: rebuilt / opened with the widgets recorded. -> widgets checked, list of "where > label (kind)".
function Shell()
    local W = import('/lua/editor/gui/widgets.lua')
    local missing, n = {}, 0
    local function Look(where, fn, close)
        local entries = {}
        W.tracking = entries
        local ok, err = pcall(fn)
        W.tracking = false
        if Visit then pcall(Visit, entries, where) end
        if not ok then table.insert(missing, where .. ': ' .. string.sub(tostring(err), 1, 120)) end
        for _, e in entries do
            local has = Has(e)
            if has ~= nil then
                n = n + 1
                if not has then table.insert(missing, where .. ' > ' .. Label(e) .. ' (' .. ((e.button and 'button') or (e.slider and 'slider') or 'field') .. ')') end
            end
        end
        if close then pcall(close) end
    end
    local S = import('/lua/editor/gui/shell.lua')
    Look('top bar and play bar', function() S.RebuildBars() end)
    local Start = import('/lua/editor/gui/startscreen.lua')
    Look('start screen', function() Start.Open({}) end, function() Start.Close() end)
    local Tour = import('/lua/editor/gui/tour.lua')
    Look('tour', function() Tour.Start() end, function() Tour.Stop(true) end)
    return n, missing
end
