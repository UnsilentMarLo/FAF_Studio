-- A curve editor widget in the style of the Photoshop curves dialog: a square plot, a monotone curve through draggable points. Click empty plot to add a point, drag a point to move it
-- (the first and last point only move up and down), right click or Ctrl+click a point to delete it. Used for the cross-section profile of a path (paths.lua).
--
--   local C = Curve(parent, { get = function() return points, smooth, symmetric end, set = function(points) end, onDragEnd = function() end,
--                             leftText = 'centre', rightText = 'edge' })
--   C:Place(x, y, w, h)     C:Refresh()     C:Destroy()
--
-- points = { {x, v}, ... } with x ascending from 0 to 1; v is plotted from VMIN to VMAX (0 and 1 are marked). The curve is the monotone cubic of paths.lua (EvalProfile), drawn as dots.
--
-- Optional opts for other kinds of curve (the particle editor's emitter curves, fxparticle.lua: linear keys, any value range, a random spread, the ends free):
--   range = function() return vmin, vmax end       the plotted value range (default VMIN, VMAX)
--   sample = function(n) return { v1 .. vn } end   the curve's values at n points from x = 0 to 1 (default: paths.lua's EvalProfile of the points)
--   band = function(n) return lo, hi end            two more arrays, drawn dimmer: the spread around the curve
--   refs = function() return { {v, 'text'}, ... } end   horizontal reference lines with their labels (replaces the 0 and 1 lines)
--   freeEnds = true                                  the first and last point move in x too, any point can be deleted down to one, a point can be added before the first / after the last
--   onSelect = function(index) end, selected = function() return index end     the point that was pressed, and which one is drawn highlighted
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Dragger = import('/lua/maui/dragger.lua').Dragger
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Paths = import('/lua/editor/paths.lua')

local VMIN, VMAX = -0.25, 1.25
local DOTS = 160
local HIT = 9
local BAND_COLOR = '70ffffff'

function Curve(parent, opts)
    local c = Skin.color
    local C = { x = 0, y = 0, w = 200, h = 140, dots = {}, handles = {}, bandLo = {}, bandHi = {}, refs = {} }

    --- The plotted value range (opts.range, else the profile's).
    local function Range()
        if opts.range then
            local lo, hi = opts.range()
            if lo and hi and hi > lo then return lo, hi end
        end
        return VMIN, VMAX
    end

    C.bg = Bitmap(parent)
    C.bg.Depth:Set(function() return parent.Depth() + 5 end)
    C.bg:SetSolidColor(c.panelAlt)
    C.zero = Bitmap(parent)
    C.zero.Depth:Set(function() return parent.Depth() + 6 end)
    C.zero:SetSolidColor('50ffffff')
    C.one = Bitmap(parent)
    C.one.Depth:Set(function() return parent.Depth() + 6 end)
    C.one:SetSolidColor('50ffffff')
    C.mid = Bitmap(parent)
    C.mid.Depth:Set(function() return parent.Depth() + 6 end)
    C.mid:SetSolidColor('28ffffff')
    C.zero:DisableHitTest()
    C.one:DisableHitTest()
    C.mid:DisableHitTest()
    C.top = W.Label(parent, '1', 0, 0, { color = c.textDim, size = 'small' })
    C.base = W.Label(parent, '0', 0, 0, { color = c.textDim, size = 'small' })
    C.left = W.Label(parent, opts.leftText or 'centre', 0, 0, { color = c.textDim, size = 'small' })
    C.right = W.Label(parent, opts.rightText or 'edge', 0, 0, { color = c.textDim, size = 'small' })
    for i = 1, DOTS do
        local d = Bitmap(parent)
        d.Depth:Set(function() return parent.Depth() + 7 end)
        d:SetSolidColor(c.accent)
        d:DisableHitTest()
        C.dots[i] = d
    end

    local function Pts()
        local points, smooth, symmetric = opts.get()
        return points or {}, smooth, symmetric
    end

    local function ToPixel(x, v)
        local vmin, vmax = Range()
        return C.bg.Left() + x * C.bg.Width(), C.bg.Top() + (vmax - v) / (vmax - vmin) * C.bg.Height()
    end

    local function FromPixel(px, py)
        local vmin, vmax = Range()
        local x = (px - C.bg.Left()) / math.max(1, C.bg.Width())
        local v = vmax - (py - C.bg.Top()) / math.max(1, C.bg.Height()) * (vmax - vmin)
        return math.max(0, math.min(1, x)), math.max(vmin, math.min(vmax, v))
    end

    local function Handle(i)
        local hnd = C.handles[i]
        if not hnd then
            hnd = Bitmap(parent)
            hnd.Depth:Set(function() return parent.Depth() + 9 end)
            hnd:SetSolidColor(c.text)
            hnd:DisableHitTest()
            C.handles[i] = hnd
        end
        return hnd
    end

    function C:Place(x, y, w, h)
        C.x, C.y, C.w, C.h = x, y, w, h
        W.Place(C.bg, parent, x, y, w, h)
        local vmin, vmax = Range()
        local function Row(v) return y + math.floor((vmax - v) / (vmax - vmin) * h) end
        if opts.refs then
            C.zero:Hide() C.one:Hide() C.top:Hide() C.base:Hide()
        else
            W.Place(C.zero, parent, x, Row(0), w, 1)
            W.Place(C.one, parent, x, Row(1), w, 1)
            W.Place(C.top, parent, x + Skin.S(3), Row(1) - Skin.S(14))
            W.Place(C.base, parent, x + Skin.S(3), Row(0) - Skin.S(14))
        end
        W.Place(C.mid, parent, x + math.floor(w / 2), y, 1, h)
        W.Place(C.left, parent, x + Skin.S(3), y + h - Skin.S(14))
        W.Place(C.right, parent, x + w - C.right.Width() - Skin.S(3), y + h - Skin.S(14))
        C:Refresh()
    end

    --- The reference lines (opts.refs): a pool of lines with labels.
    local function DrawRefs(vmin, vmax)
        if not opts.refs then return end
        local list = opts.refs() or {}
        for i = 1, math.max(table.getn(list), table.getn(C.refs)) do
            local r = C.refs[i]
            local ref = list[i]
            if ref and ref[1] >= vmin and ref[1] <= vmax then
                if not r then
                    r = { line = Bitmap(parent), label = W.Label(parent, '', 0, 0, { color = c.textDim, size = 'small' }) }
                    r.line.Depth:Set(function() return parent.Depth() + 6 end)
                    r.line:SetSolidColor('40ffffff')
                    r.line:DisableHitTest()
                    C.refs[i] = r
                end
                local row = C.y + math.floor((vmax - ref[1]) / (vmax - vmin) * C.h)
                W.Place(r.line, parent, C.x, row, C.w, 1)
                r.label:SetText(ref[2])
                W.Place(r.label, parent, C.x + Skin.S(3), row - Skin.S(14))
                r.line:Show() r.label:Show()
            elseif r then
                r.line:Hide() r.label:Hide()
            end
        end
    end

    local function DotSet(set, i)
        local d = set[i]
        if not d then
            d = Bitmap(parent)
            d.Depth:Set(function() return parent.Depth() + 7 end)
            d:SetSolidColor(BAND_COLOR)
            d:DisableHitTest()
            set[i] = d
        end
        return d
    end

    function C:Refresh()
        local points, smooth, symmetric = Pts()
        local w, h = C.w, C.h
        local vmin, vmax = Range()
        local lastY = nil
        local samples = opts.sample and opts.sample(DOTS)
        DrawRefs(vmin, vmax)
        if opts.band then
            local lo, hi = opts.band(DOTS)
            for i = 1, DOTS do
                local l, u = DotSet(C.bandLo, i), DotSet(C.bandHi, i)
                if lo and hi and lo[i] and hi[i] then
                    local x = (i - 1) / (DOTS - 1)
                    local dw = math.max(2, math.floor(w / DOTS) + 1)
                    local ly = math.floor((vmax - math.max(vmin, math.min(vmax, lo[i]))) / (vmax - vmin) * h)
                    local uy = math.floor((vmax - math.max(vmin, math.min(vmax, hi[i]))) / (vmax - vmin) * h)
                    W.Place(l, parent, C.x + math.floor(x * (w - 2)), C.y + ly, dw, 2)
                    W.Place(u, parent, C.x + math.floor(x * (w - 2)), C.y + uy, dw, 2)
                    l:Show() u:Show()
                else
                    l:Hide() u:Hide()
                end
            end
        end
        for i = 1, DOTS do
            local x = (i - 1) / (DOTS - 1)
            local v = samples and samples[i] or Paths.EvalProfile(points, smooth, x)
            v = math.max(vmin, math.min(vmax, v))
            local py = math.floor((vmax - v) / (vmax - vmin) * h)
            local top, bottom = py, py
            if lastY then top, bottom = math.min(py, lastY), math.max(py, lastY) end
            lastY = py
            local dh = math.max(2, bottom - top + 2)
            W.Place(C.dots[i], parent, C.x + math.floor(x * (w - 2)), C.y + top, math.max(2, math.floor(w / DOTS) + 1), dh)
        end
        local hs = Skin.S(7)
        for i = 1, math.max(table.getn(points), table.getn(C.handles)) do
            local p = points[i]
            local hnd = Handle(i)
            if p then
                local py = math.floor((vmax - math.max(vmin, math.min(vmax, p[2]))) / (vmax - vmin) * h)
                W.Place(hnd, parent, C.x + math.floor(p[1] * (w - 2)) - math.floor(hs / 2), C.y + py - math.floor(hs / 2), hs, hs)
                hnd:SetSolidColor((opts.selected and opts.selected() == i) and c.accent or c.text)
                hnd:Show()
            else
                hnd:Hide()
            end
        end
        if not opts.fixedLabels then          -- fixedLabels: the caller's leftText / rightText stay (the graph's curve node is not a profile)
            C.left:SetText(symmetric and 'centre' or '- side')
            C.right:SetText(symmetric and 'edge' or '+ side')
        end
    end

    local function Nearest(points, mx, my)
        local best, bi = HIT * HIT, nil
        for i, p in points do
            local px, py = ToPixel(p[1], p[2])
            local d = (px - mx) * (px - mx) + (py - my) * (py - my)
            if d <= best then best, bi = d, i end
        end
        return bi
    end

    C.bg.HandleEvent = function(self, event)
        if event.Type ~= 'ButtonPress' then return false end
        local points, smooth, symmetric = Pts()
        local mods = event.Modifiers or {}
        local hit = Nearest(points, event.MouseX, event.MouseY)
        local list = {}
        for i, p in points do list[i] = { p[1], p[2] } end
        if hit and (mods.Right or (IsKeyDown and IsKeyDown(17))) then
            local deletable = opts.freeEnds and table.getn(list) > 1 or (table.getn(list) > 2 and hit > 1 and hit < table.getn(list))
            if deletable then
                table.remove(list, hit)
                opts.set(list)
                if opts.onDragEnd then opts.onDragEnd() end
                C:Refresh()
            end
            return true
        end
        if not hit then
            local x, v = FromPixel(event.MouseX, event.MouseY)
            -- a point at the clicked x: between its neighbours
            local at = table.getn(list) + 1
            for i, p in list do
                if p[1] > x then at = i break end
            end
            if not opts.freeEnds and (at == 1 or at > table.getn(list)) then return true end    -- the ends are fixed in x
            table.insert(list, at, { x, v })
            hit = at
            opts.set(list)
        end
        local index = hit
        if opts.onSelect then opts.onSelect(index) end
        local dragger = Dragger()
        dragger.OnMove = function(d, x, y)
            local px, pv = FromPixel(x, y)
            local cur, _, _ = Pts()
            local l2 = {}
            for i, p in cur do l2[i] = { p[1], p[2] } end
            local p = l2[index]
            if not p then return end
            if (index == 1 or index == table.getn(l2)) and not opts.freeEnds then
                p[2] = pv
            else
                local lo = l2[index - 1] and (l2[index - 1][1] + 0.002) or 0
                local hi = l2[index + 1] and (l2[index + 1][1] - 0.002) or 1
                p[1] = math.max(lo, math.min(hi, px))
                p[2] = pv
            end
            opts.set(l2)
            C:Refresh()
        end
        local function Done(d)
            d:Destroy()
            if opts.onDragEnd then opts.onDragEnd() end
        end
        dragger.OnRelease = function(d, x, y) Done(d) end
        dragger.OnCancel = function(d) Done(d) end
        PostDragger(GetFrame(0), event.KeyCode, dragger)
        C:Refresh()
        return true
    end

    function C:Destroy()
        C.bg:Destroy() C.zero:Destroy() C.one:Destroy() C.mid:Destroy() C.left:Destroy() C.right:Destroy() C.top:Destroy() C.base:Destroy()
        for _, d in C.dots do d:Destroy() end
        for _, hnd in C.handles do hnd:Destroy() end
        for _, d in C.bandLo do d:Destroy() end
        for _, d in C.bandHi do d:Destroy() end
        for _, r in C.refs do r.line:Destroy() r.label:Destroy() end
    end

    return C
end
