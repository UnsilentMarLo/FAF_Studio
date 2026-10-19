-- Tooltips: a small framed text near the pointer after it rested on a button or a tab for a moment.
--
--   Hover(control, text, event, opts)   call from a control's MouseEnter; `text` is a string or a function returning one (nil / '' = no tooltip); opts.menu = true: shown while a menu is open
--                                 (the rows of the menu itself)
--
-- Text: a line break (\n) starts a new paragraph (each wraps at 280 pixels); a paragraph that starts with '@' is the shortcut line (dim: `@Shortcut: Ctrl+Z`, tooltips.lua WithHotkey).
--   Leave(control)                call from MouseExit (also hides it); Hide() hides whatever is shown
--
-- The pointer position is the one of the event (or GetMouseScreenPos()). One tooltip at a time; any click hides it. While a menu is open only the menu's own rows show one.
--
-- Lua 5.0 dialect.

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Skin = import('/lua/editor/gui/skin.lua')
local W = import('/lua/editor/gui/widgets.lua')

DELAY = 0.55        -- seconds the pointer rests before the tooltip appears

local pending = false       -- { control, text, x, y, time }
local shown = false         -- the group on screen
local poller = false

function Hide()
    pending = false
    if shown then
        local g = shown
        shown = false
        g:Destroy()
    end
end

local function Pointer(event)
    if event and event.MouseX then return event.MouseX, event.MouseY end
    if rawget(_G, 'GetMouseScreenPos') then
        local p = GetMouseScreenPos()
        if p then return p[1], p[2] end
    end
    return 0, 0
end

local function Blocked(allowMenu)
    if allowMenu then return false end
    -- while a menu is open the controls behind it show nothing (a dialog's own controls do: the tooltip is above the dialog)
    local ok1, Menu = pcall(import, '/lua/editor/gui/menu.lua')
    if ok1 and Menu.IsOpen and Menu.IsOpen() then return true end
    return false
end

local function Show()
    local p = pending
    pending = false
    local text = p.text
    if type(text) == 'function' then text = text() end
    if not text or text == '' then return end
    if Blocked(p.menu) then return end
    local frame = GetFrame(0)
    local c = Skin.color
    local maxW = Skin.S(280)
    local g = Group(frame)
    g.Depth:Set(9800)
    g.Left:Set(0) g.Top:Set(0) g.Width:Set(10) g.Height:Set(10)
    local lines = {}
    local y = Skin.S(5)
    local textW = 0
    for para in string.gfind(text .. '\n', '([^\n]*)\n') do
        if para ~= '' then
            local dim = string.sub(para, 1, 1) == '@'
            if dim then para = string.sub(para, 2) end
            local ls, ny = W.Paragraph(g, para, Skin.S(8), y, maxW - Skin.S(16), { color = dim and c.textDim or c.text, size = 'small' }, Skin.S(16))
            for _, l in ls do
                table.insert(lines, l)
                textW = math.max(textW, l.Width())
            end
            y = ny
        end
    end
    local w, h = math.min(maxW, textW + Skin.S(16)), y + Skin.S(5)
    local x, y = p.x + Skin.S(14), p.y + Skin.S(20)
    if x + w > frame.Width() then x = math.max(0, frame.Width() - w - Skin.S(4)) end
    if y + h > frame.Height() then y = math.max(0, p.y - h - Skin.S(6)) end
    g.Left:Set(x) g.Top:Set(y) g.Width:Set(w) g.Height:Set(h)
    local edge = Bitmap(g)
    edge.Depth:Set(function() return g.Depth() + 1 end)
    edge:SetSolidColor(c.line)
    edge.Left:Set(function() return g.Left() end) edge.Top:Set(function() return g.Top() end)
    edge.Width:Set(w) edge.Height:Set(h)
    edge:DisableHitTest()
    local inner = Bitmap(g)
    inner.Depth:Set(function() return g.Depth() + 2 end)
    inner:SetSolidColor(c.panelAlt)
    inner.Left:Set(function() return g.Left() + 1 end) inner.Top:Set(function() return g.Top() + 1 end)
    inner.Width:Set(w - 2) inner.Height:Set(h - 2)
    inner:DisableHitTest()
    for _, l in lines do l.Depth:Set(function() return g.Depth() + 10 end) end
    g:DisableHitTest()
    shown = g
end

local function EnsurePoller()
    if poller then return end
    local frame = GetFrame(0)
    poller = Bitmap(frame)
    poller:SetSolidColor('00000000')
    poller.Left:Set(0) poller.Top:Set(0) poller.Width:Set(1) poller.Height:Set(1)
    poller:DisableHitTest()
    poller:SetNeedsFrameUpdate(true)
    poller.OnFrame = function(self, delta)
        if pending and GetSystemTimeSeconds() - pending.time >= DELAY then
            local ok, err = pcall(Show)
            if not ok then
                pending = false
                LOG('EDITOR tooltip: ' .. tostring(err))
            end
        end
    end
end

function Hover(control, text, event, opts)
    Hide()
    if not text then return end
    EnsurePoller()
    local x, y = Pointer(event)
    pending = { control = control, text = text, x = x, y = y, time = GetSystemTimeSeconds(), menu = opts and opts.menu }
end

function Leave(control)
    if pending and pending.control ~= control then return end
    Hide()
end

--- Forgets the poller (a new session builds a fresh one; the old control died with the frame).
function Reset()
    pending = false
    shown = false
    poller = false
end

--- 'idle' | 'waiting' | 'shown', for the self test.
function State()
    if shown then return 'shown' end
    if pending then return 'waiting' end
    return 'idle'
end
