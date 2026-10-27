-- Graph nodes that shape the LAND (docs/projects/editor/GRAPH_TEXTURING.md, "What a good map has"): a map that plays and looks good is not noise everywhere, it is flat open ground with steep, well
-- defined features. These nodes make that from any noisy height field.
--
--   Flatten gentle ground   smooths the ground where it is gentle (below a slope) and leaves the steep parts alone: plains and basins with crisp ridges, cliffs and banks (the World Machine
--                           "select by slope, blur the selection" step that the reference maps are full of)
--
-- graphnodes.lua calls Install(Kit, Covers) once. Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

function Install(Kit, Covers)
    local Def, N, C, B, In, Out = Kit.Def, Kit.N, Kit.C, Kit.B, Kit.In, Kit.Out

    -- the value (in standard deviations) that a share p of a normal distribution lies above (Abramowitz and Stegun 26.2.23)
    local function Z(p)
        p = math.max(0.001, math.min(0.999, p))
        local q = (p < 0.5) and p or (1 - p)
        local t = math.sqrt(-2 * math.log(q))
        local z = t - (2.515517 + 0.802853 * t + 0.010328 * t * t) / (1 + 1.432788 * t + 0.189269 * t * t + 0.001308 * t * t * t)
        if p < 0.5 then return z end
        return -z
    end

    Def('landform', { label = 'Landforms (plains and hills)', cat = 'gen', kw = 'landform plains hills valley plateau cliffs layout shapes open ground flat buildable world machine selective',
        desc = 'The layout of a good map: flat open plains and clusters of hills with defined flanks. A large noise decides where the hills are (a share of the map you choose), the flanks are as wide as you say (steepness = height / flank), the hills get ridged detail and rounder or sharper tops, the plains stay nearly flat with a little unevenness. Output height is in units (ground height + landforms); mask is the hills (1) against the plains (0): use it for paint (green hills on bare plains) and scatter. Erode it afterwards for realism.',
        outputs = { Out('out', 'height'), Out('mask', 'mask') },
        params = { N('seed', 'Seed', 0, 9999, 1, '%d', 1, { seed = true }), N('base', 'Ground height of the plains (units)', 0, 200, 0.5, '%.1f', 30),
                   N('size', 'Landform size (units)', 60, 800, 5, '%d', 240), N('coverage', 'Share of the map that is hills', 0.05, 0.9, 0.01, '%.2f', 0.35),
                   N('height', 'Hill height above the plains (units)', 1, 120, 0.5, '%.1f', 16), N('edge', 'Width of the flanks (units)', 4, 120, 1, '%d', 24),
                   N('top', 'Roundness of the tops', 0, 1, 0.05, '%.2f', 0.5), N('detail', 'Roughness of the hills', 0, 1, 0.05, '%.2f', 0.5),
                   N('plains', 'Unevenness of the plains (units)', 0, 10, 0.1, '%.1f', 1.5) },
        eval = function(E, v, ins)
            local function Fit01(f, lo, hi)
                return E:Op('clamp', { a = E:Op('affine', { a = f, mul = 1 / (hi - lo), add = -lo / (hi - lo) }), lo = 0, hi = 1 })
            end
            -- where the hills are: a large noise cut at the level that leaves `coverage` of the map above it (perlin fitted 0.25 .. 0.75 is about normal around 0.5, sigma 0.16)
            local n = Fit01(E:Op('perlin', { like = E.like, seed = E:Seed(v.seed), scale = v.size, octaves = 4, persistence = 0.5, rotate = 1 }), 0.25, 0.75)
            local t = 0.5 + 0.16 * Z(v.coverage)          -- (Z is the distance above the middle that a share `coverage` lies above: coverage 0.4 cuts above the middle; with a minus the hills covered 1 - coverage, 0.58 for 0.4)
            local cut = E:Op('smoothstep', { a = n, edge0 = t - 0.012, edge1 = t + 0.012 })
            local mask = E:Op('blur', { a = cut, radius = E:Units(math.max(2, v.edge * 0.5)) })
            -- tops: a power of the softened mask (small exponent = plateaus, large = peaks)
            local shaped = E:Op('gamma', { a = mask, gamma = 1.6 - v.top })
            -- detail on the hills only
            local ridges = Fit01(E:Op('ridged', { like = E.like, seed = E:Seed(v.seed + 1), scale = math.max(20, v.size * 0.35), octaves = 5, persistence = 0.5, rotate = 1 }), 0.25, 1)
            local factor = E:Op('affine', { a = ridges, mul = 0.5 * v.detail, add = 1 - 0.25 * v.detail })
            local hills = E:Op('mul', { a = E:Op('affine', { a = shaped, mul = v.height, add = 0 }), b = factor })
            -- the plains
            local p = Fit01(E:Op('perlin', { like = E.like, seed = E:Seed(v.seed + 2), scale = v.size * 1.6, octaves = 3, persistence = 0.5, rotate = 1 }), 0.25, 0.75)
            local plains = E:Op('affine', { a = p, mul = 2 * v.plains, add = v.base - v.plains })
            return { out = E:Op('add', { a = plains, b = hills }), mask = mask }
        end })

    Def('flatten', { label = 'Flatten gentle ground', cat = 'shape', kw = 'flatten plains smooth gentle slope selective blur flat buildable open ground valley basin',
        desc = 'Smooths the ground where it is gentle and keeps what is steep: the slope (measured over a distance, so small bumps do not count) selects the ground below the limit, that selection is softened at its edges, and the ground there is replaced by a blur of itself. The result is flat, open, buildable ground with crisp ridges, banks and cliffs instead of noise everywhere (a good map has about half of its ground under 5 degrees). mask is the flattened area (use it for paint: dirt and sand on the plains).',
        inputs = { In('a', 'height') },
        outputs = { Out('out', 'height'), Out('mask', 'mask') },
        params = { N('below', 'Ground gentler than (degrees)', 2, 40, 1, '%d', 12, { wire = true }), N('soft', 'Transition (degrees)', 1, 20, 1, '%d', 6),
                   N('measure', 'Slope measured over (units)', 2, 60, 1, '%d', 12), N('radius', 'Smoothing distance (units)', 4, 200, 1, '%d', 40),
                   N('edge', 'Softness of the edges (units)', 0, 80, 1, '%d', 20), N('strength', 'Strength', 0, 1, 0.05, '%.2f', 0.9, { wire = true }) },
        eval = function(E, v, ins)
            local H = ins.a
            local seen = E:Op('blur', { a = H, radius = E:Units(v.measure) })
            local slope = E:Op('slope', { a = seen, mode = 'degrees', radius = 1 })
            local lo = math.max(0, v.below - v.soft * 0.5)
            local steep = E:Op('smoothstep', { a = slope, edge0 = lo, edge1 = lo + v.soft })
            local flat = E:Op('invert', { a = steep, lo = 0, hi = 1 })
            if v.edge > 0 then flat = E:Op('blur', { a = flat, radius = E:Units(v.edge) }) end
            local mask = E:Op('affine', { a = flat, mul = v.strength, add = 0 })
            local smooth = E:Op('blur', { a = H, radius = E:Units(v.radius) })
            local out = E:Op('blend', { a = H, b = smooth, mask = mask, mode = 'normal', opacity = 1 })
            return { out = out, mask = flat }
        end })
end
