-- Texture sets: ready-made choices of terrain textures for the painted layers, so a new map and the generators (terrain graph outputs, mask generator) paint with something instead of
-- empty layers. A set gives every painted layer (1..8) a texture by ROLE, the base layer (0) and the upper layer (9, the macrotexture); the generators name a role, not a file:
--
--   layer  1 grass   2 rock   3 sand (the shore)   4 dirt   5 wet ground   6 high rock   7 dark rock (cavities)   8 snow
--
--   Themes, ThemeOrder      the sets: { label, base, upper, grass = { candidate paths }, rock = ..., ... } (the first path that exists in the game data is used)
--   Roles, RoleLabels       the role names in layer order and their labels
--   Theme / SetTheme(id)    the theme roles are looked up in (what the last Apply or the map was given; Temperate until chosen)
--   TextureFor(role[, theme])  the path of a role in a theme (nil when none of its candidates exists)
--   Apply(themeId)          gives layers 0..9 the textures of a theme (the masks stay as they are); -> number of layers set
--   ApplyRole(layer, role)  gives one painted layer the texture of a role (keeps its mask); -> true | nil, message
--   ApplyIfNew()            the first thing a new map gets: the default set, when its painted layers have no texture (called by Map.Load)
--   RoleChoices()           ids and labels for a choice parameter: 'keep' (leave the layer's texture) and every role
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

Roles = { 'grass', 'rock', 'sand', 'dirt', 'wet', 'highrock', 'darkrock', 'snow' }
RoleLabels = { grass = 'Grass', rock = 'Rock (cliffs)', sand = 'Sand (shore)', dirt = 'Dirt', wet = 'Wet ground', highrock = 'High rock', darkrock = 'Dark rock', snow = 'Snow' }

DEFAULT = 'temperate'
Theme = DEFAULT

Themes = {
    temperate = { label = 'Temperate (Evergreen)', size = 12,
        base = { '/env/Evergreen/layers/grass001_albedo.dds' }, upper = { '/env/Evergreen/layers/macrotexture000_albedo.dds' },
        grass = { '/env/Evergreen/layers/grass000_albedo.dds', '/env/Evergreen/layers/grass001_albedo.dds' },
        rock = { '/env/Evergreen/layers/RockMed_albedo.dds' }, sand = { '/env/Evergreen/layers/SandLight_albedo.dds' },
        dirt = { '/env/Evergreen/layers/Dirt001_albedo.dds' }, wet = { '/env/Evergreen/layers/Sandwet_albedo.dds' },
        highrock = { '/env/Evergreen/layers/RockLight_albedo.dds' }, darkrock = { '/env/Evergreen/layers/SandRock_albedo.dds' },
        snow = { '/env/Evergreen/layers/snow001_albedo.dds' } },
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
ThemeOrder = { 'temperate', 'desert', 'tropical', 'tundra', 'lava', 'swamp', 'geothermal' }

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

--- Gives layers 0..9 the textures of a theme. The masks stay; the normal maps follow their albedo (or are the neutral map).
function Apply(themeId)
    local theme = Themes[themeId]
    if not theme or not rawget(_G, 'ed_stratum_layer') then return 0 end
    local Strata = Strata_()
    local n = 0
    local size = theme.size or 12
    local function Set(layer, list, tile)
        local path = FirstExisting(list)
        if path and Strata.SetTexture(layer, path, '', tile, tile) then n = n + 1 end
    end
    Set(0, theme.base, size * 2)
    for i, role in Roles do Set(i, theme[role], size) end
    Set(9, theme.upper, 128)
    Theme = themeId
    return n
end

--- One painted layer gets the texture of a role (its mask is not touched).
function ApplyRole(layer, role, themeId)
    if not role or role == 'keep' then return true end
    if not RoleLabels[role] then return nil, 'unknown texture role ' .. tostring(role) end
    local path = TextureFor(role, themeId)
    if not path then return nil, 'no texture found for ' .. role end
    local Strata = Strata_()
    local theme = Themes[themeId or Theme] or Themes[DEFAULT]
    local tile = theme.size or 12
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

--- ids, labels for a choice parameter: keep + every role.
function RoleChoices()
    local ids, labels = { 'keep' }, { 'Keep the layer\'s texture' }
    for _, role in Roles do
        table.insert(ids, role)
        table.insert(labels, RoleLabels[role])
    end
    return ids, labels
end
