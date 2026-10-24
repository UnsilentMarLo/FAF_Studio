-- Node definitions of stage T7 (docs/projects/editor/TERRAIN_GEN_DESIGN.md, section T7): the 28 new field ops (EdFieldGen.cpp, EdFieldFilt.cpp, EdFieldEro2.cpp) as dedicated nodes, three
-- composed presets (hills, mountains, mesas), the colour ramp and the colour output. graphnodes.lua calls Install(Kit, Covers) once; Kit carries its constructors (Def, N, C, B, T, In, Out, ...), so
-- this file does not import graphnodes.lua (no import cycle). The palette, inspector, evaluation, cache, thumbnails and the self test pick the nodes up like any other.
--
-- Port type `color` (new): an RGBA bundle { r = field, g = field, b = field, a = field } (four mask fields, 0..1). The `Colour ramp` node makes it, `Output: colour image` writes it.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

function Install(Kit, Covers)
    local Def, N, C, B, T, In, Out, One, Fit, SEED = Kit.Def, Kit.N, Kit.C, Kit.B, Kit.T, Kit.In, Kit.Out, Kit.One, Kit.Fit, Kit.SEED

    for _, op in { 'fractal', 'musgrave', 'fbm_damped', 'cells', 'craters', 'dunes', 'cracks', 'island', 'dwarp', 'bilateral', 'diffuse', 'unsharp', 'edge', 'morph', 'convolve', 'blur_dir', 'blur_slope',
                   'stratify', 'occlusion', 'hillshade', 'wetness', 'rockiness', 'color_ramp', 'thermal_map', 'erode_rocksoil', 'erode_snow', 'erode_wind', 'erode_glacier', 'settle' } do
        Covers[op] = true
    end

    --- Iteration counts follow the preview resolution (a coarse grid needs fewer steps for the same reach).
    local function Iters(E, n)
        if E.step > 1 then return math.max(1, math.floor(n / E.step + 0.5)) end
        return n
    end

    --- Runs an op with several results; the main result is `out`, the extras are named like the op names them. Everything is owned by the evaluation.
    local function Multi(E, op, p, names)
        local main, extra = Kit.Fields.OpMulti(op, p)
        if not main then error(tostring(extra)) end
        E:Add(main)
        local outs = { out = main }
        if extra then
            for k, f in extra do E:Add(f) end
            for _, name in names do
                if extra[name] then outs[name] = extra[name] end
            end
        end
        return outs
    end

    local function NoiseNode(id, label, kw, desc, params, eval)
        Def(id, { label = label, cat = 'gen', kw = kw, desc = desc, params = params, eval = eval })
    end

    -- ---- generators ---------------------------------------------------------------------------------------------------------------------------------

    NoiseNode('fractal', 'Terrain noise', 'terrain noise fractal natural fbm ridged billow warp slope detail gradient hills mountains', 'Gradient noise built to look like land: every octave in its own turned frame (no grid lines), an optional domain warp, rolling, rounded or sharp ridged shapes, and finer detail on steep or flat ground. 0..1.',
        { SEED, N('scale', 'Feature size (units)', 8, 1000, 2, '%d', 160, { wire = true }), N('octaves', 'Octaves', 1, 12, 1, '%d', 8), N('finest', 'Smallest detail (units)', 2, 200, 1, '%d', 12),
          N('persistence', 'Persistence', 0.2, 0.9, 0.05, '%.2f', 0.5), C('kind', 'Shape', { 'fbm', 'billow', 'ridged' }, { 'Rolling (fBm)', 'Rounded hills (billow)', 'Sharp crests (ridged)' }, 'fbm'),
          N('sharpness', 'Ridge sharpness', 1, 5, 0.1, '%.1f', 2), N('warp', 'Warp (units)', 0, 300, 1, '%d', 20), N('slope_detail', 'Detail on slopes (- flat, + steep)', -1, 1, 0.05, '%.2f', 0),
          N('warp_levels', 'Warp passes', 1, 2, 1, '%d', 1, { tip = '1: the warp noise bends the ground once. 2: the warp is read at a place that was already bent (a warp of a warp): more twisted, folded shapes.' }),
          C('style', 'Style', { 'classic', 'erosive' }, { 'Classic', 'Eroded (smooth slopes)' }, 'classic', 'Classic: every octave adds the same detail. Eroded: finer octaves are damped where the terrain so far is steep, so slopes stay smooth and crests and flats keep their detail (the look of water worn land).'),
          N('erosion', 'Erosion strength', 0, 6, 0.1, '%.1f', 1, { tip = 'Eroded style only: how strongly steep ground damps the finer detail. 0 = like classic. Ridged shapes already have steep crests, so use less there.' }) },
        function(E, v, ins)
            return One(E:Op('fractal', { like = E.like, seed = E:Seed(v.seed), scale = v.scale, octaves = v.octaves, finest = v.finest, persistence = v.persistence, kind = v.kind,
                                         sharpness = v.sharpness, warp = v.warp, slope_detail = v.slope_detail, style = v.style, erosion = v.erosion, warp_levels = v.warp_levels }))
        end)

    NoiseNode('musgrave', 'Multifractal (Musgrave)', 'musgrave multifractal ridged hybrid heterogeneous mountains terrain noise', 'Musgrave multifractals: ridged (sharp crests), hybrid (rough peaks over smooth valleys) and heterogeneous terrain.',
        { SEED, N('scale', 'Feature size (units)', 8, 1000, 2, '%d', 160, { wire = true }), N('octaves', 'Octaves', 1, 12, 1, '%d', 7), N('lacunarity', 'Lacunarity', 1.5, 3.5, 0.05, '%.2f', 2),
          N('h', 'Roughness exponent (H)', 0, 2, 0.05, '%.2f', 1), N('offset', 'Offset', 0.2, 1.5, 0.05, '%.2f', 1), N('gain', 'Gain', 0.5, 4, 0.1, '%.1f', 2),
          C('mode', 'Mode', { 'ridged', 'hybrid', 'hetero' }, { 'Ridged', 'Hybrid', 'Heterogeneous' }, 'ridged') },
        function(E, v, ins)
            local f = E:Op('musgrave', { like = E.like, seed = E:Seed(v.seed), scale = v.scale, octaves = v.octaves, lacunarity = v.lacunarity, h = v.h, offset = v.offset, gain = v.gain, mode = v.mode, rotate = 1 })
            if v.mode == 'ridged' then return One(Fit(E, f, 0.05, 0.95)) end
            if v.mode == 'hybrid' then return One(Fit(E, f, 0, 0.6)) end
            return One(Fit(E, f, 0, 0.9))
        end)

    NoiseNode('fbm_damped', 'Eroded noise', 'eroded noise damped fbm derivative smooth valleys terrain realistic', 'Fractal noise that smooths itself where it is steep: smooth valley floors, rough crests, the look of eroded land. 0..1.',
        { SEED, N('scale', 'Feature size (units)', 8, 1000, 2, '%d', 160, { wire = true }), N('octaves', 'Octaves', 1, 12, 1, '%d', 8), N('persistence', 'Persistence', 0.2, 0.9, 0.05, '%.2f', 0.5),
          N('damp', 'Slope damping', 0, 8, 0.1, '%.1f', 1.5) },
        function(E, v, ins)
            return One(Fit(E, E:Op('fbm_damped', { like = E.like, seed = E:Seed(v.seed), scale = v.scale, octaves = v.octaves, persistence = v.persistence, damp = v.damp, rotate = 1 }), 0.15, 0.82))
        end)

    NoiseNode('cells', 'Cells (Voronoi variants)', 'voronoi cells cellular plates crystal facets border distance metric manhattan chebyshev smooth', 'Cell noise with the usual variants: nearest distances, borders, smooth blends, a level per cell with bevelled borders (plates), tilted facets; several distance metrics; domain warp.',
        { SEED, N('scale', 'Cell size (units)', 6, 800, 2, '%d', 90, { wire = true }), N('jitter', 'Jitter', 0, 1, 0.05, '%.2f', 1),
          C('mode', 'Mode', { 'f1', 'f2', 'f3', 'edge', 'crack', 'id', 'smooth', 'border', 'plate', 'facet' },
            { 'Nearest distance', 'Second distance', 'Third distance', 'Edges (f2 - f1)', 'Cracks', 'Value per cell', 'Smooth minimum', 'Distance to the border', 'Plates (bevelled)', 'Facets' }, 'plate'),
          C('metric', 'Distance metric', { 'euclid', 'manhattan', 'chebyshev', 'minkowski' }, { 'Euclidean', 'Manhattan', 'Chebyshev', 'Minkowski' }, 'euclid'),
          N('p', 'Minkowski exponent', 0.3, 8, 0.1, '%.1f', 3), N('smooth', 'Smooth minimum sharpness', 1, 30, 0.5, '%.1f', 8), N('thickness', 'Crack thickness', 0.02, 0.5, 0.01, '%.2f', 0.12),
          N('bevel', 'Plate bevel (share of a cell)', 0.01, 0.5, 0.01, '%.2f', 0.12), N('drop', 'Plate bevel depth', 0, 1, 0.05, '%.2f', 0.4),
          N('warp', 'Domain warp (units)', 0, 300, 1, '%d', 0), N('warp_scale', 'Warp feature size (units)', 8, 600, 2, '%d', 160) },
        function(E, v, ins)
            return One(E:Op('cells', { like = E.like, seed = E:Seed(v.seed), scale = v.scale, jitter = v.jitter, mode = v.mode, metric = v.metric, p = v.p, smooth = v.smooth, thickness = v.thickness,
                                       bevel = v.bevel, drop = v.drop, warp = v.warp, warp_scale = v.warp_scale }))
        end)

    NoiseNode('craters', 'Craters', 'craters impact meteor moon bowl rim', 'A scatter of impact craters: a bowl with a raised rim. 0.5 is the ground, bowls go down, rims up.',
        { SEED, N('scale', 'Spacing (units)', 20, 600, 2, '%d', 120, { wire = true }), N('density', 'Share of cells with a crater', 0, 1, 0.05, '%.2f', 0.6), N('rmin', 'Smallest radius (share of a cell)', 0.02, 0.5, 0.01, '%.2f', 0.15),
          N('rmax', 'Largest radius (share of a cell)', 0.05, 0.5, 0.01, '%.2f', 0.45), N('depth', 'Depth', 0, 0.5, 0.01, '%.2f', 0.4), N('rim', 'Rim height (share of depth)', 0, 1, 0.05, '%.2f', 0.25),
          N('shape', 'Bowl shape (flat floor above 1)', 0.5, 6, 0.1, '%.1f', 1.5) },
        function(E, v, ins)
            return One(E:Op('craters', { like = E.like, seed = E:Seed(v.seed), scale = v.scale, density = v.density, rmin = v.rmin, rmax = v.rmax, depth = v.depth, rim = v.rim, shape = v.shape, base = 0.5 }))
        end)

    NoiseNode('dunes', 'Dunes', 'dunes sand desert wind ridges barchan waves', 'Asymmetric dune ridges (a gentle windward and a steep slip face) with meandering crests and ripples. 0..1.',
        { SEED, N('wavelength', 'Wavelength (units)', 8, 600, 1, '%d', 70, { wire = true }), N('angle', 'Wind direction (degrees)', 0, 360, 5, '%d', 20), N('asym', 'Asymmetry', 0, 1.6, 0.05, '%.2f', 0.9),
          N('warp', 'Crest meander (units)', 0, 200, 1, '%d', 25), N('warp_size', 'Meander size (units)', 10, 600, 5, '%d', 140), N('variation', 'Crest height variation', 0, 1, 0.05, '%.2f', 0.4),
          N('ripples', 'Ripples', 0, 0.6, 0.02, '%.2f', 0.12) },
        function(E, v, ins)
            return One(E:Op('dunes', { like = E.like, seed = E:Seed(v.seed), wavelength = v.wavelength, angle = v.angle, asym = v.asym, warp = v.warp, warp_size = v.warp_size, variation = v.variation, ripples = v.ripples }))
        end)

    Def('cracks', { label = 'Cracks', cat = 'gen', kw = 'cracks fractures dry mud rock fissures network', outputs = { Out('out', 'mask') },
        desc = 'A network of cracks (1 in a crack, 0 on the plates), several finer networks, warped. Subtract it from the ground to cut fissures.',
        params = { SEED, N('scale', 'Plate size (units)', 8, 800, 2, '%d', 90, { wire = true }), N('crack_width', 'Crack width (units)', 0.3, 40, 0.1, '%.1f', 3), N('levels', 'Networks (finer each)', 1, 3, 1, '%d', 2),
                   N('warp', 'Warp (units)', 0, 200, 1, '%d', 12), N('jitter', 'Jitter', 0, 1, 0.05, '%.2f', 0.9), C('profile', 'Profile', { 'v', 'u', 'flat' }, { 'V (soft)', 'U', 'Flat (hard edge)' }, 'v') },
        eval = function(E, v, ins)
            return One(E:Op('cracks', { like = E.like, seed = E:Seed(v.seed), scale = v.scale, crack_width = v.crack_width, levels = v.levels, warp = v.warp, jitter = v.jitter, profile = v.profile }))
        end })

    Def('island', { label = 'Island shape', cat = 'gen', kw = 'island coast atoll shape continent ragged disc archipelago', desc = 'A ragged island: height dome (or a mask, or the distance from the coast) from a disc with noisy coast.',
        params = { SEED, N('cx', 'Centre x (share of the map)', 0, 1, 0.01, '%.2f', 0.5), N('cz', 'Centre z (share of the map)', 0, 1, 0.01, '%.2f', 0.5), N('radius', 'Radius (units, 0 = half the map)', 0, 6000, 4, '%d', 0, { wire = true }),
                   N('aspect', 'Aspect (stretch along the angle)', 0.3, 3, 0.05, '%.2f', 1), N('angle', 'Angle (degrees)', 0, 180, 5, '%d', 0), N('roughness', 'Coast roughness', 0, 1, 0.05, '%.2f', 0.35),
                   N('noise_scale', 'Coast feature size (units, 0 = auto)', 0, 2000, 5, '%d', 0), N('edge', 'Coast softness', 0.005, 0.5, 0.005, '%.3f', 0.08), N('power', 'Profile exponent', 0.2, 4, 0.05, '%.2f', 1.4),
                   C('output', 'Output', { 'height', 'mask', 'distance' }, { 'Height dome', 'Land mask', 'Distance from the coast' }, 'height') },
        eval = function(E, v, ins)
            local p = { like = E.like, seed = E:Seed(v.seed), cx = v.cx * E.W, cz = v.cz * E.H, aspect = v.aspect, angle = v.angle, roughness = v.roughness, edge = v.edge, power = v.power, output = v.output }
            if v.radius > 0 then p.radius = v.radius else p.radius = 0.5 * math.min(E.W, E.H) end
            p.noise_scale = v.noise_scale > 0 and v.noise_scale or p.radius * 0.5
            return One(E:Op('island', p))
        end })

    -- ---- composed presets -----------------------------------------------------------------------------------------------------------------------------

    NoiseNode('hills', 'Hills (preset)', 'hills rolling soft hills preset terrain', 'Rolling hills: soft billow and fractal noise blended, gentle slopes. 0..1.',
        { SEED, N('scale', 'Hill size (units)', 30, 1200, 5, '%d', 220, { wire = true }), N('roundness', 'Roundness', 0, 1, 0.05, '%.2f', 0.5), N('detail', 'Detail', 0, 1, 0.05, '%.2f', 0.3) },
        function(E, v, ins)
            local seed = E:Seed(v.seed)
            local soft = E:Op('billow', { like = E.like, seed = seed, scale = v.scale, octaves = 3, persistence = 0.45, rotate = 1 })
            local base = E:Op('perlin', { like = E.like, seed = seed + 1, scale = v.scale * 1.4, octaves = 4, persistence = 0.5, rotate = 1 })
            local fine = E:Op('perlin', { like = E.like, seed = seed + 2, scale = v.scale * 0.25, octaves = 3, persistence = 0.5, rotate = 1 })
            local mix = E:Op('blend', { a = Fit(E, base, 0.25, 0.75), b = Fit(E, soft, 0, 0.5), mode = 'normal', opacity = v.roundness })
            return One(E:Op('blend', { a = mix, b = Fit(E, fine, 0.25, 0.75), mode = 'overlay', opacity = v.detail }))
        end)

    NoiseNode('mountains', 'Mountains (preset)', 'mountains ridges peaks alpine range preset terrain', 'Mountain ranges: ridged multifractal with a domain warp and sharpened peaks. 0..1.',
        { SEED, N('scale', 'Range size (units)', 60, 1500, 5, '%d', 320, { wire = true }), N('octaves', 'Octaves', 3, 10, 1, '%d', 7), N('warp', 'Warp (units)', 0, 300, 1, '%d', 60), N('peaks', 'Sharp peaks', 0.5, 3, 0.05, '%.2f', 1.5) },
        function(E, v, ins)
            local seed = E:Seed(v.seed)
            local f = Fit(E, E:Op('musgrave', { like = E.like, seed = seed, scale = v.scale, octaves = v.octaves, mode = 'ridged', rotate = 1 }), 0.05, 0.95)
            if v.warp > 0 then
                local dx = E:Op('perlin', { like = E.like, seed = seed + 11, scale = v.scale * 0.6, octaves = 3, rotate = 1 })
                local dz = E:Op('perlin', { like = E.like, seed = seed + 12, scale = v.scale * 0.6, octaves = 3, rotate = 1 })
                f = E:Op('warp', { a = f, dx = dx, dz = dz, strength = v.warp })
            end
            return One(E:Op('gamma', { a = f, gamma = v.peaks }))
        end)

    NoiseNode('mesas', 'Mesas and terraces (preset)', 'mesas terraces plateau stepped buttes badlands preset', 'Flat topped hills with stepped sides (a terraced fractal). 0..1.',
        { SEED, N('scale', 'Mesa size (units)', 40, 1200, 5, '%d', 240, { wire = true }), N('steps', 'Steps', 2, 24, 1, '%d', 6), N('sharpness', 'Sharpness', 0, 1, 0.05, '%.2f', 0.75), N('roughness', 'Roughness', 0, 1, 0.05, '%.2f', 0.3) },
        function(E, v, ins)
            local seed = E:Seed(v.seed)
            local f = Fit(E, E:Op('perlin', { like = E.like, seed = seed, scale = v.scale, octaves = 4, persistence = 0.5, rotate = 1 }), 0.25, 0.75)
            f = E:Op('terrace', { a = f, steps = v.steps, sharpness = v.sharpness, lo = 0, hi = 1 })
            local grit = E:Op('perlin', { like = E.like, seed = seed + 5, scale = v.scale * 0.12, octaves = 3, rotate = 1 })
            return One(E:Op('blend', { a = f, b = Fit(E, grit, 0.25, 0.75), mode = 'overlay', opacity = v.roughness }))
        end)

    -- ---- shape (warps and filters) ----------------------------------------------------------------------------------------------------------------------

    Def('dwarp', { label = 'Domain warp', cat = 'shape', kw = 'warp domain distort swirl curl ripple pinch turbulence displace fbm',
        desc = 'Bends a field: by fractal noise (once or twice), a divergence free curl flow, a swirl, ripples or a pinch / bulge.',
        inputs = { In('a', 'height'), In('mask', 'mask', true) },
        params = { SEED, C('kind', 'Kind', { 'fbm', 'curl', 'swirl', 'ripple', 'pinch' }, { 'Noise', 'Curl flow', 'Swirl', 'Ripples', 'Pinch / bulge' }, 'fbm'),
                   N('strength', 'Strength (units; swirl: degrees; pinch: factor)', -400, 400, 0.5, '%.1f', 40, { wire = true }), N('size', 'Size (units; swirl, pinch: radius)', 5, 1500, 5, '%d', 120),
                   N('octaves', 'Octaves', 1, 8, 1, '%d', 3), N('iterations', 'Warp of a warp (1 - 3)', 1, 3, 1, '%d', 1), N('angle', 'Ripple direction (degrees)', 0, 360, 5, '%d', 0),
                   N('wavelength', 'Ripple wavelength (units)', 4, 600, 1, '%d', 60), N('cx', 'Centre x (share)', 0, 1, 0.01, '%.2f', 0.5), N('cz', 'Centre z (share)', 0, 1, 0.01, '%.2f', 0.5),
                   C('edge', 'Edges', { 'clamp', 'wrap', 'mirror' }, { 'Clamp', 'Wrap', 'Mirror' }, 'clamp') },
        eval = function(E, v, ins)
            return One(E:Op('dwarp', { a = ins.a, mask = ins.mask, seed = E:Seed(v.seed), kind = v.kind, strength = v.strength, size = v.size, octaves = v.octaves, iterations = v.iterations, angle = v.angle,
                                       wavelength = v.wavelength, cx = v.cx * E.W, cz = v.cz * E.H, edge = v.edge }))
        end })

    local function Shape(id, label, kw, desc, params, make, extra)
        local d = { label = label, cat = 'shape', kw = kw, desc = desc, inputs = { In('a', 'height'), In('mask', 'mask', true) }, params = params,
            eval = function(E, v, ins)
                local p = make(v, E)
                p.a = ins.a
                p.mask = ins.mask
                return One(E:Op(id, p))
            end }
        if extra then for k, x in extra do d[k] = x end end
        Def(id, d)
    end

    Shape('bilateral', 'Smooth (keep edges)', 'bilateral smooth edge preserving ridge keep cliffs denoise', 'Averages a window but ignores neighbours that differ by much more than the range: noise goes, cliffs and ridges stay.',
        { N('radius', 'Radius (units)', 1, 40, 0.5, '%.1f', 6), N('sigma_r', 'Height range kept (units)', 0.1, 60, 0.1, '%.1f', 2, { wire = true }) },
        function(v) return { radius = v.radius, sigma_r = v.sigma_r } end)
    Shape('diffuse', 'Smooth (diffusion)', 'anisotropic diffusion perona malik smooth cliffs keep flat soften', 'Perona-Malik diffusion: flat ground relaxes, steep faces (above the edge threshold) stay sharp.',
        { N('iterations', 'Iterations', 1, 300, 1, '%d', 30), N('kappa', 'Edge threshold (rise / run)', 0.02, 3, 0.02, '%.2f', 0.4, { wire = true }), N('rate', 'Rate', 0.02, 0.25, 0.01, '%.2f', 0.2),
          C('g', 'Conduction', { 'lorentz', 'exp' }, { 'Lorentzian', 'Exponential (sharper)' }, 'lorentz') },
        function(v, E) return { iterations = Iters(E, v.iterations), kappa = v.kappa, rate = v.rate, g = v.g } end)
    Shape('unsharp', 'Sharpen', 'sharpen unsharp mask detail crisp contrast', 'Unsharp mask: adds back the difference to a blurred copy.',
        { N('radius', 'Radius (units)', 0.5, 80, 0.5, '%.1f', 4), N('amount', 'Amount', 0, 4, 0.05, '%.2f', 1, { wire = true }), N('threshold', 'Ignore differences below (units)', 0, 10, 0.05, '%.2f', 0) },
        function(v) return { radius = v.radius, amount = v.amount, threshold = v.threshold } end)
    Shape('edge', 'Edge detect', 'edge detect sobel prewitt laplace difference gaussians outline ridge', 'Edge strength: Sobel / Prewitt (rise per run), the Laplacian (creases) or a difference of gaussians. A mask.',
        { C('mode', 'Method', { 'sobel', 'prewitt', 'laplace', 'dog' }, { 'Sobel', 'Prewitt', 'Laplacian', 'Difference of gaussians' }, 'sobel'), N('gain', 'Gain', 0.05, 100, 0.05, '%.2f', 2, { wire = true }),
          N('smooth', 'Smooth first (units)', 0, 40, 0.5, '%.1f', 0), N('radius', 'Gaussian size (units, DoG)', 0.5, 60, 0.5, '%.1f', 3), B('signed', 'Signed (0.5 = flat)', false) },
        function(v) return { mode = v.mode, gain = v.gain, smooth = v.smooth, radius = v.radius, signed = v.signed and 1 or 0 } end, { outputs = { Out('out', 'mask') } })
    Shape('morph', 'Morphology', 'morphology dilate erode open close gradient tophat grayscale shapes', 'Grey scale morphology with a square, disc, cross or diamond: dilate, erode, open (removes narrow peaks), close (fills narrow pits), gradient, top hats.',
        { C('op', 'Operation', { 'dilate', 'erode', 'open', 'close', 'gradient', 'tophat', 'bothat' }, { 'Dilate (max)', 'Erode (min)', 'Open', 'Close', 'Gradient', 'Top hat (peaks)', 'Bottom hat (pits)' }, 'open'),
          N('radius', 'Radius (units)', 1, 60, 0.5, '%.1f', 6), C('shape', 'Shape', { 'square', 'disc', 'cross', 'diamond' }, { 'Square', 'Disc', 'Cross', 'Diamond' }, 'disc') },
        function(v) return { op = v.op, radius = v.radius, shape = v.shape } end)
    local KERNELS = {
        { 'identity', 'Identity', '0:0:0;0:1:0;0:0:0', 1, 0 }, { 'sharpen', 'Sharpen', '0:-1:0;-1:5:-1;0:-1:0', 1, 0 }, { 'emboss', 'Emboss', '-2:-1:0;-1:1:1;0:1:2', 0, 0 },
        { 'edge', 'Edge (Laplacian)', '0:1:0;1:-4:1;0:1:0', 0, 0 }, { 'ridge', 'Ridge detect', '-1:-1:-1;-1:8:-1;-1:-1:-1', 0, 0 }, { 'blur3', 'Blur 3 x 3', '1:2:1;2:4:2;1:2:1', 1, 0 },
        { 'blur5', 'Blur 5 x 5', '1:4:6:4:1;4:16:24:16:4;6:24:36:24:6;4:16:24:16:4;1:4:6:4:1', 1, 0 }, { 'sobelx', 'Sobel x', '-1:0:1;-2:0:2;-1:0:1', 0, 0 }, { 'custom', 'Custom', '', 1, 0 },
    }
    local kids, klabels = {}, {}
    for _, k in KERNELS do table.insert(kids, k[1]) table.insert(klabels, k[2]) end
    Shape('convolve', 'Convolution', 'convolve kernel matrix emboss sharpen filter custom', 'Convolves with a 3 x 3 or 5 x 5 kernel: presets or your own numbers (rows separated by ;, values by :).',
        { C('preset', 'Kernel', kids, klabels, 'sharpen'), T('kernel', 'Custom kernel (a:b:c;d:e:f;g:h:i)', '0:-1:0;-1:5:-1;0:-1:0'), N('scale', 'Multiply', -10, 10, 0.05, '%.2f', 1), N('bias', 'Add', -300, 600, 0.5, '%.1f', 0) },
        function(v)
            local text, norm = v.kernel, 1
            for _, k in KERNELS do
                if k[1] == v.preset and k[1] ~= 'custom' then text, norm = k[3], k[4] end
            end
            local flat = {}
            for num in string.gfind(text, '[^:;]+') do
                local n = tonumber(num)
                if n then table.insert(flat, n) end
            end
            if table.getn(flat) ~= 9 and table.getn(flat) ~= 25 and table.getn(flat) ~= 49 then error('the kernel needs 9, 25 or 49 numbers') end
            return { kernel = flat, normalize = norm, scale = v.scale, bias = v.bias }
        end)
    Shape('blur_dir', 'Directional blur', 'blur directional motion streak wind smear', 'Blurs along a direction: wind-swept streaks, smeared ridges.',
        { N('angle', 'Direction (degrees)', 0, 360, 5, '%d', 30), N('length', 'Length (units)', 1, 300, 1, '%d', 30, { wire = true }), C('shape', 'Weights', { 'box', 'tri', 'gauss' }, { 'Even', 'Triangle', 'Gaussian' }, 'tri') },
        function(v) return { angle = v.angle, length = v.length, shape = v.shape } end)
    Shape('blur_slope', 'Slope blur', 'blur slope flat steep selective smooth cliffs keep', 'Blurs only where the ground is flat (or only where it is steep): smooth plains without softening the cliffs.',
        { N('radius', 'Blur radius (units)', 0.5, 80, 0.5, '%.1f', 8), C('mode', 'Blur where', { 'flat', 'steep' }, { 'The ground is flat', 'The ground is steep' }, 'flat'),
          N('lo', 'From slope (rise / run)', 0, 3, 0.02, '%.2f', 0.2), N('hi', 'To slope (rise / run)', 0.02, 4, 0.02, '%.2f', 0.6), N('amount', 'Amount', 0, 1, 0.05, '%.2f', 1) },
        function(v) return { radius = v.radius, mode = v.mode, lo = v.lo, hi = v.hi, amount = v.amount } end)
    Shape('stratify', 'Rock layers (stratify)', 'stratify strata layers sedimentary rock bedding terraces cliffs ledges', 'Pushes the height onto shelves of random thickness: layered cliffs with ledges, optionally dipping and only on steep ground.',
        { SEED, N('thickness', 'Layer thickness (units)', 0.3, 40, 0.1, '%.1f', 3, { wire = true }), N('variation', 'Thickness variation', 0, 1, 0.05, '%.2f', 0.5), N('sharpness', 'Sharpness', 0, 1, 0.05, '%.2f', 0.8),
          N('strength', 'Strength', 0, 1, 0.05, '%.2f', 1), N('slope_lo', 'Only on slopes from (rise / run)', 0, 3, 0.02, '%.2f', 0), N('slope_hi', '... full strength at', 0, 4, 0.02, '%.2f', 0),
          N('tilt_x', 'Dip along x (rise / run)', -0.5, 0.5, 0.005, '%.3f', 0), N('tilt_z', 'Dip along z (rise / run)', -0.5, 0.5, 0.005, '%.3f', 0), N('warp', 'Layer waviness (units)', 0, 40, 0.5, '%.1f', 0),
          N('warp_size', 'Waviness size (units)', 10, 600, 5, '%d', 120) },
        function(v, E)
            return { seed = E:Seed(v.seed), thickness = v.thickness, variation = v.variation, sharpness = v.sharpness, strength = v.strength, slope_lo = v.slope_lo, slope_hi = v.slope_hi,
                     tilt_x = v.tilt_x, tilt_z = v.tilt_z, warp = v.warp, warp_size = v.warp_size }
        end)

    -- ---- erosion variants -------------------------------------------------------------------------------------------------------------------------------

    Def('thermal_map', { label = 'Thermal (talus map)', cat = 'erosion', kw = 'thermal talus map scree debris slide erosion variable', inputs = { In('a', 'height'), In('b', 'mask', true), In('mask', 'mask', true) },
        outputs = { Out('out', 'height'), Out('scree', 'mask'), Out('moved', 'mask') },
        desc = 'Thermal erosion with a talus angle that varies over the map (wire a mask into b: 0 = the soft angle, 1 = the hard angle). Outputs the debris (scree) and the moved material as masks.',
        params = { N('iterations', 'Iterations', 1, 400, 1, '%d', 30), N('talus', 'Talus without a map (rise / run)', 0.05, 2, 0.05, '%.2f', 0.6), N('talus_lo', 'Soft angle (b = 0)', 0.05, 2, 0.05, '%.2f', 0.35),
                   N('talus_hi', 'Hard angle (b = 1)', 0.05, 3, 0.05, '%.2f', 1), N('rate', 'Rate', 0.05, 1, 0.05, '%.2f', 0.5), N('scree_scale', 'Material that reads 1 (units)', 0.05, 20, 0.05, '%.2f', 1) },
        eval = function(E, v, ins)
            return Multi(E, 'thermal_map', { a = ins.a, b = ins.b, mask = ins.mask, iterations = Iters(E, v.iterations), talus = v.talus, talus_lo = v.talus_lo, talus_hi = v.talus_hi, rate = v.rate, scree_scale = v.scree_scale }, { 'scree', 'moved' })
        end })

    Def('erode_rocksoil', { label = 'Rock and soil', cat = 'erosion', kw = 'rock soil weathering regolith slide split rockiness bedrock', inputs = { In('a', 'height'), In('b', 'mask', true) },
        outputs = { Out('out', 'height'), Out('soil', 'height'), Out('rock', 'mask'), Out('moved', 'mask') },
        desc = 'Two layers: rock weathers into soil, the soil slides off steep ground (never more than there is), the rock holds steeper faces. Outputs the soil thickness and a rock exposure mask. Wire a soil thickness into b to start from your own.',
        params = { N('iterations', 'Iterations', 1, 400, 1, '%d', 60), N('soil', 'Start soil thickness (units)', 0, 20, 0.1, '%.1f', 0.4), N('weather', 'Weathering per step', 0, 0.2, 0.002, '%.3f', 0.01),
                   N('depth0', 'Weathering slows at soil depth (units)', 0.1, 10, 0.1, '%.1f', 1), N('soil_talus', 'Soil talus (rise / run)', 0.05, 1.5, 0.05, '%.2f', 0.7), N('rock_talus', 'Rock talus (0 = rock holds)', 0, 4, 0.05, '%.2f', 3),
                   N('rock_vis', 'Rock shows below soil depth (units)', 0.05, 5, 0.05, '%.2f', 0.4), N('rate', 'Rate', 0.05, 1, 0.05, '%.2f', 0.5) },
        eval = function(E, v, ins)
            return Multi(E, 'erode_rocksoil', { a = ins.a, b = ins.b, iterations = Iters(E, v.iterations), soil = v.soil, weather = v.weather, depth0 = v.depth0, soil_talus = v.soil_talus,
                                                  rock_talus = v.rock_talus, rock_vis = v.rock_vis, rate = v.rate }, { 'soil', 'rock', 'moved' })
        end })

    Def('erode_snow', { label = 'Snow and slumping', cat = 'erosion', kw = 'snow slump avalanche snowline accumulation cover glacier ice', inputs = { In('a', 'height'), In('mask', 'mask', true) },
        outputs = { Out('out', 'height'), Out('snow', 'height'), Out('cover', 'mask'), Out('moved', 'mask') },
        desc = 'Snow lies above the snow line (not on cliffs, optionally only where a mask allows) and slumps downhill. Outputs ground + snow, the snow depth and a cover mask for the texture.',
        params = { N('snowline', 'Snow line (height)', -100, 600, 0.5, '%.1f', 40, { wire = true }), N('band', 'Soft band (units)', 0.5, 120, 0.5, '%.1f', 10), N('amount', 'Depth (units)', 0, 30, 0.1, '%.1f', 3),
                   N('steep_lo', 'Sheds from slope (rise / run)', 0.1, 4, 0.05, '%.2f', 0.8), N('steep_hi', '... all gone at', 0.2, 5, 0.05, '%.2f', 1.4), N('snow_talus', 'Slump talus (rise / run)', 0.05, 2, 0.05, '%.2f', 0.9),
                   N('iterations', 'Slump iterations', 0, 300, 1, '%d', 40), N('rate', 'Rate', 0.05, 1, 0.05, '%.2f', 0.5), N('cover_depth', 'Depth that reads covered (units)', 0.05, 5, 0.05, '%.2f', 0.5) },
        eval = function(E, v, ins)
            return Multi(E, 'erode_snow', { a = ins.a, mask = ins.mask, snowline = v.snowline, band = v.band, amount = v.amount, steep_lo = v.steep_lo, steep_hi = v.steep_hi, snow_talus = v.snow_talus,
                                              iterations = Iters(E, v.iterations), rate = v.rate, cover_depth = v.cover_depth }, { 'snow', 'cover', 'moved' })
        end })

    Def('erode_wind', { label = 'Wind erosion', cat = 'erosion', kw = 'wind erosion dust sand abrasion saltation deflation dunes aeolian', inputs = { In('a', 'height'), In('b', 'mask', true) },
        outputs = { Out('out', 'height'), Out('sand', 'height'), Out('abrasion', 'mask') },
        desc = 'Wind abrades exposed windward rock into sand, carries it (slowed uphill, free in the lee) and the sand slides at its angle of repose. Outputs the sand depth and an abrasion mask.',
        params = { N('azimuth', 'Wind blows towards (degrees, 0 = +x, 90 = +z)', 0, 360, 5, '%d', 20), N('iterations', 'Iterations', 1, 400, 1, '%d', 40), N('sand', 'Start sand depth (units)', 0, 10, 0.05, '%.2f', 0.5),
                   N('abrade', 'Abrasion per step (units)', 0, 0.3, 0.002, '%.3f', 0.02), N('speed', 'Carry speed (cells per step)', 0.05, 0.7, 0.05, '%.2f', 0.5), N('drag', 'Slowing on windward slopes', 0, 6, 0.1, '%.1f', 1.5),
                   N('repose', 'Sand angle of repose (rise / run)', 0.2, 1.2, 0.02, '%.2f', 0.62) },
        eval = function(E, v, ins)
            return Multi(E, 'erode_wind', { a = ins.a, b = ins.b, azimuth = v.azimuth, iterations = Iters(E, v.iterations), sand = v.sand, abrade = v.abrade, speed = v.speed, drag = v.drag, repose = v.repose },
                { 'sand', 'abrasion' })
        end })

    Def('erode_glacier', { label = 'Glacier', cat = 'erosion', kw = 'glacier ice valley u shaped carve snow cirque erosion moraine', inputs = { In('a', 'height'), In('b', 'mask', true) },
        outputs = { Out('out', 'height'), Out('ice', 'height'), Out('cover', 'mask'), Out('carve', 'height') },
        desc = 'Ice builds above the equilibrium line, flows downhill and grinds the bed where it is thick and fast: valleys turn U shaped. Outputs the ice thickness, a cover mask and the depth carved.',
        params = { N('ela', 'Equilibrium line (height)', -100, 600, 0.5, '%.1f', 40, { wire = true }), N('iterations', 'Iterations', 10, 2000, 10, '%d', 300), N('grad', 'Mass balance gradient', 0.001, 0.2, 0.001, '%.3f', 0.02),
                   N('acc_max', 'Most accumulation per step', 0, 5, 0.05, '%.2f', 0.5), N('abl_max', 'Most melt per step', 0, 5, 0.05, '%.2f', 1), N('flow', 'Flow coefficient', 0.001, 0.5, 0.001, '%.3f', 0.02),
                   N('max_ice', 'Thickest ice (units)', 5, 500, 5, '%d', 120), N('erode', 'Erosion strength', 0, 0.01, 0.0001, '%.4f', 0.0005), N('erode_pow', 'Erosion exponent', 0.5, 3, 0.05, '%.2f', 1.5),
                   N('max_cut', 'Deepest cut (units)', 0, 100, 0.5, '%.1f', 25) },
        eval = function(E, v, ins)
            return Multi(E, 'erode_glacier', { a = ins.a, b = ins.b, ela = v.ela, iterations = Iters(E, v.iterations), grad = v.grad, acc_max = v.acc_max, abl_max = v.abl_max, flow = v.flow, max_ice = v.max_ice,
                                                 erode = v.erode, erode_pow = v.erode_pow, max_cut = v.max_cut }, { 'ice', 'cover', 'carve' })
        end })

    Def('settle', { label = 'Sediment settling', cat = 'erosion', kw = 'sediment settle deposit fill hollows valley floor alluvial plain flat', inputs = { In('a', 'height'), In('mask', 'mask', true) },
        outputs = { Out('out', 'height'), Out('deposit', 'mask') },
        desc = 'Hollows fill with sediment where the ground is flat enough: valley floors and basins level out. Outputs a deposit mask (alluvium).',
        params = { N('iterations', 'Iterations', 1, 300, 1, '%d', 20), N('rate', 'Rate', 0.05, 1, 0.05, '%.2f', 0.4), N('cap', 'Most per step (units)', 0.02, 5, 0.02, '%.2f', 0.5), N('slope_lo', 'Fills below slope (rise / run)', 0, 2, 0.02, '%.2f', 0.2),
                   N('slope_hi', '... nothing above', 0.02, 3, 0.02, '%.2f', 0.6), N('deposit_scale', 'Fill that reads 1 (units)', 0.05, 20, 0.05, '%.2f', 1) },
        eval = function(E, v, ins)
            return Multi(E, 'settle', { a = ins.a, mask = ins.mask, iterations = Iters(E, v.iterations), rate = v.rate, cap = v.cap, slope_lo = v.slope_lo, slope_hi = v.slope_hi, deposit_scale = v.deposit_scale }, { 'deposit' })
        end })

    -- ---- analysis masks -----------------------------------------------------------------------------------------------------------------------------------

    local function Analysis(id, label, kw, desc, params, make)
        Def(id, { label = label, cat = 'analysis', kw = kw, desc = desc, inputs = { In('a', 'height') }, outputs = { Out('out', 'mask') }, params = params,
            eval = function(E, v, ins)
                local p = make(v, E)
                p.a = ins.a
                return One(E:Op(id, p))
            end })
    end

    Analysis('occlusion', 'Cavity / occlusion', 'occlusion cavity ambient exposure concave convex dirt crevice ao', 'Ambient occlusion of the surface: how closed the ground is (pits, gullies, crevices), how exposed (ridges), or both around 0.5.',
        { C('mode', 'Mask', { 'cavity', 'convex', 'both' }, { 'Cavity (concave)', 'Exposure (convex)', 'Both (0.5 = flat)' }, 'cavity'), N('radius', 'Radius (units)', 2, 300, 1, '%d', 40, { wire = true }),
          N('directions', 'Directions', 4, 32, 1, '%d', 12), N('gain', 'Gain', 0.1, 10, 0.1, '%.1f', 2, { wire = true }) },
        function(v) return { mode = v.mode, radius = v.radius, directions = v.directions, gain = v.gain } end)
    Analysis('hillshade', 'Hillshade / lit sides', 'hillshade shade sun light shadow lit side aspect illumination moss snow', 'Sun light on the terrain: the shaded relief, only the sun facing and unshadowed ground (lit), or the cast shadow.',
        { C('mode', 'Mask', { 'shade', 'lit', 'shadow' }, { 'Shaded relief', 'Lit (facing the sun, not shadowed)', 'Cast shadow' }, 'shade'), N('azimuth', 'Towards the sun (degrees, 0 = +x, 90 = +z)', 0, 360, 5, '%d', 315),
          N('altitude', 'Sun height (degrees)', 1, 89, 1, '%d', 40), N('z', 'Vertical exaggeration', 0.1, 10, 0.1, '%.1f', 1), B('shadows', 'Cast shadows in the shade', false), N('shadow_len', 'Shadow length (units)', 5, 800, 5, '%d', 200),
          N('ambient', 'Ambient light', 0, 1, 0.02, '%.2f', 0.15) },
        function(v) return { mode = v.mode, azimuth = v.azimuth, altitude = v.altitude, z = v.z, shadows = v.shadows and 1 or 0, shadow_len = v.shadow_len, ambient = v.ambient } end)
    Analysis('wetness', 'Wetness (topographic)', 'wetness moisture twi topographic wetness index water catchment valley green lush', 'Where water gathers: the topographic wetness index from a multiple flow direction catchment and the slope. Lush ground, river banks, marshes.',
        { C('mode', 'Result', { 'wet', 'twi', 'area' }, { 'Wetness 0..1', 'Raw index', 'Catchment (log)' }, 'wet'), N('p', 'Flow spreading exponent', 0.5, 6, 0.1, '%.1f', 1.1), N('lo', 'Index that reads 0', -5, 20, 0.5, '%.1f', 3),
          N('hi', 'Index that reads 1', -5, 25, 0.5, '%.1f', 11), N('smooth', 'Smooth (units)', 0, 40, 0.5, '%.1f', 2) },
        function(v) return { mode = v.mode, p = v.p, lo = v.lo, hi = v.hi, smooth = v.smooth } end)
    Def('rockiness', { label = 'Rockiness', cat = 'analysis', kw = 'rock rockiness bare exposed outcrop steep convex soil thin', inputs = { In('a', 'height'), In('b', 'height', true) }, outputs = { Out('out', 'mask') },
        desc = 'Where bare rock shows: steep ground, convex ridges and (when a soil thickness is wired into b) thin soil, with some noise breakup.',
        params = { SEED, N('slope_lo', 'Rock from slope (degrees)', 0, 90, 1, '%d', 25), N('slope_hi', '... all rock at', 1, 90, 1, '%d', 50), N('radius', 'Convexity radius (units)', 1, 60, 1, '%d', 6), N('gain', 'Convexity gain', 1, 100, 1, '%d', 14),
                   N('w_slope', 'Weight: slope', 0, 2, 0.05, '%.2f', 1), N('w_convex', 'Weight: convexity', 0, 2, 0.05, '%.2f', 0.5), N('w_soil', 'Weight: thin soil', 0, 2, 0.05, '%.2f', 1),
                   N('soil_full', 'Soil that hides the rock (units)', 0.05, 10, 0.05, '%.2f', 1.5), N('breakup', 'Noise breakup', 0, 0.6, 0.01, '%.2f', 0.15) },
        eval = function(E, v, ins)
            return One(E:Op('rockiness', { a = ins.a, b = ins.b, seed = E:Seed(v.seed), slope_lo = v.slope_lo, slope_hi = v.slope_hi, radius = v.radius, gain = v.gain, w_slope = v.w_slope, w_convex = v.w_convex,
                                           w_soil = v.w_soil, soil_full = v.soil_full, breakup = v.breakup }))
        end })

    -- ---- numbers --------------------------------------------------------------------------------------------------------------------------------------

    Def('map_share', { label = 'Map share (units)', cat = 'numbers', kw = 'map size share fraction scale units width portable independent length',
        desc = 'A length as a share of the map width, in units: wire it into noise sizes, radii and widths so that a graph looks the same on a 256, 512 or 1024 map.',
        outputs = { Out('out', 'number') }, params = { N('share', 'Share of the map width', 0.002, 2, 0.001, '%.3f', 0.1) },
        eval = function(E, v, ins) return One(v.share * E.W) end })

    -- ---- colour -------------------------------------------------------------------------------------------------------------------------------------------

    local RAMPS = {
        terrain = { { 0, 0.06, 0.18, 0.4 }, { 0.2, 0.2, 0.45, 0.65 }, { 0.3, 0.76, 0.7, 0.5 }, { 0.4, 0.3, 0.55, 0.2 }, { 0.65, 0.5, 0.4, 0.25 }, { 0.85, 0.7, 0.68, 0.65 }, { 1, 1, 1, 1 } },
        heat = { { 0, 0, 0, 0 }, { 0.25, 0.5, 0, 0.1 }, { 0.5, 0.9, 0.3, 0 }, { 0.75, 1, 0.85, 0.1 }, { 1, 1, 1, 0.9 } },
        ocean = { { 0, 0.02, 0.05, 0.2 }, { 0.5, 0.1, 0.4, 0.6 }, { 0.85, 0.5, 0.85, 0.9 }, { 1, 1, 1, 1 } },
        snow = { { 0, 0.25, 0.28, 0.33 }, { 0.5, 0.6, 0.65, 0.72 }, { 1, 1, 1, 1 } },
        viridis = { { 0, 0.27, 0, 0.33 }, { 0.25, 0.23, 0.32, 0.55 }, { 0.5, 0.13, 0.57, 0.55 }, { 0.75, 0.37, 0.79, 0.38 }, { 1, 0.99, 0.91, 0.14 } },
        grey = { { 0, 0, 0, 0 }, { 1, 1, 1, 1 } },
        lush = { { 0, 0.55, 0.45, 0.3 }, { 0.35, 0.45, 0.55, 0.25 }, { 0.65, 0.2, 0.5, 0.15 }, { 1, 0.08, 0.3, 0.12 } },
    }
    local RAMP_IDS = { 'terrain', 'heat', 'ocean', 'snow', 'viridis', 'grey', 'lush', 'custom' }
    local RAMP_LABELS = { 'Terrain', 'Heat', 'Ocean depth', 'Snow and rock', 'Viridis', 'Grey', 'Lush ground', 'Custom stops' }

    --- The flat stop list (position, r, g, b, a per stop) of a ramp id, or of the custom text `pos:#rrggbb;pos:#rrggbb` (an optional :aa alpha byte after the colour).
    function RampStops(id, custom, reverse, alpha)
        local stops = {}
        if id ~= 'custom' and RAMPS[id] then
            for _, s in RAMPS[id] do table.insert(stops, { s[1], s[2], s[3], s[4], alpha }) end
        else
            for item in string.gfind(custom or '', '[^;]+') do
                local pos, hex = nil, nil
                local colon = string.find(item, ':', 1, true)
                if colon then
                    pos = tonumber(string.sub(item, 1, colon - 1))
                    hex = string.gsub(string.sub(item, colon + 1), '#', '')
                end
                if pos and hex and string.len(hex) >= 6 then
                    local function Byte(i) return (tonumber(string.sub(hex, i, i + 1), 16) or 0) / 255 end
                    local a = string.len(hex) >= 8 and Byte(7) or alpha
                    table.insert(stops, { pos, Byte(1), Byte(3), Byte(5), a })
                end
            end
            if table.getn(stops) < 2 then error('the custom ramp needs two stops like 0:#103060;1:#ffffff') end
        end
        if reverse then
            local r = {}
            for i = table.getn(stops), 1, -1 do
                local s = stops[i]
                table.insert(r, { 1 - s[1], s[2], s[3], s[4], s[5] })
            end
            stops = r
        end
        local flat = {}
        for _, s in stops do
            for i = 1, 5 do table.insert(flat, s[i]) end
        end
        return flat
    end

    Def('color_ramp', { label = 'Colour ramp', cat = 'color', kw = 'color colour ramp gradient map lut palette texture preview rgba',
        desc = 'A gradient map: turns a mask (or heights over lo .. hi) into colours. Output rgba feeds Output: colour image; red, green, blue and alpha are the channels as masks. The node thumbnail shows the colours.',
        inputs = { In('a', 'height') },
        outputs = { Out('rgba', 'color'), Out('red', 'mask'), Out('green', 'mask'), Out('blue', 'mask'), Out('alpha', 'mask') },
        params = { C('ramp', 'Ramp', RAMP_IDS, RAMP_LABELS, 'terrain'), T('stops', 'Custom stops (pos:#rrggbb;...)', '0:#103060;0.5:#80a060;1:#ffffff'), B('reverse', 'Reverse', false),
                   N('lo', 'Input that reads 0', -300, 900, 0.5, '%.1f', 0, { wire = true }), N('hi', 'Input that reads 1', -300, 900, 0.5, '%.1f', 1, { wire = true }),
                   C('interp', 'Between stops', { 'linear', 'smooth', 'step' }, { 'Linear', 'Smooth', 'Steps' }, 'linear'), N('alpha', 'Alpha', 0, 1, 0.05, '%.2f', 1) },
        eval = function(E, v, ins)
            local main, extra = Kit.Fields.OpMulti('color_ramp', { a = ins.a, stops = RampStops(v.ramp, v.stops, v.reverse, v.alpha), lo = v.lo, hi = v.hi, interp = v.interp })
            if not main then error(tostring(extra)) end
            E:Add(main)
            for k, f in extra do E:Add(f) end
            return { rgba = { r = main, g = extra.g, b = extra.b, a = extra.a }, red = main, green = extra.g, blue = extra.b, alpha = extra.a }
        end })

    Def('out_colormap', { label = 'Output: colour image', cat = 'outputs', kw = 'output colour color image texture map preview minimap dds write export',
        desc = 'Writes the colours into a DXT5 DDS file (a texture for a decal or an album cover) and optionally into the map\'s preview image. Runs on Build only.',
        inputs = { In('rgba', 'color') }, outputs = { Out('view', 'color', true) }, output = 'colormap',
        params = { T('path', 'File (folder under the editor, .dds)', 'graphs/colormap.dds'), N('size', 'Size (pixels, square)', 32, 2048, 32, '%d', 512) },
        eval = function(E, v, ins) return { view = ins.rgba } end })
end
