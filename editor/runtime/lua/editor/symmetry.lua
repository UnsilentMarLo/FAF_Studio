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
--   Detect(data) / AutoDetect(force)    which mode (and centre) a map is symmetric under, from its start positions, resource markers and a coarse sample of the heights
--                                       (see "detection" below); Map.Load calls AutoDetect, the Symmetry panel's "Detect again" button AutoDetect(true)
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
Manual = false       -- the user chose a mode (SetMode) since the last detection: AutoDetect on a map load leaves it alone
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

--- The images of the point (x, z) under `mode` about the centre (cx, cz): the point itself first. Points uses the current mode and centre; the detection tries the others.
function PointsFor(mode, cx, cz, x, z)
    local list = { { x = x, z = z, kind = 'id', angle = 0 } }
    if mode == 'off' then return list end
    local dx, dz = x - cx, z - cz
    if mode == 'mirror_x' then
        Add(list, cx - dx, z, 'mx', 0)
    elseif mode == 'mirror_z' then
        Add(list, x, cz - dz, 'mz', 0)
    elseif mode == 'mirror_xz' then
        Add(list, cx - dx, z, 'mx', 0)
        Add(list, x, cz - dz, 'mz', 0)
        Add(list, cx - dx, cz - dz, 'rot', PI)
    elseif mode == 'rot2' then
        Add(list, cx - dx, cz - dz, 'rot', PI)
    elseif mode == 'rot4' then
        Add(list, cx - dz, cz + dx, 'rot', -PI / 2)
        Add(list, cx - dx, cz - dz, 'rot', PI)
        Add(list, cx + dz, cz - dx, 'rot', PI / 2)
    elseif mode == 'diag' then
        Add(list, cx + dz, cz + dx, 'dg', 0)
    elseif mode == 'diag_both' then
        Add(list, cx + dz, cz + dx, 'dg', 0)          -- across the diagonal x = z
        Add(list, cx - dz, cz - dx, 'da', 0)          -- across the other diagonal
        Add(list, cx - dx, cz - dz, 'rot', PI)
    end
    return list
end

--- The point and its images.
function Points(x, z)
    if Mode == 'off' then return { { x = x, z = z, kind = 'id', angle = 0 } } end
    local cx, cz = Centre()
    return PointsFor(Mode, cx, cz, x, z)
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
        if m.id == id then
            Mode = id
            Manual = true           -- the user's choice: loading a map does not replace it (AutoDetect)
            return true
        end
    end
    return false
end

--- The label of a mode id.
function LabelOf(id)
    for _, m in Modes do
        if m.id == id then return m.label end
    end
    return tostring(id)
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


-- ---- detection ------------------------------------------------------------------------------------------------------------------------------------
-- Which of the modes a map is symmetric under. Evidence:
--   * the markers: every start position (ARMY_n) and resource marker (Mass, Hydrocarbon) is mapped by each image of the mode; the image must land on another marker of the same kind
--     (within a tolerance of a few units). A marker that lies on the axis maps onto itself: that proves nothing and counts neither way. Every start position must find its partner;
--     a quarter of the resource markers may be missing.
--   * the heights: a grid of GRID x GRID samples (about a thousand calls of ed_terrain_get, not the whole map) is compared with its mirrored / rotated copy: the mean difference,
--     relative to the spread of the heights, is small on a symmetric map and about 1.4 (or more) on any other. A flat map says nothing.
-- A small offset of the symmetry axis (mirror and 180 degree modes) is measured from the matched markers and applied to the centre.
-- Several modes may fit (a map symmetric in both directions is also symmetric in each one): the mode with the most matched markers wins, and among equals the larger group if the
-- heights confirm it (and the smaller one if the heights are flat).
-- The detection never changes the mode by itself: AutoDetect does that.

Detected = false         -- the last detection: { mode, cx, cz, text, applied } or { text } when nothing fitted; false before the first one

local DETECT_MODES = { 'mirror_x', 'mirror_z', 'mirror_xz', 'rot2', 'rot4', 'diag', 'diag_both' }
local NEEDS_SQUARE = { rot4 = true, diag = true, diag_both = true }
local GROUP = { mirror_x = 2, mirror_z = 2, mirror_xz = 4, rot2 = 2, rot4 = 4, diag = 2, diag_both = 4 }
local GRID = 32                  -- height samples per side (GRID + 1 points)
local FLAT = 0.25                -- mean absolute deviation of the heights (world units) under which the map counts as flat
local HEIGHT_FIT = 0.35          -- height difference relative to the spread: at most this with markers that fit
local HEIGHT_ALONE = 0.15        -- ... and at most this when the heights are the only evidence
local RESOURCE_MISS = 0.25       -- the share of resource markers that may lack a partner
local MIN_STARTS = 2

--- Marker evidence of `mode` about (cx, cz). items: list of { x, z, kind } (kind 1 = start, 2 = resource markers by type string). Returns a table of counts and the mean offsets
--- (how far the partners lie from the exact images) for the centre refinement.
local function MarkerEvidence(items, mode, cx, cz, tol)
    local ev = { startTested = 0, startMatched = 0, startMissed = 0, resTested = 0, resMatched = 0, resMissed = 0, sumX = 0, nX = 0, sumZ = 0, nZ = 0 }
    local tol2 = tol * tol
    for i, p in items do
        local isStart = (p.kind == 'start')
        for k, q in PointsFor(mode, cx, cz, p.x, p.z) do
            if q.kind ~= 'id' then
                local best, bestD = nil, tol2 + 1
                for j, o in items do
                    if o.kind == p.kind then
                        local dx, dz = o.x - q.x, o.z - q.z
                        local d = dx * dx + dz * dz
                        if d < bestD then best, bestD = j, d end
                    end
                end
                if isStart then ev.startTested = ev.startTested + 1 else ev.resTested = ev.resTested + 1 end
                if not best or bestD > tol2 then
                    if isStart then ev.startMissed = ev.startMissed + 1 else ev.resMissed = ev.resMissed + 1 end
                elseif best ~= i then
                    if isStart then ev.startMatched = ev.startMatched + 1 else ev.resMatched = ev.resMatched + 1 end
                    local o = items[best]
                    if q.kind == 'mx' or q.kind == 'rot' then ev.sumX = ev.sumX + (o.x - q.x) ev.nX = ev.nX + 1 end
                    if q.kind == 'mz' or q.kind == 'rot' then ev.sumZ = ev.sumZ + (o.z - q.z) ev.nZ = ev.nZ + 1 end
                end
                -- (best == i: the image lies on the marker itself, a marker on the axis: no evidence)
            end
        end
    end
    return ev
end

--- How far the heights differ from their image under `mode` about (cx, cz): mean |h(p) - h(image)| over the sample grid, in world units, and the number of comparisons.
local function HeightDifference(points, sample, mode, cx, cz, lastX, lastZ)
    local sum, n = 0, 0
    for _, p in points do
        for k, q in PointsFor(mode, cx, cz, p.x, p.z) do
            if q.kind ~= 'id' and q.x >= -0.5 and q.z >= -0.5 and q.x <= lastX + 0.5 and q.z <= lastZ + 0.5 then
                local a, b = p.h, sample(q.x, q.z)
                if a and b then
                    sum = sum + math.abs(a - b)
                    n = n + 1
                end
            end
        end
    end
    if n == 0 then return nil, 0 end
    return sum / n, n
end

--- data = { w, h (samples of the height map), starts = { { x, z }, ... }, marks = { { x, z, type }, ... }, height = function(x, z) -> world height or nil }.
--- Returns the best fit { mode, cx, cz, matches, ratio, text } or nil, then the list of every candidate that was tried (for tests and the panel's tip).
function Detect(data)
    local w, h = data.w, data.h
    if not w or not h or w < 9 or h < 9 then return nil, {} end
    local lastX, lastZ = w - 1, h - 1
    local tol = math.max(3.5, math.max(lastX, lastZ) * 0.012)
    local items = {}
    local nStarts = 0
    for _, s in data.starts or {} do
        table.insert(items, { x = s[1], z = s[2], kind = 'start' })
        nStarts = nStarts + 1
    end
    for _, m in data.marks or {} do
        table.insert(items, { x = m[1], z = m[2], kind = m[3] or 'mass' })
    end
    -- the sample grid of the heights, read once (the images of grid points mostly land on grid points: the memo makes the repeated reads free)
    local memo = {}
    local function Sample(x, z)
        local ix, iz = math.floor(x + 0.5), math.floor(z + 0.5)
        if ix < 0 then ix = 0 elseif ix > lastX then ix = lastX end
        if iz < 0 then iz = 0 elseif iz > lastZ then iz = lastZ end
        local key = iz * (lastX + 1) + ix
        local v = memo[key]
        if v == nil then
            v = data.height(ix, iz) or false
            memo[key] = v
        end
        return v or nil
    end
    local points = {}
    local sum, count = 0, 0
    if data.height then
        for j = 0, GRID do
            for i = 0, GRID do
                local x, z = lastX * i / GRID, lastZ * j / GRID
                local v = Sample(x, z)
                if v then
                    table.insert(points, { x = x, z = z, h = v })
                    sum = sum + v
                    count = count + 1
                end
            end
        end
    end
    local spread, flat = 0, true
    if count > 0 then
        local mean = sum / count
        for _, p in points do spread = spread + math.abs(p.h - mean) end
        spread = spread / count
        flat = spread < FLAT
    end

    local candidates = {}
    local function Try(mode, cx, cz)
        local ev = MarkerEvidence(items, mode, cx, cz, tol)
        local c = { mode = mode, cx = cx, cz = cz, ev = ev, matches = ev.startMatched + ev.resMatched, group = GROUP[mode] }
        c.resFrac = (ev.resTested > 0) and (ev.resMissed / ev.resTested) or 0
        c.startsOK = (nStarts >= MIN_STARTS) and ev.startMissed == 0
        c.evidence = c.startsOK and ev.startMatched >= 1
        -- the heights only when the markers do not rule the mode out
        local ruledOut = (nStarts >= MIN_STARTS and ev.startMissed > 0) or c.resFrac > 0.5 and ev.resTested >= 4
        if not ruledOut and not flat and count > 0 then
            local diff, n = HeightDifference(points, Sample, mode, cx, cz, lastX, lastZ)
            if diff and n >= 20 then c.ratio = diff / spread end
        end
        if ruledOut then
            c.ok = false
        elseif c.evidence then
            c.ok = c.resFrac <= RESOURCE_MISS and (c.ratio == nil or c.ratio <= HEIGHT_FIT)
        else
            c.ok = (c.ratio ~= nil and c.ratio <= HEIGHT_ALONE) and (ev.resTested < 4 or c.resFrac <= RESOURCE_MISS)
        end
        return c
    end

    local best
    local cx0, cz0 = lastX / 2, lastZ / 2
    for _, mode in DETECT_MODES do
        if not (NEEDS_SQUARE[mode] and w ~= h) then
            local c = Try(mode, cx0, cz0)
            -- a symmetry axis that is a little off the middle of the map: measure it from the partners and try again
            local refinable = (mode == 'mirror_x' or mode == 'mirror_z' or mode == 'mirror_xz' or mode == 'rot2')
            if refinable and c.ev.startMatched + c.ev.resMatched >= 2 then
                local dx = (c.ev.nX > 0 and mode ~= 'mirror_z') and c.ev.sumX / c.ev.nX / 2 or 0
                local dz = (c.ev.nZ > 0 and mode ~= 'mirror_x') and c.ev.sumZ / c.ev.nZ / 2 or 0
                if math.abs(dx) >= 0.3 or math.abs(dz) >= 0.3 then
                    local limit = tol * 3
                    dx, dz = math.max(-limit, math.min(limit, dx)), math.max(-limit, math.min(limit, dz))
                    local r = Try(mode, cx0 + dx, cz0 + dz)
                    if r.ok and (not c.ok or (r.ev.startMissed + r.ev.resMissed) <= (c.ev.startMissed + c.ev.resMissed)) then c = r end
                end
            end
            table.insert(candidates, c)
            if c.ok then
                local better = false
                if not best then
                    better = true
                elseif c.matches ~= best.matches then
                    better = c.matches > best.matches
                elseif flat then
                    better = c.group < best.group
                elseif c.group ~= best.group then
                    better = c.group > best.group
                else
                    better = (c.ratio or 9) < (best.ratio or 9)
                end
                if better then best = c end
            end
        end
    end
    if not best then return nil, candidates end
    local parts = {}
    if best.ev.startTested > 0 then table.insert(parts, string.format('%d start positions fit', nStarts)) end
    if best.ev.resMatched > 0 then table.insert(parts, string.format('%d resource markers match', best.ev.resMatched)) end
    if best.ratio then table.insert(parts, string.format('heights differ by %d%% of their spread', math.floor(best.ratio * 100 + 0.5))) end
    best.text = LabelOf(best.mode) .. (table.getn(parts) > 0 and (' (' .. table.concat(parts, ', ') .. ')') or '')
    return best, candidates
end

--- The open map as the data of Detect, or nil without a map document / terrain.
function Collect()
    local Map = import('/lua/editor/map.lua')
    if not Map.Doc or not ed_terrain_info or not ed_terrain_get then return nil end
    local w, h = ed_terrain_info()
    if not w then return nil end
    local data = { w = w, h = h or w, starts = {}, marks = {}, height = function(x, z) return ed_terrain_get(x, z) end }
    local ok, markers = pcall(function() return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers end)
    if not ok or not markers then return data end
    local names = {}
    for name, _ in markers do table.insert(names, name) end
    table.sort(names)
    for _, name in names do
        local m = markers[name]
        if m and m.position then
            if string.find(name, '^ARMY_%d+$') then
                table.insert(data.starts, { m.position[1], m.position[3] })
            elseif m.type == 'Mass' or m.type == 'Hydrocarbon' then
                table.insert(data.marks, { m.position[1], m.position[3], m.type })
            end
        end
    end
    return data
end

--- Detects the symmetry of the open map and sets the mode and centre. Called by Map.Load (the mode the user chose before stays: `force` nil) and by the panel's "Detect again" (force).
--- Returns the mode found or nil. Leaves `Detected` for the panel; shows "Symmetry detected: <mode>" in the status line.
function AutoDetect(force)
    local data = Collect()
    if not data then return nil end
    local best = Detect(data)
    local apply = force or not Manual
    if best then
        Detected = { mode = best.mode, cx = best.cx, cz = best.cz, text = best.text, applied = apply and true or false }
        if apply then
            Mode = best.mode
            local size = (ed_terrain_info and ed_terrain_info()) or data.w
            local dx, dz = (size - 1) / 2, (size - 1) / 2         -- what Centre() gives without an override
            CenterX = (math.abs(best.cx - dx) > 0.01) and best.cx or false
            CenterZ = (math.abs(best.cz - dz) > 0.01) and best.cz or false
            Manual = false
            pcall(function() import('/lua/editor/ui.lua').Say('Symmetry detected: ' .. LabelOf(best.mode)) end)
        end
        return best.mode
    end
    Detected = { text = 'No symmetry found.', applied = false }
    if not force and not Manual then
        Mode = 'off'
        CenterX, CenterZ = false, false
    end
    if force then pcall(function() import('/lua/editor/ui.lua').Say('No symmetry found') end) end
    return nil
end
