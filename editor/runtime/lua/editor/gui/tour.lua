-- The first-run tour: a dimmed screen with one part of the window lit up at a time and a short text beside it (Back / Next / Skip). It starts by itself once after the
-- first start screen (gui/feature_start.lua) and any time from Help > Tutorial.
--
--   Start()   begins at step 1 (switches to the Terrain workspace so the panels the text talks about are there); Stop() ends it; IsOpen()
--   Steps     the list of { target, title, text }; target = 'center' | 'bar' | 'status' | 'panel:<id>' (the first existing of 'panel:a,b')
--
-- The lit rectangle comes from the dock (the stack that holds the panel) and the shell's bars, so it follows the user's own layout; a step whose panel is not in the layout is skipped.
--
-- Lua 5.0 dialect.

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local UserData = import('/lua/editor/userdata.lua')

Steps = {
    { target = 'center', title = 'Welcome to FAF Studio',
      text = 'A short tutorial of the editor window. Click Skip to close it at any time. Help > Tutorial starts it again.' },
    { target = 'bar', title = 'Menus and workspaces',
      text = 'The menus list every command. The buttons below them switch the workspace: Terrain, Objects, Environment, Generate, Mission, Mod and Review (Alt+1 to Alt+7). Each workspace has its own tools and panels.' },
    { target = 'panel:tools', title = 'Tools',
      text = 'Pick a tool here, then use it in the viewport. Number keys 1 to 8 select the first eight tools. Undo, Redo, Save map and Play test are further down (scroll the panel with the mouse wheel).' },
    { target = 'panel:viewport', title = 'Viewport',
      text = 'The live map. Use the mouse wheel to zoom, the middle button to pan and the right button to rotate; W A S D move the camera. Click and drag to use the active tool.' },
    { target = 'panel:brush,properties', title = 'Tool settings',
      text = 'The Brush panel sets radius, strength and falloff; hold Shift while painting to invert the brush. The Properties panel shows the settings of the active tool, or the values of the selected object.' },
    { target = 'panel:console,validation', title = 'Messages and checks',
      text = 'The console shows what the editor did. The Validation tab finds problems with the map, such as unusable resource markers. Click Check now to run it.' },
    { target = 'status', title = 'Status line',
      text = 'Shows the pointer position, the active tool, how many steps can be undone and the last message.' },
    { target = 'center', title = 'Where to go from here',
      text = 'F1 opens Help with step-by-step topics, Ctrl+Shift+P opens the command palette and File > Start screen shows the start page. A good first read: the topic "Terrain from nothing".' },
}

local current = false

function IsOpen()
    return current ~= false
end

function Stop(finished)
    if current then
        local g = current.group
        current = false
        g:Destroy()
    end
    UserData.Set('tourDone', true)
    UserData.Set('tourPending', false)
    UserData.Flush()
end

--- Rectangle { x, y, w, h } of what a step lights up, or nil when it is not there (a layout without that panel).
local function TargetRect(target)
    local shell = import('/lua/editor/gui/shell.lua')
    local S = shell.S
    if target == 'center' then return 'center' end
    if target == 'bar' then
        local b = S.bar
        if b then return { 0, 0, b.Width(), b.Height() } end
        return nil
    end
    if target == 'status' then
        local s = S.status
        if s then return { s.Left(), s.Top(), s.Width(), s.Height() } end
        return nil
    end
    local ids = string.gsub(target, '^panel:', '')
    for id in string.gfind(ids, '[^,]+') do
        local Dock = import('/lua/editor/gui/dock.lua')
        local stack = S.main and S.main.tree and Dock.FindStack(S.main.tree, id)
        if stack and stack.rect then
            S.main:ShowPanel(id)
            local r = stack.rect
            return { r[1], r[2], r[3], r[4] }
        end
    end
    return nil
end

local function Build(index)
    local state = current
    if state.view then state.view:Destroy() end
    local frame = GetFrame(0)
    local c = Skin.color
    local fw, fh = frame.Width(), frame.Height()
    local step = Steps[index]
    local rect = TargetRect(step.target)
    local g = Group(state.group)
    state.view = g
    g.Depth:Set(function() return state.group.Depth() + 1 end)
    g.Left:Set(0) g.Top:Set(0) g.Width:Set(fw) g.Height:Set(fh)

    local function Shade(x, y, w, h)
        if w <= 0 or h <= 0 then return end
        local b = Bitmap(g)
        b.Depth:Set(function() return g.Depth() + 1 end)
        b:SetSolidColor('a0000000')
        b.Left:Set(x) b.Top:Set(y) b.Width:Set(w) b.Height:Set(h)
        b.HandleEvent = function(self, event) return true end      -- the dimmed parts take every click: the tour is steered with its own buttons
    end
    local hole
    if rect and rect ~= 'center' then
        local pad = Skin.S(3)
        local x, y = math.max(0, rect[1] - pad), math.max(0, rect[2] - pad)
        local w, h = math.min(fw - x, rect[3] + 2 * pad), math.min(fh - y, rect[4] + 2 * pad)
        hole = { x, y, w, h }
        Shade(0, 0, fw, y)
        Shade(0, y + h, fw, fh - y - h)
        Shade(0, y, x, h)
        Shade(x + w, y, fw - x - w, h)
        local t = Skin.S(2)
        for _, e in { { x, y, w, t }, { x, y + h - t, w, t }, { x, y, t, h }, { x + w - t, y, t, h } } do
            local edge = Bitmap(g)
            edge.Depth:Set(function() return g.Depth() + 2 end)
            edge:SetSolidColor(c.accent)
            edge:DisableHitTest()
            edge.Left:Set(e[1]) edge.Top:Set(e[2]) edge.Width:Set(e[3]) edge.Height:Set(e[4])
        end
    else
        Shade(0, 0, fw, fh)
    end

    -- the callout box
    local bw = Skin.S(360)
    local lines
    local box = Group(g)
    box.panelId = 'tour'
    box.Depth:Set(function() return g.Depth() + 5 end)
    box.Left:Set(0) box.Top:Set(0) box.Width:Set(bw) box.Height:Set(10)
    local title = W.Label(box, step.title, Skin.S(14), Skin.S(10), { color = c.accent, size = 15 })
    lines = W.Paragraph(box, step.text, Skin.S(14), Skin.S(38), bw - Skin.S(28), { color = c.text }, Skin.S(18))
    local textBottom = Skin.S(38) + table.getn(lines) * Skin.S(18)
    local bh = textBottom + Skin.S(52)
    -- position: right of the lit part when there is room, else left, else below / above; centred for the steps about nothing in particular
    local x, y
    if not hole then
        x, y = math.floor((fw - bw) / 2), math.floor((fh - bh) / 2)
    else
        local gap = Skin.S(14)
        if hole[1] + hole[3] + gap + bw <= fw then x = hole[1] + hole[3] + gap
        elseif hole[1] - gap - bw >= 0 then x = hole[1] - gap - bw
        else x = math.max(0, math.floor((fw - bw) / 2)) end
        y = math.max(Skin.S(8), math.min(fh - bh - Skin.S(8), hole[2] + math.floor(hole[4] / 2) - math.floor(bh / 2)))
        if x < hole[1] + hole[3] and x + bw > hole[1] then      -- it would cover the lit part: put it below or above
            x = math.max(Skin.S(8), math.min(fw - bw - Skin.S(8), hole[1]))
            if hole[2] + hole[4] + gap + bh <= fh then y = hole[2] + hole[4] + gap else y = math.max(Skin.S(8), hole[2] - gap - bh) end
        end
    end
    box.Left:Set(x) box.Top:Set(y) box.Width:Set(bw) box.Height:Set(bh)
    local edge = Bitmap(box)
    edge.Depth:Set(function() return box.Depth() + 1 end)
    edge:SetSolidColor(c.accent)
    edge.Left:Set(function() return box.Left() end) edge.Top:Set(function() return box.Top() end)
    edge.Width:Set(bw) edge.Height:Set(bh)
    local fill = Bitmap(box)
    fill.Depth:Set(function() return box.Depth() + 2 end)
    fill:SetSolidColor(c.panel)
    fill.Left:Set(function() return box.Left() + 1 end) fill.Top:Set(function() return box.Top() + 1 end)
    fill.Width:Set(bw - 2) fill.Height:Set(bh - 2)
    fill.HandleEvent = function(self, event) return true end
    title.Depth:Set(function() return box.Depth() + 10 end)
    for _, l in lines do l.Depth:Set(function() return box.Depth() + 10 end) end
    local function Raise(ctl) ctl.Depth:Set(function() return box.Depth() + 12 end) return ctl end

    local total = table.getn(Steps)
    local counter = W.Label(box, index .. ' / ' .. total, Skin.S(14), bh - Skin.S(36), { color = c.textDim, size = 'small' })
    counter.Depth:Set(function() return box.Depth() + 10 end)
    local by = bh - Skin.S(40)
    local last = (index == total)
    Raise(W.Button(box, last and 'Done' or 'Next', bw - Skin.S(14) - Skin.S(84), by, Skin.S(84), Skin.S(28), function()
        if last then Stop(true) else state.Go(index + 1, 1) end
    end))
    if index > 1 then
        Raise(W.Button(box, 'Back', bw - Skin.S(14) - Skin.S(84) * 2 - Skin.S(8), by, Skin.S(84), Skin.S(28), function() state.Go(index - 1, -1) end))
    end
    if not last then
        Raise(W.Button(box, 'Skip', Skin.S(70), by, Skin.S(70), Skin.S(28), function() Stop(true) end))
    end
end

--- Shows step `index`; a step that has nothing to light up in this layout is passed over in the direction of travel.
local function Go(index, dir)
    local total = table.getn(Steps)
    while index >= 1 and index <= total do
        local rect = TargetRect(Steps[index].target)
        if rect then break end
        index = index + (dir or 1)
    end
    if index < 1 then index = 1 end
    if index > total then Stop(true) return end
    Build(index)
end

function Start()
    if current then Stop() end
    local shell = import('/lua/editor/gui/shell.lua')
    if shell.S.current ~= 'Terrain' then shell.ShowWorkspace('Terrain') end
    import('/lua/editor/gui/startscreen.lua').Close()
    import('/lua/editor/gui/dialog.lua').Close()
    local frame = GetFrame(0)
    local group = Group(frame)
    group.Depth:Set(9450)
    group.Left:Set(0) group.Top:Set(0) group.Width:Set(frame.Width()) group.Height:Set(frame.Height())
    current = { group = group, Go = Go }
    Go(1, 1)
end
