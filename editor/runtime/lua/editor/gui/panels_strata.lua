-- The Layers panel: the ten terrain texture layers (Base, eight painted layers, Upper), which one the paint / erase brushes work on, and the
-- textures and tile size of each (a picker lists the layer textures of every environment found in the game data).
--
--   click a row         the layer to paint with (painted layers 1..8; selects the Paint tool when no layer brush is active)
--   click the albedo    pick another albedo texture (the matching normal map follows when there is one next to it)
--   click the normal    pick the normal map alone
--   Shader              the terrain shader of the map (shaderbrowser.lua)
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
    import('/lua/editor/gui/dialog.lua').Close()
end

--- Opens the texture browser on the layer textures of every environment (folders = environments, kind filter, thumbnails, search).
--- `kind` is 'albedo' or 'normal'. `done(path)` gets the chosen path; Esc or a click outside closes.
function OpenPicker(kind, title, done)
    import('/lua/editor/gui/browser.lua').OpenTextures{
        title = title,
        sources = { { '/env', kind == 'albedo' and '*_albedo.dds' or '*_normals.dds' } },
        match = function(path) return string.find(string.lower(path), '/layers/', 1, true) ~= nil end,
        done = done,
    }
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

        -- the two textures of the layer as pictures; a click on one picks another texture for it
        local function Picture(kind, tip)
            local b = Bitmap(group)
            b:SetSolidColor(Skin.color.panelAlt)
            b.HandleEvent = function(self, event)
                if event.Type == 'MouseEnter' then
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Hover(self, function() return tip end, event) end)
                    return true
                elseif event.Type == 'MouseExit' then
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Leave(self) end)
                    return true
                elseif event.Type == 'ButtonPress' then
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Hide() end)
                    P:Change(kind)
                    return true
                end
                return false
            end
            return b
        end
        P.preview = Picture('albedo', 'The albedo (colour) texture of the layer. Click to pick another one; the matching normal map follows.')
        P.previewNormal = Picture('normal', 'The normal map of the layer. Click to pick another one.')
        P.previewName = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.previewNormalName = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

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
        P.texset = W.Button(group, 'Texture set: ...', 0, 0, Skin.S(220), Skin.S(24), function()
            local TS = import('/lua/editor/texsets.lua')
            local items = {}
            for _, id in TS.ThemeOrder do
                local themeId = id
                table.insert(items, { title = TS.Themes[themeId].label, run = function()
                    local n = TS.Apply(themeId)
                    Say('texture set ' .. TS.Themes[themeId].label .. ': ' .. n .. ' layers')
                    P:Refresh()
                end })
            end
            local x, y = P.texset.Left(), P.texset.Bottom()
            Menu.Show(GetFrame(0), x, y, items)
        end)
        P.shader = W.Button(group, 'Shader: ...', 0, 0, Skin.S(220), Skin.S(24), function()
            import('/lua/editor/gui/shaderbrowser.lua').Open(function(id)
                Say('terrain shader: ' .. id)
                P:Refresh()
            end)
        end)

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
            -- The list binds its rows again (a texture, a fitted name and two positions each) only when a layer, the chosen layer or the painting layer changed: the shell's tick
            -- calls this four times a second.
            local rowsKey = tostring(P.sel) .. '|' .. tostring(Strata.Active) .. '|' .. tostring(P.list.w) .. '|' .. tostring(P.list.h)
            for _, r in P.rows do rowsKey = rowsKey .. ';' .. r.index .. ',' .. r.albedo .. ',' .. tostring(r.size) end
            if rowsKey ~= P.rowsKey then
                P.rowsKey = rowsKey
                P.list:Refresh()
            end
            local TS = import('/lua/editor/texsets.lua')
            local texsetText = 'Texture set: ' .. ((TS.Themes[TS.Theme] and TS.Themes[TS.Theme].label) or TS.Theme)
            if texsetText ~= P.texsetShown then
                P.texsetShown = texsetText
                P.texset:SetText(texsetText)
            end
            local shaderName = import('/lua/editor/shaders.lua').Current() or '?'
            if P.shaderShown ~= shaderName then
                P.shaderShown = shaderName
                P.shader:SetText('Shader: ' .. shaderName)
            end
            local l = Selected()
            -- the preview and the size fields only change when the selected layer or its texture does (a field may be mid-edit)
            local key = l and (l.index .. '|' .. l.albedo .. '|' .. l.normal .. '|' .. tostring(l.size) .. '|' .. tostring(l.nsize)) or ''
            if key ~= P.shownKey then
                P.shownKey = key
                local pw = P.previewW or Skin.S(72)
                if l and l.albedo ~= '' and l.albedo ~= Strata.CLEAR then
                    P.preview:SetTexture(l.albedo)
                    W.Fit(P.previewName, 'Albedo: ' .. l.file, pw)
                else
                    P.preview:SetSolidColor(Skin.color.panelAlt)
                    P.previewName:SetText(l and 'Albedo: none' or '')
                end
                if l and l.normal ~= '' and l.normal ~= Strata.NONE_NORMAL then
                    P.previewNormal:SetTexture(l.normal)
                    W.Fit(P.previewNormalName, 'Normal: ' .. (l.normalFile or ''), pw)
                else
                    P.previewNormal:SetSolidColor(Skin.color.panelAlt)
                    P.previewNormalName:SetText(l and 'Normal: none' or '')
                end
                P.size:Refresh()
                P.nsize:Refresh()
            end
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            local rowH = Skin.S(26)
            local detail = Skin.S(366)
            local listH = math.max(rowH * 3, math.min(rowH * 10, h - 2 * pad - detail))
            P.list:SetRect(pad, pad, w - 2 * pad, listH)
            local y = pad + listH + Skin.S(8)
            local ps = math.max(Skin.S(56), math.min(Skin.S(120), math.floor((w - 3 * pad) / 2)))
            P.previewW = ps
            W.Place(P.preview, group, pad, y, ps, ps)
            W.Place(P.previewNormal, group, 2 * pad + ps, y, ps, ps)
            W.Place(P.previewName, group, pad, y + ps + Skin.S(2))
            W.Place(P.previewNormalName, group, 2 * pad + ps, y + ps + Skin.S(2))
            P.shownKey = nil          -- the file names are fitted to the picture width
            y = y + ps + Skin.S(24)
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
            local sw = math.min(Skin.S(220), w - 2 * pad)
            W.Place(P.texset, group, pad, y, sw, Skin.S(24))
            W.Center(P.texset.label, P.texset, 0, 0, sw, Skin.S(24))
            y = y + Skin.S(30)
            W.Place(P.shader, group, pad, y, sw, Skin.S(24))
            W.Center(P.shader.label, P.shader, 0, 0, sw, Skin.S(24))
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
