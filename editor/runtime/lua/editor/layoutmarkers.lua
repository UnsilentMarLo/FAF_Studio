-- The start and resource generator (docs/projects/editor/MAP_LAYOUT.md): makes the start positions of a map (from the start markers that are there, from the bases drawn in the map layout, or
-- from a pattern: around the map, in the corners, on two sides, in a line) and places Mass and Hydrocarbon markers around each of them by SHAPE and DISTANCE:
--
--   ring      evenly around the start, the distances alternating between the nearest and the farthest
--   arc       a fan of the given width, facing the middle of the map (or away from it)
--   cluster   a blob, a sunflower of points, at the middle of the distance range in the facing direction
--   line      a row across the facing direction
--   pairs     ring positions with two markers side by side
--
-- Every start gets the same shape turned to face the middle of the map, so symmetric starts get symmetric resources. Positions are checked against the ground (land, not under water, a slope the
-- limit allows, inside the playable area) and against every other marker (the spacing); a spot that does not pass is searched around (a few angles and distances) and skipped when nothing fits.
-- Extra mass per start (further out, the expansions) and a cluster in the middle of the map use the same shapes. The result is first a PLAN (Plan: shown on the layout canvas) and then markers
-- (Place: one undo step; the markers made before are removed first when `clear` is on).
--
--   Settings               the choices of the panel
--   Starts() -> { { x, z } }        the start positions the current settings give
--   Plan() -> plan         { starts = { { x, z } }, items = { { kind, x, z, start, group } }, failed = n, text }  nothing is placed
--   Place() -> counts | nil, message     writes the starts (when they are not the existing ones) and the resources into the map
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local History = import('/lua/editor/history.lua')
local Layout = import('/lua/editor/layout.lua')

local PI = 3.14159265

StartModes = { 'existing', 'base', 'pattern' }
Patterns = { 'ring', 'corners', 'sides', 'line' }
Shapes = { 'ring', 'arc', 'cluster', 'line', 'pairs' }

Settings = {
    starts = 'pattern', pattern = 'ring', count = 4, radius = 0.68, rotation = 0, replaceStarts = true,
    mass = 6, massMin = 16, massMax = 30, massShape = 'ring', arc = 160, facing = 'centre',
    hydro = 1, hydroMin = 36, hydroMax = 48,
    extra = 4, extraMin = 70, extraMax = 110, extraShape = 'arc',
    middle = 4, middleRadius = 40,
    spacing = 7, maxSlope = 30, seed = 1, clear = true,
}

Plan_ = false

--- The playable area as its middle and half sizes (cx, cz, hx, hz): the starts, the middle and the facing of the resources are measured from it (a map that is not square has an area that is not square).
local function Frame()
    local x0, z0, x1, z1 = Layout.Area()
    return (x0 + x1) / 2, (z0 + z1) / 2, (x1 - x0) / 2, (z1 - z0) / 2
end

-- a small random generator whose numbers stay below 2^24 (the numbers of the Lua here are 32 bit floats)
local function Rng(seed)
    local s = math.mod(math.floor(seed) * 7919 + 13, 65537)
    return function()
        s = math.mod(s * 75 + 74, 65537)
        return s / 65537
    end
end

local function Ground(x, z)
    local h = ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5))
    return h or 0
end

local function SlopeDeg(x, z)
    local hx = (Ground(x + 1, z) - Ground(x - 1, z)) / 2
    local hz = (Ground(x, z + 1) - Ground(x, z - 1)) / 2
    return math.deg(math.atan(math.sqrt(hx * hx + hz * hz)))
end

local function WaterLevel()
    local World = import('/lua/editor/world.lua')
    if World.Value('water_on') ~= 0 then return World.Value('water_elev') end
    return -1000
end

-- ---- the starts ----------------------------------------------------------------------------------------------------------------------------------------

--- The start positions the settings give. 'existing': the ARMY_<n> markers of the map; 'base': the centres of the bases drawn in the layout; 'pattern': count points by the pattern.
function Starts()
    local s = Settings
    local mx, mz, hx, hz = Frame()
    local list = {}
    if s.starts == 'existing' then
        for _, name in import('/lua/editor/armies.lua').Names() do
            local m = Map.GetMarker(name)
            if m and m.position then table.insert(list, { x = m.position[1], z = m.position[3], name = name }) end
        end
    elseif s.starts == 'base' then
        for _, c in Layout.BaseCentres() do table.insert(list, { x = c.x, z = c.z }) end
    else
        local n = math.max(1, math.floor(s.count))
        local rot = math.rad(s.rotation)
        -- the pattern is drawn on the unit square / circle and stretched over the playable area, so a long map gets starts spread along it
        local rx, rz = s.radius * hx, s.radius * hz
        local function Put(u, v) table.insert(list, { x = mx + rx * u, z = mz + rz * v }) end
        if s.pattern == 'corners' then
            local corners = { { -1, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 } }
            for k = 1, math.min(n, 4) do
                local c = corners[k]
                local u, v = c[1] * 0.82, c[2] * 0.82
                Put(u * math.cos(rot) - v * math.sin(rot), u * math.sin(rot) + v * math.cos(rot))
            end
        elseif s.pattern == 'sides' then
            for k = 1, math.min(n, 2) do
                local a = rot + (k - 1) * PI
                Put(math.cos(a), math.sin(a))
            end
        elseif s.pattern == 'line' then
            for k = 1, n do
                local off = (k - 1 - (n - 1) / 2) * (2 / math.max(1, n - 1))
                if n == 1 then off = 0 end
                Put(off * math.cos(rot), off * math.sin(rot))
            end
        else
            for k = 1, n do
                local a = rot + (k - 1) * 2 * PI / n - PI / 2
                Put(math.cos(a), math.sin(a))
            end
        end
    end
    return list
end

-- ---- the shapes ---------------------------------------------------------------------------------------------------------------------------------------

--- Ideal positions of `count` markers around the start (sx, sz): shape, the facing angle (towards the middle of the map when facing = 'centre'), the distance range, the arc width (radians),
--- the spacing. Returns { { x, z, group } } (group: the pair number of the 'pairs' shape).
local function Shape(shape, sx, sz, facing, count, dmin, dmax, arc, spacing)
    local out = {}
    local function At(a, d, group) table.insert(out, { x = sx + d * math.cos(a), z = sz + d * math.sin(a), group = group }) end
    if count < 1 then return out end
    if shape == 'arc' then
        for j = 1, count do
            local t = (count == 1) and 0 or ((j - 1) / (count - 1) - 0.5)
            local d = dmin + (dmax - dmin) * ((math.mod(j, 2) == 0) and 0.75 or 0.25)
            At(facing + t * arc, d)
        end
    elseif shape == 'cluster' then
        local cd = (dmin + dmax) / 2
        local rho = math.max(spacing, (dmax - dmin) / 2 + spacing * 0.5)
        local cx, cz = sx + cd * math.cos(facing), sz + cd * math.sin(facing)
        for j = 1, count do
            local r = rho * math.sqrt((j - 0.5) / count)
            local a = (j - 1) * 2.39996
            table.insert(out, { x = cx + r * math.cos(a), z = cz + r * math.sin(a) })
        end
    elseif shape == 'line' then
        local cd = (dmin + dmax) / 2
        local px, pz = -math.sin(facing), math.cos(facing)
        local cx, cz = sx + cd * math.cos(facing), sz + cd * math.sin(facing)
        for j = 1, count do
            local off = (j - 1 - (count - 1) / 2) * spacing * 1.35
            table.insert(out, { x = cx + off * px, z = cz + off * pz })
        end
    elseif shape == 'pairs' then
        local groups = math.ceil(count / 2)
        local placed = 0
        for g = 1, groups do
            local a = facing + (g - 0.5) * 2 * PI / groups
            local d = dmin + (dmax - dmin) * ((math.mod(g, 2) == 0) and 0.75 or 0.25)
            local cx, cz = sx + d * math.cos(a), sz + d * math.sin(a)
            local tx, tz = -math.sin(a), math.cos(a)
            for k = 1, 2 do
                if placed < count then
                    placed = placed + 1
                    local off = (k == 1 and -0.5 or 0.5) * spacing * 1.1
                    table.insert(out, { x = cx + off * tx, z = cz + off * tz, group = g })
                end
            end
        end
    else
        for j = 1, count do
            local a = facing + (j - 0.5) * 2 * PI / count
            local d = dmin + (dmax - dmin) * ((math.mod(j, 2) == 0) and 0.75 or 0.25)
            At(a, d)
        end
    end
    return out
end

-- ---- the plan --------------------------------------------------------------------------------------------------------------------------------------------

local function Snap(kind, x, z)
    local ok, gx, gz = pcall(function() return import('/lua/editor/grid.lua').SnapMarker(kind, x, z) end)
    if ok and gx then return gx, gz end
    return x, z
end

--- Finds a valid position near the ideal one: tries the spot, then other angles and distances around the start. `occupied` is a list of { x, z, r }. Returns x, z or nil.
local function Fit(kind, ideal, sx, sz, occupied, rng, S)
    local px0, pz0, px1, pz1 = Layout.Area()
    local playable = { px0 + 4, pz0 + 4, px1 - 4, pz1 - 4 }
    local water = WaterLevel()
    local function Ok(x, z)
        if x < playable[1] or z < playable[2] or x > playable[3] or z > playable[4] then return false end
        if Ground(x, z) < water + 1 then return false end
        if SlopeDeg(x, z) > S.maxSlope then return false end
        for _, o in occupied do
            local dx, dz = o.x - x, o.z - z
            local lim = o.r or S.spacing
            if dx * dx + dz * dz < lim * lim then return false end
        end
        return true
    end
    local dx0, dz0 = ideal.x - sx, ideal.z - sz
    local d0 = math.sqrt(dx0 * dx0 + dz0 * dz0)
    local a0 = math.atan2(dz0, dx0)
    for attempt = 0, 30 do
        local x, z = ideal.x, ideal.z
        if attempt > 0 then
            local sign = (math.mod(attempt, 2) == 0) and 1 or -1
            local da = sign * math.rad(attempt * 4) * (0.6 + 0.8 * rng())
            local dd = (rng() - 0.5) * attempt * 1.2
            x, z = sx + (d0 + dd) * math.cos(a0 + da), sz + (d0 + dd) * math.sin(a0 + da)
        end
        x, z = Snap(kind, x, z)
        if Ok(x, z) then return x, z end
    end
    return nil
end

--- Plans the whole thing without placing anything.
function Plan()
    local S = Settings
    local mx, mz = Frame()
    local rng = Rng(S.seed)
    local plan = { starts = Starts(), items = {}, failed = 0 }
    local occupied = {}
    local skip = {}
    -- what is there already stays in the way, except the markers this generator made and is about to remove
    if S.clear then
        for _, name in (Layout.Doc.generated or {}) do skip[name] = true end
    end
    for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        if not skip[name] and m.position and (m.type == 'Mass' or m.type == 'Hydrocarbon') then
            table.insert(occupied, { x = m.position[1], z = m.position[3], r = S.spacing })
        end
    end
    for _, st in plan.starts do table.insert(occupied, { x = st.x, z = st.z, r = math.max(S.spacing * 1.5, 8) }) end
    local arc = math.rad(S.arc)
    local function FacingOf(st)
        local a = math.atan2(mz - st.z, mx - st.x)
        if S.facing == 'away' then a = a + PI end
        return a
    end
    local function Group(kind, count, dmin, dmax, shape, label)
        if count < 1 then return end
        for si, st in plan.starts do
            local ideal = Shape(shape, st.x, st.z, FacingOf(st), math.floor(count), dmin, math.max(dmax, dmin + 1), arc, S.spacing)
            for _, id in ideal do
                local x, z = Fit(kind, id, st.x, st.z, occupied, rng, S)
                if x then
                    table.insert(plan.items, { kind = kind, x = x, z = z, start = si, group = label })
                    table.insert(occupied, { x = x, z = z, r = (kind == 'Hydrocarbon') and math.max(S.spacing, 12) or S.spacing })
                else
                    plan.failed = plan.failed + 1
                end
            end
        end
    end
    Group('Hydrocarbon', S.hydro, S.hydroMin, S.hydroMax, 'ring', 'hydro')
    Group('Mass', S.mass, S.massMin, S.massMax, S.massShape, 'mass')
    Group('Mass', S.extra, S.extraMin, S.extraMax, S.extraShape, 'extra')
    -- the middle of the map
    if S.middle >= 1 then
        local ideal = Shape('cluster', mx, mz, 0, math.floor(S.middle), 0, math.max(2, S.middleRadius * 0.5), arc, S.spacing)
        for _, id in ideal do
            local x, z = Fit('Mass', id, mx, mz, occupied, rng, S)
            if x then
                table.insert(plan.items, { kind = 'Mass', x = x, z = z, start = 0, group = 'middle' })
                table.insert(occupied, { x = x, z = z, r = S.spacing })
            else
                plan.failed = plan.failed + 1
            end
        end
    end
    local masses, hydros = 0, 0
    for _, it in plan.items do
        if it.kind == 'Mass' then masses = masses + 1 else hydros = hydros + 1 end
    end
    plan.masses, plan.hydros = masses, hydros
    plan.text = table.getn(plan.starts) .. ' starts, ' .. masses .. ' mass, ' .. hydros .. ' hydrocarbon' .. (plan.failed > 0 and (', ' .. plan.failed .. ' did not fit') or '')
    Plan_ = plan
    return plan
end

function LastPlan() return Plan_ end
function ClearPlan() Plan_ = false end

-- ---- placing -------------------------------------------------------------------------------------------------------------------------------------------

local function MarkersOfType(kind)
    local names = {}
    for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        if m.type == kind then table.insert(names, name) end
    end
    return names
end

local function Delete(names)
    local list = {}
    for _, name in names do
        if Map.GetMarker(name) then table.insert(list, { kind = 'marker', name = name }) end
    end
    if table.getn(list) == 0 then return 0 end
    Tools.SelectMany(list)
    Tools.DeleteSelection()
    return table.getn(list)
end

--- Places the plan (made now): removes what the generator made before (`clear`), replaces the start markers when the starts are not the existing ones (`replaceStarts`), places the starts and the
--- resources. One undo step. Returns { starts, mass, hydro, failed } or nil and a message.
function Place()
    if not Map.Doc then return nil, 'no map is open' end
    local S = Settings
    local depth = History.Depth()
    local armies = import('/lua/editor/armies.lua')
    local plan = Plan()
    if S.starts ~= 'existing' and table.getn(plan.starts) == 0 then
        return nil, (S.starts == 'base') and 'no base is drawn in the layout (draw blobs on a Base layer)' or 'no start positions'
    end
    if S.clear then Delete(Layout.Doc.generated or {}) end
    Layout.Doc.generated = {}
    local made = { starts = 0, mass = 0, hydro = 0, failed = plan.failed }
    if S.starts ~= 'existing' then
        if S.replaceStarts then Delete(armies.Names()) end
        for _, st in plan.starts do
            local name = Tools.PlaceMarker(st.x, st.z, 'Blank Marker', armies.NextName())
            if name then made.starts = made.starts + 1 end
        end
    end
    -- the plan was made before the old markers went: the resources are fitted again against the map as it is now
    plan = Plan()
    for _, it in plan.items do
        local name = Tools.PlaceMarker(it.x, it.z, it.kind)
        if name then
            table.insert(Layout.Doc.generated, name)
            if it.kind == 'Mass' then made.mass = made.mass + 1 else made.hydro = made.hydro + 1 end
        end
    end
    made.failed = plan.failed
    local pushed = History.Depth() - depth
    if pushed >= 2 then History.Merge(pushed, 'generate starts and resources') end
    Tools.Select(nil)
    Plan_ = false
    return made
end
