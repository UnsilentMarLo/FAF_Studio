-- The layout check: every control the editor builds (buttons, sliders, text fields, text labels, paragraph lines, list rows) stays inside the area the user sees and
-- does not run into another one. Used by scripts/editor_nightly.py (step `layout`).
--
--   Panel(panelId)            -> widgets checked, list of problems   the panel is shown (as the click sweep does) and its widgets, and those of the dialogs its buttons open, are measured
--   Dialogs([long])           -> widgets checked, list of problems   the dialogs of the menus; `long`: with long map names, long list entries and every empty status line filled with a long error text
--   Shell()                   -> widgets checked, list of problems   the top bar / play bar / start screen / tour
--   Workspace(name, scale)    -> widgets checked, list of problems   every panel a workspace builds, at the UI scale, in the dock at its real size
--   Resize(name, scale)       -> widgets checked, list of problems   the same workspace after the dock area shrank (a smaller window) and after every split was pulled to its narrowest
--
-- Problems (each "where > label: what"):
--   past area     the widget's edge is outside the area the user sees: the panel (the scroll holder), the dialog box, or the group it was built in, and the window
--   text wider    a label / a paragraph line / a list row text is wider than its box (the panel, the button, the row)
--   overlap       two widgets of one group cover each other (more than 3 px in both directions)
-- The place of a widget is the one it was given (W.Place remembers it), so a control that a scroll cull parked off screen is measured too. Hidden widgets and the ones of
-- a hidden tab are not measured.
--
-- Lua 5.0 dialect.

local ClickSweep = import('/lua/editor/clicksweep.lua')
local TipCheck = import('/lua/editor/tipcheck.lua')

local SLACK = 1
local OVERLAP = 3
local LONG = 'a very long text that does not fit any box of the editor, for a map name, a file name or an error line, and goes on and on and on past every edge and every limit'

local function Object(e)
    if e.button then return e.button end
    if e.slider then return e.slider.track end
    if e.field then return e.field.frame or e.field end
    return e.label
end

local function Name(e)
    local t = e.text
    if t == nil or t == '' then
        local ok, text = pcall(function()
            if e.button then return e.button.label:GetText() end
            if e.label then return e.label:GetText() end
            if e.slider then return e.slider.opts.label end
            return nil
        end)
        t = (ok and text) or '?'
    end
    t = tostring(t)
    if string.len(t) > 40 then t = string.sub(t, 1, 37) .. '...' end
    local kind = (e.button and 'button') or (e.slider and 'slider') or (e.field and 'field') or 'text'
    if kind == 'field' then return '[field]' end
    if kind == 'slider' then return t .. ' (slider)' end
    return t
end

local function Frame()
    local f = GetFrame(0)
    return { l = 0, t = 0, r = f.Width(), b = f.Height() }
end

local function RectOf(c)
    local ok, l, t, r, b = pcall(function() return c.Left(), c.Top(), c.Right(), c.Bottom() end)
    if not ok or not l or not r then return nil end
    return { l = l, t = t, r = r, b = b }
end

--- The area the user sees for a widget: the holder of the scroll content it was built in (a panel, a scrolling dialog), else a dialog's box, else the widget's immediate parent.
--- -> kind, rect, group
local function Scope(o)
    local ok, p = pcall(function() return o:GetParent() end)
    local first = ok and p or nil
    local n = 0
    local c = first
    while c and n < 16 do
        local okS, ctx = pcall(function() return c.scroll end)
        if okS and ctx then
            local rc = RectOf(ctx.holder)
            -- the overlay scrollbar takes the right edge of the panel: the controls end before it (the dock tells a panel its width less the bar)
            if rc then
                rc.r = rc.r - import('/lua/editor/gui/skin.lua').S(import('/lua/editor/gui/skin.lua').size.scrollW)
                return 'panel', rc, c
            end
        end
        local okP, pid = pcall(function() return c.panelId end)
        if okP and pid == 'dialog' then
            local rc = RectOf(c)
            if rc then return 'dialog', rc, c end
        end
        local okG, parent = pcall(function() return c:GetParent() end)
        if not okG then break end
        c = parent
        n = n + 1
    end
    if first then
        local rc = RectOf(first)
        if rc then return 'parent', rc, first end
    end
    return nil
end

--- A panel the dock gave less width than the panel declares as its minimum (the window cannot hold the minimum of every panel at this UI scale): its controls scroll sideways, they
--- are not measured (the dock keeps every stack at its minimum whenever the window allows it).
local function Degraded(group)
    local ok, res = pcall(function()
        local ctx = group.scroll
        local def = ctx and ctx.id and import('/lua/editor/gui/panels.lua').Get(ctx.id)
        if not def then return false end
        local Skin = import('/lua/editor/gui/skin.lua')
        return ctx.holder.Width() + Skin.S(2) < Skin.S(def.minW or import('/lua/editor/gui/panels.lua').DEFAULT_MIN_W)
    end)
    return ok and res
end

--- { l, t, r, b, parent, kind, area } of a tracked widget, or nil when it is destroyed, hidden or in a hidden tab.
local function Rect(e)
    local o = Object(e)
    if not o then return nil end
    local ok, parent = pcall(function() return o:GetParent() end)
    if not ok or parent == nil then return nil end
    local ok2, hidden = pcall(function() return o:IsHidden() end)
    if ok2 and hidden then return nil end
    local ok3, l, t, r, b = pcall(function() return o.Left(), o.Top(), o.Right(), o.Bottom() end)
    if not ok3 or not l or not r then return nil end
    -- a control a scroll cull parked off screen: its own place (relative to the group it belongs to) is what is measured
    local lx, ly = o.layX, o.layY
    local okP, pl, pt = pcall(function() return parent.Left(), parent.Top() end)
    if okP and lx and ly and ((t < -5000 and o.culledY) or (l < -5000 and o.culledX)) then
        local w, h = r - l, b - t
        if h < 0 then h = 0 end
        l, t = pl + lx, pt + ly
        r, b = l + w, t + h
    end
    if t < -5000 or t > 20000 or l < -2000 or l > 20000 then return nil end
    if r - l < 2 then return nil end
    local kind, area, group = Scope(o)
    return { l = l, t = t, r = r, b = b, parent = parent, kind = kind, area = area, group = group, degraded = (kind == 'panel') and Degraded(group) }
end

--- The id of the panel a widget belongs to (the group a panel builds into carries it, panels.lua Register).
local function PanelOf(o)
    local n = 0
    local c = o
    while c and n < 12 do
        local ok, id = pcall(function() return c.panelId end)
        if ok and id then return id end
        local okp, parent = pcall(function() return c:GetParent() end)
        if not okp then return nil end
        c = parent
        n = n + 1
    end
    return nil
end

--- A text whose parent is a bitmap (a button, a list row, a tab) is judged against that bitmap.
local function IsBitmap(c)
    local ok, f = pcall(function() return c.SetSolidColor end)
    return ok and f ~= nil
end

local function Px(n) return math.floor(n + 0.5) end

--- Panels with problems that belong to the files of another group of the 2026-11 stabilization (docs/projects/editor/STABILIZATION_PLAN.md): the layout group does not edit
--- them. Their problems are measured and kept apart (TakeKnown), the nightly reports them as "known" next to the result instead of failing on them. Empty this table when the owners
--- have fixed their panels (the nightly then fails on them like on any other).
Known = {
    stages = 'group E, gui/panels_mission.lua',
    bases = 'group E, gui/panels_mission.lua',
    platoons = 'group E, gui/panels_platoons.lua',
    run = 'group E, gui/panels_missionrun.lua',
    mods = 'group F, gui/panels_mods.lua',
}
local knownLines = {}

--- The problems found in the panels of Known since the last call -> list of "where > text (owner)"; clears the list.
function TakeKnown()
    local list = knownLines
    knownLines = {}
    return list
end

--- Puts a problem of the panel `pid` in the list of problems, or in the known list when the panel is one of Known's.
local function Add(out, pid, text)
    if pid and Known[pid] then
        if table.getn(knownLines) < 400 then table.insert(knownLines, text .. ' (' .. Known[pid] .. ')') end
    else
        table.insert(out, text)
    end
end

--- The problems of a list of tracked entries (W.tracking) -> list of strings.
function Analyze(entries, where)
    local out = {}
    local rects = {}
    local frame = Frame()
    for i, e in entries do
        local rc = Rect(e)
        if rc and not rc.degraded then
            rects[i] = rc
            local name = where .. ' > ' .. Name(e)
            local pid = PanelOf(Object(e))
            rc.pid = pid
            if pid and not string.find(where, pid, 1, true) then name = name .. ' [' .. pid .. ']' end
            -- the box the widget has to stay in: the area the user sees; a text on a bitmap (button, row) the bitmap
            local box, what = rc.area, 'the ' .. tostring(rc.kind)
            if e.label and rc.parent ~= rc.group and IsBitmap(rc.parent) then
                local pr = RectOf(rc.parent)
                if pr then box, what = pr, 'its button / row' end
            end
            if box then
                if rc.r > box.r + SLACK then
                    Add(out, pid, name .. ': ' .. (e.label and 'text' or 'past area') .. ' runs ' .. Px(rc.r - box.r) .. ' px past the right edge of ' .. what)
                elseif rc.l < box.l - SLACK then
                    Add(out, pid, name .. ': ' .. (e.label and 'text' or 'past area') .. ' starts ' .. Px(box.l - rc.l) .. ' px left of ' .. what)
                end
                -- a dialog does not scroll sideways or up and down unless it was given a scroll: its widgets stay inside the box
                if rc.kind == 'dialog' or (rc.kind == 'parent' and not e.label) then
                    if rc.b > box.b + SLACK then
                        Add(out, pid, name .. ': past area, bottom edge ' .. Px(rc.b - box.b) .. ' px below ' .. what)
                    end
                end
            end
            -- the window
            if rc.kind ~= 'panel' and (rc.r > frame.r + SLACK or rc.l < frame.l - SLACK or rc.b > frame.b + SLACK) then
                Add(out, pid, name .. ': off the window (' .. Px(rc.l) .. ',' .. Px(rc.t) .. ',' .. Px(rc.r) .. ',' .. Px(rc.b) .. ' in ' .. frame.r .. 'x' .. frame.b .. ')')
            end
            if e.button and e.button.label then
                local okw, lw = pcall(function() return e.button.label.Width() end)
                local okt, lt = pcall(function() return e.button.label:GetText() end)
                if okw and lw and lw > (rc.r - rc.l) + SLACK and okt and lt ~= '' then
                    Add(out, pid, name .. ': label wider than the button (' .. lw .. ' > ' .. (rc.r - rc.l) .. ')')
                end
            end
        end
    end
    for i, a in rects do
        for j, b in rects do
            if j > i and a.parent == b.parent then
                local ox = math.min(a.r, b.r) - math.max(a.l, b.l)
                local oy = math.min(a.b, b.b) - math.max(a.t, b.t)
                if ox > OVERLAP and oy > OVERLAP then
                    Add(out, a.pid or b.pid, where .. ' > ' .. Name(entries[i]) .. ' / ' .. Name(entries[j]) .. ': overlap (' .. Px(ox) .. ' x ' .. Px(oy) .. ' px) at ' .. Px(a.l) .. ',' .. Px(a.t) .. ',' .. Px(a.r) .. ',' .. Px(a.b) .. ' and ' .. Px(b.l) .. ',' .. Px(b.t) .. ',' .. Px(b.r) .. ',' .. Px(b.b))
                end
            end
        end
    end
    return out
end

--- The box of the open dialog against the window: -> list of problems.
local function DialogBox(where)
    local out = {}
    local Dialog = import('/lua/editor/gui/dialog.lua')
    if not Dialog.IsOpen() then return out end
    local rc = Dialog.Rect and Dialog.Rect()
    if not rc then return out end
    local f = Frame()
    if rc.l < f.l - SLACK or rc.t < f.t - SLACK or rc.r > f.r + SLACK or rc.b > f.b + SLACK then
        table.insert(out, where .. ': the dialog box (' .. Px(rc.l) .. ',' .. Px(rc.t) .. ',' .. Px(rc.r) .. ',' .. Px(rc.b) .. ') is not inside the window ' .. f.r .. 'x' .. f.b)
    end
    return out
end

--- Every empty text of the open dialog is filled with a long text (a status or error line a button press would show) and the entries measured again.
local function Stuff(entries)
    local n = 0
    for _, e in entries do
        local okP, parent = pcall(function() return e.label and e.label:GetParent() end)
        if e.label and okP and parent and not IsBitmap(parent) then          -- (the text of a button or a list row is the owner's to fill)
            local ok, text = pcall(function() return e.label:GetText() end)
            if ok and text == '' then
                local okS = pcall(function() e.label:SetText(LONG) end)
                if okS then n = n + 1 end
            end
        end
    end
    return n
end

local function Counted(entries)
    local n = 0
    for _, e in entries do
        if Rect(e) then n = n + 1 end
    end
    return n
end

--- The widgets of a panel and of the dialogs its buttons open.
--- Panels that only live in a window of their own (Settings): opening one here creates a second native window, which the engine of this machine does not survive (access violation
--- in the first frame, seen with the layout instance); they are not measured.
local function WindowOnly(panelId)
    local def = import('/lua/editor/gui/panels.lua').Get(panelId)
    return def and def.windowOnly
end

function Panel(panelId)
    if WindowOnly(panelId) then return 0, {} end
    local problems, n, seen = {}, 0, {}
    local function Collect(entries, where)
        n = n + Counted(entries)
        local list = Analyze(entries, where)
        for _, p in DialogBox(where) do table.insert(list, p) end
        for _, p in list do
            if not seen[p] then
                seen[p] = true
                table.insert(problems, p)
            end
        end
    end
    ClickSweep.Collect = Collect
    local ok, count, errors = pcall(ClickSweep.Run, panelId)
    ClickSweep.Collect = false
    if not ok then table.insert(problems, panelId .. ': ' .. tostring(count)) end
    return n, problems
end

--- Shows the panel without pressing anything (the layout of the panel alone) -> widgets checked, list of problems. `where` names the scale.
function PanelOnly(panelId, where)
    if WindowOnly(panelId) then return 0, {} end
    local W = import('/lua/editor/gui/widgets.lua')
    local Shell = import('/lua/editor/gui/shell.lua')
    local list = {}
    W.tracking = list
    local ok, err = pcall(function()
        local main = Shell.S.main
        if main and main.instances[panelId] then main:DropInstance(panelId) end
        if main and not main:ShowPanel(panelId) then main:AddPanel(panelId) end
    end)
    W.tracking = false
    if not ok then return 0, { panelId .. ': could not be shown: ' .. tostring(err) } end
    return Counted(list), Analyze(list, where or panelId)
end

--- A list of dialogs: each is opened, its widgets recorded and measured (`long`: also with every empty text filled), then closed.
local function VisitDialogs(list, long)
    local W = import('/lua/editor/gui/widgets.lua')
    local Dialog = import('/lua/editor/gui/dialog.lua')
    local problems, n = {}, 0
    for _, d in list do
        local entries = {}
        W.tracking = entries
        local ok, err = pcall(d[2])
        W.tracking = false
        local where = d[1] .. (long and ' (long text)' or '')
        if not ok then
            table.insert(problems, where .. ': could not be opened: ' .. string.sub(tostring(err), 1, 120))
        else
            if long then Stuff(entries) end
            n = n + Counted(entries)
            for _, p in Analyze(entries, where) do table.insert(problems, p) end
            for _, p in DialogBox(where) do table.insert(problems, p) end
        end
        pcall(Dialog.Close)
    end
    return n, problems
end

--- Dialogs of the menus, with a document that has long names when `long`.
function Dialogs(long)
    local DM = import('/lua/editor/gui/dialogs_map.lua')
    local DT = import('/lua/editor/gui/dialogs_terrain.lua')
    local DX = import('/lua/editor/gui/dialogs_mission.lua')
    local Maps = import('/lua/editor/maps.lua')
    local names = {}
    for i = 1, 30 do table.insert(names, 'Mass ' .. i .. (long and (' ' .. LONG) or '')) end
    local list = {
        { 'New map', function() DM.NewMap() end },
        { 'New map of any size', function() DM.NewCustomMap() end },
        { 'Open map', function() DM.OpenMap({}) end },
        { 'Map info', function() DM.MapInfo() end },
        { 'Lobby slots', function() DM.LobbySlots() end },
        { 'Unsaved changes', function() DM.Guard(function() end) end },
        { 'Generate terrain', function() DT.Generate() end },
        { 'Flatten the map', function() DT.FlattenMap() end },
        { 'Playable area', function() DT.PlayableArea() end },
        { 'Pick a type', function() DT.PickType('Pick', '', function() end) end },
        { 'Pick a name', function() DX.PickName('Pick', names, names[1], function() end) end },
        { 'Pick several', function() DX.PickMulti('Pick', names, {}, function() end) end },
        { 'Name', function() DX.NameDialog('Name', 'a name', function() end) end },
        { 'Find and replace', function() import('/lua/editor/gui/feature_parity.lua').FindDialog() end },
        { 'Release map', function() import('/lua/editor/gui/feature_release.lua').ReleaseDialog() end },
        { 'Import mesh', function() import('/lua/editor/gui/dialogs_meshimport.lua').Open() end },
        { 'Resize map', function() import('/lua/editor/gui/dialogs_resize.lua').Open() end },
        { 'Mirror', function() import('/lua/editor/gui/dialogs_mirror.lua').Open() end },
        { 'Texture browser', function() import('/lua/editor/gui/browser.lua').OpenTextures{ sources = { { '/env', '*_albedo.dds' } } } end },
        { 'Name browser', function() import('/lua/editor/gui/browser.lua').OpenNames{ title = 'Names', names = names } end },
        { 'Diagnostics', function() import('/lua/editor/gui/commands.lua').Run('help.diagnostics') end },
        { 'Reset settings', function() import('/lua/editor/gui/commands.lua').Run('help.reset_settings') end },
        { 'Add a node', function() DX.AddNode(1, 'ready') end },
        { 'Edit a node', function() DX.EditNode(1, 'ready', { 1 }) end },
        { 'Define a base', function() DX.DefineBase(function() end) end },
        { 'Base', function() DX.BaseEdit(1) end },
        { 'Base groups', function() DX.BaseGroups(1) end },
        { 'Base attacks', function() DX.BaseAttacks(1) end },
        { 'Base details', function() DX.BaseDetails(1) end },
        { 'Dialogue lines', function() DX.DialogueLines(1) end },
        { 'Pick a group', function() DX.PickGroup('Enemy', function() end) end },
        { 'Platoon builder', function() import('/lua/editor/gui/dialogs_platoons.lua').EditBuilder('Enemy', 'PLATOON_X') end },
    }
    local realInfo, realList, realDirty = Maps.Info, Maps.List, Maps.Dirty
    Maps.Dirty = function() return true end        -- the "Unsaved changes" dialog only opens for a map with unsaved changes
    if long then
        Maps.Info = function()
            local info = realInfo()
            info.name, info.author, info.description = LONG, LONG, LONG
            return info
        end
        Maps.List = function()
            return { { name = LONG, folder = 'a_long_folder_name_of_a_map_' .. string.rep('x', 60), path = '/maps/none/none.scmap' }, { name = 'Short', folder = 'short', path = '/maps/short/short.scmap' } }
        end
    end
    local n, problems = VisitDialogs(list, long)
    Maps.Info, Maps.List, Maps.Dirty = realInfo, realList, realDirty
    return n, problems
end

--- Top bar, play bar, start screen, tour.
function Shell()
    local W = import('/lua/editor/gui/widgets.lua')
    local problems, n = {}, 0
    local function Look(where, fn, close)
        local entries = {}
        W.tracking = entries
        local ok, err = pcall(fn)
        W.tracking = false
        if not ok then table.insert(problems, where .. ': ' .. string.sub(tostring(err), 1, 120)) end
        n = n + Counted(entries)
        for _, p in Analyze(entries, where) do table.insert(problems, p) end
        if close then pcall(close) end
    end
    local S = import('/lua/editor/gui/shell.lua')
    Look('top bar and play bar', function() S.RebuildBars() end)
    local Start = import('/lua/editor/gui/startscreen.lua')
    Look('start screen', function() Start.Open({}) end, function() Start.Close() end)
    local Tour = import('/lua/editor/gui/tour.lua')
    Look('tour', function() Tour.Start() end, function() Tour.Stop(true) end)
    return n, problems
end

--- Every widget of the panels a workspace builds, measured at their real sizes in the dock: the UI is rebuilt at `scale` with the widgets recorded.
--- (The layout of a panel depends on the size of the window: a short or narrow dock shows what a tall one hides.) -> widgets checked, list of problems.
function Workspace(name, scale)
    local W = import('/lua/editor/gui/widgets.lua')
    local Shell = import('/lua/editor/gui/shell.lua')
    local list = {}
    W.tracking = list
    local ok, err = pcall(function()
        import('/lua/editor/gui/skin.lua').SetScale(scale or 1)
        Shell.ShowWorkspace(name)
    end)
    W.tracking = false
    if not ok then return 0, { name .. ': ' .. tostring(err) } end
    return Counted(list), Analyze(list, name .. '@' .. math.floor((scale or 1) * 100))
end

local function Splits(node, fn)
    if node and node.kind == 'split' then
        fn(node)
        Splits(node.a, fn)
        Splits(node.b, fn)
    end
end

--- The workspace after the dock area got smaller (what a window resize does: the shell calls SetRect with the new size) and after every row split was pulled to its
--- narrowest and every column split to its shortest. The controls that were built or placed again are measured.
function Resize(name, scale)
    local W = import('/lua/editor/gui/widgets.lua')
    local Shell = import('/lua/editor/gui/shell.lua')
    local Skin = import('/lua/editor/gui/skin.lua')
    local tag = name .. '@' .. math.floor((scale or 1) * 100)
    local problems, n = {}, 0
    local ok, err = pcall(function()
        Skin.SetScale(scale or 1)
        local first = {}
        W.tracking = first
        Shell.ShowWorkspace(name)
        W.tracking = false
        local main = Shell.S.main
        local x, y, w, h = main.x, main.y, main.w, main.h
        -- what is measured after each change: the controls of the first layout (the panels place them again) and the ones built meanwhile
        local function Look(what, change)
            local fresh = {}
            W.tracking = fresh
            change()
            W.tracking = false
            local all = {}
            for _, e in first do table.insert(all, e) end
            for _, e in fresh do table.insert(all, e) end
            n = n + Counted(all)
            for _, p in Analyze(all, tag .. ' ' .. what) do table.insert(problems, p) end
        end
        -- a smaller window
        Look('smaller window', function() main:SetRect(x, y, math.floor(w * 0.7), math.floor(h * 0.8)) end)
        -- the narrowest docks: every split pulled to its end
        Look('narrowest docks', function()
            Splits(main.tree, function(s) s.ratio = 0.02 end)
            main:Layout()
        end)
        Look('widest first docks', function()
            Splits(main.tree, function(s) s.ratio = 0.98 end)
            main:Layout()
        end)
    end)
    W.tracking = false
    if not ok then table.insert(problems, tag .. ': resize test failed: ' .. tostring(err)) end
    return n, problems
end
