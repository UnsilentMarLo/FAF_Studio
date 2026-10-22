-- The terrain shaders a map can use (the technique named in the .scmap: ed_stratum_shader) with what the mapper has to know about each: what it does, how its textures have to be made.
-- The information comes from the shader source (effects/terrain.fx: its layout tables and the comments of each family) and the engine; the list is completed from the file the game
-- really loads (Discover), so a shader FAF adds later shows up with its name even before it has a description here.
--
--   Families             list of { id, label, summary, instructions, layers, order }: the groups of the browser's sidebar
--   List()               every shader as { id, name, family, summary, instructions, layout, mask, normals, listed }, sorted by family and name
--   Find(id)             one entry (an id nobody knows gets a plain entry)
--   Current()            the shader of the open map;   Set(id) -> true | nil, message     changes it (the terrain re-reads the technique on the next frame)
--   Discover()           the composite terrain techniques found in effects/terrain.fx: { name = normalsTechnique }
--   Profile(id)          what the mask bytes and layers mean for a shader: { range = 'half' | 'full' (how the albedo pass reads a mask byte: saturate(2m - 1) or m), painted = 4 | 7 | 8 (painted layers it blends),
--                          l8 = 'paint' | 'rough' | 'data' | 'none' (what layer 8 is: a painted layer, the roughness multiplier mask, map-wide data in its textures, not drawn),
--                          upper = 'overlay' | 'specular' | 'atlas', alpha = 'spec' | 'matte' | 'glow' | 'unused' (the albedo alpha of the layers), supported, reason }
--   RangeOf(id)          'half' or 'full': the encoding of the paint masks a shader reads (strata.lua uses it for every mask it reads or writes)
--   Rows(id)             the layer table of a shader: { { layer, albedo, normal }, ... } Base, Layer 1-8, Upper;  Notes(id): the lines under it
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

Families = {
    { id = 'legacy', label = 'Original', order = 1 },
    { id = 'ext', label = 'Extended (0xx)', order = 2 },
    { id = 'pbr', label = 'PBR (1xx)', order = 3 },
    { id = 'splat', label = 'PBR + height splatting (2xx)', order = 4 },
    { id = 'old', label = 'Older / special', order = 5 },
}

-- how the last digits of the numbered shaders read, from the naming convention at the top of the family in terrain.fx
local NAMING = 'Naming: the first digit is the lighting (0 = the old specularity, 1 = PBR roughness, 2 = PBR roughness and height splatting); the middle digit 0 = the full mask range, 5 = only the upper half of it; ' ..
               'a letter B at the end means biplanar mapping (steep ground is textured from the side).'

local LAYOUT_OLD = 'Albedo: R G B + A = specularity (lower layer, painted layers, upper layer). Normal: X Y Z.'
local LAYOUT_XP = 'Layers: Base (lower), painted layers 1-4 and 5-8, Upper. Albedo RGB + alpha = specularity; normals X Y Z.'
local LAYOUT_EXT = 'Layers: Base (lower), painted layers 1-7 (the 8th is not used), Upper. Albedo RGB + alpha = specularity; normals X Y Z. The upper layer is a macrotexture (RGB) with its opacity in alpha. ' ..
                   'The map\'s own normal map and shadow map are used (the engine writes them).'
local LAYOUT_PBR = 'Layers: Base, painted layers 1-7, Upper. Albedo RGB + alpha = roughness; normals X Y Z. The mask of layer 8 is not painted: it acts as a roughness multiplier (0.5 = neutral).'
local LAYOUT_SPLAT = 'Layers: Base, painted layers 1-7, Upper. Albedo RGB; the normal map\'s alpha holds the height used for splatting. The mask of layer 8 is a roughness multiplier (0.5 = neutral). ' ..
                     'The normal tile sizes follow the albedo tile sizes (except on the base layer).'

local Info = {
    TTerrain = { family = 'legacy', summary = 'The shader of the original Supreme Commander.', mask = 'full',
        instructions = 'Blends only the painted layers 1-4 over the base layer; layers 5-8 are not drawn. Choose it only for a map that has to look like the original game. Use TTerrainXP for everything else.',
        layout = LAYOUT_OLD },
    TTerrainXP = { family = 'legacy', summary = 'The Forged Alliance shader: the default of nearly every map.', mask = 'full',
        instructions = 'Blends all eight painted layers and the upper layer. Masks are read as saturate(2 * m - 1), so the paint brushes store half-range masks (what the editor does for you). Normals are blended by simple lerps.',
        layout = LAYOUT_XP },
    TTerrainGlow = { family = 'legacy', summary = 'TTerrain where the alpha of the first painted layer is animated as a glow.', mask = 'full',
        instructions = 'Like TTerrain (painted layers 1-4) but the alpha of the first painted layer\'s texture is animated and used as a glow channel. Use it for lava or energy ground; give that layer an albedo whose alpha is the glow mask.',
        layout = LAYOUT_OLD },
    TTerrainXPExt = { family = 'ext', summary = 'Drop-in replacement for TTerrainXP that adds the map-wide normals and shadows.', mask = 'mixed',
        instructions = 'Keeps the different mask ranges of TTerrainXP (half range for albedo, full for normals), so an existing map looks the same. Choose it to upgrade a TTerrainXP map without repainting.',
        layout = LAYOUT_EXT },
    Terrain000 = { family = 'ext', summary = 'Like TTerrainXPExt, with the full mask range for albedo and normals.', mask = 'full',
        instructions = 'Both albedo and normals use the whole mask range (0-255). Paint layers normally; there is no half-range conversion. Good for new maps that only need the extended shader.',
        layout = LAYOUT_EXT },
    Terrain050 = { family = 'ext', summary = 'Like Terrain000, but only the upper half of the mask range counts.', mask = 'half',
        instructions = 'Uses only the upper half of the mask range, which is what maps made for TTerrainXP store. Easiest choice when converting an existing map.',
        layout = LAYOUT_EXT },
    Terrain001 = { family = 'ext', summary = 'UDN normal blending and a specularity texture on the upper layer.', mask = 'full',
        instructions = 'Normals are blended with UDN blending. The base layer\'s albedo is drawn first and blended over everything again by its alpha. The upper layer is not a macrotexture: its RGB is the specular colour and its alpha the specular sharpness, which gives fine control over the shine of the whole map.',
        layout = 'Layers: Base, painted layers 1-7, Upper. Albedo RGB + alpha = specularity; normals X Y Z. Upper layer: specular RGB + specular sharpness in alpha.' },
    Terrain051 = { family = 'ext', summary = 'Terrain001 with only the upper half of the mask range.', mask = 'half',
        instructions = 'As Terrain001, but only the upper half of the mask range counts (maps converted from TTerrainXP).',
        layout = 'Layers: Base, painted layers 1-7, Upper. Albedo RGB + alpha = specularity; normals X Y Z. Upper layer: specular RGB + specular sharpness in alpha.' },
    Terrain301 = { family = 'old', summary = 'Height splatting, the first version (kept for old maps).', mask = 'half',
        instructions = 'The earlier form of the splatting of the 2xx shaders. Prefer Terrain200 / Terrain250 for new maps.',
        layout = LAYOUT_SPLAT },
}

local function PbrInfo(name)
    local digit, mid, last = string.sub(name, 8, 8), string.sub(name, 9, 9), string.sub(name, 10, 10)
    local biplanar = string.sub(name, -1) == 'B'
    local tail = last
    local macro = ({ ['0'] = 'no macrotexture', ['1'] = 'the base layer\'s texture is blended over the map by its alpha as a macrotexture',
                     ['2'] = 'the base layer\'s texture multiplies the map by its alpha as a macrotexture' })[tail]
    local splat = digit == '2'
    local half = mid == '5'
    local text = (splat and 'PBR lighting with height-based splatting: layers are mixed by comparing heights (the alpha of the normal maps), so ground shows through rock and mud collects in dips. ' or
                  'PBR lighting (roughness in the albedo alpha) with UDN normal blending. ') ..
                 (half and 'Only the upper half of the mask range counts. ' or 'Full mask range. ') ..
                 (biplanar and 'Biplanar mapping: steep ground is textured from the side, so cliffs are not stretched. Put the cliff texture on layer 4. ' or '') ..
                 (macro and ('Macrotexture: ' .. macro .. '.') or '')
    return { family = splat and 'splat' or 'pbr', mask = half and 'half' or 'full',
             summary = (splat and 'Height splatting' or 'PBR') .. (biplanar and ', biplanar' or '') .. (half and ', half mask range' or ', full mask range') .. (macro and ('; ' .. macro) or ''),
             instructions = text .. (splat and ' SpecularColor.r (the map\'s specular colour, Lighting panel) sets how soft the splat transitions are; SpecularColor.g raises the contrast of the height texture. Loading the same texture into two neighbouring layers lets the shader rotate every second one and hides tiling.' or ''),
             layout = splat and LAYOUT_SPLAT or LAYOUT_PBR }
end

--- The terrain techniques with usage "composite" of the shader file the game loads: { name = normals technique }.
function Discover()
    local found = {}
    local ok, text = pcall(function()
        local disk = ed_vfs_to_disk('/effects/terrain.fx')
        return disk and ed_read_file(disk)
    end)
    if not ok or not text then return found end
    local pos = 1
    while true do
        local s, e, name = string.find(text, 'technique%s+([%w_]+)%s*<', pos)
        if not s then break end
        local close = string.find(text, '>', e, true)
        local block = close and string.sub(text, e, close) or ''
        if string.find(block, 'usage%s*=%s*"composite"') then
            local _, _, normals = string.find(block, 'normals%s*=%s*"([%w_]+)"')
            found[name] = normals or ''
        end
        pos = (close or e) + 1
    end
    return found
end

local function Describe(name, normals)
    local e = Info[name]
    if not e and string.find(name, '^Terrain[123]%d%dB?$') then e = PbrInfo(name) end
    local listed = e ~= nil
    e = e or { family = 'old', summary = 'A terrain shader of this game version without a description here.',
               instructions = 'This technique is in effects/terrain.fx but the editor has no notes about it. Read the comment above it in the shader file for its texture layout; the usual layers (base, painted layers, upper) apply.',
               layout = '' }
    return { id = name, name = name, family = e.family, summary = e.summary, instructions = e.instructions .. (string.find(name, '^Terrain%d') and ('\n' .. NAMING) or ''),
             layout = e.layout, mask = e.mask or '', normals = normals or '', listed = listed }
end

--- Every shader: the ones described above that the game's shader file has (or all of them when it cannot be read), plus the ones only the file has.
function List()
    local found = Discover()
    local list, seen = {}, {}
    local any = next(found) ~= nil
    for name, _ in Info do
        if not any or found[name] then
            seen[name] = true
            table.insert(list, Describe(name, found[name]))
        end
    end
    for name, normals in found do
        if not seen[name] then
            seen[name] = true
            table.insert(list, Describe(name, normals))
        end
    end
    -- the numbered families the game does not have are not listed; when the file cannot be read the common ones still are
    local order = {}
    for _, f in Families do order[f.id] = f.order end
    table.sort(list, function(a, b)
        local oa, ob = order[a.family] or 9, order[b.family] or 9
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)
    return list
end

function Find(id)
    for _, s in List() do
        if s.id == id then return s end
    end
    return Describe(id, '')
end

function Current()
    if rawget(_G, 'ed_stratum_shader') then return ed_stratum_shader() end
    return nil
end

--- Changes the terrain shader. The names are techniques of effects/terrain.fx; one the file does not have is refused (the terrain would be drawn with nothing).
function Set(id)
    if not rawget(_G, 'ed_stratum_shader') then return nil, 'no terrain' end
    local found = Discover()
    if next(found) and not found[id] then return nil, 'the shader file of this game version has no terrain shader named ' .. tostring(id) end
    ed_stratum_shader(id)
    return true
end
