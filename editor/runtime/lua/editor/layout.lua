-- The map layout: a coarse drawing of the map in layers (hills, mountains, plateaus, water, valleys, flat ground, bases and free masks) that is turned into a height map, into the masks the generator
-- nodes use and into start positions (docs/projects/editor/MAP_LAYOUT.md). The drawing is a grid of Doc.res x Doc.res cells per layer (0..1 each); the generator spreads it over the map, softens
-- every layer by its own soft edge, adds noise relief where the kind asks for it and writes the result like any other generator (one undo step).
--
--   Kinds, KindOrder        what each kind of layer does and its settings (label, colour, params { key, label, min, max, step, fmt, default })
--   Doc                     { res, base (ground height, units), water (water level, units), seed, weather (0..1), layers = { { id, name, kind, visible, color, p = {...}, data = {...} } }, sel, rev }
--   New(opts)               a fresh document with a layer of each of the first six kinds         Listen(fn)  fn() is called when the document changed
--   AddLayer(kind, name) / RemoveLayer(i) / MoveLayer(i, dir) / Select(i) / Layer(i) / Count() / LayerNamed(name)
--   Strokes: BeginStroke(i) ... Dab / Line / FillRect / FillEllipse / FillPolygon / Clear / Fill / Smooth ... EndStroke(label)   one undo entry in the editor history per stroke; every tool paints the
--                           images of the editor's symmetry (symmetry.lua) as well
--   Pixels(opts) -> px, w, h   the picture of the layers (and the markers on them) for the canvas: w * h * 4 numbers 0..255
--   Build(env, like, o) -> height, masks   the generator: the height field and the softened mask of every layer (env = a Fields scope or a graph evaluation); o.weather, o.symmetry (default true)
--   LayerMask(env, like, i) / RawLayerMask(env, like, i)   the softened / the plain mask of layer i      Generate(o) -> samples changed | nil, message   builds and writes the heights (and the water level), one undo step
--   BaseCentres() -> { { x, z, cells } }   the centres of the blobs drawn on layers of the kind `base`, in world units (start positions)
--   Templates, ApplyTemplate(id)   starting drawings (duel, four players, river, islands); the editor symmetry is set to the one they are drawn in
--   Preview(size) -> px, w, h   a coloured height picture of the layout at low resolution (no commit)
--   SidecarText() / LoadSidecar(scenarioFile)   saved next to the map (the `_editor.lua` file); the cells are run length coded
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Symmetry = import('/lua/editor/symmetry.lua')

local function P(key, label, min, max, step, fmt, default) return { key = key, label = label, min = min, max = max, step = step, fmt = fmt, default = default } end

KindOrder = { 'hills', 'mountains', 'plateau', 'water', 'valley', 'flat', 'base', 'mask' }

Kinds = {
    hills = { label = 'Hills', color = { 118, 196, 92 },
        tip = 'Rolling ground raised above the base height, with soft edges and a little noise.',
        params = { P('height', 'Height above the ground (units)', 0, 80, 1, '%d', 12), P('soft', 'Soft edge (units)', 2, 120, 1, '%d', 30),
                   P('rough', 'Roughness (units)', 0, 40, 0.5, '%.1f', 6), P('scale', 'Feature size (units)', 20, 400, 5, '%d', 110) } },
    mountains = { label = 'Mountains', color = { 226, 226, 236 },
        tip = 'High ridged ground: steep, with sharp crests and valleys between them.',
        params = { P('height', 'Height above the ground (units)', 10, 200, 1, '%d', 70), P('soft', 'Soft edge (units)', 4, 160, 1, '%d', 40),
                   P('rough', 'Roughness (units)', 0, 60, 0.5, '%.1f', 14), P('scale', 'Feature size (units)', 30, 500, 5, '%d', 150) } },
    plateau = { label = 'Plateau', color = { 224, 172, 88 },
        tip = 'Flat topped high ground with a steep edge (a mesa).',
        params = { P('height', 'Height above the ground (units)', 4, 150, 1, '%d', 35), P('edge', 'Edge width (units)', 1, 60, 1, '%d', 6),
                   P('rough', 'Roughness of the top (units)', 0, 10, 0.25, '%.2f', 1), P('scale', 'Feature size (units)', 20, 300, 5, '%d', 70) } },
    water = { label = 'Water', color = { 72, 140, 232 },
        tip = 'Lakes, seas and rivers: the ground is dug down below the water level of the layout.',
        params = { P('depth', 'Depth under the water (units)', 1, 60, 1, '%d', 12), P('soft', 'Shore width (units)', 2, 100, 1, '%d', 14) } },
    valley = { label = 'Valley', color = { 160, 98, 62 },
        tip = 'A channel or basin dug into the ground (ravines, dry river beds).',
        params = { P('depth', 'Depth (units)', 1, 80, 1, '%d', 12), P('soft', 'Soft edge (units)', 2, 120, 1, '%d', 16) } },
    flat = { label = 'Flat ground', color = { 196, 196, 120 },
        tip = 'Levels the ground to a height relative to the base height (building areas, ramps between levels).',
        params = { P('level', 'Height relative to the ground (units)', -40, 120, 1, '%d', 0), P('soft', 'Soft edge (units)', 2, 100, 1, '%d', 10) } },
    base = { label = 'Base', color = { 242, 72, 72 },
        tip = 'A start base: the ground is levelled at the base height and the start position goes to the middle of each blob.',
        params = { P('soft', 'Soft edge (units)', 2, 100, 1, '%d', 14) } },
    mask = { label = 'Free mask', color = { 204, 92, 224 },
        tip = 'Changes no heights: a mask for the graph nodes (forests, texture areas, scatter regions).',
        params = {} },
}

local DEFAULT_KINDS = { 'hills', 'mountains', 'plateau', 'water', 'valley', 'base' }

Doc = false
local listeners = {}
local stroke = false
local nextId = 1

function Listen(fn) table.insert(listeners, fn) end

local function Touch()
    Doc.rev = Doc.rev + 1
    for _, fn in listeners do pcall(fn) end
end

local function WorldSize()
    local w = rawget(_G, 'ed_terrain_info') and ed_terrain_info()
    return (w or 257) - 1
end

local function Zeros(n)
    local d = {}
    for i = 1, n do d[i] = 0 end
    return d
end

local function ParamsOf(kind)
    local p = {}
    for _, info in Kinds[kind].params do p[info.key] = info.default end
    return p
end

local function MakeLayer(kind, name)
    local L = { id = nextId, name = name or Kinds[kind].label, kind = kind, visible = true, color = { Kinds[kind].color[1], Kinds[kind].color[2], Kinds[kind].color[3] },
                p = ParamsOf(kind), data = Zeros(Doc.res * Doc.res) }
    nextId = nextId + 1
    return L
end

--- A fresh document. opts: res (cells a side, 64 .. 256, default 128), kinds (a list of kinds to start with).
function New(opts)
    opts = opts or {}
    local res = math.max(32, math.min(256, math.floor(opts.res or 128)))
    Doc = { res = res, base = 25, water = 20, seed = 1, weather = 0, layers = {}, sel = 1, rev = 0, generated = {} }
    stroke = false
    for _, kind in (opts.kinds or DEFAULT_KINDS) do table.insert(Doc.layers, MakeLayer(kind)) end
    Doc.sel = 1
    Touch()
    return Doc
end

function Count() return table.getn(Doc.layers) end
function Layer(i) return Doc.layers[i or Doc.sel] end

function LayerNamed(name)
    for i, L in Doc.layers do
        if L.name == name then return i, L end
    end
    return nil
end

function Select(i)
    if Doc.layers[i] then
        Doc.sel = i
        Touch()
    end
end

function AddLayer(kind, name)
    if not Kinds[kind] or table.getn(Doc.layers) >= 16 then return nil end
    local L = MakeLayer(kind, name)
    -- a second layer of a kind is numbered
    local same = 0
    for _, o in Doc.layers do
        if o.kind == kind then same = same + 1 end
    end
    if not name and same > 0 then L.name = Kinds[kind].label .. ' ' .. (same + 1) end
    table.insert(Doc.layers, L)
    Doc.sel = table.getn(Doc.layers)
    Touch()
    return Doc.sel
end

function RemoveLayer(i)
    if not Doc.layers[i] or table.getn(Doc.layers) <= 1 then return false end
    table.remove(Doc.layers, i)
    if Doc.sel > table.getn(Doc.layers) then Doc.sel = table.getn(Doc.layers) end
    Touch()
    return true
end

--- Moves layer i up (dir 1, later = drawn on top, applied later) or down (dir -1).
function MoveLayer(i, dir)
    local j = i + dir
    if not Doc.layers[i] or not Doc.layers[j] then return false end
    Doc.layers[i], Doc.layers[j] = Doc.layers[j], Doc.layers[i]
    if Doc.sel == i then Doc.sel = j elseif Doc.sel == j then Doc.sel = i end
    Touch()
    return true
end

-- ---- painting -------------------------------------------------------------------------------------------------------------------------------------------

local function Copy(t)
    local c = {}
    for i = 1, table.getn(t) do c[i] = t[i] end
    return c
end

local function ById(id)
    for _, L in Doc.layers do
        if L.id == id then return L end
    end
    return nil
end

--- Starts a stroke on layer i: what it was is kept for the undo entry EndStroke makes.
function BeginStroke(i)
    local L = Doc.layers[i]
    if not L then return false end
    stroke = { id = L.id, before = Copy(L.data) }
    return true
end

--- Ends the stroke: one undo entry when something changed.
function EndStroke(label)
    local s = stroke
    stroke = false
    if not s then return false end
    local L = ById(s.id)
    if not L then return false end
    local changed = false
    for i = 1, table.getn(s.before) do
        if s.before[i] ~= L.data[i] then changed = true break end
    end
    if not changed then return false end
    local after = Copy(L.data)
    local id = s.id
    local before = s.before
    History.Push({
        label = label or ('draw on ' .. L.name),
        undo = function() local l = ById(id) if l then l.data = Copy(before) Touch() end end,
        redo = function() local l = ById(id) if l then l.data = Copy(after) Touch() end end,
    })
    return true
end

--- Images of a canvas point under the editor's symmetry: { { x, z } } in canvas cells (the point itself first).
local function Images(cx, cz)
    if Symmetry.Mode == 'off' then return { { cx, cz } } end
    local res, size = Doc.res, WorldSize()
    local k = size / res
    local out = {}
    for _, p in Symmetry.Points(cx * k, cz * k) do
        table.insert(out, { p.x / k, p.z / k })
    end
    return out
end

local function Smoothstep(t)
    if t <= 0 then return 0 elseif t >= 1 then return 1 end
    return t * t * (3 - 2 * t)
end

--- A round dab on layer i at canvas point (cx, cz): radius r cells, hardness 0..1 (how much of the radius is full strength), strength 0..1. Erase takes paint away instead of adding it.
--- Paints the images of the symmetry too. The cells change by max(old, strength * falloff) (add) or old - strength * falloff (erase).
function Dab(i, cx, cz, r, hardness, strength, erase)
    local L = Doc.layers[i]
    if not L then return end
    local res = Doc.res
    local data = L.data
    for _, img in Images(cx, cz) do
        local x0, x1 = math.max(0, math.floor(img[1] - r)), math.min(res - 1, math.ceil(img[1] + r))
        local z0, z1 = math.max(0, math.floor(img[2] - r)), math.min(res - 1, math.ceil(img[2] + r))
        for z = z0, z1 do
            local dz = z + 0.5 - img[2]
            for x = x0, x1 do
                local dx = x + 0.5 - img[1]
                local d = math.sqrt(dx * dx + dz * dz)
                if d <= r then
                    local t = d / math.max(r, 0.001)
                    local fall = (t <= hardness) and 1 or (1 - Smoothstep((t - hardness) / math.max(1 - hardness, 0.001)))
                    local v = fall * strength
                    local at = z * res + x + 1
                    if erase then
                        local n = data[at] - v
                        data[at] = n < 0 and 0 or n
                    elseif v > data[at] then
                        data[at] = v
                    end
                end
            end
        end
    end
end

--- A line of dabs from (x0, z0) to (x1, z1).
function Line(i, x0, z0, x1, z1, r, hardness, strength, erase)
    local len = math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0))
    local steps = math.max(1, math.ceil(len / math.max(0.5, r * 0.35)))
    for s = 0, steps do
        local t = s / steps
        Dab(i, x0 + (x1 - x0) * t, z0 + (z1 - z0) * t, r, hardness, strength, erase)
    end
end

--- Sets the cells whose centres satisfy inside(cx, cz) (canvas cells) to `strength` (or takes the paint away) on layer i, with the images of the symmetry (a cell is mapped through its centre).
local function FillWhere(i, x0, z0, x1, z1, inside, strength, erase)
    local L = Doc.layers[i]
    if not L then return 0 end
    local res = Doc.res
    local data = L.data
    local plain = Symmetry.Mode == 'off'
    local n = 0
    local function Put(ix, iz)
        if ix < 0 or iz < 0 or ix >= res or iz >= res then return end
        local at = iz * res + ix + 1
        if erase then
            if data[at] ~= 0 then data[at] = 0 n = n + 1 end
        elseif data[at] < strength then
            data[at] = strength
            n = n + 1
        end
    end
    for z = math.max(0, math.floor(z0)), math.min(res - 1, math.ceil(z1)) do
        for x = math.max(0, math.floor(x0)), math.min(res - 1, math.ceil(x1)) do
            if inside(x + 0.5, z + 0.5) then
                if plain then
                    Put(x, z)
                else
                    for _, img in Images(x + 0.5, z + 0.5) do Put(math.floor(img[1]), math.floor(img[2])) end
                end
            end
        end
    end
    return n
end

function FillRect(i, x0, z0, x1, z1, strength, erase)
    local ax, bx = math.min(x0, x1), math.max(x0, x1)
    local az, bz = math.min(z0, z1), math.max(z0, z1)
    return FillWhere(i, ax, az, bx, bz, function(x, z) return x >= ax and x <= bx and z >= az and z <= bz end, strength, erase)
end

function FillEllipse(i, x0, z0, x1, z1, strength, erase)
    local ax, bx = math.min(x0, x1), math.max(x0, x1)
    local az, bz = math.min(z0, z1), math.max(z0, z1)
    local cx, cz = (ax + bx) / 2, (az + bz) / 2
    local rx, rz = math.max(0.5, (bx - ax) / 2), math.max(0.5, (bz - az) / 2)
    return FillWhere(i, ax, az, bx, bz, function(x, z)
        local dx, dz = (x - cx) / rx, (z - cz) / rz
        return dx * dx + dz * dz <= 1
    end, strength, erase)
end

--- Fills a polygon (a list of { x, z } canvas points; even-odd rule).
function FillPolygon(i, points, strength, erase)
    local n = table.getn(points)
    if n < 3 then return 0 end
    local x0, z0, x1, z1 = points[1][1], points[1][2], points[1][1], points[1][2]
    for _, p in points do
        x0, x1 = math.min(x0, p[1]), math.max(x1, p[1])
        z0, z1 = math.min(z0, p[2]), math.max(z1, p[2])
    end
    return FillWhere(i, x0, z0, x1, z1, function(x, z)
        local inside = false
        local j = n
        for k = 1, n do
            local a, b = points[k], points[j]
            if (a[2] > z) ~= (b[2] > z) and x < (b[1] - a[1]) * (z - a[2]) / (b[2] - a[2]) + a[1] then inside = not inside end
            j = k
        end
        return inside
    end, strength, erase)
end

--- Every cell of layer i to `value` (0 clears).
function Fill(i, value)
    local L = Doc.layers[i]
    if not L then return end
    for k = 1, table.getn(L.data) do L.data[k] = value end
end

--- One pass of a 3 x 3 average (softens what was drawn).
function Smooth(i)
    local L = Doc.layers[i]
    if not L then return end
    local res = Doc.res
    local old = Copy(L.data)
    for z = 0, res - 1 do
        for x = 0, res - 1 do
            local sum, cnt = 0, 0
            for dz = -1, 1 do
                for dx = -1, 1 do
                    local xx, zz = x + dx, z + dz
                    if xx >= 0 and zz >= 0 and xx < res and zz < res then
                        sum = sum + old[zz * res + xx + 1]
                        cnt = cnt + 1
                    end
                end
            end
            L.data[z * res + x + 1] = sum / cnt
        end
    end
end

--- Turns what is drawn into its opposite (1 - v).
function Invert(i)
    local L = Doc.layers[i]
    if not L then return end
    for k = 1, table.getn(L.data) do L.data[k] = 1 - L.data[k] end
end

--- Any change made outside a stroke (the panel's Clear, Fill, Smooth buttons): wrap it so it gets its undo entry.
function Edit(i, label, fn)
    if not BeginStroke(i) then return end
    fn()
    EndStroke(label)
    Touch()
end

function Changed() Touch() end

-- ---- the picture ----------------------------------------------------------------------------------------------------------------------------------------

local BG = { 28, 32, 38 }

--- The canvas picture: the visible layers over a dark ground, bright where there is more paint. opts.only: show only the layer with that index; opts.dim: 0..1 dims the other layers when `only` is set.
--- Returns the pixels (a list of w * h * 4 numbers 0..255) and w, h.
function Pixels(opts)
    opts = opts or {}
    local res = Doc.res
    local px = {}
    local layers = Doc.layers
    local nl = table.getn(layers)
    local o = 0
    for z = 0, res - 1 do
        for x = 0, res - 1 do
            local r, g, b = BG[1], BG[2], BG[3]
            local at = z * res + x + 1
            for li = 1, nl do
                local L = layers[li]
                if L.visible then
                    local v = L.data[at]
                    if v > 0.004 then
                        local a = v * (opts.only and (li == opts.only and 0.95 or 0.4) or 0.85)
                        r = r + (L.color[1] - r) * a
                        g = g + (L.color[2] - g) * a
                        b = b + (L.color[3] - b) * a
                    end
                end
            end
            px[o + 1], px[o + 2], px[o + 3], px[o + 4] = r, g, b, 255
            o = o + 4
        end
    end
    return px, res, res
end

--- Marks a spot of the picture (canvas cells) with a coloured square of `size` cells: used for start positions and resources.
function Mark(px, x, z, size, r, g, b)
    local res = Doc.res
    local x0, z0 = math.floor(x - size / 2 + 0.5), math.floor(z - size / 2 + 0.5)
    for dz = 0, size - 1 do
        for dx = 0, size - 1 do
            local ix, iz = x0 + dx, z0 + dz
            if ix >= 0 and iz >= 0 and ix < res and iz < res then
                local o = (iz * res + ix) * 4
                px[o + 1], px[o + 2], px[o + 3] = r, g, b
            end
        end
    end
end

-- ---- the generator ------------------------------------------------------------------------------------------------------------------------------------

local function Noise(env, like, seed, scale, kind, extra)
    local p = { like = like, seed = math.floor(seed), scale = scale, octaves = 6, finest = math.max(3, scale * 0.05), persistence = 0.5, kind = kind or 'fbm' }
    if extra then
        for k, v in extra do p[k] = v end
    end
    return env:Op('fractal', p)
end

local function Const(env, like, v) return env:Op('const', { like = like, value = v }) end

--- The raw mask of layer i on the grid of `like` (the drawing spread over the map, bilinear).
local function RawMask(env, like, L)
    local res = Doc.res
    local cell = WorldSize() / res
    local f = ed_field_from_table(res, res, L.data, cell, cell * 0.5, cell * 0.5)
    env:Add(f)
    return env:Op('resample', { a = f, like = like })
end

--- A mask softened by `soft` units (at least a little more than one drawing cell, so the cells do not show as diamonds).
local function Soft(env, like, m, soft)
    local cell = WorldSize() / Doc.res
    local sigma = math.max(cell * 0.8, (soft or 0) * 0.5)
    return env:Op('clamp', { a = env:Op('blur', { a = m, radius = sigma }), lo = 0, hi = 1 })
end

--- The softened mask of layer i (for the graph nodes). The soft edge is the kind's own setting.
function LayerMask(env, like, i)
    local L = Doc.layers[i]
    if not L then return nil end
    local p = L.p
    local soft = p.soft or p.edge or 6
    return Soft(env, like, RawMask(env, like, L), soft)
end

--- The unsoftened mask of layer i (the drawing spread over the map, bilinear).
function RawLayerMask(env, like, i)
    local L = Doc.layers[i]
    if not L then return nil end
    return RawMask(env, like, L)
end

local function Lerp(env, a, b, m) return env:Op('blend', { a = a, b = b, mask = m, mode = 'normal', opacity = 1 }) end

--- The height field of the layout on the grid of `like`, and the softened masks { [i] = field } of the layers. env: a Fields scope (S:Op, S:Add) or a graph evaluation (E:Op, E:Add).
--- o.weather (0..1): droplet erosion on top; o.symmetry = false leaves the noise as it is (otherwise the editor's symmetry is applied to the result).
function Build(env, like, o)
    o = o or {}
    local base = Doc.base
    local H = Const(env, like, base)
    local masks = {}
    for i, L in Doc.layers do
        local p = L.p
        local kind = L.kind
        local seed = Doc.seed + i * 17
        local m = Soft(env, like, RawMask(env, like, L), p.soft or p.edge or 6)
        masks[i] = m
        if kind == 'hills' then
            local n = Noise(env, like, seed, p.scale, 'fbm')
            local bump = env:Op('affine', { a = n, mul = 2 * p.rough, add = p.height - p.rough })
            H = env:Op('add', { a = H, b = env:Op('mul', { a = m, b = bump }) })
        elseif kind == 'mountains' then
            local r = Noise(env, like, seed, p.scale, 'ridged', { sharpness = 2.2 })
            local n = Noise(env, like, seed + 3, p.scale * 0.6, 'fbm')
            local rise = env:Op('add', { a = env:Op('affine', { a = r, mul = p.height * 1.0, add = p.height * 0.3 }), b = env:Op('affine', { a = n, mul = 2 * p.rough, add = -p.rough }) })
            H = env:Op('add', { a = H, b = env:Op('mul', { a = env:Op('gamma', { a = m, gamma = 1.4 }), b = rise }) })
        elseif kind == 'plateau' then
            local n = Noise(env, like, seed, p.scale, 'fbm')
            local top = env:Op('affine', { a = n, mul = 2 * p.rough, add = base + p.height - p.rough })
            H = Lerp(env, H, top, m)
        elseif kind == 'water' then
            local bed = Const(env, like, Doc.water - p.depth)
            H = env:Op('min', { a = H, b = Lerp(env, H, bed, m) })
        elseif kind == 'valley' then
            H = env:Op('sub', { a = H, b = env:Op('affine', { a = m, mul = p.depth, add = 0 }) })
        elseif kind == 'flat' then
            H = Lerp(env, H, Const(env, like, base + p.level), m)
        elseif kind == 'base' then
            H = Lerp(env, H, Const(env, like, base), m)
        end
    end
    if (o.weather or Doc.weather or 0) > 0.01 then
        local Erosion = import('/lua/editor/erosion.lua')
        local w = o.weather or Doc.weather
        local v = Erosion.Defaults('droplet')
        local mine = { density = 0.3 + 2.5 * w, lifetime = 70, inertia = 0.25, capacity = 6, erode = 0.45, deposit = 0.12, gravity = 5, thermal = 0.4, thermal_steps = 3,
                       talus = 0.9, vary = 0.4, protect = 0.5, drop_vary = 0.6, radius = 2, creep = 1.5, max_change = 6 }
        for k, x in mine do v[k] = x end
        local params = Erosion.OpParams('droplet', v, 1, Doc.seed + 101)
        params.a = H
        params.masks = 0
        local main, extra = Fields.OpMulti('erode_droplet', params)
        if not main then error(tostring(extra)) end
        env:Add(main)
        if extra then
            for _, f in extra do env:Add(f) end
        end
        H = main
    end
    if o.symmetry ~= false and Symmetry.Mode ~= 'off' then
        local cx, cz = Symmetry.Centre()
        local size = WorldSize()
        H = env:Op('symmetrize', { a = H, mode = Symmetry.Mode, side = 0, combine = 'copy', seam = 12, centred = true, cx = cx / size, cz = cz / size })
    end
    H = env:Op('clamp', { a = H, lo = 0, hi = 400 })
    return H, masks
end

--- Builds the layout and writes it into the map heights (one undo step) and, when a water layer has paint, the water level. o: weather, water (false: leave the water settings alone).
--- Returns the number of samples that changed, or nil and a message.
function Generate(o)
    o = o or {}
    if not Fields.IsAvailable() or not (rawget(_G, 'ed_terrain_info') and ed_terrain_info()) then return nil, 'no map is open' end
    local n, why
    local depth0 = History.Depth()
    local ok, err = pcall(function()
        Fields.Run(function(S)
            local like = S:Height(1)
            local H = Build(S, like, o)
            n, why = Fields.CommitHeight(H, { label = 'Layout: generate terrain' })
        end)
    end)
    if not ok then return nil, Fields.CleanError(err) end
    if not n then return nil, tostring(why) end
    local hasWater = false
    for _, L in Doc.layers do
        if L.kind == 'water' then
            for k = 1, table.getn(L.data) do
                if L.data[k] > 0.3 then hasWater = true break end
            end
        end
    end
    if hasWater and o.water ~= false then
        local World = import('/lua/editor/world.lua')
        World.Change({ water_on = 1, water_elev = Doc.water, water_deep = Doc.water - 12, water_abyss = Doc.water - 30 }, { label = 'layout water', refresh = true })
    end
    local pushed = History.Depth() - depth0
    if pushed >= 2 then History.Merge(pushed, 'Layout: generate terrain') end        -- the heights and the water level are one undo step
    return n
end

--- A coloured height picture of the layout at low resolution: size x size pixels (at most). Returns the pixels, w, h; nil and a message when the generator fails. Nothing is written.
function Preview(size)
    if not Fields.IsAvailable() or not (rawget(_G, 'ed_terrain_info') and ed_terrain_info()) then return nil, 'no map is open' end
    local out, pw, ph, why
    local ok, err = pcall(function()
        Fields.Run(function(S)
            local step = 1
            local w = ed_terrain_info()
            while (w - 1) / step > size * 1.5 and step < 16 do step = step * 2 end
            local like = S:Height(step)
            local H = Build(S, like, { weather = 0 })
            local lo, hi = Fields.Stats(H)
            local px, lo2, hi2 = ed_field_preview(H, size, size, { ramp = 'terrain', lo = Doc.water - 25, hi = math.max(Doc.base + 60, hi) })
            out, pw, ph = px, size, size
        end)
    end)
    if not ok then return nil, Fields.CleanError(err) end
    return out, pw, ph
end

-- ---- templates -----------------------------------------------------------------------------------------------------------------------------------------

--- Starting drawings. Each paints the master part with the layers of the document, in fractions of the canvas (0..1), under the symmetry the template names; the editor's symmetry is switched
--- to it, so the rest of the map is drawn by the images. `order`: layer kinds that go to the bottom of the list (applied first).
Templates = {
    { id = 'duel', label = 'Duel', symmetry = 'rot2', tip = 'Two bases facing each other across a winding ridge, a lake beside each base (turned by 180 degrees).',
      paint = function(P)
          P.ellipse('hills', 0.05, 0.2, 0.42, 0.8, 0.9)
          P.line('mountains', 0.46, 0.08, 0.54, 0.5, 0.05, 1)
          P.ellipse('water', 0.27, 0.12, 0.39, 0.25, 1)
          P.dab('base', 0.2, 0.5, 0.07, 1)
      end },
    { id = 'four', label = 'Four players', symmetry = 'mirror_xz', tip = 'A base in each corner, ridges between the corners and a plateau in the middle (mirrored both ways).',
      paint = function(P)
          P.ellipse('hills', 0.04, 0.04, 0.42, 0.42, 0.9)
          P.line('mountains', 0.5, 0.04, 0.5, 0.32, 0.045, 1)
          P.line('mountains', 0.04, 0.5, 0.32, 0.5, 0.045, 1)
          P.ellipse('plateau', 0.4, 0.4, 0.6, 0.6, 1)
          P.dab('base', 0.17, 0.17, 0.065, 1)
      end },
    { id = 'river', label = 'River', symmetry = 'mirror_x', tip = 'A river down the middle with two bases on each bank (mirrored left to right).',
      paint = function(P)
          P.ellipse('hills', 0.02, 0.1, 0.42, 0.9, 0.8)
          P.line('water', 0.5, -0.05, 0.5, 1.05, 0.035, 1)
          P.dab('mountains', 0.3, 0.5, 0.06, 1)
          P.dab('base', 0.2, 0.28, 0.06, 1)
          P.dab('base', 0.2, 0.72, 0.06, 1)
      end },
    { id = 'islands', label = 'Islands', symmetry = 'rot2', order = { 'water' }, tip = 'Open water with an island for each base and a small islet between them (turned by 180 degrees).',
      paint = function(P)
          P.fill('water', 1)
          P.ellipse('hills', 0.1, 0.25, 0.4, 0.75, 1)
          P.dab('mountains', 0.27, 0.42, 0.05, 1)
          P.ellipse('hills', 0.42, 0.1, 0.52, 0.2, 0.7)
          P.dab('base', 0.22, 0.58, 0.06, 1)
      end },
}

--- Replaces the drawing with a template (one undo step); the editor's symmetry is set to the one the template is drawn in. Returns true, or nil and a message.
function ApplyTemplate(id)
    local t
    for _, x in Templates do
        if x.id == id then t = x end
    end
    if not t then return nil, 'no such template' end
    local before = Plain()
    local res = Doc.res
    local keep = { res = res, kinds = {} }
    New(keep)
    -- the layers: the ones the template puts first, then the usual six
    local kinds = {}
    for _, k in (t.order or {}) do table.insert(kinds, k) end
    for _, k in DEFAULT_KINDS do
        local have = false
        for _, e in kinds do if e == k then have = true end end
        if not have then table.insert(kinds, k) end
    end
    for _, k in kinds do table.insert(Doc.layers, MakeLayer(k)) end
    Doc.sel = 1
    Symmetry.SetMode(t.symmetry)
    local function Index(kind)
        for i, L in Doc.layers do
            if L.kind == kind then return i end
        end
        return 1
    end
    local P = {}
    function P.dab(kind, x, z, r, v) Dab(Index(kind), x * res, z * res, r * res, 0.8, v or 1, false) end
    function P.line(kind, x0, z0, x1, z1, r, v) Line(Index(kind), x0 * res, z0 * res, x1 * res, z1 * res, r * res, 0.8, v or 1, false) end
    function P.ellipse(kind, x0, z0, x1, z1, v) FillEllipse(Index(kind), x0 * res, z0 * res, x1 * res, z1 * res, v or 1, false) end
    function P.fill(kind, v) Fill(Index(kind), v) end
    t.paint(P)
    local after = Plain()
    local function Restore(plain)
        if plain then Load(plain) else New({ res = res }) end
    end
    History.Push({ label = 'layout template ' .. t.label, undo = function() Restore(before) end, redo = function() Restore(after) end })
    Touch()
    return true
end

-- ---- start positions from the drawing -------------------------------------------------------------------------------------------------------------------

--- The blobs drawn on the layers of the kind `base` (cells above one half, joined by their sides) as { { x, z, cells } } in world units (the centre of mass), the biggest first.
function BaseCentres()
    local res = Doc.res
    local size = WorldSize()
    local k = size / res
    local on = {}
    local any = false
    for _, L in Doc.layers do
        if L.kind == 'base' and L.visible then
            for at = 1, res * res do
                if L.data[at] >= 0.5 then on[at] = true any = true end
            end
        end
    end
    if not any then return {} end
    local seen = {}
    local list = {}
    for z = 0, res - 1 do
        for x = 0, res - 1 do
            local at = z * res + x + 1
            if on[at] and not seen[at] then
                local stack, sp = { at }, 1
                seen[at] = true
                local sx, sz, n = 0, 0, 0
                while sp > 0 do
                    local cur = stack[sp]
                    stack[sp] = nil
                    sp = sp - 1
                    local cz = math.floor((cur - 1) / res)
                    local cx = cur - 1 - cz * res
                    sx, sz, n = sx + cx + 0.5, sz + cz + 0.5, n + 1
                    for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
                        local nx, nz = cx + d[1], cz + d[2]
                        if nx >= 0 and nz >= 0 and nx < res and nz < res then
                            local na = nz * res + nx + 1
                            if on[na] and not seen[na] then
                                seen[na] = true
                                sp = sp + 1
                                stack[sp] = na
                            end
                        end
                    end
                end
                if n >= 3 then table.insert(list, { x = sx / n * k, z = sz / n * k, cells = n }) end
            end
        end
    end
    table.sort(list, function(a, b) if a.cells ~= b.cells then return a.cells > b.cells end return a.x < b.x end)
    return list
end

-- ---- saved with the map -------------------------------------------------------------------------------------------------------------------------------

local function Encode(data)
    local parts = {}
    local n = table.getn(data)
    local i = 1
    while i <= n do
        local q = math.floor(data[i] * 255 + 0.5)
        local j = i
        while j < n and math.floor(data[j + 1] * 255 + 0.5) == q do j = j + 1 end
        table.insert(parts, q .. 'x' .. (j - i + 1))
        i = j + 1
    end
    return table.concat(parts, ',')
end

local function Decode(text, count)
    local data = {}
    local n = 0
    for q, c in string.gfind(text or '', '(%d+)x(%d+)') do
        local v = tonumber(q) / 255
        for _ = 1, tonumber(c) do
            n = n + 1
            data[n] = v
        end
    end
    if n ~= count then return nil end
    return data
end

--- The document as a plain table (what is saved); nothing when nothing is drawn.
function Plain()
    if not Doc then return nil end
    local drawn = false
    for _, L in Doc.layers do
        for k = 1, table.getn(L.data) do
            if L.data[k] ~= 0 then drawn = true break end
        end
        if drawn then break end
    end
    if not drawn then return nil end
    local t = { res = Doc.res, base = Doc.base, water = Doc.water, seed = Doc.seed, weather = Doc.weather, sel = Doc.sel, generated = Doc.generated, layers = {} }
    for _, L in Doc.layers do
        table.insert(t.layers, { name = L.name, kind = L.kind, visible = L.visible, color = L.color, p = L.p, data = Encode(L.data) })
    end
    return t
end

function Load(t)
    if type(t) ~= 'table' or type(t.layers) ~= 'table' then return false end
    New({ res = t.res, kinds = {} })
    Doc.base, Doc.water, Doc.seed, Doc.weather = t.base or 25, t.water or 20, t.seed or 1, t.weather or 0
    Doc.generated = t.generated or {}
    for _, e in t.layers do
        if Kinds[e.kind] then
            local L = MakeLayer(e.kind, e.name)
            L.visible = e.visible ~= false
            if type(e.color) == 'table' then L.color = { e.color[1], e.color[2], e.color[3] } end
            for _, info in Kinds[e.kind].params do
                if type(e.p) == 'table' and type(e.p[info.key]) == 'number' then L.p[info.key] = e.p[info.key] end
            end
            local d = Decode(e.data, Doc.res * Doc.res)
            if d then L.data = d end
            table.insert(Doc.layers, L)
        end
    end
    if table.getn(Doc.layers) == 0 then New({}) end
    Doc.sel = math.max(1, math.min(table.getn(Doc.layers), t.sel or 1))
    Touch()
    return true
end

function SidecarText()
    local plain = Plain()
    if not plain then return '' end
    return import('/lua/editor/luaser.lua').Chunk({ { 'Layout', plain } })
end

function LoadSidecar(scenarioFile)
    New({})
    local path = scenarioFile and import('/lua/editor/mods.lua').SidecarPath(scenarioFile)
    if path and DiskGetFileInfo(path) then
        local env = {}
        doscript(path, env)
        if type(env.Layout) == 'table' then Load(env.Layout) end
    end
end

New({})
