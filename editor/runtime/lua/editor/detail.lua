-- Detail pass: the small things on top of the map-wide textures, in classes by size and slope (docs/projects/editor/GRAPH_TEXTURING.md, "Operation Citadel").
--
-- A map that looks rich is not only painted: Operation Citadel carries 12,625 props and 971 decals on 20 km. Measured against the slope under them (the terrain's mean is 8.6 degrees):
--   small rocks and crystals (about 10,300)   4 degrees: gentle ground, in clusters        big cliff rocks (about 1,850)   16 degrees, a third of them on ground over 20 degrees
--   crevice decals, 25 units (about 750)      2 to 6 degrees, slightly in hollows           rock ground decals, 36 units (175)   17 degrees, slightly raised
-- The pass places such classes with the props scatter (scatter.lua, Poisson disc, symmetry aware): every class is one scatter run with its own entries, slope window, clustering noise and
-- density per 1,000 square units; each run is one undo step. The entries come from the environment of the texture set (props and decals of the game's /env/<environment> folders); what does
-- not exist is skipped.
--
--   Classes(themeId) -> list      { id, label, mode ('props' | 'decals'), entries = { paths that exist }, slopeMin, slopeMax, per1000, minDist, scaleMin, scaleMax, decalSize, cluster = { size, share } }
--   Plan(opts) -> lines           what Run would place, per class (nothing is placed)
--   Run(opts) -> summary | nil, message   places the classes; opts = { theme, density (multiplier, default Scale), seed, only = { class ids }, underWater (also below the water surface) }
--   Scale                         the density multiplier of the panel (1 = the measured density)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Scatter = import('/lua/editor/scatter.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Recipes = import('/lua/editor/recipes.lua')
local TexSets = import('/lua/editor/texsets.lua')

Scale = 1

-- the game's props and decals per environment, by class (paths of /env/<environment>/props and /Decals; the ones that do not exist are dropped when the pass runs)
local E = '/env/'
Sets = {
    evergreen = {
        group = 'evergreen',
        small = { 'fieldstone01', 'fieldstone02', 'fieldstone03', 'fieldstone04',
                  'rock01', 'rock02' },
        big = { 'rock03', 'rock04', 'rock05', 'rockpile01', 'rockpile02' },
        crack = { E .. 'Evergreen2/Decals/eg_scatterstones001_albedo.dds', E .. 'Evergreen2/Decals/eg_scatterstones002_albedo.dds', E .. 'Evergreen2/Decals/eg_scatterstones003_albedo.dds',
                  E .. 'Evergreen2/Decals/eg_scatterstones004_albedo.dds', E .. 'Evergreen2/Decals/eg_patchdry001_albedo.dds', E .. 'Evergreen2/Decals/eg_patchwarm001_albedo.dds',
                  E .. 'Evergreen2/Decals/eg_mudder01_albedo.dds', E .. 'Evergreen2/Decals/eg_mudder02_albedo.dds' },
        ground = { E .. 'Evergreen2/Decals/eg_ground001_albedo.dds', E .. 'Evergreen2/Decals/eg_ground002_albedo.dds', E .. 'Evergreen2/Decals/eg_ground003_albedo.dds',
                   E .. 'Evergreen2/Decals/eg_boulder002_albedo.dds', E .. 'Evergreen2/Decals/eg_boulder005_albedo.dds', E .. 'Evergreen2/Decals/eg_boulder007_albedo.dds' },
        cliff = { E .. 'Evergreen2/Decals/eg_cliff01_albedo.dds', E .. 'Evergreen2/Decals/eg_cliff02_albedo.dds', E .. 'Evergreen2/Decals/eg_cliff03_albedo.dds', E .. 'Evergreen2/Decals/eg_cliff04_albedo.dds' },
    },
    desert = {
        group = 'desert',
        small = { 'des_boulder01', 'des_boulder02', 'des_boulder03' },
        big = { 'des_boulder04', 'des_boulder05', 'des_boulder06' },
        crack = { E .. 'Desert/Decals/des_swirl01_albedo.dds', E .. 'Desert/Decals/des_swirl02_albedo.dds', E .. 'Desert/Decals/des_swirl03_albedo.dds',
                  E .. 'Desert/Decals/des_rock01_albedo.dds', E .. 'Desert/Decals/des_rock02_albedo.dds', E .. 'Desert/Decals/des_rock03_albedo.dds' },
        ground = { E .. 'Desert/Decals/des_rockground_albedo.dds', E .. 'Desert/Decals/des_rockground2_albedo.dds', E .. 'Desert/Decals/des_rockground3_albedo.dds',
                   E .. 'Desert/Decals/des_boulder005_albedo.dds', E .. 'Desert/Decals/des_boulder008_albedo.dds' },
        cliff = { E .. 'Desert/Decals/des_cliff01_albedo.dds', E .. 'Desert/Decals/des_cliff02_albedo.dds', E .. 'Desert/Decals/des_cliff03_albedo.dds' },
    },
    tropical = {
        group = 'tropical',
        small = { 'rock01', 'rock02', 'trrock01' },
        big = { 'rock03', 'rock04', 'rock05', 'rockpile01' },
        crack = { E .. 'Tropical/Decals/trrawground01_albedo.dds', E .. 'Tropical/Decals/trrawground02_albedo.dds', E .. 'Tropical/Decals/trrawground03_albedo.dds', E .. 'Tropical/Decals/tr_mud004_albedo.dds' },
        ground = { E .. 'Tropical/Decals/trrockage001_albedo.dds', E .. 'Tropical/Decals/trrockage002_albedo.dds', E .. 'Tropical/Decals/trrockage003_albedo.dds', E .. 'Tropical/Decals/trrockage004_albedo.dds' },
        cliff = { E .. 'Tropical/Decals/trrockage005_albedo.dds', E .. 'Tropical/Decals/trrockage006_albedo.dds', E .. 'Tropical/Decals/trrockage007_albedo.dds' },
    },
    tundra = {
        group = 'tundra',
        small = { 'icerocksm01', 'icerocksm02', 'icerocksm03', 'icerocksm04' },
        big = { 'tund_rock02', 'tund_rock03', 'tund_rock04', 'tund_rock05' },
        crack = { E .. 'Tundra/Decals/tund_crack001_albedo.dds', E .. 'Tundra/Decals/tund_crack002_albedo.dds', E .. 'Tundra/Decals/tund_crack003_albedo.dds', E .. 'Tundra/Decals/tund_crack004_albedo.dds' },
        ground = { E .. 'Tundra/Decals/tund_rockground_albedo.dds', E .. 'Tundra/Decals/tund_rockground2_albedo.dds', E .. 'Tundra/Decals/tund_rockground3_albedo.dds', E .. 'Tundra/Decals/tund_rockground4_albedo.dds' },
        cliff = { E .. 'Tundra/Decals/tund_cliff002_albedo.dds', E .. 'Tundra/Decals/tund_cliff003_albedo.dds', E .. 'Tundra/Decals/tund_cliff004_albedo.dds' },
    },
    lava = {
        group = 'lava',
        small = { 'lav_rock01', 'lav_rock02', 'lv_rock01' },
        big = { 'lav_rock03', 'lav_rock04', 'lav_rock05', 'lv_rock02' },
        crack = { E .. 'Lava/Decals/lav_lavarock01_albedo.dds', E .. 'Lava/Decals/lav_lavarock02_albedo.dds', E .. 'Lava/Decals/lav_lavarock03_albedo.dds' },
        ground = { E .. 'Lava/Decals/lav_lavarock04_albedo.dds', E .. 'Lava/Decals/lav_lavarock05_albedo.dds', E .. 'Lava/Decals/lav_lavarock06_albedo.dds' },
        cliff = { E .. 'Lava/Decals/lav_lavarock07_albedo.dds' },
    },
    swamp = {
        group = 'swamp',
        small = { 'boulder01', 'boulder02' },
        big = { 'boulder03', 'outcrop01' },
        crack = { E .. 'Swamp/Decals/muddetail01_albedo.dds', E .. 'Swamp/Decals/mudhole001_albedo.dds', E .. 'Swamp/Decals/mudhole002_albedo.dds', E .. 'Swamp/Decals/mudhole003_albedo.dds' },
        ground = { E .. 'Swamp/Decals/sw_boulder002_albedo.dds', E .. 'Swamp/Decals/sw_boulder007_albedo.dds', E .. 'Swamp/Decals/sw_boulder008_albedo.dds' },
        cliff = { E .. 'Swamp/Decals/swcliff01_albedo.dds', E .. 'Swamp/Decals/swcliff02_albedo.dds', E .. 'Swamp/Decals/swcliff03_albedo.dds', E .. 'Swamp/Decals/cliffside001_albedo.dds' },
    },
    redbarrens = {
        group = 'redrocks',
        small = { 'rock_sm01', 'rock_sm02', 'rock_sm03', 'rock_sm04', 'rock_sm05', 'rock_sm06', 'rock_sm07' },
        big = { 'rock01', 'rock02', 'rock03', 'boulder01', 'boulder02', 'boulder03', 'boulder04' },
        crack = { E .. 'Desert/Decals/des_rockground_albedo.dds', E .. 'Desert/Decals/des_rockground2_albedo.dds', E .. 'Desert/Decals/des_rockground3_albedo.dds',
                  E .. 'Desert/Decals/des_swirl01_albedo.dds', E .. 'Desert/Decals/des_swirl02_albedo.dds' },
        ground = { E .. 'Red Barrens/Decals/rb_rockground_albedo.dds', E .. 'Red Barrens/Decals/rb_rockground2_albedo.dds' },
        cliff = { E .. 'Red Barrens/Decals/rb_cliff01_albedo.dds', E .. 'Red Barrens/Decals/rb_cliff02_albedo.dds', E .. 'Red Barrens/Decals/rb_cliff03_albedo.dds' },
        scale = { small = { 320, 560 }, big = { 160, 280 } },
    },
    geothermal = {
        group = 'geothermal',
        small = { 'georock01', 'georock04', 'georock05' },
        big = { 'georock02', 'georock03', 'georock06', 'georock07' },
        crack = { E .. 'Geothermal/Decals/mudsplats01_albedo.dds', E .. 'Geothermal/Decals/mudsplats02_albedo.dds', E .. 'Geothermal/Decals/mudsplats03_albedo.dds' },
        ground = { E .. 'Geothermal/Decals/scum001_albedo.dds', E .. 'Geothermal/Decals/scum002_albedo.dds' },
        cliff = {},
    },
}
-- which environment a texture set belongs to
SetOf = { temperate = 'evergreen', valley = 'evergreen', desert = 'desert', redbarrens = 'redbarrens', tropical = 'tropical', tundra = 'tundra', lava = 'lava', swamp = 'swamp', geothermal = 'geothermal' }

-- the classes: slope window (degrees), how many per 1,000 square units (Operation Citadel: small 9.8, big 1.8, crevices 0.7, rock ground 0.17), the minimum distance, the scale window (percent), the decal
-- size (units at 100 percent), the clustering: noise of `size` units whose top `share` of the map takes the density (things lie in groups along the ground, not evenly)
Defs = {
    { id = 'small', label = 'Small rocks (gentle ground, in clusters)', mode = 'props', slopeMin = 0, slopeMax = 14, per1000 = 9.8, minDist = 6, scaleMin = 60, scaleMax = 130, cluster = { size = 70, share = 0.5 } },
    { id = 'stones', label = 'Stones along the water (channels and banks)', mode = 'props', slopeMin = 0, slopeMax = 25, per1000 = 3.5, minDist = 3, scaleMin = 60, scaleMax = 150, cluster = { size = 40, share = 0.8, flow = { 0.42, 0.55 } } },
    { id = 'big', label = 'Big rocks (steep ground, cliffs)', mode = 'props', slopeMin = 6, slopeMax = 55, per1000 = 1.8, minDist = 10, scaleMin = 90, scaleMax = 150, cluster = { size = 50, share = 0.85 } },
    { id = 'crack', label = 'Crevice and patch decals (gentle ground)', mode = 'decals', slopeMin = 0, slopeMax = 12, per1000 = 0.7, minDist = 14, scaleMin = 60, scaleMax = 160, decalSize = 25, cluster = { size = 90, share = 0.6 } },
    { id = 'ground', label = 'Rock ground decals (steeper ground)', mode = 'decals', slopeMin = 8, slopeMax = 35, per1000 = 0.17, minDist = 25, scaleMin = 70, scaleMax = 140, decalSize = 36, cluster = { size = 110, share = 0.6 } },
    { id = 'cliff', label = 'Cliff face decals (steep ground)', mode = 'decals', slopeMin = 30, slopeMax = 85, per1000 = 0.12, minDist = 22, scaleMin = 60, scaleMax = 110, decalSize = 26, cluster = { size = 70, share = 0.8 } },
}

-- decal textures are files of the game data; prop blueprints are not (the game loads them into its rules: DiskGetFileInfo does not see them), and they lie in subfolders (/env/evergreen/props/rocks/...):
-- the props catalog lists them, found here by environment and name
local propIndex = false
local function PropPath(group, name)
    if not propIndex then
        propIndex = {}
        local ok, list = pcall(function() return import('/lua/editor/props.lua').Catalog() end)
        if ok and list then
            for _, e in list do propIndex[string.lower(e.group .. '/' .. e.name)] = e.path end
        end
    end
    return propIndex[string.lower(group .. '/' .. name)]
end

local function DecalExists(path)
    local ok, info = pcall(DiskGetFileInfo, path)
    return ok and info ~= nil and info ~= false
end

--- The classes for a texture set with the entries that exist: { id, label, mode, entries = { path, ... }, ... }.
function Classes(themeId)
    local set = Sets[SetOf[themeId or TexSets.Theme] or 'evergreen'] or Sets.evergreen
    local out = {}
    for _, d in Defs do
        local c = {}
        for k, v in d do c[k] = v end
        c.entries = {}
        local entryKey = (d.id == 'stones') and 'small' or d.id
        if set.scale and set.scale[entryKey] then c.scaleMin, c.scaleMax = set.scale[entryKey][1], set.scale[entryKey][2] end
        for _, p in set[entryKey] or {} do
            if d.mode == 'props' then
                local path = PropPath(set.group, p)
                if path then table.insert(c.entries, path) end
            elseif DecalExists(p) then
                table.insert(c.entries, p)
            end
        end
        if table.getn(c.entries) > 0 then table.insert(out, c) end
    end
    return out
end

local function Rule(type, values, op)
    local r = MaskGen.NewRule(type)
    for k, x in (values or {}) do r.v[k] = x end
    r.op = op or 'and'
    r.invert = false
    return r
end

--- The density rules of a class: the clustering noise (its top `share` of the map), softened a little.
local function DensityRules(c, seed)
    local cl = c.cluster
    if not cl then return {} end
    -- along the water: stones collect in the channels and on their banks (the pebble lines of an eroded map): the drainage network (maskgen's flow rule), widened a little, thinned by the noise
    if cl.flow then
        local noise = Recipes.NoiseAt(5, seed, cl.size, 4, 1 - cl.share)
        return { Rule('flow', { range = 600, from = cl.flow[1], to = cl.flow[2] }), Rule('grow', { distance = 2, soft = 2 }),
                 Rule('noise', { kind = 5, seed = seed, size = cl.size, octaves = 4, from = noise, to = math.min(0.99, noise + 0.12) }, 'and') }
    end
    local size = cl.size
    local from = Recipes.NoiseAt(5, seed, size, 4, 1 - cl.share)
    local to = Recipes.NoiseAt(5, seed, size, 4, math.min(0.98, 1 - cl.share + 0.3))
    if to - from < 0.02 then to = from + 0.02 end
    return { Rule('noise', { kind = 5, seed = seed, size = size, octaves = 4, from = from, to = to }), Rule('blur', { radius = 3 }) }
end

local function MapArea()
    local n = (rawget(_G, 'ed_terrain_info') and ed_terrain_info() or 0) - 1
    return n * n
end

--- Counts per class for the map: { id, count, entries } (no change to the map).
function Plan(opts)
    opts = opts or {}
    local mult = opts.density or Scale
    local area = MapArea()
    local out = {}
    for _, c in Classes(opts.theme) do
        local skip = false
        if opts.only then
            skip = true
            for _, id in opts.only do
                if id == c.id then skip = false end
            end
        end
        if not skip then
            table.insert(out, { id = c.id, label = c.label, mode = c.mode, entries = table.getn(c.entries), count = math.max(1, math.floor(c.per1000 * area / 1000 * mult + 0.5)) })
        end
    end
    return out
end

--- Places the classes with the props scatter. -> { { id, label, placed }, ... }, total | nil, message. One undo step per class.
function Run(opts)
    opts = opts or {}
    if not rawget(_G, 'ed_terrain_info') or not ed_terrain_info() then return nil, 'no terrain' end
    local mult = opts.density or Scale
    local area = MapArea()
    local seed = opts.seed or 1
    local classes = Classes(opts.theme)
    if table.getn(classes) == 0 then return nil, 'no props or decals of this environment exist in the game data' end
    local saved = { settings = {}, entries = Scatter.Entries, decals = Scatter.DecalEntries, density = Scatter.Density }
    for k, v in Scatter.Settings do saved.settings[k] = v end
    local summary, total = {}, 0
    local ok, err = pcall(function()
        for i, c in classes do
            local skip = false
            if opts.only then
                skip = true
                for _, id in opts.only do
                    if id == c.id then skip = false end
                end
            end
            if not skip then
                local s = Scatter.Settings
                s.mode = c.mode
                s.seed = seed * 100 + i
                s.count = math.max(1, math.floor(c.per1000 * area / 1000 * mult + 0.5))
                s.minDist = c.minDist
                s.fill = 1
                s.slopeMin, s.slopeMax = c.slopeMin, c.slopeMax
                s.scaleMin, s.scaleMax = c.scaleMin, c.scaleMax
                s.randomHeading = true
                s.avoidExisting = true
                s.withNormals = false
                s.underWater = opts.underWater and true or false
                if c.decalSize then s.decalSize = c.decalSize end
                local list = {}
                for _, p in c.entries do table.insert(list, { bp = p, weight = 1 }) end
                if c.mode == 'decals' then Scatter.DecalEntries = list else Scatter.Entries = list end
                Scatter.Density = { rules = DensityRules(c, 700 + i * 31 + seed) }
                local t0 = GetSystemTimeSeconds()
                local plan, report = Scatter.Plan()
                local t1 = GetSystemTimeSeconds()
                local n = plan and Scatter.Place(plan, 'detail pass: ' .. c.id) or nil
                local t2 = GetSystemTimeSeconds()
                table.insert(summary, { id = c.id, label = c.label, placed = n or 0, note = (not n) and tostring(report) or nil, planSeconds = t1 - t0, placeSeconds = t2 - t1 })
                total = total + (n or 0)
            end
        end
    end)
    for k, v in saved.settings do Scatter.Settings[k] = v end
    Scatter.Entries, Scatter.DecalEntries, Scatter.Density = saved.entries, saved.decals, saved.density
    if not ok then return nil, tostring(err) end
    return summary, total
end
