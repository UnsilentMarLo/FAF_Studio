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
--                          upper = 'overlay' | 'specular' | 'atlas', alpha = 'spec' | 'matte' | 'glow' | 'unused' (the albedo alpha of the layers), supported, reason,
--                          class = 'legacy' | 'ext' | 'spec' | 'pbr' | 'splat' | 'old301' | 'other' (the family of texture layouts), maps = { normal, light, macro, specular } the map-wide
--                          pictures the shader reads and from which layer slot (maptextures.lua; a kind the shader does not use is missing) }
--   ClassOf(id)          the class of a shader ('legacy' for the empty name, as for a map without a shader)      MapSlots(class) -> the maps table of a class
--   RangeOf(id)          'half' or 'full': the encoding of the paint masks a shader reads (strata.lua uses it for every mask it reads or writes)
--   Mismatch()           nil, or { range, shader, now, current } when the paint masks are still in the range of `shader` (they were written for it) while the map's shader reads the range `now`: a plain
--                          Set(id) changes the technique only, so the paint looks different until Convert layers (stratumconv.lua) re-encodes the masks. Saved with the map (SidecarText / LoadSidecar,
--                          the `_editor.lua` file); MaskState() / SetMaskState(state) are for the undo of a conversion
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

-- ---- the layer tables ------------------------------------------------------------------------------------------------------------------------
-- One row per layer: what its albedo texture (colour) and its normal map hold for the shader. Derived from the layout tables above each shader family in effects/terrain.fx and from what the
-- pixel shaders read (where the comment and the code differ, the code wins). Layers 1-8 are the painted layers (strata 0-7 of the shader: its "S0".."S7"), Base is its "L", Upper its "U".

local function Row(layer, albedo, normal) return { layer = layer, albedo = albedo, normal = normal } end

local XYZ = 'XYZ'
local UNUSED = 'not used'
local SPEC = 'RGB, alpha = specularity'
local RGB = 'RGB (alpha not used)'

--- spec: base = { albedo, normal }, p = the cell of the painted layers 1-7, at[i] = a different cell for layer i, l8, upper.
local function MakeRows(spec)
    local rows = { Row('Base', spec.base[1], spec.base[2]) }
    for i = 1, 7 do
        local cell = (spec.at and spec.at[i]) or spec.p
        table.insert(rows, Row('Layer ' .. i, cell[1], cell[2]))
    end
    table.insert(rows, Row('Layer 8', spec.l8[1], spec.l8[2]))
    table.insert(rows, Row('Upper', spec.upper[1], spec.upper[2]))
    return rows
end

local NOT_DRAWN = { 'not drawn', 'not drawn' }
local OVERLAY = { 'RGB, alpha = opacity (laid over everything)', UNUSED }
local MATTE = 'RGB, alpha: specular amount = 1 - alpha'
local ROWS_LEGACY4 = MakeRows{ base = { MATTE, XYZ }, p = { MATTE, XYZ },
    at = { [5] = NOT_DRAWN, [6] = NOT_DRAWN, [7] = NOT_DRAWN }, l8 = NOT_DRAWN, upper = OVERLAY }
local ROWS_GLOW = MakeRows{ base = { MATTE, XYZ }, p = { MATTE, XYZ },
    at = { [1] = { 'RGB, alpha = glow mask (animated)', XYZ }, [5] = NOT_DRAWN, [6] = NOT_DRAWN, [7] = NOT_DRAWN }, l8 = NOT_DRAWN, upper = OVERLAY }
local ROWS_XP = MakeRows{ base = { SPEC, XYZ }, p = { SPEC, XYZ }, l8 = { SPEC, XYZ }, upper = OVERLAY }
local ROWS_EXT = MakeRows{ base = { SPEC, XYZ }, p = { SPEC, XYZ },
    l8 = { 'map-wide data when its tile size is below 1: R water depth, G occlusion, A shadow', UNUSED },
    upper = { 'macrotexture RGB, alpha = opacity', UNUSED } }
local ROWS_SPEC = MakeRows{ base = { 'RGB, alpha = macrotexture opacity (drawn over everything again)', XYZ }, p = { RGB, XYZ },
    l8 = { 'map-wide data: alpha = baked shadow (always read)', UNUSED },
    upper = { 'specular RGB, alpha = sharpness', UNUSED } }

local ROWS_301 = MakeRows{ base = { RGB, XYZ }, p = { RGB, XYZ },
    l8 = { 'map-wide colour RGB, alpha = opacity', 'atlas: roughness in G and A, height in R and B' },
    upper = { 'B = water depth', UNUSED } }

local function RowsPbr(macro, biplanar, splat)
    local cliff = biplanar and { 'RGB, also mapped from the side (cliffs)', 'XYZ, also mapped from the side' } or nil
    return MakeRows{ base = { macro and 'RGB, alpha = macrotexture opacity' or RGB, XYZ }, p = { RGB, XYZ },
        at = cliff and { [3] = cliff, [4] = cliff } or nil,
        l8 = biplanar and { 'R = water depth (map-wide data)', 'terrain normal Z / X (map-wide data)' } or { UNUSED, UNUSED },
        upper = { splat and 'roughness and height atlas' or 'roughness atlas', UNUSED } }
end

local NOTE_ATLAS = 'Upper atlas: 2 x 2 tiles. The tile of the Base layer and layers 1-3 (top left, top right, bottom left, bottom right) hold their roughness in R and their height in G; layers 4-7 use the same tiles in B (roughness) and A (height).'
local NOTE_ROUGH = 'Layer 8 has no paint: its mask is a roughness multiplier (128 = neutral, lower = shinier, higher = rougher).'

-- The map-wide pictures (maptextures.lua) by class: the layer slot (an index of ed_stratum_layer: 0..9 albedo, 10..19 normal) the shader reads each kind from, how the editor packs the channels
-- (`pack`), whether the layer's tile size has to exceed the map for the shader to use it (`tile`: terrain.fx ShaderUsesTerrainInfoTexture / UseMapNormalFromTexture), and the texts of the panel.
local N7 = { layer = 18, pack = 'normal7', tile = true, where = 'normal map of layer 8', layout = 'A = normal x, R = G = B = normal z' }
local L7 = { layer = 8, pack = 'info7', tile = true, where = 'albedo of layer 8', layout = 'R = water depth, G = B = ambient occlusion, A = sun (1) or shadow (0)' }
local MAPS = {
    ext = { normal = N7, light = L7, macro = { layer = 9, pack = 'raw', where = 'albedo of the Upper layer', layout = 'RGB = colour, A = opacity' } },
    spec = { normal = N7, light = L7, specular = { layer = 9, pack = 'raw', where = 'albedo of the Upper layer', layout = 'RGB = specular colour, A = sharpness' } },
    pbr = { normal = N7, light = L7 },
    splat = { normal = N7, light = L7 },
    old301 = { light = { layer = 9, pack = 'light301', tile = true, where = 'albedo of the Upper layer', layout = 'R = normal x, G = normal z, B = water depth, A = sun (1) or shadow (0)' } },
    legacy = {},
    other = {},
}
MAPS.old301.normal = { layer = 9, pack = 'light301', tile = true, shared = 'light', where = 'albedo of the Upper layer (with the lighting)', layout = MAPS.old301.light.layout }

--- The map-wide pictures a class of shaders reads (see above).
function MapSlots(class)
    return MAPS[class] or MAPS.other
end

local function Prof(range, painted, l8, upper, alpha, class)
    return { range = range, painted = painted, l8 = l8, upper = upper, alpha = alpha, supported = true, class = class, maps = MapSlots(class) }
end

local LAYOUT_OLD = 'Layers: Base, painted layers 1-4, Upper. Albedo RGB plus an alpha that sets the specular amount; normals X Y Z.'
local LAYOUT_XP = 'Layers: Base, painted layers 1-8, Upper. Albedo RGB plus alpha = specularity; normals X Y Z. The Upper layer is an overlay whose alpha is its opacity.'
local LAYOUT_EXT = 'Layers: Base, painted layers 1-7 (the 8th is not painted), Upper. Albedo RGB plus alpha = specularity; normals X Y Z. The Upper layer is a macrotexture (RGB) with its opacity in alpha. ' ..
                   'The map\'s own normal map and shadow map are used (the engine writes them).'
local LAYOUT_SPEC = 'Layers: Base, painted layers 1-7, Upper. Albedo RGB; normals X Y Z. The Upper layer is the specular texture of the whole map: specular colour RGB and sharpness in alpha. The 8th layer\'s albedo alpha is read as the baked shadow.'
local LAYOUT_PBR = 'Layers: Base, painted layers 1-7, Upper. Albedo RGB; normals X Y Z. The roughness of every layer comes from the Upper layer, a small atlas texture, not from the albedo alpha. The mask of layer 8 is not painted: it is a roughness multiplier (128 = neutral).'
local LAYOUT_SPLAT = 'Layers: Base, painted layers 1-7, Upper. Albedo RGB; normals X Y Z. Roughness and the heights used for splatting come from the Upper layer, a small atlas texture, not from the albedo alpha or the normal alpha. ' ..
                     'The mask of layer 8 is a roughness multiplier (128 = neutral). The normal tile sizes follow the albedo tile sizes (except on the base layer).'

local Info = {
    TTerrain = { family = 'legacy', summary = 'The shader of the original Supreme Commander.', mask = 'half',
        instructions = 'Blends only the painted layers 1-4 over the base layer; layers 5-8 are not drawn. Choose it only for a map that has to look like the original game. Use TTerrainXP for everything else. ' ..
                       'The alpha of the albedo textures works the other way round than in TTerrainXP: the specular amount is 1 - alpha.',
        layout = LAYOUT_OLD, rows = ROWS_LEGACY4, profile = Prof('half', 4, 'none', 'overlay', 'matte', 'legacy'),
        notes = { 'Only layers 1-4 are blended; paint on layers 5-8 is not drawn.' } },
    TTerrainXP = { family = 'legacy', summary = 'The Forged Alliance shader: the default of nearly every map.', mask = 'half',
        instructions = 'Blends all eight painted layers and the upper layer. Masks are read as saturate(2 * m - 1), so the paint brushes store half-range masks (what the editor does for you). ' ..
                       'Normals are blended by simple lerps; they read the mask without the half-range conversion, so they follow the paint a little more broadly than the colours.',
        layout = LAYOUT_XP, rows = ROWS_XP, profile = Prof('half', 8, 'paint', 'overlay', 'spec', 'legacy'),
        notes = { 'Masks use the half range: a byte up to 127 means "none", 255 means "fully this layer".' } },
    TTerrainGlow = { family = 'legacy', summary = 'TTerrain where the alpha of the first painted layer is animated as a glow.', mask = 'half',
        instructions = 'Like TTerrain (painted layers 1-4) but the alpha of the first painted layer\'s texture is animated and used as a glow channel. Use it for lava or energy ground; give that layer an albedo whose alpha is the glow mask.',
        layout = LAYOUT_OLD, rows = ROWS_GLOW, profile = Prof('half', 4, 'none', 'overlay', 'glow', 'legacy'),
        notes = { 'Only layers 1-4 are blended; paint on layers 5-8 is not drawn.' } },
    TTerrainXPExt = { family = 'ext', summary = 'Drop-in replacement for TTerrainXP that adds the map-wide normals and shadows.', mask = 'mixed',
        instructions = 'Keeps the different mask ranges of TTerrainXP (half range for albedo, full for normals), so an existing map looks the same. Choose it to upgrade a TTerrainXP map without repainting.',
        layout = LAYOUT_EXT, rows = ROWS_EXT, profile = Prof('half', 7, 'data', 'overlay', 'spec', 'ext'),
        notes = { 'Layer 8 has no paint. Masks use the half range for the colours and the full range for the normals, like TTerrainXP.' } },
    Terrain000 = { family = 'ext', summary = 'Like TTerrainXPExt, with the full mask range for albedo and normals.', mask = 'full',
        instructions = 'Both albedo and normals use the whole mask range (0-255). Paint layers normally; there is no half-range conversion. Good for new maps that only need the extended shader.',
        layout = LAYOUT_EXT, rows = ROWS_EXT, profile = Prof('full', 7, 'data', 'overlay', 'spec', 'ext'),
        notes = { 'Layer 8 has no paint. Masks use the full range: the byte is the share of the layer.' } },
    Terrain050 = { family = 'ext', summary = 'Like Terrain000, but only the upper half of the mask range counts.', mask = 'half',
        instructions = 'Uses only the upper half of the mask range, which is what maps made for TTerrainXP store. Easiest choice when converting an existing map.',
        layout = LAYOUT_EXT, rows = ROWS_EXT, profile = Prof('half', 7, 'data', 'overlay', 'spec', 'ext'),
        notes = { 'Layer 8 has no paint. Masks use the half range: a byte up to 127 means "none".' } },
    Terrain001 = { family = 'ext', summary = 'UDN normal blending and a specularity texture on the upper layer.', mask = 'full',
        instructions = 'Normals are blended with UDN blending. The base layer\'s albedo is drawn first and blended over everything again by its alpha. The upper layer is not a macrotexture: its RGB is the specular colour and its alpha the specular sharpness, which gives fine control over the shine of the whole map.',
        layout = LAYOUT_SPEC, rows = ROWS_SPEC, profile = Prof('full', 7, 'data', 'specular', 'unused', 'spec'),
        notes = { 'Layer 8 has no paint. Masks use the full range.' } },
    Terrain051 = { family = 'ext', summary = 'Terrain001 with only the upper half of the mask range.', mask = 'half',
        instructions = 'As Terrain001, but only the upper half of the mask range counts (maps converted from TTerrainXP).',
        layout = LAYOUT_SPEC, rows = ROWS_SPEC, profile = Prof('half', 7, 'data', 'specular', 'unused', 'spec'),
        notes = { 'Layer 8 has no paint. Masks use the half range.' } },
    Terrain301 = { family = 'old', summary = 'Height splatting, the first version (kept for old maps).', mask = 'half',
        instructions = 'The earlier form of the splatting of the 2xx shaders. Prefer Terrain200 / Terrain250 for new maps. It uses an older texture layout (the roughness atlas is in the normal map of layer 8, the water depth in the Upper layer), so the editor does not convert layers to or from it.',
        layout = 'Layers: Base, painted layers 1-7. The atlas for roughness and height is in the normal map of layer 8; layer 8\'s albedo is a map-wide colour with its opacity in alpha; the Upper layer holds the water depth in its blue channel.',
        rows = ROWS_301, notes = { 'Layer 8 has no paint: its mask is a roughness multiplier (128 = neutral).', 'Masks use the half range.' },
        profile = { supported = false, range = 'half', painted = 7, l8 = 'rough', upper = 'atlas', alpha = 'unused', class = 'old301', maps = MapSlots('old301'),
                    reason = 'Terrain301 uses an older texture layout (the atlas is in the normal map of layer 8)' } },
}

local function PbrInfo(name)
    local digit, mid, last = string.sub(name, 8, 8), string.sub(name, 9, 9), string.sub(name, 10, 10)
    local biplanar = string.sub(name, -1) == 'B'
    local tail = last
    local macro = ({ ['0'] = 'no macrotexture', ['1'] = 'the base layer\'s texture is blended over the map by its alpha as a macrotexture',
                     ['2'] = 'the base layer\'s texture multiplies the map by its alpha as a macrotexture' })[tail]
    local splat = digit == '2'
    local half = mid == '5'
    local text = (splat and 'PBR lighting with height-based splatting: layers are mixed by comparing heights (from the Upper atlas), so ground shows through rock and mud collects in dips. ' or
                  'PBR lighting (roughness from the Upper atlas) with UDN normal blending. ') ..
                 (half and 'Only the upper half of the mask range counts. ' or 'Full mask range. ') ..
                 (biplanar and 'Biplanar mapping: steep ground is textured from the side, so cliffs are not stretched. Put the cliff textures on layers 3 and 4. ' or '') ..
                 (macro and ('Macrotexture: ' .. macro .. '.') or '')
    local notes = { half and 'Masks use the half range: a byte up to 127 means "none".' or 'Masks use the full range: the byte is the share of the layer.', NOTE_ROUGH, NOTE_ATLAS }
    return { family = splat and 'splat' or 'pbr', mask = half and 'half' or 'full',
             summary = (splat and 'Height splatting' or 'PBR') .. (biplanar and ', biplanar' or '') .. (half and ', half mask range' or ', full mask range') .. (macro and ('; ' .. macro) or ''),
             instructions = text .. (splat and ' SpecularColor.r (the map\'s specular colour, Lighting panel) sets how soft the splat transitions are; SpecularColor.g raises the contrast of the height texture. Loading the same texture into two neighbouring layers lets the shader rotate every second one and hides tiling.' or ''),
             layout = splat and LAYOUT_SPLAT or LAYOUT_PBR, rows = RowsPbr(tail ~= '0', biplanar, splat), notes = notes,
             profile = Prof(half and 'half' or 'full', 7, 'rough', 'atlas', 'unused', splat and 'splat' or (digit == '1' and 'pbr' or 'other')) }
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

local UNKNOWN_PROFILE = { supported = false, range = 'half', painted = 8, l8 = 'paint', upper = 'overlay', alpha = 'spec', class = 'other', maps = MAPS.other,
                          reason = 'the editor has no notes about this shader' }

local function Entry(name)
    local e = Info[name]
    if not e and string.find(name, '^Terrain[123]%d%dB?$') then e = PbrInfo(name) end
    return e
end

local function Describe(name, normals)
    local e = Entry(name)
    local listed = e ~= nil
    e = e or { family = 'old', summary = 'A terrain shader of this game version without a description here.',
               instructions = 'This technique is in effects/terrain.fx but the editor has no notes about it. Read the comment above it in the shader file for its texture layout; the usual layers (base, painted layers, upper) apply.',
               layout = '' }
    return { id = name, name = name, family = e.family, summary = e.summary, instructions = e.instructions .. (string.find(name, '^Terrain%d') and ('\n' .. NAMING) or ''),
             layout = e.layout, mask = e.mask or '', normals = normals or '', listed = listed, rows = e.rows, notes = e.notes or {}, profile = e.profile or UNKNOWN_PROFILE }
end

local profiles = {}

--- What the mask bytes and layers mean for a shader (see the header). A shader nobody described gets the TTerrainXP profile with supported = false.
function Profile(id)
    local p = profiles[id]
    if not p then
        local e = Entry(tostring(id))
        p = e and e.profile or UNKNOWN_PROFILE
        profiles[id] = p
    end
    return p
end

--- The class of a shader ('legacy', 'ext', 'spec', 'pbr', 'splat', 'old301' or 'other'): the empty name (no shader) counts as 'legacy'.
function ClassOf(id)
    if id == nil or id == '' then return 'legacy' end
    return Profile(id).class or 'other'
end

--- The encoding of the paint masks a shader reads: 'half' (saturate(2m - 1): bytes up to 127 mean nothing) or 'full' (the byte is the share). The editor stores every mask in the encoding of
--- the map's shader, so a shader that is not described counts as 'half' (what every map had until the numbered shaders).
function RangeOf(id)
    return Profile(id).range or 'half'
end

--- The layer table of a shader: Base, Layer 1-8, Upper as { layer, albedo, normal }; nil for a shader nobody described.
function Rows(id)
    local e = Entry(tostring(id))
    return e and e.rows or nil
end

--- The lines shown under the layer table.
function Notes(id)
    local e = Entry(tostring(id))
    return e and e.notes or {}
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
    local old = ed_stratum_shader()
    ed_stratum_shader(id)
    NoteSwitch(old, id)
    return true
end

-- ---- the range the paint masks were written for ----------------------------------------------------------------------------------------------------
-- Set() only changes the technique. When the new shader reads a mask byte in another range than the old one, the bytes stay as they were: the paint looks different (half range: bytes up to 127
-- mean "none"). `authored` remembers the range (and the shader) the masks are really in until they match the map's shader again (a switch back, or Convert layers). It is the minimal state
-- for the Layers panel's warning; the convert plan (stratumconv.lua) takes the layer roles from the authored shader.

local authored = false          -- false | { range = 'half' | 'full', shader = id }

--- Called by Set(old, new): remembers the range of the first shader the masks were made for; forgets it when the new shader reads that range.
function NoteSwitch(old, new)
    if not old or old == new then return end
    if not authored then authored = { range = RangeOf(old), shader = old } end
    if RangeOf(new) == authored.range then authored = false end
end

function MaskState()
    if not authored then return false end
    return { range = authored.range, shader = authored.shader }
end

function SetMaskState(state)
    authored = state and { range = state.range, shader = state.shader } or false
end

function Mismatch()
    if not authored then return nil end
    local cur = Current()
    if not cur then return nil end
    local now = RangeOf(cur)
    if now == authored.range then return nil end
    return { range = authored.range, shader = authored.shader, now = now, current = cur }
end

--- The saved form: nothing for a map whose masks match its shader.
function SidecarText()
    if not authored then return '' end
    return import('/lua/editor/luaser.lua').Chunk({ { 'StrataAuthored', { range = authored.range, shader = authored.shader } } })
end

--- Reads the sidecar of a map (a new map or one without the entry: the masks match).
function LoadSidecar(scenarioFile)
    authored = false
    local path = scenarioFile and import('/lua/editor/mods.lua').SidecarPath(scenarioFile)
    if not path or not DiskGetFileInfo(path) then return end
    local env = {}
    doscript(path, env)
    local d = env.StrataAuthored
    if type(d) == 'table' and (d.range == 'half' or d.range == 'full') and type(d.shader) == 'string' then
        authored = { range = d.range, shader = d.shader }
    end
end
