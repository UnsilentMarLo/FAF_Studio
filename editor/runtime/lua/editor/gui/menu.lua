-- Menus: the popup widget behind the menu bar and every right-click menu, and the registry that makes both extensible.
--
--   Menu.Extend(id, fn, order)    add a provider to menu `id`: fn(ctx) returns a list of items (or nil). Providers of one menu are
--                                 sorted by `order` (default 50) and separated by a line. Editor mods extend any menu the same way.
--   Menu.Build(id, ctx)           the combined item list of a menu
--   Menu.Context(id, ctx, x, y)   open menu `id` at a frame position (nothing opens when it is empty)
--   Menu.Show(frame, x, y, items, opts)   open an item list directly; opts.shadeTop keeps the strip above that y clickable (menu bar)
--   Menu.Close()
--
-- Menu ids used by the editor: 'menubar.<Title>' (File, Edit, View, Workspace, Window, Help; Menu.Titles lists them in order),
-- 'context.world' (right click in the viewport; ctx = { wx, wz, height, hit }), 'context.object' (a marker or area; ctx = { kind, name }),
-- 'context.list' (a list row: ctx = { list = '<panel id>', index, ... }).
--
-- Item fields: title, command (a command id: title and key text come from the registry, a click runs it), run (function), keys (text shown
-- on the right), checked / enabled (booleans or functions), why (text, or a function returning it: shown dim at the right instead of the keys while the item is
-- disabled, so a greyed-out entry says what is missing), title may be a function (a live label such as "Undo: move ARMY_1"), submenu (item list or function returning one), separator = true, header = true
-- (a dim, non-clickable title row).

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Commands = import('/lua/editor/gui/commands.lua')

Titles = { 'File', 'Edit', 'View', 'Map', 'Terrain', 'Workspace', 'Window', 'Help' }

providers = {}
debug = false         -- LOG the events menu controls receive
current = false       -- the open menu: { shade, levels = { { group, rows, items, row } } , onClose }

function Extend(id, fn, order)
    if not providers[id] then providers[id] = {} end
    table.insert(providers[id], { order = order or 50, fn = fn })
    table.sort(providers[id], function(a, b) return a.order < b.order end)
end

function Build(id, ctx)
    local items = {}
    for _, p in providers[id] or {} do
        local ok, list = pcall(p.fn, ctx)
        if not ok then
            LOG('EDITOR menu ' .. id .. ': provider failed: ' .. tostring(list))
        elseif list and table.getn(list) > 0 then
            if table.getn(items) > 0 then table.insert(items, { separator = true }) end
            local bar = string.find(id, '^menubar%.') ~= nil
            for _, item in list do
                if bar then item.strip = true end
                table.insert(items, item)
            end
        end
    end
    return items
end

local function Value(v)
    if type(v) == 'function' then
        local ok, r = pcall(v)
        if ok then return r end
        return false
    end
    return v
end

--- Resolves one item into plain fields: { title, keys, enabled, checked, run, submenu, separator, header }.
local function Resolve(item)
    local r = { separator = item.separator, header = item.header }
    if item.separator then return r end
    local def = item.command and Commands.registry[item.command]
    r.title = Value(item.title) or (def and (def.title or def.id)) or tostring(item.command)
    if item.strip and not item.title then
        -- command titles carry their category ("View: build grid"); under a menu bar title the category is redundant
        local stripped = string.gsub(r.title, '^%a+: ', '')
        r.title = string.upper(string.sub(stripped, 1, 1)) .. string.sub(stripped, 2)
    end
    local keys = item.keys
    if not keys and def and not item.nokeys then
        keys = def.keys
        if (not keys or keys == '') and def.keys2 and def.keys2 ~= '' then keys = def.keys2 end
    end
    if keys and keys ~= '' then
        r.keys = string.gsub(keys, '%-', '+')
    end
    r.enabled = item.enabled == nil and true or Value(item.enabled)
    if item.command and not def then r.enabled = false end
    if item.header then r.enabled = false end
    r.checked = Value(item.checked)
    if not r.enabled and not item.header then
        local why = Value(item.why)
        if why and why ~= '' then r.why = why end
    end
    r.submenu = item.submenu
    if item.strip and type(item.submenu) == 'table' then
        for _, sub in item.submenu do sub.strip = true end
    end
    r.run = item.run or (item.command and function() Commands.Run(item.command) end)
    r.command, r.tip = item.command, item.tip
    return r
end

function Close()
    if not current then return end
    local c = current
    current = false
    for _, level in c.levels do level.group:Destroy() end
    pcall(function() c.shade:AbandonKeyboardFocus() end)
    c.shade:Destroy()
    if c.onClose then pcall(c.onClose) end
end

local function CloseFrom(index)
    if not current then return end
    for i = table.getn(current.levels), index, -1 do
        current.levels[i].group:Destroy()
        current.levels[i] = nil
    end
end

local function Measure(frame, text, size)
    local probe = W.Label(frame, text, 0, 0, { size = size })
    local w = probe.Width()
    probe:Destroy()
    return w
end

local function ShowLevel(frame, index, items, x, y, rowRect)
    local c = Skin.color
    local list = {}
    for _, item in items do table.insert(list, Resolve(item)) end

    local rowH, sepH, padX = Skin.S(22), Skin.S(7), Skin.S(10)
    local titleW, keysW = 0, 0
    local height = 0
    for _, r in list do
        if r.separator then
            height = height + sepH
        else
            titleW = math.max(titleW, Measure(frame, r.title))
            local side = r.why or r.keys
            if side then keysW = math.max(keysW, Measure(frame, side, 'small')) end
            height = height + rowH
        end
    end
    local markW = Skin.S(18)
    local width = markW + titleW + (keysW > 0 and (keysW + Skin.S(28)) or Skin.S(10)) + Skin.S(18) + padX
    width = math.max(width, Skin.S(150))
    local pad = Skin.S(3)
    local fw, fh = frame.Width(), frame.Height()
    -- a menu taller than the window is laid out in columns (each as tall as the window allows): the rows of a column start at colY, the column of a row is colOf
    local maxH = fh - 2 * pad - 4
    local cols, colOf, colY = 1, {}, {}
    if height > maxH then
        local cy, col = 0, 1
        for i, r in list do
            local h = r.separator and sepH or rowH
            if cy + h > maxH and cy > 0 then
                col = col + 1
                cy = 0
            end
            colOf[i], colY[i] = col, cy
            cy = cy + h
        end
        cols = col
        height = maxH
    end
    local totalW = width * cols
    -- stay on screen: a submenu that does not fit opens to the left of its parent, a long menu moves up
    if x + totalW + 2 > fw then
        if rowRect then x = rowRect.left - totalW + Skin.S(2) else x = fw - totalW - 2 end
    end
    if x < 0 then x = 0 end
    if y + height + 2 * pad + 2 > fh then y = math.max(0, fh - height - 2 * pad - 2) end

    local group = Group(frame)
    group.Depth:Set(9600 + index * 10)
    group.Left:Set(x) group.Top:Set(y) group.Width:Set(totalW + 2) group.Height:Set(height + 2 * pad + 2)
    local border = Bitmap(group)
    border.Depth:Set(function() return group.Depth() + 1 end)
    border:SetSolidColor(c.line)
    border.Left:Set(function() return group.Left() end) border.Top:Set(function() return group.Top() end)
    border.Width:Set(totalW + 2) border.Height:Set(height + 2 * pad + 2)
    local body = Bitmap(group)
    body.Depth:Set(function() return group.Depth() + 2 end)
    body:SetSolidColor(c.panel)
    body.Left:Set(function() return group.Left() + 1 end) body.Top:Set(function() return group.Top() + 1 end)
    body.Width:Set(totalW) body.Height:Set(height + 2 * pad)

    local level = { group = group, rows = {}, items = list }
    current.levels[index] = level

    local ry = pad
    for i, item in list do
        -- closures made below outlive the loop: they need their own copies (the loop variable is nil afterwards, `ry` keeps moving)
        local r = item
        local cx = (colOf[i] or 1) - 1
        cx = cx * width
        if colY[i] then ry = pad + colY[i] end
        local rowY = ry
        if r.separator then
            local line = Bitmap(group)
            line.Depth:Set(function() return group.Depth() + 3 end)
            line:SetSolidColor(c.line)
            W.Place(line, group, cx + Skin.S(8), ry + math.floor(sepH / 2), width - Skin.S(14), 1)
            line:DisableHitTest()
            ry = ry + sepH
        else
            local row = Bitmap(group)
            row.Depth:Set(function() return group.Depth() + 3 end)
            row:SetSolidColor(c.panel)
            W.Place(row, group, cx + 1, ry + 1, width, rowH)
            local textColor = r.enabled and c.text or c.textDim
            if r.header then textColor = c.textDim end
            local label = W.Label(row, r.title, markW, math.floor((rowH - Skin.S(15)) / 2), { color = textColor })
            local entry = { row = row, data = r, y = rowY }
            if r.checked then
                local mark = Bitmap(row)
                mark.Depth:Set(function() return row.Depth() + 4 end)
                mark:SetSolidColor(r.enabled and c.accent or c.textDim)
                local ms = Skin.S(6)
                W.Place(mark, row, Skin.S(7), math.floor((rowH - ms) / 2), ms, ms)
                mark:DisableHitTest()
            end
            if r.why or r.keys then
                local kl = W.Label(row, r.why or r.keys, 0, math.floor((rowH - Skin.S(14)) / 2), { color = c.textDim, size = 'small' })
                local kw = kl.Width()
                kl.Left:Set(function() return row.Left() + width - kw - Skin.S(14) end)
            end
            if r.submenu then
                local al = W.Label(row, '>', 0, math.floor((rowH - Skin.S(15)) / 2), { color = textColor })
                al.Left:Set(function() return row.Left() + width - Skin.S(14) end)
            end
            row.HandleEvent = function(self, event)
                if debug then LOG('MENU row ' .. tostring(r.title) .. ' ' .. tostring(event.Type)) end
                if event.Type == 'MouseEnter' then
                    CloseFrom(index + 1)
                    if r.enabled then self:SetSolidColor(c.hover) end
                    if not r.header then
                        pcall(function()
                            import('/lua/editor/gui/tooltip.lua').Hover(self, function()
                                local Tips = import('/lua/editor/tooltips.lua')
                                local text = Tips.ForMenuItem(r)
                                if text and r.command then text = Tips.WithHotkey(text, r.command) end
                                return text
                            end, event, { menu = true })
                        end)
                    end
                    if r.submenu and r.enabled and current then
                        local sub = r.submenu
                        if type(sub) == 'function' then sub = sub() end
                        if sub and table.getn(sub) > 0 then
                            ShowLevel(frame, index + 1, sub, x + cx + width + 2 - Skin.S(2), y + rowY,
                                { left = x + cx })
                        end
                    end
                    return true
                elseif event.Type == 'MouseExit' then
                    self:SetSolidColor(c.panel)
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Leave(self) end)
                    return true
                elseif event.Type == 'ButtonPress' then
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Hide() end)
                    if r.enabled and not r.submenu and r.run then
                        local run = r.run
                        Close()
                        local ok, err = pcall(run)
                        if not ok then LOG('EDITOR menu: ' .. tostring(r.title) .. ' failed: ' .. tostring(err)) end
                    end
                    return true
                end
                return false
            end
            table.insert(level.rows, entry)
            ry = ry + rowH
        end
    end
    return level
end

--- Opens a menu from an item list at frame position (x, y). Replaces any open menu.
function Show(frame, x, y, items, opts)
    Close()
    if not items or table.getn(items) == 0 then return false end
    opts = opts or {}
    local shade = Bitmap(frame)
    shade.Depth:Set(9590)
    shade:SetSolidColor('00000000')
    shade.Left:Set(0) shade.Top:Set(opts.shadeTop or 0)
    shade.Width:Set(frame.Width()) shade.Height:Set(frame.Height() - (opts.shadeTop or 0))
    shade.HandleEvent = function(self, event)
        if debug then LOG('MENU shade ' .. tostring(event.Type)) end
        if event.Type == 'ButtonPress' then
            Close()
            return true
        elseif event.Type == 'KeyDown' then
            if event.RawKeyCode == 27 then Close() end
            return true
        end
        return true
    end
    current = { shade = shade, levels = {}, onClose = opts.onClose }
    shade:AcquireKeyboardFocus(false)
    ShowLevel(frame, 1, items, x, y, nil)
    return true
end

function Context(id, ctx, x, y)
    local items = Build(id, ctx)
    return Show(GetFrame(0), x, y, items)
end

function IsOpen()
    return current ~= false
end
