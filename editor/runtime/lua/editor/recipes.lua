-- Stratum recipes (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2): a recipe paints the texture layers of the map with the eight kinds of ground a landscape is made of, from height, slope,
-- curvature, water and noise rules. Apply fills the paint masks (and, if asked, the terrain-type grid) in one undo step. The rules are the mask generator's (maskgen.lua).
--
-- THE EIGHT ROLES. Every role has a SELECTION rule (where this kind of ground belongs) built from the map's own numbers, never fixed heights. Every selection is made of WIDE SMOOTH RAMPS (a
-- height or slope ramp goes from 0 to 1 over 10 to 25 percent of the relief or 15 to 25 degrees) and a blur of 3 units or more; noise never cuts a shape out, it only wobbles the thresholds
-- of the ramps by a few percent (fractal noise of 40 to 160 units) so that edges are ragged but soft. Secondary kinds stay below full opacity, so the kind below shows through.
--   grass     open ground: gentle ground above the beach and below the snow line (only drawn when grass is NOT the base layer: the base is what is left). A second grass layer is a soft partial mix
--   dirt      a low contrast patchwork on flat ground: a wide smoothstep of fractal noise calibrated so that it covers Dirt coverage of the map, at most 0.9 opacity
--   wet       wet ground: concave drainage lines (gullies) and the strip along the waterline, at most 0.7 opacity
--   sand      beach: the shore band of Beach half width on gentle ground (only when the map has water; a dry map only has it in the desert style: dry low basins)
--   rock      slopes: opacity rises with the slope from Rock slope (0) to Cliff slope (1)
--   darkrock  occlusion: concave ground on slopes (the foot of cliffs, gullies), wide and blurred, at most 0.15 + 0.4 * Dark rock opacity
--   highrock  altitude: a ramp from High rock starts at (share of the height range) up, strongest on steep and convex ground, still 0.3 on flat high ground
--   snow      altitude: a ramp around the snow line (the top Snow covers share of the land), reduced on steep ground (it does not stay on cliffs), ragged but soft at the edge
--
-- Heights are PERCENTILES of the land heights (the cells above the water level, read from the field engine, Stats), the relief is the span from the 3rd to the 99.5th percentile, the noise
-- thresholds come from the noise itself (NoiseAt), so "snow covers the top 8%" and "dirt covers 38%" mean that on any map.
--
-- ROLE DETECTION, NOT LAYER NUMBERS. Which layer holds which role is found from the textures (roledetect.lua: file name words, then the colour of a 16 x 16 reduction), corrected by the user
-- per texture (the table in the panel). Plan() lists, per role, the layers that hold it. A role with no layer is skipped (a layer is never painted with a texture of the wrong kind). Two layers of
-- one role: the lower one gets the role's region, the others get soft partial mixes (at most 0.55 opacity) of fractal noise inside it (variants). The BASE layer (0) can be any role: it has no mask and is the default ground of its role,
-- so the recipe drops that role's own rule and lets the other roles claim their places (base sand: no beach rule, grass covers the interior; base snow: no snow rule, grass and dirt stay
-- below the snow line; base rock: cliffs are what is left). The result does not depend on which layer number holds what.
--
-- ORDER AND OPACITY. The engine draws layer 0, then 1 .. 8 on top; a mask byte is the OPACITY of its layer, so what you see of layer l is m_l * (1 - m_above). The recipe works in VISIBLE WEIGHTS
-- instead: the roles are resolved from the top of the priority list down (Priority: snow, high rock, dark rock, rock, wet, sand, dirt, grass; a role takes its selection of what the roles
-- above left, so the weights add up to 1 and never fire all at once), and then every layer gets the opacity that shows exactly its weight whatever its layer number is:
--     m_l = w_l / (1 - sum of the weights of the layers above l)         (clamped to 0..1; the division is a monotone curve through 1 / x, RECIP)
-- The bottom-to-top reading is base, grass, dirt, wet, sand, rock, dark rock, high rock, snow; the priority list is that stack read from the top. A layer outside the recipe (unknown texture,
-- role switched off) keeps its mask and covers what lies under it. The terrain types follow what is seen most in each cell (terraintype.lua).
--
-- The shader of the map decides how many layers have a paint mask (strata.lua Profile / Range): TTerrainXP 8; the numbered shaders 7; TTerrainGlow 4; TTerrain 4, but layers 5-8 switch it to
-- TTerrainXP as before. A texture on a layer the shader cannot paint is not used (Notes says so). The masks are written in the shader's encoding by the field commit (fields.lua).
--
--   Presets, SelectPreset(i)       styles: knob values and roles switched off      Knobs, KnobInfo      the settings (cliff / rock angle, snow share, high rock start, beach, wet strip, dirt share, dark rock, breakup, patch, seed)
--   State                          { preset, types, selected (layer), layers = nil | explicit role -> layer list (AutoLayers / MatchTextures; nil = detect) }
--   Order, Priority, RoleInfo      the roles bottom to top, in conflict order, their labels
--   Stats() / HeightAt(st, p) / NoiseAt(kind, seed, size, octaves, p)    the map's height percentiles, the percentile of a noise
--   Plan() -> plan                 { base, has, byRole, missing, unknown, beyond, info, cap }       Context(plan) -> { base, has }
--   Roles([cx]) -> list            { id, label, keywords, rules, base, off } for the plan of the map (or the given context)
--   Cap()  FitLayers(layers)  Notes(roles) -> line, warnings    the shader cap; the explicit-list helper; what the panel says
--   AutoLayers(roles)  MatchTextures(roles)    explicit layer lists (-1 = skip): the texture set layout / what the detection found
--   AssignMissing() -> count, text   gives empty layers the textures of the roles the map lacks (texsets.lua)
--   PreviewRole(i)  Apply() -> summary | nil, message   Coverage() -> { mask = {[layer]=share}, seen = {...} } from the committed masks
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Strata = import('/lua/editor/strata.lua')
local Detect = import('/lua/editor/roledetect.lua')
local World = import('/lua/editor/world.lua')

local function Rule(type, values, op, invert)
    local r = MaskGen.NewRule(type)
    for k, x in (values or {}) do r.v[k] = x end
    r.op = op or 'and'
    r.invert = invert or false
    return r
end


Knobs = { cliff = 52, rock = 34, snow = 0.08, high = 0.5, beach = 3, wet = 1.5, dirt = 0.38, dark = 0.5, breakup = 0.5, patch = 50, crisp = 0.45, fine = 0.35, seed = 1 }
KnobDefaults = { cliff = 52, rock = 34, snow = 0.08, high = 0.5, beach = 3, wet = 1.5, dirt = 0.38, dark = 0.5, breakup = 0.5, patch = 50, crisp = 0.45, fine = 0.35, seed = 1 }

KnobInfo = {
    { key = 'cliff', label = 'Cliff slope from (degrees)', min = 20, max = 85, step = 1, fmt = '%d' },
    { key = 'rock', label = 'Rock slope from (degrees)', min = 5, max = 80, step = 1, fmt = '%d' },
    { key = 'snow', label = 'Snow covers the top (share of land)', min = 0, max = 0.6, step = 0.01, fmt = '%.2f' },
    { key = 'high', label = 'High rock starts at (share of height range)', min = 0.2, max = 0.95, step = 0.01, fmt = '%.2f' },
    { key = 'beach', label = 'Beach half width (units)', min = 0, max = 20, step = 0.5, fmt = '%.1f' },
    { key = 'wet', label = 'Wet strip half width (units)', min = 0, max = 10, step = 0.5, fmt = '%.1f' },
    { key = 'dirt', label = 'Dirt coverage (share of flat ground)', min = 0, max = 0.8, step = 0.01, fmt = '%.2f' },
    { key = 'dark', label = 'Dark rock in cavities (amount)', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
    { key = 'breakup', label = 'Edge breakup (noise)', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
    { key = 'patch', label = 'Patch size (units)', min = 8, max = 300, step = 2, fmt = '%d' },
    { key = 'crisp', label = 'Edge crispness (0 soft, 1 sharp)', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
    { key = 'fine', label = 'Fine grain (variation at texture size)', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
    { key = 'seed', label = 'Seed', min = 0, max = 9999, step = 1, fmt = '%d' },
}

ALL_KNOBS = { 'cliff', 'rock', 'snow', 'high', 'beach', 'wet', 'dirt', 'dark', 'breakup', 'patch', 'crisp', 'fine', 'seed' }

--- The styles. `knobs` replaces the settings when the style is chosen (SelectPreset); `off` lists roles the style does not paint.
Presets = {
    { id = 'temperate', name = 'Natural (all eight kinds of ground)', uses = ALL_KNOBS, knobs = {}, off = {} },
    { id = 'alpine', name = 'Alpine (more rock, high rock and snow)', uses = ALL_KNOBS, knobs = { snow = 0.18, high = 0.4, cliff = 46, rock = 28, dark = 0.6 }, off = {}, altForce = true },
    { id = 'desert', name = 'Desert (dust and sand, no snow)', uses = ALL_KNOBS, knobs = { snow = 0, beach = 4, dirt = 0.42, dark = 0.4, wet = 1, crisp = 0.3 }, off = { snow = true }, drySand = true },
    { id = 'arctic', name = 'Arctic (snow and ice, rock)', uses = ALL_KNOBS, knobs = { snow = 0.4, high = 0.35, beach = 2, dirt = 0.15, cliff = 48, rock = 30 }, off = {}, altForce = true },
    { id = 'rocky', name = 'Rocky (cliffs, dark rock, little grass)', uses = ALL_KNOBS, knobs = { cliff = 44, rock = 26, dirt = 0.5, dark = 0.8, high = 0.4, snow = 0.05, crisp = 0.55 }, off = {} },
    { id = 'coast', name = 'Coast and wetland (wide beach, wet ground)', uses = ALL_KNOBS, knobs = { beach = 6, wet = 3, dirt = 0.36, snow = 0, rock = 38, cliff = 56, crisp = 0.3 }, off = { snow = true } },
}

State = { preset = 1, types = true, roughness = true, selected = 0 }          -- State.layers (nil): detect the roles from the textures; a list: the roles are on those layers

--- Chooses a style: the settings go back to the defaults, then the style's own values are put on top.
function SelectPreset(i)
    local p = Presets[i]
    if not p then return false end
    State.preset = i
    for k, v in KnobDefaults do Knobs[k] = v end
    for k, v in p.knobs or {} do Knobs[k] = v end
    return true
end

-- ---- numbers of the map ------------------------------------------------------------------------------------------------------------------------------------

--- Heights 0..100 percent (index p + 1) of the values >= minv (all when nil), by a 1024 bin histogram; the count. nil when no value qualifies.
function Percentiles(vals, minv)
    local n = table.getn(vals)
    local lo, hi, cnt = nil, nil, 0
    for i = 1, n do
        local v = vals[i]
        if not minv or v >= minv then
            cnt = cnt + 1
            if not lo or v < lo then lo = v end
            if not hi or v > hi then hi = v end
        end
    end
    if cnt < 1 then return nil end
    local pct = {}
    if hi - lo < 0.000001 then
        for p = 0, 100 do pct[p + 1] = lo end
        return pct, cnt
    end
    local B = 1024
    local bins = {}
    for b = 1, B do bins[b] = 0 end
    local scale = (B - 0.001) / (hi - lo)
    for i = 1, n do
        local v = vals[i]
        if not minv or v >= minv then
            local b = math.floor((v - lo) * scale) + 1
            bins[b] = bins[b] + 1
        end
    end
    local b, cum = 1, 0
    for p = 0, 100 do
        local target = p / 100 * cnt
        while b < B and cum + bins[b] < target do
            cum = cum + bins[b]
            b = b + 1
        end
        local frac = bins[b] > 0 and math.min(1, math.max(0, (target - cum) / bins[b])) or 0
        pct[p + 1] = lo + (b - 1 + frac) / B * (hi - lo)
    end
    pct[1], pct[101] = lo, hi
    return pct, cnt
end

--- The height at land percentile p (0..1) of st (Stats).
function HeightAt(st, p)
    local pct = st.pct
    if p <= 0 then return pct[1] end
    if p >= 1 then return pct[101] end
    local x = p * 100
    local i = math.floor(x)
    return pct[i + 1] + (pct[i + 2] - pct[i + 1]) * (x - i)
end

local statsCache = { key = false, st = false }

--- Drops the remembered numbers of the map (the next call reads them again).
function Invalidate()
    statsCache = { key = false, st = false }
    noiseCache = {}
end

--- The map's numbers: { hmin, hmax, water (level), hasWater, pct = land height percentiles }. Land = the cells above the water level (all cells when little is above it or there is no water).
--- Cached until the history changes.
function Stats()
    local size = rawget(_G, 'ed_terrain_info') and ed_terrain_info() or false
    local world = World.Get()
    local wl, on = world.water_elev or 0, (world.water_on or 0) ~= 0
    local key = tostring(size) .. '|' .. History.Version .. '|' .. wl .. '|' .. tostring(on)
    if statsCache.key == key then return statsCache.st end
    local st = { hmin = 0, hmax = 100, water = wl, hasWater = false, pct = {} }
    local got = false
    if size and Fields.IsAvailable() then
        local ok, r = pcall(Fields.Run, function(S)
            local H = S:Height(size > 1100 and 8 or 4)
            local w, h = Fields.Info(H)
            local mn, mx = Fields.Stats(H)
            return { vals = Fields.Read(H, 0, 0, w - 1, h - 1), lo = mn, hi = mx }
        end)
        if ok and r and r.vals then
            st.hmin, st.hmax = r.lo, r.hi
            st.hasWater = on and wl > r.lo + 0.5 and wl < r.hi - 0.5
            local pct, cnt
            if st.hasWater then
                pct, cnt = Percentiles(r.vals, wl)
                if cnt and cnt < table.getn(r.vals) * 0.03 then pct = nil end
            end
            pct = pct or Percentiles(r.vals, nil)
            if pct then st.pct, got = pct, true end
        end
    end
    if not got then
        for p = 0, 100 do st.pct[p + 1] = st.hmin + (st.hmax - st.hmin) * p / 100 end
    end
    statsCache = { key = key, st = st }
    return st
end

noiseCache = {}
local NOISE_OPS = { 'perlin', 'simplex', 'ridged', 'billow', 'fractal' }

--- The noise value (0..1) that a share p of the map lies BELOW, for the noise rule with these settings: a rule that smoothsteps around it covers 1 - p of the map. Read from the noise at
--- the preview resolution (the noise depends on the world position only); cached.
function NoiseAt(kind, seed, size, octaves, p)
    local tsize = rawget(_G, 'ed_terrain_info') and ed_terrain_info() or 0
    local key = tsize .. '|' .. kind .. '|' .. seed .. '|' .. size .. '|' .. octaves
    local pct = noiseCache[key]
    if pct == nil then
        pct = false
        if tsize > 0 and Fields.IsAvailable() then
            local ok, res = pcall(Fields.Run, function(S)
                local H = S:Height(tsize > 1100 and 8 or 4)
                local n = S:Op(NOISE_OPS[math.max(1, math.min(5, kind))], { like = H, seed = math.floor(seed), scale = size, octaves = math.floor(octaves) })
                local w, h = Fields.Info(n)
                return (Percentiles(Fields.Read(n, 0, 0, w - 1, h - 1), nil))
            end)
            if ok and res then pct = res end
        end
        if table.getsize(noiseCache) > 60 then noiseCache = {} end
        noiseCache[key] = pct
    end
    p = math.max(0, math.min(1, p))
    if not pct then return 0.5 + (p - 0.5) * 0.4 end          -- no natives: a typical spread
    local x = p * 100
    local i = math.floor(x)
    if i >= 100 then return pct[101] end
    return pct[i + 1] + (pct[i + 2] - pct[i + 1]) * (x - i)
end

-- ---- the roles ------------------------------------------------------------------------------------------------------------------------------------------------

Order = { 'grass', 'dirt', 'wet', 'sand', 'rock', 'darkrock', 'highrock', 'snow' }               -- bottom to top
Priority = { 'snow', 'highrock', 'darkrock', 'rock', 'wet', 'sand', 'dirt', 'grass' }            -- who wins where selections overlap

RoleInfo = {
    grass = { label = 'Grass (open ground)', keywords = { 'grass', 'gras', 'moss' } },
    dirt = { label = 'Dirt (patches)', keywords = { 'dirt', 'mud', 'soil', 'gravel' } },
    wet = { label = 'Wet ground (waterline, gullies)', keywords = { 'wet', 'melt', 'lava' } },
    sand = { label = 'Sand (beach)', keywords = { 'sand', 'dune', 'beach' } },
    rock = { label = 'Rock (cliffs)', keywords = { 'rock', 'cliff', 'stone' } },
    darkrock = { label = 'Dark rock (cavities)', keywords = { 'darkrock', 'obsidian', 'ash' } },
    highrock = { label = 'High rock (peaks)', keywords = { 'highrock', 'peak', 'icerock' } },
    snow = { label = 'Snow (high, flat)', keywords = { 'snow', 'ice', 'frost' } },
}

-- ---- the rules: wide ramps, never cut -------------------------------------------------------------------------------------------------------------------------
-- Every selection is a product of SMOOTH RAMPS (a height or slope ramp is 0 at one value and 1 at another, 10 to 25 percent of the relief wide; maskgen.lua height / slope rules with a soft edge),
-- blurred by 3 units or more. Noise never cuts a shape out: it only WOBBLES the ramp thresholds (the `wobble` of a height / slope rule: fractal noise of 40..160 units, a few percent of the
-- ramp's range), so edges are ragged but soft, and where a role is a gentle mix on flat ground (dirt, a second grass) the mix is a wide smoothstep of a fractal noise at partial opacity.

local function Zone(st)
    local z0 = HeightAt(st, 0.03)
    return z0, math.max(1, HeightAt(st, 0.995) - z0)
end

--- A size for the wobble noise and the breakup strength (0..2, 1 = the knob's middle) of the settings.
local function Wob(k) return math.max(40, math.min(160, k.patch * 1.6)), k.breakup * 2 end

--- How much altitude counts on this map: 0 for flat country (a relief under 18 units: no snow line, no high rock), 1 from a relief of 60 units. The alpine and arctic styles ignore it.
function AltFactor(st)
    local R = HeightAt(st, 0.99) - HeightAt(st, 0.03)
    local f = math.max(0, math.min(1, (R - 18) / 42))
    local p = Presets[State.preset]
    if p and p.altForce then f = 1 end
    return f
end

--- Slope ramp: 0 below a0 degrees, 1 from a1 on.
local function SteepFrom(a0, a1, wob, size, seed, op)
    return Rule('slope', { lo = a1, hi = 90, soft = math.max(1, a1 - a0), wobble = wob or 0, wsize = size or 80, wseed = seed or 1 }, op)
end
--- Slope ramp: 1 below a0 degrees, 0 from a1 on.
local function FlatTo(a0, a1, wob, size, seed, op)
    return Rule('slope', { lo = 0, hi = a0, soft = math.max(1, a1 - a0), wobble = wob or 0, wsize = size or 80, wseed = seed or 1 }, op)
end
--- Height ramp: 0 at h0, 1 from h1 on.
local function RiseFrom(st, h0, h1, wob, size, seed, op, sun)
    return Rule('height', { lo = h1, hi = st.hmax + 1000, soft = math.max(0.5, h1 - h0), wobble = wob or 0, wsize = size or 80, wseed = seed or 1, sun = sun or 0 }, op)
end
--- Height ramp: 1 up to h0, 0 from h1 on.
local function FallTo(st, h0, h1, wob, size, seed, op)
    return Rule('height', { lo = st.hmin - 1000, hi = h0, soft = math.max(0.5, h1 - h0), wobble = wob or 0, wsize = size or 80, wseed = seed or 1 }, op)
end
local function Blur(r) return Rule('blur', { radius = r }) end
local function AtMost(f) return Rule('amount', { factor = f }) end              -- the opacity a role reaches at most
--- Edges that follow a noise (the knob "Edge crispness"): ragged and fairly sharp instead of a smooth ramp.
local function Crisp(k, seed, size) return Rule('crisp', { crisp = k.crisp, noise = 0.25 + 0.4 * k.breakup, size = size or math.max(10, k.patch * 0.4), seed = seed }) end
--- Variation at the size of the texture detail (the knob "Fine grain"): where a role is only partly there, the paint is patchy at that size instead of an even tint.
local function Grain(k, seed, scale) return Rule('grain', { amount = math.min(0.8, (scale or 1) * (0.1 + 0.6 * k.fine)), size = 7, seed = seed }) end

--- The height of the snow line (50 percent snow): the top share of the land heights, never lower than a floor that keeps a flat map from being white (the lower the share the higher the floor).
function SnowLine(k, st)
    local z0, R = Zone(st)
    return math.max(HeightAt(st, 1 - k.snow), z0 + R * math.max(0, 0.45 - 1.2 * k.snow))
end

--- A fractal noise (kind 5 of the mask generator) as a gentle 0..1 mix: 0 at the noise value that a share p0 of the map lies below, 1 at the value of p1. The values come from the noise itself
--- (NoiseAt), so a wide window around the share 1 - d makes patches that cover about d of the map, with edges as wide as the window.
local function Mix(seed, size, p0, p1)
    local from = NoiseAt(5, seed, size, 5, p0)
    local to = NoiseAt(5, seed, size, 5, p1)
    if to - from < 0.02 then to = from + 0.02 end
    return Rule('noise', { kind = 5, seed = seed, size = size, octaves = 5, from = from, to = to })
end

Builders = {}           -- role id -> function(knobs, stats, context) -> rule list | {} (the base: no mask) | false (switched off)

Builders.grass = function(k, st, cx)
    if cx.base == 'grass' then return {} end
    local size, bk = Wob(k)
    local rules = { Mix(k.seed + 5, size * 1.6, 0.05, 0.6) }
    table.insert(rules, Rule('const', { value = 0.75 }, 'or'))                           -- the mix only takes a quarter away: grass is what is left
    table.insert(rules, FlatTo(k.rock - 4, k.rock + 12, 3 * bk, size, k.seed + 6, 'mul'))
    if st.hasWater then table.insert(rules, Rule('water', { mode = 1, offset = cx.has.sand and (k.beach + 0.5) or 0.5, soft = math.max(2, k.beach) }, 'mul')) end
    if (cx.has.snow or cx.base == 'snow') and k.snow > 0.004 and AltFactor(st) > 0.04 then
        local _, R = Zone(st)
        local sl = SnowLine(k, st)
        table.insert(rules, FallTo(st, sl - 0.12 * R, sl + 0.04 * R, 0.1 * R * bk, size, k.seed + 7, 'mul'))
    end
    table.insert(rules, Blur(3))
    table.insert(rules, Grain(k, k.seed + 301, 0.7))
    return rules
end

Builders.dirt = function(k, st, cx)
    if cx.base == 'dirt' then return {} end
    if k.dirt <= 0.005 then return false end
    local size, bk = Wob(k)
    local rules = { Mix(k.seed, k.patch * 2.4, 1 - k.dirt - 0.22, 1 - k.dirt + 0.22), Crisp(k, k.seed + 4), FlatTo(k.rock - 6, k.rock + 10, 3 * bk, size, k.seed + 3, 'mul') }
    if (cx.has.snow or cx.base == 'snow') and k.snow > 0.004 and AltFactor(st) > 0.04 then
        local _, R = Zone(st)
        local sl = SnowLine(k, st)
        table.insert(rules, FallTo(st, sl - 0.12 * R, sl + 0.04 * R, 0.1 * R * bk, size, k.seed + 7, 'mul'))
    end
    table.insert(rules, Blur(1.5))
    table.insert(rules, Grain(k, k.seed + 302, 1))
    table.insert(rules, AtMost(0.88))
    return rules
end

--- Wet ground: the bed of the drainage lines (a strong drainage area in a concave channel on flat ground) and a narrow strip along the waterline. Not whole plains: it needs a channel.
Builders.wet = function(k, st, cx)
    if cx.base == 'wet' then return {} end
    local size, bk = Wob(k)
    local rules = { Rule('flow', { range = 600, from = 0.62, to = 0.86 }), Rule('curvature', { radius = 4, gain = 20, lo = 0, hi = 0.45, soft = 0.08 }), FlatTo(7, 20, 0, size, 1, 'mul') }
    if st.hasWater and k.wet > 0 then
        table.insert(rules, Rule('shoredist', { width = k.wet * 2, depth = 2, soft = 1.5 + k.wet }, 'or'))
    end
    table.insert(rules, Blur(2))
    table.insert(rules, Crisp(k, k.seed + 51, 12))
    table.insert(rules, AtMost(0.72))
    return rules
end

Builders.sand = function(k, st, cx)
    if cx.base == 'sand' then return {} end
    local size, bk = Wob(k)
    if st.hasWater then
        if k.beach <= 0 then return false end
        return { Rule('shoredist', { width = k.beach * 2.5, depth = 3, soft = 1 + k.beach }), FlatTo(10, 28, 2 * bk, size, k.seed + 8, 'mul'), Crisp(k, k.seed + 81, 14), Blur(1.5), Grain(k, k.seed + 303, 0.5), AtMost(0.92) }
    end
    local p = Presets[State.preset]
    if not (p and p.drySand) then return false end                            -- sand lies along water; a dry map only has it when the style asks (desert: dry basins)
    local h0, h1 = HeightAt(st, 0.04), HeightAt(st, 0.3)                     -- the lowest third of the land: dry basins
    return { FallTo(st, h0, h1, 0.4 * (h1 - h0) * bk, size * 1.5, k.seed + 9), FlatTo(6, 18, 0, size, 1, 'mul'), Crisp(k, k.seed + 82, 20), Blur(2.5), Grain(k, k.seed + 304, 0.7), AtMost(0.65) }
end

Builders.rock = function(k, st, cx)
    if cx.base == 'rock' then return {} end
    local size, bk = Wob(k)
    return { SteepFrom(k.rock, math.max(k.rock + 4, k.cliff), 4 * bk, size, k.seed + 11), Crisp(k, k.seed + 12, 18), Blur(1.2) }
end

Builders.darkrock = function(k, st, cx)
    if cx.base == 'darkrock' then return {} end
    if k.dark <= 0.01 then return false end
    local size, bk = Wob(k)
    return { Rule('curvature', { radius = 6, gain = 18, lo = 0, hi = 0.42, soft = 0.1 }), SteepFrom(k.rock * 0.45, k.rock + 6, 3 * bk, size, k.seed + 31, 'mul'), Blur(5), Grain(k, k.seed + 305, 1), AtMost(0.15 + 0.45 * k.dark) }
end

Builders.highrock = function(k, st, cx)
    if cx.base == 'highrock' then return {} end
    local alt = AltFactor(st)
    if alt < 0.05 then return false end
    local z0, R = Zone(st)
    local size, bk = Wob(k)
    local h = z0 + R * k.high
    local rules = { SteepFrom(k.rock * 0.4, k.rock + 8), Rule('curvature', { radius = 6, gain = 25, lo = 0.56, hi = 1, soft = 0.1 }, 'or') }
    if not cx.biplanar then table.insert(rules, Rule('const', { value = 0.3 }, 'or')) end                -- some rock on flat high ground (a side-mapped layer would be stretched there)
    for _, r in { RiseFrom(st, h - 0.12 * R, h + 0.14 * R, 0.1 * R * bk, size, k.seed + 41, 'mul'), Crisp(k, k.seed + 42, 22), Blur(2), AtMost(alt) } do table.insert(rules, r) end
    return rules
end

Builders.snow = function(k, st, cx)
    if cx.base == 'snow' then return {} end
    if k.snow <= 0.004 then return false end
    local alt = AltFactor(st)
    if alt < 0.05 then return false end
    local _, R = Zone(st)
    local size, bk = Wob(k)
    local sl = SnowLine(k, st)
    return { RiseFrom(st, sl - 0.14 * R, sl + 0.06 * R, 0.08 * R * bk, size, k.seed + 21, nil, 0.05 * R), FlatTo(k.cliff, k.cliff + 22, 4 * bk, size, k.seed + 22, 'mul'), Crisp(k, k.seed + 23, 16), Blur(2), AtMost(alt) }
end

-- ---- the layers of the map and their roles ---------------------------------------------------------------------------------------------------------------------

--- The highest painted layer the shader of the map draws with a mask: 8 for TTerrainXP and for TTerrain (writing layers 5-8 switches it to TTerrainXP, as it always did), 7 for the numbered
--- shaders, 4 for TTerrainGlow. Without a terrain: 8.
function Cap()
    return Strata.PaintCap()
end

--- The layers an explicit list really gets: a role on a layer the shader cannot paint takes the highest free layer it can, or shares the top layer when none is free.
function FitLayers(layers)
    local cap = Cap()
    local fit, used = {}, {}
    for i = 1, table.getn(layers) do
        fit[i] = layers[i] or 0
        if fit[i] >= 1 and fit[i] <= cap then used[fit[i]] = true end
    end
    for i = table.getn(layers), 1, -1 do
        if fit[i] > cap then
            local free
            for k = cap, 1, -1 do
                if not used[k] then free = k break end
            end
            fit[i] = free or cap
            used[fit[i]] = true
        end
    end
    return fit
end

--- Which layer holds which role. Detected from the textures (State.layers = nil), or taken from the explicit list State.layers (parallel to Order, -1 = skip). Returns
--- { cap, base (role of layer 0), has (role -> true), byRole (role -> layers, lowest first), missing (roles without a layer), unknown (layers whose texture is not recognised or not used),
---   beyond (layers with a texture the shader does not paint), moved (explicit list: role, wish, layer), info (roledetect.Layers) }.
function Plan()
    local cap = Cap()
    local plan = { cap = cap, base = nil, has = {}, byRole = {}, missing = {}, unknown = {}, beyond = {}, moved = {}, info = Detect.Layers(8), manual = false }
    local okProfile, profile = pcall(function() return Strata.Profile() end)
    plan.biplanar = (okProfile and profile and profile.biplanar) and true or false       -- layers 3 and 4 are drawn from the side only (the B shaders): nothing but steep ground goes there
    local taken = {}
    local function Add(layer, role)
        if taken[layer] then return end
        taken[layer] = true
        plan.byRole[role] = plan.byRole[role] or {}
        table.insert(plan.byRole[role], layer)
        plan.has[role] = true
        if layer == 0 then plan.base = role end
    end
    if State.layers and table.getn(State.layers) == table.getn(Order) then
        plan.manual = true
        local fit = FitLayers(State.layers)
        for i, id in Order do
            local wish = State.layers[i]
            if wish and wish >= 0 and fit[i] and fit[i] >= 0 then
                if fit[i] ~= wish then table.insert(plan.moved, { role = id, wish = wish, layer = fit[i] }) end
                Add(fit[i], id)
            end
        end
    else
        for l = 0, 8 do
            local e = plan.info[l]
            if e then
                if l > cap then table.insert(plan.beyond, l)
                elseif e.role then Add(l, e.role)
                else table.insert(plan.unknown, l) end
            end
        end
    end
    for _, list in plan.byRole do table.sort(list) end
    for _, id in Order do
        if not plan.has[id] then table.insert(plan.missing, id) end
    end
    return plan
end

--- What the role rules need to know about the layers: the role of the base layer and the roles present.
function Context(plan)
    return { base = plan.base, has = plan.has, biplanar = plan.biplanar }
end

--- The roles of the current style with the current settings, for the plan of the map (or the context cx): { id, label, keywords, rules, base, off }.
function Roles(cx)
    cx = cx or Context(Plan())
    local p = Presets[State.preset]
    local st = Stats()
    local list = {}
    for i, id in Order do
        local info = RoleInfo[id]
        local rules = Builders[id](Knobs, st, cx)
        local isBase = cx.base == id
        list[i] = { id = id, label = info.label, keywords = info.keywords, rules = rules or {}, base = isBase,
                    off = (not isBase) and (rules == false or (p.off and p.off[id]) or false) or false }
    end
    return list
end

--- What the panel says about the shader and the layers: the shader line and the warnings (plain sentences).
function Notes(roles)
    local name = rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or '?'
    local p = rawget(_G, 'ed_stratum_shader') and Strata.Profile() or {}
    local cap = Cap()
    local line = 'Shader ' .. tostring(name) .. ': masks in the ' .. (p.range or 'half') .. ' range, ' .. cap .. ' painted layers'
    local warnings = {}
    if p.supported == false and p.reason then table.insert(warnings, 'No notes about this shader: masks are written in the half range') end
    local plan = Plan()
    local function L(id) return string.lower(Detect.Label(id)) end
    if plan.manual then table.insert(warnings, 'Kinds of ground are on fixed layers (not detected from the textures)') end
    for _, m in plan.moved do
        table.insert(warnings, Detect.Label(m.role) .. ': layer ' .. m.wish .. ' is not painted here, moved to layer ' .. m.layer)
    end
    local anyRole = false
    for _ in plan.has do anyRole = true end
    if not anyRole then
        table.insert(warnings, 'No layer has a texture the recipe can use: press Assign textures, or set the kind of ground of each layer in the table')
    else
        if plan.base then
            table.insert(warnings, 'Base layer is ' .. L(plan.base) .. ': it shows where nothing else is painted' .. ((plan.base ~= 'grass' and plan.has.grass) and '; grass covers the open ground' or ''))
        end
        local names = {}
        for _, id in plan.missing do
            local off = Presets[State.preset].off and Presets[State.preset].off[id]
            if not off then table.insert(names, L(id)) end
        end
        if table.getn(names) > 0 then table.insert(warnings, 'No texture for: ' .. table.concat(names, ', ') .. ' (skipped; Assign textures fills empty layers)') end
    end
    for _, l in plan.beyond do table.insert(warnings, 'Layer ' .. l .. ' is not painted with this shader: left alone') end
    for _, l in plan.unknown do
        local e = plan.info[l]
        table.insert(warnings, 'Layer ' .. l .. ' (' .. (e and e.short or '?') .. '): ' .. ((e and e.override == 'none') and 'not used' or 'kind of ground unknown, left alone'))
    end
    for id, list in plan.byRole do
        if table.getn(list) > 1 then
            local nums = {}
            for _, l in list do table.insert(nums, tostring(l)) end
            table.insert(warnings, L(id) .. ' on layers ' .. table.concat(nums, ', ') .. ': the lowest gets the ground, the others patches')
        end
    end
    return line, warnings
end

--- An explicit list for State.layers (parallel to Order): the layout of the texture sets (texsets.lua: layer 1 grass, 2 rock, 3 sand, 4 dirt, 5 wet, 6 high rock, 7 dark rock, 8 snow);
--- a role whose layer the shader does not paint is skipped (-1), the last ones first.
function AutoLayers(roles)
    local TS = import('/lua/editor/texsets.lua')
    local cap = Cap()
    local layers = {}
    for i, role in roles do
        local idx = TS.RoleLayer(role.id) or 0
        layers[i] = (idx >= 1 and idx <= cap) and idx or -1
    end
    return layers
end

--- An explicit list from the detection: the lowest layer of each role (0 = the base layer), -1 where no layer holds the role.
function MatchTextures(roles)
    local plan = Plan()
    local layers = {}
    for i, role in roles do
        local list = plan.byRole[role.id]
        layers[i] = list and list[1] or -1
    end
    return layers
end

--- Gives empty layers (no texture) the textures of the roles the map lacks, from the current texture set; layers that have a texture are not touched. Returns the number of layers set and a
--- sentence (what was done, or why nothing was).
function AssignMissing()
    if not rawget(_G, 'ed_stratum_layer') then return 0, 'the map has no texture layers' end
    local TS = import('/lua/editor/texsets.lua')
    local plan = Plan()
    local cap = Cap()
    local empty = {}
    for l = 0, cap do
        if not Detect.Albedo(l) then table.insert(empty, l) end
    end
    if table.getn(empty) == 0 then return 0, 'no empty layer' end
    local off = Presets[State.preset].off or {}
    local done, names = 0, {}
    local next = 1
    for _, role in TS.Roles do
        if not plan.has[role] and not off[role] and empty[next] then
            local layer = empty[next]
            -- the Base layer takes grass only; a layer another role would need is not used for it
            if layer == 0 and role ~= 'grass' then
                next = next + 1
                layer = empty[next]
            end
            if layer then
                local ok = TS.ApplyRole(layer, role)
                if ok then
                    done = done + 1
                    table.insert(names, Detect.Label(role) .. ' on layer ' .. layer)
                    next = next + 1
                end
            end
        end
    end
    if done == 0 then return 0, 'nothing to assign (every kind of ground has a texture, or the texture set has none for it)' end
    return done, 'assigned: ' .. table.concat(names, ', ')
end

--- Shows the selection of role i (an index into Roles()) on the map at preview resolution. Returns the field, or nil and a message.
function PreviewRole(i)
    local roles = Roles()
    local role = roles[i]
    if not role then return nil, 'no such kind of ground' end
    if role.base then return nil, role.label .. ' is the base layer: it has no mask, it is what the other kinds leave free' end
    if role.off or table.getn(role.rules) == 0 then return nil, role.label .. ' is switched off in this style' end
    return MaskGen.PreviewDef({ rules = role.rules })
end

-- ---- applying -----------------------------------------------------------------------------------------------------------------------------------------------------

-- 1 / x as a monotone curve through (1 - 1 / y, y): the opacity of a layer is its weight divided by what the layers above leave free
local RECIP = {}
for _, y in { 1, 1.1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 100 } do
    table.insert(RECIP, 1 - 1 / y)
    table.insert(RECIP, y)
end
RECIP_POINTS = RECIP

--- The mix field of variant n of a role (a second grass layer, ...): a wide smoothstep of fractal noise at partial opacity (at most 0.55), covering about a quarter of the region. No hard edge.
local function PatchField(c, k, st, id, n)
    local size = math.max(60, k.patch * 2.2)
    local seed = k.seed + 91 + n * 17
    for i, rid in Order do
        if rid == id then seed = seed + i * 7 end
    end
    local m, err = MaskGen.Evaluate(c, { rules = { Mix(seed, size, 0.3, 0.85), AtMost(0.55), Blur(3) } })
    if not m then error(err or 'patch noise failed') end
    return m
end

--- The visible weight of every layer of the plan, as fields: { [layer] = field }. See the header (priority cascade, then variants split a role's region).
local function Weights(S, c, plan, roles, k, st)
    local byId = {}
    for _, r in roles do byId[r.id] = r end
    local groups, sel = {}, {}
    for _, id in Order do
        local list, role = plan.byRole[id], byId[id]
        if list and role and not role.off and (role.base or table.getn(role.rules) > 0) then
            groups[id] = list
            if not role.base then
                local m, err = MaskGen.Evaluate(c, { rules = role.rules })
                if not m then error(role.label .. ': ' .. tostring(err)) end
                -- a role on a side-mapped layer (3 or 4 of the B shaders) only gets steep ground: on flat ground that texture is stretched
                local onCliff = false
                if plan.biplanar then
                    for _, l in list do
                        if l == 3 or l == 4 then onCliff = true end
                    end
                end
                if onCliff then
                    local gate, gerr = MaskGen.Evaluate(c, { rules = { Rule('slope', { lo = 24, hi = 90, soft = 12 }) } })
                    if not gate then error(role.label .. ': ' .. tostring(gerr)) end
                    m = S:Op('mul', { a = m, b = gate })
                end
                sel[id] = m
            end
        end
    end
    local rem = S:Op('const', { like = c.H, value = 1 })
    local region = {}
    for _, id in Priority do
        if groups[id] and sel[id] then
            region[id] = S:Op('mul', { a = sel[id], b = rem })
            rem = S:Op('mul', { a = rem, b = S:Op('invert', { a = sel[id], lo = 0, hi = 1 }) })
        end
    end
    if plan.base and groups[plan.base] then region[plan.base] = rem end
    local target = {}
    for id, g in groups do
        local reg = region[id]
        if reg then
            local left = reg
            for gi = 2, table.getn(g) do
                local t = S:Op('mul', { a = left, b = PatchField(c, k, st, id, gi - 1) })
                left = S:Op('sub', { a = left, b = t })
                target[g[gi]] = t
            end
            target[g[1]] = left
        end
    end
    return target, groups
end

--- Writes all roles: the paint masks of their layers and (State.types) the terrain-type grid. ONE undo step. Returns a summary { { label, share, layer }, ... } (the shares add up to 1)
--- and the number of cells changed, or nil, message.
local function ApplyPaint()
    if not Fields.IsAvailable() or not ed_stratum_info() then return nil, 'the map has no paint masks' end
    local plan = Plan()
    local anyRole = false
    for _ in plan.has do anyRole = true end
    if not anyRole then return nil, 'no layer has a texture the recipe can use (press Assign textures, or choose the kind of ground of each layer)' end
    local roles = Roles(Context(plan))
    local cap = Cap()
    local TT = import('/lua/editor/terraintype.lua')
    return Fields.Run(function(S)
        local c = MaskGen.NewContext(S, { step = 1 })
        local ok, target, groups = pcall(Weights, S, c, plan, roles, Knobs, Stats())
        if not ok then return nil, tostring(target) end
        -- a kind of ground the style or the map does not have (snow on a flat map, in the desert style) is cleared from its layer: the recipe replaces what an earlier run painted
        for _, r in roles do
            local list = plan.byRole[r.id]
            if r.off and list then
                for _, l in list do
                    if l >= 1 and l <= cap and not target[l] then target[l] = S:Op('const', { like = c.H, value = 0 }) end
                end
            end
        end
        local parts, cells = {}, 0
        local free = S:Op('const', { like = c.H, value = 1 })
        local vis = {}
        for layer = cap, 1, -1 do
            local t = target[layer]
            if t then
                local cum = S:Op('invert', { a = free, lo = 0, hi = 1 })
                local rec = S:Op('remap', { a = cum, points = RECIP_POINTS, smooth = 1 })
                local m = S:Op('clamp', { a = S:Op('mul', { a = t, b = rec }), lo = 0, hi = 1 })
                local entry, n = MaskGen.WriteLayer(c, m, layer, { mode = 1, strength = 1, takeAway = false }, true)
                if entry then
                    table.insert(parts, entry)
                    cells = cells + n
                end
                vis[layer] = S:Op('mul', { a = m, b = free })
                free = S:Op('mul', { a = free, b = S:Op('invert', { a = m, lo = 0, hi = 1 }) })
            elseif Detect.Albedo(layer) then
                -- a layer outside the recipe keeps its mask and still covers what lies under it
                local e = S:Op('resample', { a = S:Stratum(layer), like = c.H })
                vis[layer] = S:Op('mul', { a = e, b = free })
                free = S:Op('mul', { a = free, b = S:Op('invert', { a = e, lo = 0, hi = 1 }) })
            end
        end
        vis[0] = free
        -- terrain types by the layer seen most
        if State.types and rawget(_G, 'ed_tt_info') and ed_tt_info() then
            local best = vis[0]
            local codes = S:Op('const', { like = c.H, value = TT.TypeOfLayer(0) })
            for layer = 1, cap do
                if vis[layer] then
                    local win = S:Op('threshold', { a = S:Op('sub', { a = vis[layer], b = best }), value = 0 })
                    codes = S:Op('blend', { a = codes, b = S:Op('const', { like = c.H, value = TT.TypeOfLayer(layer) }), mask = win })
                    best = S:Op('max', { a = best, b = vis[layer] })
                end
            end
            local entry, n = Fields.CommitTypes(codes, { noPush = true, label = 'recipe terrain types' })
            if entry then
                table.insert(parts, entry)
                cells = cells + n
            end
        end
        if table.getn(parts) == 0 then return nil, 'nothing changed' end
        History.Push({
            label = 'stratum recipe ' .. Presets[State.preset].name,
            undo = function() for i = table.getn(parts), 1, -1 do parts[i].undo() end end,
            redo = function() for i = 1, table.getn(parts) do parts[i].redo() end end,
            release = function() for _, e in parts do e.release() end end,
        })
        -- the shares: what each kind shows, the layers of the recipe, the rest
        local summary, listed = {}, {}
        local function Mean(layer)
            if not vis[layer] then return 0 end
            local _, _, mean = Fields.Stats(vis[layer])
            return mean
        end
        for _, id in Order do
            local g = groups[id]
            if g then
                local share = 0
                for _, l in g do
                    share = share + Mean(l)
                    listed[l] = true
                end
                table.insert(summary, { label = RoleInfo[id].label, share = share, layer = g[1], layers = g })
            end
        end
        local other = 0
        for l = 1, cap do
            if vis[l] and not listed[l] then other = other + Mean(l) end
        end
        if not listed[0] then table.insert(summary, { label = 'Base layer (left as it is)', share = Mean(0), layer = 0 }) end
        if other > 0.0005 then table.insert(summary, { label = 'Layers outside the recipe', share = other, layer = -1 }) end
        return summary, cells
    end)
end

--- Paints the kinds of ground (see ApplyPaint above) and, for the shaders that read layer 8 as a roughness multiplier (Terrain1xx / 2xx: shaders.lua Profile l8 = 'rough'), also sets that mask from the
--- paint (wet ground, ice and snow shiny, dry rock and sand rough): State.roughness. One undo step. Returns the summary and the number of cells changed, or nil and a message.
function Apply()
    local depthBefore = History.Depth()
    local summary, cells = ApplyPaint()
    if not summary then return summary, cells end
    local okProfile, p = pcall(function() return Strata.Profile() end)
    if State.roughness and okProfile and p and p.l8 == 'rough' then
        local MT = import('/lua/editor/maptextures.lua')
        local entry, n = MT.GenerateRoughness({ amount = 0.6 })
        if entry then cells = cells + (n or 0) end
        if History.Depth() - depthBefore >= 2 then History.Merge(History.Depth() - depthBefore, 'stratum recipe ' .. Presets[State.preset].name) end
    end
    return summary, cells
end

--- How much of the map each layer covers, from the masks now on the map: { mask = { [layer] = mean opacity }, seen = { [layer] = share that shows after the layers above took theirs, [0] = base } }.
--- Layers 1 .. Cap() that have a texture only. nil without masks.
function Coverage()
    if not Fields.IsAvailable() or not ed_stratum_info() then return nil end
    local cap = Cap()
    local ok, res = pcall(Fields.Run, function(S)
        local free
        local mask, seen = {}, {}
        for layer = cap, 1, -1 do
            if Detect.Albedo(layer) then
                local m = S:Stratum(layer)
                free = free or S:Op('const', { like = m, value = 1 })
                local _, _, mean = Fields.Stats(m)
                mask[layer] = mean
                local _, _, sm = Fields.Stats(S:Op('mul', { a = m, b = free }))
                seen[layer] = sm
                free = S:Op('mul', { a = free, b = S:Op('invert', { a = m, lo = 0, hi = 1 }) })
            end
        end
        if free then
            local _, _, fm = Fields.Stats(free)
            seen[0] = fm
        else
            seen[0] = 1
        end
        return { mask = mask, seen = seen }
    end)
    if ok then return res end
    return nil
end
