-- A modal dialog: a dimmed screen, a framed box centred (or at the upper third) with a title; a click outside closes it. The caller adds its
-- controls to `d.group` (positions relative to the box) and calls d:Close() when done. One dialog at a time. Enter in a d:Field presses the dialog's first button that is not
-- Cancel, Escape in it closes the dialog.
--
--   local d = Dialog.Open('Title', width, height)      logical pixels (Skin.S applied here)
--   d.group, d.width, d.height (scaled), d:Close(), d:Label(text, x, y, opts), d:Button(text, x, y, w, h, onClick, opts)
--   d:Flow(items, y, h[, x])                           places buttons / fields in rows across the box (W.Flow), wrapping when the box is narrow: items { { control, logical width }, ... }
--
-- The box is never larger than the window: it is clamped to the window (a margin of 12 logical pixels) and follows a window resize. What does not fit the box scrolls: d.group is a
-- scrolling content group (W.ScrollContent: the mouse wheel, an overlay bar; sideways with Shift + wheel when the controls are wider than the box), so a dialog laid out
-- for 620 x 470 stays usable in a 1280 x 720 window at UI 200 %. The title and every d:Label are cut to the box's width (opts.nofit: not).
--
-- Controls made with W.* on d.group are above the box; d:Label / d:Button / d:Field / d:Raise give them the depth the dialog's own controls have.
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
        pcall(W.ScrollRelease, d.group)
        d.root:Destroy()
        if d.onClose then pcall(d.onClose) end
    end
end

function IsOpen()
    return current ~= false
end

--- The box of the open dialog in window coordinates { l, t, r, b } (nil without one): the layout check measures it against the window.
function Rect()
    if not current then return nil end
    local g = current.root
    return { l = g.Left(), t = g.Top(), r = g.Left() + g.Width(), b = g.Top() + g.Height() }
end

local MARGIN = 12      -- logical pixels between the box and the window edge

function Open(title, width, height, onClose)
    Close()
    local frame = GetFrame(0)
    local c = Skin.color
    local wantW, wantH = Skin.S(width), Skin.S(height)
    local margin = Skin.S(MARGIN)
    -- the box: as designed, but never larger than the window less its margins; centred, in the upper third when there is room
    local function Dims()
        local fw, fh = frame.Width(), frame.Height()
        local w = math.max(Skin.S(160), math.min(wantW, fw - 2 * margin))
        local h = math.max(Skin.S(100), math.min(wantH, fh - 2 * margin))
        local top = math.max(margin, math.floor((fh - h) / 3))
        if top + h > fh - margin then top = math.max(0, fh - margin - h) end
        return { math.floor((fw - w) / 2), top, w, h }
    end
    local dims = Dims()
    local w, h = dims[3], dims[4]
    local group = Group(frame)
    group.Depth:Set(9500)
    group.Left:Set(function() return Dims()[1] end)
    group.Top:Set(function() return Dims()[2] end)
    group.Width:Set(function() return Dims()[3] end)
    group.Height:Set(function() return Dims()[4] end)

    local shade = Bitmap(group)
    shade.Depth:Set(function() return group.Depth() + 1 end)
    shade:SetSolidColor('70000000')
    shade.Left:Set(0) shade.Top:Set(0)
    shade.Width:Set(function() return frame.Width() end) shade.Height:Set(function() return frame.Height() end)
    shade.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' then Close() end
        return true
    end
    local box = Bitmap(group)
    box.Depth:Set(function() return group.Depth() + 2 end)
    box:SetSolidColor(c.line)
    box.Left:Set(function() return group.Left() end) box.Top:Set(function() return group.Top() end)
    box.Width:Set(function() return group.Width() end) box.Height:Set(function() return group.Height() end)
    local inner = Bitmap(group)
    inner.Depth:Set(function() return group.Depth() + 3 end)
    inner:SetSolidColor(c.panel)
    inner.Left:Set(function() return group.Left() + 1 end) inner.Top:Set(function() return group.Top() + 1 end)
    inner.Width:Set(function() return group.Width() - 2 end) inner.Height:Set(function() return group.Height() - 2 end)
    inner.HandleEvent = function(self, event) return true end        -- clicks on the box itself do not fall through to the shade

    -- the content: a scrolling group over the whole box (the title strip at the top is not scrolled under)
    local holder = Group(group)
    holder.Depth:Set(function() return group.Depth() + 4 end)
    holder.Left:Set(function() return group.Left() end) holder.Top:Set(function() return group.Top() end)
    holder.Width:Set(function() return group.Width() end) holder.Height:Set(function() return group.Height() end)
    holder:DisableHitTest()
    local content = W.ScrollContent(holder, nil)
    content.panelId = 'dialog'          -- (the scope of the tooltip texts of a dialog's widgets, tooltips.lua)
    group.panelId = 'dialog'
    content.scroll.inset = Skin.S(28)
    local catch = content.scroll.catcher
    local wheel = catch.HandleEvent
    catch.HandleEvent = function(self, event)           -- the box swallows what it does not use
        wheel(self, event)
        return true
    end

    local d = { group = content, root = group, width = w, height = h, onClose = onClose }

    function d:Raise(control)
        control.Depth:Set(function() return group.Depth() + 6 end)
        return control
    end
    --- A label: its text is cut to what is left of the box to the right of x (unless opts.nofit); a status line keeps the cut when its text changes later.
    function d:Label(text, x, y, opts)
        opts = opts or { color = c.text }
        local sx = Skin.S(x)
        local o = {}
        for k, v in opts do o[k] = v end
        if not o.maxW and not o.nofit then
            o.maxW = function() return group.Width() - sx - Skin.S(16) end
        end
        return d:Raise(W.Label(content, text, sx, Skin.S(y), o))
    end
    function d:Button(text, x, y, bw, bh, onClick, opts)
        -- the first button that is not Cancel is the default one: Enter in a text field presses it
        if not d.defaultAction and text ~= 'Cancel' and onClick then d.defaultAction = onClick end
        return d:Raise(W.Button(content, text, Skin.S(x), Skin.S(y), Skin.S(math.min(bw, d:Span(x, 16))), Skin.S(bh), onClick, opts))
    end
    function d:Field(x, y, fw2, fh2, opts)
        local f = W.TextField(content, Skin.S(x), Skin.S(y), Skin.S(math.min(fw2, d:Span(x, 16))), Skin.S(fh2), opts)
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
    --- Controls in rows across the box, wrapping to a new row when the next one does not fit: items { { control, logical width }, ... }, `y` and `h` logical, `x` the left edge (default 14).
    --- A control wider than the room is narrowed to it. Returns the logical y below the last row.
    function d:Flow(items, y, h, x)
        x = x or 14
        local list = {}
        for _, it in items do list[table.getn(list) + 1] = { d:Raise(it[1]), Skin.S(it[2]) } end
        local bottom = W.Flow(content, list, Skin.S(x), Skin.S(y), d.width - Skin.S(x) - Skin.S(18), Skin.S(h), Skin.S(6))
        return math.floor(bottom / math.max(0.5, Skin.scale) + 0.5)
    end
    --- Word-wrapped text in the box: d:Text(text, x, y[, opts]) (opts: color, size, lineH logical) -> the logical y below the last line. A hint that was a single long label.
    function d:Text(text, x, y, opts)
        opts = opts or {}
        local small = opts.size == 'small'
        local lineH = Skin.S(opts.lineH or (small and 15 or 18))
        local labels, bottom = W.Paragraph(content, text, Skin.S(x), Skin.S(y), math.max(Skin.S(60), d.width - Skin.S(x) - Skin.S(18)),
            { color = opts.color or c.textDim, size = opts.size }, lineH)
        for _, l in labels do d:Raise(l) end
        return math.floor(bottom / math.max(0.5, Skin.scale) + 0.5)
    end
    --- The logical width left of the box from x to its right margin (default 14): what a field or a slider that spans the box may be.
    function d:Span(x, margin)
        return math.max(60, math.floor(d.width / math.max(0.5, Skin.scale) + 0.5) - x - (margin or 18))      -- (the default margin keeps clear of the overlay scrollbar)
    end
    --- A designed rectangle (logical x, y, w, h) kept inside the box: -> scaled x, y, w, h. `below`: logical room kept under it (for the buttons at the bottom).
    function d:Room(x, y, rw, rh, below)
        local sx, sy = Skin.S(x), Skin.S(y)
        local sw = math.max(Skin.S(60), math.min(Skin.S(rw), d.width - sx - Skin.S(8)))
        local sh = math.max(Skin.S(44), math.min(Skin.S(rh), d.height - sy - Skin.S(below or 8)))
        return sx, sy, sw, sh
    end
    function d:Close() Close() end

    -- the title is cut to the box; the box follows a window resize (its sizes are lazy) and the scroll range is read again
    local titleLabel = W.Label(group, title, Skin.S(12), Skin.S(8), { color = c.textDim, maxW = function() return group.Width() - Skin.S(24) end })
    local fw0, fh0 = frame.Width(), frame.Height()
    local frames = 0
    local poller = Bitmap(group)
    poller:SetSolidColor('00000000')
    poller.Left:Set(0) poller.Top:Set(0) poller.Width:Set(1) poller.Height:Set(1)
    poller:DisableHitTest()
    poller:SetNeedsFrameUpdate(true)
    poller.OnFrame = function(self, delta)
        frames = frames + 1
        local fw, fh = frame.Width(), frame.Height()
        if fw ~= fw0 or fh ~= fh0 then
            fw0, fh0 = fw, fh
            d.width, d.height = Dims()[3], Dims()[4]
            pcall(titleLabel.Refit, titleLabel)
            pcall(content.scroll.Update, content.scroll)
        elseif frames == 2 or frames == 6 then
            pcall(content.scroll.Update, content.scroll)       -- what the caller built after Open returned
        end
    end
    current = d
    return d
end
