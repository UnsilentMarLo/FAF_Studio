-- The Interop panel: terrain import and export for external tools (Gaea, World Machine, Blender, Photoshop, QGIS), docs/projects/editor/TERRAIN_INTEROP.md.
-- Four pages: Heightmap (file, mapping of the image values to world heights, resampling, orientation, region, blend, pads, thumbnail and height range, Apply as ONE undo step),
-- Masks (a list of image files -> texture layers / terrain types / named masks), Export (heightmap with a sidecar json, masks, markers, README), Live link (watch the files, re-import with
-- the saved settings, revert). Every number is a field + slider + minus / plus. The work is done by interop.lua / interopexport.lua on the native field engine.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Interop = import('/lua/editor/interop.lua')
local Export = import('/lua/editor/interopexport.lua')

live = {}

PAGES = { { 'setup', 'Gaea / WM' }, { 'heightmap', 'Heightmap' }, { 'masks', 'Masks' }, { 'export', 'Export' }, { 'link', 'Live link' } }

--- Module level (the controls come and go).
state = { page = 'setup', status = '', dirty = true, preview = false, previewAt = 0, previewText = '', linkSeen = -1, rebuild = false }

local function Say(text)
    state.status = text
    pcall(function() UI.Say(text) end)
end

local function Clock()
    return rawget(_G, 'ed_field_clock') and ed_field_clock() or 0
end

local function Cycle(list, value, step)
    local n = table.getn(list)
    local at = 1
    for i, v in list do if v == value then at = i end end
    at = math.mod(at - 1 + (step or 1), n) + 1
    return list[at]
end

local function Basename(path)
    return string.gsub(path or '', '^.*[/\\]', '')
end

local GenSym = import('/lua/editor/gensym.lua')
local function SymIds()
    local ids = {}
    for _, ch in GenSym.Choices_ do table.insert(ids, ch.id) end
    return ids
end
local function SymNames()
    local names = {}
    for _, ch in GenSym.Choices_ do names[ch.id] = ch.label end
    return names
end

local function IsRaw(path)
    local ext = string.lower(string.gsub(path or '', '^.*%.', ''))
    return ext == 'raw' or ext == 'r16' or ext == 'r32'
end

-- ---- actions (module level: used by the buttons and by the commands) ---------------------------------------------------------------------------------

--- Chooses the heightmap file: reads its size, takes the range from the json an export of ours left next to it.
local function Later()
    state.rebuild = true
end

function SetFile(path)
    local st = Interop.Settings
    local ext = string.lower(string.gsub(path, '^.*%.', ''))
    if ext == 'exr' then
        Say('EXR cannot be read (Windows has no EXR codec): export the Height as a 16-bit PNG or TIFF, or a 32-bit float TIFF')
        return
    end
    st.file = path
    if ext == 'r32' then st.rawBits, st.rawFloat = 32, true elseif ext == 'r16' or ext == 'raw' then st.rawBits, st.rawFloat = 16, false end
    local text = ''
    local json = Export.JsonFor(path) and Export.ReadJson(Export.JsonFor(path))
    local filled = Export.FillImportFrom(st, json)
    if filled then text = '   ' .. filled end
    local info, err = Interop.Probe(path, st)
    if info then
        Say(string.format('%s: %d x %d, %d bit%s, %s%s', Basename(path), info.width, info.height, info.bits, info.float == 1 and ' float' or '', info.format, text))
    else
        Say('cannot read ' .. Basename(path) .. ': ' .. tostring(err))
    end
    state.dirty = true
    Later()
end

function BrowseFile()
    local path = ed_file_dialog(false, 'Import heightmap', Interop.FILTER, '')
    if path then SetFile(path) end
end

function ApplyHeights()
    local ok, out, err = pcall(Interop.ApplyHeights, Interop.Settings)
    if not ok then Say('import failed: ' .. tostring(out)) return end
    if not out then Say('import failed: ' .. tostring(err)) return end
    local r = out.result
    Say(string.format('imported: %d samples changed, heights %.1f to %.1f (one undo step)', out.changed, r.hLo, r.hHi))
    state.dirty = true
end

--- Re-runs the preview (the thumbnail and the report).
local function RunPreview()
    state.dirty = false
    state.previewAt = Clock()
    local st = Interop.Settings
    if st.file == '' then
        state.preview, state.previewText = false, 'choose a heightmap file'
        return
    end
    local ok, out, err = pcall(Interop.PreviewHeights, st, 128)
    if not ok then state.preview, state.previewText = false, tostring(out)
    elseif not out then state.preview, state.previewText = false, tostring(err)
    else state.preview, state.previewText = out, '' end
end

-- ---- the panel ------------------------------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'interop', title = 'Interop', minW = 280, minH = 200, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = { group = group, dyn = {}, rows = {}, pending = {} }
        live.interop = Pn
        local c = Skin.color

        Pn.pic = Bitmap(group)
        Pn.frame = Bitmap(group)
        Pn.frame:SetSolidColor(c.panelAlt)
        Pn.frame.Depth:Set(function() return group.Depth() + 4 end)
        Pn.pic.Depth:Set(function() return group.Depth() + 6 end)
        Pn.pic:DisableHitTest()
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.tabs = {}
        for _, p in PAGES do
            local id = p[1]
            local b = W.Button(group, p[2], 0, 0, Skin.S(90), Skin.S(22), function() Pn:Flush() state.page = id Later() end)
            table.insert(Pn.tabs, { id = id, button = b })
        end

        local function Track(kind, ctl)
            table.insert(Pn.dyn, { kind = kind, ctl = ctl })
            return ctl
        end
        local function Row(kind, a, b, d)
            table.insert(Pn.rows, { kind = kind, a = a, b = b, c = d })
        end
        --- Text typed into a field counts when the next button is pressed, not only on Enter (typing a folder and pressing Export used to export without a folder).
        function Pn:Flush()
            local list = self.pending
            self.pending = {}
            for _, p in list do p.fn(p.text) end
        end
        local function Btn(text, w, fn, opts)
            return Track('button', W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), function(self) Pn:Flush() fn(self) end, opts))
        end
        local function Lbl(text, opts)
            local l = Track('label', W.Label(group, text, 0, 0, opts or { color = c.textDim, size = 'small' }))
            l.full = text
            return l
        end
        local function Changed()
            state.dirty = true
        end
        local function Sld(label, min, max, step, fmt, get, set, curve)
            return Track('slider', W.Slider(group, { label = label, compact = true, min = min, max = max, step = step, fmt = fmt, curve = curve,
                get = get, set = function(v) set(v) Changed() Pn:Refresh() end }))
        end
        --- A toggle button bound to a boolean.
        local function Tog(text, w, get, set)
            local b = Btn(text, w, function(self) set(self.on) Changed() Later() end, { toggle = true })
            b:SetOn(get() and true or false)
            return b
        end
        --- A button that steps through a list.
        local function Cyc(label, w, list, get, set, names)
            local function Text() local v = get() return label .. ': ' .. tostring(names and names[v] or v) end
            local b
            b = Btn(Text(), w, function() set(Cycle(list, get())) b:SetText(Text()) Changed() Later() end)
            return b
        end
        --- A text field with the label above it; onEnter(text).
        local function Fld(label, text, onEnter)
            local l = Lbl(label)
            local e
            e = W.TextField(group, 0, 0, Skin.S(100), Skin.S(22), {
                text = text,
                onChange = function(t) if t ~= (text or '') then Pn.pending[e] = { text = t, fn = onEnter } else Pn.pending[e] = nil end end,
                onEnter = function(t) Pn.pending[e] = nil onEnter(t) end,
            })
            Track('field', e)
            return l, e
        end

        -- ---- pages ----------------------------------------------------------------------------------------------------------------------------------------

        --- Gaea / World Machine: what to set in the other tool for this map, the typical height, and the send-and-watch loop.
        local function PageSetup()
            local ex = Export.Settings
            local L = Interop.Link
            local mw, mh = ed_terrain_info()
            local n = mw - 1
            local sug, key = Interop.Suggest()
            Row('label', Lbl(string.format('This map: %d x %d units (%.1f km), %d x %d samples (1 sample = 1 unit).', n, mh - 1, n / 51.2, mw, mh), { color = c.text, size = 'small' }))
            Row('label', Lbl(string.format('Gaea: build resolution %d (or %d). Export Height as 16-bit PNG / TIFF or 32-bit float TIFF; masks as greyscale PNG. No EXR.', mw, n)))
            Row('label', Lbl(string.format('World Machine: build size %d x %d, terrain extents %d m wide, output .r16 / 16-bit PNG / 32-bit TIFF; masks as bitmaps.', mw, mh, n)))
            if sug then
                Row('label', Lbl(string.format('Height: your %d maps of this size have a relief of %.0f to %.0f units (median %.0f) and a mean slope of %.1f to %.1f deg (median %.1f). Gaea\'s default heights are',
                    sug.n, sug.relief[2], sug.relief[4], sug.relief[3], sug.slope[2], sug.slope[4], sug.slope[3])))
                Row('label', Lbl('Both tools let you choose the height of the terrain: aim for about the median relief, or set it with the buttons of the Heightmap page.'))
            end
            Row('label', Lbl('Name the files so the editor knows them: flow / river / stream, wear / erosion, deposit / sediment (named masks for the Ground kinds), or the kind of ground (grass, rock ...).'))
            local fl, fe = Fld('Export folder (the other tool reads from it and writes its results into it)', ex.dir, function(text) ex.dir = text Later() end)
            Row('field', fl, fe)
            Row('buttons', {
                Btn('Folder...', 70, function()
                    local d = ed_folder_dialog and ed_folder_dialog('Folder for the other tool')
                    if d then ex.dir = d Later() end
                end),
                Btn('Send and watch', 110, function()
                    local out, err = Interop.SendAndWatch()
                    Say(out and ('sent ' .. table.getn(out.files) .. ' files; watching ' .. ex.dir .. ' (a new heightmap or mask written there comes in by itself)') or ('cannot send: ' .. tostring(err)))
                    Later()
                end),
                Btn(L.enabled and 'Stop watching' or 'Watch only', 100, function()
                    if L.enabled then Interop.LinkStop() else
                        L.mode, L.folder = 'folder', ex.dir
                        if ex.dir == '' then Say('choose the folder first') else Interop.LinkStart() end
                    end
                    Later()
                end),
                Btn('Undo', 44, function() local l = History.Undo() Say(l and ('undid ' .. tostring(l)) or 'nothing to undo') end),
            })
            Row('label', Lbl('Send and watch: exports the map (heightmap, json, masks, start positions, README) and watches the folder. The first other file becomes the heightmap, mask files by their names.'))
            Pn.linkLabels = {}
            for i = 1, 6 do
                local l = Lbl(L.log[i] or '', { color = i == 1 and c.text or c.textDim, size = 'small' })
                Row('label', l)
                table.insert(Pn.linkLabels, l)
            end
        end

        local function PageHeightmap()
            local st = Interop.Settings
            local mw, mh = ed_terrain_info()
            Row('buttons', {
                Btn('Browse...', 70, BrowseFile),
                Btn('Reload', 56, function() Interop.FreeCache() if st.file ~= '' then SetFile(st.file) end end),
                Btn('Apply', 54, function() ApplyHeights() Pn:Refresh() end),
                Btn('Undo', 44, function() local l = History.Undo() Say(l and ('undid ' .. tostring(l)) or 'nothing to undo') state.dirty = true end),
                Btn('Preview', 60, function() RunPreview() Pn:Refresh() end),
            })
            local fl, fe = Fld('Heightmap file (PNG, TIFF 16 bit or 32 bit float, .raw .r16 .r32)', st.file, function(text) if text ~= '' then SetFile(text) end end)
            Row('field', fl, fe)
            local bNorm = Btn('Normalised 0..1', 100, function() st.mode = 'normalised' Changed() Later() end)
            local bAbs = Btn('Absolute', 66, function() st.mode = 'absolute' Changed() Later() end)
            bNorm:SetOn(st.mode == 'normalised')
            bAbs:SetOn(st.mode == 'absolute')
            Row('buttons', {
                bNorm, bAbs,
                Tog('Stretch to image range', 130, function() return st.stretch end, function(v) st.stretch = v end),
                Tog('Invert', 56, function() return st.invert end, function(v) st.invert = v end),
                Tog('Sea level in image', 110, function() return st.anchor end, function(v) st.anchor = v end),
            })
            local sl = {}
            if st.mode == 'normalised' then
                table.insert(sl, Sld(st.anchor and 'Height range, low end (the sea level stays on the water)' or 'Image 0 = height (units)', -50, 520, 0.5, '%.1f',
                    function() return st.min end, function(v) st.min = v end))
                table.insert(sl, Sld('Image 1 = height (units)', -50, 520, 0.5, '%.1f', function() return st.max end, function(v) st.max = v end))
                if st.anchor then
                    table.insert(sl, Sld('Value of the sea level in the image', 0, 1, 0.005, '%.3f', function() return st.sea end, function(v) st.sea = v end))
                end
            end
            Row('sliders', sl)
            if st.mode == 'normalised' then
                local sug = Interop.Suggest()
                if sug and st.file ~= '' then
                    Row('label', Lbl(string.format('Your maps of this size (%d): relief %.0f units (%.0f to %.0f), mean slope %.1f deg. Set Image 1 so the import has the relief of:', sug.n, sug.relief[3], sug.relief[2],
                        sug.relief[4], sug.slope[3])))
                    local function Typical(which, name)
                        local m, relief = Interop.SuggestMax(st, which)
                        if m then
                            st.max = math.floor(m * 2 + 0.5) / 2
                            Say(string.format('Image 1 = %.1f units: a relief of %.0f units, the %s of your maps', st.max, relief, name))
                            Changed()
                            Later()
                        end
                    end
                    Row('buttons', {
                        Btn('A calm map', 90, function() Typical(2, 'lower quartile') end),
                        Btn('The median map', 110, function() Typical(3, 'median') end),
                        Btn('A tall map', 90, function() Typical(4, 'upper quartile') end),
                    })
                end
            end
            Row('buttons', {
                Cyc('Channel', 82, Interop.CHANNELS, function() return st.channel end, function(v) st.channel = v end),
                Cyc('Align', 86, Interop.ALIGNS, function() return st.align end, function(v) st.align = v end),
                Cyc('Filter', 96, Interop.FILTERS, function() return st.filter end, function(v) st.filter = v end),
                Cyc('Rotate', 82, { 0, 90, 180, 270 }, function() return st.rot end, function(v) st.rot = v end),
                Tog('Flip X', 50, function() return st.flipX end, function(v) st.flipX = v end),
                Tog('Flip Z', 50, function() return st.flipZ end, function(v) st.flipZ = v end),
            })
            if IsRaw(st.file) then
                Row('buttons', {
                    Cyc('Raw bits', 90, { 16, 32 }, function() return st.rawBits end, function(v) st.rawBits = v st.rawFloat = (v == 32) end),
                    Tog('Float', 50, function() return st.rawFloat end, function(v) st.rawFloat = v end),
                    Tog('Big endian', 80, function() return st.rawBig end, function(v) st.rawBig = v end),
                })
                Row('sliders', {
                    Sld('Raw width (0 = a square from the file size)', 0, 8192, 1, '%d', function() return st.rawWidth end, function(v) st.rawWidth = v end),
                    Sld('Raw height (0 = a square)', 0, 8192, 1, '%d', function() return st.rawHeight end, function(v) st.rawHeight = v end),
                })
            end
            Row('buttons', {
                Cyc('Region', 140, Interop.REGIONS, function() return st.region end, function(v) st.region = v end, { map = 'whole map', playable = 'playable area', rect = 'rectangle' }),
                Cyc('Blend', 110, Interop.BLENDS, function() return st.blend end, function(v) st.blend = v end, { replace = 'replace', add = 'add', max = 'max', min = 'min', mask = 'by mask' }),
                Cyc('Pads', 90, { 'off', 'keep', 'flatten' }, function() return st.pads end, function(v) st.pads = v end),
                Cyc('Symmetry', 170, SymIds(), function() return st.symmetry or 'off' end, function(v) st.symmetry = v end, SymNames()),
            })
            local sl2 = {}
            if st.region == 'rect' then
                local r = st.rect
                if r[3] <= r[1] or r[4] <= r[2] then r[1], r[2], r[3], r[4] = 0, 0, mw - 1, mh - 1 end
                table.insert(sl2, Sld('Region left (sample)', 0, mw - 1, 1, '%d', function() return r[1] end, function(v) r[1] = v end))
                table.insert(sl2, Sld('Region top (sample)', 0, mh - 1, 1, '%d', function() return r[2] end, function(v) r[2] = v end))
                table.insert(sl2, Sld('Region right (sample)', 0, mw - 1, 1, '%d', function() return r[3] end, function(v) r[3] = v end))
                table.insert(sl2, Sld('Region bottom (sample)', 0, mh - 1, 1, '%d', function() return r[4] end, function(v) r[4] = v end))
            end
            table.insert(sl2, Sld('Strength', 0, 1, 0.01, '%.2f', function() return st.strength end, function(v) st.strength = v end))
            table.insert(sl2, Sld('Feather at the region border (units)', 0, 200, 1, '%d', function() return st.feather end, function(v) st.feather = v end))
            if st.pads ~= 'off' then
                table.insert(sl2, Sld('Pad radius around starts (units; mass points 40%)', 2, 40, 1, '%d', function() return st.padRadius end, function(v) st.padRadius = v end))
            end
            Row('sliders', sl2)
            if st.blend == 'mask' then
                local ml, me = Fld('Mask image (white = take the import)', st.maskFile, function(text) st.maskFile = text Changed() end)
                Row('field', ml, me)
                Row('buttons', { Btn('Browse mask...', 100, function()
                    local p = ed_file_dialog(false, 'Blend mask', Interop.FILTER, '')
                    if p then st.maskFile = p Changed() Later() end
                end) })
            end
            Pn.picLines = {}
            for i = 1, 11 do table.insert(Pn.picLines, Lbl('')) end
            Row('pic')
        end

        local function PageMasks()
            local ms = Interop.MaskSet
            Row('buttons', {
                Btn('Add files...', 80, function()
                    local list = ed_files_dialog and ed_files_dialog('Mask images', Interop.FILTER)
                    if list then
                        local layer = table.getn(ms.items) + 1
                        local told = {}
                        for _, f in list do
                            local item = Interop.NewItem(f)
                            item.layer = math.min(8, layer)
                            layer = layer + 1
                            local guess = Interop.GuessItem(item)       -- flow / wear / deposit, or a kind of ground, from the file name
                            if guess then table.insert(told, Basename(f) .. ': ' .. guess) end
                            table.insert(ms.items, item)
                        end
                        if table.getn(told) > 0 then Say(table.concat(told, '; ')) end
                        Later()
                    end
                end),
                Btn('RGBA splat...', 90, function()
                    local f = ed_file_dialog(false, 'Splat image (R, G, B, A = four layers)', Interop.FILTER, '')
                    if f then
                        for i, ch in { 'r', 'g', 'b', 'a' } do
                            local item = Interop.NewItem(f, ch)
                            item.layer = i
                            table.insert(ms.items, item)
                        end
                        Later()
                    end
                end),
                Btn('Clear list', 70, function() ms.items = {} Later() end),
                Btn('Apply masks', 90, function()
                    local ok, out, err = pcall(Interop.ApplyMasks, ms)
                    if not ok then Say('mask import failed: ' .. tostring(out))
                    elseif not out then Say('mask import failed: ' .. tostring(err))
                    else Say(string.format('masks imported: %d cells, %d layers, %d terrain type grids, %d named (one undo step)', out.cells, out.layers, out.types, out.named)) end
                    Later()
                end),
                Btn('Undo', 44, function() local l = History.Undo() Say(l and ('undid ' .. tostring(l)) or 'nothing to undo') end),
            })
            Row('buttons', {
                Cyc('Write', 100, { 1, 2, 3 }, function() return ms.mode end, function(v) ms.mode = v end, { 'replace', 'add to', 'subtract from' }),
                Tog('Layers above take away', 140, function() return ms.takeAway end, function(v) ms.takeAway = v end),
                Tog('Orientation as heightmap', 150, function() return ms.sync end, function(v) ms.sync = v end),
                Cyc('Symmetry', 170, SymIds(), function() return ms.symmetry or 'off' end, function(v) ms.symmetry = v end, SymNames()),
            })
            Row('sliders', { Sld('Strength', 0, 1, 0.01, '%.2f', function() return ms.strength end, function(v) ms.strength = v end) })
            Row('label', Lbl('Files (a layer is written from the highest down, so each takes away from the ones above): ' .. table.getn(ms.items)))
            for i, item in ms.items do
                local it = item
                local index = i
                Row('label', Lbl(string.format('%d. %s', index, Basename(it.file)), { color = c.text, size = 'small' }))
                local line = {
                    Cyc('Target', 130, { 'layer', 'types', 'named' }, function() return it.target end, function(v) it.target = v end, { layer = 'texture layer', types = 'terrain types', named = 'named mask' }),
                    Cyc('Channel', 82, Interop.CHANNELS, function() return it.channel end, function(v) it.channel = v end),
                    Tog('Invert', 50, function() return it.invert end, function(v) it.invert = v end),
                    Btn('Remove', 56, function() table.remove(ms.items, index) Later() end),
                }
                Row('buttons', line)
                if it.target == 'layer' then
                    Row('sliders', { Sld('Texture layer', 1, 8, 1, '%d', function() return it.layer end, function(v) it.layer = v end) })
                elseif it.target == 'types' then
                    Row('sliders', {
                        Sld('Terrain type code', 0, 40, 1, '%d', function() return it.code end, function(v) it.code = v end),
                        Sld('Where the mask is above', 0, 1, 0.01, '%.2f', function() return it.threshold end, function(v) it.threshold = v end),
                    })
                else
                    local nl, ne = Fld('Name (kept for the mask generator: rule "Imported mask")', it.name, function(text) it.name = text end)
                    Row('field', nl, ne)
                end
            end
            if table.getn(Interop.Named) > 0 then
                Row('label', Lbl('Named masks (slot = the number the mask generator rule asks for):'))
                for i, n in Interop.Named do
                    local index = i
                    Row('label', Lbl(string.format('slot %d: %s  <-  %s (%s)', index, n.name, Basename(n.file), n.channel), { color = c.text, size = 'small' }))
                    Row('buttons', { Btn('Forget', 56, function() Interop.RemoveNamed(index) Later() end) })
                end
            end
        end

        local function PageExport()
            local ex = Export.Settings
            Row('buttons', {
                Btn('Folder...', 70, function()
                    local d = ed_folder_dialog and ed_folder_dialog('Export folder')
                    if d then ex.dir = d Later() end
                end),
                Btn('Export', 66, function()
                    local out, err = Export.Export(ex)
                    Say(out and out.text or ('export failed: ' .. tostring(err)))
                    Later()
                end),
            })
            local fl, fe = Fld('Export folder', ex.dir, function(text) ex.dir = text Later() end)
            Row('field', fl, fe)
            local nl, ne = Fld('File name (empty = the map name)', ex.name, function(text) ex.name = text Later() end)
            Row('field', nl, ne)
            Row('buttons', {
                Cyc('Values', 150, { 'normalised', 'absolute' }, function() return ex.mode end, function(v) ex.mode = v end, { normalised = 'normalised 0..1', absolute = 'absolute' }),
                Cyc('Format', 86, { 'png', 'tif', 'raw' }, function() return ex.format end, function(v) ex.format = v end),
                Cyc('Bits', 70, { 16, 32 }, function() return ex.bits end, function(v) ex.bits = v end, { [16] = '16', [32] = '32 float' }),
                Cyc('Mask bits', 90, { 8, 16 }, function() return ex.maskBits end, function(v) ex.maskBits = v end),
            })
            local sl = {}
            Row('buttons', { Tog('Fixed range instead of the map\'s own', 210, function() return ex.fixed end, function(v) ex.fixed = v end) })
            if ex.fixed then
                table.insert(sl, Sld('Range low end (units)', -50, 520, 0.5, '%.1f', function() return ex.lo end, function(v) ex.lo = v end))
                table.insert(sl, Sld('Range high end (units)', -50, 520, 0.5, '%.1f', function() return ex.hi end, function(v) ex.hi = v end))
            end
            table.insert(sl, Sld('Water mask soft edge (units)', 0, 20, 0.5, '%.1f', function() return ex.waterSoft end, function(v) ex.waterSoft = v end))
            table.insert(sl, Sld('Marker disc radius (samples)', 0, 20, 1, '%d', function() return ex.markerRadius end, function(v) ex.markerRadius = v end))
            Row('sliders', sl)
            local items = {}
            for _, k in { 'height', 'water', 'slope', 'flow', 'wear', 'layers', 'types', 'markers', 'playable', 'readme' } do
                local key = k
                table.insert(items, Tog(key, 74, function() return ex.items[key] end, function(v) ex.items[key] = v end))
            end
            Row('buttons', items)
            Row('label', Lbl('Files that will be written:'))
            for _, p in Export.Plan(ex) do
                Row('label', Lbl(Basename(p.file) .. '   ' .. p.what, { color = c.textDim, size = 'small' }))
            end
        end

        local function PageLink()
            local L = Interop.Link
            Row('buttons', {
                Btn(L.enabled and 'Stop watching' or 'Start watching', 110, function()
                    if L.enabled then Interop.LinkStop() else Interop.LinkStart() end
                    Later()
                end),
                Btn('Revert last', 76, function() Interop.LinkRevert() Pn:Refresh() end),
                Btn('Import now', 80, function()
                    ApplyHeights()
                    Pn:Refresh()
                end),
            })
            Row('buttons', {
                Cyc('Watch', 230, { 'file', 'folder' }, function() return L.mode end, function(v) L.mode = v end, { file = 'the files of the import', folder = 'every image of a folder' }),
                Tog('Heightmap', 80, function() return L.apply.heights end, function(v) L.apply.heights = v end),
                Tog('Masks', 56, function() return L.apply.masks end, function(v) L.apply.masks = v end),
            })
            if L.mode == 'folder' then
                local fl, fe = Fld('Folder to watch (the heightmap and the mask files of the lists in it are imported when they change)', L.folder, function(text) L.folder = text Later() end)
                Row('field', fl, fe)
                Row('buttons', { Btn('Folder...', 70, function()
                    local d = ed_folder_dialog and ed_folder_dialog('Folder to watch')
                    if d then L.folder = d Later() end
                end) })
            end
            Row('sliders', { Sld('Look every (seconds)', 0.25, 10, 0.25, '%.2f', function() return L.interval end, function(v) L.interval = v end) })
            Pn.linkLabels = {}
            Row('label', Lbl('Uses the settings of the Heightmap and Masks pages. A change is imported when the file has stopped changing.'))
            Row('label', Lbl('The previous live import is replaced, so one Undo (or Revert last) takes all of it back.'))
            for i = 1, 8 do
                local l = Lbl(L.log[i] or '', { color = i == 1 and c.text or c.textDim, size = 'small' })
                Row('label', l)
                table.insert(Pn.linkLabels, l)
            end
        end

        -- ---- build / layout ----------------------------------------------------------------------------------------------------------------------

        function Pn:Kill()
            for _, d in self.dyn do
                if d.kind == 'slider' then
                    for _, part in { d.ctl.label, d.ctl.track, d.ctl.fill, d.ctl.thumb, d.ctl.minus, d.ctl.plus } do part:Destroy() end
                    d.ctl.field:Destroy()
                    if d.ctl.field.frame then d.ctl.field.frame:Destroy() end
                elseif d.kind == 'field' then
                    -- the edit first, then its frame: destroying the frame destroys the edit with it, and a second Destroy of the edit raised in its OnDestroy
                    local frame = d.ctl.frame
                    d.ctl:Destroy()
                    if frame then frame:Destroy() end
                else
                    d.ctl:Destroy()
                end
            end
            self.dyn, self.rows, self.picLines, self.linkLabels, self.pending = {}, {}, nil, nil, {}
        end

        function Pn:Rebuild()
            self:Kill()
            local ok, err = pcall(function()
                if state.page == 'setup' then PageSetup()
                elseif state.page == 'heightmap' then PageHeightmap()
                elseif state.page == 'masks' then PageMasks()
                elseif state.page == 'export' then PageExport()
                else PageLink() end
            end)
            if not ok then Say('panel error: ' .. tostring(err)) end
            self:OnResize(self.w, self.h)
        end

        function Pn:Refresh()
            local st = Interop.Settings
            W.Fit(self.status, state.status, (self.w or 300) - Skin.S(16))
            for _, d in self.dyn do
                if d.kind == 'slider' then d.ctl:Refresh() end
            end
            for _, t in self.tabs do t.button:SetOn(t.id == state.page) end
            if self.linkLabels then
                for i, l in self.linkLabels do
                    l.full = Interop.Link.log[i] or ''
                    W.Fit(l, l.full, (self.w or 300) - Skin.S(16))
                end
            end
            if state.page == 'heightmap' then
                local p = state.preview
                if p and p.path then
                    self.pic:SetTexture(p.path)
                    self.pic:Show()
                else
                    self.pic:Hide()
                end
                if self.picLines then
                    local lines = {}
                    if p then
                        table.insert(lines, string.format('image %d x %d  ->  %d x %d samples (%s alignment, %s)', p.imageW or 0, p.imageH or 0, p.region[3] - p.region[1] + 1, p.region[4] - p.region[2] + 1,
                            p.align, st.filter))
                        table.insert(lines, string.format('image values %.4g to %.4g', p.srcLo, p.srcHi))
                        table.insert(lines, string.format('result heights %.1f to %.1f units', p.hLo, p.hHi))
                        if p.advice then table.insert(lines, p.advice) end
                        for _, wtext in p.warnings do table.insert(lines, 'WARNING: ' .. wtext) end
                    else
                        table.insert(lines, state.previewText ~= '' and state.previewText or 'no preview yet')
                    end
                    for i, l in self.picLines do
                        l:SetText('')
                        if lines[i] then
                            W.Fit(l, lines[i], math.max(Skin.S(80), (self.w or 300) - Skin.S(160)))
                            l:SetColor(string.find(lines[i], 'WARNING', 1, true) and c.warn or c.textDim)
                        end
                    end
                end
            end
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            W.BeginLayout(group)
            -- tabs
            local x = pad
            local tabW = Skin.S(90)
            -- the tabs wrap when the panel is narrower than the row (a tab past the panel's edge was drawn over the panel beside it)
            local perRow = math.max(1, math.floor((w - 2 * pad + Skin.S(4)) / (tabW + Skin.S(4))))
            local n = 0
            for _, t in self.tabs do
                if n > 0 and math.mod(n, perRow) == 0 then
                    x = pad
                    y = y + Skin.S(26)
                end
                W.Place(t.button, group, x, y, tabW, Skin.S(22))
                x = x + tabW + Skin.S(4)
                n = n + 1
            end
            y = y + Skin.S(28)
            self.pic:Hide()
            W.Place(self.frame, group, -20000, 0, 1, 1)
            for _, row in self.rows do
                if row.kind == 'buttons' then
                    local bx = pad
                    for _, b in row.a do
                        local bw = b.Width()
                        if bx > pad and bx + bw > w - pad then
                            bx = pad
                            y = y + Skin.S(26)
                        end
                        W.Place(b, group, bx, y, bw, Skin.S(22))
                        bx = bx + bw + Skin.S(4)
                    end
                    y = y + Skin.S(28)
                elseif row.kind == 'sliders' then
                    local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(190) + pad)))
                    local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
                    local i = 0
                    local rows = 0
                    for _, sl in row.a do
                        sl:Place(pad + math.mod(i, cols) * (colW + pad), y + math.floor(i / cols) * Skin.S(46), colW)
                        rows = math.floor(i / cols) + 1
                        i = i + 1
                    end
                    y = y + rows * Skin.S(46) + Skin.S(2)
                elseif row.kind == 'label' then
                    W.Fit(row.a, row.a.full or '', w - 2 * pad)
                    W.Place(row.a, group, pad, y)
                    y = y + Skin.S(16)
                elseif row.kind == 'field' then
                    W.Place(row.a, group, pad, y)
                    y = y + Skin.S(16)
                    local fw = w - 2 * pad
                    W.Place(row.b.frame, group, pad, y, fw, Skin.S(22))
                    row.b.Width:Set(fw - 2)
                    y = y + Skin.S(28)
                elseif row.kind == 'pic' then
                    local size = Skin.S(128)
                    W.Place(self.frame, group, pad, y, size, size)
                    W.Place(self.pic, group, pad, y, size, size)
                    for i, l in self.picLines do
                        W.Place(l, group, size + 2 * pad, y + (i - 1) * Skin.S(16))
                    end
                    y = y + math.max(size, table.getn(self.picLines) * Skin.S(16)) + Skin.S(6)
                end
            end
            W.Place(self.status, group, pad, y)
            y = y + Skin.S(18)
            W.EndLayout(group)
            self:Refresh()
        end

        function Pn:Destroy()
            live.interop = nil
        end

        Pn:Rebuild()
        return Pn
    end,
}

--- Ticked by the shell about four times a second (also while the panel is closed): the live link looks at its files, a changed setting re-runs the preview.
function Refresh()
    if Interop.Available() then
        local ok, err = pcall(Interop.LinkPoll)
        if not ok then LOG('EDITOR interop link poll failed: ' .. tostring(err)) end
    end
    local P = live.interop
    if P and state.rebuild then
        state.rebuild = false
        P:Rebuild()
    end
    if P and state.page == 'heightmap' and state.dirty and Clock() - state.previewAt > 0.3 then
        RunPreview()
        P:Refresh()
    end
    if P and (state.page == 'link' or state.page == 'setup') and state.linkSeen ~= Interop.Revision then
        state.linkSeen = Interop.Revision
        P:Refresh()
    end
end

--- Frees what the module holds natively (a module reload or leaving the editor).
function Release()
    Interop.Release()
end
