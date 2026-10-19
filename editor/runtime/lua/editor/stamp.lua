-- Stamp brushes: a stamp is a shape of brushes.lua (a procedural one or a greyscale picture: PNG / TIF / BMP / DDS from the brush folders or imported) pressed into the terrain along a stroke.
--
--   Height stamp (tool 'stamp'): the picture is a height map, white = Height units. Modes: add (the stamp is added to the ground), subtract, max (the ground rises to the stamp where that is
--   higher), min (the ground sinks to the stamp where that is lower), replace (the stamp replaces the ground inside it: a mountain set into the landscape).
--   Texture stamp (tool 'stamp_paint'): the picture is the mask of the texture layer painting (the Layers and Texture brush panels give layer and strength).
--
-- Every dab of a stroke can differ: Rotation (+ random turn per dab), Scale (+ random jitter), position jitter. The dabs are `Spacing` percent of the stamp's width apart along the path;
-- a click is one stamp. All dabs of a stroke are one undo step (terrain.lua: the native command stack for heights, strata.lua for the layer mask). Symmetry: every image of a dab is stamped with the
-- picture mirrored / rotated the way the image is (ToSource).
--
--   S                      the settings (see below)
--   Spacing()              world units between two dabs
--   BeginStroke()          resets the stroke state (terrain.lua calls it)
--   BeginDab(cx, cz)       one dab's random choices; returns the (jittered) centre: the symmetry images are made from that
--   Dab(cx, cz, brush, image) -> samples changed      height stamp, one image of one dab (inside terrain.lua's open command)
--   PaintWeight(dx, dz, radius, image)                the mask weight the texture stamp gives, (dx, dz) from the centre of one image of the dab
--   Weight(dx, dz, r)      the mask weight (0..1) with the current rotation / scale, for the cursor preview
--   ToSource(image, dx, dz)   offset in the dab's own frame of an offset seen from a symmetry image
--
-- Lua 5.0 dialect.

local Brushes = import('/lua/editor/brushes.lua')
local Sim = import('/lua/editor/sim.lua')

local WORD = 128
local PI = 3.14159265
local RES = 128           -- resolution at which picture masks are sampled

MODES = {
    { id = 'add', label = 'Add' }, { id = 'subtract', label = 'Subtract' }, { id = 'max', label = 'Max' }, { id = 'min', label = 'Min' }, { id = 'replace', label = 'Replace' },
}

S = {
    shape = 'mountain',      -- brushes.lua shape id
    mode = 'add',            -- height stamp mode
    height = 12,             -- world units a white pixel is high
    strength = 100,          -- percent: how much of the stamp is applied (opacity)
    falloff = 30,            -- percent of the radius over which the edge fades out (0 = the picture only)
    rotation = 0,            -- degrees
    randomRotation = false,  -- a random turn per dab
    scaleJitter = 0,         -- percent: each dab's size varies by up to this much
    posJitter = 0,           -- percent of the radius: each dab moves by up to this much
    spacing = 100,           -- percent of the stamp's width between dabs (100 = they touch)
    baseMode = 'dab',        -- 'dab': max / min / replace measure from the ground under the centre of every dab; 'stroke': from the ground under the first dab
}

local dab = { turn = 0, scale = 1 }       -- this dab's random turn (degrees) and size factor
local strokeBase = false                  -- the base height of the stroke ('stroke' mode)
local strokeSeed = 0

function BeginStroke()
    dab = { turn = 0, scale = 1 }
    strokeBase = false
    strokeSeed = strokeSeed + 1
end

--- This dab's random turn (degrees) and size factor (the last BeginDab).
function LastDab() return dab.turn, dab.scale end

--- World units between two dabs of the current stamp.
function Spacing()
    local r = import('/lua/editor/terrain.lua').Brush.radius
    return math.max(1, 2 * r * (S.spacing / 100))
end

--- The draws of one dab. Returns the centre after the position jitter. (math.random: stamping is an editing tool, not sim code.)
function BeginDab(cx, cz)
    dab = { turn = 0, scale = 1 }
    if S.randomRotation then dab.turn = math.random() * 360 end
    if S.scaleJitter > 0 then dab.scale = 1 + (math.random() * 2 - 1) * S.scaleJitter / 100 end
    if S.posJitter > 0 then
        local r = import('/lua/editor/terrain.lua').Brush.radius * S.posJitter / 100
        local a, d = math.random() * 2 * PI, r * math.sqrt(math.random())
        cx, cz = cx + math.cos(a) * d, cz + math.sin(a) * d
    end
    return cx, cz
end

--- The offset (dx, dz) from the centre of a symmetry image, in the frame of the dab itself (the picture of a mirrored image is the mirrored picture).
function ToSource(image, dx, dz)
    local k = image and image.kind or 'id'
    if k == 'id' then return dx, dz end
    if k == 'mx' then return -dx, dz end
    if k == 'mz' then return dx, -dz end
    if k == 'dg' then return dz, dx end
    if k == 'da' then return -dz, -dx end
    if k == 'rot' then
        local a = image.angle or 0
        local c, s = math.cos(a), math.sin(a)
        return dx * c - dz * s, dx * s + dz * c
    end
    return dx, dz
end

--- The stamp's value (0..1) at the offset (dx, dz) of a dab of radius r: picture rotated by the settings, scaled by the dab's size, faded at the edge.
local function Mask(dx, dz, r)
    local rr = r * dab.scale
    local a = math.rad(S.rotation + dab.turn)
    local c, s = math.cos(a), math.sin(a)
    local u = (dx * c + dz * s) / rr
    local v = (-dx * s + dz * c) / rr
    local d2 = u * u + v * v
    if d2 > 1.6 then return 0 end
    local m = Brushes.Sample(S.shape, u, v, RES)
    if m <= 0 then return 0 end
    local f = S.falloff / 100
    if f > 0 then
        local d = math.sqrt(d2)
        if d >= 1 then return 0 end
        local inner = 1 - f
        if d > inner then m = m * 0.5 * (1 + math.cos(PI * (d - inner) / f)) end
    end
    return m
end

--- Cursor preview: the mask for the current rotation / scale (the random parts are not shown).
function Weight(dx, dz, r)
    local saved = dab
    dab = { turn = 0, scale = 1 }
    local m = Mask(dx, dz, r)
    dab = saved
    return m
end

--- The weight of the texture stamp at (dx, dz) from the centre of image `image` of the dab (strata.lua multiplies it by the layer brush's strength).
function PaintWeight(dx, dz, r, image)
    local sx, sz = ToSource(image, dx, dz)
    return Mask(sx, sz, r)
end

--- The brush table the texture stamp hands to strata.lua: the dab's radius (size factor included).
function PaintBrush(brush)
    return { mode = 'paint', radius = brush.radius * dab.scale * 1.0 }
end

--- One image of one height stamp dab at (cx, cz). Returns the number of samples changed. Runs inside terrain.lua's open command (ed_cmd_begin ... ed_cmd_end).
function Dab(cx, cz, brush, image)
    local r = brush.radius * dab.scale
    local x0i, z0i, x1i, z1i = math.floor(cx - r) - 1, math.floor(cz - r) - 1, math.ceil(cx + r) + 1, math.ceil(cz + r) + 1
    local words, x0, z0, x1, z1 = ed_terrain_read_rect(x0i, z0i, x1i, z1i)
    if not words or x1 < x0 or z1 < z0 then return 0 end
    local w, h = x1 - x0 + 1, z1 - z0 + 1
    local before = {}
    for i = 1, w * h do before[i] = words[i] end

    local inverted = false
    if IsKeyDown and IsKeyDown('Shift') then inverted = true end
    local mode = S.mode
    local amount = S.height * WORD
    local k = math.max(0, math.min(1, S.strength / 100))
    if inverted then
        if mode == 'add' then mode = 'subtract' elseif mode == 'subtract' then mode = 'add' elseif mode == 'max' then mode = 'min' elseif mode == 'min' then mode = 'max' end
    end
    -- the base of max / min / replace: the ground under the centre of the dab, or of the stroke's first dab
    local cxi = math.min(math.max(math.floor(cx + 0.5), x0), x1)
    local czi = math.min(math.max(math.floor(cz + 0.5), z0), z1)
    local here = before[(czi - z0) * w + (cxi - x0) + 1]
    local base = here
    if S.baseMode == 'stroke' then
        if not strokeBase then strokeBase = here end
        base = strokeBase
    end

    local changed = 0
    local after = {}
    for i = 1, w * h do after[i] = before[i] end
    for z = z0, z1 do
        for x = x0, x1 do
            local sx, sz = ToSource(image, x - cx, z - cz)
            local m = Mask(sx, sz, r)
            -- (replace also acts where the picture is 0: inside the stamp's circle the ground becomes the base)
            local inside = ((sx * sx + sz * sz) < r * r)
            if m > 0 or (mode == 'replace' and inside) then
                local i = (z - z0) * w + (x - x0) + 1
                local value = before[i]
                local target = base + m * amount
                if mode == 'add' then
                    value = value + m * amount * k
                elseif mode == 'subtract' then
                    value = value - m * amount * k
                elseif mode == 'max' then
                    local t = base + m * amount
                    if t > value then value = value + (t - value) * k end
                elseif mode == 'min' then
                    local t = base - m * amount
                    if t < value then value = value + (t - value) * k end
                elseif mode == 'replace' then
                    -- the edge fade blends the stamp into the ground
                    local edge = 1
                    local f = S.falloff / 100
                    if f > 0 then
                        local d = math.sqrt(sx * sx + sz * sz) / r
                        if d >= 1 then edge = 0 elseif d > 1 - f then edge = 0.5 * (1 + math.cos(PI * (d - (1 - f)) / f)) end
                    end
                    value = value + (target - value) * k * edge
                end
                value = math.floor(value + 0.5)
                if value < 0 then value = 0 elseif value > 65535 then value = 65535 end
                if value ~= before[i] then
                    after[i] = value
                    changed = changed + 1
                end
            end
        end
    end
    if changed == 0 then return 0 end
    if ed_doc_height_write(x0, z0, x1, z1, after) == 0 then return 0 end
    Sim.Resnap(x0, z0, x1, z1)
    return changed
end

--- The settings as a table (for the panel's persistence and the self test).
function Snapshot()
    local out = {}
    for k, v in S do out[k] = v end
    return out
end

function Restore(t)
    for k, v in t or {} do
        if S[k] ~= nil and type(S[k]) == type(v) then S[k] = v end
    end
end
