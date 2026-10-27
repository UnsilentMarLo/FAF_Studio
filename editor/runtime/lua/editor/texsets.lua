-- Texture sets: ready-made choices of terrain textures for the painted layers, so a new map and the generators (terrain graph outputs, mask generator) paint with something instead of
-- empty layers. A set gives every painted layer (1..8) a texture by ROLE, the base layer (0) and the upper layer (9, the macrotexture); the generators name a role, not a file:
--
--   layer  1 grass   2 rock   3 sand (the shore)   4 dirt   5 wet ground   6 high rock   7 dark rock (cavities)   8 snow
--
--   Themes, ThemeOrder      the sets: { label, base, upper, grass = { candidate paths }, rock = ..., ... } (the first path that exists in the game data is used)
--   Roles, RoleLabels       the role names in layer order and their labels
--   Theme / SetTheme(id)    the theme roles are looked up in (what the last Apply or the map was given; Temperate until chosen)
--   TextureFor(role[, theme])  the path of a role in a theme (nil when none of its candidates exists)
--   Apply(themeId)          gives layers 0..9 the textures of a theme (the masks stay as they are); -> number of layers set. Tile sizes come from texscale.lua (Optimal for each texture;
--                           the theme's `size` is only the fallback for a texture that cannot be read; the Upper layer's tile is a golden ratio power of the base tile). The shader of the map decides which: the numbered shaders
--                           (Terrain0xx / 1xx / 2xx) have no painted 8th layer (its textures hold map-wide data) and the 1xx / 2xx / x01 ones no overlay on the Upper layer: those are left alone
--   ApplyRole(layer, role)  gives one painted layer the texture of a role (keeps its mask) at its Optimal tile size; -> true | nil, message
--   ApplyIfNew()            the first thing a new map gets: the default set, when its painted layers have no texture (called by Map.Load)
--   RoleChoices()           ids and labels for a choice parameter: 'keep' (leave the layer's texture) and every role
--   Layout(profile)        the painted layer of every role for a shader (shaders.lua Profile; the map's shader when nil): { role = layer }. The standard layout above for the eight painted layers of
--                          TTerrainXP; the seven layers of the numbered shaders have no dark rock and put snow on layer 7; TTerrain / TTerrainGlow paint four layers (rock, sand, dirt, snow; grass is the base);
--                          the biplanar shaders draw layers 3 and 4 from the side only, so rock and high rock go there and sand and dirt move out of them
--   RoleLayer(role[, profile])  the painted layer a role has in that layout, nil when the shader has no layer for it (recipes.lua AutoLayers)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

Roles = { 'grass', 'rock', 'sand', 'dirt', 'wet', 'highrock', 'darkrock', 'snow' }
RoleLabels = { grass = 'Grass', rock = 'Rock (cliffs)', sand = 'Sand (shore)', dirt = 'Dirt', wet = 'Wet ground', highrock = 'High rock', darkrock = 'Dark rock', snow = 'Snow' }

DEFAULT = 'valley'          -- the set a new map gets: green hills against tan plains read well; Temperate (olive grass, brown dirt) is still in the list
Theme = DEFAULT

Themes = {
    temperate = { label = 'Temperate (Evergreen)', size = 12,
        base = { '/env/Evergreen/layers/grass001_albedo.dds' }, upper = { '/env/Evergreen/layers/macrotexture000_albedo.dds' },
        grass = { '/env/Evergreen/layers/grass000_albedo.dds', '/env/Evergreen/layers/grass001_albedo.dds' },
        rock = { '/env/Evergreen/layers/RockMed_albedo.dds' }, sand = { '/env/Evergreen/layers/SandLight_albedo.dds' },
        dirt = { '/env/Evergreen/layers/Dirt001_albedo.dds' }, wet = { '/env/Evergreen/layers/Sandwet_albedo.dds' },
        highrock = { '/env/Evergreen/layers/RockLight_albedo.dds' }, darkrock = { '/env/Evergreen/layers/SandRock_albedo.dds' },
        snow = { '/env/Evergreen/layers/snow001_albedo.dds' } },
    -- the textures of a reference map that looks right (docs/projects/editor/GRAPH_TEXTURING.md): deep green grass against light tan gravel is the contrast, the rock is grey
    valley = { label = 'Open valley (Evergreen 2: green hills, tan plains)', size = 12,
        base = { '/env/Evergreen2/Layers/EvGrass005a_albedo.dds', '/env/Evergreen2/Layers/EG_Grass001_albedo.dds', '/env/Evergreen/layers/grass001_albedo.dds' }, upper = { '/env/Evergreen/layers/macrotexture000_albedo.dds' },
        grass = { '/env/Evergreen2/Layers/EvGrass005a_albedo.dds', '/env/Evergreen2/Layers/EG_Grass001_albedo.dds', '/env/Evergreen/layers/grass000_albedo.dds' },
        rock = { '/env/Evergreen2/Layers/EvRock006c_albedo.dds', '/env/Evergreen2/Layers/EG_Rock_albedo.dds', '/env/Evergreen/layers/RockMed_albedo.dds' },
        sand = { '/env/Evergreen2/Layers/EV_Reef_sand_albedo.dds', '/env/Evergreen/layers/SandLight_albedo.dds' },
        dirt = { '/env/Desert/Layers/Des_Gravel01_albedo.dds', '/env/Evergreen2/Layers/Eg_Gravel01_albedo.dds', '/env/Evergreen/layers/Dirt001_albedo.dds' },
        wet = { '/env/Evergreen2/Layers/Eg_Dirt003_albedo.dds', '/env/Evergreen2/Layers/Eg_Dirt001_albedo.dds', '/env/Evergreen/layers/Sandwet_albedo.dds' },
        highrock = { '/env/Evergreen2/Layers/EvRock002_albedo.dds', '/env/Evergreen2/Layers/EG_Rock_albedo.dds', '/env/Evergreen/layers/RockLight_albedo.dds' },
        darkrock = { '/env/Evergreen2/Layers/EvRock008_albedo.dds', '/env/Evergreen2/Layers/EvRock004_albedo.dds', '/env/Evergreen/layers/SandRock_albedo.dds' },
        snow = { '/env/Evergreen2/Layers/EG_Snow_albedo.dds', '/env/Evergreen/layers/snow001_albedo.dds' } },
    desert = { label = 'Desert', size = 14,
        base = { '/env/Desert/Layers/Des_SandMed_albedo.dds' }, upper = { '/env/Evergreen/layers/macrotexture000_albedo.dds' },
        grass = { '/env/Desert/Layers/Des_SandMed02_albedo.dds', '/env/Desert/Layers/Des_SandMed_albedo.dds' },
        rock = { '/env/Desert/Layers/Des_Rock_albedo.dds', '/env/Desert/Layers/Des_Rock01_albedo.dds', '/env/Desert/Decals/Des_Rock01_albedo.dds' },
        sand = { '/env/Desert/Layers/Des_sandLight_albedo.dds' }, dirt = { '/env/Desert/Layers/Des_Gravel_albedo.dds' },
        wet = { '/env/Desert/Layers/Des_Sandwet_albedo.dds' }, highrock = { '/env/Desert/Layers/Des_Rock03_albedo.dds', '/env/Desert/Decals/Des_Rock03_albedo.dds' },
        darkrock = { '/env/Desert/Layers/Des_SandDark_albedo.dds' }, snow = { '/env/Desert/Layers/Des_sandLight_albedo.dds' } },
    tropical = { label = 'Tropical', size = 12,
        base = { '/env/Tropical/Layers/TrGrass002_albedo.dds' }, upper = { '/env/Evergreen/layers/macrotexture000_albedo.dds' },
        grass = { '/env/Tropical/Layers/TrGrass005_albedo.dds', '/env/Tropical/Layers/TrGrass002_albedo.dds' },
        rock = { '/env/Tropical/Layers/TrRock002_albedo.dds' }, sand = { '/env/Tropical/Layers/DrySand001_albedo.dds' },
        dirt = { '/env/Tropical/Layers/Tr_ground001_albedo.dds' }, wet = { '/env/Tropical/Layers/TrBush_moss_albedo.dds' },
        highrock = { '/env/Tropical/Layers/TrRock005_albedo.dds' }, darkrock = { '/env/Tropical/Layers/TrRock003_albedo.dds', '/env/Tropical/Layers/TrRock006_albedo.dds' },
        snow = { '/env/Tropical/Layers/DrySand002_albedo.dds' } },
    tundra = { label = 'Tundra', size = 14,
        base = { '/env/Tundra/Layers/Tund_Grass_albedo.DDS' }, upper = { '/env/Tundra/Layers/MacroIce_albedo.dds' },
        grass = { '/env/Tundra/Layers/Tund_Grass_albedo.DDS' }, rock = { '/env/Tundra/Layers/Tund_Rock02_albedo.DDS', '/env/Tundra/Layers/Tund_Rock03_albedo.DDS' },
        sand = { '/env/Tundra/Layers/Tund_gravil_albedo.dds' }, dirt = { '/env/Tundra/Layers/_TundraDirt001_albedo.dds', '/env/Tundra/Layers/Tund_sandLight2_albedo.dds' },
        wet = { '/env/Tundra/Layers/Tund_melt001_albedo.dds' }, highrock = { '/env/Tundra/Layers/Tund_iceRock_albedo.dds' },
        darkrock = { '/env/Tundra/Layers/Tund_Ice004_albedo.DDS', '/env/Tundra/Layers/Tund_Ice001_albedo.DDS' }, snow = { '/env/Tundra/Layers/Tund_Snow_albedo.DDS' } },
    lava = { label = 'Lava', size = 14,
        base = { '/env/Lava/Layers/LAV_Gravel_albedo.dds' }, upper = { '/env/Lava/Layers/macrotexture000_albedo.dds' },
        grass = { '/env/Lava/Layers/LAV_Gravel_albedo.dds' }, rock = { '/env/Lava/Layers/LAV_Rock01_albedo.dds' },
        sand = { '/env/Lava/Layers/LAV_Cracked_albedo.dds' }, dirt = { '/env/Lava/Layers/LAV_Rock02_albedo.dds' },
        wet = { '/env/Lava/Layers/LAV_Lava01_albedo.dds' }, highrock = { '/env/Lava/Layers/LAV_Rock05_albedo.dds' },
        darkrock = { '/env/Lava/Layers/LAV_Rock09_albedo.dds' }, snow = { '/env/Lava/Layers/LAV_Ribbon01_albedo.dds' } },
    swamp = { label = 'Swamp', size = 12,
        base = { '/env/Swamp/layers/Sw_Grass_01_albedo.dds' }, upper = { '/env/Evergreen/layers/macrotexture000_albedo.dds' },
        grass = { '/env/Swamp/layers/Sw_Grass_01_albedo.dds' }, rock = { '/env/Swamp/layers/Sw_Rocky_01_albedo.dds' },
        sand = { '/env/Swamp/layers/Sw_Mudder_01_albedo.dds' }, dirt = { '/env/Swamp/layers/Sw_Mossy_01_albedo.dds' },
        wet = { '/env/Swamp/layers/Sw_Sphagnum_01_albedo.dds' }, highrock = { '/env/Swamp/layers/Sw_Rocky_02_albedo.dds' },
        darkrock = { '/env/Swamp/layers/Sw_Mudder_03_albedo.dds' }, snow = { '/env/Swamp/layers/Sw_Ferns_01_albedo.dds' } },
    geothermal = { label = 'Geothermal', size = 14,
        base = { '/env/Geothermal/layers/Geo_Dirt_01_albedo.dds' }, upper = { '/env/Evergreen/layers/macrotexture000_albedo.dds' },
        grass = { '/env/Geothermal/layers/Geo_Dirt_01_albedo.dds' }, rock = { '/env/Geothermal/layers/Geo_Rock001_albedo.DDS', '/env/Geothermal/layers/Geo_Rock001_albedo.dds' },
        sand = { '/env/Geothermal/layers/Geo_Ashley_01_albedo.dds' }, dirt = { '/env/Geothermal/layers/Geo_Rock002_albedo.dds' },
        wet = { '/env/Geothermal/layers/Geo_LavaDk_01_albedo.dds' }, highrock = { '/env/Geothermal/layers/Geo_Rock002_albedo.dds' },
        darkrock = { '/env/Geothermal/layers/Geo_LavaMd_01_albedo.dds' }, snow = { '/env/Geothermal/layers/Geo_LavaLt_01_albedo.dds' } },
}
-- Mars: tan sand with red-brown rock and dark pebbles (the look of the Gaea reference map: peach ground, dark rock bands). Desert sands and rocks with the red barrens gravel.
Themes.redbarrens = { label = 'Mars (tan sand, red-brown rock)', size = 14,
    base = { '/env/Desert/Layers/Des_SandMed01_albedo.dds' }, upper = { '/env/Red Barrens/Layers/macrotexture001_albedo.dds', '/env/Evergreen/layers/macrotexture000_albedo.dds' },
    grass = { '/env/Desert/Layers/Des_SandMed01_albedo.dds' }, rock = { '/env/Desert/Layers/Des_Rock_albedo.dds', '/env/Red Barrens/Layers/RB_Rock04_albedo.dds' },
    sand = { '/env/Desert/Layers/Des_SandMed_albedo.dds' }, dirt = { '/env/Desert/Layers/Des_Gravel_albedo.dds', '/env/Red Barrens/Layers/RB_Gravel01_albedo.dds' },
    wet = { '/env/Desert/Layers/Des_SandDark02_albedo.dds', '/env/Desert/Layers/Des_SandDark_albedo.dds' }, highrock = { '/env/Desert/Layers/Des_Rock03_albedo.dds', '/env/Red Barrens/Layers/RB_Rock02_albedo.dds' },
    darkrock = { '/env/Desert/Layers/Des_Rock06_albedo.dds', '/env/Red Barrens/Layers/RB_Rock09_albedo.dds' }, snow = { '/env/Desert/Layers/Des_SandMed_albedo.dds' } }
ThemeOrder = { 'temperate', 'valley', 'desert', 'redbarrens', 'tropical', 'tundra', 'lava', 'swamp', 'geothermal' }

-- ---- layered sets: several textures of one kind of ground (docs/projects/editor/GRAPH_TEXTURING.md, "Operation Citadel") -------------------------------------------------------------
-- A map that looks rich has three to five textures of the same kind side by side: Operation Citadel paints three kinds of rock and three of wet ground, every texel blends 2.7 layers on average.
-- Variants[theme][role] lists the other textures of a kind of ground (the first existing ones; the theme's own texture is variant 1). ApplyLayered gives the eight painted layers the
-- LAYERED layout (kinds repeated, each with its own variant); the recipe knows which layer is which kind from Recipes.State.layerRoles (the colour detection can mistake a rock variant for dirt).
Variants = {
    temperate = {
        grass = { '/env/Evergreen/layers/grass000_albedo.dds', '/env/Evergreen2/Layers/EvGrass006_albedo.dds', '/env/Evergreen2/Layers/EvGrass008_albedo.dds' },
        rock = { '/env/Evergreen/layers/RockLight_albedo.dds', '/env/Evergreen/layers/SandRock_albedo.dds', '/env/Evergreen2/Layers/EvRock002_albedo.dds' },
        dirt = { '/env/Evergreen2/Layers/Eg_Gravel01_albedo.dds', '/env/Evergreen2/Layers/Eg_Dirt002_albedo.dds' },
        wet = { '/env/Evergreen2/Layers/Eg_Dirt003_albedo.dds', '/env/Evergreen2/Layers/Eg_Dirt001_albedo.dds' },
    },
    valley = {
        grass = { '/env/Evergreen2/Layers/EG_Grass001_albedo.dds', '/env/Evergreen2/Layers/EvGrass006_albedo.dds', '/env/Evergreen2/Layers/EvGrass008_albedo.dds' },
        rock = { '/env/Evergreen2/Layers/EG_Rock_albedo.dds', '/env/Evergreen2/Layers/EvRock002_albedo.dds', '/env/Evergreen2/Layers/EvRock007_albedo.dds' },
        dirt = { '/env/Evergreen2/Layers/Eg_Gravel01_albedo.dds', '/env/Evergreen2/Layers/Eg_Gravel003_albedo.dds', '/env/Evergreen2/Layers/Eg_Dirt002_albedo.dds' },
        wet = { '/env/Evergreen2/Layers/Eg_Dirt001_albedo.dds', '/env/Evergreen2/Layers/Eg_Gravel004_albedo.dds' },
    },
    desert = {
        grass = { '/env/Desert/Layers/Des_SandMed01_albedo.dds', '/env/Desert/Layers/Des_SandMed_albedo.dds' },
        rock = { '/env/Desert/Layers/Des_Rock01_albedo.dds', '/env/Desert/Layers/Des_Rock02_albedo.dds', '/env/Desert/Layers/Des_Rock04_albedo.dds' },
        dirt = { '/env/Desert/Layers/Des_Gravel01_albedo.dds', '/env/Desert/Layers/Des_SandDark02_albedo.dds' },
        wet = { '/env/Desert/Layers/Des_SandDark_albedo.dds', '/env/Desert/Layers/Des_SandWet_albedo.dds' },
    },
    redbarrens = {
        grass = { '/env/Desert/Layers/Des_SandMed02_albedo.dds', '/env/Desert/Layers/Des_SandDark_albedo.dds', '/env/Red Barrens/Layers/RB_Sand_albedo.dds' },
        rock = { '/env/Red Barrens/Layers/RB_Rock04_albedo.dds', '/env/Desert/Layers/Des_Rock05_albedo.dds', '/env/Red Barrens/Layers/RB_Rock02_albedo.dds' },
        dirt = { '/env/Desert/Layers/Des_Gravel01_albedo.dds', '/env/Red Barrens/Layers/RB_Gravel01_albedo.dds' },
        wet = { '/env/Desert/Layers/Des_SandDark_albedo.dds', '/env/Red Barrens/Layers/RB_SandWet01_albedo.dds' },
    },
    tropical = {
        grass = { '/env/Tropical/Layers/TrGrass003_albedo.dds', '/env/Tropical/Layers/TrGrass004_albedo.dds', '/env/Tropical/Layers/Trop_Grass_albedo.dds' },
        rock = { '/env/Tropical/Layers/TrRock003_albedo.dds', '/env/Tropical/Layers/TrRock006_albedo.dds', '/env/Tropical/Layers/TrRock007_albedo.dds' },
        dirt = { '/env/Tropical/Layers/TrRawGround01_albedo.dds', '/env/Tropical/Layers/Trop_Dirt_albedo.dds' },
        wet = { '/env/Tropical/Layers/WetSand001_albedo.dds', '/env/Tropical/Layers/WetSand002_albedo.dds' },
    },
}

-- the layered layout per shader: { role, variant } for painted layer 1, 2, ... (variant 1 = the theme's own texture, n = Variants[theme][role][n - 1]). The B shaders draw layers 3 and 4 from the side only: rock there.
local LAYERED_8 = { { 'grass', 2 }, { 'rock', 1 }, { 'dirt', 1 }, { 'rock', 2 }, { 'wet', 1 }, { 'dirt', 2 }, { 'rock', 3 }, { 'wet', 2 } }
local LAYERED_7_BIPLANAR = { { 'grass', 2 }, { 'dirt', 1 }, { 'rock', 1 }, { 'rock', 2 }, { 'wet', 1 }, { 'dirt', 2 }, { 'wet', 2 } }
local LAYERED_7 = { { 'grass', 2 }, { 'rock', 1 }, { 'dirt', 1 }, { 'rock', 2 }, { 'wet', 1 }, { 'dirt', 2 }, { 'rock', 3 } }



-- The sets measured on a set of reference maps (scripts/map_texture_stats.py, map_texture_presets.py -> mapsets.lua): Themes of the same shape (they have a `family`), MapFamilies = { { family,
-- label, ids } } for the menu, and the recipe style of each family (`style`, an id of recipes.lua Presets).
MapFamilies = {}
do
    local ok, M = pcall(import, '/lua/editor/mapsets.lua')
    if ok and M then
        for id, theme in M.Themes do
            if not Themes[id] then Themes[id] = theme end
        end
        MapFamilies = M.Order
    end
end

local function Exists(path)
    local ok, info = pcall(DiskGetFileInfo, path)
    return ok and info ~= nil and info ~= false
end

local function FirstExisting(list)
    for _, p in list or {} do
        if Exists(p) then return p end
    end
    return nil
end

function SetTheme(id)
    if Themes[id] then Theme = id end
end

function TextureFor(role, themeId)
    local theme = Themes[themeId or Theme] or Themes[DEFAULT]
    return FirstExisting(theme[role]) or FirstExisting(Themes[DEFAULT][role])
end

local function Strata_() return import('/lua/editor/strata.lua') end
local function TexScale_() return import('/lua/editor/texscale.lua') end

--- nil when layer 8 takes a ground texture with the shader of the map; else the reason it does not (its textures are map-wide data, its mask a roughness multiplier).
local function Layer8Unavailable()
    local ok, p = pcall(function() return Strata_().Profile() end)
    if ok and p and (p.l8 == 'rough' or p.l8 == 'data') then return 'layer 8 is not a painted layer with ' .. tostring(ed_stratum_shader()) end
    return nil
end

--- Whether the Upper layer of the map's shader is an overlay (a macrotexture fits); the PBR shaders read it as a roughness atlas, the 001 / 051 as a specular texture.
local function UpperIsOverlay()
    local ok, p = pcall(function() return Strata_().Profile() end)
    return not (ok and p and p.upper and p.upper ~= 'overlay')
end

--- The tile size a texture of a theme gets: Optimal for the texture (texscale.lua: texel density), the `size` field of the theme only when the file cannot be read.
local function TileOf(path, theme, factor)
    return TexScale_().Optimal(path, (theme.size or 12) * (factor or 1))
end

--- Gives layers 0..9 the textures of a theme. The masks stay; the normal maps follow their albedo (or are the neutral map) at the same tile size. Every tile size is Optimal for its
--- texture; the Upper layer (macrotexture) gets a tile near 128 that is a golden ratio power of the base tile (texscale.MacroTile).
function Apply(themeId)
    local theme = Themes[themeId]
    if not theme or not rawget(_G, 'ed_stratum_layer') then return 0 end
    local Strata = Strata_()
    local TS = TexScale_()
    local n = 0
    local baseTile
    local function Set(layer, list, factor, macro)
        local path = FirstExisting(list)
        if not path then return end
        local tile
        if macro then tile = TS.MacroTile(baseTile) else tile = TileOf(path, theme, factor) end
        if layer == 0 then baseTile = tile end
        if Strata.SetTexture(layer, path, '', tile, tile) then n = n + 1 end
    end
    Set(0, theme.base, 2)
    baseTile = baseTile or TileOf(nil, theme, 2)
    local layout = Layout()
    for _, role in Roles do
        local layer = layout[role]
        if layer then Set(layer, theme[role], 1) end
    end
    if UpperIsOverlay() then Set(9, theme.upper, 1, true) end
    Theme = themeId
    pcall(function() import('/lua/editor/alphagen.lua').FitBase() end)          -- the base alpha of the macrotexture variants
    return n
end

--- The layered layout for the map's shader: { { role, variant }, ... } per painted layer (index = layer), or nil when the shader has too few layers for it (4 painted layers).
function LayeredLayout(profile)
    if profile == nil then
        local ok, p = pcall(function() return Strata_().Profile() end)
        profile = ok and p or nil
    end
    local cap = (profile and profile.painted) or 8
    if cap >= 8 then return LAYERED_8 end
    if cap >= 7 then return (profile and profile.biplanar) and LAYERED_7_BIPLANAR or LAYERED_7 end
    return nil
end

--- The path of variant n of a role in a theme: n = 1 the theme's own texture, n > 1 the (n - 1)th of Variants (the first that exists; the previous variant when none does).
local function VariantPath(theme, themeId, role, n)
    local own = FirstExisting(theme[role]) or FirstExisting(Themes[DEFAULT][role])
    if n <= 1 then return own end
    local list = Variants[themeId] and Variants[themeId][role]
    if list and list[n - 1] and Exists(list[n - 1]) then return list[n - 1] end
    if list then
        for i = n - 1, 1, -1 do
            if list[i] and Exists(list[i]) then return list[i] end
        end
    end
    return own
end

--- Gives the layers the textures of the LAYERED layout (several textures of one kind of ground, see Variants): the base and the upper layer as Apply does, painted layer l the variant the layout
--- says. -> number of layers set, { [layer] = role } (what the recipe has to know: Recipes.State.layerRoles) | nil, message.
function ApplyLayered(themeId)
    themeId = themeId or Theme
    local theme = Themes[themeId]
    if not theme or not rawget(_G, 'ed_stratum_layer') then return nil, 'no texture set' end
    local layout = LayeredLayout()
    if not layout then return nil, 'this shader has only four painted layers: layered textures need seven or eight' end
    local Strata = Strata_()
    local TS = TexScale_()
    local n, roles, paths = 0, {}, {}
    local baseTile
    local function Set(layer, path, macro)
        if not path then return end
        local tile
        if macro then tile = TS.MacroTile(baseTile) else tile = TileOf(path, theme, layer == 0 and 2 or 1) end
        if layer == 0 then baseTile = tile end
        if Strata.SetTexture(layer, path, '', tile, tile) then
            n = n + 1
            paths[layer] = path
        end
    end
    Set(0, FirstExisting(theme.base))
    baseTile = baseTile or TileOf(nil, theme, 2)
    roles[0] = 'grass'
    for layer, entry in layout do
        local role, variant = entry[1], entry[2]
        local path = VariantPath(theme, themeId, role, variant)
        if path then
            Set(layer, path)
            roles[layer] = role
        end
    end
    if UpperIsOverlay() then Set(9, FirstExisting(theme.upper), true) end
    Theme = themeId
    pcall(function() import('/lua/editor/alphagen.lua').FitBase() end)
    return n, roles, paths
end

--- One painted layer gets the texture of a role (its mask is not touched), at the Optimal tile size of the texture.
function ApplyRole(layer, role, themeId)
    if not role or role == 'keep' then return true end
    if not RoleLabels[role] then return nil, 'unknown texture role ' .. tostring(role) end
    if layer == 8 then
        local why = Layer8Unavailable()
        if why then return nil, why end
    end
    local path = TextureFor(role, themeId)
    if not path then return nil, 'no texture found for ' .. role end
    local Strata = Strata_()
    local theme = Themes[themeId or Theme] or Themes[DEFAULT]
    local tile = TileOf(path, theme, 1)
    if Strata.SetTexture(layer, path, '', tile, tile) then return true end
    return nil, 'the texture ' .. path .. ' did not load'
end

--- True when no painted layer has a texture (what a blank map is made with).
function PaintedLayersEmpty()
    if not rawget(_G, 'ed_stratum_layer') then return false end
    local Strata = Strata_()
    for i = 1, 8 do
        local albedo = ed_stratum_layer(i)
        if albedo and albedo ~= '' and albedo ~= Strata.CLEAR then return false end
    end
    return true
end

--- A new map gets the default set when it has none (called by Map.Load; Maps.TakeFresh says whether the session was made by File > New).
function ApplyIfNew()
    local fresh = false
    pcall(function() fresh = import('/lua/editor/maps.lua').TakeFresh() end)
    if fresh and PaintedLayersEmpty() then
        local n = Apply(DEFAULT)
        LOG('EDITOR texture set: ' .. n .. ' layers of a new map')
        return n
    end
    return 0
end

local STANDARD = { grass = 1, rock = 2, sand = 3, dirt = 4, wet = 5, highrock = 6, darkrock = 7, snow = 8 }

--- The painted layer of every role for a shader profile (the map's shader when nil): { role = layer }; a role the shader has no layer for is missing from the table (see the header).
function Layout(profile)
    if profile == nil then
        local ok, p = pcall(function() return Strata_().Profile() end)
        profile = ok and p or nil
    end
    local cap = (profile and profile.painted) or 8
    if cap >= 8 then return { grass = 1, rock = 2, sand = 3, dirt = 4, wet = 5, highrock = 6, darkrock = 7, snow = 8 } end
    if cap <= 4 then return { rock = 1, sand = 2, dirt = 3, snow = 4 } end
    if profile and profile.biplanar then
        return { grass = 1, sand = 2, rock = 3, highrock = 4, wet = 5, dirt = 6, snow = 7 }
    end
    return { grass = 1, rock = 2, sand = 3, dirt = 4, wet = 5, highrock = 6, snow = 7 }
end

--- The painted layer a role has for a shader (the standard 8 layer layout when `profile` is false): grass 1, rock 2, sand 3, dirt 4, wet 5, high rock 6, dark rock 7, snow 8.
function RoleLayer(role, profile)
    if profile == false then return STANDARD[role] end
    return Layout(profile)[role]
end

--- The kind of ground a texture file is, when it is one of the textures of the sets above (any theme): the role of the layer it sits on when that layer's role has the file in some theme (the
--- layout of Apply: layer 1 grass ... 8 snow, the base layer is grass), else the one role of the sets that lists it. nil for a file that is in no set (the name and colour of the texture
--- decide then: roledetect.lua). `layer` may be nil.
function RoleOfTexture(path, layer)
    if not path or path == '' then return nil end
    local key = string.lower((string.gsub(path, '\\', '/')))
    local function Lists(role, theme)
        if theme.family then return false end                      -- the sets of the maps: a texture is another kind of ground in each map
        local list = theme[role]
        if role == 'grass' and theme.base then
            for _, c in theme.base do if string.lower(c) == key then return true end end
        end
        for _, c in list or {} do
            if string.lower(c) == key then return true end
        end
        return false
    end
    if layer ~= nil then
        local role = (layer == 0) and 'grass' or nil
        if layer ~= 0 then
            for r, l in Layout() do
                if l == layer then role = r end
            end
        end
        if role then
            for _, theme in Themes do
                if Lists(role, theme) then return role end
            end
        end
    end
    local found, count = nil, 0
    for _, role in Roles do
        for _, theme in Themes do
            if Lists(role, theme) then
                if found ~= role then count = count + 1 end
                found = role
                break
            end
        end
    end
    if count == 1 then return found end
    return nil
end

--- ids, labels for a choice parameter: keep + every role.
function RoleChoices()
    local ids, labels = { 'keep' }, { 'Keep the layer\'s texture' }
    for _, role in Roles do
        table.insert(ids, role)
        table.insert(labels, RoleLabels[role])
    end
    return ids, labels
end
