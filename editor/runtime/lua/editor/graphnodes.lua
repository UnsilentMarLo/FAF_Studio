-- Node catalogue of the terrain graph (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5). One entry per node type: its ports, its parameters (the inspector builds its sliders from them) and
-- `eval`, which turns the input fields into output fields with the native field engine (fields.lua). graph.lua is the model, graphrun.lua the evaluator.
--
--   Defs[id] = { label, cat, desc, kw (search words), inputs = { { name, type, opt } }, outputs = { { name, type, hidden } }, params = { ... }, presets = { { id, label, values } }, eval }
--   Cats, Order            palette categories and the order of the nodes in them
--   Inputs(id) / Outputs(id) / InputPort(id, name) / OutputPort(id, name)     the ports; a number parameter with `wire = true` also has an input port of its name (type number)
--   DefaultParams(id)      a fresh table of default values
--   Describe(node)         a short text for the canvas
--
-- Port types: height and mask are both fields (they connect freely; the colour tells what the node means), points (a path), number (a single value that overrides the parameter of that name).
-- eval(E, v, ins) -> { port = value }: E is the evaluation environment of graphrun.lua (E:Op, E:Const, E:Base, E:Seed, E:Units, E.like, E.step ...), v the parameter values (number wires applied),
-- ins the input values by port name. Fields made with E:Op are owned by the cache entry when returned, freed otherwise. Parameter kinds: number (slider), choice, bool, text, curve, props.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

local Fields = import('/lua/editor/fields.lua')

Defs = {}
Order = {}
Cats = {
    { id = 'sources', label = 'Sources' },
    { id = 'gen', label = 'Generators' },
    { id = 'shape', label = 'Shape' },
    { id = 'combine', label = 'Combine' },
    { id = 'erosion', label = 'Erosion' },
    { id = 'analysis', label = 'Analysis and masks' },
    { id = 'paths', label = 'Paths' },
    { id = 'sc', label = 'SC terrain (pads, symmetry, pathing)' },
    { id = 'color', label = 'Colour' },
    { id = 'numbers', label = 'Numbers' },
    { id = 'outputs', label = 'Outputs' },
    { id = 'organise', label = 'Organise' },
    { id = 'raw', label = 'Engine ops (generic)' },
}

-- ---- parameter constructors -------------------------------------------------------------------------------------------------------------------------

local function N(key, label, min, max, step, fmt, default, flags)
    local p = { kind = 'number', key = key, label = label, min = min, max = max, step = step, fmt = fmt, default = default }
    if flags then for k, v in flags do p[k] = v end end
    return p
end

local function C(key, label, ids, labels, default, tip)
    return { kind = 'choice', key = key, label = label, ids = ids, labels = labels or ids, default = default or ids[1], tip = tip }
end

local function B(key, label, default) return { kind = 'bool', key = key, label = label, default = default and true or false } end
local function T(key, label, default) return { kind = 'text', key = key, label = label, default = default or '' } end

local SEED = N('seed', 'Seed', 0, 9999, 1, '%d', 1, { seed = true })

local function NoiseParams(size)
    return { SEED, N('scale', 'Feature size (units)', 4, 800, 2, '%d', size or 120, { wire = true }), N('octaves', 'Octaves', 1, 10, 1, '%d', 5),
             N('persistence', 'Persistence', 0.2, 0.9, 0.05, '%.2f', 0.5) }
end

local function In(name, type, opt) return { name = name, type = type or 'height', opt = opt and true or false } end
local function Out(name, type, hidden) return { name = name, type = type or 'height', hidden = hidden } end

local function Def(id, d)
    d.id = id
    d.inputs = d.inputs or {}
    d.outputs = d.outputs or { Out('out', 'height') }
    d.params = d.params or {}
    if not Defs[id] then table.insert(Order, id) end
    Defs[id] = d
    -- the port lists: declared inputs, then a number port for every wirable parameter
    d.ports = {}
    for _, p in d.inputs do table.insert(d.ports, p) end
    for _, p in d.params do
        if p.kind == 'number' and p.wire then table.insert(d.ports, { name = p.key, type = 'number', opt = true, param = true, label = p.label }) end
    end
end

function Inputs(id)
    local d = Defs[id]
    return d and d.ports or {}
end

function Outputs(id)
    local d = Defs[id]
    return d and d.outputs or {}
end

function InputPort(id, name)
    for _, p in Inputs(id) do
        if p.name == name then return p end
    end
    return nil
end

function OutputPort(id, name)
    for _, p in Outputs(id) do
        if p.name == name then return p end
    end
    return nil
end

local function CopyValue(v)
    if type(v) ~= 'table' then return v end
    local c = {}
    for k, x in v do c[k] = CopyValue(x) end
    return c
end

function DefaultParams(id)
    local params = {}
    local d = Defs[id]
    if d then
        for _, p in d.params do params[p.key] = CopyValue(p.default) end
    end
    return params
end

function ParamInfo(id, key)
    local d = Defs[id]
    if not d then return nil end
    for _, p in d.params do
        if p.key == key then return p end
    end
    return nil
end

function Describe(node)
    local d = Defs[node.type]
    if not d then return tostring(node.type) end
    if d.describe then
        local ok, text = pcall(d.describe, node)
        if ok and text then return text end
    end
    local parts = {}
    for _, p in d.params do
        if table.getn(parts) < 2 and (p.kind == 'number' or p.kind == 'choice') and not p.seed then
            local v = node.params[p.key]
            if v == nil then v = p.default end
            if p.kind == 'number' then
                table.insert(parts, p.key .. ' ' .. string.format(p.fmt, v))
            else
                for i, id in p.ids do
                    if id == v then table.insert(parts, p.labels[i]) end
                end
            end
        end
    end
    return table.concat(parts, '  ')
end

-- ---- helpers for the evals --------------------------------------------------------------------------------------------------------------------------

local function One(f) return { out = f } end

--- Rescales a raw noise range to 0..1 (fixed constants: the preview and the full run must agree, so no min / max of the field).
local function Fit(E, f, lo, hi)
    return E:Op('clamp', { a = E:Op('affine', { a = f, mul = 1 / (hi - lo), add = -lo / (hi - lo) }), lo = 0, hi = 1 })
end

local function Noise(op, lo, hi)
    return function(E, v, ins)
        local f = E:Op(op, { like = E.like, seed = E:Seed(v.seed), scale = v.scale, octaves = v.octaves, persistence = v.persistence, rotate = 1 })       -- rotate: every octave in its own frame, no lattice seams (EdFieldCore.h OctaveFrame)
        return One(Fit(E, f, lo, hi))
    end
end

local function Flat(list)
    local out = {}
    for _, p in list do
        table.insert(out, p[1])
        table.insert(out, p[2])
    end
    return out
end

-- ---- sources ----------------------------------------------------------------------------------------------------------------------------------------

Def('terrain', { label = 'Map heights', cat = 'sources', kw = 'terrain heights map input current',
    desc = 'The heights of the map as they were before the graph was run (a repeated Build starts from the same ground).',
    eval = function(E, v, ins) return One(E:Base()) end })

Def('stratum', { label = 'Texture layer', cat = 'sources', kw = 'stratum paint mask layer texture',
    desc = 'What a texture layer (1..8) covers now, as a mask.', outputs = { Out('out', 'mask') },
    params = { N('layer', 'Layer', 1, 8, 1, '%d', 1) },
    eval = function(E, v, ins)
        local m = E:Stratum(math.floor(v.layer + 0.5))
        return One(E:Op('resample', { a = m, like = E.like }))
    end })

Def('image', { label = 'Image (PNG16)', cat = 'sources', kw = 'image import png heightmap file raw',
    desc = 'A 16 bit grey image, stretched over the map; 0..1 becomes low..high.',
    params = { T('path', 'File (full path)', ''), N('lo', 'Value at black', -200, 600, 1, '%d', 0), N('hi', 'Value at white', -200, 600, 1, '%d', 100) },
    eval = function(E, v, ins)
        if v.path == '' then error('no file chosen') end
        local img = E:Add(Fields.Image(v.path))
        local r = E:Op('resample', { a = img, like = E.like })
        return One(E:Op('affine', { a = r, mul = v.hi - v.lo, add = v.lo }))
    end })

Def('const', { label = 'Constant', cat = 'sources', kw = 'constant flat value level',
    desc = 'The same value everywhere.',
    params = { N('value', 'Value', -200, 600, 0.5, '%.1f', 30, { wire = true }) },
    eval = function(E, v, ins) return One(E:Const(v.value)) end })

-- ---- generators -------------------------------------------------------------------------------------------------------------------------------------

Def('perlin', { label = 'Perlin noise', cat = 'gen', kw = 'noise perlin fbm fractal rolling', desc = 'Fractal noise, 0..1. The same world position gives the same value at every resolution.',
    params = NoiseParams(), eval = Noise('perlin', 0.25, 0.75) })
Def('simplex', { label = 'Simplex noise', cat = 'gen', kw = 'noise simplex fbm fractal', desc = 'Fractal simplex noise, 0..1.',
    params = NoiseParams(), eval = Noise('simplex', 0.1, 0.9) })
Def('billow', { label = 'Billow noise', cat = 'gen', kw = 'noise billow rounded hills puffy', desc = 'Rounded hills (absolute value noise), 0..1.',
    params = NoiseParams(), eval = Noise('billow', 0, 0.5) })
Def('ridged', { label = 'Ridged noise', cat = 'gen', kw = 'noise ridged mountains ridge crest',
    desc = 'Sharp mountain ridges, 0..1.',
    params = { SEED, N('scale', 'Feature size (units)', 4, 800, 2, '%d', 150, { wire = true }), N('octaves', 'Octaves', 1, 10, 1, '%d', 5), N('persistence', 'Persistence', 0.2, 0.9, 0.05, '%.2f', 0.5),
               C('basis', 'Basis noise', { 'perlin', 'simplex' }, { 'Perlin', 'Simplex' }, 'perlin') },
    eval = function(E, v, ins)
        local f = E:Op('ridged', { like = E.like, seed = E:Seed(v.seed), scale = v.scale, octaves = v.octaves, persistence = v.persistence, basis = v.basis, rotate = 1 })
        return One(Fit(E, f, 0.25, 1))
    end })

Def('voronoi', { label = 'Voronoi cells', cat = 'gen', kw = 'voronoi cells cracks plates edges patches',
    desc = 'Cell noise: distance to the nearest cell centre, the edges between cells, a random value per cell or cracks.',
    params = { SEED, N('scale', 'Cell size (units)', 4, 600, 2, '%d', 80, { wire = true }), N('jitter', 'Jitter', 0, 1, 0.05, '%.2f', 1),
               C('mode', 'Mode', { 'f1', 'f2', 'edge', 'id', 'crack' }, { 'Distance', 'Second distance', 'Edges', 'Value per cell', 'Cracks' }, 'f1'),
               N('thickness', 'Crack thickness', 0.02, 0.5, 0.01, '%.2f', 0.12) },
    eval = function(E, v, ins)
        local f = E:Op('voronoi', { like = E.like, seed = E:Seed(v.seed), scale = v.scale, jitter = v.jitter, mode = v.mode, thickness = v.thickness })
        if v.mode == 'f1' then return One(Fit(E, f, 0, 0.9)) end
        return One(f)
    end })

Def('gradient', { label = 'Gradient', cat = 'gen', kw = 'gradient ramp linear slope tilt',
    desc = 'A linear ramp across the map in a direction.',
    params = { N('angle', 'Direction (degrees)', 0, 360, 5, '%d', 0), N('lo', 'Start value', -1, 2, 0.05, '%.2f', 0), N('hi', 'End value', -1, 2, 0.05, '%.2f', 1) },
    eval = function(E, v, ins) return One(E:Op('gradient', { like = E.like, angle = v.angle, lo = v.lo, hi = v.hi })) end })

Def('radial', { label = 'Radial', cat = 'gen', kw = 'radial island circle falloff distance centre',
    desc = 'Distance from a centre: 0 there, 1 at the radius (and beyond). Invert it for an island.',
    params = { N('cx', 'Centre x (share of the map)', 0, 1, 0.01, '%.2f', 0.5), N('cz', 'Centre z (share of the map)', 0, 1, 0.01, '%.2f', 0.5),
               N('radius', 'Radius (units, 0 = half the map)', 0, 6000, 4, '%d', 0, { wire = true }), B('invert', 'Invert (1 in the middle)', false) },
    eval = function(E, v, ins)
        local p = { like = E.like, cx = v.cx * E.W, cz = v.cz * E.H }
        if v.radius > 0 then p.radius = v.radius else p.radius = 0.5 * math.min(E.W, E.H) end
        local f = E:Op('radial', p)
        if v.invert then f = E:Op('affine', { a = f, mul = -1, add = 1 }) end
        return One(f)
    end })

Def('white', { label = 'White noise', cat = 'gen', kw = 'white noise random grain', desc = 'Uncorrelated noise per sample, 0..1.',
    params = { SEED }, eval = function(E, v, ins) return One(E:Op('white', { like = E.like, seed = E:Seed(v.seed) })) end })

-- ---- shape (filters) --------------------------------------------------------------------------------------------------------------------------------

local function Filter(id, label, kw, desc, params, make, extra)
    local d = { label = label, cat = 'shape', kw = kw, desc = desc, inputs = { In('a', 'height') }, params = params,
        eval = function(E, v, ins)
            local p = make and make(v, E) or {}
            p.a = ins.a
            return One(E:Op(id, p))
        end }
    if extra then for k, x in extra do d[k] = x end end
    Def(id, d)
end

Filter('blur', 'Blur', 'blur smooth soften gaussian', 'Gaussian blur.', { N('radius', 'Sigma (units)', 0.5, 120, 0.5, '%.1f', 4, { wire = true }) }, function(v) return { radius = v.radius } end)
Filter('box', 'Box blur', 'box blur average', 'Box blur (square average).', { N('radius', 'Half width (units)', 1, 100, 1, '%d', 4) }, function(v, E) return { radius = v.radius } end)
Filter('clamp', 'Clamp', 'clamp limit cap floor', 'Limits the values to a range.', { N('lo', 'Lowest', -300, 600, 0.05, '%.2f', 0, { wire = true }), N('hi', 'Highest', -300, 600, 0.05, '%.2f', 1, { wire = true }) },
    function(v) return { lo = v.lo, hi = v.hi } end)
Filter('invert', 'Invert', 'invert flip negative', 'Turns low into high inside a range.', { N('lo', 'Low', -300, 600, 0.05, '%.2f', 0), N('hi', 'High', -300, 600, 0.05, '%.2f', 1) },
    function(v) return { lo = v.lo, hi = v.hi } end)
Filter('abs', 'Absolute value', 'abs absolute', 'The absolute value (folds negative values up).', {}, nil)
Filter('gamma', 'Gamma', 'gamma curve power contrast', 'A power curve on 0..1: below 1 lifts the lows, above 1 flattens them.', { N('gamma', 'Gamma', 0.2, 4, 0.05, '%.2f', 1.5, { wire = true }) },
    function(v) return { gamma = v.gamma } end)
Filter('affine', 'Scale and offset', 'scale offset multiply add gain bias', 'value x multiply + add.', { N('mul', 'Multiply', -300, 600, 0.05, '%.2f', 1, { wire = true }), N('add', 'Add', -300, 600, 0.5, '%.1f', 0, { wire = true }) },
    function(v) return { mul = v.mul, add = v.add } end)
Filter('smoothstep', 'Smooth step', 'smoothstep contrast edge range', 'Smooth S curve between two edges: below edge 0 is 0, above edge 1 is 1.',
    { N('edge0', 'Edge 0', -300, 600, 0.02, '%.2f', 0.3, { wire = true }), N('edge1', 'Edge 1', -300, 600, 0.02, '%.2f', 0.7, { wire = true }) },
    function(v) return { edge0 = v.edge0, edge1 = v.edge1 } end)
Filter('threshold', 'Threshold', 'threshold binary cut mask', 'Hard cut: 1 above the value, 0 below.', { N('value', 'Threshold', -300, 600, 0.02, '%.2f', 0.5, { wire = true }) },
    function(v) return { value = v.value } end, { outputs = { Out('out', 'mask') } })
Filter('normalize', 'Normalize', 'normalize stretch range fit', 'Stretches the lowest and highest value of the field to a range (preview and full run may differ slightly).',
    { N('lo', 'Lowest', -300, 600, 0.5, '%.1f', 0), N('hi', 'Highest', -300, 600, 0.5, '%.1f', 1) }, function(v) return { lo = v.lo, hi = v.hi } end)
Filter('quantize', 'Quantize', 'quantize step round snap words', 'Rounds values to steps. 0.0078 (1/128) is the map\'s own height step.', { N('step', 'Step', 0.0078125, 20, 0.0078125, '%.4f', 1) },
    function(v) return { step = v.step } end)
Filter('levels', 'Levels', 'levels contrast input output', 'Input range, gamma and output range, like Photoshop levels.',
    { N('in_lo', 'In low', -300, 600, 0.02, '%.2f', 0.2), N('in_hi', 'In high', -300, 600, 0.02, '%.2f', 0.8), N('gamma', 'Gamma', 0.2, 4, 0.05, '%.2f', 1),
      N('out_lo', 'Out low', -300, 600, 0.02, '%.2f', 0), N('out_hi', 'Out high', -300, 600, 0.02, '%.2f', 1) },
    function(v) return { in_lo = v.in_lo, in_hi = v.in_hi, gamma = v.gamma, out_lo = v.out_lo, out_hi = v.out_hi } end)
Filter('terrace', 'Terrace', 'terrace steps plateau stairs mesa', 'Steps the values: flat shelves with steep risers.',
    { N('steps', 'Steps', 1, 40, 1, '%d', 6), N('sharpness', 'Sharpness', 0, 1, 0.05, '%.2f', 0.7), N('lo', 'Low', -300, 600, 0.5, '%.1f', 0), N('hi', 'High', -300, 600, 0.5, '%.1f', 1) },
    function(v) return { steps = v.steps, sharpness = v.sharpness, lo = v.lo, hi = v.hi } end)
Filter('offset', 'Offset', 'offset move shift translate wrap', 'Moves the field (units).', { N('move_x', 'Move x (units)', -4000, 4000, 1, '%d', 50), N('move_z', 'Move z (units)', -4000, 4000, 1, '%d', 0) },
    function(v) return { move_x = v.move_x, move_z = v.move_z } end)
Filter('rotate', 'Rotate', 'rotate turn angle', 'Turns the field around the middle.', { N('angle', 'Angle (degrees)', -180, 180, 1, '%d', 30) },
    function(v) return { angle = v.angle } end)
Filter('scale', 'Zoom', 'scale zoom stretch magnify', 'Zooms the field around the middle.', { N('factor', 'Zoom', 0.25, 4, 0.05, '%.2f', 1.5) },
    function(v) return { factor = v.factor } end)
Filter('mirror', 'Mirror / symmetry', 'mirror symmetry rot4 rot2 diagonal fold', 'Makes the field symmetric by copying one half or quarter over the rest (exact copies, for competitive maps).',
    { C('mode', 'Mode', { 'x', 'z', 'xz', 'rot2', 'rot4', 'diag', 'adiag' }, { 'Mirror across x', 'Mirror across z', 'Four-fold mirror', 'Two-fold rotation', 'Four-fold rotation', 'Diagonal', 'Anti-diagonal' }, 'x'),
      N('side', 'Source side (0 or 1)', 0, 1, 1, '%d', 0) },
    function(v) return { mode = v.mode, side = v.side } end)

Def('range', { label = 'To height range', cat = 'shape', kw = 'range height units scale amplitude',
    desc = 'Maps 0..1 to a range of heights in world units (a fixed rule, not the min / max of the field).',
    inputs = { In('a', 'height') },
    params = { N('lo', 'Value at 0', -200, 600, 0.5, '%.1f', 20, { wire = true }), N('hi', 'Value at 1', -200, 600, 0.5, '%.1f', 70, { wire = true }) },
    eval = function(E, v, ins) return One(E:Op('affine', { a = ins.a, mul = v.hi - v.lo, add = v.lo })) end })

Def('remap', { label = 'Curve (remap)', cat = 'shape', kw = 'remap curve spline contour photoshop',
    desc = 'Maps 0..1 through a curve you draw (monotone, like the Photoshop curves dialog).',
    inputs = { In('a', 'height') },
    params = { { kind = 'curve', key = 'points', label = 'Curve', default = { { 0, 0 }, { 0.5, 0.5 }, { 1, 1 } } }, B('smooth', 'Smooth curve', true) },
    eval = function(E, v, ins) return One(E:Op('remap', { a = ins.a, points = Flat(v.points), smooth = v.smooth and 1 or 0 })) end })

Def('warp', { label = 'Warp', cat = 'shape', kw = 'warp distort displace turbulence domain',
    desc = 'Bends the field by noise (or by two fields you wire in).',
    inputs = { In('a', 'height'), In('dx', 'height', true), In('dz', 'height', true) },
    params = { N('strength', 'Strength (units)', 0, 400, 1, '%d', 30, { wire = true }), N('size', 'Noise size (units)', 5, 600, 5, '%d', 80), SEED },
    eval = function(E, v, ins)
        local dx, dz = ins.dx, ins.dz
        local seed = E:Seed(v.seed)
        if not dx then dx = E:Op('perlin', { like = E.like, seed = seed, scale = v.size, octaves = 3 }) end
        if not dz then dz = E:Op('perlin', { like = E.like, seed = seed + 1, scale = v.size, octaves = 3 }) end
        return One(E:Op('warp', { a = ins.a, dx = dx, dz = dz, strength = v.strength }))
    end })

-- ---- combine ----------------------------------------------------------------------------------------------------------------------------------------

local function Binary(id, label, kw, desc)
    Def(id, { label = label, cat = 'combine', kw = kw, desc = desc, inputs = { In('a', 'height'), In('b', 'height', true) },
        params = { N('value', 'Value (when b is not wired)', -300, 600, 0.05, '%.2f', 0, { wire = true }) },
        eval = function(E, v, ins)
            local b = ins.b or E:Const(v.value)
            return One(E:Op(id, { a = ins.a, b = b }))
        end })
end
Binary('add', 'Add', 'add sum plus combine', 'a + b (or a + a value).')
Binary('sub', 'Subtract', 'subtract minus difference', 'a - b (or a - a value).')
Binary('mul', 'Multiply', 'multiply times mask product', 'a x b (or a x a value). Multiplying by a mask limits an effect to the mask.')
Binary('min', 'Minimum', 'min minimum smaller and intersect', 'The smaller of a and b.')
Binary('max', 'Maximum', 'max maximum larger union or', 'The larger of a and b.')

Def('blend', { label = 'Blend', cat = 'combine', kw = 'blend mix overlay screen mask opacity layer',
    desc = 'Mixes b over a with a blend mode, an opacity and an optional mask.',
    inputs = { In('a', 'height'), In('b', 'height'), In('mask', 'mask', true) },
    params = { C('mode', 'Mode', { 'normal', 'add', 'sub', 'mul', 'screen', 'overlay', 'min', 'max', 'diff' }, { 'Normal', 'Add', 'Subtract', 'Multiply', 'Screen', 'Overlay', 'Minimum', 'Maximum', 'Difference' }, 'normal'),
               N('opacity', 'Opacity', 0, 1, 0.05, '%.2f', 0.5, { wire = true }) },
    eval = function(E, v, ins)
        return One(E:Op('blend', { a = ins.a, b = ins.b, mask = ins.mask, mode = v.mode, opacity = v.opacity }))
    end })

-- ---- erosion ----------------------------------------------------------------------------------------------------------------------------------------

local function ThermalIterations(E, n)
    if E.step > 1 then return math.max(1, math.floor(n / E.step + 0.5)) end
    return n
end

Def('thermal', { label = 'Thermal erosion', cat = 'erosion', kw = 'thermal talus slump scree erosion slide',
    desc = 'Material slides down slopes steeper than the talus angle (rise / run).',
    inputs = { In('a', 'height'), In('mask', 'mask', true) },
    params = { N('iterations', 'Iterations', 1, 400, 1, '%d', 30), N('talus', 'Talus (rise / run)', 0.05, 2, 0.05, '%.2f', 0.6, { wire = true }), N('rate', 'Rate', 0.05, 1, 0.05, '%.2f', 0.5) },
    eval = function(E, v, ins)
        return One(E:Op('thermal', { a = ins.a, mask = ins.mask, iterations = ThermalIterations(E, v.iterations), talus = v.talus, rate = v.rate }))
    end })

local function ErodeNode(solver, label, kw, desc, presetsOf)
    local Erosion = import('/lua/editor/erosion.lua')
    local def = Erosion.Solvers[solver]
    local params = {}
    for _, p in def.params do
        local c = N(p.key, p.label, p.min, p.max, p.step, p.fmt, p.default)
        if p.key == 'seed' then c.seed = true end
        c.tip = p.tip
        table.insert(params, c)
    end
    local presets = {}
    for _, pr in Erosion.Presets do
        if pr.solver == solver then
            local values = {}
            for _, p in def.params do      -- (a preset is complete: the settings it does not name go back to the defaults, except the seed)
                if p.key ~= 'seed' then values[p.key] = p.default end
            end
            for k, x in pr.values do values[k] = x end
            table.insert(presets, { id = pr.id, label = pr.label, values = values })
        end
    end
    Def('erode_' .. solver, { label = label, cat = 'erosion', kw = kw, desc = desc, presets = presets,
        inputs = { In('a', 'height'), In('mask', 'mask', true) },
        outputs = { Out('out', 'height'), Out('wear', 'mask'), Out('deposit', 'mask'), Out('flow', 'mask'), Out('accum', 'mask') },
        params = params,
        eval = function(E, v, ins)
            local values = {}
            for _, p in def.params do values[p.key] = v[p.key] end
            local p = Erosion.OpParams(solver, values, E.step, E:Seed(v.seed))
            p.a = ins.a
            if ins.mask then p.mask = ins.mask end
            local wantMasks = E.wanted.wear or E.wanted.deposit or E.wanted.flow or E.wanted.accum
            if not wantMasks then p.masks = 0 end
            local main, extra = ed_field_op_multi(def.op, p)
            if not main then error(tostring(extra)) end
            E:Add(main)
            local out = { out = main }
            local raw = {}
            for k, f in extra do
                E:Add(f)
                raw[k] = f
            end
            if wantMasks and raw.wear and raw.deposit and raw.flow and raw.accum then
                local made = Erosion.Masks(raw)
                for k, f in made do
                    E:Add(f)
                    out[k] = f
                end
            end
            return out
        end })
end

ErodeNode('hydraulic', 'Hydraulic erosion', 'hydraulic water rain erosion pipe river grid weathering', 'Water flows over the ground, dissolves and drops sediment (grid solver). Outputs the eroded height and the wear, deposit, flow and drainage masks. Runs on the graphics card when there is one, with an improved solver (CPU only = 1 forces the CPU solver).')
ErodeNode('droplet', 'Droplet erosion', 'droplet particle erosion mountain gullies ridges', 'Particle erosion: droplets run downhill and carve gullies and sharp ridges. The first choice for mountains. Runs on the graphics card when there is one (CPU only = 1 forces the CPU solver).')
ErodeNode('stream', 'Stream power (rivers)', 'stream power river valley incision canyon drainage', 'Cuts a drainage network of river valleys (stream power law). Drains all closed basins.')

-- ---- analysis and masks -----------------------------------------------------------------------------------------------------------------------------

Def('slope', { label = 'Slope', cat = 'analysis', kw = 'slope angle steep gradient degrees rating',
    desc = 'Steepness of the ground: degrees, gradient (rise / run), the engine\'s unit footprint rating (0.75 blocks land units) or the structure variation.',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'height') },
    params = { C('mode', 'Output', { 'degrees', 'gradient', 'rating', 'variation' }, { 'Degrees', 'Gradient (rise / run)', 'Unit footprint rating', 'Structure variation' }, 'degrees'),
               N('window', 'Footprint (units, rating / variation)', 1, 12, 1, '%d', 1) },
    eval = function(E, v, ins)
        local p = { a = ins.a, mode = v.mode }
        if v.mode == 'degrees' or v.mode == 'gradient' then p.radius = 1 else p.window = E:Units(v.window) end
        return One(E:Op('slope', p))
    end })

Def('range_mask', { label = 'Range mask', cat = 'analysis', kw = 'range band height mask select soft edge',
    desc = 'A mask 1 between two values with soft edges: heights in a band, slopes in an angle range, anything.',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'mask') },
    params = { N('lo', 'From', -300, 900, 0.5, '%.1f', 20, { wire = true }), N('hi', 'To', -300, 900, 0.5, '%.1f', 40, { wire = true }), N('soft', 'Soft edge', 0, 200, 0.5, '%.1f', 6) },
    eval = function(E, v, ins) return One(E:Op('height_band', { a = ins.a, lo = v.lo, hi = v.hi, soft = v.soft })) end })

Def('curvature', { label = 'Curvature', cat = 'analysis', kw = 'curvature convex concave ridge gully cavity',
    desc = 'Convex ground (ridges) towards 1, concave (gullies) towards 0, flat 0.5.',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'mask') },
    params = { N('radius', 'Radius (units)', 1, 60, 1, '%d', 6), N('gain', 'Gain', 1, 300, 1, '%d', 25) },
    eval = function(E, v, ins) return One(E:Op('curvature', { a = ins.a, radius = E:Units(v.radius), gain = v.gain })) end })

Def('aspect', { label = 'Aspect (facing)', cat = 'analysis', kw = 'aspect facing sun direction shade orientation',
    desc = 'How much the ground faces a direction (0.5 across, 1 straight at it): sun-facing slopes.',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'mask') },
    params = { N('azimuth', 'Facing (degrees, 0 = +x, 90 = +z)', 0, 360, 5, '%d', 225), N('flat', 'Level below (rise / run)', 0.005, 1, 0.005, '%.3f', 0.05) },
    eval = function(E, v, ins) return One(E:Op('aspect', { a = ins.a, azimuth = v.azimuth, flat = v.flat, radius = 1 })) end })

Def('flow', { label = 'Flow (drainage)', cat = 'analysis', kw = 'flow drainage catchment river accumulation watershed',
    desc = 'Where water collects: log of the drainage area, 0..1.',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'mask') },
    params = { N('range', 'Catchment that reads 1 (x1000 units squared)', 1, 100000, 10, '%d', 1000), C('mode', 'Scale', { 'log', 'area', 'cells' }, { 'Logarithmic', 'Area', 'Cells' }, 'log') },
    eval = function(E, v, ins) return One(E:Op('flow', { a = ins.a, mode = v.mode, range = v.range * 1000 })) end })

local function WaterNode(id, label, kw, desc, extraParams, make)
    local params = { N('offset', 'Level above the water surface (units)', -100, 300, 0.5, '%.1f', 0, { wire = true }) }
    for _, p in extraParams do table.insert(params, p) end
    Def(id, { label = label, cat = 'analysis', kw = kw, desc = desc, inputs = { In('a', 'height') }, outputs = { Out('out', id == 'water_depth' and 'height' or 'mask') }, params = params,
        eval = function(E, v, ins)
            local p = make(v)
            p.a = ins.a
            p.level = E.water + v.offset
            return One(E:Op(id, p))
        end })
end
WaterNode('water_above', 'Land above water', 'water above land dry shore', 'Mask of ground above the map\'s water surface (plus an offset).',
    { N('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 2) }, function(v) return { soft = v.soft } end)
WaterNode('water_below', 'Under water', 'water below sea lake underwater wet', 'Mask of ground under the water surface (plus an offset).',
    { N('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 2) }, function(v) return { soft = v.soft } end)
WaterNode('water_depth', 'Water depth', 'water depth depth below surface', 'Depth under the water surface in units (0 on land).',
    {}, function(v) return {} end)
WaterNode('shore', 'Shore band', 'shore beach coast band shoreline', 'A band around the waterline.',
    { N('width', 'Half width (units)', 0, 50, 0.5, '%.1f', 3), N('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 2) }, function(v) return { width = v.width, soft = v.soft } end)

Def('distance', { label = 'Distance field', cat = 'analysis', kw = 'distance field euclidean grow shrink expand outline',
    desc = 'Distance (units) to the nearest value above a threshold. Outside, inside or signed; the range makes it a 0..1 falloff.',
    inputs = { In('a', 'height') },
    params = { N('threshold', 'Threshold', -300, 900, 0.05, '%.2f', 0.5, { wire = true }), C('mode', 'Measure', { 'outside', 'inside', 'signed' }, { 'Outside the shape', 'Inside the shape', 'Signed' }, 'outside'),
               N('range', 'Range (units, 0 = raw distance)', 0, 2000, 1, '%d', 0) },
    eval = function(E, v, ins) return One(E:Op('distance', { a = ins.a, threshold = v.threshold, mode = v.mode, range = v.range })) end })

Def('grow', { label = 'Grow / shrink mask', cat = 'analysis', kw = 'grow shrink expand erode dilate morphology open close mask',
    desc = 'Grows or shrinks a mask by a distance (exact Euclidean), with a soft edge.',
    inputs = { In('a', 'mask') }, outputs = { Out('out', 'mask') },
    params = { C('mode', 'Mode', { 'grow', 'shrink', 'open', 'close' }, { 'Grow', 'Shrink', 'Remove specks', 'Fill holes' }, 'grow'),
               N('distance', 'Distance (units)', 0.5, 200, 0.5, '%.1f', 6, { wire = true }), N('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 2) },
    eval = function(E, v, ins)
        local function Grow(m, d, soft)
            local dist = E:Op('distance', { a = m, threshold = 0.5, mode = 'outside' })
            return E:Op('max', { a = m, b = E:Op('water_below', { a = dist, level = d, soft = soft }) })
        end
        local function Shrink(m, d, soft)
            local dist = E:Op('distance', { a = m, threshold = 0.5, mode = 'inside' })
            return E:Op('min', { a = m, b = E:Op('water_above', { a = dist, level = d, soft = soft }) })
        end
        local m = ins.a
        if v.mode == 'grow' then return One(Grow(m, v.distance, v.soft)) end
        if v.mode == 'shrink' then return One(Shrink(m, v.distance, v.soft)) end
        if v.mode == 'open' then return One(Grow(Shrink(m, v.distance, 0), v.distance, 0)) end
        return One(Shrink(Grow(m, v.distance, 0), v.distance, 0))
    end })

Def('mask_preset', { label = 'Mask preset', cat = 'analysis', kw = 'mask preset cliffs beach snow buildable blocked ridges gullies sunny patches edge rules',
    desc = 'A ready made mask of the Mask generator (cliffs, beach, snow caps, buildable ground, ground land units cannot cross ...) from the heights wired in.',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'mask') },
    params = { C('preset', 'Preset', { 'cliffs', 'blocked', 'buildable', 'beach', 'snow', 'ridges', 'gullies', 'sunny', 'patches', 'edge' },
                 { 'Cliffs (steep ground)', 'Ground land units cannot cross', 'Buildable flat ground', 'Beach', 'Snow caps', 'Ridge tops', 'Gullies and river beds', 'Sun-facing slopes', 'Dirt patches', 'Map edge band' }, 'cliffs') },
    eval = function(E, v, ins)
        local MaskGen = import('/lua/editor/maskgen.lua')
        local def = { rules = {} }
        if not MaskGen.LoadPreset(def, v.preset) then error('unknown preset ' .. tostring(v.preset)) end
        local w, h = Fields.Info(ins.a)
        local hmin, hmax = Fields.Stats(ins.a)
        local c = { S = E, H = ins.a, w = w, h = h, cell = E.cell, step = E.step, hmin = hmin, hmax = hmax, water = E.water, cache = {} }
        local m, err = MaskGen.Evaluate(c, def)
        if not m then error(tostring(err)) end
        return One(m)
    end })

Def('unit_slope', { label = 'Pathable ground', cat = 'analysis', kw = 'pathable passable blocked unit class slope footprint land hover buildable',
    desc = 'The engine\'s own slope rule for a unit class: ground it can cross (or the blocked ground).',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'mask') },
    params = { C('class', 'Unit class', { '1', '2', '3', '4', '5' }, { 'Land, small (1x1)', 'Land, medium (2x2)', 'Land, large (3x3)', 'Experimental (5x5)', 'Structure (ground variation)' }, '1'),
               C('which', 'Mask', { 'passable', 'blocked' }, { 'Passable ground', 'Blocked ground' }, 'passable'), N('soft', 'Soft edge', 0, 1, 0.01, '%.2f', 0.05) },
    eval = function(E, v, ins)
        local MaskGen = import('/lua/editor/maskgen.lua')
        local cls = MaskGen.CLASSES[tonumber(v.class)]
        local r = E:Op('slope', { a = ins.a, mode = cls.kind, window = E:Units(cls.window) })
        local pass = E:Op('water_below', { a = r, level = cls.limit, soft = v.soft })
        if v.which == 'blocked' then return One(E:Op('invert', { a = pass, lo = 0, hi = 1 })) end
        return One(pass)
    end })

Def('basins', { label = 'Closed basins', cat = 'analysis', kw = 'basin lake depression pit fill closed',
    desc = 'Depth of closed depressions (where water would pool): a lake mask when thresholded.',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'height') },
    eval = function(E, v, ins) return One(E:Op('basin_depth', { a = ins.a })) end })

Def('slope_area', { label = 'Slope-area statistic', cat = 'analysis', kw = 'slope area statistic concavity quality',
    desc = 'Slope binned by drainage area (a terrain quality statistic, mostly for tuning erosion).',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'height') },
    params = { N('bins', 'Bins', 2, 16, 1, '%d', 10), N('first', 'First bin (log2 cells)', 1, 8, 1, '%d', 4) },
    eval = function(E, v, ins) return One(E:Op('slope_area', { a = ins.a, bins = v.bins, first = v.first })) end })

-- ---- paths ------------------------------------------------------------------------------------------------------------------------------------------

--- A path model (paths.lua) from control points { x, z } in map units, with width / falloff / height settings for all points.
local function PathModel(points, v, closed)
    local Paths = import('/lua/editor/paths.lua')
    local mode = v.mode or 'carve'
    local preset = nil
    for _, p in Paths.Presets do
        if p.id == (v.profile or Paths.Modes[mode].preset) then preset = p end
    end
    if not preset then preset = Paths.Presets[1] end
    local pts = {}
    for _, q in points do
        table.insert(pts, { x = q[1], z = q[2], w = v.width or 6, f = v.falloff or 4, h = v.height or 0, bank = 0 })
    end
    local prof = {}
    for _, q in preset.points do table.insert(prof, { q[1], q[2] }) end
    return { kind = 'catmull', mode = mode, closed = closed and true or false, strength = 1, tension = 1, grade = 0.75, erosion = 0, strata = {}, points = pts,
             profile = { points = prof, smooth = preset.smooth, symmetric = true } }
end

local function Wobble(E, v, x0, z0, x1, z1, n)
    local pts = {}
    local dx, dz = x1 - x0, z1 - z0
    local len = math.sqrt(dx * dx + dz * dz)
    local nx, nz = -dz / math.max(len, 1e-6), dx / math.max(len, 1e-6)
    local seed = E:Seed(v.seed)
    for i = 0, n do
        local t = i / n
        local amp = 0
        if i > 0 and i < n then
            -- a hash of (seed, i): deterministic and identical at every resolution
            local h = math.mod(math.sin(seed * 12.9898 + i * 78.233) * 43758.5453, 1)
            if h < 0 then h = h + 1 end
            amp = (h - 0.5) * 2 * v.wobble * len
        end
        table.insert(pts, { x0 + dx * t + nx * amp, z0 + dz * t + nz * amp })
    end
    return pts
end

local PATH_PROFILE = { 'ramp', 'road', 'v', 'u', 'ridge', 'wall', 'terrace' }
local PATH_MODES = { 'carve', 'raise', 'level', 'ramp', 'road', 'river' }

Def('path_line', { label = 'Path: line', cat = 'paths', kw = 'path line river road ridge spline curve wobble',
    desc = 'A curved path from one point to another (shares of the map), with a seeded wobble. Feed it to Path mask or Path shape.',
    outputs = { Out('out', 'points') },
    params = { N('x0', 'Start x', 0, 1, 0.01, '%.2f', 0.1), N('z0', 'Start z', 0, 1, 0.01, '%.2f', 0.1), N('x1', 'End x', 0, 1, 0.01, '%.2f', 0.9), N('z1', 'End z', 0, 1, 0.01, '%.2f', 0.9),
               N('wobble', 'Wobble (share of the length)', 0, 0.5, 0.01, '%.2f', 0.08), N('points', 'Control points', 2, 24, 1, '%d', 7), SEED,
               N('width', 'Half width (units)', 1, 100, 0.5, '%.1f', 8, { wire = true }), N('falloff', 'Falloff (units)', 0, 100, 0.5, '%.1f', 10), N('height', 'Height / depth (units)', -100, 100, 0.5, '%.1f', -3) },
    eval = function(E, v, ins)
        local pts = Wobble(E, v, v.x0 * E.W, v.z0 * E.H, v.x1 * E.W, v.z1 * E.H, math.floor(v.points + 0.5) - 1)
        return { out = PathModel(pts, v, false) }
    end })

Def('path_ring', { label = 'Path: ring', cat = 'paths', kw = 'path ring circle loop closed lake crater',
    desc = 'A closed loop around a centre (shares of the map) with a seeded wobble.',
    outputs = { Out('out', 'points') },
    params = { N('cx', 'Centre x', 0, 1, 0.01, '%.2f', 0.5), N('cz', 'Centre z', 0, 1, 0.01, '%.2f', 0.5), N('radius', 'Radius (share of the map)', 0.02, 0.7, 0.01, '%.2f', 0.3),
               N('wobble', 'Wobble (share of the radius)', 0, 0.5, 0.01, '%.2f', 0.1), N('points', 'Control points', 4, 32, 1, '%d', 10), SEED,
               N('width', 'Half width (units)', 1, 100, 0.5, '%.1f', 8, { wire = true }), N('falloff', 'Falloff (units)', 0, 100, 0.5, '%.1f', 10), N('height', 'Height / depth (units)', -100, 100, 0.5, '%.1f', 3) },
    eval = function(E, v, ins)
        local n = math.floor(v.points + 0.5)
        local seed = E:Seed(v.seed)
        local r0 = v.radius * math.min(E.W, E.H)
        local pts = {}
        for i = 0, n - 1 do
            local a = i / n * 6.2831853
            local h = math.mod(math.sin(seed * 12.9898 + i * 78.233) * 43758.5453, 1)
            if h < 0 then h = h + 1 end
            local r = r0 * (1 + (h - 0.5) * 2 * v.wobble)
            table.insert(pts, { v.cx * E.W + math.cos(a) * r, v.cz * E.H + math.sin(a) * r })
        end
        return { out = PathModel(pts, v, true) }
    end })

Def('path_drawn', { label = 'Path: from the Paths tool', cat = 'paths', kw = 'path drawn tool existing paths spline user',
    desc = 'A path you drew with the Paths tool (number 1 = the first path in the Paths panel).',
    outputs = { Out('out', 'points') },
    params = { N('index', 'Path number', 1, 40, 1, '%d', 1) },
    eval = function(E, v, ins)
        local Paths = import('/lua/editor/paths.lua')
        local p = Paths.List[math.floor(v.index + 0.5)]
        if not p then error('the Paths tool has no path number ' .. math.floor(v.index + 0.5)) end
        return { out = Paths.DeepCopy(p) }
    end })

local function ZeroArgs(Paths, path, S)
    local zeros = {}
    for k = 1, S.n do zeros[k] = 0 end
    local flat = {}
    for k = 1, S.n do
        table.insert(flat, S.x[k]) table.insert(flat, S.z[k]) table.insert(flat, 0)
        table.insert(flat, S.w[k]) table.insert(flat, S.f[k]) table.insert(flat, S.bank[k]) table.insert(flat, 0) table.insert(flat, S.s[k])
    end
    local flatProfile = {}
    for _, q in path.profile.points do
        table.insert(flatProfile, q[1]) table.insert(flatProfile, q[2])
    end
    return { pts = flat, profile = flatProfile, smooth = path.profile.smooth and 1 or 0, symmetric = path.profile.symmetric and 1 or 0 }
end

Def('path_mask', { label = 'Path mask', cat = 'paths', kw = 'path mask corridor river bank road reach core weight',
    desc = 'A mask along a path: the shaping weight, the flat core, the whole reach or just the banks.',
    inputs = { In('pts', 'points') }, outputs = { Out('out', 'mask') },
    params = { C('kind', 'Mask', { 'weight', 'core', 'reach', 'bank' }, { 'Shaping weight (profile)', 'Core (half width)', 'Reach (width and falloff)', 'Banks' }, 'weight'),
               N('soft', 'Soft edge (units)', 0, 50, 0.5, '%.1f', 3) },
    eval = function(E, v, ins)
        local Paths = import('/lua/editor/paths.lua')
        local S = Paths.Sample(ins.pts, 1.0)
        if S.n < 1 then error('the path has no points') end
        local args = ZeroArgs(Paths, ins.pts, S)
        args.like = E.like
        args.kind = v.kind
        args.soft = v.soft
        return One(E:Op('path_mask', args))
    end })

Def('path_dist', { label = 'Path distance', cat = 'paths', kw = 'path distance along signed corridor',
    desc = 'Distance of every point to a path (units), or the distance along it.',
    inputs = { In('pts', 'points') },
    params = { C('what', 'Output', { 'dist', 'signed', 'along', 'u' }, { 'Distance', 'Signed distance (left / right)', 'Along the path', 'Across the path (profile coordinate)' }, 'dist'), N('far', 'Largest distance (units)', 10, 3000, 10, '%d', 300) },
    eval = function(E, v, ins)
        local Paths = import('/lua/editor/paths.lua')
        local S = Paths.Sample(ins.pts, 1.0)
        if S.n < 1 then error('the path has no points') end
        local args = ZeroArgs(Paths, ins.pts, S)
        args.like = E.like
        if v.what == 'along' then
            args.normalize = 1
            return One(E:Op('path_along', args))
        end
        if v.what == 'u' then return One(E:Op('path_u', args)) end
        args.far = v.far
        if v.what == 'signed' then args.signed = 1 end
        return One(E:Op('path_dist', args))
    end })

Def('path_shape', { label = 'Path shape', cat = 'paths', kw = 'path shape carve raise ramp river road level canyon ridge terrain',
    desc = 'Shapes the heights along a path: carve a valley, raise a ridge, level a road, ramp between heights or cut a river bed. The profile is the cross section.',
    inputs = { In('a', 'height'), In('pts', 'points') },
    params = { C('mode', 'Mode', PATH_MODES, { 'Carve', 'Raise', 'Level', 'Ramp', 'Road', 'River' }, 'carve'),
               C('profile', 'Cross section', PATH_PROFILE, { 'Ramp', 'Road with shoulders', 'V valley', 'U canyon', 'Ridge', 'Wall', 'Terrace steps' }, 'u'),
               N('strength', 'Strength', 0, 1, 0.05, '%.2f', 1, { wire = true }) },
    eval = function(E, v, ins)
        local Paths = import('/lua/editor/paths.lua')
        local path = Paths.DeepCopy(ins.pts)
        path.mode = v.mode
        local m = Paths.Modes[v.mode]
        for _, p in Paths.Presets do
            if p.id == v.profile then
                local prof = {}
                for _, q in p.points do table.insert(prof, { q[1], q[2] }) end
                path.profile = { points = prof, smooth = p.smooth, symmetric = true }
            end
        end
        local S = Paths.Sample(path, 1.0)
        if S.n < 1 then error('the path has no points') end
        local base = ins.a
        local args = Paths.NativeArgs(path, S, function(x, z) return Fields.Sample(base, x, z) end)
        args.a = base
        args.mode = m.native
        args.clip = m.clip
        args.strength = v.strength
        return One(E:Op('path_shape', args))
    end })

-- ---- numbers ----------------------------------------------------------------------------------------------------------------------------------------

Def('number', { label = 'Number', cat = 'numbers', kw = 'number value constant parameter',
    desc = 'A single number. Wire it into any parameter that has a number port to drive several nodes from one value.',
    outputs = { Out('out', 'number') }, params = { N('value', 'Value', -10000, 10000, 0.01, '%.2f', 1) },
    eval = function(E, v, ins) return One(v.value) end })

Def('water_level', { label = 'Water level', cat = 'numbers', kw = 'water level surface elevation sea',
    desc = 'The map\'s water surface elevation (plus an offset), as a number.',
    outputs = { Out('out', 'number') }, params = { N('offset', 'Offset', -100, 100, 0.5, '%.1f', 0) },
    eval = function(E, v, ins) return One(E.water + v.offset) end })

Def('math', { label = 'Math', cat = 'numbers', kw = 'math add multiply divide min max number calculate',
    desc = 'Combines two numbers (a unwired side uses its value).',
    inputs = { In('a', 'number', true), In('b', 'number', true) }, outputs = { Out('out', 'number') },
    params = { C('op', 'Operation', { 'add', 'sub', 'mul', 'div', 'min', 'max' }, { 'a + b', 'a - b', 'a x b', 'a / b', 'smaller', 'larger' }, 'add'),
               N('va', 'a (when not wired)', -10000, 10000, 0.01, '%.2f', 0), N('vb', 'b (when not wired)', -10000, 10000, 0.01, '%.2f', 1) },
    eval = function(E, v, ins)
        local a = ins.a
        if a == nil then a = v.va end
        local b = ins.b
        if b == nil then b = v.vb end
        local r
        if v.op == 'add' then r = a + b
        elseif v.op == 'sub' then r = a - b
        elseif v.op == 'mul' then r = a * b
        elseif v.op == 'div' then r = (b ~= 0) and (a / b) or 0
        elseif v.op == 'min' then r = math.min(a, b)
        else r = math.max(a, b) end
        return One(r)
    end })

Def('field_stat', { label = 'Field statistic', cat = 'numbers', kw = 'statistic min max mean average deviation number measure',
    desc = 'The lowest, highest and mean value and the spread of a field, as numbers (preview resolution during editing).',
    inputs = { In('a', 'height') },
    outputs = { Out('min', 'number'), Out('max', 'number'), Out('mean', 'number'), Out('sd', 'number') },
    eval = function(E, v, ins)
        local mn, mx, mean, sd = Fields.Stats(ins.a)
        return { min = mn, max = mx, mean = mean, sd = sd }
    end })

-- ---- outputs ----------------------------------------------------------------------------------------------------------------------------------------

Def('out_height', { label = 'Output: heights', cat = 'outputs', kw = 'output height terrain write map build',
    desc = 'Writes the field into the map heights (world units). Replace, add to the ground or blend with an opacity and an optional mask.',
    inputs = { In('a', 'height'), In('mask', 'mask', true) }, outputs = { Out('view', 'height', true) }, output = 'height',
    params = { C('mode', 'Mode', { 'replace', 'add', 'blend' }, { 'Replace the heights', 'Add to the heights', 'Blend with the heights' }, 'replace'),
               N('strength', 'Strength', 0, 1, 0.05, '%.2f', 1, { wire = true }), N('gain', 'Gain (add mode)', -4, 4, 0.05, '%.2f', 1) },
    eval = function(E, v, ins) return { view = ins.a } end })

local TextureRoleIds, TextureRoleLabels = import('/lua/editor/texsets.lua').RoleChoices()

Def('out_layer', { label = 'Output: texture layer', cat = 'outputs', kw = 'output layer stratum texture paint mask write',
    desc = 'Writes a mask into the paint mask of a texture layer (1..8; a layer the map\'s shader does not paint, such as layer 8 of the numbered shaders, refuses the build). The Layer texture setting also gives the layer a texture of a kind (grass, rock, sand ...) from the map\'s texture set; Keep leaves the layer\'s own texture.',
    inputs = { In('a', 'mask') }, outputs = { Out('view', 'mask', true) }, output = 'layer',
    params = { N('layer', 'Layer', 1, 8, 1, '%d', 2), C('mode', 'Mode', { 'replace', 'add', 'subtract' }, { 'Replace', 'Add to (the larger)', 'Subtract from' }, 'replace'),
               N('strength', 'Strength', 0, 1, 0.05, '%.2f', 1, { wire = true }), B('takeAway', 'Layers above take away', false),
               C('texture', 'Layer texture', TextureRoleIds, TextureRoleLabels, 'keep') },
    eval = function(E, v, ins) return { view = ins.a } end })

Def('out_types', { label = 'Output: terrain type', cat = 'outputs', kw = 'output terrain type code surface write',
    desc = 'Sets a terrain type code in the terrain-type grid where the mask is above a threshold.',
    inputs = { In('a', 'mask') }, outputs = { Out('view', 'mask', true) }, output = 'types',
    params = { N('code', 'Type code', 0, 255, 1, '%d', 2), N('threshold', 'Where the mask is above', 0, 1, 0.01, '%.2f', 0.5, { wire = true }) },
    eval = function(E, v, ins) return { view = ins.a } end })

Def('out_scatter', { label = 'Output: scatter props', cat = 'outputs', kw = 'output scatter props decals trees rocks poisson write',
    desc = 'Scatters props (or decals) where the density mask allows: Poisson disc sampling with a minimum distance, seeded, symmetry aware. Runs on Build only.',
    inputs = { In('a', 'mask', true) }, outputs = { Out('view', 'mask', true) }, output = 'scatter',
    params = { C('kind', 'Scatter', { 'props', 'decals' }, { 'Props', 'Decals' }, 'props'),
               { kind = 'props', key = 'entries', label = 'Blueprints (weights)', default = {} },
               N('count', 'Most to place', 1, 20000, 10, '%d', 800), N('minDist', 'Minimum distance (units)', 0.5, 80, 0.5, '%.1f', 6), N('fill', 'Fill (acceptance)', 0, 1, 0.05, '%.2f', 1),
               N('slopeMax', 'Steepest slope (degrees)', 0, 90, 1, '%d', 35), N('scaleMin', 'Smallest scale (%)', 10, 400, 5, '%d', 80), N('scaleMax', 'Largest scale (%)', 10, 400, 5, '%d', 120),
               N('margin', 'Margin from the edge (units)', 0, 100, 1, '%d', 4), B('underWater', 'Also under water', false), SEED },
    eval = function(E, v, ins)
        if ins.a then return { view = ins.a } end
        return { view = E:Const(1) }
    end })

-- ---- Supreme Commander terrain (T6) and image fitting (interop) ---------------------------------------------------------------------------------------------

--- Pads of the map's markers as the flat list of the native op (x, z, half, skirt, y, group per pad), from the same rules the SC terrain panel uses (sctools.lua).
local function MarkerPads()
    local Sc = import('/lua/editor/sctools.lua')
    local flat = {}
    for _, p in Sc.Collect() do
        table.insert(flat, p.x) table.insert(flat, p.z) table.insert(flat, p.half) table.insert(flat, p.skirt) table.insert(flat, p.y or 0) table.insert(flat, p.group)
    end
    return flat
end

Def('pad_flatten', { label = 'Base pads', cat = 'sc', kw = 'pad flatten base start mass hydro resource ring plateau level markers',
    desc = 'Levels flat square pads with a smooth skirt: under the start positions and resource markers of the map (the SC terrain panel\'s rules), or one pad of your own. A cluster shares one height.',
    inputs = { In('a', 'height') }, outputs = { Out('out', 'height'), Out('core', 'mask'), Out('weight', 'mask') },
    params = { C('source', 'Pads from', { 'markers', 'one' }, { 'The map\'s markers', 'One pad (below)' }, 'markers'),
               C('level', 'Pad height', { '0', '1', '2' }, { 'Mean of the ground', 'Lowest of the ground', 'Highest of the ground' }, '0'),
               N('strength', 'Strength', 0, 1, 0.05, '%.2f', 1, { wire = true }),
               N('x', 'One pad: x (share of the map)', 0, 1, 0.01, '%.2f', 0.5), N('z', 'One pad: z (share of the map)', 0, 1, 0.01, '%.2f', 0.5),
               N('half', 'One pad: half size (units)', 1, 100, 0.5, '%.1f', 8), N('skirt', 'One pad: skirt (units)', 0, 100, 0.5, '%.1f', 10),
               N('grid', 'Build grid (units)', 1, 8, 1, '%d', 1) },
    liveKey = function()
        local ok, sig = pcall(function() return import('/lua/editor/sctools.lua').Signature() end)
        return ok and tostring(sig) or ''
    end,
    eval = function(E, v, ins)
        local pads
        if v.source == 'markers' then
            pads = MarkerPads()
            if table.getn(pads) == 0 then error('the map has no start positions or resource markers') end
        else
            pads = { v.x * E.W, v.z * E.H, v.half, v.skirt, 0, 0 }
        end
        local p = { a = ins.a, pads = pads, strength = v.strength, level = tonumber(v.level), grid = v.grid, snap = 1, word = 128 }
        local out = { out = E:Op('pad_flatten', p) }
        if E.wanted.core then
            p.output = 'core'
            out.core = E:Op('pad_flatten', p)
        end
        if E.wanted.weight then
            p.output = 'weight'
            out.weight = E:Op('pad_flatten', p)
        end
        return out
    end })

--- How many wedges (master part choices) a symmetry has: mirrors 2 (x, z, diagonals) or 4 (both axes / both diagonals), turns by 180 / 90 / N: 2 / 4 / n. Matches EdFieldSc.cpp BuildGroup.
function SymWedges(mode, n)
    if mode == 'mirror_xz' or mode == 'diag_both' or mode == 'rot4' then return 4 end
    if mode == 'rot2' or mode == 'mirror_x' or mode == 'mirror_z' or mode == 'diag' or mode == 'adiag' then return 2 end
    return math.max(2, math.min(12, math.floor((tonumber(n) or 3) + 0.5)))
end

Def('symmetrize', { label = 'Symmetrize', cat = 'sc', kw = 'symmetry symmetrize mirror rotate wedge master copy competitive fair turn pinwheel seam',
    desc = 'Copies a master part of the map over the rest by a symmetry group (mirrors, diagonals, 2 / 4 / N-fold turns). A turn cannot match the contents of two neighbouring parts, so the soft seam cross-fades every border (the master continuing over it); Average / Larger / Smaller combine all copies instead of copying the master (superposed copies: shapes appear several times and detail washes out). Turn by 90 and the diagonal mirrors need a square map: beyond the square the map is not symmetric.',
    inputs = { In('a', 'height') },
    describe = function(node)
        local pr = node.params or {}
        local mode = pr.mode or 'mirror_x'
        local d = Defs.symmetrize
        local label = mode
        for i, id in d.params[1].ids do
            if id == mode then label = d.params[1].labels[i] end
        end
        local count = SymWedges(mode, pr.n)
        local text = label .. '  part ' .. math.min(math.max(math.floor((pr.side or 0) + 0.5), 0), count - 1) .. ' of ' .. count
        if (pr.combine or 'copy') == 'copy' and (pr.seam or 0) > 0 then text = text .. '  seam ' .. string.format('%d', pr.seam) end
        return text
    end,
    params = { C('mode', 'Symmetry', { 'mirror_x', 'mirror_z', 'mirror_xz', 'diag', 'adiag', 'diag_both', 'rot2', 'rot4', 'rotn' },
                 { 'Mirror x', 'Mirror z', 'Mirror x and z', 'Diagonal', 'Anti-diagonal', 'Both diagonals', 'Turn by 180', 'Turn by 90', 'N-fold turn' }, 'mirror_x'),
               N('side', 'Master part (0 to parts - 1)', 0, 11, 1, '%d', 0, { tip = 'Which part of the map is copied onto the rest. Mirrors across one line have 2 parts (0, 1), Turn by 180 has 2, Turn by 90 and the two-line mirrors have 4 (0 to 3), an N-fold turn has N. A larger value is brought back to the last part. The canvas shows "part k of n".' }),
               N('n', 'Turns (N-fold)', 2, 12, 1, '%d', 3, { tip = 'N-fold turn only: the number of copies around the centre.' }),
               N('angle', 'Start angle (turns, degrees)', 0, 360, 1, '%d', 0, { tip = 'Turns the whole layout of parts around the centre. 0 is the default: Turn by 180 / 90 start at the left (part 0 is the upper half / upper left quarter), an N-fold turn starts to the right.' }),
               B('centred', 'Own centre (otherwise the middle of the map)', false), N('cx', 'Centre x (share)', 0, 1, 0.01, '%.2f', 0.5), N('cz', 'Centre z (share)', 0, 1, 0.01, '%.2f', 0.5),
               C('combine', 'Where images meet', { 'copy', 'avg', 'max', 'min' }, { 'Copy the master', 'Average', 'Larger', 'Smaller' }, 'copy'),
               N('seam', 'Soft seam (units)', 0, 200, 1, '%d', 24, { tip = 'Width of the soft border on each side of every part border when copying the master. 0 gives hard cuts (a turn then shows the two borders of the master side by side). Around 3 to 8 percent of the map is a good start.' }),
               B('nearest', 'Nearest sample (codes, no blending)', false) },
    eval = function(E, v, ins)
        local count = SymWedges(v.mode, v.n)
        local side = math.min(math.max(math.floor((v.side or 0) + 0.5), 0), count - 1)
        local p = { a = ins.a, mode = v.mode, side = side, sector = side, n = v.n, angle = v.angle, combine = v.combine, seam = v.seam, nearest = v.nearest and 1 or 0 }
        if v.centred then p.cx, p.cz = v.cx * E.W, v.cz * E.H end
        return One(E:Op('symmetrize', p))
    end })

Def('slope_limit', { label = 'Slope limit (pathable)', cat = 'sc', kw = 'slope limit pathable clamp steep lower raise lipschitz units land',
    desc = 'Makes every neighbouring pair of samples differ by at most the limit (the engine\'s 0.75 rule: pathable for every unit class). Cut peaks, fill valleys or both.',
    inputs = { In('a', 'height'), In('mask', 'mask', true) },
    params = { N('limit', 'Steepest allowed (rise / run)', 0.05, 3, 0.05, '%.2f', 0.75, { wire = true }),
               C('mode', 'Fix by', { 'lower', 'raise', 'both' }, { 'Cutting peaks', 'Filling valleys', 'Both (balanced)' }, 'both'),
               N('balance', 'Balance (0 raise .. 1 lower)', 0, 1, 0.05, '%.2f', 0.5), N('margin', 'Safety margin', 0, 0.5, 0.01, '%.2f', 0.02),
               N('strength', 'Strength', 0, 1, 0.05, '%.2f', 1, { wire = true }) },
    eval = function(E, v, ins)
        return One(E:Op('slope_limit', { a = ins.a, mask = ins.mask, limit = v.limit, mode = v.mode, balance = v.balance, margin = v.margin, strength = v.strength }))
    end })

Def('reach', { label = 'Travel distance', cat = 'sc', kw = 'reach travel distance path route cost flood connectivity pathing start',
    desc = 'Walking distance (units) over the passable ground from a source point; ground that cannot be reached gets the unreachable value. A cost field slows travel.',
    inputs = { In('a', 'mask'), In('b', 'height', true) },
    params = { N('x', 'Source x (share of the map)', 0, 1, 0.01, '%.2f', 0.1), N('z', 'Source z (share of the map)', 0, 1, 0.01, '%.2f', 0.1),
               N('snap', 'Move the source to passable ground within (samples)', 0, 32, 1, '%d', 4), N('unreach', 'Value where it cannot be reached', -100, 100000, 1, '%d', -1) },
    eval = function(E, v, ins)
        return One(E:Op('reach', { a = ins.a, b = ins.b, src = { v.x * E.W, v.z * E.H }, snap = v.snap, unreach = v.unreach }))
    end })

Def('regions', { label = 'Connected regions', cat = 'sc', kw = 'regions connected components islands pockets label size area passable',
    desc = 'Labels the connected areas of a passable mask (1..N), or gives every area its size in square units: find sealed-off pockets.',
    inputs = { In('a', 'mask') },
    params = { C('mode', 'Output', { 'label', 'size' }, { 'Region number', 'Area of the region' }, 'label'),
               C('connectivity', 'Neighbours', { '8', '4' }, { '8 (no corner cutting)', '4' }, '8') },
    eval = function(E, v, ins)
        return One(E:Op('regions', { a = ins.a, mode = v.mode, connectivity = tonumber(v.connectivity) }))
    end })

Def('rect_mask', { label = 'Rectangle mask', cat = 'sc', kw = 'rectangle rect box mask region area feather window crop',
    desc = 'A mask that is 1 inside a rectangle (shares of the map) with soft borders.',
    outputs = { Out('out', 'mask') },
    params = { N('x0', 'Left (share)', 0, 1, 0.01, '%.2f', 0.25, { wire = true }), N('z0', 'Top (share)', 0, 1, 0.01, '%.2f', 0.25, { wire = true }),
               N('x1', 'Right (share)', 0, 1, 0.01, '%.2f', 0.75, { wire = true }), N('z1', 'Bottom (share)', 0, 1, 0.01, '%.2f', 0.75, { wire = true }),
               N('feather', 'Soft border (units)', 0, 300, 1, '%d', 20), C('curve', 'Border curve', { 'smooth', 'linear' }, { 'Smooth', 'Linear' }, 'smooth') },
    eval = function(E, v, ins)
        local w, h = Fields.Info(E.like)
        local function Ix(share, n) return math.max(0, math.min(n - 1, math.floor(share * (n - 1) + 0.5))) end
        return One(E:Op('rect_mask', { like = E.like, x0 = Ix(v.x0, w), z0 = Ix(v.z0, h), x1 = Ix(v.x1, w), z1 = Ix(v.z1, h),
                                       feather = v.feather / E.cell, curve = v.curve }))
    end })

Def('points_mask', { label = 'Points mask (discs)', cat = 'sc', kw = 'points mask disc circle radius markers start spots',
    desc = 'A disc around every control point of a path (or one point of your own) with a soft edge: rings around bases, resource spots.',
    inputs = { In('pts', 'points', true) }, outputs = { Out('out', 'mask') },
    params = { N('x', 'One point: x (share of the map)', 0, 1, 0.01, '%.2f', 0.5), N('z', 'One point: z (share of the map)', 0, 1, 0.01, '%.2f', 0.5),
               N('radius', 'Radius (units)', 0.5, 600, 0.5, '%.1f', 30, { wire = true }), N('value', 'Value inside', 0, 1, 0.05, '%.2f', 1), N('feather', 'Soft edge (units)', 0, 300, 0.5, '%.1f', 10) },
    eval = function(E, v, ins)
        local pts = {}
        if ins.pts then
            for _, q in ins.pts.points do
                table.insert(pts, q.x) table.insert(pts, q.z) table.insert(pts, v.radius) table.insert(pts, v.value)
            end
        else
            pts = { v.x * E.W, v.z * E.H, v.radius, v.value }
        end
        return One(E:Op('points_mask', { like = E.like, pts = pts, feather = v.feather }))
    end })

Def('img_resample', { label = 'Fit image to the map', cat = 'sources', kw = 'image resample fit stretch scale lanczos bicubic bilinear import size interop',
    desc = 'Fits a field of any size (an imported image, a field from another tool) over the map with a proper filter; the image can cover a rectangle of the map only.',
    inputs = { In('a', 'height') },
    params = { C('align', 'Pixels sit', { 'cell', 'corner' }, { 'On the cells (1024 image over a 1025 map)', 'On the samples (1025 image = identity)' }, 'cell'),
               C('filter', 'Filter', { 'bilinear', 'bicubic', 'lanczos', 'nearest' }, { 'Bilinear', 'Bicubic', 'Lanczos', 'Nearest' }, 'bicubic'),
               N('x0', 'Covers: left (share)', 0, 1, 0.01, '%.2f', 0), N('z0', 'Covers: top (share)', 0, 1, 0.01, '%.2f', 0),
               N('x1', 'Covers: right (share)', 0, 1, 0.01, '%.2f', 1), N('z1', 'Covers: bottom (share)', 0, 1, 0.01, '%.2f', 1),
               N('outside', 'Value outside the rectangle', -300, 600, 0.5, '%.1f', 0) },
    eval = function(E, v, ins)
        local w, h = Fields.Info(E.like)
        local function Ix(share, n) return math.max(0, math.min(n - 1, math.floor(share * (n - 1) + 0.5))) end
        return One(E:Op('img_resample', { a = ins.a, like = E.like, x0 = Ix(v.x0, w), z0 = Ix(v.z0, h), x1 = Ix(v.x1, w), z1 = Ix(v.z1, h),
                                          align = v.align, filter = v.filter, outside = v.outside }))
    end })

Def('img_orient', { label = 'Turn / flip image', cat = 'shape', kw = 'image orient flip transpose rotate mirror swap axes interop gaea world machine',
    desc = 'Swaps x and z and / or flips an axis: the eight orientations of a square image (other tools put north at the top, this editor does not).',
    inputs = { In('a', 'height') },
    params = { B('transpose', 'Swap x and z', false), B('flip_x', 'Flip x', false), B('flip_z', 'Flip z', false) },
    eval = function(E, v, ins)
        return One(E:Op('img_orient', { a = ins.a, transpose = v.transpose and 1 or 0, flip_x = v.flip_x and 1 or 0, flip_z = v.flip_z and 1 or 0 }))
    end })

-- ---- the engine's own catalogue -----------------------------------------------------------------------------------------------------------------------

--- The engine ops that a node above wraps. A name here that the engine no longer lists is harmless; a name the engine lists that is not here gets a generic node (below), so a new op is
--- always in the palette. selftest_graph checks that every name in this table is really used by a node.
Covers = {}
for _, op in { 'abs', 'add', 'affine', 'aspect', 'basin_depth', 'billow', 'blend', 'blur', 'box', 'clamp', 'const', 'curvature', 'distance', 'erode_droplet', 'erode_hydraulic', 'erode_stream',
               'flow', 'gamma', 'gradient', 'height_band', 'invert', 'levels', 'max', 'min', 'mirror', 'mul', 'normalize', 'offset', 'path_along', 'path_dist', 'path_mask', 'path_shape', 'path_u',
               'perlin', 'quantize', 'radial', 'remap', 'resample', 'ridged', 'rotate', 'scale', 'shore', 'simplex', 'slope', 'slope_area', 'smoothstep', 'sub', 'terrace', 'thermal',
               'threshold', 'voronoi', 'warp', 'water_above', 'water_below', 'water_depth', 'white',
               'pad_flatten', 'symmetrize', 'slope_limit', 'reach', 'regions', 'rect_mask', 'points_mask', 'img_resample', 'img_orient' } do
    Covers[op] = true
end
-- internal helpers of the graph itself (reached through other nodes or not meant for a palette entry)
for _, op in { 'crop', 'resize', 'path_paste' } do Covers[op] = true end
-- the stage T7 nodes (graphnodes_t7.lua): the kit hands it the constructors of this file
import('/lua/editor/graphnodes_t7.lua').Install({ Def = Def, N = N, C = C, B = B, T = T, In = In, Out = Out, One = One, Fit = Fit, SEED = SEED, Fields = Fields }, Covers)
-- the nodes of the map-wide shader textures (graphnodes_map.lua, maptextures.lua): normal map, environment lighting, lighting texture and their two outputs
import('/lua/editor/graphnodes_map.lua').Install({ Def = Def, N = N, C = C, B = B, In = In, Out = Out }, Covers)

--- Parses `key=value,key=value` (a number, a word, or a list x:y;x:y) into op parameters: the text format of the golden cases.
function ParseArgs(text)
    local p = {}
    for kv in string.gfind(text or '', '[^,]+') do
        local eq = string.find(kv, '=', 1, true)
        if eq then
            local key, val = string.sub(kv, 1, eq - 1), string.sub(kv, eq + 1)
            key = string.gsub(key, '^%s+', '')
            if string.find(val, '[:;]') then
                local flat = {}
                for num in string.gfind(val, '[^:;]+') do
                    local n = tonumber(num)
                    if n then table.insert(flat, n) end
                end
                p[key] = flat
            elseif tonumber(val) then
                p[key] = tonumber(val)
            else
                p[key] = val
            end
        end
    end
    return p
end

--- A generic node for every engine op that has no node of its own: the optional inputs a, b, mask, dx, dz, the parameters as `key=value,...` text (lists as x:y;x:y), `like` = the graph's grid
--- when no `a` is wired. Made from the engine's catalogue when this module loads, so a new native op shows up in the palette (category Engine ops) without a change here.
Raw = {}

function MakeRaw(op)
    local opName = op
    do
        do
            do
                Def('raw_' .. op, { label = op .. ' (engine op)', cat = 'raw', raw = true, kw = 'engine op raw native ' .. op,
                    desc = 'The native field op "' .. op .. '" without a dedicated node yet: wire the fields it reads (a, b, mask, dx, dz) and type its parameters as key=value,key=value (lists as x:y;x:y; see its golden cases in the field engine tests).',
                    inputs = { In('a', 'height', true), In('b', 'height', true), In('mask', 'mask', true), In('dx', 'height', true), In('dz', 'height', true) },
                    params = { T('args', 'Parameters (key=value,key=value)', '') },
                    eval = function(E, v, ins)
                        local p = ParseArgs(v.args)
                        for _, k in { 'a', 'b', 'mask', 'dx', 'dz' } do
                            if ins[k] then p[k] = ins[k] end
                        end
                        if not ins.a then p.like = E.like end
                        return One(E:Op(opName, p))
                    end })
            end
        end
    end
    return Defs['raw_' .. op]
end

if rawget(_G, 'ed_field_ops') then
    local ok, names = pcall(ed_field_ops)
    if ok and type(names) == 'table' then
        for _, op in names do
            if not Covers[op] then
                table.insert(Raw, op)
                MakeRaw(op)
            end
        end
    end
end

-- ---- organise ---------------------------------------------------------------------------------------------------------------------------------------

Def('frame', { label = 'Frame (group)', cat = 'organise', kw = 'frame group comment box label organise note',
    desc = 'A labelled box behind other nodes (it has no ports and does nothing): drag its title bar to move the nodes inside together; set its size here.',
    outputs = {}, frame = true,
    params = { T('title', 'Title', 'Group'), N('w', 'Width (canvas units)', 160, 4000, 8, '%d', 480), N('h', 'Height (canvas units)', 96, 3000, 8, '%d', 320),
               C('color', 'Colour', { 'blue', 'green', 'red', 'grey', 'yellow' }, { 'Blue', 'Green', 'Red', 'Grey', 'Yellow' }, 'blue') },
    eval = function(E, v, ins) return {} end })

FrameColor = { blue = '2a3f8fbf', green = '2a4fbf6f', red = '2abf4f4f', grey = '2a9fa5ab', yellow = '2abfa73f' }
FrameHeader = { blue = 'ff2f5f8a', green = 'ff2f7a4a', red = 'ff8a3a3a', grey = 'ff5a6068', yellow = 'ff8a7a2f' }

-- ---- groups of nodes by category ----------------------------------------------------------------------------------------------------------------------

--- The ids of a category in palette order.
function InCat(cat)
    local list = {}
    for _, id in Order do
        if Defs[id].cat == cat then table.insert(list, id) end
    end
    return list
end

--- Palette search: words match the label, the id, the category or the keywords.
function Search(text)
    text = string.lower(text or '')
    local words = {}
    for w in string.gfind(text, '%S+') do table.insert(words, w) end
    local list = {}
    for _, id in Order do
        local d = Defs[id]
        local hay = string.lower(d.label .. ' ' .. id .. ' ' .. (d.kw or '') .. ' ' .. d.cat)
        local ok = true
        for _, w in words do
            if not string.find(hay, w, 1, true) then ok = false end
        end
        if ok then table.insert(list, id) end
    end
    return list
end

--- Colours of the port types.
PortColor = { height = 'ff7fb0e0', mask = 'ffe0a64a', points = 'ff7fd47f', number = 'ffc88ae0', color = 'ffe07fb4' }

--- Colour of the header of a category.
CatColor = { sc = 'ff3f7a5a', raw = 'ff4a4a4a', organise = 'ff5a6068', sources = 'ff3f5f7a', gen = 'ff3f7a5f', shape = 'ff55607a', combine = 'ff6a5a7a', erosion = 'ff7a5a3f', analysis = 'ff7a6a3f', paths = 'ff3f7a74', numbers = 'ff6a3f7a', outputs = 'ff8a3f3f', color = 'ff8a3f6f' }
