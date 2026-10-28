-- The Layers panel: the ten terrain texture layers (Base, eight painted layers, Upper), which one the paint / erase brushes work on, and the
-- textures and tile size of each (a picker lists the layer textures of every environment found in the game data).
--
--   click a row         the layer to paint with (painted layers 1..8; selects the Paint tool when no layer brush is active)
--   click the albedo    pick another albedo texture (the matching normal map follows when there is one next to it)
--   click the normal    pick the normal map alone
--   Shader              the terrain shader of the map (shaderbrowser.lua)
--   Convert layers...   the shader browser asking for the shader to convert the layers to (paint masks, layer 8, Upper layer: stratumconv.lua, convertdialog.lua)
--   Tile size           world units one texture tile covers; Enter applies
--   right click a row   the same as menu entries ('context.list')
--   Relief / Raw        the normal picture: a shaded relief made from the normals (normalpreview.lua, the default) or the texture as it is
--
-- Layout: the list takes the height the panel has left over (up to all ten layers; at least MIN_ROWS rows, then it scrolls itself); everything below it keeps its size, and the panel
-- scrolls (widgets.lua ScrollContent) when the whole is taller than the panel. The pictures stand side by side when the panel is wide enough, else one above the other.

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
local Shaders = import('/lua/editor/shaders.lua')

live = {}
picker = false     -- the open texture picker { group }
NONE = '*none*'    -- the picker's "no texture" entry
MIN_ROWS = 6       -- fewest list rows the layout keeps before the whole panel scrolls instead

--- 'relief' or 'raw': what the normal map picture shows (remembered in the user settings).
function NormalView()
    local ok, v = pcall(function() return import('/lua/editor/userdata.lua').Get('layers_normalview', 'relief') end)
    if ok and v == 'raw' then return 'raw' end
    return 'relief'
end

function SetNormalView(v)
    pcall(function() import('/lua/editor/userdata.lua').Set('layers_normalview', v) end)
end

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
        -- the map's own textures (category 'This map'): any .dds of its folder that is not a decal; a normal map is one with 'normal' in its name, everything else is an albedo texture
        mapMatch = function(path, lower)
            if string.find(lower, '/decals/', 1, true) then return false end
            local normal = string.find(lower, 'normal', 1, true) ~= nil
            return (kind == 'albedo') ~= normal
        end,
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
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Hover(self, function() if type(tip) == 'function' then return tip() end return tip end, event) end)
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
        -- the full texture names, for the tooltips of the pictures (the captions below them wrap, but a very long name still ends in "...")
        P.full = { albedo = '', normal = '' }
        local function FullTip(kind, text)
            return function()
                if P.full[kind] ~= '' then return text .. '\n' .. P.full[kind] end
                return text
            end
        end
        P.preview = Picture('albedo', FullTip('albedo', 'The albedo (colour) texture of the layer. Click to pick another one; the matching normal map follows.'))
        P.previewNormal = Picture('normal', FullTip('normal', 'The normal map of the layer, drawn as a shaded relief (Raw shows the texture itself). Click to pick another one.'))

        -- a caption under a picture: a heading line and the file name over two lines (cut at _ - . where it can, "..." only when two lines are not enough)
        local function Caption()
            local function Line() return W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' }) end
            return { head = Line(), l1 = Line(), l2 = Line() }
        end
        P.cap = { albedo = Caption(), normal = Caption() }
        local function SetCaption(c, head, name, maxW)
            c.head:SetText(head)
            c.l1:SetText('')
            c.l2:SetText('')
            if name == '' then return end
            c.l1:SetText(name)
            if c.l1.Width() <= maxW then return end
            local cut = 0
            for i = 1, string.len(name) - 1 do
                local ch = string.sub(name, i, i)
                if ch == '_' or ch == '-' or ch == '.' or ch == ' ' then
                    c.l1:SetText(string.sub(name, 1, i))
                    if c.l1.Width() > maxW then break end
                    cut = i
                end
            end
            if cut == 0 then                      -- no break point fits: as many letters as fit
                cut = 1
                for i = 2, string.len(name) - 1 do
                    c.l1:SetText(string.sub(name, 1, i))
                    if c.l1.Width() > maxW then break end
                    cut = i
                end
            end
            c.l1:SetText(string.sub(name, 1, cut))
            W.Fit(c.l2, string.sub(name, cut + 1), maxW)
        end

        -- what the normal picture shows: a relief made from the normals, or the raw texture
        P.viewLabel = W.Label(group, 'Normal picture', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.viewRelief = W.Button(group, 'Relief', 0, 0, Skin.S(60), Skin.S(22), function()
            SetNormalView('relief')
            P.shownKey = nil
            P:Refresh()
        end, { toggle = true })
        P.viewRaw = W.Button(group, 'Raw', 0, 0, Skin.S(50), Skin.S(22), function()
            SetNormalView('raw')
            P.shownKey = nil
            P:Refresh()
        end, { toggle = true })

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
        -- Optimal: both tile sizes from the texture's pixel width (texscale.lua), one undo step; the line beside it shows the texel density of the present albedo size
        P.optimal = W.Button(group, 'Optimal', 0, 0, Skin.S(70), Skin.S(24), function()
            local l = Selected()
            if not l then return end
            if l.albedo == '' or l.albedo == Strata.CLEAR then Say('This layer has no texture yet') return end
            local TexScale = import('/lua/editor/texscale.lua')
            local opt = TexScale.Optimal(l.albedo)
            Edit('optimal tile size of', function(sel) Strata.SetSizes(sel.index, opt, opt) end)
            Say(string.format('tile size %g for %s', opt, l.file))
        end)
        P.density = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

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
        -- a button text that may be longer than the button (the name of a texture set or shader): cut with "..." to the width of the button
        local function ButtonText(btn, text)
            btn:SetText(text)
            local maxW = btn.Width() - Skin.S(12)
            if btn.label.Width() > maxW then
                W.Fit(btn.label, text, maxW)
                W.Center(btn.label, btn, 0, 0, btn.Width(), btn.Height())
            end
        end
        P.ButtonText = ButtonText
        P.texset = W.Button(group, 'Texture set: ...', 0, 0, Skin.S(220), Skin.S(24), function()
            local TS = import('/lua/editor/texsets.lua')
            local items = {}
            local function SetItem(themeId)
                return { title = TS.Themes[themeId].label, run = function()
                    local n = TS.Apply(themeId)
                    local text = 'texture set ' .. TS.Themes[themeId].label .. ': ' .. n .. ' layers'
                    local style = TS.Themes[themeId].style
                    if style then
                        local Recipes = import('/lua/editor/recipes.lua')
                        for i, pr in Recipes.Presets do
                            if pr.id == style then
                                Recipes.SelectPreset(i)
                                text = text .. '; recipe style ' .. pr.name
                            end
                        end
                    end
                    Say(text)
                    P:Refresh()
                end }
            end
            for _, id in TS.ThemeOrder do table.insert(items, SetItem(id)) end
            if table.getn(TS.MapFamilies) > 0 then
                table.insert(items, { separator = true })
                table.insert(items, { header = true, title = 'Environment sets' })
                for _, fam in TS.MapFamilies do
                    local sub = {}
                    for _, id in fam.ids do table.insert(sub, SetItem(id)) end
                    table.insert(items, { title = fam.label, submenu = sub })
                end
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

        P.convert = W.Button(group, 'Convert layers...', 0, 0, Skin.S(220), Skin.S(24), function()
            import('/lua/editor/gui/shaderbrowser.lua').Open(function(id)
                Say('terrain shader: ' .. id)
                P:Refresh()
            end, { convert = true })
        end, { tip = 'Change the shader and adapt the layers to it in one undo step: paint masks re-encoded where the mask range differs, layer 8 and the Upper layer handled. Opens the shader browser; choose the shader and press Convert layers.' })

        P.maskSize = W.Button(group, 'Paint mask size: ...', 0, 0, Skin.S(220), Skin.S(24), function()
            local w = ed_stratum_info()
            local minW = Strata.MaskLimits()
            if not w or not minW then Say('the map has no paint masks') return end
            local items = {}
            for _, n in Strata.MaskSizes() do
                local size = n
                local note = (size == minW) and '  (half the map, what the shipped exe uses)' or ''
                table.insert(items, { title = size .. ' x ' .. size .. note, checked = (size == w), run = function()
                    local ok, why = Strata.SetMaskSize(size)
                    if ok then
                        Say('paint masks ' .. size .. ' x ' .. size .. (size > minW and ' (the shipped exe shows them at ' .. minW .. '); undo history cleared' or '; undo history cleared'))
                    else
                        Say('paint mask size: ' .. tostring(why))
                    end
                    P:Refresh()
                end })
            end
            Menu.Show(GetFrame(0), P.maskSize.Left(), P.maskSize.Bottom(), items)
        end, { tip = 'The resolution of the paint masks (the eight layer masks, two textures). The shipped exe resamples them to half the map\'s size on load; an exe that keeps the resolution (the FAF Studio engine) draws the finer mask. Bigger is more memory (2048: 32 MB, 4096: 128 MB, 8192: 512 MB) and a finer brush edge. The paint is resampled and the undo history is cleared.' })

        -- A plain shader switch only changes the technique: when the new shader reads a mask byte in another range than the masks were written in (shaders.lua Mismatch), a warning
        -- stands at the top of the panel with a button that opens the Convert layers dialog for the map's shader.
        P.warnParas = {}
        P.warnBtn = W.Button(group, 'Convert masks...', 0, 0, Skin.S(150), Skin.S(24), function()
            local cur = Shaders.Current()
            if not cur then return end
            import('/lua/editor/gui/convertdialog.lua').Open(cur, function(report)
                Say('terrain shader: ' .. cur)
                P:Refresh()
            end)
        end, { tip = 'Open the Convert layers dialog for the shader of the map: the paint masks are re-encoded from the range they were made in to the range this shader reads, so the picture stays the same. One undo step.' })
        local function WarnText()
            local mis = Shaders.Mismatch()
            if not mis then return '' end
            return 'The paint masks are in the ' .. mis.range .. ' range (made for ' .. tostring(mis.shader) .. '), but ' .. tostring(mis.current) .. ' reads the ' .. mis.now ..
                   ' range: the paint looks different. Convert the masks to keep the picture.'
        end

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
                    local size, nsize = l.size, l.nsize
                    if kind == 'albedo' then
                        -- a tile size the user tuned stays; an empty layer or a default size takes the Optimal tile of the new texture (texscale.lua)
                        size, nsize = import('/lua/editor/texscale.lua').Carry(l.albedo, l.size, l.nsize, path)
                        albedo = path
                        normal = ''                 -- SetTexture picks the matching normal map, or the neutral one
                    else
                        normal = path
                    end
                    Strata.SetTexture(l.index, albedo, normal, size, nsize)
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
                ButtonText(P.texset, texsetText)
            end
            local shaderName = import('/lua/editor/shaders.lua').Current() or '?'
            if P.shaderShown ~= shaderName then
                P.shaderShown = shaderName
                ButtonText(P.shader, 'Shader: ' .. shaderName)
            end
            local mw, mh = ed_stratum_info()
            local maskText = mw and ('Paint mask size: ' .. mw .. (mh ~= mw and (' x ' .. mh) or ' x ' .. mw)) or 'Paint mask size: none'
            if P.maskShown ~= maskText then
                P.maskShown = maskText
                ButtonText(P.maskSize, maskText)
            end
            if P.laidOut and WarnText() ~= P.warnShown then
                P:OnResize(P.w, P.h)          -- the warning appeared or went away: the panel lays out again (this ends in a Refresh with the same text)
                return
            end
            local l = Selected()
            -- the preview and the size fields only change when the selected layer or its texture does (a field may be mid-edit)
            local view = NormalView()
            local key = l and (l.index .. '|' .. l.albedo .. '|' .. l.normal .. '|' .. tostring(l.size) .. '|' .. tostring(l.nsize) .. '|' .. view) or view
            P.viewRelief:SetOn(view == 'relief')
            P.viewRaw:SetOn(view == 'raw')
            if key ~= P.shownKey then
                P.shownKey = key
                local pw = P.previewW or Skin.S(72)
                if l and l.albedo ~= '' and l.albedo ~= Strata.CLEAR then
                    P.preview:SetTexture(l.albedo)
                    P.full.albedo = l.file or ''
                    SetCaption(P.cap.albedo, 'Albedo', l.file or '', pw)
                else
                    P.preview:SetSolidColor(Skin.color.panelAlt)
                    P.full.albedo = ''
                    SetCaption(P.cap.albedo, l and 'Albedo: none' or '', '', pw)
                end
                if l and l.normal ~= '' and l.normal ~= Strata.NONE_NORMAL then
                    -- the relief picture is made once per texture and kept (normalpreview.lua); when it cannot be made the texture itself is shown
                    local shown, mode = l.normal, 'Normal'
                    if view == 'relief' then
                        local ok, relief = pcall(function()
                            return import('/lua/editor/normalpreview.lua').Preview(l.normal, { albedo = (l.albedo ~= Strata.CLEAR) and l.albedo or nil })
                        end)
                        if ok and relief then shown, mode = relief, 'Normal relief' end
                    end
                    P.previewNormal:SetTexture(shown)
                    P.full.normal = l.normalFile or ''
                    SetCaption(P.cap.normal, mode, l.normalFile or '', pw)
                else
                    P.previewNormal:SetSolidColor(Skin.color.panelAlt)
                    P.full.normal = ''
                    SetCaption(P.cap.normal, l and 'Normal: none' or '', '', pw)
                end
                P.size:Refresh()
                P.nsize:Refresh()
                -- texel density of the albedo at its tile size (pixel width / tile size) and the Optimal tile for the texture
                local dens = ''
                if l and l.albedo ~= '' and l.albedo ~= Strata.CLEAR then
                    local TexScale = import('/lua/editor/texscale.lua')
                    local px = TexScale.Pixels(l.albedo)
                    if px and l.size and l.size > 0 then
                        dens = string.format('%.0f texels per unit (%d px), optimal %g', px / l.size, px, TexScale.ForPixels(px))
                    end
                end
                P.densityText = dens
                W.Fit(P.density, dens, P.densityW or Skin.S(160))
            end
        end

        --- Lays out everything below the list from `y`: the two pictures with their captions (side by side, or one above the other), the Relief / Raw buttons, the tile sliders, Optimal and
        --- the buttons. `place` false only measures. Returns the y below the last control.
        local function Below(y, w, ps, side, place)
            local pad, lineH = Skin.S(8), Skin.S(15)
            local capH = lineH * 3 + Skin.S(2)
            local function Pic(pic, cap, x, py)
                if place then
                    W.Place(pic, group, x, py, ps, ps)
                    W.Place(cap.head, group, x, py + ps + Skin.S(2))
                    W.Place(cap.l1, group, x, py + ps + Skin.S(2) + lineH)
                    W.Place(cap.l2, group, x, py + ps + Skin.S(2) + 2 * lineH)
                end
                return py + ps + Skin.S(2) + capH
            end
            local y1 = Pic(P.preview, P.cap.albedo, pad, y)
            local y2
            if side then
                y2 = Pic(P.previewNormal, P.cap.normal, 2 * pad + ps, y)
            else
                y2 = Pic(P.previewNormal, P.cap.normal, pad, y1 + Skin.S(4))
            end
            y = math.max(y1, y2) + Skin.S(4)
            -- Relief / Raw: beside their label when there is room, else under it
            local items = { { P.viewRelief, Skin.S(60) }, { P.viewRaw, Skin.S(50) } }
            local bx = pad + P.viewLabel.Width() + Skin.S(8)
            if w - pad - bx >= Skin.S(114) then
                if place then W.Place(P.viewLabel, group, pad, y + Skin.S(4)) end
                y = W.Flow(group, items, bx, y, w - pad - bx, Skin.S(22), Skin.S(4), not place) + Skin.S(8)
            else
                if place then W.Place(P.viewLabel, group, pad, y) end
                y = W.Flow(group, items, pad, y + Skin.S(16), w - 2 * pad, Skin.S(22), Skin.S(4), not place) + Skin.S(8)
            end
            if place then P.size:Place(pad, y, w - 2 * pad) end
            y = y + Skin.S(50)
            if place then P.nsize:Place(pad, y, w - 2 * pad) end
            y = y + Skin.S(54)
            local ow = Skin.S(70)
            if place then
                W.Place(P.optimal, group, pad, y, ow, Skin.S(24))
                W.Center(P.optimal.label, P.optimal, 0, 0, ow, Skin.S(24))
            end
            if w - 2 * pad - ow - Skin.S(8) >= Skin.S(150) then
                if place then
                    P.densityW = w - 2 * pad - ow - Skin.S(8)
                    W.Place(P.density, group, pad + ow + Skin.S(8), y + Skin.S(5))
                end
                y = y + Skin.S(30)
            else
                if place then
                    P.densityW = w - 2 * pad
                    W.Place(P.density, group, pad, y + Skin.S(28))
                end
                y = y + Skin.S(48)
            end
            y = W.Flow(group, { { P.up, P.up.Width() }, { P.down, P.down.Width() }, { P.clearMask, P.clearMask.Width() }, { P.fillMask, P.fillMask.Width() } },
                       pad, y, w - 2 * pad, Skin.S(24), Skin.S(4), not place) + Skin.S(6)
            local sw = math.min(Skin.S(220), w - 2 * pad)
            for _, b in { P.texset, P.shader, P.convert, P.maskSize } do
                if place then
                    W.Place(b, group, pad, y, sw, Skin.S(24))
                    W.Center(b.label, b, 0, 0, sw, Skin.S(24))
                    P.texsetShown, P.shaderShown, P.maskShown = nil, nil, nil         -- the texts are cut to the new width on the next refresh
                end
                y = y + Skin.S(30)
            end
            return y + pad
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            P.laidOut = true
            W.BeginLayout(group)          -- the height of the content is measured anew (it shrinks when the panel gets wider)
            Reload()                      -- the number of layers sets the height the list wants
            local pad = Skin.S(8)
            local rowH = Skin.S(26)
            local top = pad
            for _, l in P.warnParas do l:Destroy() end
            P.warnParas = {}
            P.warnShown = WarnText()
            if P.warnShown ~= '' then
                local labels, endY = W.Paragraph(group, P.warnShown, pad, top, w - 2 * pad, { color = Skin.color.warn, size = 'small' })
                P.warnParas = labels
                W.Place(P.warnBtn, group, pad, endY + Skin.S(4), Skin.S(150), Skin.S(24))
                W.Center(P.warnBtn.label, P.warnBtn, 0, 0, Skin.S(150), Skin.S(24))
                top = endY + Skin.S(36)
            else
                W.Place(P.warnBtn, group, -4000, 0, Skin.S(150), Skin.S(24))
            end
            -- The pictures are as large as the width allows (side by side, or one above the other in a narrow panel), but shrink step by step while the list would not get its ten rows;
            -- what the list is then given is what remains (at least MIN_ROWS rows; below that the panel scrolls, widgets.lua ScrollContent).
            local rows = math.max(1, table.getn(P.rows))
            local wantRows = math.max(MIN_ROWS, rows)
            local avail = h - top - pad - Skin.S(8)
            local side = math.floor((w - 3 * pad) / 2) >= Skin.S(80)
            local maxPs, minPs
            if side then
                maxPs, minPs = math.min(Skin.S(150), math.floor((w - 3 * pad) / 2)), Skin.S(72)
            else
                maxPs, minPs = math.max(Skin.S(48), math.min(Skin.S(130), w - 2 * pad)), Skin.S(64)
            end
            minPs = math.min(minPs, maxPs)
            local ps = maxPs
            while ps > minPs and avail - (Below(0, w, ps, side, false)) < wantRows * rowH do
                ps = math.max(minPs, ps - Skin.S(10))
            end
            local lowerH = Below(0, w, ps, side, false)
            local listH = math.max(MIN_ROWS * rowH, math.min(wantRows * rowH, avail - lowerH))
            P.list:SetRect(pad, top, w - 2 * pad, listH)
            P.previewW = ps
            P.shownKey = nil              -- the file names are cut to the picture width, the density line to its width
            Below(top + listH + Skin.S(8), w, ps, side, true)
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
