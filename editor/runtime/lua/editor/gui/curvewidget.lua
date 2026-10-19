-- A curve editor widget in the style of the Photoshop curves dialog: a square plot, a monotone curve through draggable points. Click empty plot to add a point, drag a point to move it
-- (the first and last point only move up and down), right click or Ctrl+click a point to delete it. Used for the cross-section profile of a path (paths.lua).
--
--   local C = Curve(parent, { get = function() return points, smooth, symmetric end, set = function(points) end, onDragEnd = function() end,
--                             leftText = 'centre', rightText = 'edge' })
--   C:Place(x, y, w, h)     C:Refresh()     C:Destroy()
--
-- points = { {x, v}, ... } with x ascending from 0 to 1; v is plotted from VMIN to VMAX (0 and 1 are marked). The curve is the monotone cubic of paths.lua (EvalProfile), drawn as dots.
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

function Curve(parent, opts)
    local c = Skin.color
    local C = { x = 0, y = 0, w = 200, h = 140, dots = {}, handles = {} }

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
        return C.bg.Left() + x * C.bg.Width(), C.bg.Top() + (VMAX - v) / (VMAX - VMIN) * C.bg.Height()
    end

    local function FromPixel(px, py)
        local x = (px - C.bg.Left()) / math.max(1, C.bg.Width())
        local v = VMAX - (py - C.bg.Top()) / math.max(1, C.bg.Height()) * (VMAX - VMIN)
        return math.max(0, math.min(1, x)), math.max(VMIN, math.min(VMAX, v))
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
        local function Row(v) return y + math.floor((VMAX - v) / (VMAX - VMIN) * h) end
        W.Place(C.zero, parent, x, Row(0), w, 1)
        W.Place(C.one, parent, x, Row(1), w, 1)
        W.Place(C.mid, parent, x + math.floor(w / 2), y, 1, h)
        W.Place(C.top, parent, x + Skin.S(3), Row(1) - Skin.S(14))
        W.Place(C.base, parent, x + Skin.S(3), Row(0) - Skin.S(14))
        W.Place(C.left, parent, x + Skin.S(3), y + h - Skin.S(14))
        W.Place(C.right, parent, x + w - C.right.Width() - Skin.S(3), y + h - Skin.S(14))
        C:Refresh()
    end

    function C:Refresh()
        local points, smooth, symmetric = Pts()
        local w, h = C.w, C.h
        local lastY = nil
        for i = 1, DOTS do
            local x = (i - 1) / (DOTS - 1)
            local v = Paths.EvalProfile(points, smooth, x)
            v = math.max(VMIN, math.min(VMAX, v))
            local py = math.floor((VMAX - v) / (VMAX - VMIN) * h)
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
                local py = math.floor((VMAX - math.max(VMIN, math.min(VMAX, p[2]))) / (VMAX - VMIN) * h)
                W.Place(hnd, parent, C.x + math.floor(p[1] * (w - 2)) - math.floor(hs / 2), C.y + py - math.floor(hs / 2), hs, hs)
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
            if table.getn(list) > 2 and hit > 1 and hit < table.getn(list) then
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
            if at == 1 or at > table.getn(list) then return true end    -- the ends are fixed in x
            table.insert(list, at, { x, v })
            hit = at
            opts.set(list)
        end
        local index = hit
        local dragger = Dragger()
        dragger.OnMove = function(d, x, y)
            local px, pv = FromPixel(x, y)
            local cur, _, _ = Pts()
            local l2 = {}
            for i, p in cur do l2[i] = { p[1], p[2] } end
            local p = l2[index]
            if not p then return end
            if index == 1 or index == table.getn(l2) then
                p[2] = pv
            else
                local lo, hi = l2[index - 1][1] + 0.01, l2[index + 1][1] - 0.01
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
    end

    return C
end
