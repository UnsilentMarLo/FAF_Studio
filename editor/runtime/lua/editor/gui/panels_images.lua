-- The Images panel: every image-like item of the map in one list, each with a small preview and its Export... / Import... buttons.
--
--   Terrain      height map, terrain type map, preview image (the lobby picture)
--   Masks        the eight texture layer masks (named after the layer's texture)
--   Water        foam, flatness and depth bias masks
--   Map-wide     the map's own textures (normal, lighting, shadow ...) when the editor has them (maptextures.lua, see MapTextures below)
--   Textures     the albedo and normal picture of every layer (game files: shown, not exported)
--
-- Export writes 16-bit PNG (heightio.lua for the height map, the field writer ed_img_write for the masks: the same one the Interop export uses). Import is the editor's existing
-- import: heightio.lua for the height map, interop.lua ApplyMasks for a layer mask; it is not offered in a read-only workspace (Review). Export all... writes every exportable item
-- into one folder as <name>_<item>.png.
--
-- Previews are small (96 px), made one per frame by a thread, never on the 4 Hz tick, and again only when History.Version (or the map) changed. The preview image is rendered on
-- demand (rendering it reads every paint mask into Lua tables, too much to do unasked on a large map).
--
-- MapTextures (optional, written by another part of the editor; absent = no rows): the module '/lua/editor/maptextures.lua' may define Items() -> list of
--   { id = 'normal', label = 'Normal map', info = 'optional text', file = 'normalmap' (file name part for Export all),
--     preview = function(size) -> VFS path of a picture | nil, export = function(path) -> true | false, message, import = function() -> true | false, message (optional) }
-- Every field but id and label is optional. All calls are made inside pcall.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap

live = {}

local THUMB = 96                      -- px of a generated preview
local FILTER = 'PNG image (*.png)|*.png|TIFF image (*.tif)|*.tif;*.tiff|All files|*.*'
local cache = {}                      -- item id -> { key, path } : the last preview and the map state it shows
local worker = false                  -- a preview thread is running

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    LOG('EDITOR images: ' .. text)
end

local function ReadOnly()
    return import('/lua/editor/tools.lua').ReadOnly and true or false
end

local READ_ONLY_WHY = 'Read-only workspace: importing changes the map. Switch to the Terrain workspace to import.'

--- Changes whenever the map or its contents may have changed: previews older than this are made again.
local function MapKey()
    local Map = import('/lua/editor/map.lua')
    local w, h = ed_terrain_info()
    return tostring(History.Version) .. '|' .. tostring(w) .. 'x' .. tostring(h) .. '|' .. tostring(Map.Doc and Map.Doc.scenarioPath)
end

local function MapStem()
    local Map = import('/lua/editor/map.lua')
    local path = Map.Doc and Map.Doc.scenarioPath
    if path then
        local stem = string.gsub(path, '^.*[/\\]', '')
        stem = string.gsub(stem, '_scenario%.lua$', '')
        if stem ~= '' then return stem end
    end
    return 'map'
end

local function Basename(path)
    return (string.gsub(path or '', '^.*[/\\]', ''))
end

-- ---- items ----------------------------------------------------------------------------------------------------------------------------------

--- A preview function for a field: make(S) gives the field inside scope S.
local function FieldPreview(make, opts)
    return function(size)
        local path = Fields.Run(function(S) return (Fields.Preview(make(S), size, opts)) end)
        return path
    end
end

--- An export function for a field written with ed_img_write (bits 16 or 8 over lo..hi).
local function FieldExport(make, bits, lo, hi)
    return function(path)
        if not rawget(_G, 'ed_img_write') then return false, 'this engine build cannot write images' end
        local ok, err = pcall(Fields.Run, function(S)
            local good, why = ed_img_write(path, make(S), { bits = bits, lo = lo, hi = hi })
            if not good then error(tostring(why)) end
        end)
        if not ok then return false, tostring(err) end
        return true
    end
end

local function HeightItem(w, h)
    local step = math.max(1, math.floor((w - 1) / (2 * THUMB)))
    return {
        id = 'height', section = 'Terrain', label = 'Height map', file = 'height',
        info = string.format('%d x %d samples, 16-bit', w, h),
        preview = FieldPreview(function(S) return S:Height(step) end, { ramp = 'terrain' }),
        export = function(path) return import('/lua/editor/heightio.lua').Export(path) end,
        import = function() return import('/lua/editor/heightio.lua').Import() end,
        exportTip = 'Write the whole height field as a 16-bit PNG (world height = value / 128).',
        importTip = 'Replace the whole height field with a 16-bit image (one undo step). More options are in the Interop panel.',
    }
end

local function LayerMaskItem(k, albedoFile, mw, mh)
    local layer = k
    return {
        id = 'mask' .. layer, section = 'Texture layer masks', file = 'layer' .. layer,
        label = 'Layer ' .. layer .. ' mask' .. ((albedoFile and albedoFile ~= '') and ('   ' .. albedoFile) or '   (no texture)'),
        info = mw and string.format('%d x %d cells, 16-bit 0..1', mw, mh) or '',
        preview = FieldPreview(function(S) return S:Stratum(layer) end, { ramp = 'grey', lo = 0, hi = 1 }),
        export = FieldExport(function(S) return S:Stratum(layer) end, 16, 0, 1),
        import = function()
            local Interop = import('/lua/editor/interop.lua')
            if not Interop.Available() then return false, 'the field engine or the image natives are missing' end
            local path = ed_file_dialog(false, 'Import mask for layer ' .. layer, Interop.FILTER, '')
            if not path then return false, 'cancelled' end
            local ms = Interop.DefaultMaskSet()
            ms.sync, ms.takeAway = false, false
            local item = Interop.NewItem(path, 'gray')
            item.target, item.layer = 'layer', layer
            ms.items = { item }
            local ok, out, err = pcall(Interop.ApplyMasks, ms)
            if not ok then return false, tostring(out) end
            if not out then return false, tostring(err) end
            return true, string.format('imported %s into layer %d (%d cells changed)', Basename(path), layer, out.cells or 0)
        end,
        exportTip = 'Write this paint mask as a 16-bit PNG (0 = none, 1 = full).',
        importTip = 'Replace this mask with an image (grey value = how much of the layer). One undo step. More options are in the Interop panel.',
    }
end

local function TypesItem()
    local tw, th = ed_tt_info()
    return {
        id = 'types', section = 'Terrain', label = 'Terrain type map', file = 'terraintypes',
        info = string.format('%d x %d cells, 8-bit type codes', tw, th),
        preview = FieldPreview(function(S) return S:Add(Fields.TerrainTypes()) end, { ramp = 'heat' }),
        export = FieldExport(function(S) return S:Add(Fields.TerrainTypes()) end, 8, 0, 255),
        importWhy = 'Terrain types are imported from the Interop panel (mask list, target "terrain type": a mask paints one type).',
        exportTip = 'Write the terrain type codes as an 8-bit PNG (the value is the type code).',
    }
end

local function WaterItem(kind, w)
    local side = math.floor((w - 1) / 2)
    return {
        id = 'water' .. kind, section = 'Water masks', label = 'Water ' .. Fields.WATER_MASKS[kind], file = 'water_' .. string.gsub(Fields.WATER_MASKS[kind], ' ', ''),
        info = string.format('%d x %d cells, 16-bit 0..1', side, side),
        preview = FieldPreview(function(S) return S:Add(Fields.WaterMask(kind)) end, { ramp = 'grey', lo = 0, hi = 1 }),
        export = FieldExport(function(S) return S:Add(Fields.WaterMask(kind)) end, 16, 0, 1),
        importWhy = 'The editor has no image import for water masks yet. Make them with the Mask generator (Water mask target).',
        exportTip = 'Write this water mask as a 16-bit PNG (0..1).',
    }
end

local function PreviewImageItem()
    return {
        id = 'previewimage', section = 'Terrain', label = 'Preview image', file = 'preview', onDemand = true,
        info = '256 x 256, the picture the lobby shows (rendered from the layers and the sun)',
        preview = function(size)
            local px = import('/lua/editor/preview.lua').Render(size)
            if not px then return nil end
            local out = {}
            local n = table.getn(px)
            for i = 1, n do
                local v = px[i]
                local r = math.floor(v / 65536)
                local g = math.floor((v - r * 65536) / 256)
                local o = (i - 1) * 4
                out[o + 1], out[o + 2], out[o + 3], out[o + 4] = r, g, v - r * 65536 - g * 256, 255
            end
            return Fields.PreviewPixels(out, size, size)
        end,
        export = function(path)
            local ok, why = import('/lua/editor/preview.lua').ExportPng(path, 256)
            return ok and true or false, why
        end,
        importWhy = 'The preview image is made from the map when it is saved; there is nothing to import.',
        exportTip = 'Render the preview image (256 x 256) and write it as a PNG.',
    }
end

local mtFound = nil

--- Does the editor have the map-wide textures module? (looked up once: the file does not appear while the editor runs)
local function HasMapTextures()
    if mtFound == nil then
        mtFound = false
        for _, f in DiskFindFiles('/lua/editor', 'maptextures.lua') or {} do mtFound = true end
    end
    return mtFound
end

--- The rows of the map-wide textures module, when the editor has one.
local function MapTextureItems()
    if not HasMapTextures() then return {} end
    local ok, mod = pcall(import, '/lua/editor/maptextures.lua')
    if not ok or type(mod) ~= 'table' or type(rawget(mod, 'Items')) ~= 'function' then return {} end
    local okList, list = pcall(mod.Items)
    if not okList or type(list) ~= 'table' then return {} end
    local out = {}
    for _, t in list do
        if type(t) == 'table' and t.id and t.label then
            table.insert(out, {
                id = 'map_' .. tostring(t.id), section = 'Map-wide textures', label = tostring(t.label), info = t.info or '', file = t.file or tostring(t.id),
                preview = t.preview, export = t.export, import = t.import,
                importWhy = 'This texture cannot be imported here.',
                exportTip = 'Write this texture as an image file.',
                importTip = 'Replace this texture with an image file.',
            })
        end
    end
    return out
end

--- Everything the panel lists for the open map, in order. Texture rows (kind 'tex') carry the albedo and normal VFS paths.
local function BuildItems()
    local items = {}
    local w, h = ed_terrain_info()
    if not w then return items end
    local Strata = import('/lua/editor/strata.lua')
    table.insert(items, HeightItem(w, h))
    if rawget(_G, 'ed_tt_info') and ed_tt_info() then table.insert(items, TypesItem()) end
    table.insert(items, PreviewImageItem())
    local mw, mh = ed_stratum_info()
    if mw then
        local layers = Strata.Layers()
        for k = 1, 8 do
            local l = layers[k + 1]
            local file = (l and l.albedo ~= '' and l.albedo ~= Strata.CLEAR) and l.file or nil
            table.insert(items, LayerMaskItem(k, file, mw, mh))
        end
    end
    if rawget(_G, 'ed_field_wmask') then
        for kind = 1, 3 do table.insert(items, WaterItem(kind, w)) end
    end
    for _, it in MapTextureItems() do table.insert(items, it) end
    if mw then
        for _, l in Strata.Layers() do
            if l.albedo ~= '' and l.albedo ~= Strata.CLEAR then
                table.insert(items, {
                    id = 'tex' .. l.index, section = 'Layer textures', kind = 'tex', label = l.name .. '   ' .. l.file,
                    info = (l.normal ~= '' and l.normalFile ~= '') and ('normal: ' .. l.normalFile) or 'no normal map',
                    albedo = l.albedo, normal = (l.normal ~= '' and l.normal ~= Strata.NONE_NORMAL) and l.normal or '',
                })
            end
        end
    end
    return items
end

--- Changes when the list of rows must be made again (another map, another texture on a layer, a map-wide texture appeared).
local function Signature()
    local parts = { tostring(ed_terrain_info()), tostring(ed_stratum_info()) }
    for i = 0, 19 do parts[table.getn(parts) + 1] = tostring((ed_stratum_layer(i))) end
    parts[table.getn(parts) + 1] = HasMapTextures() and 'mt' or ''
    parts[table.getn(parts) + 1] = import('/lua/editor/map.lua').Doc and tostring(import('/lua/editor/map.lua').Doc.scenarioPath) or ''
    return table.concat(parts, '|')
end

-- ---- previews: one per frame ------------------------------------------------------------------------------------------------------------------

local function NextStale(P)
    local key = MapKey()
    for _, it in P.items do
        if it.preview and not it.onDemand and not it.kind then
            local c = cache[it.id]
            if not c or c.key ~= key then return it, key end
        end
    end
    return nil
end

local function Render(it, key)
    local ok, path = pcall(it.preview, THUMB)
    cache[it.id] = { key = key, path = ok and path or nil, failed = not (ok and path) }
    if not ok then LOG('EDITOR images: preview of ' .. it.id .. ' failed: ' .. tostring(path)) end
end

--- One step of the preview thread: makes the next stale preview. Returns true while there is more to do.
local function Step()
    local P = live.images
    if not P or P.dead or P.hiddenTab then return false end
    local it, key = NextStale(P)
    if not it then return false end
    Render(it, key)
    P:ShowThumb(it)
    return true
end

local function Pump()
    if worker then return end
    worker = true
    ForkThread(function()
        while true do
            local ok, more = pcall(Step)
            if not ok or not more then break end
            WaitSeconds(0.03)               -- (never inside the pcall)
        end
        worker = false
    end)
end

-- ---- the panel --------------------------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'images', title = 'Images', minW = 240, minH = 160,
    stack = { workspace = 'Review', with = 'view' },
    create = function(group, host)
        local P = { items = {}, ctl = {}, rows = {}, helpLabels = {}, sig = false }
        live.images = P
        local c = Skin.color

        local function Own(control)
            table.insert(P.ctl, control)
            return control
        end

        P.title = Own(W.Label(group, 'Images of the map', 0, 0, { color = c.accent }))
        P.help = 'Every image-like part of the map. Export writes a 16-bit PNG; Import replaces the map data with an image (not in the read-only Review workspace).'
        P.bAll = Own(W.Button(group, 'Export all...', 0, 0, Skin.S(96), Skin.S(24), function() P:ExportAll() end))

        --- Shows the cached preview in the row of `it` (a grey square while there is none).
        function P:ShowThumb(it)
            local row = P.rows[it.id]
            if not row or not row.pic then return end
            local entry = cache[it.id]
            if entry and entry.path then
                row.pic:SetTexture(entry.path)
                if row.note then row.note:SetText('') end
            else
                row.pic:SetSolidColor(c.panelAlt)
                if row.note then row.note:SetText(it.onDemand and (entry == nil and 'not rendered' or 'n/a') or (entry and entry.failed and 'n/a' or '...')) end
            end
        end

        local function Report(it, verb, ok, msg)
            if ok then
                Say(msg and tostring(msg) ~= '' and tostring(msg) or (verb .. ' ' .. it.label))
            else
                Say(verb .. ' ' .. it.label .. ' failed: ' .. tostring(msg or 'see the log'))
            end
        end

        local function ExportOne(it)
            local stem = MapStem()
            local path = ed_file_dialog(true, 'Export ' .. it.label, FILTER, stem .. '_' .. (it.file or it.id) .. '.png')
            if not path then return end
            local ok, ret, msg = pcall(it.export, path)
            if not ok then Report(it, 'export of', false, ret) return end
            Report(it, 'exported', ret and true or false, ret and ('exported ' .. it.label .. ' to ' .. path) or msg)
        end

        local function ImportOne(it)
            if ReadOnly() then Say(READ_ONLY_WHY) return end
            if not it.import then Say(it.importWhy or 'nothing to import here') return end
            local ok, ret, msg = pcall(it.import)
            if not ok then Report(it, 'import of', false, ret) return end
            if ret then
                Say(msg and tostring(msg) or ('imported ' .. it.label))
            elseif msg ~= nil and msg ~= 'cancelled' then
                Report(it, 'import of', false, msg)         -- (no message: the importer said what is wrong, or the dialog was cancelled)
            end
        end

        function P:ExportAll()
            local stem = MapStem()
            local path = ed_file_dialog(true, 'Export all images: choose a folder and a name', FILTER, stem .. '.png')
            if not path then return end
            local _, _, dir, file = string.find(path, '^(.*)[/\\]([^/\\]*)$')
            if not dir then dir, file = '.', path end
            local base = string.gsub(file, '%.[%w]+$', '')
            if base == '' then base = stem end
            local done, failed = 0, {}
            for _, it in P.items do
                if it.export then
                    local target = dir .. '/' .. base .. '_' .. (it.file or it.id) .. '.png'
                    local ok, ret, msg = pcall(it.export, target)
                    if ok and ret then done = done + 1 else table.insert(failed, it.label .. ' (' .. tostring(ok and (msg or 'failed') or ret) .. ')') end
                end
            end
            if table.getn(failed) == 0 then
                Say(string.format('exported %d images to %s as %s_<item>.png', done, dir, base))
            else
                Say(string.format('exported %d images to %s, failed: %s', done, dir, table.concat(failed, '; ')))
            end
        end

        --- Makes the controls of every row. The rows come from BuildItems; their pictures from the cache (or the preview thread).
        function P:Build()
            for id, row in P.rows do
                for _, ctl in { row.pic, row.pic2, row.title, row.info, row.note, row.bExport, row.bImport, row.bRender } do pcall(ctl.Destroy, ctl) end
            end
            for _, l in P.helpLabels do pcall(l.Destroy, l) end
            for _, l in P.heads or {} do pcall(l.Destroy, l) end
            P.rows, P.helpLabels, P.heads = {}, {}, {}
            P.items = BuildItems()
            P.sig = Signature()
            local readOnly = ReadOnly()
            for _, it in P.items do
                local item = it
                local row = {}
                P.rows[item.id] = row
                row.pic = Bitmap(group)
                row.pic.Depth:Set(function() return group.Depth() + 5 end)
                row.pic:SetSolidColor(c.panelAlt)
                row.title = W.Label(group, item.label, 0, 0, { color = c.text })
                row.info = W.Label(group, item.info or '', 0, 0, { color = c.textDim, size = 'small' })
                if item.kind == 'tex' then
                    row.pic.Width:Set(Skin.S(52)) row.pic.Height:Set(Skin.S(52))
                    row.pic:SetTexture(item.albedo)
                    row.pic2 = Bitmap(group)
                    row.pic2.Depth:Set(function() return group.Depth() + 5 end)
                    row.pic2.Width:Set(Skin.S(52)) row.pic2.Height:Set(Skin.S(52))
                    if item.normal ~= '' then row.pic2:SetTexture(item.normal) else row.pic2:SetSolidColor(c.panelAlt) end
                else
                    row.note = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
                    row.bExport = W.Button(group, 'Export...', 0, 0, Skin.S(78), Skin.S(22), function() ExportOne(item) end,
                        { tip = function() return item.export and item.exportTip or 'This item cannot be exported.' end })
                    row.bImport = W.Button(group, 'Import...', 0, 0, Skin.S(78), Skin.S(22), function() ImportOne(item) end,
                        { tip = function()
                            if readOnly then return READ_ONLY_WHY end
                            if not item.import then return item.importWhy end
                            return item.importTip
                        end })
                    if not item.export then row.bExport.label:SetColor(c.textDim) end
                    if readOnly or not item.import then row.bImport.label:SetColor(c.textDim) end
                    if item.onDemand then
                        row.bRender = W.Button(group, 'Render', 0, 0, Skin.S(64), Skin.S(22), function()
                            Render(item, MapKey())
                            P:ShowThumb(item)
                        end, { tip = 'Render the preview image now (it reads every paint mask, so it takes a moment on a large map).' })
                    end
                    P:ShowThumb(item)
                end
            end
            P.heads = {}
            local seen = {}
            for _, it in P.items do
                if not seen[it.section] then
                    seen[it.section] = true
                    P.heads[it.section] = W.Label(group, it.section, 0, 0, { color = c.accent })
                end
            end
        end

        function P:Layout()
            local w = P.w or Skin.S(300)
            local pad = Skin.S(8)
            W.BeginLayout(group)
            local y = pad
            W.Place(P.title, group, pad, y + Skin.S(3))
            W.Place(P.bAll, group, math.max(pad, w - pad - Skin.S(96)), y, Skin.S(96), Skin.S(24))
            y = y + Skin.S(30)
            local labels, below = W.Paragraph(group, P.help, pad, y, math.max(Skin.S(80), w - 2 * pad), { color = c.textDim, size = 'small' }, Skin.S(15))
            for _, l in P.helpLabels do pcall(l.Destroy, l) end
            P.helpLabels = labels
            y = below + Skin.S(6)
            local last = false
            local thumb = Skin.S(72)
            for _, it in P.items do
                local row = P.rows[it.id]
                if it.section ~= last then
                    last = it.section
                    y = y + Skin.S(4)
                    W.Place(P.heads[it.section], group, pad, y)
                    y = y + Skin.S(22)
                end
                if it.kind == 'tex' then
                    local ps = Skin.S(52)
                    W.Place(row.pic, group, pad, y, ps, ps)
                    W.Place(row.pic2, group, pad + ps + Skin.S(4), y, ps, ps)
                    local tx = pad + 2 * ps + Skin.S(12)
                    local tw = math.max(Skin.S(40), w - tx - pad)
                    W.Fit(row.title, it.label, tw)
                    W.Place(row.title, group, tx, y + Skin.S(8))
                    W.Fit(row.info, it.info or '', tw)
                    W.Place(row.info, group, tx, y + Skin.S(28))
                    y = y + ps + Skin.S(6)
                else
                    W.Place(row.pic, group, pad, y, thumb, thumb)
                    local tx = pad + thumb + Skin.S(8)
                    local tw = math.max(Skin.S(40), w - tx - pad)
                    W.Fit(row.title, it.label, tw)
                    W.Place(row.title, group, tx, y)
                    W.Fit(row.info, it.info or '', tw)
                    W.Place(row.info, group, tx, y + Skin.S(20))
                    W.Place(row.note, group, pad + Skin.S(4), y + Skin.S(4))
                    local buttons = { { row.bExport, Skin.S(78) }, { row.bImport, Skin.S(78) } }
                    if row.bRender then table.insert(buttons, { row.bRender, Skin.S(64) }) end
                    local bottom = W.Flow(group, buttons, tx, y + Skin.S(42), tw, Skin.S(22), Skin.S(4))
                    y = math.max(y + thumb, bottom) + Skin.S(8)
                end
            end
            W.EndLayout(group)
        end

        function P:Refresh()
            if not ed_terrain_info() then return end
            local sig = Signature()
            if sig ~= P.sig then
                P:Build()
                if P.w then P:Layout() end
            end
            -- a picture that is rendered on demand is out of date once the map changed: back to the placeholder
            local key = MapKey()
            for _, it in P.items do
                local entry = cache[it.id]
                if it.onDemand and entry and entry.key ~= key then
                    cache[it.id] = nil
                    P:ShowThumb(it)
                end
            end
            if NextStale(P) then Pump() end
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            if not P.sig then P:Build() end
            P:Layout()
            P:Refresh()
        end

        function P:Destroy()
            P.dead = true
            if live.images == P then live.images = nil end
        end

        return P
    end,
}

--- Module level tick (about four times a second): looks for a changed map and starts the preview thread when something is stale.
function Refresh()
    local P = live.images
    if P and not P.dead and P.Refresh then pcall(P.Refresh, P) end
end
