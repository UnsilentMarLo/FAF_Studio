-- Mask generator (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2): a rule list that makes a 0..1 mask over the whole map from the terrain, built on the native field engine
-- (fields.lua). Nothing here loops over the map in Lua: a rule is a few field ops, the list is evaluated top to bottom in C++, and only the result is written back.
--
-- A definition is { rules = { rule, ... } }; a rule is { type, op, invert, enabled, v = { parameter values } }.
--   Source rules make a mask and combine it with what the rules above made (rule.op): and (the smaller), or (the larger), mul (multiply), sub (difference: what is there minus this),
--   add; rule.invert turns the rule into its "not" first. Modifier rules work on the result so far: not, blur, grow, shrink, open, close, threshold, smoothstep, amount.
--   The height and slope rules can WOBBLE their limits by fractal noise (wobble, wsize, wseed: an edge that is ragged but stays soft) and the height rule can start higher on the sun side (sun, sunaz);
--   noise kind 5 is the engine's `fractal` (every octave in its own turned frame, no lattice seams).
--   Sources: slope (degrees), unitclass (the engine's own rule for a footprint: pathable / blocked for land, hover and amphibious units, or buildable for structures), height, curvature
--   (convex / concave), aspect (facing an azimuth: sun side), water (above, below, shoreline band, relative to the map's water surface), noise, flow (drainage area: rivers), position
--   (gradient or distance from the middle: map edge masks), layer (what a texture layer covers), free_above (not covered by the layers above a layer: the strata cascade), near_layer, const.
--
--   Types, Order, NewRule(type), Describe(rule), Ops        the rule catalogue (the panel builds its sliders from it)
--   NewContext(scope, opts) -> ctx                           the heights and map facts the rules read; opts.step (1 = full resolution, 2 = preview on big maps)
--   Evaluate(ctx, def) -> field | nil, message               the mask (owned by ctx's scope)
--   PreviewDef(def) -> field | nil, message                  evaluates at preview resolution and keeps it as the preview (drawn on the map by DrawOverlay, in the panel as a thumbnail)
--   Defer(fn)                                                runs a re-evaluation now or, when one ran less than 80 ms ago, in a moment (the last one wins): what a slider that drags calls
--   ApplyToLayer(def, target) / ApplyToTypes(def, target)    write the mask into a texture layer's paint mask / the terrain-type grid: ONE undo step each
--   FreeAbove(ctx, layer)                                    field: how much of every cell the layers above `layer` leave free
--   Presets, LoadPreset(def, id)                             starting points (cliffs, beach, snow ...)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local World = import('/lua/editor/world.lua')
local Strata = import('/lua/editor/strata.lua')
local GenSym = import('/lua/editor/gensym.lua')

-- ---- the catalogue ----------------------------------------------------------------------------------------------------------------------------------

local function P(key, label, min, max, step, fmt, default)
    return { key = key, label = label, min = min, max = max, step = step, fmt = fmt, default = default }
end

Ops = {
    { id = 'and', label = 'AND (the smaller)' },
    { id = 'or', label = 'OR (the larger)' },
    { id = 'mul', label = 'Multiply' },
    { id = 'sub', label = 'Difference (minus)' },
    { id = 'add', label = 'Add' },
}

CLASSES = {
    { name = 'Land, small (1x1)', kind = 'rating', window = 1, limit = 0.75 },
    { name = 'Land, medium (2x2)', kind = 'rating', window = 2, limit = 0.75 },
    { name = 'Land, large (3x3)', kind = 'rating', window = 3, limit = 0.75 },
    { name = 'Experimental (5x5)', kind = 'rating', window = 5, limit = 0.75 },
    { name = 'Structure (ground variation)', kind = 'variation', window = 2, limit = 1.1 },
}

Types = {
    slope = { label = 'Slope', kind = 'source', params = {
        P('lo', 'From (degrees)', 0, 89, 0.5, '%.1f', 0), P('hi', 'To (degrees)', 0.5, 90, 0.5, '%.1f', 25), P('soft', 'Soft edge (degrees)', 0, 45, 0.5, '%.1f', 3),
        P('wobble', 'Wobble (degrees, fractal noise)', 0, 30, 0.5, '%.1f', 0), P('wsize', 'Wobble feature size (units)', 8, 600, 2, '%d', 80), P('wseed', 'Wobble seed', 0, 9999, 1, '%d', 1) } },
    unitclass = { label = 'Unit class slope', kind = 'source', params = {
        P('class', 'Class (1-3 land by size, 4 experimental, 5 structure)', 1, 5, 1, '%d', 1), P('limit', 'Limit (0 = the class rule)', 0, 4, 0.05, '%.2f', 0),
        P('soft', 'Soft edge', 0, 1, 0.01, '%.2f', 0.05), P('blocked', 'Mask the blocked ground (1) or the passable (0)', 0, 1, 1, '%d', 0) } },
    height = { label = 'Height band', kind = 'source', params = {
        P('lo', 'From (units)', -100, 600, 0.5, '%.1f', 0), P('hi', 'To (units)', -100, 600, 0.5, '%.1f', 40), P('soft', 'Soft edge (units)', 0, 100, 0.5, '%.1f', 4),
        P('wobble', 'Wobble (units, fractal noise)', 0, 100, 0.5, '%.1f', 0), P('wsize', 'Wobble feature size (units)', 8, 600, 2, '%d', 80), P('wseed', 'Wobble seed', 0, 9999, 1, '%d', 1),
        P('sun', 'Sun side starts the band higher by (units; negative: lower)', -100, 100, 0.5, '%.1f', 0), P('sunaz', 'Sun direction (degrees, 0 = +x, 90 = +z)', 0, 360, 5, '%d', 225) } },
    curvature = { label = 'Curvature', kind = 'source', params = {
        P('radius', 'Radius (units)', 1, 60, 1, '%d', 6), P('gain', 'Gain', 1, 300, 1, '%d', 25), P('lo', 'From (0.5 = flat)', 0, 1, 0.01, '%.2f', 0.56),
        P('hi', 'To (1 = sharpest ridge)', 0, 1, 0.01, '%.2f', 1), P('soft', 'Soft edge', 0, 0.5, 0.01, '%.2f', 0.04) } },
    relief = { label = 'Relief (height above the surroundings)', kind = 'source', params = {
        P('radius', 'Surroundings: blur radius (units)', 8, 300, 2, '%d', 60), P('lo', 'From (units above the surroundings)', -60, 60, 0.25, '%.2f', 0.5),
        P('hi', 'To (units above the surroundings)', -60, 100, 0.25, '%.2f', 100), P('soft', 'Soft edge (units)', 0, 30, 0.25, '%.2f', 1.5) } },
    aspect = { label = 'Aspect (facing)', kind = 'source', params = {
        P('azimuth', 'Facing direction (degrees, 0 = +x, 90 = +z)', 0, 360, 5, '%d', 225), P('from', 'Facing from (0.5 = across, 1 = straight at it)', 0, 1, 0.01, '%.2f', 0.6),
        P('soft', 'Soft edge', 0, 1, 0.01, '%.2f', 0.15), P('flat', 'Level below this rise per run', 0.005, 1, 0.005, '%.3f', 0.05) } },
    water = { label = 'Water', kind = 'source', params = {
        P('mode', 'Mode (1 land above, 2 under water, 3 shore band)', 1, 3, 1, '%d', 1), P('offset', 'Level above the water surface (units)', -60, 200, 0.5, '%.1f', 0),
        P('width', 'Band half width (mode 3, units)', 0, 50, 0.5, '%.1f', 2), P('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 2) } },
    shoredist = { label = 'Shore (width along the ground)', kind = 'source', params = {
        P('width', 'Width on land (units)', 0, 100, 0.5, '%.1f', 6), P('depth', 'Shallow water that counts (units)', 0, 30, 0.5, '%.1f', 3), P('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 3) } },
    noise = { label = 'Noise', kind = 'source', params = {
        P('kind', 'Kind (1 perlin, 2 simplex, 3 ridged, 4 billow, 5 fractal)', 1, 5, 1, '%d', 1), P('seed', 'Seed', 0, 9999, 1, '%d', 1), P('size', 'Feature size (units)', 4, 600, 2, '%d', 60),
        P('octaves', 'Octaves', 1, 8, 1, '%d', 4), P('from', 'From', 0, 1, 0.01, '%.2f', 0.45), P('to', 'To', 0, 1, 0.01, '%.2f', 0.65) } },
    flow = { label = 'Flow (drainage)', kind = 'source', params = {
        P('range', 'Catchment area that reads 1 (x1000 units squared)', 10, 100000, 10, '%d', 1000), P('from', 'From', 0, 1, 0.01, '%.2f', 0.5), P('to', 'To', 0, 1, 0.01, '%.2f', 0.7) } },
    position = { label = 'Position', kind = 'source', params = {
        P('kind', 'Kind (1 linear, 2 distance from the middle)', 1, 2, 1, '%d', 1), P('angle', 'Direction (degrees)', 0, 360, 5, '%d', 90),
        P('from', 'From', -1, 2, 0.01, '%.2f', 0), P('to', 'To', -1, 2, 0.01, '%.2f', 1) } },
    layer = { label = 'Texture layer', kind = 'source', params = {
        P('layer', 'Layer', 1, 8, 1, '%d', 1), P('visible', 'Only where visible (1) or all of it (0)', 0, 1, 1, '%d', 0) } },
    free_above = { label = 'Free of layers above', kind = 'source', params = { P('layer', 'Layers above this one', 0, 8, 1, '%d', 1) } },
    near_layer = { label = 'Near a texture layer', kind = 'source', params = {
        P('layer', 'Layer', 1, 8, 1, '%d', 1), P('distance', 'Distance (units)', 0, 300, 1, '%d', 12), P('soft', 'Soft edge (units)', 0, 100, 1, '%d', 4) } },
    const = { label = 'Constant', kind = 'source', params = { P('value', 'Value', 0, 1, 0.05, '%.2f', 1) } },
    named = { label = 'Imported mask', kind = 'source', params = { P('slot', 'Slot of the imported mask (Interop panel)', 1, 16, 1, '%d', 1) } },
    ['not'] = { label = 'Not (invert)', kind = 'modifier', params = {} },
    blur = { label = 'Blur', kind = 'modifier', params = { P('radius', 'Sigma (units)', 0.5, 100, 0.5, '%.1f', 6) } },
    grow = { label = 'Grow', kind = 'modifier', params = { P('distance', 'Distance (units)', 0.5, 200, 0.5, '%.1f', 6), P('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 2) } },
    shrink = { label = 'Shrink', kind = 'modifier', params = { P('distance', 'Distance (units)', 0.5, 200, 0.5, '%.1f', 6), P('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 2) } },
    open = { label = 'Remove specks', kind = 'modifier', params = { P('radius', 'Smaller than (units)', 0.5, 100, 0.5, '%.1f', 3) } },
    close = { label = 'Fill holes', kind = 'modifier', params = { P('radius', 'Smaller than (units)', 0.5, 100, 0.5, '%.1f', 3) } },
    threshold = { label = 'Threshold', kind = 'modifier', params = { P('value', 'Above', 0, 1, 0.01, '%.2f', 0.5) } },
    smoothstep = { label = 'Smooth step', kind = 'modifier', params = { P('edge0', 'Edge 0', 0, 1, 0.01, '%.2f', 0.3), P('edge1', 'Edge 1', 0, 1, 0.01, '%.2f', 0.7) } },
    amount = { label = 'Amount', kind = 'modifier', params = { P('factor', 'Multiply by', 0, 10, 0.05, '%.2f', 1.5) } },
    crisp = { label = 'Ragged edge', kind = 'modifier', params = {
        P('crisp', 'Crispness (0 soft, 1 sharp)', 0, 1, 0.05, '%.2f', 0.5), P('noise', 'Edge noise', 0, 1, 0.05, '%.2f', 0.35), P('size', 'Noise feature size (units)', 4, 300, 2, '%d', 24), P('seed', 'Seed', 0, 9999, 1, '%d', 1) } },
    grain = { label = 'Fine grain', kind = 'modifier', params = {
        P('amount', 'How much the paint varies (0..1)', 0, 1, 0.05, '%.2f', 0.3), P('size', 'Grain size (units)', 2, 60, 1, '%d', 7), P('seed', 'Seed', 0, 9999, 1, '%d', 1) } },
}

Order = { 'slope', 'unitclass', 'height', 'curvature', 'relief', 'aspect', 'water', 'shoredist', 'noise', 'flow', 'position', 'layer', 'free_above', 'near_layer', 'const', 'named',
          'not', 'blur', 'grow', 'shrink', 'open', 'close', 'threshold', 'smoothstep', 'amount', 'crisp', 'grain' }

--- A rule of `type` with the default values.
function NewRule(type)
    local t = Types[type]
    local rule = { type = type, op = 'and', invert = false, enabled = true, v = {} }
    for _, p in t.params do rule.v[p.key] = p.default end
    return rule
end

--- A short text for lists: 'slope  0 / 25 / 3'.
function Describe(rule)
    local t = Types[rule.type]
    if not t then return tostring(rule.type) end
    local parts = {}
    for _, p in t.params do
        if table.getn(parts) < 3 then
            local v = rule.v[p.key]
            table.insert(parts, string.format(p.fmt, v == nil and p.default or v))
        end
    end
    local text = t.label
    if table.getn(parts) > 0 then text = text .. '  ' .. table.concat(parts, ' / ') end
    if rule.type == 'unitclass' then
        local c = CLASSES[math.floor((rule.v.class or 1) + 0.5)]
        if c then text = c.name .. ((rule.v.blocked or 0) >= 0.5 and ' blocked' or ' passable') end
    end
    return text
end

-- ---- evaluation context -----------------------------------------------------------------------------------------------------------------------------

--- The heights and the map facts the rules read. step 1 = the heights as they are, 2 = every second sample (the preview of big maps). Fields made through ctx.S are freed with the scope.
function NewContext(S, opts)
    opts = opts or {}
    local step = opts.step or 1
    local H = S:Height(step)
    local w, h, cell = Fields.Info(H)
    local hmin, hmax = Fields.Stats(H)
    local world = World.Get()
    -- symmetry: what the writers (WriteLayer, WriteTypes, recipes.lua) make symmetric. opts.symmetry = a spec (gensym.lua), false for none; not given: the editor's symmetry
    local symmetry = opts.symmetry
    if symmetry == nil then symmetry = GenSym.FromEditor() end
    return { S = S, H = H, w = w, h = h, cell = cell, step = step, hmin = hmin, hmax = hmax, water = world.water_elev or 0, cache = {}, symmetry = symmetry }
end

local function Samples(c, units)
    return math.max(1, math.floor(units / c.cell + 0.5))
end

local function Cached(c, key, make)
    local f = c.cache[key]
    if not f then
        f = make()
        c.cache[key] = f
    end
    return f
end

local function Op(c, name, params) return c.S:Op(name, params) end

--- A paint mask layer (1..8) as an effective 0..1 field on the height grid.
local function LayerField(c, layer)
    return Cached(c, 'layer' .. layer, function()
        return Op(c, 'resample', { a = c.S:Stratum(layer), like = c.H })
    end)
end

--- How much the layers above `layer` leave free: the product of (1 - mask) over layers layer+1 .. 8.
function FreeAbove(c, layer)
    return Cached(c, 'above' .. layer, function()
        local free = Op(c, 'const', { like = c.H, value = 1 })
        for k = layer + 1, 8 do
            local covered = LayerField(c, k)
            free = Op(c, 'mul', { a = free, b = Op(c, 'invert', { a = covered, lo = 0, hi = 1 }) })
        end
        return free
    end)
end

local SOURCE = {}
local MODIFY = {}

--- The field f moved by up to +-amount of fractal noise (feature size `size`, 5 octaves; the noise has mean 0.5 and spread 0.155, so the factor makes the typical shift +-amount / 2): the
--- thresholds of a rule that reads f wobble by a little instead of being cut by noise blobs. amount 0 / nil: f itself.
local function Wobbled(c, f, amount, size, seed)
    if not amount or amount <= 0 then return f end
    local n = Cached(c, 'fractal' .. size .. '_' .. seed, function()
        return Op(c, 'fractal', { like = c.H, seed = math.floor(seed or 1), scale = size or 80, octaves = 5 })
    end)
    return Op(c, 'add', { a = f, b = Op(c, 'affine', { a = n, mul = amount / 0.31, add = -amount * 0.5 / 0.31 }) })
end

function SOURCE.slope(c, v)
    local s = Cached(c, 'slope', function() return Op(c, 'slope', { a = c.H, mode = 'degrees', radius = 1 }) end)
    return Op(c, 'height_band', { a = Wobbled(c, s, v.wobble, v.wsize, v.wseed), lo = v.lo, hi = v.hi, soft = v.soft })
end

function SOURCE.unitclass(c, v)
    local cls = CLASSES[math.max(1, math.min(table.getn(CLASSES), math.floor(v.class + 0.5)))]
    local limit = v.limit > 0 and v.limit or cls.limit
    local window = Samples(c, cls.window)
    local r = Cached(c, cls.kind .. window, function() return Op(c, 'slope', { a = c.H, mode = cls.kind, window = window }) end)
    local pass = Op(c, 'water_below', { a = r, level = limit, soft = v.soft })      -- 1 up to the limit, falling to 0 over `soft` above it
    if v.blocked >= 0.5 then return Op(c, 'invert', { a = pass, lo = 0, hi = 1 }) end
    return pass
end

--- The heights as a height rule reads them: moved by the wobble and, with `sun` (units), lowered on the ground that faces the sun (azimuth `sunaz`) and raised on the far side: a band that
--- starts high up (snow) then starts `sun` units higher on the sunny side and `sun` units lower on the far side.
local function RuleHeights(c, v)
    local f = Wobbled(c, c.H, v.wobble, v.wsize, v.wseed)
    if v.sun and v.sun ~= 0 then
        local n = Samples(c, 6)
        local facing = Cached(c, 'facing' .. v.sunaz .. '_' .. n, function() return Op(c, 'aspect', { a = c.H, azimuth = v.sunaz, flat = 0.03, radius = n }) end)
        f = Op(c, 'sub', { a = f, b = Op(c, 'affine', { a = facing, mul = 2 * v.sun, add = -v.sun }) })
    end
    return f
end

function SOURCE.height(c, v)
    return Op(c, 'height_band', { a = RuleHeights(c, v), lo = v.lo, hi = v.hi, soft = v.soft })
end

function SOURCE.curvature(c, v)
    local n = Samples(c, v.radius)
    local curv = Cached(c, 'curv' .. n .. '_' .. v.gain, function() return Op(c, 'curvature', { a = c.H, radius = n, gain = v.gain }) end)
    return Op(c, 'height_band', { a = curv, lo = v.lo, hi = v.hi, soft = v.soft })
end

--- How far the ground stands above (or below) the average of its surroundings: the ridges and hills of a valley are positive, its floor negative, flat ground is about 0 whatever its altitude.
function SOURCE.relief(c, v)
    local n = Samples(c, v.radius)
    local rel = Cached(c, 'relief' .. n, function() return Op(c, 'sub', { a = c.H, b = Op(c, 'blur', { a = c.H, radius = n }) }) end)
    return Op(c, 'height_band', { a = rel, lo = v.lo, hi = v.hi, soft = v.soft })
end

function SOURCE.aspect(c, v)
    local asp = Op(c, 'aspect', { a = c.H, azimuth = v.azimuth, flat = v.flat, radius = 1 })
    return Op(c, 'height_band', { a = asp, lo = v.from, hi = 1, soft = v.soft })
end

function SOURCE.water(c, v)
    local level = c.water + v.offset
    local mode = math.floor(v.mode + 0.5)
    if mode == 2 then return Op(c, 'water_below', { a = c.H, level = level, soft = v.soft }) end
    if mode == 3 then return Op(c, 'shore', { a = c.H, level = level, width = v.width, soft = v.soft }) end
    return Op(c, 'water_above', { a = c.H, level = level, soft = v.soft })
end

--- A band along the water: the land up to `width` units (along the ground, not up the slope) from the waterline, and the shallow water (up to `depth` units deep) in front of it.
function SOURCE.shoredist(c, v)
    local wet = Op(c, 'water_below', { a = c.H, level = c.water, soft = 0.01 })           -- 1 under water
    local d = Op(c, 'distance', { a = wet, threshold = 0.5, mode = 'outside' })           -- 0 under water, the distance to the water on land
    local land = Op(c, 'water_below', { a = d, level = v.width, soft = math.max(0.5, v.soft) })
    local gate = Op(c, 'water_above', { a = c.H, level = c.water - v.depth, soft = math.max(0.5, v.depth * 0.5) })
    return Op(c, 'mul', { a = land, b = gate })
end

local NOISE = { 'perlin', 'simplex', 'ridged', 'billow', 'fractal' }

function SOURCE.noise(c, v)
    local n = Op(c, NOISE[math.max(1, math.min(5, math.floor(v.kind + 0.5)))], { like = c.H, seed = math.floor(v.seed), scale = v.size, octaves = math.floor(v.octaves) })
    return Op(c, 'smoothstep', { a = n, edge0 = v.from, edge1 = v.to })
end

function SOURCE.flow(c, v)
    local f = Op(c, 'flow', { a = c.H, mode = 'log', range = v.range * 1000 })
    return Op(c, 'smoothstep', { a = f, edge0 = v.from, edge1 = v.to })
end

function SOURCE.position(c, v)
    local g
    if v.kind >= 1.5 then
        g = Op(c, 'radial', { like = c.H })
    else
        g = Op(c, 'gradient', { like = c.H, angle = v.angle, lo = 0, hi = 1 })
    end
    return Op(c, 'smoothstep', { a = g, edge0 = v.from, edge1 = v.to })
end

function SOURCE.layer(c, v)
    local layer = math.floor(v.layer + 0.5)
    local m = LayerField(c, layer)
    if v.visible >= 0.5 then return Op(c, 'mul', { a = m, b = FreeAbove(c, layer) }) end
    return m
end

function SOURCE.free_above(c, v)
    return FreeAbove(c, math.floor(v.layer + 0.5))
end

function SOURCE.near_layer(c, v)
    local m = LayerField(c, math.floor(v.layer + 0.5))
    local d = Op(c, 'distance', { a = m, threshold = 0.5, mode = 'outside' })
    return Op(c, 'water_below', { a = d, level = v.distance, soft = v.soft })
end

function SOURCE.const(c, v)
    return Op(c, 'const', { like = c.H, value = v.value })
end

--- A mask imported from an image file (interop.lua): the file is read when the rule runs, on the height grid. An empty slot masks nothing (0).
function SOURCE.named(c, v)
    local Interop = import('/lua/editor/interop.lua')
    if not Interop.Named[math.floor(v.slot + 0.5)] then return Op(c, 'const', { like = c.H, value = 0 }) end      -- an empty slot masks nothing
    local f, err = Interop.NamedField(c.S, v.slot, c.H)
    if not f then error(err or 'no imported mask') end
    return f
end

local function Clamp01(c, f) return Op(c, 'clamp', { a = f, lo = 0, hi = 1 }) end

MODIFY['not'] = function(c, m, v) return Op(c, 'invert', { a = m, lo = 0, hi = 1 }) end
MODIFY.blur = function(c, m, v) return Clamp01(c, Op(c, 'blur', { a = m, radius = v.radius })) end
MODIFY.threshold = function(c, m, v) return Op(c, 'threshold', { a = m, value = v.value }) end
MODIFY.smoothstep = function(c, m, v) return Op(c, 'smoothstep', { a = m, edge0 = v.edge0, edge1 = v.edge1 }) end
MODIFY.amount = function(c, m, v) return Clamp01(c, Op(c, 'affine', { a = m, mul = v.factor, add = 0 })) end
--- Edges that follow a noise instead of a smooth ramp: the mask plus a noise, run through a smoothstep around one half. crisp 0 keeps the soft ramp (a wide smoothstep), 1 makes the edge sharp,
--- the noise makes it ragged. The inside of the mask (1) and the outside (0) stay as they are.
MODIFY.crisp = function(c, m, v)
    local n = Op(c, 'fractal', { like = c.H, seed = math.floor(v.seed), scale = v.size, octaves = 4 })
    local shifted = Op(c, 'add', { a = m, b = Op(c, 'affine', { a = n, mul = v.noise, add = -0.5 * v.noise }) })
    local w = math.max(0.05, 0.5 * (1 - v.crisp))
    return Clamp01(c, Op(c, 'smoothstep', { a = shifted, edge0 = 0.5 - w, edge1 = 0.5 + w }))
end

--- The paint varies at the size of the texture detail: the mask times a fine noise (1 - amount .. 1).
MODIFY.grain = function(c, m, v)
    local n = Op(c, 'fractal', { like = c.H, seed = math.floor(v.seed), scale = v.size, octaves = 3 })
    return Clamp01(c, Op(c, 'mul', { a = m, b = Op(c, 'affine', { a = n, mul = v.amount, add = 1 - v.amount }) }))
end

local function Grow(c, m, distance, soft)
    local d = Op(c, 'distance', { a = m, threshold = 0.5, mode = 'outside' })          -- 0 inside the mask, the distance to it outside
    return Op(c, 'max', { a = m, b = Op(c, 'water_below', { a = d, level = distance, soft = soft }) })
end

local function Shrink(c, m, distance, soft)
    local d = Op(c, 'distance', { a = m, threshold = 0.5, mode = 'inside' })           -- the distance to the nearest ground outside the mask
    return Op(c, 'min', { a = m, b = Op(c, 'water_above', { a = d, level = distance, soft = soft }) })
end

MODIFY.grow = function(c, m, v) return Grow(c, m, v.distance, v.soft) end
MODIFY.shrink = function(c, m, v) return Shrink(c, m, v.distance, v.soft) end
MODIFY.open = function(c, m, v) return Grow(c, Shrink(c, m, v.radius, 0), v.radius, 0) end
MODIFY.close = function(c, m, v) return Shrink(c, Grow(c, m, v.radius, 0), v.radius, 0) end

local function Combine(c, acc, r, op)
    if op == 'or' then return Op(c, 'max', { a = acc, b = r }) end
    if op == 'mul' then return Op(c, 'mul', { a = acc, b = r }) end
    if op == 'sub' then return Op(c, 'mul', { a = acc, b = Op(c, 'invert', { a = r, lo = 0, hi = 1 }) }) end
    if op == 'add' then return Clamp01(c, Op(c, 'add', { a = acc, b = r })) end
    return Op(c, 'min', { a = acc, b = r })
end

--- Evaluates the rules top to bottom; the mask (0..1, on the height grid) belongs to ctx's scope. nil, message when there is nothing to evaluate or an op failed.
function Evaluate(c, def)
    local ok, acc = pcall(function()
        local acc = nil
        for _, rule in def.rules do
            if rule.enabled ~= false then
                local t = Types[rule.type]
                if not t then error('unknown rule ' .. tostring(rule.type)) end
                local v = {}
                for _, p in t.params do
                    local x = rule.v[p.key]
                    if x == nil then x = p.default end
                    v[p.key] = x
                end
                if t.kind == 'modifier' then
                    if acc then acc = MODIFY[rule.type](c, acc, v) end
                else
                    local r = SOURCE[rule.type](c, v)
                    if rule.invert then r = Op(c, 'invert', { a = r, lo = 0, hi = 1 }) end
                    if acc then acc = Combine(c, acc, r, rule.op) else acc = r end
                end
            end
        end
        return acc
    end)
    if not ok then return nil, tostring(acc) end
    if not acc then return nil, 'no rule is switched on' end
    return acc
end

-- ---- the working definition and the preview ---------------------------------------------------------------------------------------------------------

Def = { rules = {} }              -- what the Mask generator panel edits
Target = { layer = 1, mode = 1, strength = 1, takeAway = false, typeCode = 2, threshold = 0.5, wmask = 1 }
MODES = { 'Replace', 'Add to', 'Subtract from' }

Preview = { field = false, show = true, revision = 0 }

function ClearPreview()
    if Preview.field then Fields.Free(Preview.field) end
    Preview.field = false
    Preview.revision = Preview.revision + 1
end

--- Takes ownership of a field as the preview (the previous one is freed).
function SetPreview(f)
    if Preview.field and Preview.field ~= f then Fields.Free(Preview.field) end
    Preview.field = f or false
    Preview.revision = Preview.revision + 1
end

--- The step the preview is evaluated at: every second sample on the biggest maps.
function PreviewStep()
    local size = ed_terrain_info()
    return (size and size > 700) and 2 or 1
end

--- Evaluates `def` at preview resolution and keeps the result as the preview. Returns the field, or nil and a message.
function PreviewDef(def)
    if not Fields.IsAvailable() or not ed_terrain_info() then return nil, 'no terrain' end
    local S = Fields.Scope()
    local ok, m, err = pcall(function()
        local c = NewContext(S, { step = PreviewStep() })
        return Evaluate(c, def)
    end)
    if not ok then
        S:Free()
        return nil, tostring(m)
    end
    if not m then
        S:Free()
        return nil, err
    end
    S:Keep(m)
    S:Free()
    SetPreview(m)
    return m
end

-- ---- the preview on the map -------------------------------------------------------------------------------------------------------------------------

local overlayKey = ''
local overlayLive = false
local Throttle = import('/lua/editor/throttle.lua')
local overlayThrottle = Throttle.New(Throttle.DEFAULT_MS)       -- at most one upload per 80 ms while a slider is dragged; the last state always arrives

--- Runs `fn` (a re-evaluation of the preview that a slider asked for) now, or in a moment when one ran less than 80 ms ago; a newer call replaces one that waits (throttle.lua).
function Defer(fn)
    Throttle.Defer('maskgen:preview', fn)
end

--- The fallback for an engine without ed_overlay_field: the old node grid (ed_overlay_nodes: up to 290 x 290 nodes, coarser when zoomed out), sampled in Lua. Slow, so it is only called
--- at the throttle's pace.
local function NodeGridOverlay(view, f)
    local Win = import('/lua/editor/overlaywin.lua')
    local x0, z0, nw, nh, step = Win.Window(view, 290)
    if not x0 then return end
    local key = x0 .. '|' .. z0 .. '|' .. nw .. '|' .. nh .. '|' .. step .. '|' .. Preview.revision
    if key == overlayKey then return end
    overlayThrottle:Push(key)
    if not overlayThrottle:Poll() then return end
    overlayKey = key
    local w, h, cell, ox, oz = Fields.Info(f)
    -- the field samples under the window: one read of the box that holds them
    local function Index(wx, wz)
        return math.max(0, math.min(w - 1, math.floor((wx - ox) / cell + 0.5))), math.max(0, math.min(h - 1, math.floor((wz - oz) / cell + 0.5)))
    end
    local ix0, iz0 = Index(x0, z0)
    local ix1, iz1 = Index(x0 + (nw - 1) * step, z0 + (nh - 1) * step)
    local rw, rh = ix1 - ix0 + 1, iz1 - iz0 + 1
    local grid = {}
    local n = 0
    if rw * rh <= 65536 then
        local vals = Fields.Read(f, ix0, iz0, ix1, iz1)
        if not vals then return end
        for j = 0, nh - 1 do
            local _, iz = Index(x0, z0 + j * step)
            for i = 0, nw - 1 do
                local ix = Index(x0 + i * step, z0)
                local v = vals[(iz - iz0) * rw + (ix - ix0) + 1] or 0
                n = n + 1
                grid[n] = Win.Level(v)
            end
        end
    else
        -- too many samples for one read (a big window on a fine field): sample the nodes one by one
        for j = 0, nh - 1 do
            for i = 0, nw - 1 do
                n = n + 1
                grid[n] = Win.Level(Fields.Sample(f, x0 + i * step, z0 + j * step))
            end
        end
    end
    ed_overlay_nodes('maskgen:mask', x0, z0, nw, nh, grid, 'FF3030', 170, step)
    overlayLive = true
end

--- Called every frame by overlay.lua: draws the preview mask as red squares over everything of the map the camera sees. The engine does it all (ed_overlay_field: it keeps the field,
--- samples it at the resolution the camera needs and drapes it over the ground, depth tested), so a new preview costs one call with the field's handle, not a table of 90000 numbers.
function DrawOverlay(view)
    Throttle.Pump()                 -- the waiting slider updates (this is the one per-frame hook the Mask generator, Recipes and Graph previews all have)
    local f = Preview.field
    local native = rawget(_G, 'ed_overlay_field')
    if not (f and Preview.show) or not (native or rawget(_G, 'ed_overlay_nodes')) then
        if overlayLive then
            ed_overlay_remove('maskgen:mask')
            overlayLive = false
            overlayKey = ''
            overlayThrottle:Cancel()
        end
        return
    end
    if native then
        local key = f .. '|' .. Preview.revision
        if key == overlayKey then return end
        overlayThrottle:Push(key)
        if not overlayThrottle:Poll() then return end
        overlayKey = key
        local ok, err = native('maskgen:mask', f, 'FF3030', 170, { reduce = 'avg' })
        overlayLive = ok and true or false
        if not ok then LOG('EDITOR mask overlay: ' .. tostring(err)) end
        return
    end
    if ed_terrain_info() then NodeGridOverlay(view, f) end
end

function OverlayReset()
    overlayKey = ''
    overlayLive = false
    overlayThrottle:Cancel()
end

-- ---- outputs ----------------------------------------------------------------------------------------------------------------------------------------

--- Makes sure layers 5..8 can show (the legacy terrain technique blends layers 1..4 only).
local function EnsureShader(layer)
    if layer >= 5 and rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() == 'TTerrain' then ed_stratum_shader('TTerrainXP') end
end

--- Writes mask `m` (a field on any grid) into texture layer `layer` (1..8). target.mode 1 replace, 2 add to (the larger), 3 subtract from; target.strength 0..1 blends old and new;
--- target.takeAway keeps the mask to the ground the layers above leave free. Returns the undo entry (pushed unless noPush) and the cells changed.
function WriteLayer(c, m, layer, target, noPush)
    -- a layer the map's shader does not paint (layer 8 of the numbered shaders is the roughness multiplier or map-wide data, layers 5-8 of TTerrainGlow are not drawn): refused, as in recipes.lua
    local why = Strata.WhyNotPaintable(layer)
    if why then return nil, why end
    EnsureShader(layer)
    local S = c.S
    m = GenSym.Field(S, m, c.symmetry, { seam = 8 })
    if target.takeAway then m = Op(c, 'mul', { a = m, b = FreeAbove(c, layer) }) end
    local old = S:Stratum(layer)
    local onGrid = Op(c, 'resample', { a = m, like = old })
    local f = onGrid
    local mode = target.mode or 1
    if mode == 2 then f = Op(c, 'max', { a = old, b = onGrid })
    elseif mode == 3 then f = Op(c, 'mul', { a = old, b = Op(c, 'invert', { a = onGrid, lo = 0, hi = 1 }) }) end
    return Fields.CommitMask(f, layer, { strength = target.strength or 1, noPush = noPush, label = 'mask to layer ' .. layer })
end

--- Evaluates `def` at full resolution and writes it into the target layer: one undo step. Returns the number of mask cells changed (nil, message on failure).
function ApplyToLayer(def, target)
    target = target or Target
    if not ed_stratum_info() then return nil, 'the map has no paint masks' end
    local why = Strata.WhyNotPaintable(target.layer)
    if why then return nil, why end
    return Fields.Run(function(S)
        local c = NewContext(S, { step = 1 })
        local m, err = Evaluate(c, def)
        if not m then return nil, err end
        local entry, n = WriteLayer(c, m, math.floor(target.layer + 0.5), target)
        if not entry then return nil, n == 0 and 'nothing changed' or tostring(n) end
        if target.texture and target.texture ~= 'keep' then
            pcall(function() import('/lua/editor/texsets.lua').ApplyRole(math.floor(target.layer + 0.5), target.texture) end)
        end
        return n
    end)
end

--- Writes terrain type `code` into the terrain-type grid where `m` is above `threshold`. Returns the undo entry (pushed unless noPush) and the cells changed.
function WriteTypes(c, m, code, threshold, noPush)
    local S = c.S
    m = GenSym.Field(S, m, c.symmetry, { seam = 8 })
    local tt = S:Add(Fields.TerrainTypes())
    local onGrid = Op(c, 'resample', { a = m, like = tt })
    local sel = Op(c, 'threshold', { a = onGrid, value = threshold })
    local codes = Op(c, 'blend', { a = tt, b = Op(c, 'const', { like = tt, value = code }), mask = sel })
    return Fields.CommitTypes(codes, { noPush = noPush, label = 'mask to terrain type ' .. code })
end

function ApplyToTypes(def, target)
    target = target or Target
    if not rawget(_G, 'ed_tt_info') or not ed_tt_info() then return nil, 'the map has no terrain type grid' end
    return Fields.Run(function(S)
        local c = NewContext(S, { step = 1 })
        local m, err = Evaluate(c, def)
        if not m then return nil, err end
        local entry, n = WriteTypes(c, m, math.floor(target.typeCode + 0.5), target.threshold or 0.5)
        if not entry then return nil, n == 0 and 'nothing changed' or tostring(n) end
        return n
    end)
end

--- Writes mask `m` into water mask `kind` (1 foam, 2 flatness, 3 depth bias) with target.mode (1 replace, 2 add to, 3 subtract from) and target.strength. Returns the undo entry (pushed unless noPush) and the cells changed.
function WriteWaterMask(c, m, kind, target, noPush)
    local S = c.S
    local old = S:Add(Fields.WaterMask(kind))
    local onGrid = Op(c, 'resample', { a = m, like = old })
    local f = onGrid
    local mode = target.mode or 1
    if mode == 2 then f = Op(c, 'max', { a = old, b = onGrid })
    elseif mode == 3 then f = Op(c, 'mul', { a = old, b = Op(c, 'invert', { a = onGrid, lo = 0, hi = 1 }) }) end
    return Fields.CommitWaterMask(f, kind, { strength = target.strength or 1, noPush = noPush })
end

function ApplyToWaterMask(def, target)
    target = target or Target
    if not rawget(_G, 'ed_field_wmask') then return nil, 'this engine build has no water masks' end
    return Fields.Run(function(S)
        local c = NewContext(S, { step = 1 })
        local m, err = Evaluate(c, def)
        if not m then return nil, err end
        local entry, n = WriteWaterMask(c, m, math.floor((target.wmask or 1) + 0.5), target)
        if not entry then return nil, n == 0 and 'nothing changed' or tostring(n) end
        return n
    end)
end

-- ---- starting points --------------------------------------------------------------------------------------------------------------------------------

local function Rule(type, values, op, invert)
    local r = NewRule(type)
    for k, x in (values or {}) do r.v[k] = x end
    r.op = op or 'and'
    r.invert = invert or false
    return r
end

local function Heights()
    local lo, hi = 0, 100
    if Fields.IsAvailable() and ed_terrain_info() then
        lo, hi = Fields.Run(function(S)
            local mn, mx = Fields.Stats(S:Height(4))
            return mn, mx
        end)
    end
    return lo, hi
end

Presets = {
    { id = 'cliffs', name = 'Cliffs (steep ground)', make = function()
        return { Rule('slope', { lo = 38, hi = 90, soft = 6 }), Rule('blur', { radius = 2 }) } end },
    { id = 'blocked', name = 'Ground land units cannot cross', make = function()
        return { Rule('unitclass', { class = 1, blocked = 1, soft = 0.05 }) } end },
    { id = 'buildable', name = 'Buildable flat ground (structures, above water)', make = function()
        return { Rule('unitclass', { class = 5, blocked = 0, soft = 0.05 }), Rule('water', { mode = 1, offset = 0.5, soft = 0.5 }) } end },
    { id = 'beach', name = 'Beach (shore band on gentle ground)', make = function()
        return { Rule('water', { mode = 3, offset = 0.5, width = 3, soft = 2 }), Rule('slope', { lo = 0, hi = 22, soft = 6 }), Rule('blur', { radius = 1.5 }) } end },
    { id = 'snow', name = 'Snow caps (top fifth, not steep, patchy)', make = function()
        local lo, hi = Heights()
        return { Rule('height', { lo = lo + (hi - lo) * 0.78, hi = hi + 50, soft = (hi - lo) * 0.08 }), Rule('slope', { lo = 0, hi = 38, soft = 10 }),
                 Rule('noise', { kind = 1, seed = 3, size = 40, octaves = 4, from = 0.3, to = 0.6 }, 'mul') } end },
    { id = 'ridges', name = 'Ridge tops (convex ground)', make = function()
        return { Rule('curvature', { radius = 6, gain = 30, lo = 0.56, hi = 1, soft = 0.05 }), Rule('blur', { radius = 2 }) } end },
    { id = 'gullies', name = 'Gullies and river beds (drainage on concave ground)', make = function()
        return { Rule('flow', { range = 1000, from = 0.45, to = 0.65 }), Rule('curvature', { radius = 4, gain = 25, lo = 0, hi = 0.46, soft = 0.04 }, 'or'), Rule('blur', { radius = 1.5 }) } end },
    { id = 'sunny', name = 'Sun-facing slopes (south west)', make = function()
        return { Rule('aspect', { azimuth = 225, from = 0.62, soft = 0.2, flat = 0.04 }), Rule('slope', { lo = 6, hi = 60, soft = 6 }) } end },
    { id = 'patches', name = 'Dirt patches (noise on flat ground)', make = function()
        return { Rule('noise', { kind = 1, seed = 5, size = 48, octaves = 4, from = 0.5, to = 0.62 }), Rule('slope', { lo = 0, hi = 28, soft = 8 }) } end },
    { id = 'shorefoam', name = 'Shore foam (the band where land meets water)', make = function()
        return { Rule('water', { mode = 3, offset = 0, width = 2.5, soft = 2.5 }), Rule('blur', { radius = 1.5 }) } end },
    { id = 'deepcalm', name = 'Deep water (for calm patches)', make = function()
        return { Rule('water', { mode = 2, offset = -8, soft = 6 }) } end },
    { id = 'edge', name = 'Map edge band', make = function()
        return { Rule('position', { kind = 2, from = 0.8, to = 1 }) } end },
}

--- Replaces def's rules with the starting point `id` (a number is an index into Presets).
function LoadPreset(def, id)
    for i, p in Presets do
        if p.id == id or i == id then
            def.rules = p.make()
            return p
        end
    end
    return nil
end
