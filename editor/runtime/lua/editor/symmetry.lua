-- Symmetry shared by every tool that places something on the map: brushes (height and texture), markers, areas.
--
--   Mode        'off', 'mirror_x' (left / right, mirror line x = centre), 'mirror_z' (top / bottom), 'mirror_xz' (both: four copies),
--               'rot2' (180 degrees), 'rot4' (90 degree steps), 'diag' (mirror across the diagonal through the centre), 'diag_both' (both diagonals)
--   Centre      the symmetry centre in world units (default: the middle of the map)
--
--   Points(x, z)    -> list of { x, z, yaw }  the point itself first, then its images (images closer than half a unit to an earlier one are dropped,
--                      so a dab on the axis is not applied twice). `yaw` is the change of a heading (radians) the image needs: rotations add their angle,
--                      mirrors reflect the heading (see Heading).
--   Heading(yaw, p) -> the heading of an object placed at image `p` of an object with heading `yaw`
--   Rect(x0, z0, x1, z1) -> list of { x0, z0, x1, z1 } the images of a rectangle (axis aligned for every mode)
--   Mirrors / Describe / Count          for the panels
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

Modes = {
    { id = 'off',       label = 'Off' },
    { id = 'mirror_x',  label = 'Mirror left / right' },
    { id = 'mirror_z',  label = 'Mirror top / bottom' },
    { id = 'mirror_xz', label = 'Mirror both (4)' },
    { id = 'rot2',      label = 'Rotate 180' },
    { id = 'rot4',      label = 'Rotate 90 (4)' },
    { id = 'diag',      label = 'Diagonal mirror' },
    { id = 'diag_both', label = 'Both diagonals (4)' },
}

Mode = 'off'
CenterX = false      -- false = the middle of the map
CenterZ = false

local PI = 3.14159265

--- The centre in world units.
function Centre()
    local size = ed_terrain_info and ed_terrain_info() or 256
    local half = ((size or 256) - 1) / 2
    return CenterX or half, CenterZ or half
end

local function Add(list, x, z, yawKind, angle)
    for _, q in list do
        local dx, dz = q.x - x, q.z - z
        if dx * dx + dz * dz < 0.25 then return end
    end
    table.insert(list, { x = x, z = z, kind = yawKind, angle = angle })
end

--- The point and its images.
function Points(x, z)
    local list = { { x = x, z = z, kind = 'id', angle = 0 } }
    if Mode == 'off' then return list end
    local cx, cz = Centre()
    local dx, dz = x - cx, z - cz
    if Mode == 'mirror_x' then
        Add(list, cx - dx, z, 'mx', 0)
    elseif Mode == 'mirror_z' then
        Add(list, x, cz - dz, 'mz', 0)
    elseif Mode == 'mirror_xz' then
        Add(list, cx - dx, z, 'mx', 0)
        Add(list, x, cz - dz, 'mz', 0)
        Add(list, cx - dx, cz - dz, 'rot', PI)
    elseif Mode == 'rot2' then
        Add(list, cx - dx, cz - dz, 'rot', PI)
    elseif Mode == 'rot4' then
        Add(list, cx - dz, cz + dx, 'rot', -PI / 2)
        Add(list, cx - dx, cz - dz, 'rot', PI)
        Add(list, cx + dz, cz - dx, 'rot', PI / 2)
    elseif Mode == 'diag' then
        Add(list, cx + dz, cz + dx, 'dg', 0)
    elseif Mode == 'diag_both' then
        Add(list, cx + dz, cz + dx, 'dg', 0)          -- across the diagonal x = z
        Add(list, cx - dz, cz - dx, 'da', 0)          -- across the other diagonal
        Add(list, cx - dx, cz - dz, 'rot', PI)
    end
    return list
end

--- Heading (radians, rotation about the vertical axis as the engine stores it) of the image `p` of an object with heading `yaw`.
function Heading(yaw, p)
    local k = p.kind
    if k == 'id' then return yaw end
    if k == 'rot' then return yaw + p.angle end
    -- a heading h points along (sin h, cos h) in (x, z)
    if k == 'mx' then return -yaw end            -- a mirror across x = const: heading h -> -h
    if k == 'mz' then return PI - yaw end        -- across z = const
    if k == 'dg' then return PI / 2 - yaw end    -- across the diagonal x = z
    if k == 'da' then return -PI / 2 - yaw end   -- across x = -z
    return yaw
end

--- Images of an axis aligned rectangle (every mode maps such a rectangle onto another one).
function Rect(x0, z0, x1, z1)
    local out = {}
    local a = Points(x0, z0)
    local b = Points(x1, z1)
    for i = 1, table.getn(a) do
        local p, q = a[i], b[i]
        if p and q then
            table.insert(out, { math.min(p.x, q.x), math.min(p.z, q.z), math.max(p.x, q.x), math.max(p.z, q.z) })
        end
    end
    return out
end

function Count()
    if Mode == 'off' then return 1 end
    if Mode == 'mirror_x' or Mode == 'mirror_z' or Mode == 'rot2' or Mode == 'diag' then return 2 end
    return 4
end

function SetMode(id)
    for _, m in Modes do
        if m.id == id then Mode = id return true end
    end
    return false
end

--- Line segments of the symmetry axes for the overlay: a list of { x0, z0, x1, z1 } across the whole map.
function Axes()
    local size = (ed_terrain_info and ed_terrain_info()) or 256
    local max = (size or 256) - 1
    local cx, cz = Centre()
    local lines = {}
    if Mode == 'mirror_x' or Mode == 'mirror_xz' then table.insert(lines, { cx, 0, cx, max }) end
    if Mode == 'mirror_z' or Mode == 'mirror_xz' then table.insert(lines, { 0, cz, max, cz }) end
    if Mode == 'diag' or Mode == 'diag_both' then table.insert(lines, { cx - max, cz - max, cx + max, cz + max }) end
    if Mode == 'diag_both' then table.insert(lines, { cx - max, cz + max, cx + max, cz - max }) end
    if Mode == 'rot2' or Mode == 'rot4' then
        -- a small cross marks the point the copies turn about
        table.insert(lines, { cx - 6, cz, cx + 6, cz })
        table.insert(lines, { cx, cz - 6, cx, cz + 6 })
    end
    return lines
end

-- ---- counterparts of a moved selection ---------------------------------------------------------------------------------------------------------
-- With symmetry on, moving or turning a selected object also moves the object that stands at its mirror image (if there is one): the mirror candidate follows by the
-- mirrored move and turn.

--- items: the selected objects, pos(o) -> x, z, candidates: every object that may be a counterpart, same(a, b): may b be the counterpart of a, selected(c): already selected.
--- -> nil (symmetry off / no counterparts) or a list of groups { key, kind, refX, refZ, targets = { candidate, ... } }; one group per image of the symmetry.
function Plan(items, pos, candidates, same, selected)
    if Mode == 'off' then return nil end
    local groups, byKey = {}, {}
    for _, it in items do
        local x, z = pos(it)
        for _, img in Points(x, z) do
            if img.kind ~= 'id' then
                for _, c in candidates do
                    if not selected(c) and same(it, c) then
                        local cx, cz = pos(c)
                        local ex, ez = cx - img.x, cz - img.z
                        if ex * ex + ez * ez <= 2.25 then
                            local key = img.kind .. ':' .. string.format('%.3f', img.angle or 0)
                            local g = byKey[key]
                            if not g then
                                g = { key = key, kind = img.kind, refX = x, refZ = z, targets = {}, used = {} }
                                byKey[key] = g
                                table.insert(groups, g)
                            end
                            if not g.used[c] then
                                g.used[c] = true
                                table.insert(g.targets, c)
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    if table.getn(groups) == 0 then return nil end
    return groups
end

local function ImageOf(key, x, z)
    for _, p in Points(x, z) do
        if p.kind .. ':' .. string.format('%.3f', p.angle or 0) == key then return p end
    end
    return nil
end

--- The move (dx, dz) of the selected object at (x, z) as its image `key` sees it.
function ImageDelta(key, x, z, dx, dz)
    local a, b = ImageOf(key, x, z), ImageOf(key, x + dx, z + dz)
    if not (a and b) then return 0, 0 end
    return b.x - a.x, b.z - a.z
end

--- A turn of `deg` degrees as the image sees it: rotations turn the same way, mirrors the other way.
function ImageTurn(kind, deg)
    if kind == 'rot' then return deg end
    return -deg
end
