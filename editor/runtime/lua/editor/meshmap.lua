-- Mesh terrain maps: the manifest `terrain/terrain.lua` (docs/projects/TERRAIN_MESH_MAPS.md, MESH_MAP_EDITOR_NEEDS.md section 1.3) and its checks.
--
-- The manifest is read by the terrain mesh patch line by line, so the editor writes the exact dialect scripts/meshmaps/convert.py writes:
-- one entry per line, single-quoted strings, fixed decimals, no exponents, a fixed key order. The reader accepts the same dialect and
-- reports everything else as a warning (Parse().warnings).
--
--   Parse(text)                -> model { settings = { key = value }, materials = { { {key, value}, ... } }, patches = { patch | { comment } }, warnings = {} }
--   Write(model)               -> manifest text (Parse(Write(m)) == m; for convert.py output Write(Parse(t)) == t)
--   New()                      -> an empty model;  FromMap()  -> a model filled from the open map (size, playable area, water, heights, sun)
--   Dir()                      -> disk folder of the open map (nil when it has no folder);  ManifestPath()
--   Load([folder]) / Save(model [, folder])   read / write <map folder>/terrain/terrain.lua
--   Check(model [, folder, opts]) -> list of { sev = 'E' | 'W' | 'I', code = 'V9', text } (validators of MESH_MAP_EDITOR_NEEDS.md section 3 that need no mesh renderer);
--                              opts.deep reads every patch and adds V3, V4, V10 and V15 (meshscan.lua); opts.coverage = false leaves V10 out
--   MaterialGet(mat, key) / MaterialSet(mat, key, value)   one field of a material entry (value nil removes it); fields stay in canonical order
--   MaterialLabel(mat)         the material's name
--   Keys                       the settings in file order with their decimals, range and meaning
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match (string.find with captures).

local Map = import('/lua/editor/map.lua')

-- decimals: a number of decimals; 'int' for integers; 'str' for a file name
Keys = {
    { key = 'size',                  dec = 'int', min = 64,   max = 5120, help = 'Map side in world units (the .scmap size)' },
    { key = 'playable_x0',           dec = 1,     min = 0,    max = 5120, help = 'Playable rectangle' },
    { key = 'playable_z0',           dec = 1,     min = 0,    max = 5120, help = 'Playable rectangle' },
    { key = 'playable_x1',           dec = 1,     min = 0,    max = 5120, help = 'Playable rectangle' },
    { key = 'playable_z1',           dec = 1,     min = 0,    max = 5120, help = 'Playable rectangle' },
    { key = 'water',                 dec = 2,     min = -100, max = 300,  help = 'Water level' },
    { key = 'water_abyss',           dec = 2,     min = -200, max = 300,  help = 'Ground fully tinted below this (below the level by at least 1)' },
    { key = 'water_tint',            dec = 'int', min = 0,    max = 1,    help = '0 = no ramp tint on the ground under water' },
    { key = 'water_map',             dec = 'str', help = 'Water depth / land texture over the map' },
    { key = 'water_map_outer',       dec = 'str', help = 'The same over the scenery square' },
    { key = 'water_outer_min',       dec = 1,     min = -5000, max = 5000, help = 'Corner of the scenery square' },
    { key = 'water_outer_span',      dec = 1,     min = 0,    max = 20000, help = 'Side of the scenery square' },
    { key = 'water_beyond',          dec = 'str', help = 'Water triangles outside the map (x z float pairs)' },
    { key = 'water_beyond_triangles', dec = 'int', min = 0,   max = 100000, help = 'Triangle count of that file' },
    { key = 'water_inside',          dec = 'str', help = 'Water triangles inside the map' },
    { key = 'water_inside_triangles', dec = 'int', min = 0,   max = 100000, help = 'Triangle count of that file' },
    { key = 'haze',                  dec = 2,     min = -300, max = 300,  help = 'Below this the ground fades into the void colour' },
    { key = 'haze_span',             dec = 2,     min = 0,    max = 300,  help = 'Fade distance' },
    { key = 'ground_low',            dec = 2,     min = -100, max = 300,  help = 'Lowest ground units can stand on' },
    { key = 'ground_high',           dec = 2,     min = -100, max = 300,  help = 'Highest ground units can stand on' },
    { key = 'mesh_high',             dec = 2,     min = -100, max = 3000, help = 'Highest mesh vertex in the playable area + 32' },
    { key = 'shadow_r',              dec = 3,     min = 0,    max = 2,    help = 'Light the shadowed ground gets' },
    { key = 'shadow_g',              dec = 3,     min = 0,    max = 2,    help = 'Light the shadowed ground gets' },
    { key = 'shadow_b',              dec = 3,     min = 0,    max = 2,    help = 'Light the shadowed ground gets' },
    { key = 'shadow_a',              dec = 3,     min = 0,    max = 2,    help = 'Light the shadowed ground gets' },
    { key = 'sun_x',                 dec = 4,     min = -1,   max = 1,    help = 'Direction towards the sun (unit vector)' },
    { key = 'sun_y',                 dec = 4,     min = -1,   max = 1,    help = 'Direction towards the sun (unit vector)' },
    { key = 'sun_z',                 dec = 4,     min = -1,   max = 1,    help = 'Direction towards the sun (unit vector)' },
    { key = 'sun_r',                 dec = 3,     min = 0,    max = 4,    help = 'Sun colour of the specular highlight' },
    { key = 'sun_g',                 dec = 3,     min = 0,    max = 4,    help = 'Sun colour of the specular highlight' },
    { key = 'sun_b',                 dec = 3,     min = 0,    max = 4,    help = 'Sun colour of the specular highlight' },
    { key = 'void_r',                dec = 3,     min = 0,    max = 1,    help = 'What is seen where there is no ground' },
    { key = 'void_g',                dec = 3,     min = 0,    max = 1,    help = 'What is seen where there is no ground' },
    { key = 'void_b',                dec = 3,     min = 0,    max = 1,    help = 'What is seen where there is no ground' },
}
local keyInfo = {}
for _, k in Keys do keyInfo[k.key] = k end

function KeyInfo(key) return keyInfo[key] end

local MATERIAL_FLAGS = { blending = true, glow = true, alpha_test = true, highlight = true, additive = true }
local MATERIAL_SLOTS = { diffuse_a = true, diffuse_b = true, normal_a = true, normal_b = true, specular = true, specular_b = true,
                         light_mask_0 = true, light_mask_1 = true, light_mask_2 = true }

local HEADER = {
    '-- Mesh terrain manifest (docs/projects/TERRAIN_MESH_MAPS.md). One entry per line.\n',
    '-- Paths are relative to this file. Texture slots: two blended layers (a, b), one specular map, light masks.\n',
}

--- The manifest model the Mesh terrain and Mesh import panels edit (false until one is loaded or created; a module global set to nil would not exist).
Current = false

function New()
    return { settings = {}, materials = {}, patches = {}, warnings = {} }
end

-- ---- material entries ------------------------------------------------------------------------------------------------------------------------

-- the order convert.py writes: name, flags, texture slots
MaterialOrder = { 'name', 'blending', 'glow', 'highlight', 'additive', 'alpha_test', 'diffuse_a', 'diffuse_b', 'normal_a', 'normal_b', 'specular', 'specular_b',
                  'light_mask_0', 'light_mask_1', 'light_mask_2' }
MaterialFlagKeys = { 'blending', 'glow', 'highlight', 'additive', 'alpha_test' }
MaterialSlotKeys = { 'diffuse_a', 'diffuse_b', 'normal_a', 'normal_b', 'specular', 'specular_b', 'light_mask_0', 'light_mask_1', 'light_mask_2' }

function MaterialGet(mat, key)
    for _, f in mat do
        if f[1] == key then return f[2] end
    end
end

function MaterialLabel(mat)
    return MaterialGet(mat, 'name') or ''
end

--- Sets (or, with nil or '', removes) one field of a material entry, keeping the canonical order; unknown fields stay at the end.
function MaterialSet(mat, key, value)
    if value == '' then value = nil end
    local found = false
    for i, f in mat do
        if f[1] == key then
            found = true
            if value == nil then table.remove(mat, i) else f[2] = value end
            break
        end
    end
    if found or value == nil then return end
    local rank = {}
    for i, k in MaterialOrder do rank[k] = i end
    local myRank = rank[key] or 1000
    local at = table.getn(mat) + 1
    for i, f in mat do
        if (rank[f[1]] or 1000) > myRank then at = i break end
    end
    table.insert(mat, at, { key, value })
end

-- ---- reading ---------------------------------------------------------------------------------------------------------------------------------

--- Splits `key = value, key = 'text', ...` into an ordered list of { key, value } (value: number or string); nil when the text is not that dialect.
local function Fields(text, warn)
    local list = {}
    local pos = 1
    while true do
        local s, e, key = string.find(text, '([%w_]+) = ', pos)
        if not s then break end
        local c = string.sub(text, e + 1, e + 1)
        local value
        if c == "'" then
            local q = string.find(text, "'", e + 2, true)
            if not q then warn('unterminated string after ' .. key) break end
            value = string.sub(text, e + 2, q - 1)
            pos = q + 1
        elseif c == '"' then
            warn('double quotes after ' .. key .. ' (the patch reads single quotes only)')
            local q = string.find(text, '"', e + 2, true)
            if not q then break end
            value = string.sub(text, e + 2, q - 1)
            pos = q + 1
        elseif c == '{' then
            -- min / max triples
            local q = string.find(text, '}', e + 2, true)
            if not q then warn('unterminated table after ' .. key) break end
            local nums = {}
            for n in string.gfind(string.sub(text, e + 2, q - 1), '[-%d.eE+]+') do table.insert(nums, tonumber(n)) end
            value = nums
            pos = q + 1
        else
            local _, e2, num = string.find(text, '^([-%d.eE+]+)', e + 1)
            if not num then warn('no value after ' .. key) break end
            if string.find(num, '[eE+]') then warn('exponent or plus sign in ' .. key .. ' = ' .. num .. ' (numbers are scanned as digits, minus and dot only)') end
            value = tonumber(num)
            pos = e2 + 1
        end
        table.insert(list, { key, value })
    end
    return list
end

function Parse(text)
    local m = New()
    local mode = 'top'          -- 'top' | 'materials' | 'patches'
    local lineNo = 0
    local seenRoot = false
    local function Warn(text2) table.insert(m.warnings, 'line ' .. lineNo .. ': ' .. text2) end
    local first, second = true, true
    text = string.gsub(text, '\r\n', '\n')
    for line in string.gfind(text .. '\n', '([^\n]*)\n') do
        lineNo = lineNo + 1
        local trimmed = string.gsub(line, '^%s+', '')
        trimmed = string.gsub(trimmed, '%s+$', '')
        if trimmed == '' then
            -- blank lines carry nothing
        elseif string.sub(trimmed, 1, 2) == '--' then
            if mode == 'patches' then table.insert(m.patches, { comment = trimmed }) end
        elseif string.find(trimmed, '^TerrainMesh = {') then
            seenRoot = true
        elseif trimmed == '}' or trimmed == '},' then
            if mode == 'materials' or mode == 'patches' then mode = 'top' end
        elseif string.find(trimmed, '^materials = {') then
            mode = 'materials'
        elseif string.find(trimmed, '^patches = {') then
            mode = 'patches'
        elseif mode == 'materials' or mode == 'patches' then
            local s, e, body = string.find(trimmed, '^{ (.*) },?$')
            if not s then
                Warn('entry not in the one-line form "{ ... },"')
            elseif mode == 'materials' then
                if not string.find(body, "name = '", 1, true) then Warn('material without a name') end
                local fields = Fields(body, Warn)
                for _, f in fields do
                    if not MATERIAL_FLAGS[f[1]] and not MATERIAL_SLOTS[f[1]] and f[1] ~= 'name' then Warn('unknown material field ' .. f[1]) end
                end
                table.insert(m.materials, fields)
            else
                if not string.find(body, "mesh = '", 1, true) then Warn('patch without mesh = ') end
                local patch = {}
                for _, f in Fields(body, Warn) do patch[f[1]] = f[2] end
                table.insert(m.patches, patch)
            end
        else
            if string.find(trimmed, "mesh = ", 1, true) or string.find(trimmed, "name = ", 1, true) then
                Warn('a settings line must not contain "mesh = " or "name = "')
            end
            local fields = Fields(trimmed, Warn)
            if table.getn(fields) ~= 1 then
                Warn('settings take one entry per line: ' .. trimmed)
            end
            for _, f in fields do
                if f[1] == 'version' then
                    m.version = f[2]
                elseif keyInfo[f[1]] then
                    m.settings[f[1]] = f[2]
                else
                    Warn('unknown setting ' .. f[1] .. ' (ignored by the patch)')
                end
            end
        end
    end
    if not seenRoot then table.insert(m.warnings, 'no "TerrainMesh = {" line') end
    m.version = m.version or 1
    return m
end

-- ---- writing ---------------------------------------------------------------------------------------------------------------------------------

local function Num(v, dec)
    if dec == 'int' then return string.format('%d', math.floor(v + 0.5)) end
    return string.format('%.' .. dec .. 'f', v)
end

local function FieldText(f)
    local v = f[2]
    if type(v) == 'string' then return f[1] .. " = '" .. v .. "'" end
    if type(v) == 'table' then return f[1] .. ' = { ' .. string.format('%.2f, %.2f, %.2f', v[1], v[2], v[3]) .. ' }' end
    return f[1] .. ' = ' .. string.format('%d', v)
end

function Write(m)
    local out = {}
    for _, l in HEADER do table.insert(out, l) end
    table.insert(out, 'TerrainMesh = {\n    version = ' .. string.format('%d', m.version or 1) .. ',\n')
    for _, k in Keys do
        local v = m.settings[k.key]
        if v ~= nil then
            if k.dec == 'str' then
                table.insert(out, '    ' .. k.key .. " = '" .. v .. "',\n")
            else
                table.insert(out, '    ' .. k.key .. ' = ' .. Num(v, k.dec) .. ',\n')
            end
        end
    end
    table.insert(out, '    materials = {\n')
    for _, mat in m.materials do
        local fields = {}
        for _, f in mat do table.insert(fields, FieldText(f)) end
        table.insert(out, '        { ' .. table.concat(fields, ', ') .. ' },\n')
    end
    table.insert(out, '    },\n    patches = {\n')
    for _, p in m.patches do
        if p.comment then
            table.insert(out, '        ' .. p.comment .. '\n')
        else
            local min, max = p.min or { 0, 0, 0 }, p.max or { 0, 0, 0 }
            table.insert(out, string.format("        { mesh = '%s', material = %d, %svertices = %d, triangles = %d, min = { %.2f, %.2f, %.2f }, max = { %.2f, %.2f, %.2f } },\n",
                p.mesh, p.material or 1, (p.sky and p.sky ~= 0) and 'sky = 1, ' or '', p.vertices or 0, p.triangles or 0,
                min[1], min[2], min[3], max[1], max[2], max[3]))
        end
    end
    table.insert(out, '    },\n}\n')
    return table.concat(out)
end

-- ---- the map's side -------------------------------------------------------------------------------------------------------------------------

--- Disk folder of the open map, or nil.
function Dir()
    if not Map.Doc or not Map.Doc.scenarioPath then return nil end
    local disk = ed_vfs_to_disk(Map.Doc.scenarioPath)
    if not disk then return nil end
    disk = string.gsub(disk, '\\', '/')
    return (string.gsub(disk, '/[^/]*$', ''))
end

function ManifestPath()
    local dir = Dir()
    return dir and (dir .. '/terrain/terrain.lua')
end

function Load(folder)
    local path = folder and (folder .. '/terrain/terrain.lua') or ManifestPath()
    if not path then return nil, 'the map has no folder yet (save it first)' end
    local text = ed_read_file(path)
    if not text then return nil, 'no terrain/terrain.lua in the map folder' end
    return Parse(text)
end

function Save(m, folder)
    local path = folder and (folder .. '/terrain/terrain.lua') or ManifestPath()
    if not path then return nil, 'the map has no folder yet (save it first)' end
    if not ed_write_file(path, Write(m)) then return nil, 'writing terrain.lua failed' end
    return path
end

--- The files a manifest names, relative to the terrain folder (the manifest itself included).
function Files(m)
    local list, seen = { 'terrain.lua' }, { ['terrain.lua'] = true }
    local function Add(f)
        if f and f ~= '' and not seen[f] then seen[f] = true table.insert(list, f) end
    end
    for _, k in { 'water_map', 'water_map_outer', 'water_beyond', 'water_inside' } do Add(m.settings[k]) end
    for _, mat in m.materials do
        for _, f in mat do
            if MATERIAL_SLOTS[f[1]] then Add(f[2]) end
        end
    end
    for _, p in m.patches do Add(p.mesh) end
    return list
end

local function SizeOf(path)
    local stamp = ed_file_stamp(path)
    if not stamp then return nil end
    return string.sub(stamp, 1, (string.find(stamp, ':', 1, true) or 0) - 1)
end

--- Saving the map into another folder: the terrain folder (manifest, patches, textures, water files) goes along. Files that are there already with the
--- same size are left alone (autosaves would otherwise copy tens of megabytes every time). -> number of files copied, or nil + reason.
function CopyTerrain(toDir)
    local from = Dir()
    if not from or not Map.Doc then return 0 end
    if string.lower(from) == string.lower(toDir) then return 0 end
    local m = Load()
    if not m then return 0 end
    local copied = 0
    for _, f in Files(m) do
        local src, dst = from .. '/terrain/' .. f, toDir .. '/terrain/' .. f
        local sizeA = SizeOf(src)
        if sizeA and sizeA ~= SizeOf(dst) then
            local data = ed_read_file(src)
            if not data then return nil, 'cannot read ' .. src end
            if not ed_write_file(dst, data) then return nil, 'cannot write ' .. dst end
            copied = copied + 1
        end
    end
    return copied
end

--- Height range of the ground over a coarse grid: min, max (world units).
local function HeightRange()
    local w = ed_terrain_info()
    if not w then return 0, 0 end
    local size = w - 1
    local step = math.max(1, math.floor(size / 128))
    local lo, hi
    for z = 0, size, step do
        for x = 0, size, step do
            local h = ed_terrain_get(x, z)
            if h then
                if not lo or h < lo then lo = h end
                if not hi or h > hi then hi = h end
            end
        end
    end
    return lo or 0, hi or 0
end
HeightRangeOf = HeightRange

--- The settings that follow from the map itself (size, playable area, water, ground heights, sun); `m` gets them, the rest stays.
function SyncFromMap(m)
    local w = ed_terrain_info()
    if not w then return end
    local size = w - 1
    local s = m.settings
    s.size = size
    local x0, z0, x1, z1 = import('/lua/editor/playable.lua').Get()
    s.playable_x0, s.playable_z0, s.playable_x1, s.playable_z1 = x0 or 0, z0 or 0, x1 or size, z1 or size
    local t = ed_world_get and ed_world_get() or {}
    if (t.water_on or 0) ~= 0 then
        s.water = t.water_elev or 0
        s.water_abyss = t.water_abyss or ((t.water_elev or 0) - 20)
        if s.water_abyss > s.water - 1 then s.water_abyss = s.water - 1 end
    else
        s.water, s.water_abyss, s.water_tint = nil, nil, nil
    end
    local lo, hi = HeightRange()
    s.ground_low, s.ground_high = lo, hi
    if t.sun_x then
        local len = math.sqrt(t.sun_x * t.sun_x + t.sun_y * t.sun_y + t.sun_z * t.sun_z)
        if len > 0.0001 then s.sun_x, s.sun_y, s.sun_z = t.sun_x / len, t.sun_y / len, t.sun_z / len end
    end
end

function FromMap()
    local m = New()
    SyncFromMap(m)
    return m
end

-- ---- checks ------------------------------------------------------------------------------------------------------------------------------

local function U32(s, at)
    local a, b, c, d = string.byte(s, at), string.byte(s, at + 1), string.byte(s, at + 2), string.byte(s, at + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function Exists(path)
    return ed_file_stamp(path) ~= nil
end

--- SCM v5 header: V1. Returns an error text or nil, plus vertex and triangle counts.
local function CheckScm(path)
    local data = ed_read_file(path)
    if not data then return 'file not found' end
    if string.sub(data, 1, 4) ~= 'MODL' then return 'not an SCM file (no MODL header)' end
    local version = U32(data, 5)
    if version ~= 5 then return 'SCM version ' .. tostring(version) .. ', the patch reads version 5' end
    local vertexAt, vertexCount, indexAt, indexCount = U32(data, 17), U32(data, 25), U32(data, 29), U32(data, 33)
    if not (vertexAt and vertexCount and indexAt and indexCount) then return 'header too short' end
    if vertexCount > 65535 then return vertexCount .. ' vertices (at most 65,535 per patch)' end
    if math.mod(indexCount, 3) ~= 0 then return 'index count ' .. indexCount .. ' is not a multiple of 3' end
    local size = string.len(data)
    if vertexAt + vertexCount * 68 > size then return 'vertex block runs past the end of the file' end
    if indexAt + indexCount * 2 > size then return 'index block runs past the end of the file' end
    for i = 0, indexCount - 1 do
        local a, b = string.byte(data, indexAt + i * 2 + 1), string.byte(data, indexAt + i * 2 + 2)
        if a + b * 256 >= vertexCount then return 'index ' .. i .. ' points past the last vertex' end
    end
    return nil, vertexCount, indexCount / 3
end

--- Checks the model against the open map and the files next to the manifest (`folder`: the map folder on disk; default the open map's).
function Check(m, folder, opts)
    local list = {}
    local function Add(sev, code, text) table.insert(list, { sev = sev, code = code, text = text }) end
    local s = m.settings
    -- V18: dialect
    for _, w in m.warnings do Add('E', 'V18', w) end
    -- V19: the scenario names the manifest
    local info = Map.Doc and Map.Doc.info
    if info then
        if info.TerrainSystem ~= 'mesh' then Add('E', 'V19', "ScenarioInfo.TerrainSystem is not 'mesh' (the patch ignores the manifest)") end
        local want
        local dir = Dir()
        if dir then want = '/maps/' .. string.lower((string.gsub(dir, '^.*/', ''))) .. '/terrain/terrain.lua' end
        if not info.TerrainMesh then
            Add('E', 'V19', 'ScenarioInfo.TerrainMesh is missing')
        elseif want and string.lower(info.TerrainMesh) ~= want then
            Add('E', 'V19', 'TerrainMesh is ' .. info.TerrainMesh .. ', the folder gives ' .. want)
        end
    end
    -- V11: size
    local w = ed_terrain_info()
    local mapSize = w and (w - 1)
    if not s.size then
        Add('E', 'V11', 'size is missing')
    elseif mapSize and s.size ~= mapSize then
        Add('E', 'V11', 'size ' .. s.size .. ' but the map is ' .. mapSize)
    end
    -- V9: playable rectangle
    local size = s.size or mapSize or 0
    local px0, pz0, px1, pz1 = s.playable_x0, s.playable_z0, s.playable_x1, s.playable_z1
    if px0 or pz0 or px1 or pz1 then
        px0, pz0, px1, pz1 = px0 or 0, pz0 or 0, px1 or size, pz1 or size
        if px0 < 0 or pz0 < 0 or px1 > size or pz1 > size then Add('E', 'V9', 'the playable rectangle leaves the map') end
        if px1 <= px0 or pz1 <= pz0 then Add('E', 'V9', 'the playable rectangle is empty (x1 <= x0 or z1 <= z0)') end
        local a0, b0, a1, b1, exists = import('/lua/editor/playable.lua').Get()
        if exists and (math.abs(a0 - px0) > 0.5 or math.abs(b0 - pz0) > 0.5 or math.abs(a1 - px1) > 0.5 or math.abs(b1 - pz1) > 0.5) then
            Add('E', 'V9', string.format('playable rectangle %.0f,%.0f - %.0f,%.0f differs from AREA_1 %.0f,%.0f - %.0f,%.0f', px0, pz0, px1, pz1, a0, b0, a1, b1))
        end
    end
    -- V12: water against the map
    local t = ed_world_get and ed_world_get() or {}
    local waterOn = (t.water_on or 0) ~= 0
    if s.water then
        if not waterOn then Add('E', 'V12', 'the manifest has water but the map has none') end
        if waterOn and math.abs((t.water_elev or 0) - s.water) > 0.01 then
            Add('E', 'V12', string.format('water %.2f but the map water elevation is %.2f', s.water, t.water_elev or 0))
        end
        if s.water_abyss and s.water_abyss >= s.water then Add('E', 'V12', 'water_abyss must be below water') end
    elseif waterOn then
        Add('W', 'V12', 'the map has water but the manifest has no water level')
    end
    if not s.water and (s.water_map or s.water_beyond or s.water_inside) then
        Add('E', 'V12', 'water files named without a water level')
    end
    -- V15 (part): the ground and mesh heights are ordered
    if s.ground_low and s.ground_high and s.ground_low > s.ground_high then Add('W', 'V15', 'ground_low is above ground_high') end
    if s.mesh_high and s.ground_high and s.mesh_high < s.ground_high then Add('W', 'V15', 'mesh_high is below ground_high') end
    -- V14: height field maximum
    if mapSize then
        local _, hi = HeightRange()
        if hi > 250 then Add('W', 'V14', string.format('the ground rises to %.0f (decals vanish beyond about 250)', hi)) end
    end
    -- the files
    local dir = folder or Dir()
    local tdir = dir and (dir .. '/terrain')
    local usedMaterial = {}
    local vertexTotal, patchCount = 0, 0
    local count = 0
    for _, p in m.patches do
        if not p.comment then count = count + 1 end
    end
    if count == 0 then Add('E', 'V2', 'the manifest names no patches (the patch keeps FA terrain)') end
    for i, p in m.patches do
        if not p.comment then
            patchCount = patchCount + 1
            local mat = p.material
            if not mat or mat < 1 or mat > table.getn(m.materials) then
                Add('E', 'V2', "patch '" .. tostring(p.mesh) .. "' uses material " .. tostring(mat) .. ' (the manifest has ' .. table.getn(m.materials) .. ')')
            else
                usedMaterial[mat] = true
            end
            if tdir and p.mesh then
                local err, vcount = CheckScm(tdir .. '/' .. p.mesh)
                if err then
                    Add('E', 'V1', p.mesh .. ': ' .. err)
                else
                    vertexTotal = vertexTotal + vcount
                    if p.vertices and p.vertices ~= vcount then Add('W', 'V1', p.mesh .. ': manifest says ' .. p.vertices .. ' vertices, the file has ' .. vcount) end
                end
            end
        end
    end
    for k, mat in m.materials do
        if not usedMaterial[k] then
            local name = ''
            for _, f in mat do if f[1] == 'name' then name = f[2] end end
            Add('W', 'V2', 'material ' .. k .. " '" .. name .. "' is not used by any patch")
        end
        -- V5: textures exist
        if tdir then
            for _, f in mat do
                if MATERIAL_SLOTS[f[1]] and not Exists(tdir .. '/' .. f[2]) then
                    Add('E', 'V5', "texture '" .. f[2] .. "' (" .. f[1] .. ', material ' .. k .. ') not found')
                end
            end
        end
    end
    -- water files (V5 / V13)
    if tdir then
        for _, key in { 'water_map', 'water_map_outer', 'water_beyond', 'water_inside' } do
            if s[key] and not Exists(tdir .. '/' .. s[key]) then Add('E', 'V5', key .. " '" .. s[key] .. "' not found") end
        end
        for _, pair in { { 'water_beyond', 'water_beyond_triangles' }, { 'water_inside', 'water_inside_triangles' } } do
            local file, n = s[pair[1]], s[pair[2]]
            if file and n and Exists(tdir .. '/' .. file) then
                local data = ed_read_file(tdir .. '/' .. file)
                if data and string.len(data) ~= n * 24 then
                    Add('E', 'V13', pair[1] .. ' has ' .. string.len(data) .. ' bytes, ' .. pair[2] .. ' = ' .. n .. ' needs ' .. n * 24)
                end
            end
        end
    end
    -- the vertex based checks (V3, V4, V10, V15): reads every patch
    if opts and opts.deep and tdir then
        local scan = import('/lua/editor/meshscan.lua').Scan(m, dir, opts)
        for _, f in scan.findings do
            if f.code ~= 'V1' then Add(f.sev, f.code, f.text) end
        end
        if scan.coverage and scan.coverage >= 99.9 then Add('I', 'V10', string.format('%.2f%% of the playable rectangle is covered by the mesh', scan.coverage)) end
    end
    -- V20: budget (informative)
    Add('I', 'V20', patchCount .. ' patches, ' .. vertexTotal .. ' vertices, ' .. table.getn(m.materials) .. ' materials')
    return list
end

--- Number of errors and warnings in a Check() result.
function Count(list)
    local e, w = 0, 0
    for _, i in list do
        if i.sev == 'E' then e = e + 1 elseif i.sev == 'W' then w = w + 1 end
    end
    return e, w
end
