-- Editor GUI widget kit on the game's own Maui controls. Every widget is placed relative to its parent group with plain
-- numbers, so moving a panel only changes the panel's root position. Maui has no child clipping, so lists scroll by whole rows
-- and only rows that fit completely are shown. Text uses the native `ed:` DirectWrite fonts (LCD by default, `;g` gray).
--
--   Place(control, parent, x, y, w, h)      position relative to parent (w / h nil: leave the size alone)
--   Label(parent, text, x, y, opts)         opts: color, size ('text' | 'small' | number), gray
--   Button(parent, text, x, y, w, h, onClick, opts)     opts: toggle, color, tip (a string or a function returning one: the tooltip; without it the text comes from tooltips.lua by the panel and
--                                                       the button's text), cmd (a command id: its key binding is added to the tooltip); b:SetOn(bool), b:SetText(s), b:TipText() -> text | nil
--   VirtualList(parent, opts)               pooled rows over any number of items; see below
--   TextField(parent, x, y, w, h, opts)     opts: text, onChange(text), onEnter(text), onEscape()

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Text = import('/lua/maui/text.lua').Text
local Edit = import('/lua/maui/edit.lua').Edit
local Dragger = import('/lua/maui/dragger.lua').Dragger
local Skin = import('/lua/editor/gui/skin.lua')

-- ---- tooltips -----------------------------------------------------------------------------------------------------------------------------------

--- The id of the panel (or 'dialog') a control belongs to: the nearest parent that carries a `panelId` (gui/panels.lua puts it on the group a panel builds into).
function ScopeOf(control)
    local c, n = control, 0
    while c and n < 24 do
        if c.panelId then return c.panelId end
        local ok, parent = pcall(function() return c:GetParent() end)
        if not ok then return nil end
        c = parent
        n = n + 1
    end
    return nil
end

local function Tips() return import('/lua/editor/tooltips.lua') end

--- The tooltip text of a widget: `tip` (string or function) when given, else the text tooltips.lua has for (panel, label); `cmd` adds the key binding. nil = none.
function TipFor(control, label, tip, cmd)
    local text = tip
    if type(text) == 'function' then
        local ok, r = pcall(text)
        text = ok and r or nil
    end
    if (not text or text == '') and label then
        local ok, r = pcall(function() return Tips().ForWidget(ScopeOf(control), label) end)
        text = ok and r or nil
    end
    if text and text ~= '' and cmd then
        local ok, r = pcall(function() return Tips().WithHotkey(text, cmd) end)
        if ok and r then text = r end
    end
    if text == '' then text = nil end
    return text
end

--- Hover / leave / press handling every tooltipped control shares. Call from the control's HandleEvent; returns true when the event was a tooltip event only.
local function TipEvent(control, event, textFn)
    if event.Type == 'MouseEnter' then
        pcall(function() import('/lua/editor/gui/tooltip.lua').Hover(control, textFn, event) end)
    elseif event.Type == 'MouseExit' then
        pcall(function() import('/lua/editor/gui/tooltip.lua').Leave(control) end)
    elseif event.Type == 'ButtonPress' then
        pcall(function() import('/lua/editor/gui/tooltip.lua').Hide() end)
    end
end

local function Colors()
    return Skin.color
end

--- Scrolling panels. Maui does not clip, so a panel whose content is taller than the panel would draw over the panel below it. The dock
--- therefore gives every panel a content group (a child of the panel's holder) that is shifted up by the scroll offset, and Place / Label
--- position the panel's direct children with a lazy rule: a control that does not lie completely inside the holder's rectangle is moved off
--- the screen, so only whole controls are ever drawn. The content's height is the lowest edge a Place / Label call has reported; the
--- overlay scrollbar and the mouse wheel appear when it exceeds the panel (ScrollContent, below).
---
--- A panel that rebuilds its controls (Properties) calls BeginLayout(group) before and EndLayout(group) after, so the height is measured anew.
--- A compound widget (Slider) wraps its parts in CullBox(y, h) so all parts appear and disappear together.
local cullBox = false

function CullBox(y, h)
    cullBox = y and { y, h } or false
end

--- The vertical extent used for the cull test and for the content height of a placed control.
local function Extent(ctx, x, y, ch)
    local top, bot = y, y + ch
    if cullBox then top, bot = cullBox[1], cullBox[1] + cullBox[2] end
    if y >= 0 and x > -1000 and bot > ctx.extent then
        ctx.extent = bot
        ctx.dirty = true
    end
    return top, bot
end

--- Lazy vertical position of a direct child of a scroll content group: its place, or off the screen when it is not fully inside the panel.
local function ScrollTop(c, parent, ctx, y, top, bot)
    c.Top:Set(function()
        local t = parent.Top()
        local holder = ctx.holder
        if t + top < holder.Top() or t + bot > holder.Bottom() then return -20000 end
        return t + y
    end)
end

--- Place `c` at (x, y) relative to `parent`; width and height when given (pixels, already scaled).
function Place(c, parent, x, y, w, h)
    local ctx = parent.scroll
    local top, bot
    if ctx then
        top, bot = Extent(ctx, x, y, h or c.Height() or Skin.S(14))
    end
    c.Left:Set(function() return parent.Left() + x end)
    if ctx then
        ScrollTop(c, parent, ctx, y, top, bot)
    else
        c.Top:Set(function() return parent.Top() + y end)
    end
    if w then c.Width:Set(w) end
    if h then c.Height:Set(h) end
end

local function PixelSize(size)
    if type(size) == 'number' then
        return Skin.FontSize(size)
    end
    return Skin.FontSize(Skin.size[size or 'text'])
end

function Label(parent, text, x, y, opts)
    opts = opts or {}
    local t = Text(parent)
    t.Depth:Set(function() return parent.Depth() + 10 end)   -- siblings share a depth by default; text sits above backgrounds
    t:SetNewFont(Skin.Font(opts.gray), PixelSize(opts.size))
    t:SetColor(opts.color or Skin.color.text)
    t:SetText(text or '')
    t:DisableHitTest()
    t.Left:Set(function() return parent.Left() + x end)
    local ctx = parent.scroll
    if ctx then
        local top, bot = Extent(ctx, x, y, t.Height())
        ScrollTop(t, parent, ctx, y, top, bot)
    else
        t.Top:Set(function() return parent.Top() + y end)
    end
    return t
end

--- Places controls in rows, left to right from x, starting a new row when the next one would pass x + width (Maui does not clip: a control past the panel's edge is drawn over its neighbour).
--- items: { { control, w }, ... } (pixels, scaled), `h` the row height, `gap` the space between controls and rows. A control wider than `width` is narrowed to it.
--- Returns the y below the last row. `dry`: only measure (nothing is placed).
function Flow(parent, items, x, y, width, h, gap, dry)
    gap = gap or Skin.S(4)
    local cx, cy = x, y
    for _, it in items do
        local c, iw = it[1], math.min(it[2], width)
        if cx > x and cx + iw > x + width then
            cx = x
            cy = cy + h + gap
        end
        if not dry then
            Place(c, parent, cx, cy, iw, h)
            if c.label and c.label.Width then Center(c.label, c, 0, 0, iw, h) end
        end
        cx = cx + iw + gap
    end
    return cy + h
end

--- Re-places `label` so it is centred in the rectangle (x, y, w, h) of `parent`.
function Center(label, parent, x, y, w, h)
    local tw, th = label.Width(), label.Height()
    local lx, ly = x + math.floor((w - tw) / 2), y + math.floor((h - th) / 2)
    label.Left:Set(function() return parent.Left() + lx end)
    label.Top:Set(function() return parent.Top() + ly end)
end

-- ---- scrolling panel content ----------------------------------------------------------------------------------------------

scrollMemory = {}     -- panel id -> scroll offset in pixels, kept across rebuilds (a new UI scale, a pop-out, a re-created panel)
local scrollLive = {}  -- contexts that exist right now, for the periodic bar update

--- Sets the scroll offset (clamped), moves the content and the scrollbar thumb.
local function ScrollSet(ctx, v)
    v = math.max(0, math.min(ctx.maxOff, v))
    ctx.off = v
    if ctx.id then scrollMemory[ctx.id] = v end
    ctx.content.Top:Set(function() return ctx.holder.Top() - v end)
    ctx:UpdateThumb()
end

--- Content group of a panel: `holder` is the panel's fixed rectangle; the returned group is what `create` builds its controls in. It is
--- shifted up by the scroll offset; the mouse wheel over the panel scrolls it and an overlay scrollbar on the right edge shows the position.
--- `id` keys the remembered scroll position. Returns the content group (`content.scroll` is the context).
function ScrollContent(holder, id)
    local c = Skin.color
    local ctx = { holder = holder, id = id, off = scrollMemory[id] or 0, extent = 0, maxOff = 0, dirty = true }
    -- The content group is shifted up by the scroll offset, so its rectangle reaches over whatever lies above the panel (the tab strip of its dock): a scrolled panel
    -- swallowed every click on its own tab strip. The group is therefore not hit tested; the wheel over the empty parts of the panel is caught by a clear bitmap that stays
    -- on the panel's own rectangle.
    ctx.catcher = Bitmap(holder)
    ctx.catcher:SetSolidColor('00000000')
    ctx.catcher.Depth:Set(function() return holder.Depth() + 1 end)
    ctx.catcher.Left:Set(function() return holder.Left() end)
    ctx.catcher.Top:Set(function() return holder.Top() end)
    ctx.catcher.Width:Set(function() return holder.Width() end)
    ctx.catcher.Height:Set(function() return holder.Height() end)
    local content = Group(holder)
    content.scroll = ctx
    ctx.content = content
    content:DisableHitTest()
    content.Depth:Set(function() return holder.Depth() + 1 end)
    content.Left:Set(function() return holder.Left() end)
    content.Width:Set(function() return holder.Width() end)
    content.Height:Set(function() return holder.Height() end)
    content.Top:Set(function() return holder.Top() - ctx.off end)

    ctx.track = Bitmap(holder)
    ctx.thumb = Bitmap(holder)
    ctx.track.Depth:Set(function() return holder.Depth() + 300 end)
    ctx.thumb.Depth:Set(function() return holder.Depth() + 301 end)
    ctx.track:SetSolidColor('50000000')
    ctx.thumb:SetSolidColor(c.textDim)
    for _, b in { ctx.track, ctx.thumb } do
        b.Left:Set(-20000) b.Top:Set(-20000) b.Width:Set(1) b.Height:Set(1)
        b:Hide()
    end

    local function Step() return Skin.S(48) end

    function ctx:Scroll(delta)
        ScrollSet(ctx, ctx.off + delta)
    end

    --- Thumb size and position from the current offset.
    function ctx:UpdateThumb()
        local view = holder.Height()
        local need = ctx.extent + Skin.S(8)
        if ctx.maxOff <= 0 then
            ctx.track:Hide()
            ctx.thumb:Hide()
            return
        end
        local sw = Skin.S(Skin.size.scrollW)
        local thumbH = math.max(Skin.S(24), math.floor(view * view / need))
        local ty = math.floor((view - thumbH) * ctx.off / ctx.maxOff)
        local tx = holder.Width() - sw
        ctx.thumbH, ctx.range = thumbH, view - thumbH
        Place(ctx.track, holder, tx, 0, sw, view)
        Place(ctx.thumb, holder, tx, ty, sw, thumbH)
        ctx.track:Show()
        ctx.thumb:Show()
    end

    --- Re-reads the content height and the panel height (after a layout, a resize or a rebuild).
    function ctx:Update()
        ctx.dirty = false
        local view = holder.Height()
        -- a panel that overshoots by a few pixels (a list that ends at the panel's padding) does not scroll
        ctx.maxOff = 0
        if ctx.extent > view + Skin.S(10) then ctx.maxOff = ctx.extent + Skin.S(8) - view end
        ScrollSet(ctx, ctx.off)
    end

    ctx.thumb.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            self:SetSolidColor(c.accent)
            return true
        elseif event.Type == 'MouseExit' then
            self:SetSolidColor(c.textDim)
            return true
        elseif event.Type == 'ButtonPress' then
            local startY, startOff = event.MouseY, ctx.off
            local drag = Dragger()
            drag.OnMove = function(d, x, y)
                local per = math.max(1, ctx.range) / math.max(1, ctx.maxOff)
                ScrollSet(ctx, startOff + (y - startY) / per)
            end
            drag.OnRelease = function(d, x, y) d:Destroy() end
            drag.OnCancel = function(d) d:Destroy() end
            PostDragger(self:GetRootFrame(), event.KeyCode, drag)
            return true
        end
        return false
    end
    ctx.track.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' then
            -- a click on the track pages towards the click
            local page = holder.Height() - Skin.S(24)
            if event.MouseY < ctx.thumb.Top() then ctx:Scroll(-page) else ctx:Scroll(page) end
            return true
        end
        return false
    end

    local function Wheel(self, event)
        if event.Type == 'WheelRotation' and ctx.maxOff > 0 then
            ctx:Scroll(event.WheelRotation > 0 and -Step() or Step())
            return true
        end
        return false
    end
    content.HandleEvent = Wheel
    ctx.catcher.HandleEvent = Wheel
    ctx.Wheel = Wheel

    scrollLive[ctx] = true
    return content
end

--- Frees a content group's context (its controls are destroyed with the holder).
function ScrollRelease(content)
    local ctx = content and content.scroll
    if ctx then scrollLive[ctx] = nil end
end

--- A panel that rebuilds its controls calls BeginLayout before and EndLayout after: the content height is measured anew.
function BeginLayout(group)
    local ctx = group.scroll
    if ctx then ctx.extent = 0 end
end

function EndLayout(group)
    local ctx = group.scroll
    if ctx then ctx:Update() end
end

--- Called by the shell's tick: contexts whose content grew since the last update (a Refresh placed something lower) get their bar.
function ScrollTick()
    for ctx, _ in scrollLive do
        if ctx.dirty then pcall(ctx.Update, ctx) end
    end
end

--- Button tracking for the click sweep (clicksweep.lua): while a list is set, every button made is recorded there with its text.
tracking = false

function Button(parent, text, x, y, w, h, onClick, opts)
    opts = opts or {}
    local c = Skin.color
    local b = Bitmap(parent)
    if tracking then table.insert(tracking, { button = b, text = text }) end
    b.Depth:Set(function() return parent.Depth() + 5 end)
    b:SetSolidColor(c.button)
    Place(b, parent, x, y, w, h)
    b.on = false
    b.hot = false
    b.toggle = opts.toggle
    b.label = Label(b, text, 0, 0, { color = opts.color or c.text })
    Center(b.label, b, 0, 0, w, h)
    b.Refresh = function(self)
        local col = c.button
        if self.on then col = c.buttonOn elseif self.hot then col = c.buttonHi end
        self:SetSolidColor(col)
        self.label:SetColor((self.on and c.textOn) or opts.color or c.text)
    end
    b.SetOn = function(self, on)
        self.on = on
        self:Refresh()
    end
    b.SetText = function(self, s)
        self.label:SetText(s)
        Center(self.label, self, 0, 0, w, h)
    end
    b.TipText = function(self) return TipFor(self, self.label:GetText(), opts.tip, opts.cmd) end
    local tipFn = function() return b:TipText() end
    b.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            self.hot = true
            self:Refresh()
            TipEvent(self, event, tipFn)
            return true
        elseif event.Type == 'MouseExit' then
            self.hot = false
            self:Refresh()
            TipEvent(self, event, tipFn)
            return true
        elseif event.Type == 'ButtonPress' then
            TipEvent(self, event, tipFn)
            if self.toggle then self:SetOn(not self.on) end
            if onClick then onClick(self) end
            return true
        end
        return false
    end
    return b
end

--- Virtual list: `opts.getCount()` items, `opts.bind(row, index, selected)` fills a pooled row (row.text is a Text control;
--- `row.bg` the row background), `opts.onSelect(index)`, `opts.onContext(index, x, y)` (right click), `opts.onHover(index)`, `opts.thumb = true` (a square `row.thumb` Bitmap at the left of each row), `opts.rowH` logical pixels. Scrolls by whole rows with the wheel
--- and an overlay scrollbar on the right edge. Methods: SetRect(x, y, w, h), Refresh(), SetSelected(i), ScrollTo(i), Destroy().
function VirtualList(parent, opts)
    local c = Skin.color
    local L = {
        parent = parent, opts = opts, offset = 0, selected = nil, rows = {},
        rowH = Skin.S(opts.rowH or Skin.size.rowH), w = 100, h = 100, x = 0, y = 0,
    }
    L.root = Group(parent)
    L.root.Depth:Set(function() return parent.Depth() + 5 end)
    -- a first position, so that the frame drawn before SetRect does not evaluate the default Left / Width / Right cycle (it logged a 'circular
    -- dependency' warning per list)
    L.root.Left:Set(0) L.root.Top:Set(0) L.root.Width:Set(1) L.root.Height:Set(1)
    L.bg = Bitmap(L.root)
    L.bg:SetSolidColor(opts.bgColor or c.panel)
    L.bg.Left:Set(function() return L.root.Left() end)
    L.bg.Top:Set(function() return L.root.Top() end)
    L.bg.Right:Set(function() return L.root.Right() end)
    L.bg.Bottom:Set(function() return L.root.Bottom() end)
    L.track = Bitmap(L.root)
    L.thumb = Bitmap(L.root)
    -- siblings share one depth by default and the first created wins hit testing: stack them explicitly
    L.track.Depth:Set(function() return L.root.Depth() + 3 end)
    L.thumb.Depth:Set(function() return L.root.Depth() + 4 end)
    L.thumb:SetSolidColor(c.textDim)
    L.track:Hide()
    L.thumb:Hide()

    local function Count()
        return opts.getCount()
    end
    local function Visible()
        return math.max(1, math.floor(L.h / L.rowH))
    end
    local function MaxOffset()
        return math.max(0, Count() - Visible())
    end

    local function Wheel(self, event)
        if event.Type == 'WheelRotation' then
            -- a list that has nothing to scroll leaves the wheel to the panel that holds it
            if MaxOffset() == 0 and parent.scroll then return parent.scroll.Wheel(self, event) end
            local dir = 1
            if event.WheelRotation > 0 then dir = -1 end
            L.offset = math.max(0, math.min(MaxOffset(), L.offset + dir * 3))
            L:Refresh()
            return true
        end
        return false
    end
    L.bg.HandleEvent = Wheel

    local function EnsureRows(n)
        while table.getn(L.rows) < n do
            local i = table.getn(L.rows) + 1
            local row = { bg = Bitmap(L.root) }
            row.bg.Depth:Set(function() return L.root.Depth() + 2 end)
            row.bg:SetSolidColor(c.panel)
            row.text = Label(row.bg, '', 0, 0, {})
            if opts.extra then row.extra = Label(row.bg, '', 0, 0, { color = c.accent }) end
            if opts.thumb then
                -- a texture thumbnail at the row's left edge (the owner sets row.thumb's texture in bind)
                row.thumb = Bitmap(row.bg)
                row.thumb.Depth:Set(function() return row.bg.Depth() + 6 end)
                row.thumb:DisableHitTest()
                local ts = L.rowH - Skin.S(4)
                row.thumb.Left:Set(function() return row.bg.Left() + Skin.S(2) end)
                row.thumb.Top:Set(function() return row.bg.Top() + Skin.S(2) end)
                row.thumb.Width:Set(ts) row.thumb.Height:Set(ts)
            end
            row.index = nil
            row.bg.HandleEvent = function(self, event)
                if event.Type == 'WheelRotation' then
                    return Wheel(self, event)
                elseif row.index == nil then
                    return false
                elseif event.Type == 'MouseEnter' then
                    row.hot = true
                    L:StyleRow(row)
                    if opts.onHover then opts.onHover(row.index) end
                    return true
                elseif event.Type == 'MouseExit' then
                    row.hot = false
                    L:StyleRow(row)
                    return true
                elseif event.Type == 'ButtonPress' then
                    if event.Modifiers and event.Modifiers.Right then
                        -- right click: the row is the context (marked, not "selected" in the list's sense), the owner opens its menu
                        if opts.onContext then
                            L.contextRow = row.index
                            opts.onContext(row.index, event.MouseX, event.MouseY)
                        end
                        return true
                    end
                    L:SetSelected(row.index)
                    if opts.onSelect then opts.onSelect(row.index) end
                    return true
                end
                return false
            end
            L.rows[i] = row
        end
    end

    function L:StyleRow(row)
        local col = c.panel
        if row.index and row.index == L.selected then col = c.select
        elseif row.hot then col = c.hover
        elseif row.index and math.mod(row.index, 2) == 0 then col = c.panelAlt end
        row.bg:SetSolidColor(col)
    end

    function L:UpdateScrollbar()
        local count, vis = Count(), Visible()
        if count <= vis then
            L.track:Hide()
            L.thumb:Hide()
            return
        end
        local sw = Skin.S(Skin.size.scrollW)
        local trackH = L.h
        local thumbH = math.max(Skin.S(24), math.floor(trackH * vis / count))
        local range = trackH - thumbH
        local ty = math.floor(range * L.offset / math.max(1, count - vis))
        local tx = L.w - sw
        L.track:SetSolidColor('50000000')
        L.thumb:SetSolidColor(L.thumbHot and c.accent or c.textDim)
        Place(L.track, L.root, tx, 0, sw, trackH)
        Place(L.thumb, L.root, tx, ty, sw, thumbH)
        L.track:Show()
        L.thumb:Show()
        L.thumb.HandleEvent = function(self, event)
            if event.Type == 'MouseEnter' then
                L.thumbHot = true
                self:SetSolidColor(c.accent)
                return true
            elseif event.Type == 'MouseExit' then
                L.thumbHot = false
                self:SetSolidColor(c.textDim)
                return true
            elseif event.Type == 'ButtonPress' then
                local startY, startOffset = event.MouseY, L.offset
                local drag = Dragger()
                drag.OnMove = function(d, x, y)
                    local per = range / math.max(1, count - vis)
                    local delta = math.floor((y - startY) / math.max(0.001, per) + 0.5)
                    L.offset = math.max(0, math.min(MaxOffset(), startOffset + delta))
                    L:Refresh()
                end
                drag.OnRelease = function(d, x, y) d:Destroy() end
                PostDragger(self:GetRootFrame(), event.KeyCode, drag)
                return true
            end
            return false
        end
    end

    function L:Refresh()
        local count, vis = Count(), Visible()
        if L.offset > MaxOffset() then L.offset = MaxOffset() end
        EnsureRows(vis)
        local rowW = L.w
        if count > vis then rowW = L.w - Skin.S(Skin.size.scrollW) end
        for i = 1, table.getn(L.rows) do
            local row = L.rows[i]
            local index = L.offset + i
            if i <= vis and index <= count then
                row.index = index
                Place(row.bg, L.root, 0, (i - 1) * L.rowH, rowW, L.rowH)
                row.bg:Show()
                row.text:Show()
                if row.extra then row.extra:Show() end
                if row.thumb then row.thumb:Show() end
                opts.bind(row, index, index == L.selected)
                L:StyleRow(row)
            else
                row.index = nil
                row.bg:Hide()
                row.text:Hide()
                if row.extra then row.extra:Hide() end
                if row.thumb then row.thumb:Hide() end
            end
        end
        L:UpdateScrollbar()
    end

    function L:SetRect(x, y, w, h)
        L.x, L.y, L.w, L.h = x, y, w, h
        Place(L.root, parent, x, y, w, h)
        L:Refresh()
    end

    function L:SetSelected(i)
        L.selected = i
        L:Refresh()
    end

    function L:ScrollTo(i)
        local vis = Visible()
        if i <= L.offset then L.offset = i - 1 elseif i > L.offset + vis then L.offset = i - vis end
        L.offset = math.max(0, math.min(MaxOffset(), L.offset))
        L:Refresh()
    end

    function L:Destroy()
        L.root:Destroy()
    end
    return L
end

--- Single-line text field. Returns the Edit control (`.frame` is its background); `field:GetText()` / `SetText(s)` as usual.
function TextField(parent, x, y, w, h, opts)
    opts = opts or {}
    local c = Skin.color
    local frame = Bitmap(parent)
    frame.Depth:Set(function() return parent.Depth() + 5 end)
    frame:SetSolidColor(c.line)
    Place(frame, parent, x, y, w, h)
    local e = Edit(frame)
    e.Left:Set(function() return frame.Left() + 1 end)
    e.Top:Set(function() return frame.Top() + 1 end)
    e.Width:Set(w - 2)
    e.Height:Set(h - 2)
    e:SetNewFont(Skin.Font(), PixelSize('text'))
    e:SetForegroundColor(c.text)
    e:SetBackgroundColor(c.panelAlt)
    e:SetCaretColor(c.accent)
    e:SetHighlightForegroundColor(c.textOn)
    e:SetHighlightBackgroundColor(c.accent)
    e:SetMaxChars(256)
    if opts.text then e:SetText(opts.text) end
    e.frame = frame
    -- tooltip: `opts.tip`, else the text tooltips.lua has for this panel's text fields
    function e:TipText() return TipFor(frame, '[field]', opts.tip, nil) end
    if tracking then table.insert(tracking, { field = e, text = '[field]' }) end
    local tipField = function() return e:TipText() end
    frame.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' or event.Type == 'MouseExit' then
            TipEvent(self, event, tipField)
            return true
        end
        return false
    end
    e.OnTextChanged = function(self, new, old)
        if opts.onChange then opts.onChange(new) end
    end
    e.OnEnterPressed = function(self, text)
        if opts.onEnter then opts.onEnter(text) end
        return true
    end
    e.OnEscPressed = function(self, text)
        if opts.onEscape then opts.onEscape() end
        return true
    end
    return e
end

--- Cuts `text` with "..." so that it is at most `maxW` pixels wide as the text control's text (Maui does not clip, so text that is too
--- long would run into the next panel).
function Fit(label, text, maxW)
    label:SetText(text)
    if label.Width() <= maxW then return end
    local n = string.len(text)
    while n > 1 do
        n = n - 1
        label:SetText(string.sub(text, 1, n) .. '...')
        if label.Width() <= maxW then return end
    end
end

--- Word-wrapped text: one label per line, `maxW` pixels wide at most, `lineH` pixels apart, nothing below `maxBottom` when given. Returns the list of labels and the y below
--- the last line.
function Paragraph(parent, text, x, y, maxW, opts, lineH, maxBottom)
    opts = opts or {}
    lineH = lineH or Skin.S(18)
    local probe = Label(parent, '', x, y, opts)
    local lines, line = {}, ''
    for word in string.gfind(text or '', '%S+') do
        local try = (line == '') and word or (line .. ' ' .. word)
        probe:SetText(try)
        if probe.Width() > maxW and line ~= '' then
            table.insert(lines, line)
            line = word
        else
            line = try
        end
    end
    if line ~= '' then table.insert(lines, line) end
    probe:Destroy()
    -- text does not clip: lines that would run below `maxBottom` (the panel's height) are cut, the last kept line ends with "..."
    if maxBottom then
        local fit = math.floor((maxBottom - y) / lineH)
        if fit < table.getn(lines) then
            local kept = {}
            for i = 1, math.max(0, fit) do kept[i] = lines[i] end
            if fit >= 1 then kept[fit] = kept[fit] .. ' ...' end
            lines = kept
        end
    end
    local labels = {}
    for i, l in lines do
        labels[i] = Label(parent, l, x, y + (i - 1) * lineH, opts)
    end
    return labels, y + table.getn(lines) * lineH
end

--- A setting with a draggable bar, - and + buttons and an editable value field, in two lines: the label above, the controls below.
--- opts: label, min, max, step, curve (1 = linear, 2 = finer at the low end), fmt ('%.1f'), get() -> number, set(value), compact (narrow: the - / + buttons move to the label line).
--- Methods: Place(x, y, w) (height is Skin.S(46)), Refresh() (re-reads get()), SetRange(min, max, step, fmt).
function Slider(parent, opts)
    local c = Skin.color
    local S = { opts = opts, x = 0, y = 0, w = 200 }
    local curve = opts.curve or 1
    local step = opts.step or 1
    local lo, hi = opts.min, opts.max

    local function Snap(v)
        v = math.floor(v / step + 0.5) * step
        return math.max(lo, math.min(hi, v))
    end
    local function ToT(v)
        return math.max(0, math.min(1, math.pow((v - lo) / (hi - lo), 1 / curve)))
    end
    local function FromT(t)
        return Snap(lo + (hi - lo) * math.pow(math.max(0, math.min(1, t)), curve))
    end
    local function Apply(v)
        opts.set(Snap(v))
        S:Refresh()
    end

    if tracking then table.insert(tracking, { slider = S, text = opts.label }) end
    S.label = Label(parent, opts.label, 0, 0, { color = c.textDim })
    S.track = Bitmap(parent)
    S.track.Depth:Set(function() return parent.Depth() + 6 end)
    S.track:SetSolidColor(c.line)
    S.fill = Bitmap(parent)
    S.fill.Depth:Set(function() return parent.Depth() + 7 end)
    S.fill:SetSolidColor(c.accent)
    S.thumb = Bitmap(parent)
    S.thumb.Depth:Set(function() return parent.Depth() + 8 end)
    S.thumb:SetSolidColor(c.text)
    --- The tooltip of the slider (its bar and thumb): `opts.tip`, else the text tooltips.lua has for (panel, label).
    function S:TipText() return TipFor(S.track, opts.label, opts.tip, opts.cmd) end
    local function Detail(what)
        return function()
            local base = S:TipText()
            if not base then return nil end
            return what .. '\n' .. base
        end
    end
    S.minus = Button(parent, '-', 0, 0, Skin.S(opts.compact and 18 or 22), Skin.S(opts.compact and 18 or 22), function() Apply(opts.get() - step) end, { tip = Detail('Smaller by one step.') })
    S.plus = Button(parent, '+', 0, 0, Skin.S(opts.compact and 18 or 22), Skin.S(opts.compact and 18 or 22), function() Apply(opts.get() + step) end, { tip = Detail('Larger by one step.') })
    S.field = TextField(parent, 0, 0, Skin.S(52), Skin.S(22), {
        onEnter = function(text)
            local v = tonumber(text)
            if v then Apply(v) else S:Refresh() end
        end,
        tip = Detail('Type a value and press Enter.'),
    })

    local function TrackGeometry()
        -- screen position of the track: trackLeft is relative to the panel, the mouse is in screen coordinates (a panel docked on the right
        -- put the mapping off by the panel's own x)
        return S.track.Left(), S.track.Width()
    end

    local function DragFrom(event)
        local left, width = TrackGeometry()
        local function Set(x) Apply(FromT((x - left) / math.max(1, width))) end
        Set(event.MouseX)
        local drag = Dragger()
        drag.OnMove = function(d, x, y) Set(x) end
        drag.OnRelease = function(d, x, y) d:Destroy() end
        drag.OnCancel = function(d) d:Destroy() end
        PostDragger(GetFrame(0), event.KeyCode, drag)
    end
    local function SliderTip() return S:TipText() end
    local function Handle(self, event)
        if event.Type == 'ButtonPress' then
            TipEvent(self, event, SliderTip)
            DragFrom(event)
            return true
        elseif event.Type == 'MouseEnter' or event.Type == 'MouseExit' then
            TipEvent(S.track, event, SliderTip)
            return true
        end
        return false
    end
    S.track.HandleEvent = Handle
    S.fill.HandleEvent = Handle
    S.thumb.HandleEvent = Handle

    --- Changes the range of a slider that edits different settings over time.
    function S:SetRange(min, max, newStep, fmt)
        lo, hi, step = min, max, newStep or step
        if fmt then opts.fmt = fmt end
    end

    function S:Place(x, y, w)
        S.x, S.y, S.w = x, y, w
        CullBox(y, Skin.S(44))    -- all parts of the slider appear and disappear together at the edge of a scrolled panel
        local bh, gap, fw = Skin.S(22), Skin.S(4), Skin.S(52)
        Place(S.label, parent, x, y)
        local row = y + Skin.S(20)
        local right = x + w
        Place(S.field.frame, parent, right - fw, row, fw, bh)
        S.field.Width:Set(fw - 2)
        Place(S.plus, parent, right - fw - gap - bh, row, bh, bh)
        Place(S.minus, parent, right - fw - 2 * gap - 2 * bh, row, bh, bh)
        S.trackLeft = x
        S.trackW = math.max(Skin.S(30), w - fw - 3 * gap - 2 * bh - Skin.S(8))
        if opts.compact then
            -- two sliders side by side in a narrow panel: bar and field take the lower line, the small - / + buttons sit at the right end of the
            -- label line (the label is cut to what is left of it)
            local sb = Skin.S(18)
            Place(S.plus, parent, right - sb, y, sb, sb)
            Place(S.minus, parent, right - 2 * sb - Skin.S(2), y, sb, sb)
            Fit(S.label, opts.label, w - 2 * sb - gap - Skin.S(4))
            S.trackW = math.max(Skin.S(30), w - fw - gap - Skin.S(4))
        end
        local th = Skin.S(6)
        Place(S.track, parent, S.trackLeft, row + math.floor((bh - th) / 2), S.trackW, th)
        S:Refresh()
        CullBox(false)
    end

    function S:Refresh()
        local v = opts.get()
        local t = ToT(v)
        local bh, th, tw = Skin.S(22), Skin.S(6), Skin.S(10)
        CullBox(S.y or 0, Skin.S(44))
        Place(S.fill, parent, S.trackLeft or 0, (S.y or 0) + Skin.S(20) + math.floor((bh - th) / 2), math.max(1, math.floor((S.trackW or 1) * t)), th)
        Place(S.thumb, parent, (S.trackLeft or 0) + math.floor((S.trackW or 1) * t) - math.floor(tw / 2), (S.y or 0) + Skin.S(20) + 1, tw, bh - 2)
        CullBox(false)
        S.field:SetText(string.format(opts.fmt or '%.1f', v))
    end

    return S
end
