-- Terrain generator: fractal noise heights over the whole map (a starting point to sculpt from). One undo step.
--
--   Params                 the settings (seed, scale, octaves, persistence, amplitude, base, mode, island, replace)
--   Generate([params])     writes the heights; returns the number of samples written
--   Flatten(height)        the whole map to one height
--
-- Built on the native field engine (fields.lua): the noise, the island falloff and the combination run in C++ on the whole map at once (a 20 km map takes a fraction of a second; the
-- Lua loops this file had took half a minute). Modes: 'fbm' (rolling), 'ridged' (mountain ridges), 'billow' (rounded hills). The noise is normalised to its own lowest and highest value,
-- so `amplitude` is the real height range from valley to peak. `island` (0..100) pulls the border down to the base height, `replace` false adds the noise to the heights that are there.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')

Params = {
    seed = 1,
    scale = 120,          -- world units of the biggest features
    octaves = 5,
    persistence = 0.5,    -- how much each octave adds relative to the one before
    amplitude = 40,       -- world units from valley to peak
    base = 30,            -- height of the lowest ground
    mode = 'fbm',
    island = 0,
    replace = true,
}

local KIND = { fbm = 'perlin', ridged = 'ridged', billow = 'billow' }

local function Settings(p)
    local s = {}
    for k, v in Params do s[k] = v end
    if p then for k, v in p do s[k] = v end end
    return s
end

--- The recipe (fields.lua Pipeline) of settings s: noise -> normalise -> island mask -> height.
function Recipe(s)
    local steps = {
        { 'noise', KIND[s.mode] or 'perlin', { seed = math.floor(s.seed), scale = s.scale, octaves = s.octaves, persistence = s.persistence } },
        { 'unit', 'normalize', { a = '@noise' } },
    }
    local last = 'unit'
    if s.island > 0 then
        table.insert(steps, { 'dist', 'radial', { a = '@noise' } })                                          -- 0 in the middle, 1 at the middle of an edge
        table.insert(steps, { 'rim', 'smoothstep', { a = '@dist', edge0 = 1 - s.island / 100, edge1 = 1 } })
        table.insert(steps, { 'mask', 'invert', { a = '@rim' } })
        table.insert(steps, { 'shaped', 'mul', { a = '@unit', b = '@mask' } })
        last = 'shaped'
    end
    table.insert(steps, { 'relief', 'affine', { a = '@' .. last, mul = s.amplitude, add = s.replace and s.base or 0 } })
    return steps, 'relief'
end

function Generate(p)
    local s = Settings(p)
    local w, h = ed_terrain_info()
    if not w or not Fields.IsAvailable() then return 0 end
    return Fields.Run(function(S)
        local steps, out = Recipe(s)
        local env = Fields.Pipeline(steps, S)
        local result = env[out]
        if not s.replace then result = S:Op('add', { a = S:Height(), b = result }) end
        return Fields.CommitHeight(result, { label = 'Generate terrain' }) or 0
    end)
end

function Flatten(height)
    local w, h = ed_terrain_info()
    if not w or not Fields.IsAvailable() then return 0 end
    return Fields.Run(function(S)
        return Fields.CommitHeight(S:New(w, h, height), { label = 'Flatten map' }) or 0
    end)
end
