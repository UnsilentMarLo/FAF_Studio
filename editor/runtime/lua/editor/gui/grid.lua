-- Virtual thumbnail grid: pooled cells over any number of items, scrolled by whole rows (wheel, scrollbar), with selection, double click, context click, hover, and dragging an item out of the
-- grid (a ghost picture follows the pointer; `onDrop` gets the screen position where it was let go). Used by the asset browser (panels_assets.lua).
--
--   Create(parent, opts) -> grid
--     opts.cellW, opts.cellH  logical pixels of a cell (the cells stretch to fill the row)
--     opts.getCount()         number of items
--     opts.bind(cell, index, selected)   fills a pooled cell: cell.thumb (Bitmap: SetTexture / SetSolidColor), cell.text = the name (the grid fits and places the label under the picture), cell.badge (Text, top right: SetText), cell.mark (Text centred on the picture: SetText, for tiles without a picture)
--     opts.onSelect(index)    a click;  opts.onActivate(index)  a double click;  opts.onContext(index, x, y)  right click;  opts.onHover(index | nil)  pointer over / left a cell
--     opts.canDrag(index)     true when the item may be dragged out;  opts.ghost(index) -> texture path | colour string;  opts.onDrop(index, x, y, frame)   (position in the grid's window; frame = that window's root frame)
--   grid:SetRect(x, y, w, h)  grid:Refresh()  grid:SetSelected(i)  grid:ScrollTo(i)  grid:Destroy()  grid.cols  grid.offset (first visible row, 0 based)  grid:Cells() visible cells
--
-- Lua 5.0 dialect.

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Dragger = import('/lua/maui/dragger.lua').Dragger
local Skin = import('/lua/editor/gui/skin.lua')
local W = import('/lua/editor/gui/widgets.lua')

DOUBLE = 0.4            -- seconds between two clicks that make a double click
Debug = false          -- LOG what the pointer does (drags)
DRAG_PIXELS = 6         -- the pointer must move this far (screen pixels) before a press becomes a drag

function Create(parent, opts)
    local c = Skin.color
    local G = { opts = opts, offset = 0, selected = nil, cells = {}, cols = 1, x = 0, y = 0, w = 100, h = 100 }
    local cellW, cellH = Skin.S(opts.cellW or 80), Skin.S(opts.cellH or 96)
    G.cellW, G.cellH = cellW, cellH
    G.root = Group(parent)
    G.root.Depth:Set(function() return parent.Depth() + 5 end)
    G.root.Left:Set(0) G.root.Top:Set(0) G.root.Width:Set(1) G.root.Height:Set(1)
    G.bg = Bitmap(G.root)
    G.bg:SetSolidColor(opts.bgColor or c.panel)
    G.bg.Left:Set(function() return G.root.Left() end)
    G.bg.Top:Set(function() return G.root.Top() end)
    G.bg.Right:Set(function() return G.root.Right() end)
    G.bg.Bottom:Set(function() return G.root.Bottom() end)
    G.track = Bitmap(G.root)
    G.thumbBar = Bitmap(G.root)
    G.track.Depth:Set(function() return G.root.Depth() + 8 end)
    G.thumbBar.Depth:Set(function() return G.root.Depth() + 9 end)
    G.track:Hide()
    G.thumbBar:Hide()

    local function Count() return opts.getCount() end
    local function Rows() return math.max(1, math.floor((G.h) / G.cellH)) end
    local function TotalRows() return math.ceil(Count() / G.cols) end
    local function MaxOffset() return math.max(0, TotalRows() - Rows()) end

    --- Cell size in logical pixels; `list` = one item per row with the picture at the left and the name beside it.
    function G:SetCellSize(w, h, list)
        cellW, cellH = Skin.S(w), Skin.S(h)
        G.cellW, G.cellH = cellW, cellH
        G.listMode = list and true or false
        G.offset = 0
        G:Refresh()
    end

    local function Wheel(self, event)
        if event.Type == 'WheelRotation' then
            if MaxOffset() == 0 and parent.scroll then return parent.scroll.Wheel(self, event) end
            local dir = 1
            if event.WheelRotation > 0 then dir = -1 end
            G.offset = math.max(0, math.min(MaxOffset(), G.offset + dir))
            G:Refresh()
            return true
        end
        return false
    end
    G.bg.HandleEvent = Wheel

    local lastClick = { index = false, time = 0 }

    local function StartDrag(cell, event)
        local index = cell.index
        local startX, startY = event.MouseX, event.MouseY
        local frame = cell.bg:GetRootFrame()          -- the window the grid is in (the main window or a pop-out)
        local ghost = false
        local drag = Dragger()
        drag.OnMove = function(d, x, y)
            if Debug then LOG('GRID move ' .. x .. ',' .. y .. ' start ' .. startX .. ',' .. startY .. ' ghost ' .. tostring(ghost)) end
            if not ghost and opts.canDrag and opts.canDrag(index) and (math.abs(x - startX) > Skin.S(DRAG_PIXELS) or math.abs(y - startY) > Skin.S(DRAG_PIXELS)) then
                ghost = Bitmap(frame)
                ghost.Depth:Set(9900)
                local g = opts.ghost and opts.ghost(index)
                if g and string.sub(g, 1, 1) == '/' then ghost:SetTexture(g) else ghost:SetSolidColor(g or c.accent) end
                local s = Skin.S(48)
                ghost.Width:Set(s) ghost.Height:Set(s)
                ghost:DisableHitTest()
                G.dragging = true
            end
            if ghost then
                ghost.Left:Set(x + Skin.S(8)) ghost.Top:Set(y + Skin.S(8))
            end
        end
        drag.OnRelease = function(d, x, y)
            if Debug then LOG('GRID release ' .. x .. ',' .. y .. ' ghost ' .. tostring(ghost)) end
            d:Destroy()
            G.dragging = false
            if ghost then
                ghost:Destroy()
                ghost = false
                if opts.onDrop then opts.onDrop(index, x, y, frame) end
                return
            end
            local now = GetSystemTimeSeconds()
            if lastClick.index == index and now - lastClick.time < DOUBLE then
                lastClick = { index = false, time = 0 }
                if opts.onActivate then opts.onActivate(index) end
            else
                lastClick = { index = index, time = now }
                G:SetSelected(index)
                if opts.onSelect then opts.onSelect(index) end
            end
        end
        drag.OnCancel = function(d)
            d:Destroy()
            G.dragging = false
            if ghost then ghost:Destroy() ghost = false end
        end
        PostDragger(frame, event.KeyCode, drag)
    end

    local function EnsureCells(n)
        while table.getn(G.cells) < n do
            local i = table.getn(G.cells) + 1
            local cell = { bg = Bitmap(G.root) }
            cell.bg.Depth:Set(function() return G.root.Depth() + 2 end)
            cell.bg:SetSolidColor(c.panel)
            cell.thumb = Bitmap(cell.bg)
            cell.thumb:SetSolidColor(c.panelAlt)
            cell.thumb.Depth:Set(function() return cell.bg.Depth() + 3 end)
            cell.thumb:DisableHitTest()
            cell.label = W.Label(cell.bg, '', 0, 0, { size = 'small' })
            cell.label.Depth:Set(function() return cell.bg.Depth() + 4 end)
            cell.badge = W.Label(cell.bg, '', 0, 0, { color = c.accent, size = 'small' })
            cell.badge.Depth:Set(function() return cell.bg.Depth() + 6 end)
            cell.mark = W.Label(cell.bg, '', 0, 0, { color = c.text })       -- a few letters on a picture-less tile
            cell.mark.Depth:Set(function() return cell.bg.Depth() + 6 end)
            cell.index = nil
            cell.bg.HandleEvent = function(self, event)
                if event.Type == 'WheelRotation' then
                    return Wheel(self, event)
                elseif cell.index == nil then
                    return false
                elseif event.Type == 'MouseEnter' then
                    cell.hot = true
                    G:StyleCell(cell)
                    if opts.onHover then opts.onHover(cell.index) end
                    return true
                elseif event.Type == 'MouseExit' then
                    cell.hot = false
                    G:StyleCell(cell)
                    if opts.onHover and not G.dragging then opts.onHover(nil) end
                    return true
                elseif event.Type == 'ButtonPress' then
                    if event.Modifiers and event.Modifiers.Right then
                        if opts.onContext then opts.onContext(cell.index, event.MouseX, event.MouseY) end
                        return true
                    end
                    StartDrag(cell, event)
                    return true
                end
                return false
            end
            G.cells[i] = cell
        end
    end

    function G:StyleCell(cell)
        local col = c.panel
        if cell.index and cell.index == G.selected then col = c.select
        elseif cell.hot then col = c.hover end
        cell.bg:SetSolidColor(col)
    end

    function G:UpdateScrollbar()
        local total, vis = TotalRows(), Rows()
        if total <= vis then
            G.track:Hide()
            G.thumbBar:Hide()
            return
        end
        local sw = Skin.S(Skin.size.scrollW)
        local trackH = G.h
        local thumbH = math.max(Skin.S(24), math.floor(trackH * vis / total))
        local range = trackH - thumbH
        local ty = math.floor(range * G.offset / math.max(1, total - vis))
        G.track:SetSolidColor('50000000')
        G.thumbBar:SetSolidColor(G.hotBar and c.accent or c.textDim)
        W.Place(G.track, G.root, G.w - sw, 0, sw, trackH)
        W.Place(G.thumbBar, G.root, G.w - sw, ty, sw, thumbH)
        G.track:Show()
        G.thumbBar:Show()
        G.thumbBar.HandleEvent = function(self, event)
            if event.Type == 'MouseEnter' then
                G.hotBar = true
                self:SetSolidColor(c.accent)
                return true
            elseif event.Type == 'MouseExit' then
                G.hotBar = false
                self:SetSolidColor(c.textDim)
                return true
            elseif event.Type == 'ButtonPress' then
                local startY, startOffset = event.MouseY, G.offset
                local drag = Dragger()
                drag.OnMove = function(d, x, y)
                    local per = range / math.max(1, total - vis)
                    local delta = math.floor((y - startY) / math.max(0.001, per) + 0.5)
                    G.offset = math.max(0, math.min(MaxOffset(), startOffset + delta))
                    G:Refresh()
                end
                drag.OnRelease = function(d, x, y) d:Destroy() end
                PostDragger(self:GetRootFrame(), event.KeyCode, drag)
                return true
            end
            return false
        end
    end

    function G:Refresh()
        local count = Count()
        local usable = G.w
        local cols = G.listMode and 1 or math.max(1, math.floor(usable / cellW))
        -- a scrollbar takes room from the cells when the rows do not all fit
        if math.ceil(count / cols) > Rows() then
            usable = G.w - Skin.S(Skin.size.scrollW)
            cols = G.listMode and 1 or math.max(1, math.floor(usable / cellW))
        end
        G.cols = cols
        if G.offset > MaxOffset() then G.offset = MaxOffset() end
        local rows = Rows()
        EnsureCells(rows * cols)
        local cw = math.floor(usable / cols)
        G.cw = cw
        for i = 1, table.getn(G.cells) do
            local cell = G.cells[i]
            local slot = i - 1
            local index = G.offset * cols + slot + 1
            if slot < rows * cols and index <= count then
                local r, col = math.floor(slot / cols), math.mod(slot, cols)
                cell.index = index
                W.Place(cell.bg, G.root, col * cw, r * G.cellH, cw - Skin.S(2), G.cellH - Skin.S(2))
                cell.bg:Show()
                cell.thumb:Show()
                cell.label:Show()
                cell.badge:Show()
                cell.mark:Show()
                local pad = Skin.S(3)
                local innerW, innerH = cw - Skin.S(2), G.cellH - Skin.S(2)
                local side, textLeft, textTop
                if G.listMode then
                    -- list: the picture at the left, the name beside it, vertically centred
                    side = innerH - 2 * pad
                    cell.thumb.Left:Set(function() return cell.bg.Left() + pad end)
                    cell.thumb.Top:Set(function() return cell.bg.Top() + pad end)
                    textLeft = side + 2 * pad + Skin.S(4)
                else
                    -- grid: the picture is square and as wide as the cell allows; the name sits under it
                    side = math.min(innerW - 2 * pad, innerH - Skin.S(16) - pad)
                    cell.thumb.Left:Set(function() return cell.bg.Left() + math.floor((innerW - side) / 2) end)
                    cell.thumb.Top:Set(function() return cell.bg.Top() + pad end)
                    textLeft = pad
                end
                cell.side = side
                cell.thumb.Width:Set(side) cell.thumb.Height:Set(side)
                opts.bind(cell, index, index == G.selected)
                local text = cell.text or ''
                W.Fit(cell.label, text, innerW - textLeft - Skin.S(G.listMode and 28 or 6))
                cell.label.Left:Set(function() return cell.bg.Left() + textLeft end)
                if G.listMode then
                    local lh = cell.label.Height()
                    cell.label.Top:Set(function() return cell.bg.Top() + math.floor((innerH - lh) / 2) end)
                else
                    cell.label.Top:Set(function() return cell.bg.Top() + pad + side + Skin.S(2) end)
                end
                local mw, mh = cell.mark.Width(), cell.mark.Height()
                local tl, tt = cell.thumb.Left, cell.thumb.Top
                cell.mark.Left:Set(function() return tl() + math.floor((side - mw) / 2) end)
                cell.mark.Top:Set(function() return tt() + math.floor((side - mh) / 2) end)
                local bw = cell.badge.Width()
                cell.badge.Left:Set(function() return cell.bg.Right() - bw - Skin.S(5) end)
                cell.badge.Top:Set(function() return cell.bg.Top() + Skin.S(3) end)
                G:StyleCell(cell)
            else
                cell.index = nil
                cell.hot = false
                cell.bg:Hide()
                cell.thumb:Hide()
                cell.label:Hide()
                cell.badge:Hide()
                cell.mark:Hide()
            end
        end
        G:UpdateScrollbar()
    end

    function G:SetRect(x, y, w, h)
        G.x, G.y, G.w, G.h = x, y, w, h
        W.Place(G.root, parent, x, y, w, h)
        G:Refresh()
    end

    function G:SetSelected(i)
        G.selected = i
        G:Refresh()
    end

    function G:ScrollTo(i)
        local row = math.floor((i - 1) / G.cols)
        local vis = Rows()
        if row < G.offset then G.offset = row elseif row >= G.offset + vis then G.offset = row - vis + 1 end
        G.offset = math.max(0, math.min(MaxOffset(), G.offset))
        G:Refresh()
    end

    --- The visible cells that hold an item, for tests.
    function G:Cells()
        local list = {}
        for _, cell in G.cells do
            if cell.index then table.insert(list, cell) end
        end
        return list
    end

    function G:Destroy()
        G.root:Destroy()
    end
    return G
end
