-- Numbers that describe how a terrain is made and painted, for comparing a map that looks good with the output of a graph (docs/projects/editor/GRAPH_TEXTURING.md, "What a good map has").
-- Run in a test instance with the map open: python scripts/editor_inst.py cmd <tag> scripts/terrain_metrics.lua --chars 8000
--
--   height     range, mean and percentiles of the land
--   slope      share of the map steeper than 5 .. 50 degrees
--   bands      rms of H - blur(H, r): how much relief lives at each scale (units)
--   curvature  share of strongly convex / concave ground at 4 and 16 units
--   layers     texture of each layer (role), coverage, share of the map where its mask is in transition (0.05 .. 0.95), how many cells it covers fully
--   seen       what the layers show after the ones above took theirs
--
-- Lua 5.0 dialect.

local Fields = import('/lua/editor/fields.lua')
local Recipes = import('/lua/editor/recipes.lua')
local Detect = import('/lua/editor/roledetect.lua')
local out = {}
local function P(...)
    table.insert(out, string.format(unpack(arg)))
end

local w, h = ed_terrain_info()
local world = import('/lua/editor/world.lua').Get()
P('map %d x %d samples, water %s at %.1f (deep %.1f), shader %s', w, h, tostring(world.water_on), world.water_elev or 0, world.water_deep or 0, tostring(rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or '?'))

local function Mean(S, f) local _, _, m = Fields.Stats(f) return m end
local function Share(S, f, t) return Mean(S, S:Op('threshold', { a = f, value = t })) end

Fields.Run(function(S)
    local H = S:Height(1)
    local lo, hi, mean = Fields.Stats(H)
    local st = Recipes.StatsOf(S, H)
    local pct = st.pct
    P('height  min %.1f  max %.1f  mean %.1f  land percentiles 5/25/50/75/95: %.1f %.1f %.1f %.1f %.1f  (land = above water: %s)', lo, hi, mean, pct[6], pct[26], pct[51], pct[76], pct[96], tostring(st.hasWater))
    local slope = S:Op('slope', { a = H, mode = 'degrees', radius = 1 })
    local line = 'slope   share steeper than'
    for _, t in { 5, 10, 20, 30, 40, 50 } do line = line .. string.format('  %d deg: %.3f', t, Share(S, slope, t)) end
    table.insert(out, line)
    local _, smx, sm = Fields.Stats(slope)
    P('slope   mean %.1f deg, max %.1f deg', sm, smx)
    -- relief per scale
    local band = 'bands   rms of H - blur(H, r):'
    for _, r in { 2, 4, 8, 16, 32, 64, 128 } do
        local d = S:Op('sub', { a = H, b = S:Op('blur', { a = H, radius = r }) })
        local _, _, ms = Fields.Stats(S:Op('mul', { a = d, b = d }))
        band = band .. string.format('  r%d: %.2f', r, math.sqrt(ms))
    end
    table.insert(out, band)
    for _, r in { 4, 16 } do
        local c = S:Op('curvature', { a = H, radius = r, gain = 25 })
        P('curv    radius %d: share convex (>0.65) %.3f  concave (<0.35) %.3f', r, Share(S, c, 0.65), 1 - Share(S, c, 0.35))
    end
    -- the paint
    local plan = Recipes.Plan()
    local free = S:Op('const', { like = H, value = 1 })
    local info = Detect.Layers(8)
    for layer = 8, 1, -1 do
        local ok, m = pcall(function() return S:Stratum(layer) end)
        if ok and m then
            local e = S:Op('resample', { a = m, like = H })
            local mm = Mean(S, e)
            local trans = Share(S, e, 0.05) - Share(S, e, 0.95)
            local full = Share(S, e, 0.95)
            local seen = Mean(S, S:Op('mul', { a = e, b = free }))
            free = S:Op('mul', { a = free, b = S:Op('invert', { a = e, lo = 0, hi = 1 }) })
            local tex = info[layer] and (info[layer].role or '?') .. ' ' .. tostring(info[layer].albedo or '') or '-'
            P('layer %d  coverage %.3f  transition %.3f  full %.3f  seen %.3f   %s', layer, mm, trans, full, seen, tex)
        end
    end
    local base = info[0]
    P('layer 0  seen %.3f   %s', Mean(S, free), base and ((base.role or '?') .. ' ' .. tostring(base.albedo or '')) or '-')
end)
return table.concat(out, '\n')
