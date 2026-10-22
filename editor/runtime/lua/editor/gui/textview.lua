-- A scrolling column of wrapped text inside a rectangle of a dialog (Maui does not clip, so the view only creates the lines that lie completely inside its rectangle and creates the
-- others when the user scrolls). Every block is measured with the real font: its height is the height of its wrapped lines, never an estimate.
--
--   local v = TextView.New(d, x, y, w, h)       d = a Dialog; x, y, w, h in logical pixels relative to the dialog
--   v:Clear()                                   remove all blocks
--   v:Heading(text[, opts])                     a small section heading (opts.color)
--   v:Text(text[, opts])                        a wrapped paragraph (opts: color, size, indent, before, after: logical pixels)
--   v:Bullet(text[, opts])                      a wrapped item with a dash in front, indented
--   v:Row(cells[, opts])                        a table row: cells = { { text, w, color, size }, ... } (w: logical pixels, v.innerW is the width available), as tall as the
--                                               tallest wrapped cell; opts.after is the padding below (default 4)
--   v:Gap(px)                                   empty space
--   v:Show([keepOffset])                        lay out, draw (the scroll offset goes back to the top unless keepOffset)
--   v:SetRect(x, y, w, h)                       move or resize (call Show afterwards)
--   v:Controls() -> list                        the controls that exist now (for the self test); v.contentH: logical height of the content; v.innerW: width of the text column
--   v:Destroy()
--
-- The mouse wheel over the view scrolls it; a thin bar on the right edge shows the position (drag it, or click the track to page).
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')

local BAR = 10          -- logical pixels at the right edge kept free for the scroll bar

local function Px(n) return Skin.S(n) end

--- The words of `text` wrapped to `maxW` pixels with the control `probe`; a word wider than the line is cut into pieces.
local function Wrap(probe, text, maxW)
    local lines, line = {}, ''
    local function Fits(s)
        probe:SetText(s)
        return probe.Width() <= maxW
    end
    for w0 in string.gfind(text or '', '%S+') do
        local word = w0
        local try = (line == '') and word or (line .. ' ' .. word)
        if Fits(try) then
            line = try
        else
            if line ~= '' then
                table.insert(lines, line)
                line = ''
            end
            -- a single word too wide for the line: break it where it stops fitting
            while not Fits(word) and string.len(word) > 1 do
                local lo, hi = 1, string.len(word) - 1
                while lo < hi do
                    local mid = math.floor((lo + hi + 1) / 2)
                    if Fits(string.sub(word, 1, mid)) then lo = mid else hi = mid - 1 end
                end
                table.insert(lines, string.sub(word, 1, lo))
                word = string.sub(word, lo + 1)
            end
            line = word
        end
    end
    if line ~= '' then table.insert(lines, line) end
    if table.getn(lines) == 0 then lines[1] = '' end
    return lines
end

function New(d, x, y, w, h)
    local c = Skin.color
    local v = { d = d, items = {}, off = 0, maxOff = 0, labels = {}, contentH = 0 }
    local group = d.group

    local function Bar(depth)
        local b = Bitmap(group)
        b.Depth:Set(function() return group.Depth() + depth end)
        b.Left:Set(-20000) b.Top:Set(-20000) b.Width:Set(1) b.Height:Set(1)
        return b
    end
    v.catcher = Bar(5)
    v.catcher:SetSolidColor('00000000')
    v.track = Bar(6)
    v.track:SetSolidColor('50000000')
    v.thumb = Bar(7)
    v.thumb:SetSolidColor(c.textDim)
    v.track:Hide()
    v.thumb:Hide()

    local function ViewH() return Px(v.h) end

    function v:SetRect(nx, ny, nw, nh)
        v.x, v.y, v.w, v.h = nx, ny, nw, nh
        v.innerW = nw - BAR
        W.Place(v.catcher, group, Px(nx), Px(ny), Px(nw), Px(nh))
    end

    function v:Clear()
        v.items = {}
    end

    local function Add(item)
        item.before = item.before or 0
        item.after = item.after or 6
        table.insert(v.items, item)
    end

    function v:Heading(text, opts)
        opts = opts or {}
        Add({ cells = { { text = text, x = 0, w = v.innerW, color = opts.color or c.textDim, size = 'text' } }, before = opts.before or 14, after = opts.after or 4 })
    end

    function v:Text(text, opts)
        opts = opts or {}
        local ind = opts.indent or 0
        Add({ cells = { { text = text, x = ind, w = v.innerW - ind, color = opts.color or c.text, size = opts.size or 'small' } }, before = opts.before, after = opts.after })
    end

    function v:Bullet(text, opts)
        opts = opts or {}
        local color = opts.color or c.text
        local size = opts.size or 'small'
        Add({ cells = { { text = '-', x = 4, w = 10, color = color, size = size, nowrap = true },
                        { text = text, x = 16, w = v.innerW - 16, color = color, size = size } }, before = opts.before, after = opts.after })
    end

    function v:Row(cells, opts)
        opts = opts or {}
        local out, cx = {}, 0
        for _, cell in cells do
            table.insert(out, { text = cell[1], x = cx, w = cell[2], color = cell[3] or c.text, size = cell[4] or 'small' })
            cx = cx + cell[2] + 6
        end
        Add({ cells = out, before = opts.before, after = opts.after or 4 })
    end

    function v:Gap(px)
        Add({ cells = {}, spacer = px, before = 0, after = 0 })
    end

    --- Measures every block with the real font; sets item.y (pixels, from the top of the content), item.lines and v.contentH.
    function v:Layout()
        local probes = {}
        local function Probe(size)
            if not probes[size] then
                local p = W.Label(group, 'Ag', 0, 0, { size = size, color = c.text })
                local lh = p.Height()
                if lh < Px(8) then lh = Px(14) end
                probes[size] = { p = p, lh = lh + Px(2) }
            end
            return probes[size]
        end
        local y1, prevAfter, first = 0, 0, true
        for _, item in v.items do
            if item.spacer then
                y1 = y1 + Px(item.spacer)
                item.y, item.h, item.lines = y1, 0, {}
            else
                if not first then y1 = y1 + math.max(Px(prevAfter), Px(item.before)) end
                first = false
                item.y = y1
                item.lines = {}
                local tallest = 0
                for i, cell in item.cells do
                    local pr = Probe(cell.size)
                    cell.lh = pr.lh
                    if cell.nowrap then
                        item.lines[i] = { cell.text }
                    else
                        item.lines[i] = Wrap(pr.p, cell.text, Px(cell.w))
                    end
                    tallest = math.max(tallest, table.getn(item.lines[i]) * pr.lh)
                end
                item.h = tallest
                y1 = y1 + tallest
                prevAfter = item.after
            end
        end
        for _, pr in probes do pr.p:Destroy() end
        v.contentPx = y1
        v.contentH = math.ceil(y1 / Skin.scale)
        v.maxOff = math.max(0, y1 - ViewH())
    end

    local function ClearLabels()
        for _, l in v.labels do l:Destroy() end
        v.labels = {}
    end

    function v:Controls()
        local out = {}
        for _, l in v.labels do table.insert(out, l) end
        table.insert(out, v.catcher)
        if v.barShown then
            table.insert(out, v.track)
            table.insert(out, v.thumb)
        end
        return out
    end

    local function UpdateBar()
        if v.maxOff <= 0 then
            v.track:Hide()
            v.thumb:Hide()
            v.barShown = false
            return
        end
        local view = ViewH()
        local sw = Px(6)
        local thumbH = math.max(Px(24), math.floor(view * view / v.contentPx))
        local range = view - thumbH
        local ty = math.floor(range * v.off / v.maxOff)
        local tx = Px(v.x + v.w) - sw - Px(2)
        v.range, v.thumbH = range, thumbH
        W.Place(v.track, group, tx, Px(v.y), sw, view)
        W.Place(v.thumb, group, tx, Px(v.y) + ty, sw, thumbH)
        v.track:Show()
        v.thumb:Show()
        v.barShown = true
    end

    --- Creates the lines that lie completely inside the view at the current offset.
    function v:Render()
        ClearLabels()
        local view = ViewH()
        local base = Px(v.y)
        local left = Px(v.x)
        for _, item in v.items do
            if not item.spacer and item.y + item.h > v.off and item.y < v.off + view then
                for i, cell in item.cells do
                    local lh = cell.lh
                    for k, text in item.lines[i] do
                        local ly = item.y + (k - 1) * lh - v.off
                        if ly >= 0 and ly + lh <= view and text ~= '' then
                            local l = W.Label(group, text, left + Px(cell.x), base + ly, { color = cell.color, size = cell.size })
                            d:Raise(l)
                            table.insert(v.labels, l)
                        end
                    end
                end
            end
        end
        UpdateBar()
    end

    function v:Scroll(delta)
        local o = math.max(0, math.min(v.maxOff, v.off + delta))
        if o ~= v.off then
            v.off = o
            v:Render()
        end
    end

    function v:ScrollTo(px)
        v:Scroll(px - v.off)
    end

    function v:Show(keepOffset)
        v:Layout()
        v.off = keepOffset and math.min(v.off, v.maxOff) or 0
        v:Render()
    end

    function v:Destroy()
        ClearLabels()
        for _, b in { v.catcher, v.track, v.thumb } do b:Destroy() end
    end

    local function Wheel(self, event)
        if event.Type == 'WheelRotation' and v.maxOff > 0 then
            v:Scroll(event.WheelRotation > 0 and -Px(40) or Px(40))
            return true
        end
        return false
    end
    v.catcher.HandleEvent = Wheel
    v.track.HandleEvent = function(self, event)
        if event.Type == 'WheelRotation' then return Wheel(self, event) end
        if event.Type == 'ButtonPress' then
            local page = ViewH() - Px(24)
            if event.MouseY < v.thumb.Top() then v:Scroll(-page) else v:Scroll(page) end
            return true
        end
        return false
    end
    v.thumb.HandleEvent = function(self, event)
        if event.Type == 'WheelRotation' then return Wheel(self, event) end
        if event.Type == 'ButtonPress' then
            local startY, startOff = event.MouseY, v.off
            local drag = Dragger()
            drag.OnMove = function(dr, mx, my)
                local per = math.max(1, v.range) / math.max(1, v.maxOff)
                v:ScrollTo(startOff + (my - startY) / per)
            end
            drag.OnRelease = function(dr, mx, my) dr:Destroy() end
            drag.OnCancel = function(dr) dr:Destroy() end
            PostDragger(self:GetRootFrame(), event.KeyCode, drag)
            return true
        end
        return false
    end

    v:SetRect(x, y, w, h)
    return v
end
