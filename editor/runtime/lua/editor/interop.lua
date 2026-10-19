-- Terrain interop with external tools (Gaea, World Machine, Blender, Photoshop, QGIS): docs/projects/editor/TERRAIN_INTEROP.md, docs/projects/editor/TERRAIN_GEN_DESIGN.md section 13.
-- Heightmaps and masks come in through the native image reader (ed_img_read: PNG, TIFF 8 / 16 / 32 bit float, raw .raw .r16 .r32, whatever Windows can decode) as float fields and are
-- fitted onto the map's N+1 sample grid by the native resampler (img_resample); nothing here loops over pixels in Lua. Export is interopexport.lua.
--
--   Settings                 the heightmap import settings (also in the sidecar `_editor.lua` as Interop.import): file, mapping (normalised min / max or absolute), resampling, orientation, region, blend
--   MaskSet                  the mask import settings: a list of files, each to a texture layer, the terrain-type grid or a named mask
--   Probe(path[, st])        -> info | nil, message         the file's size, bits per channel, float, format
--   BuildHeights(S, st)      -> result | nil, message       the new heights as a field (full map, in scope S) and what the import will do; nothing is written
--   PreviewHeights(st)       -> { path, lo, hi, ... } | nil, message     the thumbnail and the height range
--   ApplyHeights(st[, opts]) -> { changed, entry, result } | nil, message       writes the heights: ONE undo step
--   ApplyMasks(ms)           -> { cells, parts } | nil, message               writes every item of the mask set: ONE undo step
--   Named / NamedField(S, slot, like)    imported masks kept for the mask generator (rule 'Imported mask')
--   Link                     the live link: Poll() applies a changed file with the saved settings as one undo step, Revert() takes it back
--   SidecarText() / LoadSidecar(file) / Reset()      settings travel with the map
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Ser = import('/lua/editor/luaser.lua')

EXTS = 'png;tif;tiff;raw;r16;r32;bmp;jpg;jpeg'
FILTER = 'Heightmaps and masks (*.png;*.tif;*.tiff;*.raw;*.r16;*.r32)|*.png;*.tif;*.tiff;*.raw;*.r16;*.r32;*.bmp;*.jpg|All files|*.*'
DECAL_LIMIT = 250          -- the editor's decal height limit (docs/projects/editor/MAP_EDITOR_DESIGN.md): decals above it are not drawn
WORD_MAX = 65535 / 128     -- the highest height a 16-bit word holds (511.9921875)

FILTERS = { 'bilinear', 'bicubic', 'lanczos', 'nearest' }
ALIGNS = { 'auto', 'cell', 'corner' }
BLENDS = { 'replace', 'add', 'max', 'min', 'mask' }
REGIONS = { 'map', 'playable', 'rect' }
CHANNELS = { 'gray', 'r', 'g', 'b', 'a' }

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    LOG('EDITOR interop: ' .. text)
end

function Available()
    return rawget(_G, 'ed_img_read') ~= nil and Fields.IsAvailable() and ed_terrain_info() ~= nil
end

-- ---- settings ---------------------------------------------------------------------------------------------------------------------------------------

function DefaultSettings()
    return {
        file = '', channel = 'gray', nodata = false,
        rawBits = 16, rawFloat = false, rawBig = false, rawWidth = 0, rawHeight = 0,
        mode = 'normalised',          -- 'normalised' (0..1 of the image -> min..max world units) | 'absolute' (16-bit word / 128, a float image: the value in world units)
        min = 0, max = 100,
        stretch = false,              -- first stretch the image's own lowest..highest value to 0..1 (an export that was not normalised)
        anchor = false, sea = 0.2,    -- the image value `sea` lands on the map's water surface (min is then derived)
        align = 'auto', filter = 'bicubic',
        flipX = false, flipZ = false, rot = 0, invert = false,
        region = 'map', rect = { 0, 0, 0, 0 },
        blend = 'replace', strength = 1, feather = 0, maskFile = '',
        pads = 'off', padRadius = 8,  -- 'off' | 'keep' (the terrain at start positions / mass points stays) | 'flatten' (the new terrain is levelled there)
    }
end

Settings = DefaultSettings()

function DefaultMaskSet()
    return {
        items = {},                   -- { file, channel, target = 'layer' | 'types' | 'named', layer, code, threshold, name, invert }
        mode = 1, strength = 1, takeAway = true,
        sync = true,                  -- orientation, alignment and filter follow the heightmap settings
        flipX = false, flipZ = false, rot = 0, align = 'auto', filter = 'bilinear',
    }
end

MaskSet = DefaultMaskSet()

Named = {}                            -- { { name, file, channel, flipX, flipZ, rot, invert }, ... } the masks kept for the mask generator
Revision = 0                          -- bumped by changes the panel should show

function NewItem(file, channel)
    return { file = file or '', channel = channel or 'gray', target = 'layer', layer = 1, code = 2, threshold = 0.5, name = '', invert = false }
end

-- ---- reading images (cached) -----------------------------------------------------------------------------------------------------------------------

local Cache = { key = false, field = false, info = false }

local function RawOptions(st)
    return { bits = st.rawBits or 16, float = (st.rawFloat or (st.rawBits or 16) == 32) and 1 or 0, big = st.rawBig and 1 or 0, width = st.rawWidth or 0, height = st.rawHeight or 0 }
end

local function ReadOptions(st, channel)
    local o = RawOptions(st)
    o.channel = channel or st.channel or 'gray'
    if st.nodata then o.nodata = st.nodata end
    return o
end

--- The file's size and format (raw files with the raw options of `st`).
function Probe(path, st)
    if not path or path == '' then return nil, 'no file' end
    if not rawget(_G, 'ed_img_info') then return nil, 'this engine build has no ed_img_info (rebuild with EdInteropLua.cpp)' end
    return ed_img_info(path, RawOptions(st or Settings))
end

local function Stamp(path)
    return ed_file_stamp(path) or 'missing'
end

--- Reads an image into a field the cache owns (do not free it). `channel` overrides the settings' channel.
function LoadSource(path, st, channel)
    if not path or path == '' then return nil, 'no file chosen' end
    local o = ReadOptions(st, channel)
    local key = string.format('%s|%s|%s|%d|%d|%d|%d|%d|%s', path, Stamp(path), o.channel, o.bits, o.float, o.big, o.width, o.height, tostring(o.nodata or ''))
    if Cache.key == key and Cache.field then return Cache.field, Cache.info end
    FreeCache()
    local f, info = ed_img_read(path, o)
    if not f then return nil, tostring(info) end
    Cache.key, Cache.field, Cache.info = key, f, info
    return f, info
end

function FreeCache()
    if Cache.field then Fields.Free(Cache.field) end
    Cache.key, Cache.field, Cache.info = false, false, false
end

--- A mask image read straight into the caller's scope (kept apart from the heightmap cache: masks and the heightmap are often read in turn).
local function ReadScoped(S, path, st, channel)
    local f, info = ed_img_read(path, ReadOptions(st, channel))
    if not f then return nil, tostring(info) end
    S:Add(f)
    return f, info
end

-- ---- orientation and region -------------------------------------------------------------------------------------------------------------------------

--- transpose, flip_x, flip_z of the field op for a rotation (0, 90 clockwise, 180, 270) followed by the flips.
local function Orientation(o)
    local rot = math.mod(math.floor((o.rot or 0) / 90 + 0.5), 4)
    if rot < 0 then rot = rot + 4 end
    local t, fx, fz = 0, false, false
    if rot == 1 then t, fx = 1, true
    elseif rot == 2 then fx, fz = true, true
    elseif rot == 3 then t, fz = 1, true end
    if o.flipX then fx = not fx end
    if o.flipZ then fz = not fz end
    return t, fx, fz
end

local function Oriented(S, f, o)
    local t, fx, fz = Orientation(o)
    if t == 0 and not fx and not fz then return f end
    return S:Op('img_orient', { a = f, transpose = t, flip_x = fx and 1 or 0, flip_z = fz and 1 or 0 })
end

--- The sample rectangle the import covers: x0, z0, x1, z1 (inclusive sample indices).
function Region(st)
    local mw, mh = ed_terrain_info()
    local x0, z0, x1, z1 = 0, 0, mw - 1, mh - 1
    if st.region == 'playable' then
        x0, z0, x1, z1 = import('/lua/editor/playable.lua').Get()
    elseif st.region == 'rect' then
        local r = st.rect or { 0, 0, 0, 0 }
        if r[3] > r[1] and r[4] > r[2] then x0, z0, x1, z1 = r[1], r[2], r[3], r[4] end
    end
    x0, z0 = math.max(0, math.floor(math.min(x0, x1) + 0.5)), math.max(0, math.floor(math.min(z0, z1) + 0.5))
    x1, z1 = math.min(mw - 1, math.floor(math.max(x0, x1) + 0.5)), math.min(mh - 1, math.floor(math.max(z0, z1) + 0.5))
    return x0, z0, x1, z1
end

--- 'corner' when the image is exactly the region's samples (a 1025 image over 1024 cells), else 'cell' (the image covers the cells: 1024 over 1024).
function AlignFor(st, iw, ih, x0, z0, x1, z1)
    if st.align == 'cell' or st.align == 'corner' then return st.align end
    if iw == x1 - x0 + 1 and ih == z1 - z0 + 1 then return 'corner' end
    return 'cell'
end

-- ---- markers (pads) -------------------------------------------------------------------------------------------------------------------------------

--- The start positions, mass points and hydrocarbon deposits as { x, z, radius, 1 } quadruples (a flat list for points_mask) and the count.
function PadPoints(radius)
    local Map = import('/lua/editor/map.lua')
    local pts, n = {}, 0
    if not Map.Doc then return pts, 0 end
    local list = {}
    for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        local r = nil
        if string.find(name, '^ARMY_%d+$') then r = radius
        elseif m.type == 'Mass' or m.type == 'Hydrocarbon' then r = math.max(2, radius * 0.4) end
        if r and m.position then table.insert(list, { name = name, x = m.position[1], z = m.position[3], r = r }) end
    end
    table.sort(list, function(a, b) return a.name < b.name end)       -- a fixed order: the result must not depend on table iteration
    for _, p in list do
        table.insert(pts, p.x) table.insert(pts, p.z) table.insert(pts, p.r) table.insert(pts, 1)
        n = n + 1
    end
    return pts, n
end

-- ---- the height pipeline ----------------------------------------------------------------------------------------------------------------------------

local function Lo(a, b) if a < b then return a end return b end

--- The affine map from image values to world heights: slope k, intercept c (h = v * k + c), and the height range of an image whose values span lo..hi.
local function Mapping(st, info, lo, hi, water)
    local k, c
    if st.mode == 'absolute' then
        local scale = (info and info.float == 1) and 1 or WORD_MAX / 1         -- a 16-bit image: word / 128 where the file value 1.0 is word 65535
        k, c = scale, 0
        if st.invert then k, c = -scale, scale * (lo + hi) end
    else
        local range = st.max - st.min
        local lo0, r0 = 0, 1
        if st.stretch and hi - lo > 1e-12 then lo0, r0 = lo, hi - lo end
        local base = st.min
        if st.anchor then base = water - st.sea * range end
        if st.invert then
            k = -range / r0
            c = base + range * (1 + lo0 / r0)
        else
            k = range / r0
            c = base - range * lo0 / r0
        end
    end
    local h1, h2 = lo * k + c, hi * k + c
    return k, c, Lo(h1, h2), (h1 > h2) and h1 or h2
end

--- The new heights for settings `st` as a full-map field (owned by S) and a report. Nothing is written.
--- result = { final (the heights after the blend), imported (the mapped image on the map grid), region = {x0, z0, x1, z1}, info, srcLo, srcHi, hLo, hHi, align, warnings = { text, ... } }
function BuildHeights(S, st)
    if not Available() then return nil, 'the field engine or the image natives are missing' end
    local src, info = LoadSource(st.file, st)
    if not src then return nil, info end
    local warnings = {}
    local mw, mh = ed_terrain_info()
    local x0, z0, x1, z1 = Region(st)
    if x1 - x0 < 8 or z1 - z0 < 8 then return nil, 'the region is too small' end
    local srcLo, srcHi = Fields.Stats(src)
    local world = import('/lua/editor/world.lua').Get()
    local water = world.water_elev or 0
    local k, c, hLo, hHi = Mapping(st, info, srcLo, srcHi, water)

    local oriented = Oriented(S, src, st)
    local iw, ih = Fields.Info(oriented)
    local align = AlignFor(st, iw, ih, x0, z0, x1, z1)
    local cur = S:Height(1)
    local fitted = S:Op('img_resample', { a = oriented, like = cur, x0 = x0, z0 = z0, x1 = x1, z1 = z1, align = align, filter = st.filter or 'bicubic', outside = 0 })
    local mapped = S:Op('affine', { a = fitted, mul = k, add = c })

    -- the blend weight: the region (feathered at the borders that are not the map's border), the strength, an optional mask image, the pads
    local m = S:Op('rect_mask', { like = cur, x0 = x0, z0 = z0, x1 = x1, z1 = z1, feather = st.feather or 0,
                                  feather_l = x0 > 0 and 1 or 0, feather_r = x1 < mw - 1 and 1 or 0, feather_t = z0 > 0 and 1 or 0, feather_b = z1 < mh - 1 and 1 or 0 })
    if st.blend == 'mask' then
        if st.maskFile == '' then return nil, 'blend by mask needs a mask image' end
        local mf, minfo = ReadScoped(S, st.maskFile, st, 'gray')
        if not mf then return nil, 'mask image: ' .. tostring(minfo) end
        local mo = Oriented(S, mf, st)
        local mw2, mh2 = Fields.Info(mo)
        local mr = S:Op('img_resample', { a = mo, like = cur, x0 = x0, z0 = z0, x1 = x1, z1 = z1, align = AlignFor(st, mw2, mh2, x0, z0, x1, z1), filter = 'bilinear', outside = 0 })
        m = S:Op('mul', { a = m, b = S:Op('clamp', { a = mr, lo = 0, hi = 1 }) })
    end
    if (st.strength or 1) < 0.9999 then m = S:Op('affine', { a = m, mul = st.strength, add = 0 }) end
    local padPts, padCount = {}, 0
    if st.pads ~= 'off' then
        padPts, padCount = PadPoints(st.padRadius or 8)
        if padCount > 0 and st.pads == 'keep' then
            local pm = S:Op('points_mask', { like = cur, pts = padPts, feather = st.padRadius or 8 })
            m = S:Op('mul', { a = m, b = S:Op('invert', { a = pm, lo = 0, hi = 1 }) })
        end
    end
    local mode = st.blend == 'add' and 'add' or (st.blend == 'max' and 'max' or (st.blend == 'min' and 'min' or 'normal'))
    local final = S:Op('blend', { a = cur, b = mapped, mask = m, mode = mode, opacity = 1 })

    if padCount > 0 and st.pads == 'flatten' then
        local r = st.padRadius or 8
        local n = math.min(padCount, 120)
        for i = 1, n do
            local px, pz = padPts[(i - 1) * 4 + 1], padPts[(i - 1) * 4 + 2]
            local h = Fields.Sample(final, px, pz)
            final = S:Op('blend', { a = final, b = S:Op('const', { like = cur, value = h }),
                                    mask = S:Op('points_mask', { like = cur, pts = { px, pz, padPts[(i - 1) * 4 + 3], 1 }, feather = r }), mode = 'normal' })
        end
    end

    -- facts for the dialog
    local region = S:Op('crop', { a = mapped, x0 = x0, z0 = z0, x1 = x1, z1 = z1 })
    local rLo, rHi = Fields.Stats(region)
    if rHi > DECAL_LIMIT then
        table.insert(warnings, string.format('the highest point is %.0f units: decals are not drawn above %d (the editor limit)', rHi, DECAL_LIMIT))
    end
    if rHi > WORD_MAX + 0.01 then
        table.insert(warnings, string.format('%.0f is above %.2f, the highest height a 16-bit word holds: the top is cut off', rHi, WORD_MAX))
    end
    if rLo < -0.01 then
        table.insert(warnings, string.format('the lowest point is %.1f units: heights below 0 are cut off (the map holds 0 to %.0f)', rLo, WORD_MAX))
    end
    if st.mode == 'normalised' and info.float == 1 and (srcLo < -0.001 or srcHi > 1.001) and not st.stretch then
        table.insert(warnings, string.format('the float image holds %.3f to %.3f, not 0 to 1: use "stretch" or the absolute mode', srcLo, srcHi))
    end
    if info.bits == 8 and info.float ~= 1 then
        table.insert(warnings, '8-bit image: only 256 height levels, the slopes will be terraced (export 16 bit)')
    end
    if info.nodata and info.nodata > 0 then
        table.insert(warnings, info.nodata .. ' samples without data were set to the lowest value')
    end
    if info.container == 'jpeg' then table.insert(warnings, 'JPEG is lossy: blocky heights (export PNG or TIFF)') end
    if padCount == 0 and st.pads ~= 'off' then table.insert(warnings, 'no start positions or resource markers to protect') end
    if (iw ~= x1 - x0 + 1 or ih ~= z1 - z0 + 1) and align == 'corner' then
        table.insert(warnings, string.format('%dx%d image fitted corner to corner onto %dx%d samples', iw, ih, x1 - x0 + 1, z1 - z0 + 1))
    end
    return { final = final, imported = mapped, region = { x0, z0, x1, z1 }, regionField = region, info = info, srcLo = srcLo, srcHi = srcHi, hLo = rLo, hHi = rHi,
             align = align, imageW = iw, imageH = ih, warnings = warnings, pads = padCount }
end

--- The thumbnail of what the import brings (the mapped image over the region) and its numbers. Returns a table { path, lo, hi, report } or nil, message.
function PreviewHeights(st, size)
    return Fields.Run(function(S)
        local r, err = BuildHeights(S, st)
        if not r then return nil, err end
        local path, lo, hi = Fields.Preview(r.regionField, size or 128, { ramp = 'terrain' })
        return { path = path, lo = lo, hi = hi, hLo = r.hLo, hHi = r.hHi, align = r.align, info = r.info, warnings = r.warnings, imageW = r.imageW, imageH = r.imageH,
                 region = r.region, srcLo = r.srcLo, srcHi = r.srcHi, pads = r.pads }
    end)
end

--- Writes the heights: ONE undo step. Returns { changed, entry, result } or nil, message.
function ApplyHeights(st, opts)
    opts = opts or {}
    local out, err = Fields.Run(function(S)
        local r, why = BuildHeights(S, st)
        if not r then return nil, why end
        local n, entry = Fields.Apply({ height = r.final, label = opts.label or 'Import heightmap' })
        r.final, r.imported, r.regionField = nil, nil, nil
        return { changed = n or 0, entry = entry, result = r }
    end)
    if not out then return nil, err end
    return out
end

-- ---- masks ------------------------------------------------------------------------------------------------------------------------------------------

local function MaskOrientation(ms)
    if ms.sync then
        local s = Settings
        return { flipX = s.flipX, flipZ = s.flipZ, rot = s.rot }, s.align, s.filter == 'nearest' and 'nearest' or 'bilinear'
    end
    return { flipX = ms.flipX, flipZ = ms.flipZ, rot = ms.rot }, ms.align, ms.filter
end

--- One mask file as a full-map field 0..1 (clamped; owned by S). `item` has file, channel, invert.
local function MaskField(S, item, ms, st)
    local f, info = ReadScoped(S, item.file, st or Settings, item.channel)
    if not f then return nil, info end
    local o, align, filter = MaskOrientation(ms)
    local ro = Oriented(S, f, o)
    local iw, ih = Fields.Info(ro)
    local mw, mh = ed_terrain_info()
    local cur = S:Height(1)
    local a = (align == 'cell' or align == 'corner') and align or ((iw == mw and ih == mh) and 'corner' or 'cell')
    local r = S:Op('img_resample', { a = ro, like = cur, align = a, filter = filter or 'bilinear', outside = 0 })
    local m = S:Op('clamp', { a = r, lo = 0, hi = 1 })
    if item.invert then m = S:Op('invert', { a = m, lo = 0, hi = 1 }) end
    return m, info
end

--- Writes every item of the mask set: texture layers from the highest down (so a layer takes away from the ones above it), terrain types, named masks kept. ONE undo step.
--- Returns { cells, layers, types, named } or nil, message.
function ApplyMasks(ms)
    ms = ms or MaskSet
    if table.getn(ms.items) == 0 then return nil, 'no mask files in the list' end
    if not Available() then return nil, 'the field engine or the image natives are missing' end
    local MaskGen = import('/lua/editor/maskgen.lua')
    local layerItems, typeItems, namedItems = {}, {}, {}
    for _, item in ms.items do
        if item.file ~= '' then
            if item.target == 'types' then table.insert(typeItems, item)
            elseif item.target == 'named' then table.insert(namedItems, item)
            else table.insert(layerItems, item) end
        end
    end
    table.sort(layerItems, function(a, b) return a.layer > b.layer end)
    if table.getn(layerItems) > 0 and not ed_stratum_info() then return nil, 'the map has no paint masks' end
    if table.getn(typeItems) > 0 and not (rawget(_G, 'ed_tt_info') and ed_tt_info()) then return nil, 'the map has no terrain type grid' end
    local out, err = Fields.Run(function(S)
        local c = MaskGen.NewContext(S, { step = 1 })
        local parts, cells, nLayers, nTypes, nNamed = {}, 0, 0, 0, 0
        for _, item in layerItems do
            local m, why = MaskField(S, item, ms)
            if not m then return nil, item.file .. ': ' .. tostring(why) end
            local entry, n = MaskGen.WriteLayer(c, m, math.floor(item.layer + 0.5), { mode = ms.mode, strength = ms.strength, takeAway = ms.takeAway }, true)
            if entry then table.insert(parts, entry) cells = cells + n nLayers = nLayers + 1 end
        end
        for _, item in typeItems do
            local m, why = MaskField(S, item, ms)
            if not m then return nil, item.file .. ': ' .. tostring(why) end
            local entry, n = MaskGen.WriteTypes(c, m, math.floor(item.code + 0.5), item.threshold or 0.5, true)
            if entry then table.insert(parts, entry) cells = cells + n nTypes = nTypes + 1 end
        end
        for _, item in namedItems do
            if item.name == '' then return nil, 'a named mask needs a name' end
            SetNamed({ name = item.name, file = item.file, channel = item.channel, invert = item.invert, flipX = Settings.flipX, flipZ = Settings.flipZ, rot = Settings.rot })
            nNamed = nNamed + 1
        end
        if table.getn(parts) > 0 then
            History.Push({
                label = 'Import masks',
                undo = function() for i = table.getn(parts), 1, -1 do parts[i].undo() end end,
                redo = function() for i = 1, table.getn(parts) do parts[i].redo() end end,
                release = function() for _, e in parts do e.release() end end,
            })
        end
        return { cells = cells, layers = nLayers, types = nTypes, named = nNamed }
    end)
    if not out then return nil, err end
    return out
end

-- ---- named masks (for the mask generator) -----------------------------------------------------------------------------------------------------------

local NamedCache = {}            -- name -> { field, stamp }

local function FreeNamed(name)
    local e = NamedCache[name]
    if e and e.field then Fields.Free(e.field) end
    NamedCache[name] = nil
end

--- Adds or replaces a named mask (the image file stays the source; it is read when a rule needs it).
function SetNamed(def)
    for i, n in Named do
        if n.name == def.name then
            Named[i] = def
            FreeNamed(def.name)
            Revision = Revision + 1
            return i
        end
    end
    table.insert(Named, def)
    Revision = Revision + 1
    return table.getn(Named)
end

function RemoveNamed(i)
    local n = Named[i]
    if not n then return end
    FreeNamed(n.name)
    table.remove(Named, i)
    Revision = Revision + 1
end

function NamedList()
    return Named
end

--- The named mask in slot `slot` on the grid of `like`, 0..1, owned by scope S. nil, message when the slot is empty or the file is gone.
function NamedField(S, slot, like)
    local n = Named[math.floor(slot + 0.5)]
    if not n then return nil, 'no imported mask in slot ' .. tostring(slot) end
    local stamp = Stamp(n.file)
    local e = NamedCache[n.name]
    if not e or e.stamp ~= stamp then
        FreeNamed(n.name)
        local ms = { sync = false, flipX = n.flipX, flipZ = n.flipZ, rot = n.rot, align = 'auto', filter = 'bilinear' }
        local out, err = Fields.Run(function(S2)
            local m, why = MaskField(S2, { file = n.file, channel = n.channel, invert = n.invert }, ms, Settings)
            if not m then return nil, why end
            S2:Keep(m)
            return m
        end)
        if not out then return nil, n.name .. ': ' .. tostring(err) end
        e = { field = out, stamp = stamp }
        NamedCache[n.name] = e
    end
    return S:Op('resample', { a = e.field, like = like })
end

-- ---- the live link -----------------------------------------------------------------------------------------------------------------------------------

Link = {
    enabled = false, mode = 'file',        -- 'file' (the heightmap file and the mask files of the set) | 'folder' (every image of the folder)
    folder = '', interval = 1.0,           -- seconds between looks
    apply = { heights = true, masks = true },
    stamps = {}, pending = {}, nextLook = 0, status = 'off', log = {}, entry = false, count = 0,
}

local function LinkLog(text)
    table.insert(Link.log, 1, text)
    while table.getn(Link.log) > 8 do table.remove(Link.log) end
    Link.status = text
    Revision = Revision + 1
    LOG('EDITOR interop link: ' .. text)
end

local function Basename(path)
    local name = string.gsub(path or '', '^.*[/\\]', '')
    return string.lower(name)
end

--- The files the link looks at and what each one means: { path = ..., kind = 'heights' | 'masks' | 'new' }.
local function Watched()
    local list = {}
    if Link.mode == 'folder' and Link.folder ~= '' then
        local stamps = ed_dir_stamps(Link.folder, EXTS)
        if stamps then
            local hb = Basename(Settings.file)
            local masks = {}
            for _, item in MaskSet.items do masks[Basename(item.file)] = true end
            for name, stamp in stamps do
                local kind = 'new'
                if string.lower(name) == hb then kind = 'heights' elseif masks[string.lower(name)] then kind = 'masks' end
                list[Link.folder .. '/' .. name] = { stamp = stamp, kind = kind }
            end
        end
    else
        if Settings.file ~= '' then list[Settings.file] = { stamp = ed_file_stamp(Settings.file) or 'missing', kind = 'heights' } end
        for _, item in MaskSet.items do
            if item.file ~= '' then list[item.file] = { stamp = ed_file_stamp(item.file) or 'missing', kind = 'masks' } end
        end
    end
    return list
end

--- Starts watching: remembers what the files look like now (a file that already exists does not count as a change).
function LinkStart()
    Link.stamps, Link.pending = {}, {}
    for path, w in Watched() do Link.stamps[path] = w.stamp end
    Link.enabled = true
    Link.nextLook = 0
    LinkLog('watching ' .. (Link.mode == 'folder' and Link.folder or Settings.file))
end

function LinkStop()
    Link.enabled = false
    LinkLog('stopped')
end

--- Takes back the last live import when it is still the latest undo step.
function LinkRevert()
    if Link.entry and History.Top() == Link.entry then
        History.Undo()
        Link.entry = false
        LinkLog('reverted the last live import')
        return true
    end
    LinkLog('cannot revert: other edits came after the last live import (use Undo)')
    return false
end

local function ApplyHeightsLive()
    -- the previous live import is replaced, not stacked: take it back first when nothing came after it
    if Link.entry and History.Top() == Link.entry then
        History.Undo()
        Link.entry = false
    end
    local out, err = ApplyHeights(Settings, { label = 'Live link: heightmap' })
    if not out then return LinkLog('heightmap not imported: ' .. tostring(err)) end
    Link.entry = out.entry or false
    Link.count = Link.count + 1
    LinkLog(string.format('heightmap imported (%d samples changed, %.0f to %.0f units)', out.changed, out.result.hLo, out.result.hHi))
end

local function ApplyMasksLive()
    local out, err = ApplyMasks(MaskSet)
    if not out then return LinkLog('masks not imported: ' .. tostring(err)) end
    Link.count = Link.count + 1
    LinkLog(string.format('masks imported (%d cells, %d layers, %d types, %d named)', out.cells, out.layers, out.types, out.named))
end

--- One look at the files (call it often; it works at most every Link.interval seconds). A change must be seen twice in a row with the same stamp (the tool is done writing).
function LinkPoll()
    if not Link.enabled or not Available() then return end
    local now = ed_field_clock()
    if now < Link.nextLook then return end
    Link.nextLook = now + Link.interval
    local heights, masks = false, false
    local list = Watched()
    for path, w in list do
        local seen = Link.stamps[path]
        if w.stamp ~= 'missing' and seen ~= w.stamp then
            if Link.pending[path] == w.stamp then
                Link.stamps[path] = w.stamp
                Link.pending[path] = nil
                if w.kind == 'heights' and Link.apply.heights then heights = true
                elseif w.kind == 'masks' and Link.apply.masks then masks = true
                elseif w.kind == 'new' then LinkLog('new file ' .. Basename(path) .. ' (not part of the import: add it to the mask list)') end
            else
                Link.pending[path] = w.stamp
            end
        end
    end
    if heights then
        local ok, err = pcall(ApplyHeightsLive)
        if not ok then LinkLog('heightmap import failed: ' .. tostring(err)) end
    end
    if masks then
        local ok, err = pcall(ApplyMasksLive)
        if not ok then LinkLog('mask import failed: ' .. tostring(err)) end
    end
end

-- ---- the sidecar --------------------------------------------------------------------------------------------------------------------------------------

local function CopyTable(t)
    local c = {}
    for k, v in t do
        if type(v) == 'table' then c[k] = CopyTable(v) else c[k] = v end
    end
    return c
end

function SidecarText()
    local d = DefaultSettings()
    local changed = false
    for k, v in Settings do
        if type(v) ~= 'table' and v ~= d[k] then changed = true end
    end
    if Settings.rect[1] ~= 0 or Settings.rect[2] ~= 0 or Settings.rect[3] ~= 0 or Settings.rect[4] ~= 0 then changed = true end
    if not changed and table.getn(MaskSet.items) == 0 and table.getn(Named) == 0 and not Link.enabled and Link.folder == '' then
        local Export = import('/lua/editor/interopexport.lua')
        if not Export.IsCustom() then return '' end
    end
    local data = {
        import = CopyTable(Settings),
        masks = CopyTable(MaskSet),
        named = CopyTable(Named),
        link = { mode = Link.mode, folder = Link.folder, interval = Link.interval, apply = CopyTable(Link.apply) },
        export = CopyTable(import('/lua/editor/interopexport.lua').Settings),
    }
    return Ser.Chunk({ { 'Interop', data } })
end

--- Back to the defaults (a new map).
function Reset()
    Settings = DefaultSettings()
    MaskSet = DefaultMaskSet()
    for name, _ in NamedCache do FreeNamed(name) end
    Named = {}
    FreeCache()
    Link.enabled = false
    Link.stamps, Link.pending, Link.log, Link.entry, Link.folder, Link.status, Link.count = {}, {}, {}, false, '', 'off', 0
    Link.mode = 'file'
    import('/lua/editor/interopexport.lua').Reset()
    Revision = Revision + 1
end

local function Merge(target, source)
    for k, v in source do
        if type(v) == 'table' and type(target[k]) == 'table' then Merge(target[k], v) else target[k] = v end
    end
end

--- Takes the settings of a sidecar table `Interop = { import, masks, named, link, export }`.
function ApplyData(d)
    if not d then return end
    Merge(Settings, d.import or {})
    Merge(MaskSet, d.masks or {})
    MaskSet.items = (d.masks and d.masks.items) or {}
    Named = d.named or {}
    if d.link then
        Link.mode = d.link.mode or 'file'
        Link.folder = d.link.folder or ''
        Link.interval = d.link.interval or 1
        Merge(Link.apply, d.link.apply or {})
    end
    if d.export then Merge(import('/lua/editor/interopexport.lua').Settings, d.export) end
    Revision = Revision + 1
end

function LoadSidecar(scenarioFile)
    Reset()
    local path = scenarioFile and import('/lua/editor/mods.lua').SidecarPath(scenarioFile)
    if path and DiskGetFileInfo(path) then
        local env = {}
        doscript(path, env)
        ApplyData(env.Interop)
    end
end

--- Frees what the module holds natively (a module reload or leaving the editor).
function Release()
    FreeCache()
    for name, _ in NamedCache do FreeNamed(name) end
end
