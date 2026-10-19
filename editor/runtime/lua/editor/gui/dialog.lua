-- A modal dialog: a dimmed screen, a framed box centred (or at the upper third) with a title; a click outside closes it. The caller adds its
-- controls to `d.group` (positions relative to the box) and calls d:Close() when done. One dialog at a time. Enter in a d:Field presses the dialog's first button that is not
-- Cancel, Escape in it closes the dialog.
--
--   local d = Dialog.Open('Title', width, height)      logical pixels (Skin.S applied here)
--   d.group, d.width, d.height (scaled), d:Close(), d:Label(text, x, y, opts), d:Button(text, x, y, w, h, onClick, opts)
--
-- Controls made with W.* on d.group get a depth below the box's content; d:Label / d:Button / d:Field fix that; for anything else call d:Raise(control).
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')

local current = false

function Close()
    if current then
        local d = current
        current = false
        d.group:Destroy()
        if d.onClose then pcall(d.onClose) end
    end
end

function IsOpen()
    return current ~= false
end

function Open(title, width, height, onClose)
    Close()
    local frame = GetFrame(0)
    local c = Skin.color
    local w, h = Skin.S(width), Skin.S(height)
    local fw, fh = frame.Width(), frame.Height()
    local group = Group(frame)
    group.panelId = 'dialog'          -- (the scope of the tooltip texts of a dialog's widgets, tooltips.lua)
    group.Depth:Set(9500)
    group.Left:Set(math.floor((fw - w) / 2)) group.Top:Set(math.max(Skin.S(20), math.floor((fh - h) / 3)))
    group.Width:Set(w) group.Height:Set(h)

    local shade = Bitmap(group)
    shade.Depth:Set(function() return group.Depth() + 1 end)
    shade:SetSolidColor('70000000')
    shade.Left:Set(0) shade.Top:Set(0) shade.Width:Set(fw) shade.Height:Set(fh)
    shade.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' then Close() end
        return true
    end
    local box = Bitmap(group)
    box.Depth:Set(function() return group.Depth() + 2 end)
    box:SetSolidColor(c.line)
    box.Left:Set(function() return group.Left() end) box.Top:Set(function() return group.Top() end)
    box.Width:Set(w) box.Height:Set(h)
    local inner = Bitmap(group)
    inner.Depth:Set(function() return group.Depth() + 3 end)
    inner:SetSolidColor(c.panel)
    inner.Left:Set(function() return group.Left() + 1 end) inner.Top:Set(function() return group.Top() + 1 end)
    inner.Width:Set(w - 2) inner.Height:Set(h - 2)
    inner.HandleEvent = function(self, event) return true end        -- clicks on the box itself do not fall through to the shade

    local d = { group = group, width = w, height = h, onClose = onClose }

    function d:Raise(control)
        control.Depth:Set(function() return group.Depth() + 6 end)
        return control
    end
    function d:Label(text, x, y, opts)
        return d:Raise(W.Label(group, text, Skin.S(x), Skin.S(y), opts or { color = c.text }))
    end
    function d:Button(text, x, y, bw, bh, onClick, opts)
        -- the first button that is not Cancel is the default one: Enter in a text field presses it
        if not d.defaultAction and text ~= 'Cancel' and onClick then d.defaultAction = onClick end
        return d:Raise(W.Button(group, text, Skin.S(x), Skin.S(y), Skin.S(bw), Skin.S(bh), onClick, opts))
    end
    function d:Field(x, y, fw2, fh2, opts)
        local f = W.TextField(group, Skin.S(x), Skin.S(y), Skin.S(fw2), Skin.S(fh2), opts)
        -- Enter presses the default button (unless the caller handles it), Escape closes the dialog
        if not (opts and opts.onEnter) then
            f.OnEnterPressed = function(self, text)
                if d.defaultAction then d.defaultAction(d) end
                return true
            end
        end
        if not (opts and opts.onEscape) then
            f.OnEscPressed = function(self, text) Close() return true end
        end
        f.Depth:Set(function() return group.Depth() + 7 end)
        f.frame.Depth:Set(function() return group.Depth() + 6 end)
        return f
    end
    function d:Close() Close() end

    d:Label(title, 12, 8, { color = c.textDim })
    current = d
    return d
end
