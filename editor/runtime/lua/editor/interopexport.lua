-- Export of the terrain for external tools (Gaea, World Machine, Blender, Photoshop, QGIS): docs/projects/editor/TERRAIN_INTEROP.md.
-- The height field goes out as a 16-bit PNG / TIFF, a 32-bit float TIFF or a raw file, normalised (0..1 between the map's lowest and highest point, the range recorded in a sidecar .json so the
-- round trip is exact) or absolute (16-bit word / 128 = world units; float: world units). Masks go out on the same N+1 sample grid as the heights.
--
--   Settings                     what to export and how (kept in the map's sidecar)
--   Plan(st)                     -> list of { id, file, what } the export would write
--   Export(st)                   -> report { files = { path, ... }, lo, hi, text } | nil, message
--   ReadJson(path)               -> table | nil          the sidecar .json written next to a heightmap
--   FillImportFrom(imp, json)    sets an import settings table from such a json: the round trip needs no typing
--   Readme(st, facts)            -> text                the scale sheet for Gaea / World Machine
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')

function Defaults()
    return {
        dir = '', name = '',
        mode = 'normalised',          -- 'normalised' | 'absolute'
        format = 'png',               -- 'png' | 'tif' | 'raw'
        bits = 16,                    -- 16 | 32 (float; a TIFF or raw)
        fixed = false, lo = 0, hi = 100,       -- fixed height range instead of the map's own
        maskBits = 16,
        items = { height = true, water = true, slope = true, flow = false, wear = false, layers = true, types = false, markers = true, playable = true, readme = true },
        waterSoft = 0.5, markerRadius = 3,
    }
end

Settings = Defaults()

function Reset()
    Settings = Defaults()
end

--- Whether the settings differ from the defaults (the sidecar is only written then).
function IsCustom()
    local d = Defaults()
    for k, v in Settings do
        if type(v) ~= 'table' and v ~= d[k] then return true end
    end
    for k, v in Settings.items do
        if v ~= d.items[k] then return true end
    end
    return false
end

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    LOG('EDITOR interop export: ' .. text)
end

local function MapName()
    local Map = import('/lua/editor/map.lua')
    local path = Map.Doc and Map.Doc.scenarioPath
    if path then
        local stem = string.gsub(path, '^.*[/\\]', '')
        stem = string.gsub(stem, '_scenario%.lua$', '')
        if stem ~= '' then return stem end
    end
    return 'terrain'
end

local function Extension(st, bits)
    if st.format == 'raw' then return bits == 32 and 'r32' or 'r16' end
    if st.format == 'tif' or bits == 32 then return 'tif' end
    return 'png'
end

local function Path(st, suffix, ext)
    local dir = st.dir
    if dir == '' then return nil end
    dir = string.gsub(dir, '[/\\]+$', '')
    local name = st.name ~= '' and st.name or MapName()
    return dir .. '/' .. name .. suffix .. '.' .. ext
end

--- The files an export would write: { id, file, what }.
function Plan(st)
    st = st or Settings
    local list = {}
    local function Add(id, suffix, ext, what)
        table.insert(list, { id = id, file = Path(st, suffix, ext) or ('<folder>' .. suffix .. '.' .. ext), what = what })
    end
    local it = st.items
    if it.height then
        local ext = Extension(st, st.bits)
        Add('height', '_height', ext, st.mode == 'normalised' and 'heightmap, 0..1 between the lowest and highest point' or 'heightmap, absolute')
    end
    if it.height or it.readme then
        Add('json', '_height', 'json', 'range, size and scale of the heightmap')
    end
    local mext = st.format == 'tif' and 'tif' or 'png'
    if it.water then Add('water', '_water', mext, 'water mask (1 under the water surface)') end
    if it.slope then Add('slope', '_slope', mext, 'slope, 0..90 degrees as 0..1') end
    if it.flow then Add('flow', '_flow', mext, 'drainage (where rivers run)') end
    if it.wear then Add('wear', '_wear', mext, 'wear (convex ridges) and deposit (concave basins)') Add('deposit', '_deposit', mext, 'deposit mask') end
    if it.layers then Add('layers', '_layerN', mext, 'the painted texture layers, one image each') end
    if it.types then Add('types', '_terraintypes', 'png', 'terrain type codes (8-bit)') end
    if it.markers then
        Add('csv', '_markers', 'csv', 'all markers: name, type, x, y, z')
        Add('starts', '_starts', mext, 'start positions as discs')
        Add('resources', '_resources', mext, 'mass and hydrocarbon deposits as discs')
    end
    if it.playable then Add('playable', '_playable', mext, 'the playable area') end
    if it.readme then Add('readme', '_README_scale', 'txt', 'the scale sheet for Gaea / World Machine') end
    return list
end

-- ---- the json sidecar ---------------------------------------------------------------------------------------------------------------------------

local function Num(v)
    return string.format('%.9g', v)
end

--- Reads the numbers and words of the flat json files written by Export (no nesting needed).
function ReadJson(path)
    local text = ed_read_file(path)
    if not text then return nil end
    local t = {}
    for key, value in string.gfind(text, '"([%w_]+)"%s*:%s*(%-?[%d%.eE%+%-]+)') do t[key] = tonumber(value) end
    for key, value in string.gfind(text, '"([%w_]+)"%s*:%s*"([^"]*)"') do t[key] = value end
    if not t.min and not t.mode then return nil end
    return t
end

--- The json belonging to a heightmap file: `x.png` -> `x.json`.
function JsonFor(file)
    local path = string.gsub(file or '', '%.[%w]+$', '.json')
    if path == file then return nil end
    return path
end

--- Fills the import settings from the json of an export: the same range, so the round trip is exact. Returns a text for the status line, or nil when there is no json.
function FillImportFrom(imp, json)
    if not json then return nil end
    if json.mode == 'normalised' and json.min and json.max then
        imp.mode, imp.min, imp.max, imp.stretch, imp.invert = 'normalised', json.min, json.max, false, false
        imp.anchor = false
        return string.format('range %.4f to %.4f units from the json', json.min, json.max)
    elseif json.mode == 'absolute' then
        imp.mode, imp.stretch, imp.invert = 'absolute', false, false
        return 'absolute heights from the json'
    end
    return nil
end

-- ---- the export ---------------------------------------------------------------------------------------------------------------------------------

local function WriteField(path, f, bits, lo, hi)
    local ok, err = ed_img_write(path, f, { bits = bits, lo = lo, hi = hi })
    if not ok then error(path .. ': ' .. tostring(err)) end
    return path
end

function Readme(st, facts)
    local n = facts.w - 1
    local lines = {
        'Terrain export of ' .. facts.name .. ' (FAF Studio)',
        '',
        string.format('Map size   : %d x %d world units (%.1f km), 1 sample = 1 world unit', n, facts.h - 1, n / 51.2),
        string.format('Sample grid: %d x %d samples (N + 1; the files hold exactly these samples)', facts.w, facts.h),
        string.format('Heights    : %.3f to %.3f units on this map; the game holds 0 to 511.99 (16-bit words, 1/128 unit steps)', facts.lo, facts.hi),
        string.format('Water level: %.2f units', facts.water),
        '',
        'Heightmap file (' .. facts.heightFile .. ')',
    }
    if st.mode == 'normalised' then
        table.insert(lines, string.format('  value 0..1 = %.4f .. %.4f units (see the .json: min / max). Importing back: mode "normalised", min %.4f, max %.4f, no stretch.', facts.rangeLo, facts.rangeHi, facts.rangeLo, facts.rangeHi))
    else
        table.insert(lines, '  absolute: 16-bit value / 128 = units (float files hold the units directly).')
    end
    local scale = facts.rangeHi - facts.rangeLo
    table.insert(lines, '')
    table.insert(lines, 'Gaea')
    table.insert(lines, string.format('  Build resolution %d (or %d to cover the cells with whole pixels). Export the Height as 16-bit PNG / TIFF or a 32-bit float TIFF.', facts.w, n))
    table.insert(lines, string.format('  Use this file as an Image / Terrain input at %d x %d. To get the same heights back set the import range to min %.2f, max %.2f (editor Interop panel).', facts.w, facts.h, facts.rangeLo, facts.rangeHi))
    table.insert(lines, '  A Gaea export normalised 0..1: choose "normalised" in the panel and set max - min to the height you want the tallest peak to have (the editor looks best below about 250).')
    table.insert(lines, '')
    table.insert(lines, 'World Machine')
    table.insert(lines, string.format('  Build size %d x %d (device "Heightfield, 16-bit": %d for the whole map). Output: Heightfield Converter / File Output as .r16 (raw 16 bit), .png or 32-bit .tif.', facts.w, facts.h, facts.w))
    table.insert(lines, string.format('  World Machine terrain extents: %d m wide; "Terrain height" %.0f m maps the 0..1 range. Import the .r16 with "normalised" and min 0, max = the height you used.', n, scale))
    table.insert(lines, '')
    table.insert(lines, 'Pixel and cell alignment')
    table.insert(lines, string.format('  An image of %d x %d pixels has a pixel on every sample (the editor aligns it corner to corner: exact). An image of %d x %d covers the %d cells (pixel centres on the cell centres).', facts.w, facts.h, n, n, n))
    table.insert(lines, '  Larger images are low-pass filtered while they are shrunk onto the map (lanczos / bicubic / bilinear).')
    table.insert(lines, '')
    table.insert(lines, 'Masks: 0 = no, 1 = full. Texture layers are exported unchanged from the paint masks (the editor takes away what the layers above cover when you import them with "layers above take away").')
    if facts.playable then
        table.insert(lines, string.format('Playable area: x %d..%d, z %d..%d', facts.playable[1], facts.playable[3], facts.playable[2], facts.playable[4]))
    end
    return table.concat(lines, '\n') .. '\n'
end

--- Writes the files of the plan. Returns { files, lo, hi, text } or nil, message.
function Export(st)
    st = st or Settings
    if not Fields.IsAvailable() or not rawget(_G, 'ed_img_write') then return nil, 'the field engine or the image natives are missing' end
    if st.dir == '' then return nil, 'choose a folder first' end
    local w, h = ed_terrain_info()
    if not w then return nil, 'no terrain' end
    local files = {}
    local it = st.items
    local world = import('/lua/editor/world.lua').Get()
    local water = world.water_elev or 0
    local Map = import('/lua/editor/map.lua')
    local Playable = import('/lua/editor/playable.lua')
    local facts = { w = w, h = h, name = st.name ~= '' and st.name or MapName(), water = water }
    local ok, err = pcall(function()
        Fields.Run(function(S)
            local H = S:Height(1)
            local lo, hi = Fields.Stats(H)
            facts.lo, facts.hi = lo, hi
            local rlo, rhi = lo, hi
            if st.fixed then rlo, rhi = st.lo, st.hi end
            if rhi - rlo < 0.01 then rhi = rlo + 0.01 end
            facts.rangeLo, facts.rangeHi = rlo, rhi
            local bits = st.bits == 32 and 32 or 16
            local heightFile = Path(st, '_height', Extension(st, bits))
            facts.heightFile = string.gsub(heightFile, '^.*[/\\]', '')
            local pa = { Playable.Get() }
            facts.playable = pa[5] and { pa[1], pa[2], pa[3], pa[4] } or nil
            local json = {
                '{',
                '  "tool": "FAF Studio",',
                '  "file": "' .. facts.heightFile .. '",',
                '  "mode": "' .. st.mode .. '",',
                '  "bits": ' .. bits .. ',',
                '  "float": ' .. (bits == 32 and 1 or 0) .. ',',
                '  "min": ' .. Num(st.mode == 'normalised' and rlo or 0) .. ',',
                '  "max": ' .. Num(st.mode == 'normalised' and rhi or 65535 / 128) .. ',',
                '  "lowest": ' .. Num(lo) .. ',',
                '  "highest": ' .. Num(hi) .. ',',
                '  "width": ' .. w .. ',',
                '  "height": ' .. h .. ',',
                '  "cells": ' .. (w - 1) .. ',',
                '  "units_per_sample": 1,',
                '  "water_elevation": ' .. Num(water) .. ',',
                '  "note": "normalised: value 0..1 = min..max world units; absolute: 16-bit value / 128 (float: units)"',
                '}',
            }
            local jpath = Path(st, '_height', 'json')
            if not ed_write_file(jpath, table.concat(json, '\n') .. '\n') then error('cannot write into ' .. st.dir) end
            table.insert(files, jpath)
            -- heightmap
            if it.height then
                if st.mode == 'absolute' then
                    if bits == 32 then WriteField(heightFile, H, 32) else WriteField(heightFile, H, 16, 0, 65535 / 128) end
                else
                    if bits == 32 then
                        WriteField(heightFile, S:Op('affine', { a = H, mul = 1 / (rhi - rlo), add = -rlo / (rhi - rlo) }), 32)
                    else
                        WriteField(heightFile, H, 16, rlo, rhi)
                    end
                end
                table.insert(files, heightFile)
            end
            local mbits = st.maskBits == 8 and 8 or 16
            local mext = st.format == 'tif' and 'tif' or 'png'
            local function Mask(suffix, f)
                local file = Path(st, suffix, mext)
                WriteField(file, f, mbits, 0, 1)
                table.insert(files, file)
            end
            local function Clamp01(f) return S:Op('clamp', { a = f, lo = 0, hi = 1 }) end
            if it.water then Mask('_water', S:Op('water_below', { a = H, level = water, soft = st.waterSoft })) end
            if it.slope then Mask('_slope', Clamp01(S:Op('affine', { a = S:Op('slope', { a = H, mode = 'degrees', radius = 1 }), mul = 1 / 90, add = 0 }))) end
            if it.flow then Mask('_flow', S:Op('flow', { a = H, range = 1000000 })) end
            if it.wear then
                local curv = S:Op('curvature', { a = H, radius = 6, gain = 25 })
                Mask('_wear', S:Op('smoothstep', { a = curv, edge0 = 0.5, edge1 = 0.9 }))
                Mask('_deposit', S:Op('smoothstep', { a = S:Op('invert', { a = curv, lo = 0, hi = 1 }), edge0 = 0.5, edge1 = 0.9 }))
            end
            if it.layers and ed_stratum_info() then
                for layer = 1, 8 do
                    local albedo = ed_stratum_layer(layer)
                    if albedo and albedo ~= '' and not string.find(albedo, 'clear_albedo', 1, true) then
                        Mask('_layer' .. layer, S:Op('resample', { a = S:Stratum(layer), like = H }))
                    end
                end
            end
            if it.types and rawget(_G, 'ed_tt_info') and ed_tt_info() then
                local tt = S:Add(Fields.TerrainTypes())
                local file = Path(st, '_terraintypes', 'png')
                WriteField(file, tt, 8, 0, 255)
                table.insert(files, file)
            end
            if it.markers and Map.Doc then
                local rows = { 'name,type,x,y,z' }
                local names = {}
                for name, _ in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do table.insert(names, name) end
                table.sort(names)
                local starts, resources = {}, {}
                for _, name in names do
                    local m = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers[name]
                    if m.position then
                        table.insert(rows, string.format('%s,%s,%.3f,%.3f,%.3f', name, tostring(m.type), m.position[1], m.position[2], m.position[3]))
                        local r = st.markerRadius
                        if string.find(name, '^ARMY_%d+$') then
                            table.insert(starts, m.position[1]) table.insert(starts, m.position[3]) table.insert(starts, r) table.insert(starts, 1)
                        elseif m.type == 'Mass' or m.type == 'Hydrocarbon' then
                            table.insert(resources, m.position[1]) table.insert(resources, m.position[3]) table.insert(resources, r) table.insert(resources, 1)
                        end
                    end
                end
                local csv = Path(st, '_markers', 'csv')
                ed_write_file(csv, table.concat(rows, '\n') .. '\n')
                table.insert(files, csv)
                Mask('_starts', S:Op('points_mask', { like = H, pts = starts, feather = 0 }))
                Mask('_resources', S:Op('points_mask', { like = H, pts = resources, feather = 0 }))
            end
            if it.playable then
                local x0, z0, x1, z1 = Playable.Get()
                Mask('_playable', S:Op('rect_mask', { like = H, x0 = x0, z0 = z0, x1 = x1, z1 = z1, feather = 0 }))
            end
            if it.readme then
                local path = Path(st, '_README_scale', 'txt')
                facts.heightFile = facts.heightFile or '(not exported)'
                ed_write_file(path, Readme(st, facts))
                table.insert(files, path)
            end
        end)
    end)
    if not ok then return nil, tostring(err) end
    local text = string.format('exported %d files to %s (heights %.2f to %.2f)', table.getn(files), st.dir, facts.lo or 0, facts.hi or 0)
    Say(text)
    return { files = files, lo = facts.lo, hi = facts.hi, rangeLo = facts.rangeLo, rangeHi = facts.rangeHi, text = text }
end
