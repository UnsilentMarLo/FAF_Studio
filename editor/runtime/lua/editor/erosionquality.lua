-- Quality statistics of erosion results (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T3). Run in the live editor:
--   return import('/lua/editor/erosionquality.lua').Report()          the presets on a generated mountain field, as a table of statistics
--   return import('/lua/editor/erosionquality.lua').Measure(field)    the statistics of one height field
--
-- What the numbers mean (all on the world unit grid, cell = 1):
--   slope      mean gradient (rise / run);   steep   share of the samples steeper than 0.75 (what land units cannot climb)
--   drain      drainage density: share of the samples whose pit filled catchment is at least 64 cells (the channel network, from erode_stream with 0 iterations)
--   theta      concavity of the slope - area relation, slope ~ area^-theta over catchments of 16 .. 2048 cells (op slope_area). Fluvial terrain has 0.3 - 0.6 (Flint's law, rivers of every
--              climate), uneroded noise 0 - 0.1
--   pits       share of the samples lying in closed depressions deeper than 0.05 units (op basin_depth), pitdepth = mean filled depth: fluvial terrain drains, so both fall with erosion
--   skew       skewness of the curvature (radius 1): convex hilltops + concave valleys; sign tells which is stronger
--   kurt       kurtosis of the curvature (radius 1): ridges and gullies are rare strong curvatures, so a sharper, more incised terrain has a larger value
--   hf         fine scale roughness: mean |curvature| at radius 1 over the mean at radius 3 (1 = smooth, large = pixel noise)
--   relief     standard deviation of the height
-- A believable erosion makes the channel network denser (drain up), sharpens ridges and gullies (kurt up), keeps the fine scale roughness below the input's (hf not up) and
-- lowers the relief a little; presets that destroy the structure or add pixel noise are visible here before the eye notices.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Erosion = import('/lua/editor/erosion.lua')

--- Statistics of a height field `f`.
function Measure(f)
    return Fields.Run(function(S)
        local out = {}
        local slope = S:Op('slope', { a = f, mode = 'gradient' })
        local _, _, mean = Fields.Stats(slope)
        out.slope = mean
        local steep = S:Op('threshold', { a = slope, value = 0.75 })
        local _, _, steepMean = Fields.Stats(steep)
        out.steep = steepMean
        local flow = S:Op('erode_stream', { a = f, iterations = 0, output = 'flow' })
        local chan = S:Op('threshold', { a = flow, value = 64 })
        local _, _, density = Fields.Stats(chan)
        out.drain = density
        -- concavity of the slope - area relation: slope ~ area^-theta in the channel range (catchments of 16 .. 2048 cells)
        local sa = S:Op('slope_area', { a = f, bins = 10, first = 4 })
        local bins = Fields.Read(sa, 0, 0, 9, 2)
        local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
        for b = 1, 10 do
            local count = bins[20 + b]
            local meanSlope = bins[10 + b]
            if count >= 100 and meanSlope > 0 then
                local x, y = bins[b] + 0.5, math.log(meanSlope) / math.log(2)
                n, sx, sy, sxx, sxy = n + 1, sx + x, sy + y, sxx + x * x, sxy + x * y
            end
        end
        local basin = S:Op('basin_depth', { a = f })
        local _, _, basinMean = Fields.Stats(basin)
        local wet = S:Op('threshold', { a = basin, value = 0.05 })
        local _, _, wetShare = Fields.Stats(wet)
        out.pits = wetShare
        out.pitdepth = basinMean
        out.theta = 0
        if n >= 3 and n * sxx - sx * sx > 0 then out.theta = -(n * sxy - sx * sy) / (n * sxx - sx * sx) end
        local c1 = S:Op('curvature', { a = f, radius = 1, raw = 1 })
        local _, _, m1, sd1 = Fields.Stats(c1)
        local centred = S:Op('affine', { a = c1, mul = 1, add = -m1 })
        local sq = S:Op('mul', { a = centred, b = centred })
        local quad = S:Op('mul', { a = sq, b = sq })
        local _, _, m2 = Fields.Stats(sq)
        local _, _, m4 = Fields.Stats(quad)
        out.kurt = m2 > 0 and (m4 / (m2 * m2)) or 0
        local cube = S:Op('mul', { a = sq, b = centred })
        local _, _, m3 = Fields.Stats(cube)
        out.skew = m2 > 0 and (m3 / math.pow(m2, 1.5)) or 0
        local a1 = S:Op('abs', { a = c1 })
        local c3 = S:Op('curvature', { a = f, radius = 3, raw = 1 })
        local a3 = S:Op('abs', { a = c3 })
        local _, _, e1 = Fields.Stats(a1)
        local _, _, e3 = Fields.Stats(a3)
        out.hf = e3 > 0 and (e1 / e3) or 0
        local _, _, _, sdh = Fields.Stats(f)
        out.relief = sdh
        return out
    end)
end

local function Row(label, m)
    return string.format('  %-26s slope %.3f  steep %.3f  drain %.3f  pits %.3f  pitdepth %.3f  skew %5.2f  kurt %6.1f  hf %.2f  relief %.2f', label, m.slope, m.steep, m.drain, m.pits, m.pitdepth, m.skew, m.kurt, m.hf, m.relief)
end

--- A mountain field of the map size: ridged fractal noise (1 - |2 perlin - 1|) with slopes like the stock maps (mean gradient 0.3; the amplitude grows with the map: 60 units at 513 samples).
local function Mountains(S)
    local w, h = ed_terrain_info()
    local p = S:Op('perlin', { width = w, height = h, seed = 21, scale = w * 0.5, octaves = 5, persistence = 0.5 })
    local a = S:Op('affine', { a = p, mul = 2, add = -1 })
    local b = S:Op('abs', { a = a })
    local r = S:Op('affine', { a = b, mul = -1, add = 1 })
    return S:Op('affine', { a = r, mul = 60 * w / 513, add = 10 })
end

--- The statistics of the generated mountains and of every preset applied to them. Returns text.
function Report()
    local lines = {}
    local w, h = ed_terrain_info()
    table.insert(lines, 'erosion quality on a generated ' .. w .. ' x ' .. h .. ' mountain field')
    Fields.Run(function(S)
        local base = Mountains(S)
        table.insert(lines, Row('input', Measure(base)))
        for _, preset in Erosion.Presets do
            local v = Erosion.Defaults(preset.solver)
            for k, x in preset.values do v[k] = x end
            local def = Erosion.Solvers[preset.solver]
            local params = Erosion.OpParams(preset.solver, v, 1, nil)
            params.a = base
            local t0 = ed_field_clock()
            local f, err = ed_field_op(def.op, params)
            local dt = ed_field_clock() - t0
            if f then
                S:Add(f)
                table.insert(lines, Row(preset.label .. string.format(' (%.2f s)', dt), Measure(f)))
            else
                table.insert(lines, '  ' .. preset.label .. ': ' .. tostring(err))
            end
        end
    end)
    return table.concat(lines, '\n')
end

--- The statistics of height maps exported as 16 bit PNG (heights in 1/128 units, see Fields.Image): the reference terrain to compare the presets with. `paths`: list of file paths.
function References(paths)
    local lines = {}
    for _, file in paths do
        local path = file
        local ok, err = pcall(function()
            Fields.Run(function(S)
                local f = S:Image(path, { as = 'height' })
                local w, h = Fields.Info(f)
                local name = string.gsub(path, '^.*/', '')
                table.insert(lines, Row(string.format('%s (%d)', name, w), Measure(f)))
            end)
        end)
        if not ok then table.insert(lines, '  ' .. path .. ': ' .. tostring(err)) end
    end
    return table.concat(lines, '\n')
end
