-- The layout check: buttons, sliders and text fields stay inside their area and do not run into each other. Used by scripts/editor_nightly.py (step `layout`).
--
--   Panel(panelId[, scale])  -> widgets checked, list of problems   the panel is shown (as the click sweep does) and its widgets, and those of the dialogs its buttons open, are measured
--   Dialogs() / Shell()      -> widgets checked, list of problems   the dialogs of the menus, the top bar / play bar / start screen / tour
--
-- Problems (each "where > label: what"):
--   past area     the widget's left / right edge is outside the group it was built in (Maui does not clip: it is drawn over the neighbouring panel)
--   label wider   a button's text is wider than the button
--   overlap       two widgets of one group cover each other (more than 3 px in both directions)
-- Widgets a scrolling panel moved out of view (top far above / below the screen) or hidden ones are not measured.
--
-- Lua 5.0 dialect.

local ClickSweep = import('/lua/editor/clicksweep.lua')
local TipCheck = import('/lua/editor/tipcheck.lua')

local SLACK = 1
local OVERLAP = 3

local function Object(e) return e.button or e.slider or e.field end

local function Label(e)
    local t = e.text
    if t == nil or t == '' then
        local ok, text = pcall(function() return e.button and e.button.label:GetText() end)
        t = ok and text or '?'
    end
    return tostring(t)
end

--- { l, t, r, b, parent } of a tracked widget, or nil when it is destroyed, hidden or scrolled out of view.
local function Rect(e)
    local o = Object(e)
    if not o then return nil end
    local ok, parent = pcall(function() return o:GetParent() end)
    if not ok or parent == nil then return nil end
    local ok2, hidden = pcall(function() return o:IsHidden() end)
    if ok2 and hidden then return nil end
    local ok3, l, t, r, b = pcall(function() return o.Left(), o.Top(), o.Right(), o.Bottom() end)
    if not ok3 or not l or not r then return nil end
    if t < -5000 or t > 20000 or l < -2000 or l > 20000 then return nil end
    if r - l < 2 then return nil end
    return { l = l, t = t, r = r, b = b, parent = parent }
end

local function Same(a, b) return a == b end

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

--- The problems of a list of tracked entries (W.tracking) -> list of strings.
function Analyze(entries, where)
    local out = {}
    local rects = {}
    for i, e in entries do
        local rc = Rect(e)
        if rc then
            rects[i] = rc
            local name = where .. ' > ' .. Label(e)
            local pid = PanelOf(Object(e))
            if pid and not string.find(where, pid, 1, true) then name = name .. ' [' .. pid .. ']' end
            local ok, pl, pr = pcall(function() return rc.parent.Left(), rc.parent.Right() end)
            if ok and pl and pr then
                if rc.r > pr + SLACK then
                    table.insert(out, name .. ': past area (right edge ' .. (rc.r - pr) .. ' px beyond its group)')
                elseif rc.l < pl - SLACK then
                    table.insert(out, name .. ': past area (left edge ' .. (pl - rc.l) .. ' px beyond its group)')
                end
            end
            if e.button and e.button.label then
                local okw, lw = pcall(function() return e.button.label.Width() end)
                if okw and lw and lw > (rc.r - rc.l) then
                    table.insert(out, name .. ': label wider than the button (' .. lw .. ' > ' .. (rc.r - rc.l) .. ')')
                end
            end
        end
    end
    for i, a in rects do
        for j, b in rects do
            if j > i and Same(a.parent, b.parent) then
                local ox = math.min(a.r, b.r) - math.max(a.l, b.l)
                local oy = math.min(a.b, b.b) - math.max(a.t, b.t)
                if ox > OVERLAP and oy > OVERLAP then
                    table.insert(out, where .. ' > ' .. Label(entries[i]) .. ' / ' .. Label(entries[j]) .. ': overlap (' .. ox .. ' x ' .. oy .. ' px) at ' .. a.l .. ',' .. a.t .. ',' .. a.r .. ',' .. a.b .. ' and ' .. b.l .. ',' .. b.t .. ',' .. b.r .. ',' .. b.b)
                end
            end
        end
    end
    return out
end

--- The widgets of a panel and of the dialogs its buttons open.
function Panel(panelId)
    local problems, n, seen = {}, 0, {}
    local function Collect(entries, where)
        for _, e in entries do
            if Rect(e) then n = n + 1 end
        end
        for _, p in Analyze(entries, where) do
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

--- Dialogs of the menus (tipcheck.lua opens each one and calls Visit with its widgets).
function Dialogs()
    local problems, n = {}, 0
    TipCheck.Visit = function(entries, where)
        for _, e in entries do
            if Rect(e) then n = n + 1 end
        end
        for _, p in Analyze(entries, where) do table.insert(problems, p) end
    end
    pcall(TipCheck.Dialogs)
    TipCheck.Visit = false
    return n, problems
end

--- Top bar, play bar, start screen, tour.
function Shell()
    local problems, n = {}, 0
    TipCheck.Visit = function(entries, where)
        for _, e in entries do
            if Rect(e) then n = n + 1 end
        end
        for _, p in Analyze(entries, where) do table.insert(problems, p) end
    end
    pcall(TipCheck.Shell)
    TipCheck.Visit = false
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
    local n = 0
    for _, e in list do
        if Rect(e) then n = n + 1 end
    end
    return n, Analyze(list, name .. '@' .. math.floor((scale or 1) * 100))
end
