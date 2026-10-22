-- Terrain brushes on the editor's native command stack (moho/editor/MapDocument.h, EditorLua.cpp).
--
-- A stroke is a run of dabs: BeginStroke(), Dab(x, z) ..., EndStroke(). Every dab is a height command of the
-- document; the dabs of one stroke merge into one undo step. This file only computes the new heights: the document
-- keeps the history, the dirty state, and projects each change into the view and (between sim beats) the sim.
-- Heights in this file are world units; the engine stores height words (world * 128) and the natives
-- read / write words.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` length (table.getn).

local Sim = import('/lua/editor/sim.lua')
local Strata = import('/lua/editor/strata.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local TerrainType = import('/lua/editor/terraintype.lua')
local Props = import('/lua/editor/props.lua')
local Decals = import('/lua/editor/decals.lua')
local Brushes = import('/lua/editor/brushes.lua')
local EroBrush = import('/lua/editor/erosionbrush.lua')
local Stamp = import('/lua/editor/stamp.lua')
local Perf = import('/lua/editor/perf.lua')

local WORD = 128
local PI = 3.14159265

--- Current brush. mode: 'raise' | 'lower' | 'flatten' | 'smooth' | 'noise' | 'paint' | 'erase' (the last two work on the terrain texture layer masks, strata.lua) | 'stamp' | 'stamp_paint' (stamp.lua)
Brush = {
    mode = 'raise',
    radius = 12,       -- world units
    strength = 2.0,    -- magnitude: raise / lower / noise: world units per dab at the centre; flatten / smooth: blend per dab (units * 0.2)
    sign = 1,          -- +1 / -1: the panels show sign * strength * 10 percent (-100..100); a negative strength inverts the brush
    falloff = 1.0,     -- 0..1: the share of the radius the edge falls off over. 0 = a flat disc (full strength to the rim, one cell of soft edge),
                       -- 1 = a cosine falloff from the centre to the rim
    level = nil,       -- flatten target (world units); nil = height under the first dab of the stroke
    noiseScale = 8,        -- noise brush: lattice cell size in samples (the size of the bumps)
    noiseOctaves = 2,      -- noise brush: 1..4 layers of finer bumps (half the cell size each)
    noiseRoughness = 0.5,  -- noise brush: the share of the amplitude each further octave keeps (0.3 soft .. 0.7 rough)
}

--- A box blur of the w x h grid `src` (1-based, row after row), half width `kr` samples, the edge samples repeated; running sums, so the cost does not grow with kr.
local function BoxBlur(src, w, h, kr)
    local n = 2 * kr + 1
    local tmp, out = {}, {}
    for z = 0, h - 1 do
        local row = z * w
        local sum = 0
        for k = -kr, kr do
            sum = sum + src[row + math.min(math.max(k, 0), w - 1) + 1]
        end
        for x = 0, w - 1 do
            tmp[row + x + 1] = sum / n
            sum = sum + src[row + math.min(x + kr + 1, w - 1) + 1] - src[row + math.max(x - kr, 0) + 1]
        end
    end
    for x = 0, w - 1 do
        local sum = 0
        for k = -kr, kr do
            sum = sum + tmp[math.min(math.max(k, 0), h - 1) * w + x + 1]
        end
        for z = 0, h - 1 do
            out[z * w + x + 1] = sum / n
            sum = sum + tmp[math.min(z + kr + 1, h - 1) * w + x + 1] - tmp[math.max(z - kr, 0) * w + x + 1]
        end
    end
    return out
end

local strokeId = 0
local strokeLevel = nil
local strokeOpen = false
local strokeTurn = 0       -- the random extra turn of the shape mask in this stroke (degrees)

-- The derived numbers of the round profile for the last (radius, falloff, softMin): Weight is called once per sample of a dab (and of a preview), so the clamps and
-- min / max calls are done when one of the three changes, not per call.
local wRadius, wFalloff, wSoft, wInner, wWidth = nil, nil, nil, 0, 1

--- The weight of a dab `distance` world units from the brush centre. `softMin` (default 1) is the narrowest edge the brush may have, one cell of
--- the grid it works on, so a flat brush does not leave a staircase.
local function Weight(distance, radius, softMin, dx, dz)
    if distance >= radius then
        return 0
    end
    if dx and Brushes.Active ~= 'round' then
        return Brushes.Weight(Brushes.Active, dx, dz, radius, strokeTurn)       -- a shape mask replaces the falloff profile
    end
    local f = Brush.falloff
    local soft = softMin or 1
    if radius ~= wRadius or f ~= wFalloff or soft ~= wSoft then
        wRadius, wFalloff, wSoft = radius, f, soft
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
        wWidth = math.min(radius, math.max(radius * f, soft))
        wInner = radius - wWidth
    end
    if distance <= wInner then
        return 1
    end
    return 0.5 * (1 + math.cos(PI * (distance - wInner) / wWidth))
end

local PROFILE_STEPS = 8
local profileRadius, profileFalloff, profileTable = nil, nil, nil

--- The round brush's weight at the distances k / 8 (k = 0 ..), as a table [0 ..] cached for the current radius and falloff: the brush preview (overlay.lua) reads it with a
--- linear interpolation instead of one Weight call per sample. Returns the table and the number of steps per world unit.
function RoundProfile(radius)
    if radius ~= profileRadius or Brush.falloff ~= profileFalloff or not profileTable then
        profileRadius, profileFalloff = radius, Brush.falloff
        local t = {}
        local n = math.ceil(radius * PROFILE_STEPS) + 2
        for k = 0, n do
            t[k] = Weight(k / PROFILE_STEPS, radius, 1)
        end
        profileTable = t
    end
    return profileTable, PROFILE_STEPS
end

--- The weight a dab gives a height sample `distance` world units from the brush centre (what the preview draws).
function BrushWeight(distance, radius, dx, dz)
    if dx and (Brush.mode == 'stamp' or Brush.mode == 'stamp_paint') then
        return Stamp.Weight(dx, dz, radius)               -- the stamp's own picture (rotation and size from its settings)
    end
    return Weight(distance, radius, nil, dx, dz)
end

-- Smooth noise for the noise brush: value noise on a lattice. The lattice values come from a seeded integer hash in -1..1; between lattice points the four corners are blended
-- bilinearly with a smoothstep weight, so the result is continuous (no per-sample speckle). It is a function of the world position (x, z in samples) and the stroke's seed only, so
-- the dabs of one stroke join into continuous bumps. Octaves add finer layers (half the cell size each, `rough` times the amplitude of the one before).
-- Lua numbers are 32-bit floats: every intermediate of the hash stays below 2^24, so the result is exact. (The first hash multiplied by 374761393 and took math.mod: the product lost
-- its low bits in a float and the hash was -1 nearly everywhere.) ed_terrain_brush (moho/editor/EdBrush.h, ValueNoise / SmoothNoise) computes the same numbers with the same
-- operations in the same order: keep the two in step.
local function Hash(x, z, seed)
    local a = math.mod(math.mod(x, 4093) * 1103 + 17, 4093)
    local b = math.mod(math.mod(z, 4091) * 1999 + 31, 4091)
    local c = math.mod(math.mod(seed, 4079) * 997 + 5, 4079)
    local n = math.mod(a * 4001 + b, 4093)
    n = math.mod(n * n + c, 4093)
    n = math.mod(n * n + a, 4093)
    n = math.mod(n * n + b, 4093)
    return n / 4093 * 2 - 1
end

local function ValueNoise(x, z, cell, seed)
    local fx = x / cell
    local fz = z / cell
    local ix = math.floor(fx)
    local iz = math.floor(fz)
    local tx = fx - ix
    local tz = fz - iz
    local bx = 2 * tx
    bx = 3 - bx
    tx = tx * tx * bx
    local bz = 2 * tz
    bz = 3 - bz
    tz = tz * tz * bz
    local v00 = Hash(ix, iz, seed)
    local v10 = Hash(ix + 1, iz, seed)
    local v01 = Hash(ix, iz + 1, seed)
    local v11 = Hash(ix + 1, iz + 1, seed)
    local top = v10 - v00
    top = top * tx
    top = v00 + top
    local bottom = v11 - v01
    bottom = bottom * tx
    bottom = v01 + bottom
    local d = bottom - top
    d = d * tz
    return top + d
end

--- Smooth noise in -1..1 at sample (x, z): scale = lattice cell size in samples, octaves 1..4, rough = amplitude share of each further octave (0..1).
local function Noise(x, z, seed, scale, octaves, rough)
    local cell = scale or 8
    if cell < 1 then cell = 1 end
    local count = math.floor(octaves or 2)
    if count < 1 then count = 1 elseif count > 4 then count = 4 end
    rough = rough or 0.5
    if rough < 0 then rough = 0 elseif rough > 1 then rough = 1 end
    local total, amp, norm = 0, 1, 0
    for o = 0, count - 1 do
        if o > 0 and cell < 1 then break end
        local v = ValueNoise(x, z, cell, seed + o * 1013)
        v = v * amp
        total = total + v
        norm = norm + amp
        amp = amp * rough
        cell = cell / 2
    end
    return total / norm
end

--- Whether the height brushes use the native dab (ed_terrain_brush, moho/editor/EdBrush.cpp) when the exe has it. false forces the Lua loop below (tests compare the two).
NativeBrush = true
local NATIVE_MODES = { raise = true, lower = true, plateau = true, flatten = true, smooth = true, noise = true }

local function IsPaint()
    return Brush.mode == 'paint' or Brush.mode == 'erase' or Brush.mode == 'stamp_paint'
end

local strokePaint = false     -- the open stroke paints a texture layer (no height commands on the native stack)
local strokeType = false      -- the open stroke paints terrain types (their own grid and undo entry, see terraintype.lua)
local strokeProp = false      -- the open stroke places or erases props (props.lua)
local strokeDecal = false     -- the open stroke places or erases decals (decals.lua)
local strokeErode = false     -- the open stroke runs the erosion session (erosionbrush.lua)

--- The random extra turn (degrees) of the shape mask in the current / last stroke (the cursor preview draws the mask with it).
function StrokeTurn()
    return strokeTurn
end

--- Test control only: the next BeginStroke gets this stroke id (the noise brush's seed), so two runs of a stroke can be compared.
function SetNextStrokeId(id)
    strokeId = id - 1
end

function BeginStroke()
    strokeId = strokeId + 1
    strokeTurn = Brushes.RandomAngle and (math.random() * 360) or 0
    strokeLevel = nil
    strokeOpen = true
    strokePaint = IsPaint()
    strokeType = (Brush.mode == 'ttype')
    strokeProp = (Brush.mode == 'prop' or Brush.mode == 'prop_erase')
    strokeDecal = (Brush.mode == 'decal' or Brush.mode == 'decal_erase')
    Stamp.BeginStroke()
    if strokeDecal then
        Decals.Mode = (Brush.mode == 'decal_erase') and 'erase' or 'place'
        Decals.BeginStroke()
    elseif strokeProp then
        Props.Mode = (Brush.mode == 'prop_erase') and 'erase' or 'place'
        Props.BeginStroke()
    elseif strokeType then
        TerrainType.BeginStroke()
    elseif strokePaint then
        Strata.BeginStroke()
    else
        ed_cmd_begin('Terrain ' .. Brush.mode)
        strokeErode = EroBrush.Handles(Brush.mode) and EroBrush.Begin()
    end
end

function EndStroke()
    strokeOpen = false
    if strokeDecal then
        strokeDecal = false
        Decals.EndStroke()
    elseif strokeProp then
        strokeProp = false
        Props.EndStroke()
    elseif strokeType then
        strokeType = false
        TerrainType.EndStroke()
    elseif strokePaint then
        strokePaint = false
        Strata.EndStroke()
    else
        if strokeErode then
            strokeErode = false
            local changed, x0, z0, x1, z1 = EroBrush.End()
            if changed > 0 then Sim.Resnap(x0, z0, x1, z1) end
        end
        ed_cmd_end()
    end
    Sim.FlushResnap()       -- the units under the stroke follow the terrain now (the dabs only collected their rectangles, sim.lua ResnapLater)
end

--- Applies the current brush once at world position (cx, cz) and at its symmetry images (symmetry.lua). Returns the number of samples written.
function Dab(cx, cz)
    if not strokeOpen then
        BeginStroke()
    end
    local total = 0
    if Brush.mode == 'stamp' or Brush.mode == 'stamp_paint' then
        cx, cz = Stamp.BeginDab(cx, cz)         -- this dab's random turn, size and position; every symmetry image gets the same
    end
    for slot, p in Symmetry.Points(cx, cz) do
        total = total + DabOne(p.x, p.z, slot, p)
    end
    return total
end

--- One dab at one position; `slot` numbers the symmetry image (the texture brush tracks the distance to its previous dab per image).
function DabOne(cx, cz, slot, image)
    if strokeDecal then
        return Decals.Dab(cx, cz, Brush, slot, image)
    end
    if strokeProp then
        return Props.Dab(cx, cz, Brush, slot, image)
    end
    if strokeType then
        return TerrainType.Dab(cx, cz, Brush)
    end
    if strokePaint then
        if Brush.mode == 'stamp_paint' then
            local brush = Stamp.PaintBrush(Brush)
            local t0 = Perf.Begin()
            local n = Strata.Dab(cx, cz, brush, function(d, rr, softMin, dx, dz) return Stamp.PaintWeight(dx, dz, Brush.radius, image) end, slot)
            Perf.End('stamp.paint.dab', t0)
            return n
        end
        local t0 = Perf.Begin()
        local n = Strata.Dab(cx, cz, Brush, Weight, slot)
        Perf.End(Brushes.Active ~= 'round' and 'strata.dab.shaped' or 'strata.dab', t0)
        return n
    end
    if Brush.mode == 'stamp' then
        local t0 = Perf.Begin()
        local n = Stamp.Dab(cx, cz, Brush, image)
        Perf.End('stamp.dab', t0)
        return n
    end
    if strokeErode then
        -- local erosion: the native session keeps water and sediment between the dabs of the stroke
        local inverted = (Brush.sign or 1) < 0
        if IsKeyDown and IsKeyDown('Shift') then inverted = not inverted end
        local shaped = nil
        if Brushes.Active ~= 'round' then
            shaped = { id = Brushes.Active, turn = strokeTurn }       -- erosionbrush.lua makes the window's weights (natively from the shape mask, else Brushes.Fill)
        end
        local changed, x0, z0, x1, z1 = EroBrush.Dab(cx, cz, Brush, Brush.mode, inverted, shaped)
        if changed > 0 then Sim.ResnapLater(x0, z0, x1, z1) end
        return changed
    end
    local nativeBrush = NativeBrush and NATIVE_MODES[Brush.mode] and rawget(_G, 'ed_terrain_brush')
    local shape, shapeAngle = 0, 0
    if nativeBrush and Brushes.Active ~= 'round' then
        -- a shaped brush: its mask grid is uploaded to the exe once (Brushes.NativeShape), the dab then reads it natively; an exe without the shape natives: the Lua loop
        shape = Brushes.NativeShape(Brushes.Active)
        if shape then
            shapeAngle = (Brushes.Angle or 0) + strokeTurn
        else
            nativeBrush = nil
        end
    end
    if nativeBrush then
        -- One native call does the whole dab (read the window, the brush math, EditHeights on the document); the Lua loop below is the same maths for shaped brushes and an exe without it.
        local inverted = (Brush.sign or 1) < 0
        if IsKeyDown and IsKeyDown('Shift') then inverted = not inverted end
        local level = strokeLevel
        if level == nil and (Brush.mode == 'flatten' or Brush.mode == 'plateau') then
            level = Brush.level
        end
        local t0 = Perf.Begin()
        local changed, x0, z0, x1, z1, used = nativeBrush(cx, cz, Brush.radius, Brush.mode, Brush.strength, inverted and -1 or 1, Brush.falloff, level or -1, strokeId,
                                                         Brush.noiseScale, Brush.noiseOctaves, Brush.noiseRoughness, shape, shapeAngle)
        Perf.End(shape ~= 0 and 'terrain.dab.native.shaped' or 'terrain.dab.native', t0)
        if changed ~= nil then
            if used ~= nil and strokeLevel == nil then
                strokeLevel = used          -- the flatten level of the stroke: the first dab's (Brush.level or the ground under it)
            end
            if changed > 0 then
                Sim.ResnapLater(x0, z0, x1, z1)
            end
            return changed
        end
    end
    local perfStart = Perf.Begin()
    local r = Brush.radius
    local words, x0, z0, x1, z1 = ed_terrain_read_rect(math.floor(cx - r) - 1, math.floor(cz - r) - 1,
                                                       math.ceil(cx + r) + 1, math.ceil(cz + r) + 1)
    if not words or x1 < x0 or z1 < z0 then
        return 0
    end
    local w = x1 - x0 + 1
    local h = z1 - z0 + 1
    local before = {}
    local after = {}
    for i = 1, w * h do
        before[i] = words[i]
        after[i] = words[i]
    end

    local mode = Brush.mode
    local strength = Brush.strength
    -- a negative strength inverts the brush, and so does holding Shift (IsKeyDown is false while the window is in the background)
    local inverted = (Brush.sign or 1) < 0
    if IsKeyDown and IsKeyDown('Shift') then inverted = not inverted end
    local dir = inverted and -1 or 1
    if (mode == 'flatten' or mode == 'plateau') and strokeLevel == nil then
        strokeLevel = Brush.level
        if strokeLevel == nil then
            local cxi = math.min(math.max(math.floor(cx + 0.5), x0), x1)
            local czi = math.min(math.max(math.floor(cz + 0.5), z0), z1)
            strokeLevel = before[(czi - z0) * w + (cxi - x0) + 1] / WORD
        end
    end

    local changed = 0
    -- smooth: the ground under the brush goes toward a blurred copy of itself. The blur widens with the strength (3 x 3 at low strength, up to a quarter of the radius at most 6 samples at the
    -- highest), two passes, so one dab at full strength really flattens the bumps (the old single 3 x 3 average barely moved them); the blur is made once per dab, not once per sample.
    local blurred
    if mode == 'smooth' then
        local kr = 1 + math.floor(math.min(1, math.abs(strength) / 10) * math.max(0, math.min(r * 0.25, 6) - 1) + 0.5)
        blurred = BoxBlur(BoxBlur(before, w, h, kr), w, h, kr)
    end
    if mode == 'erode' then
        -- thermal erosion: ground steeper than the talus slope between a sample and its lowest neighbour slides down; a few passes per dab,
        -- weighted by the brush and scaled by the strength
        local talus = 0.9 * WORD
        local rate = math.min(1, strength * 0.25)
        for pass = 1, 6 do
            for z = z0 + 1, z1 - 1 do
                for x = x0 + 1, x1 - 1 do
                    local dx = x - cx
                    local dz = z - cz
                    local weight = Weight(math.sqrt(dx * dx + dz * dz), r, nil, dx, dz)
                    if weight > 0 then
                        local i = (z - z0) * w + (x - x0) + 1
                        local here = after[i]
                        local lowest, lowestI = here, nil
                        for oz = -1, 1 do
                            for ox = -1, 1 do
                                if ox ~= 0 or oz ~= 0 then
                                    local j = (z + oz - z0) * w + (x + ox - x0) + 1
                                    if after[j] < lowest then lowest, lowestI = after[j], j end
                                end
                            end
                        end
                        if lowestI and here - lowest > talus then
                            local move = (here - lowest - talus) * 0.5 * rate * weight
                            after[i] = here - move
                            after[lowestI] = after[lowestI] + move
                        end
                    end
                end
            end
        end
        for i = 1, w * h do
            local v = math.floor(after[i] + 0.5)
            if v < 0 then v = 0 elseif v > 65535 then v = 65535 end
            after[i] = v
            if v ~= before[i] then changed = changed + 1 end
        end
    else
    for z = z0, z1 do
        for x = x0, x1 do
            local dx = x - cx
            local dz = z - cz
            local weight = Weight(math.sqrt(dx * dx + dz * dz), r, nil, dx, dz)
            if weight > 0 then
                local i = (z - z0) * w + (x - x0) + 1
                local value = before[i]
                if mode == 'raise' then
                    value = value + dir * strength * weight * WORD
                elseif mode == 'lower' then
                    value = value - dir * strength * weight * WORD
                elseif mode == 'plateau' then
                    -- a plateau: the ground goes to the level in one go inside the brush (the falloff shapes the shoulder); inverted: away from it
                    local k = math.min(1, strength * 0.5 * weight) * dir
                    value = value + (strokeLevel * WORD - value) * k
                elseif mode == 'flatten' then
                    -- inverted: away from the level instead of toward it
                    local k = math.min(1, strength * 0.2 * weight) * dir
                    value = value + (strokeLevel * WORD - value) * k
                elseif mode == 'smooth' then
                    -- inverted: sharpen (away from the blurred ground)
                    local k = math.min(1, strength * 0.2 * weight) * dir
                    value = value + (blurred[i] - value) * k
                elseif mode == 'noise' then
                    value = value + dir * Noise(x, z, strokeId, Brush.noiseScale, Brush.noiseOctaves, Brush.noiseRoughness) * strength * weight * WORD
                end
                value = math.floor(value + 0.5)
                if value < 0 then value = 0 end
                if value > 65535 then value = 65535 end
                if value ~= before[i] then
                    after[i] = value
                    changed = changed + 1
                end
            end
        end
    end
    end

    Perf.End(Brushes.Active ~= 'round' and 'terrain.dab.lua.shaped' or 'terrain.dab.lua', perfStart)
    if changed == 0 then
        return 0
    end
    if ed_doc_height_write(x0, z0, x1, z1, after) == 0 then
        return 0
    end
    Sim.ResnapLater(x0, z0, x1, z1)
    return changed
end

--- Convenience: a straight stroke from (ax, az) to (bx, bz), one dab every `spacing` units (default radius / 3).
function Line(ax, az, bx, bz, spacing)
    spacing = spacing or math.max(1, Brush.radius / 3)
    local dx = bx - ax
    local dz = bz - az
    local length = math.sqrt(dx * dx + dz * dz)
    local steps = math.max(1, math.ceil(length / spacing))
    BeginStroke()
    local total = 0
    for s = 0, steps do
        local f = s / steps
        total = total + Dab(ax + dx * f, az + dz * f)
    end
    EndStroke()
    return total
end

--- Undoes the last stroke. Returns true when something was undone.
function Undo()
    strokeOpen = false
    local ok, x0, z0, x1, z1 = ed_cmd_undo()
    if not ok then
        return false
    end
    Sim.Resnap(x0, z0, x1, z1)
    return true
end

--- Redoes the last undone stroke.
function Redo()
    strokeOpen = false
    local ok, x0, z0, x1, z1 = ed_cmd_redo()
    if not ok then
        return false
    end
    Sim.Resnap(x0, z0, x1, z1)
    return true
end

--- Number of undoable and redoable steps (a stroke is one step, however many dabs it wrote).
function UndoDepth()
    local undo, redo = ed_cmd_depth()
    return undo, redo
end

function ClearHistory()
    ed_cmd_clear()
end

--- Flattens an inclusive sample rectangle to `height` (world units) and re-snaps what stands on it.
function SetRect(x0, z0, x1, z1, height)
    local words, ax0, az0, ax1, az1 = ed_terrain_read_rect(x0, z0, x1, z1)
    if not words or ax1 < ax0 or az1 < az0 then
        return 0
    end
    local word = math.floor(height * WORD + 0.5)
    local count = (ax1 - ax0 + 1) * (az1 - az0 + 1)
    for i = 1, count do
        words[i] = word
    end
    ed_cmd_begin('Set height')
    local n = ed_doc_height_write(ax0, az0, ax1, az1, words)
    ed_cmd_end()
    if n > 0 then
        Sim.Resnap(ax0, az0, ax1, az1)
    end
    return n
end

--- Writes a height checksum over a rectangle (for tests): sum of words, count.
function Checksum(x0, z0, x1, z1)
    local words, ax0, az0, ax1, az1 = ed_terrain_read_rect(x0, z0, x1, z1)
    if not words then
        return nil
    end
    local sum = 0
    local n = (ax1 - ax0 + 1) * (az1 - az0 + 1)
    for i = 1, n do
        sum = sum + words[i]
    end
    return sum, n
end
