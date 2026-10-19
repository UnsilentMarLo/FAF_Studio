-- The Layers panel: the ten terrain texture layers (Base, eight painted layers, Upper), which one the paint / erase brushes work on, and the
-- textures and tile size of each (a picker lists the layer textures of every environment found in the game data).
--
--   click a row         the layer to paint with (painted layers 1..8; selects the Paint tool when no layer brush is active)
--   Change albedo...    pick another albedo texture (the matching normal map follows when there is one next to it)
--   Change normal...    pick the normal map alone
--   Tile size           world units one texture tile covers; Enter applies
--   right click a row   the same as menu entries ('context.list')

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local UI = import('/lua/editor/ui.lua')
local Strata = import('/lua/editor/strata.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')

live = {}
picker = false     -- the open texture picker { group }
NONE = '*none*'    -- the picker's "no texture" entry

-- ---- texture picker ----------------------------------------------------------------------------------------------------------------------

function ClosePicker()
    if picker then
        picker.group:Destroy()
        picker = false
    end
end

local function LayerTextures(pattern)
    local list = {}
    for _, path in DiskFindFiles('/env', pattern) do
        if string.find(string.lower(path), '/layers/', 1, true) then
            table.insert(list, path)
        end
    end
    table.sort(list, function(a, b) return string.lower(a) < string.lower(b) end)
    return list
end

--- Opens the texture browser: a list with a thumbnail on every row, a large preview of the texture under the pointer, a filter field.
--- `kind` is 'albedo' or 'normal'. `done(path)` gets the chosen path; Esc or a click outside closes.
function OpenPicker(kind, title, done)
    ClosePicker()
    local frame = GetFrame(0)
    local c = Skin.color
    local rowH, rows = Skin.S(52), 9
    local listW, previewW = Skin.S(500), Skin.S(240)
    local width = listW + previewW + Skin.S(40)
    local height = Skin.S(66) + rowH * rows + Skin.S(16)
    local fw, fh = frame.Width(), frame.Height()
    local x, y = math.floor((fw - width) / 2), math.max(Skin.S(20), math.floor((fh - height) / 3))
    local group = Group(frame)
    group.Depth:Set(9000)
    group.Left:Set(x) group.Top:Set(y) group.Width:Set(width) group.Height:Set(height)
    local shade = Bitmap(group)
    shade.Depth:Set(function() return group.Depth() + 1 end)
    shade:SetSolidColor('60000000')
    shade.Left:Set(0) shade.Top:Set(0) shade.Width:Set(fw) shade.Height:Set(fh)
    shade.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' then ClosePicker() end
        return true
    end
    local box = Bitmap(group)
    box.Depth:Set(function() return group.Depth() + 2 end)
    box:SetSolidColor(c.line)
    box.Left:Set(function() return group.Left() end) box.Top:Set(function() return group.Top() end)
    box.Width:Set(width) box.Height:Set(height)
    local inner = Bitmap(group)
    inner.Depth:Set(function() return group.Depth() + 3 end)
    inner:SetSolidColor(c.panel)
    inner.Left:Set(function() return group.Left() + 1 end) inner.Top:Set(function() return group.Top() + 1 end)
    inner.Width:Set(width - 2) inner.Height:Set(height - 2)
    W.Label(group, title, Skin.S(10), Skin.S(8), { color = c.textDim }).Depth:Set(function() return group.Depth() + 6 end)

    local all = LayerTextures(kind == 'albedo' and '*_albedo.dds' or '*_normals.dds')
    table.insert(all, 1, NONE)         -- "no texture" first: transparent, what the Upper layer needs to let the layers below show
    local state = { shown = all }

    -- the large preview and its description (follows the pointer over the list)
    local px = listW + Skin.S(24)
    local preview = Bitmap(group)
    preview.Depth:Set(function() return group.Depth() + 6 end)
    preview:SetSolidColor(c.panelAlt)
    W.Place(preview, group, px, Skin.S(34), previewW, previewW)
    preview:DisableHitTest()
    local nameLabel = W.Label(group, '', px, Skin.S(34) + previewW + Skin.S(8), { color = c.text })
    local pathLabel = W.Label(group, '', px, Skin.S(34) + previewW + Skin.S(28), { color = c.textDim, size = 'small' })
    nameLabel.Depth:Set(function() return group.Depth() + 6 end)
    pathLabel.Depth:Set(function() return group.Depth() + 6 end)
    local function ShowPreview(path)
        if not path then return end
        if path == NONE then
            preview:SetSolidColor(c.panelAlt)
            nameLabel:SetText('(none)')
            pathLabel:SetText('transparent: the layers below show through')
            return
        end
        preview:SetTexture(path)
        W.Fit(nameLabel, (string.gsub(path, '^.*/', '')), previewW)
        W.Fit(pathLabel, (string.gsub(path, '/[^/]*$', '')), previewW)
    end

    local list
    local field = W.TextField(group, Skin.S(10), Skin.S(30), listW, Skin.S(22), {
        onChange = function(text)
            local f = string.lower(text or '')
            state.shown = {}
            for _, p in all do
                if f == '' or string.find(string.lower(p), f, 1, true) then table.insert(state.shown, p) end
            end
            list:SetSelected(nil)
            list:Refresh()
            ShowPreview(state.shown[1])
        end,
        onEscape = function() ClosePicker() end,
    })
    list = W.VirtualList(group, {
        rowH = 52,
        thumb = true,
        getCount = function() return table.getn(state.shown) end,
        bind = function(row, index)
            local path = state.shown[index]
            local tx = rowH - Skin.S(4) + Skin.S(10)
            local name, set
            if path == NONE then
                row.thumb:SetSolidColor(c.panelAlt)
                name, set = '(none)', 'transparent'
            else
                row.thumb:SetTexture(path)
                name = string.gsub(path, '^.*/', '')
                set = string.gsub((string.gsub(path, '/layers/.*$', '')), '^.*/', '')
            end
            W.Fit(row.text, name, math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(10)))
            row.text:SetColor(c.text)
            row.text.Left:Set(function() return row.bg.Left() + tx end)
            row.text.Top:Set(function() return row.bg.Top() + Skin.S(9) end)
            if not row.sub then
                row.sub = W.Label(row.bg, '', 0, 0, { color = c.textDim, size = 'small' })
            end
            row.sub:SetText(set)
            row.sub.Left:Set(function() return row.bg.Left() + tx end)
            row.sub.Top:Set(function() return row.bg.Top() + Skin.S(28) end)
        end,
        onSelect = function(index)
            local path = state.shown[index]
            ClosePicker()
            if path then done(path) end
        end,
        onHover = function(index)
            ShowPreview(state.shown[index])
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(58), listW + Skin.S(4), rowH * rows)
    ShowPreview(state.shown[1])
    field:AcquireFocus()
    picker = { group = group }
end

-- ---- the panel ---------------------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'layers', title = 'Layers',
    create = function(group, host)
        local P = { rows = {}, sel = false, w = 240, h = 300 }
        live.layers = P

        local function Reload()
            local layers = Strata.Layers()
            P.rows = {}
            for i = 10, 1, -1 do                  -- top layer first
                if layers[i] then table.insert(P.rows, layers[i]) end
            end
        end
        local function Selected()
            for _, l in P.rows do
                if l.index == P.sel then return l end
            end
            return nil
        end
        local function Say(text)
            UI.State.message = text
        end

        -- a change of the selected layer's textures or sizes, undoable
        local merge = false      -- { key, entry, time }: the last edit made by a slider, so a drag is one undo entry
        local function Edit(label, fn, mergeKey)
            local l = Selected()
            if not l then return end
            local before = Strata.Snapshot(l.index)
            fn(l)
            local after = Strata.Snapshot(l.index)
            local now = GetSystemTimeSeconds()
            if mergeKey and merge and merge.key == mergeKey .. l.index and now - merge.time < 1.5 and History.Top() == merge.entry then
                local entry = merge.entry
                entry.redo = function() Strata.Restore(after) end
                merge.time = now
            else
                local entry = {
                    label = label .. ' ' .. l.name,
                    undo = function() Strata.Restore(before) end,
                    redo = function() Strata.Restore(after) end,
                }
                UI.PushEdit(entry)
                merge = mergeKey and { key = mergeKey .. l.index, entry = entry, time = now } or false
            end
            P:Refresh()
        end

        P.list = W.VirtualList(group, {
            extra = true,
            thumb = true,
            rowH = 26,
            getCount = function() return table.getn(P.rows) end,
            bind = function(row, index)
                local l = P.rows[index]
                local active = l.painted and l.index == Strata.Active
                local clear = (l.albedo == Strata.CLEAR)
                local has = (l.file ~= '' and not clear)
                local title = l.name .. (has and ('   ' .. l.file) or '   (none)')
                if has then
                    row.thumb:SetTexture(l.albedo)
                else
                    row.thumb:SetSolidColor(Skin.color.panelAlt)
                end
                row.extra:SetText(has and string.format('%g', l.size) or '')
                local tx = row.bg.Height() + Skin.S(4)
                W.Fit(row.text, title, math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(50)))
                row.text:SetColor(active and Skin.color.accent or (has and Skin.color.text or Skin.color.textDim))
                row.extra:SetColor(Skin.color.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + tx end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local ew = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - ew - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local l = P.rows[index]
                if not l then return end
                P.sel = l.index
                if l.painted then
                    Strata.Active = l.index
                    local tool
                    for _, t in UI.Tools do if t.id == UI.State.tool then tool = t end end
                    if not tool or (tool.id ~= 'paint' and tool.id ~= 'erase') then UI.SelectTool('paint') end
                end
                P:Refresh()
            end,
            onContext = function(index, x, y)
                local l = P.rows[index]
                if l then
                    P.sel = l.index
                    Menu.Context('context.list', { list = 'layers', layer = l.index }, x, y)
                    P:Refresh()
                end
            end,
            bgColor = Skin.color.panel,
        })

        P.preview = Bitmap(group)
        P.preview:SetSolidColor(Skin.color.panelAlt)
        P.previewName = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.change = W.Button(group, 'Albedo...', 0, 0, Skin.S(84), Skin.S(24), function() P:Change('albedo') end)
        P.changeNormal = W.Button(group, 'Normal...', 0, 0, Skin.S(84), Skin.S(24), function() P:Change('normal') end)

        -- tile sizes: field, bar and - / + like every other number setting
        local function SizeSlider(which, label)
            return W.Slider(group, {
                label = label, min = 1, max = 256, step = 0.5, curve = 2, fmt = '%g',
                get = function()
                    local l = Selected()
                    if not l then return 1 end
                    return (which == 'albedo') and l.size or l.nsize
                end,
                set = function(v)
                    if v <= 0 then return end
                    Edit('tile size of', function(l)
                        if which == 'albedo' then Strata.SetSizes(l.index, v, l.nsize) else Strata.SetSizes(l.index, l.size, v) end
                    end, which)
                end,
            })
        end
        P.size = SizeSlider('albedo', 'Albedo tile size (world units)')
        P.nsize = SizeSlider('normal', 'Normal tile size (world units)')

        local function Entry(entry)
            if entry then
                UI.PushEdit(entry)
            else
                local n = Strata.TakeNotice()
                if n then Say(n) end
            end
            P:Refresh()
        end
        P.up = W.Button(group, 'Up', 0, 0, Skin.S(40), Skin.S(24), function()
            local l = Selected()
            if l then P.sel = l.index + 1 Entry(Strata.Move(l.index, 1)) end
        end)
        P.down = W.Button(group, 'Down', 0, 0, Skin.S(46), Skin.S(24), function()
            local l = Selected()
            if l then P.sel = l.index - 1 Entry(Strata.Move(l.index, -1)) end
        end)
        P.clearMask = W.Button(group, 'Clear', 0, 0, Skin.S(46), Skin.S(24), function()
            local l = Selected()
            if l then Entry(Strata.ClearMask(l.index)) end
        end)
        P.fillMask = W.Button(group, 'Fill', 0, 0, Skin.S(40), Skin.S(24), function()
            local l = Selected()
            if l then Entry(Strata.FillMask(l.index)) end
        end)
        P.xp = W.Button(group, 'TerrainXP (layers 5-8)', 0, 0, Skin.S(160), Skin.S(24), function()
            Strata.SetXP(not Strata.IsXP())
            P:Refresh()
        end, { toggle = true })

        --- Picks a texture for the selected layer.
        function P:Change(kind)
            local l = Selected()
            if not l then return end
            OpenPicker(kind, string.format('%s: %s texture', l.name, kind), function(path)
                if path == NONE then
                    if l.index == 0 then return end       -- the base layer always has a texture
                    Entry(Strata.RemoveTexture(l.index))        -- the texture and what it painted, one undo step
                    return
                end
                Edit('texture of', function()
                    local albedo, normal = l.albedo, l.normal
                    if kind == 'albedo' then
                        albedo = path
                        normal = ''                 -- SetTexture picks the matching normal map, or the neutral one
                    else
                        normal = path
                    end
                    Strata.SetTexture(l.index, albedo, normal, l.size, l.nsize)
                end)
            end)
        end

        function P:Refresh()
            Reload()
            if not P.sel then P.sel = Strata.Active end
            P.list:Refresh()
            P.xp:SetOn(Strata.IsXP())
            local l = Selected()
            -- the preview and the size fields only change when the selected layer or its texture does (a field may be mid-edit)
            local key = l and (l.index .. '|' .. l.albedo .. '|' .. tostring(l.size) .. '|' .. tostring(l.nsize)) or ''
            if key ~= P.shownKey then
                P.shownKey = key
                if l and l.albedo ~= '' and l.albedo ~= Strata.CLEAR then
                    P.preview:SetTexture(l.albedo)
                    P.previewName:SetText(l.file)
                    P.size:Refresh()
                    P.nsize:Refresh()
                else
                    P.preview:SetSolidColor(Skin.color.panelAlt)
                    P.previewName:SetText(l and 'no texture' or '')
                    P.size:Refresh()
                    P.nsize:Refresh()
                end
            end
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            local rowH = Skin.S(26)
            local detail = Skin.S(284)
            local listH = math.max(rowH * 3, math.min(rowH * 10, h - 2 * pad - detail))
            P.list:SetRect(pad, pad, w - 2 * pad, listH)
            local y = pad + listH + Skin.S(8)
            local ps = Skin.S(72)
            W.Place(P.preview, group, pad, y, ps, ps)
            W.Place(P.previewName, group, pad, y + ps + Skin.S(2))
            local x = pad + ps + Skin.S(10)
            local cw = math.max(Skin.S(52), math.min(Skin.S(84), w - pad - x))      -- in a narrow panel the buttons shrink instead of running past its edge
            W.Place(P.change, group, x, y, cw, Skin.S(24))
            W.Place(P.changeNormal, group, x, y + Skin.S(28), cw, Skin.S(24))
            W.Center(P.change.label, P.change, 0, 0, cw, Skin.S(24))
            W.Center(P.changeNormal.label, P.changeNormal, 0, 0, cw, Skin.S(24))
            y = y + ps + Skin.S(22)
            P.size:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(50)
            P.nsize:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(54)
            local bx = pad
            for _, b in { P.up, P.down, P.clearMask, P.fillMask } do
                W.Place(b, group, bx, y, b.Width(), Skin.S(24))
                bx = bx + b.Width() + Skin.S(4)
            end
            y = y + Skin.S(30)
            W.Place(P.xp, group, pad, y, math.min(Skin.S(160), w - 2 * pad), Skin.S(24))
            W.Center(P.xp.label, P.xp, 0, 0, math.min(Skin.S(160), w - 2 * pad), Skin.S(24))
            P:Refresh()
        end

        function P:Destroy()
            ClosePicker()
        end
        return P
    end,
}

-- ---- the texture brush ---------------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'texbrush', title = 'Texture brush',
    create = function(group, host)
        local P = { rows = {} }
        live.texbrush = P
        local B = Strata.Brush
        local TB = Terrain.Brush

        local function Single(label, min, max, step, fmt, get, set)
            local s = W.Slider(group, { label = label, min = min, max = max, step = step, fmt = fmt, get = get, set = set })
            table.insert(P.rows, { single = s })
            return s
        end
        local function Pair(a, b)
            a.compact, b.compact = true, true
            local sa, sb = W.Slider(group, a), W.Slider(group, b)
            table.insert(P.rows, { left = sa, right = sb })
        end

        Single('Size', 1, 64, 1, '%d', function() return TB.radius end, function(v) UI.SetRadius(v) end)
        Single('Strength % (Shift inverts)', -100, 100, 1, '%d', function() return B.strength end, function(v) B.strength = v end)
        Single('Falloff % (0 flat, 100 full)', 0, 100, 1, '%d', function() return TB.falloff * 100 end, function(v) TB.falloff = v / 100 end)
        Pair({ label = 'Target %', min = 5, max = 100, step = 1, fmt = '%d', get = function() return B.target end, set = function(v) B.target = v end },
             { label = 'Scatter %', min = 0, max = 100, step = 1, fmt = '%d', get = function() return B.scatter end, set = function(v) B.scatter = v end })
        Pair({ label = 'Min slope', min = 0, max = 90, step = 1, fmt = '%d', get = function() return B.minSlope end,
               set = function(v) B.minSlope = v if B.maxSlope < v then B.maxSlope = v end P:Refresh() end },
             { label = 'Max slope', min = 0, max = 90, step = 1, fmt = '%d', get = function() return B.maxSlope end,
               set = function(v) B.maxSlope = v if B.minSlope > v then B.minSlope = v end P:Refresh() end })
        Pair({ label = 'Min height', min = 0, max = 512, step = 1, fmt = '%d', get = function() return B.minHeight end,
               set = function(v) B.minHeight = v if B.maxHeight < v then B.maxHeight = v end P:Refresh() end },
             { label = 'Max height', min = 0, max = 512, step = 1, fmt = '%d', get = function() return B.maxHeight end,
               set = function(v) B.maxHeight = v if B.minHeight > v then B.minHeight = v end P:Refresh() end })

        -- how the dabs of one stroke combine (strata.lua Brush.blend)
        P.blendLabel = W.Label(group, 'Blend', 0, 0, { color = Skin.color.textDim })
        P.blendMax = W.Button(group, 'Stroke max', 0, 0, Skin.S(86), Skin.S(24), function()
            B.blend = 'max'
            P:Refresh()
        end, { toggle = true })
        P.blendAdd = W.Button(group, 'Build up', 0, 0, Skin.S(72), Skin.S(24), function()
            B.blend = 'add'
            P:Refresh()
        end, { toggle = true })
        P.blendNote = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        P.invert = W.Button(group, 'Invert', 0, 0, Skin.S(70), Skin.S(24), function(self)
            B.invert = self.on
        end, { toggle = true })
        -- the limits above, applied to the whole map in one go
        local function Auto(erase)
            local entry = Strata.AutoPaint(Strata.Active, erase)
            if entry then
                UI.PushEdit(entry)
            else
                local n = Strata.TakeNotice()
                if n then UI.Say(n) end
            end
        end
        P.autoPaint = W.Button(group, 'Auto paint', 0, 0, Skin.S(90), Skin.S(24), function() Auto(false) end)
        P.autoErase = W.Button(group, 'Auto erase', 0, 0, Skin.S(90), Skin.S(24), function() Auto(true) end)
        P.reset = W.Button(group, 'Reset', 0, 0, Skin.S(60), Skin.S(24), function()
            B.strength, B.target, B.scatter, B.minSlope, B.maxSlope, B.minHeight, B.maxHeight, B.invert = 50, 100, 0, 0, 90, 0, 512, false
            B.blend = 'max'
            P:Refresh()
        end)
        P.layer = W.Label(group, '', 0, 0, { color = Skin.color.textDim })
        P.note = W.Label(group, 'Slope and height limits skip cells outside the range.', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            for _, r in P.rows do
                if r.single then
                    r.single:Refresh()
                else
                    r.left:Refresh()
                    r.right:Refresh()
                end
            end
            P.invert:SetOn(B.invert)
            P.blendMax:SetOn(B.blend ~= 'add')
            P.blendAdd:SetOn(B.blend == 'add')
            P.blendNote:SetText(B.blend == 'add' and 'Every dab adds: slow strokes and repeated passes get stronger.'
                or 'A cell takes the strongest dab of the stroke; passes over it add nothing.')
            P:RefreshLabel()
        end

        --- The "painting with" line follows the layer picked elsewhere (the sliders are left alone: a field may be mid-edit).
        function P:RefreshLabel()
            local layers = Strata.Layers()
            local l = layers[Strata.Active + 1]
            local text = 'Painting with: ' .. (l and (l.name .. (l.file ~= '' and ('  ' .. l.file) or '  (no texture)')) or '?')
            if text ~= P.labelText then
                P.labelText = text
                P.layer:SetText(text)
            end
        end

        function P:OnResize(w, h)
            local pad = Skin.S(10)
            local y = pad
            local half = math.floor((w - 3 * pad) / 2)
            for _, r in P.rows do
                if r.single then
                    r.single:Place(pad, y, w - 2 * pad)
                else
                    r.left:Place(pad, y, half)
                    r.right:Place(pad + half + pad, y, half)
                end
                y = y + Skin.S(52)
            end
            W.Place(P.blendLabel, group, pad, y + Skin.S(4))
            W.Place(P.blendMax, group, pad + Skin.S(44), y, Skin.S(86), Skin.S(24))
            W.Place(P.blendAdd, group, pad + Skin.S(44) + Skin.S(90), y, Skin.S(72), Skin.S(24))
            y = y + Skin.S(28)
            W.Place(P.blendNote, group, pad, y)
            y = y + Skin.S(22)
            W.Place(P.invert, group, pad, y, Skin.S(70), Skin.S(24))
            W.Place(P.reset, group, pad + Skin.S(78), y, Skin.S(60), Skin.S(24))
            y = y + Skin.S(28)
            W.Place(P.autoPaint, group, pad, y, Skin.S(94), Skin.S(24))
            W.Place(P.autoErase, group, pad + Skin.S(100), y, Skin.S(94), Skin.S(24))
            y = y + Skin.S(30)
            W.Place(P.layer, group, pad, y)
            W.Place(P.note, group, pad, y + Skin.S(20))
            P:Refresh()
        end
        return P
    end,
}

function Refresh()
    -- the texture brush panel is not polled: its fields would lose what is being typed (its values only change through the panel)
    for id, inst in live do
        if id ~= 'texbrush' and inst.Refresh then pcall(inst.Refresh, inst) end
    end
    if live.texbrush then pcall(live.texbrush.RefreshLabel, live.texbrush) end
end

-- right-click menu of a layer row
Menu.Extend('context.list', function(ctx)
    if ctx.list ~= 'layers' then return nil end
    local items = {}
    local layers = Strata.Layers()
    local l = layers[ctx.layer + 1]
    if l and l.painted then
        table.insert(items, { title = 'Paint with ' .. l.name, run = function()
            Strata.Active = l.index
            UI.SelectTool('paint')
        end })
    end
    table.insert(items, { title = 'Change albedo texture...', run = function() if live.layers then live.layers:Change('albedo') end end })
    table.insert(items, { title = 'Change normal map...', run = function() if live.layers then live.layers:Change('normal') end end })
    if l and l.index >= 1 then
        table.insert(items, { title = 'Remove texture (transparent)', run = function()
            local entry = Strata.RemoveTexture(l.index)
            if entry then UI.PushEdit(entry) end
            if live.layers then live.layers:Refresh() end
        end })
    end
    return items
end, 10)
