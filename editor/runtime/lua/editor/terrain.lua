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
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    local width = math.min(radius, math.max(radius * f, softMin or 1))
    local inner = radius - width
    if distance <= inner then
        return 1
    end
    return 0.5 * (1 + math.cos(PI * (distance - inner) / width))
end

--- The weight a dab gives a height sample `distance` world units from the brush centre (what the preview draws).
function BrushWeight(distance, radius, dx, dz)
    if dx and (Brush.mode == 'stamp' or Brush.mode == 'stamp_paint') then
        return Stamp.Weight(dx, dz, radius)               -- the stamp's own picture (rotation and size from its settings)
    end
    return Weight(distance, radius, nil, dx, dz)
end

-- tiny deterministic hash noise in -1..1 (the sim is not involved, but edits should be reproducible)
local function Noise(x, z, seed)
    local n = x * 374761393 + z * 668265263 + seed * 2147483
    n = math.mod(n, 2147483647)
    n = math.mod(n * 1103515245 + 12345, 2147483647)
    return (math.mod(n, 20001) / 10000) - 1
end

local function IsPaint()
    return Brush.mode == 'paint' or Brush.mode == 'erase' or Brush.mode == 'stamp_paint'
end

local strokePaint = false     -- the open stroke paints a texture layer (no height commands on the native stack)
local strokeType = false      -- the open stroke paints terrain types (their own grid and undo entry, see terraintype.lua)
local strokeProp = false      -- the open stroke places or erases props (props.lua)
local strokeDecal = false     -- the open stroke places or erases decals (decals.lua)
local strokeErode = false     -- the open stroke runs the erosion session (erosionbrush.lua)

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
            return Strata.Dab(cx, cz, brush, function(d, rr, softMin, dx, dz) return Stamp.PaintWeight(dx, dz, Brush.radius, image) end, slot)
        end
        return Strata.Dab(cx, cz, Brush, Weight, slot)
    end
    if Brush.mode == 'stamp' then
        return Stamp.Dab(cx, cz, Brush, image)
    end
    if strokeErode then
        -- local erosion: the native session keeps water and sediment between the dabs of the stroke
        local inverted = (Brush.sign or 1) < 0
        if IsKeyDown and IsKeyDown('Shift') then inverted = not inverted end
        local shaped = nil
        if Brushes.Active ~= 'round' then
            shaped = function(dx, dz) return Weight(math.sqrt(dx * dx + dz * dz), Brush.radius, nil, dx, dz) end
        end
        local changed, x0, z0, x1, z1 = EroBrush.Dab(cx, cz, Brush, Brush.mode, inverted, shaped)
        if changed > 0 then Sim.Resnap(x0, z0, x1, z1) end
        return changed
    end
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
                    value = value + dir * Noise(x, z, strokeId) * strength * weight * WORD
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

    if changed == 0 then
        return 0
    end
    if ed_doc_height_write(x0, z0, x1, z1, after) == 0 then
        return 0
    end
    Sim.Resnap(x0, z0, x1, z1)
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
