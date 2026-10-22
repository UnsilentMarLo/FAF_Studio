-- Terrain generation that mixes into the map instead of replacing it (the Fields panel's Generate section; docs/projects/editor/TERRAIN_GEN_DESIGN.md).
--
-- The old way was: make a field, write it into the heights. A generator makes a 0..1 field, so the commit flattened the whole map to a height between 0 and 1. Here a generator makes a RELIEF: a
-- zero-mean field in world units whose largest rise or dip is exactly `amplitude` (native op `amplitude`), and the relief is mixed into the heights that are there (native op `terrain_mix`):
--
--   Settings         the choices of the panel (module level, the controls come and go): preset, blend, amplitude (units), strength (0..1), scale (feature size, units), seed, detail, warp, gullies,
--                    mask (1 whole map, 2 playable area, 3 selected area), feather (units), keepFlat + flatRadius (units), keepWater
--   Presets          { id, label, tip, scale, amplitude, gullies, warp, detail, build(S, like, p) }: ready op chains (hills, mountains, badlands, dunes, plains, rocks); build makes the raw relief
--   Choose(id)       puts a preset's own scale, amplitude and so on into Settings
--   Relief(S, like, p)      the relief of p.preset: gradient noise (op `fractal`: every octave in its own turned frame, domain warp, ridged multifractal, slope dependent detail), shaped by the
--                           preset, optionally weathered by a brief droplet erosion (`gullies`), then `amplitude`
--   Combine(S, H, G, o)     the terrain H with the relief G mixed in: o.mode (add | multiply | max | min | replace), o.strength, o.mask (a field, 1 = may change), o.pts (flat list x, z, radius, 1 per
--                           protected spot) with o.feather (units), o.water (water elevation) with o.margin: -> new terrain, the mask that was used
--   Pads(p)                 the protected spots of the open map: start positions (flatRadius) and Mass / Hydrocarbon markers (0.4 * flatRadius), as the flat list Combine reads
--   MaskField(S, like, p)   the field of the chosen mask (nil = the whole map), and a text when the choice cannot be made
--   Difference(S, T, H)     how much T differs from H: { max, mean, share (0..1: samples that moved by more than 0.05 units), change (field) }
--   Build(p)                everything above on the map: -> result { terrain, change, stats, text } (native handles: free with Free) or nil, message
--   Commit(result)          writes result.terrain into the map: ONE undo entry, returns the number of samples changed
--   Free(result)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')

Blends = { 'add', 'multiply', 'max', 'min', 'replace' }
BlendNames = { add = 'Add', multiply = 'Multiply', max = 'Raise only', min = 'Lower only', replace = 'Replace' }
BlendTips = {
    add = 'The relief is added to the ground that is there: hills and valleys on top of the map.',
    multiply = 'Higher ground gets more of the relief, the lowest ground none: the shape of the map stays, its slopes get rougher.',
    max = 'Only raises: the relief can lift the ground but never dig it.',
    min = 'Only digs: the relief can lower the ground but never lift it.',
    replace = 'The relief takes the place of the ground that is there (the average height of the map stays). Use strength to mix.',
}
Masks = { 'whole', 'playable', 'selected' }
MaskNames = { whole = 'Whole map', playable = 'Playable area', selected = 'Selected area' }

Settings = {
    preset = 'hills', blend = 'add', amplitude = 18, strength = 1, scale = 140, seed = 1, detail = 0.5, warp = 0.5, gullies = 0,
    mask = 1, feather = 24, keepFlat = true, flatRadius = 24, keepWater = true,
}

-- ---- presets -----------------------------------------------------------------------------------------------------------------------------------------

--- The smallest wavelength an octave may have (units): the finer, the more detail, but never finer than 3 units (the ground a unit stands on).
local function Finest(p)
    return math.max(3, p.scale * (0.22 - 0.19 * p.detail))
end

local function Seed(p, k) return math.floor(p.seed) + k end

local function Fractal(S, like, p, k, extra)
    local params = { like = like, seed = Seed(p, k), octaves = 8, finest = Finest(p) }
    for key, v in extra do params[key] = v end
    return S:Op('fractal', params)
end

local function Centred(S, f, amount)
    return S:Op('affine', { a = f, mul = amount or 1, add = -0.5 * (amount or 1) })
end

Presets = {
    { id = 'hills', label = 'Hills', scale = 140, amplitude = 18, gullies = 0, warp = 0.5, detail = 0.5,
      tip = 'Rolling hills: rounded hills and broad swells with a little warp, gentle slopes.',
      build = function(S, like, p)
          local a = Fractal(S, like, p, 0, { scale = p.scale, kind = 'billow', persistence = 0.42, warp = p.warp * 0.2 * p.scale })
          local b = Fractal(S, like, p, 1, { scale = p.scale * 1.8, kind = 'fbm', persistence = 0.5, warp = p.warp * 0.15 * p.scale, slope_detail = 0.3 })
          return S:Op('blend', { a = a, b = b, mode = 'normal', opacity = 0.5 })
      end },
    { id = 'mountains', label = 'Mountains', scale = 240, amplitude = 60, gullies = 0.5, warp = 0.4, detail = 0.6,
      tip = 'Mountain ranges: ridged multifractal with sharp crests, finer detail on the steep ground, weathered by gullies.',
      build = function(S, like, p)
          local r = Fractal(S, like, p, 0, { scale = p.scale, kind = 'ridged', persistence = 0.5, sharpness = 2.2, warp = p.warp * 0.2 * p.scale, slope_detail = 0.5 })
          local peaks = S:Op('gamma', { a = r, gamma = 1.3 })
          -- a broad, smooth massif under the crests: ridged noise alone makes rings and loops around its own bumps
          local massif = Fractal(S, like, p, 1, { scale = p.scale * 1.35, kind = 'fbm', persistence = 0.5, warp = p.warp * 0.2 * p.scale })
          return S:Op('blend', { a = peaks, b = massif, mode = 'normal', opacity = 0.4 })
      end },
    { id = 'badlands', label = 'Badlands', scale = 200, amplitude = 35, gullies = 0.3, warp = 0.4, detail = 0.5,
      tip = 'Flat topped mesas with steep stepped sides and rough cliffs.',
      build = function(S, like, p)
          local base = S:Op('fractal', { like = like, seed = Seed(p, 0), scale = p.scale, octaves = 3, finest = math.max(Finest(p), p.scale * 0.18), warp = p.warp * 0.1 * p.scale })
          local shaped = S:Op('smoothstep', { a = base, edge0 = 0.3, edge1 = 0.7 })
          local steps = S:Op('terrace', { a = shaped, steps = 5, sharpness = 0.9, lo = 0, hi = 1 })
          -- cliffs are rougher than the flat tops: ridged detail weighted by the slope
          local slope = S:Op('slope', { a = steps, mode = 'gradient' })
          local cliff = S:Op('blur', { a = S:Op('clamp', { a = S:Op('affine', { a = slope, mul = 10, add = 0 }), lo = 0, hi = 1 }), radius = 2 })
          local rough = Fractal(S, like, p, 1, { scale = p.scale * 0.18, kind = 'ridged', persistence = 0.55 })
          local detail = S:Op('mul', { a = Centred(S, rough), b = cliff })
          local sum = S:Op('blend', { a = steps, b = detail, mode = 'add', opacity = 0.35 })
          local grit = Fractal(S, like, p, 2, { scale = p.scale * 0.15, octaves = 3, kind = 'fbm' })
          return S:Op('blend', { a = sum, b = Centred(S, grit), mode = 'add', opacity = 0.03 })
      end },
    { id = 'dunes', label = 'Dunes', scale = 120, amplitude = 10, gullies = 0, warp = 0.5, detail = 0.4,
      tip = 'Sand dunes: long crests with a gentle windward and a steep lee side, meandering and uneven.',
      build = function(S, like, p)
          local d = S:Op('dunes', { like = like, seed = Seed(p, 0), wavelength = p.scale, angle = math.mod(math.floor(p.seed) * 47, 180), asym = 0.9, warp = p.warp * 0.5 * p.scale,
                                    warp_size = p.scale * 2, variation = 0.6, ripples = 0 })
          -- some stretches carry big dunes, some are flat
          local patchy = S:Op('smoothstep', { a = Fractal(S, like, p, 1, { scale = p.scale * 2.5, octaves = 2, finest = p.scale }), edge0 = 0.35, edge1 = 0.65 })
          local big = S:Op('blend', { a = d, b = patchy, mode = 'mul', opacity = 0.8 })
          return S:Op('blend', { a = big, b = Fractal(S, like, p, 2, { scale = p.scale * 0.75, persistence = 0.45 }), mode = 'normal', opacity = 0.25 })
      end },
    { id = 'plains', label = 'Plains detail', scale = 90, amplitude = 4, gullies = 0, warp = 0.3, detail = 0.8,
      tip = 'Small, soft relief for flat ground: gentle swells and a little roughness, so open ground does not look ironed.',
      build = function(S, like, p)
          return Fractal(S, like, p, 0, { scale = p.scale, kind = 'fbm', persistence = 0.45, warp = p.warp * 0.15 * p.scale, slope_detail = 0.7 })
      end },
    { id = 'rocks', label = 'Rocks', scale = 45, amplitude = 10, gullies = 0, warp = 0.3, detail = 0.6,
      tip = 'Fields of boulders: rounded cells (cellular noise) roughened by fractal noise.',
      build = function(S, like, p)
          local cells = S:Op('cells', { like = like, seed = Seed(p, 0), scale = p.scale, mode = 'f1', warp = p.warp * 0.2 * p.scale, warp_scale = p.scale * 0.8 })
          local domes = S:Op('invert', { a = cells, lo = 0, hi = 1 })
          return S:Op('blend', { a = domes, b = Fractal(S, like, p, 1, { scale = p.scale * 0.8, persistence = 0.5 }), mode = 'normal', opacity = 0.3 })
      end },
}

function PresetOf(id)
    for _, def in Presets do
        if def.id == id then return def end
    end
    return Presets[1]
end

--- Takes the preset's own values into the settings (the preset buttons of the panel).
function Choose(id)
    local def = PresetOf(id)
    local s = Settings
    s.preset = def.id
    s.scale, s.amplitude, s.gullies, s.warp, s.detail = def.scale, def.amplitude, def.gullies, def.warp, def.detail
end

-- ---- relief ------------------------------------------------------------------------------------------------------------------------------------------

--- A brief droplet erosion of a relief (units: the relief runs 0 .. 2 * amplitude): gullies and drainage, `gullies` 0..1 is how many droplets. Returns the eroded field (owned by S).
local function Weather(S, raw, p)
    local Erosion = import('/lua/editor/erosion.lua')
    local v = Erosion.Defaults('droplet')
    local mine = { density = 0.3 + 3.2 * p.gullies, lifetime = 70, inertia = 0.25, capacity = 6, erode = 0.45, deposit = 0.12, gravity = 5, thermal = 0.4, thermal_steps = 3,
                   talus = 0.9, vary = 0.4, protect = 0.5, drop_vary = 0.6, radius = 2, max_change = math.max(1, p.amplitude * 0.5) }
    for k, x in mine do v[k] = x end
    local relief = S:Op('amplitude', { a = raw, amplitude = math.max(1, p.amplitude) * 2, mode = 'range', centre = 'min' })
    local params = Erosion.OpParams('droplet', v, 1, Seed(p, 100))
    params.a = relief
    params.masks = 0
    local main, extra = Fields.OpMulti('erode_droplet', params)        -- the engine may hand back more than the height: the caller owns every handle
    if not main then error(tostring(extra)) end
    S:Add(main)
    if extra then
        for _, f in extra do S:Add(f) end
    end
    return main
end

function Relief(S, like, p)
    local def = PresetOf(p.preset)
    local raw = def.build(S, like, p)
    if p.gullies > 0.001 then raw = Weather(S, raw, p) end
    return S:Op('amplitude', { a = raw, amplitude = p.amplitude, mode = 'peak' })
end

-- ---- masks and protection ----------------------------------------------------------------------------------------------------------------------------

local function MapDoc()
    local ok, Map = pcall(import, '/lua/editor/map.lua')
    if ok and Map and Map.Doc then return Map.Doc end
    return nil
end

--- The protected spots of the open map as a flat list x, z, radius, 1: starts (radius), Mass and Hydrocarbon (0.4 * radius, at least 4 units).
function Pads(p)
    local doc = MapDoc()
    local list = {}
    if not doc then return list end
    local ok, markers = pcall(function() return doc.save.MasterChain._MASTERCHAIN_.Markers end)
    if not ok or not markers then return list end
    local names = {}
    for name, _ in markers do table.insert(names, name) end
    table.sort(names)
    for _, name in names do
        local m = markers[name]
        if m and m.position then
            local r
            if string.find(name, '^ARMY_%d+$') then
                r = p.flatRadius
            elseif m.type == 'Mass' or m.type == 'Hydrocarbon' then
                r = math.max(4, p.flatRadius * 0.4)
            end
            if r then
                table.insert(list, m.position[1]) table.insert(list, m.position[3]) table.insert(list, r) table.insert(list, 1)
            end
        end
    end
    return list
end

--- The rectangle (world units) of the chosen mask, or nil, text when it cannot be made.
local function MaskRect(p)
    if p.mask == 2 then
        local ok, Playable = pcall(import, '/lua/editor/playable.lua')
        if not ok or not Playable then return nil, 'no playable area' end
        local x0, z0, x1, z1 = Playable.Get()
        return { x0, z0, x1, z1 }
    elseif p.mask == 3 then
        local doc = MapDoc()
        local okT, Tools = pcall(import, '/lua/editor/tools.lua')
        if not doc or not okT or not Tools then return nil, 'select an area first (Select area tool)' end
        for _, it in Tools.Items do
            if it.kind == 'area' then
                local a = doc.save.Areas and doc.save.Areas[it.name]
                if a and a.rectangle then
                    local r = a.rectangle
                    return { math.min(r[1], r[3]), math.min(r[2], r[4]), math.max(r[1], r[3]), math.max(r[2], r[4]) }
                end
            end
        end
        return nil, 'select an area first (Select area tool)'
    end
    return nil
end

--- The mask field (1 inside, soft border of p.feather units inside the rectangle), nil for the whole map. Second result: why a choice cannot be made.
function MaskField(S, like, p)
    if p.mask == 1 or not p.mask then return nil end
    local rect, why = MaskRect(p)
    if not rect then return nil, why end
    local w, h, cell = Fields.Info(like)
    local function Ix(v, n) return math.max(0, math.min(n - 1, math.floor(v / cell + 0.5))) end
    local x0, z0, x1, z1 = Ix(rect[1], w), Ix(rect[2], h), Ix(rect[3], w), Ix(rect[4], h)
    local feather = math.min(p.feather / cell, 0.5 * math.min(x1 - x0, z1 - z0))
    return S:Op('rect_mask', { like = like, x0 = x0, z0 = z0, x1 = x1, z1 = z1, feather = feather })
end

--- The water elevation of the map, or nil when the map has no water.
function WaterLevel()
    local ok, v = pcall(function()
        local world = import('/lua/editor/world.lua').Get()
        if (world.water_on or 1) == 0 then return nil end
        return world.water_elev
    end)
    if ok then return v end
    return nil
end

-- ---- mixing ------------------------------------------------------------------------------------------------------------------------------------------

--- The terrain H with the relief G mixed in. o: mode, strength, mask (field), pts + feather (protected spots), water + margin. Returns the terrain (owned by S) and the mask that was used (or nil).
function Combine(S, H, G, o)
    local mask = o.mask
    if o.pts and table.getn(o.pts) >= 4 then
        local near = S:Op('points_mask', { like = H, pts = o.pts, feather = o.feather or 14 })
        local away = S:Op('invert', { a = near, lo = 0, hi = 1 })
        if mask then mask = S:Op('mul', { a = mask, b = away }) else mask = away end
    end
    local T = S:Op('terrain_mix', { a = H, b = G, mask = mask, mode = o.mode or 'add', strength = o.strength or 1 })
    if o.water then T = S:Op('keep_side', { a = T, b = H, level = o.water, margin = o.margin or 0.25, soft = 1 }) end
    return T, mask
end

--- How much T differs from H: max / mean of the absolute change, the share of samples that moved by more than 0.05 units, and the change itself (a field owned by S).
function Difference(S, T, H)
    local change = S:Op('sub', { a = T, b = H })
    local mag = S:Op('abs', { a = change })
    local _, mx, mean = Fields.Stats(mag)
    local moved = S:Op('threshold', { a = mag, value = 0.05 })
    local _, _, share = Fields.Stats(moved)
    return { max = mx, mean = mean, share = share, change = change }
end

function Describe(stats)
    if stats.max < 0.05 then return 'No change: nothing moves by more than 0.05 units' end
    return string.format('Changes heights by up to %.1f units, %.1f on average, over %d%% of the map', stats.max, stats.mean, math.floor(stats.share * 100 + 0.5))
end

-- ---- on the map --------------------------------------------------------------------------------------------------------------------------------------

local function Copy(t)
    local c = {}
    for k, v in t do c[k] = v end
    return c
end

--- Generates with settings p (default Settings) on the heights of the open map. Returns result { terrain, change, stats, text, note } or nil, message. The caller frees it with Free.
function Build(p)
    p = Copy(p or Settings)
    local w, h = ed_terrain_info()
    if not w then return nil, 'no map is open' end
    if not Fields.IsAvailable() then return nil, 'the field engine is not available' end
    local S = Fields.Scope()
    local ok, result, why = pcall(function()
        local H = S:Height(1)
        local mask, maskWhy = MaskField(S, H, p)
        if maskWhy then return nil, maskWhy end
        local G = Relief(S, H, p)
        local o = { mode = p.blend, strength = p.strength, mask = mask, feather = math.max(4, p.flatRadius * 0.6) }
        if p.keepFlat then o.pts = Pads(p) end
        if p.keepWater then o.water = WaterLevel() end
        local T = Combine(S, H, G, o)
        local stats = Difference(S, T, H)
        local r = { terrain = S:Keep(T), change = S:Keep(stats.change), stats = stats }
        r.text = Describe(stats)
        stats.change = nil
        return r
    end)
    S:Free()
    if not ok then return nil, tostring(result) end
    if not result then return nil, why end
    return result
end

--- Writes the generated terrain into the map: one undo entry. Returns the number of samples changed (nil, message on failure).
function Commit(result, label)
    local n, err = Fields.CommitHeight(result.terrain, { label = label or ('Generate terrain: ' .. PresetOf(Settings.preset).label) })
    if not n then return nil, err end
    return n
end

function Free(result)
    if not result then return end
    if result.terrain then Fields.Free(result.terrain) result.terrain = nil end
    if result.change then Fields.Free(result.change) result.change = nil end
end
