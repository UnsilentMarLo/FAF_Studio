-- Map skeleton generator (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T6): from the start positions and a lane style it lays down spline paths (the objects of the Paths tool, paths.lua)
-- and base pads (sctools.lua). Everything it makes is an ordinary path: the user edits, moves and re-applies the paths afterwards. Generate() replaces an earlier skeleton (paths tagged
-- `skeleton`), ApplyAll() applies the pads and the paths in order as ONE undo entry.
--
--   styles  open    wide level lanes (ramp paths pinned to the base heights, grade limited) between the bases
--           ridge   the same lanes with a ridge along both sides: raised walls that keep units in the lane
--           ramps   every base on a plateau (a pad at an absolute height, steep sides) with ramps down to the lane level; the lane between two bases narrows to a choke in the middle
--           islands every base on an island inside a carved moat; narrow causeways join the islands
--   topology  ring (each base to its neighbours around the middle), hub (every base to a plaza in the middle), both
--
-- Every path starts and ends inside a flat pad (the base pads, the plateaus, the hub plaza): there the terrain already has the height the path is pinned to, so the paths join the pads
-- without a step. `smooth` finally runs the pathable slope limit over the lane corridors, which takes out the small steps that remain where a path leaves a pad skirt.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Paths = import('/lua/editor/paths.lua')
local SC = import('/lua/editor/sctools.lua')
local History = import('/lua/editor/history.lua')
local Map = import('/lua/editor/map.lua')
local Fields = import('/lua/editor/fields.lua')

Styles = {
    { id = 'open', label = 'Open lanes' },
    { id = 'ridge', label = 'Ridge lanes' },
    { id = 'ramps', label = 'Ramps and chokes' },
    { id = 'islands', label = 'Islands' },
}
Topologies = { 'ring', 'hub', 'both' }

Settings = {
    style = 'open', topology = 'ring',
    lanes = 1,                  -- parallel lanes per connection
    laneWidth = 9,              -- half width of a lane
    laneFalloff = 7,
    laneGrade = 0.5,            -- maximum grade of a lane (rise per run)
    bend = 14,                  -- how far a lane bows away from the straight line
    ridgeHeight = 9, ridgeWidth = 5, ridgeGap = 3,
    plateau = 7, plateauHalf = 14, rampWidth = 6, chokeWidth = 4,
    islandRadius = 26, moatWidth = 16, moatDepth = 5, bridgeWidth = 4,
    hubHalf = 8,
    pads = true,                -- apply the base pads (and plateaus, plaza) before reading the base heights
    smooth = true,              -- ApplyAll: slope limit over the lane corridors at the end
    count = 0,
}

Message = ''

local function Markers()
    if not Map.Doc then return {} end
    return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

local function Starts()
    local list = {}
    for name, m in Markers() do
        if string.find(name, '^ARMY_%d+$') and m.position then table.insert(list, { name = name, x = m.position[1], z = m.position[3] }) end
    end
    table.sort(list, function(a, b) return (tonumber(string.sub(a.name, 6)) or 0) < (tonumber(string.sub(b.name, 6)) or 0) end)
    return list
end

local function Pt(x, z, w, f, h, pinned)
    return { x = x, z = z, w = w, f = f, h = h or 0, abs = pinned and true or false, bank = 0 }
end

local function NewPath(mode, name, points, extra)
    local path = Paths.NewPath(mode, 'catmull')
    path.name = name
    path.points = points
    path.skeleton = true
    if extra then
        for k, v in extra do path[k] = v end
    end
    return path
end

local function Preset(path, id)
    for _, p in Paths.Presets do
        if p.id == id then
            path.profile = { points = {}, smooth = p.smooth, symmetric = true, preset = p.id }
            for _, q in p.points do table.insert(path.profile.points, { q[1], q[2] }) end
            return
        end
    end
end

--- The graph of connections between bases: list of { a, b } with a, b = { x, z, name, hub } (the hub is the middle of the bases).
local function Connections(starts)
    local cx, cz = 0, 0
    for _, s in starts do cx, cz = cx + s.x, cz + s.z end
    cx, cz = cx / table.getn(starts), cz / table.getn(starts)
    local hub = { x = cx, z = cz, name = 'hub', hub = true }
    local sorted = {}
    for _, s in starts do table.insert(sorted, s) end
    table.sort(sorted, function(a, b) return math.atan2(a.z - cz, a.x - cx) < math.atan2(b.z - cz, b.x - cx) end)
    local n = table.getn(sorted)
    local list = {}
    local topo = Settings.topology
    if (topo == 'ring' or topo == 'both') and n >= 2 then
        for i = 1, n do
            local j = i + 1
            if j > n then j = 1 end
            if n > 2 or i == 1 then table.insert(list, { a = sorted[i], b = sorted[j] }) end
        end
    end
    if (topo == 'hub' or topo == 'both') and n >= 2 then
        for i = 1, n do table.insert(list, { a = sorted[i], b = hub }) end
    end
    return list, hub
end

local function Dir(a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.001 then return 1, 0, 0 end
    return dx / len, dz / len, len
end

--- Points along the connection a -> b from distance d0 to len - d1, with `count` points, bowing by `bend` (away from the middle of the map; hub lanes bow to the left),
--- shifted sideways by `shift`. Every point: { x, z, d, t }.
local function LanePoints(conn, hub, d0, d1, count, bend, shift)
    local a, b = conn.a, conn.b
    local ux, uz, len = Dir(a, b)
    local nx, nz = -uz, ux
    local mx, mz = (a.x + b.x) / 2 - hub.x, (a.z + b.z) / 2 - hub.z
    local sign = (nx * mx + nz * mz) >= 0 and 1 or -1
    if b.hub then sign = 1 end
    local pts = {}
    for k = 0, count - 1 do
        local t = (count > 1) and k / (count - 1) or 0
        local d = d0 + (len - d0 - d1) * t
        local off = shift + sign * bend * math.sin(math.pi * (d / len))
        table.insert(pts, { x = a.x + ux * d + nx * off, z = a.z + uz * d + nz * off, d = d, t = t })
    end
    return pts, ux, uz, len
end

local function ParallelOffsets()
    local n = math.max(1, math.floor(Settings.lanes + 0.5))
    local spacing = 2 * (Settings.laneWidth + Settings.laneFalloff) + 4
    local out = {}
    for k = 1, n do table.insert(out, (k - (n + 1) / 2) * spacing) end
    return out
end

-- the distance from a base centre at which a path may start: inside the flat core of the pad
local function Inside(node)
    if node.hub then return 0 end
    local ov = SC.PadOverrides[node.name]
    local half = ov and ov.half or SC.Settings.startHalf
    return math.max(1, half * 0.55)
end

local function LanePath(list, conn, hub, h0, h1, shift, label, widthAt, d0, d1)
    local S = Settings
    d0 = d0 or Inside(conn.a)
    d1 = d1 or Inside(conn.b)
    local pts = LanePoints(conn, hub, d0, d1, 5, S.bend, shift)
    local points = {}
    for k, p in pts do
        local pinned = (k == 1 or k == table.getn(pts))
        local h = (k == 1) and h0 or ((k == table.getn(pts)) and h1 or 0)
        table.insert(points, Pt(p.x, p.z, widthAt and widthAt(k) or S.laneWidth, S.laneFalloff, h, pinned))
    end
    local path = NewPath('ramp', label, points, { limitGrade = true, grade = S.laneGrade, strength = 1 })
    Preset(path, 'ramp')
    table.insert(list, path)
end

local function MakeRidges(list, conn, hub, shift, label)
    local S = Settings
    local side = S.laneWidth + S.laneFalloff * 0.5 + S.ridgeGap + S.ridgeWidth
    local _, _, len = Dir(conn.a, conn.b)
    local pad = SC.Settings.startHalf + SC.Settings.startSkirt
    local d0 = math.max(pad + 4, len * 0.18)
    local d1 = conn.b.hub and len * 0.25 or math.max(pad + 4, len * 0.18)
    for _, sgn in { -1, 1 } do
        local pts = LanePoints(conn, hub, d0, d1, 6, S.bend, shift + sgn * side)
        local points = {}
        for k, p in pts do
            local taper = (k == 1 or k == table.getn(pts)) and 0.2 or ((k == 2 or k == table.getn(pts) - 1) and 0.7 or 1)
            table.insert(points, Pt(p.x, p.z, S.ridgeWidth * (0.6 + 0.4 * taper), S.ridgeWidth * 0.7, S.ridgeHeight * taper, false))
        end
        local path = NewPath('raise', label .. (sgn < 0 and ' ridge L' or ' ridge R'), points, { strength = 1 })
        Preset(path, 'ridge')
        table.insert(list, path)
    end
end

local function MakeMoat(list, start, label)
    local S = Settings
    local water = SC.WaterLevel() or 25
    local g = Ground(start.x, start.z)
    local depth = math.max(S.moatDepth, g - water + S.moatDepth)
    local r = S.islandRadius + S.moatWidth / 2
    local points = {}
    local n = 16
    for k = 0, n - 1 do
        local ang = 2 * math.pi * k / n
        table.insert(points, Pt(start.x + math.cos(ang) * r, start.z + math.sin(ang) * r, S.moatWidth / 2, 4, -depth, false))
    end
    local path = NewPath('carve', label .. ' moat', points, { closed = true, strength = 1 })
    Preset(path, 'u')
    table.insert(list, path)
end

--- Ramp from the plateau pad of `node` towards `target`: returns the ramp bottom position and its ground height.
local function MakeRamp(list, node, target, label)
    local S = Settings
    local ov = SC.PadOverrides[node.name]
    local ux, uz = Dir(node, target)
    local half, skirt = ov.half, ov.skirt
    local edge = half / math.max(math.abs(ux), math.abs(uz), 0.01)
    local rampLen = math.max(8, S.plateau / math.max(0.2, S.laneGrade) * 1.25)
    local top = half * 0.55
    local bottom = edge + skirt + rampLen
    local bx, bz = node.x + ux * bottom, node.z + uz * bottom
    local yBottom = Ground(bx, bz)
    local points = {
        Pt(node.x + ux * top, node.z + uz * top, S.rampWidth, 3, ov.y, true),
        Pt(node.x + ux * (top + bottom) / 2, node.z + uz * (top + bottom) / 2, S.rampWidth, 3, 0, false),
        Pt(bx, bz, S.rampWidth, 3, yBottom, true),
    }
    local path = NewPath('ramp', label, points, { limitGrade = true, grade = S.laneGrade })
    Preset(path, 'ramp')
    table.insert(list, path)
    return bx, bz, yBottom
end

--- The skeleton paths that exist now: list of path tables.
function Existing()
    local out = {}
    for _, p in Paths.List do
        if p.skeleton then table.insert(out, p) end
    end
    return out
end

local function UnapplyExisting()
    for _, p in Existing() do
        if Paths.Results[p.id] then Paths.Unapply(p.id) end
    end
end

--- Lays down the skeleton: removes an earlier one (its applied results are taken off first), makes the paths in the order they must be applied, one undo entry for the path list.
--- Returns the number of paths, or false and a message.
function Generate()
    if not Map.Doc then return false, 'no map' end
    local starts = Starts()
    if table.getn(starts) < 2 then return false, 'the skeleton needs at least two start positions (ARMY_1, ARMY_2, ...)' end
    local S = Settings
    UnapplyExisting()
    local conns, hub = Connections(starts)
    -- pads: plateaus (ramps style) and the hub plaza need the ground as it is now
    SC.PadOverrides = {}
    SC.PadExtras = {}
    local needPads = S.pads or S.style == 'ramps'
    local usesHub = false
    for _, c in conns do if c.b.hub then usesHub = true end end
    local hubGround = 0
    for _, s in starts do hubGround = hubGround + Ground(s.x, s.z) end
    hubGround = hubGround / table.getn(starts)
    if S.style == 'ramps' then
        for _, st in starts do
            local half = S.plateauHalf
            SC.PadOverrides[st.name] = { half = half, skirt = math.max(2, S.plateau / 1.6), y = Ground(st.x, st.z) + S.plateau }
        end
    end
    if usesHub and needPads then
        table.insert(SC.PadExtras, { x = hub.x, z = hub.z, half = S.hubHalf, skirt = S.hubHalf, y = math.floor(hubGround * 128 + 0.5) / 128 })
    end
    if needPads then
        local ok, err = SC.Apply()
        if ok == false then return false, 'pads: ' .. tostring(err) end
    end
    local function BaseY(node)
        if node.hub then return Ground(node.x, node.z) end
        return Ground(node.x, node.z)
    end
    local offsets = ParallelOffsets()
    local made = {}
    local style = S.style
    local k = 0
    if style == 'islands' then
        for _, st in starts do MakeMoat(made, st, 'Skeleton ' .. st.name) end
    end
    for _, conn in conns do
        k = k + 1
        for j, shift in offsets do
            local label = string.format('Skeleton %s %d.%d', style, k, j)
            if style == 'ramps' then
                local ax, az, ay, bx, bz, by
                ax, az, ay = MakeRamp(made, conn.a, conn.b, label .. ' ramp A')
                if conn.b.hub then
                    bx, bz, by = conn.b.x, conn.b.z, BaseY(conn.b)
                else
                    bx, bz, by = MakeRamp(made, conn.b, conn.a, label .. ' ramp B')
                end
                local sub = { a = { x = ax, z = az, name = 'ra' }, b = { x = bx, z = bz, name = 'rb', hub = conn.b.hub } }
                LanePath(made, sub, hub, ay, by, shift, label .. ' choke lane', function(q)
                    if q == 3 then return S.chokeWidth end
                    if q == 2 or q == 4 then return (S.chokeWidth + S.laneWidth) / 2 end
                    return S.laneWidth
                end, 0, conn.b.hub and Inside(conn.b) or 0)
            elseif style == 'islands' then
                local d0 = math.max(Inside(conn.a), 4)
                local d1 = conn.b.hub and 2 or math.max(Inside(conn.b), 4)
                LanePath(made, conn, hub, BaseY(conn.a), BaseY(conn.b), shift, label .. ' causeway', function() return S.bridgeWidth end, d0, d1)
            else
                LanePath(made, conn, hub, BaseY(conn.a), BaseY(conn.b), shift, label, nil, nil, nil)
                if style == 'ridge' then MakeRidges(made, conn, hub, shift, label) end
            end
        end
    end
    Paths.Edit('Generate skeleton', function()
        local keep = {}
        for _, p in Paths.List do
            if not p.skeleton then table.insert(keep, p) end
        end
        Paths.List = keep
        for _, p in made do table.insert(Paths.List, p) end
        Paths.Current = made[1] and made[1].id or false
        Paths.Sel = {}
    end)
    Settings.count = table.getn(made)
    Message = string.format('skeleton: %d paths (%s, %s), edit them in the Paths tool', table.getn(made), style, S.topology)
    pcall(function() import('/lua/editor/ui.lua').Say(Message) end)
    return table.getn(made)
end

--- Removes the generated paths (one undo entry; applied results are taken off first) and the plateau / plaza pads.
function Clear()
    UnapplyExisting()
    Paths.Edit('Remove skeleton', function()
        local keep = {}
        for _, p in Paths.List do
            if not p.skeleton then table.insert(keep, p) end
        end
        Paths.List = keep
        if Paths.Current and not Paths.ById(Paths.Current) then Paths.Current = false Paths.Sel = {} end
    end)
    SC.PadOverrides = {}
    SC.PadExtras = {}
    Settings.count = 0
end

local function CorridorMask(s, like)
    local mask
    for _, p in Existing() do
        local m = Paths.Modes[p.mode]
        if m and m.grade and table.getn(p.points) >= 2 then
            local S = Paths.Sample(p, 1)
            local pts = {}
            for k = 1, S.n do
                table.insert(pts, S.x[k]) table.insert(pts, S.z[k]) table.insert(pts, 0) table.insert(pts, S.w[k]) table.insert(pts, S.f[k])
                table.insert(pts, 0) table.insert(pts, 0) table.insert(pts, S.s[k])
            end
            local mk = s:Op('path_mask', { like = like, pts = pts, kind = 'reach', soft = 4 })
            mask = mask and s:Op('max', { a = mask, b = mk }) or mk
        end
    end
    return mask
end

--- Applies the base pads and then every skeleton path in order, then (smooth) the slope limit over the lane corridors; everything is ONE undo entry.
--- Returns the number of entries folded and the samples changed.
function ApplyAll()
    local list = Existing()
    if table.getn(list) == 0 then return false, 'there is no skeleton: Generate first' end
    local undo0 = History.Depth()
    local changed = 0
    if Settings.pads or Settings.style == 'ramps' then
        local n = SC.Apply()
        if n then changed = changed + n end
    end
    for _, p in list do
        local n = Paths.Apply(p.id)
        if n then changed = changed + n end
    end
    if Settings.smooth and Fields.IsAvailable() then
        local s = Fields.Scope()
        local ok, n = pcall(function()
            local H = s:Height(1)
            local mask = CorridorMask(s, H)
            if not mask then return 0 end
            local new = s:Op('quantize', { a = s:Op('slope_limit', { a = H, limit = SC.Slope.limit, margin = SC.Slope.margin, mode = 'both', balance = 0.5, mask = mask }), step = 1 / 128 })
            return Fields.Apply({ height = new, label = 'Skeleton: smooth lanes' }) or 0
        end)
        s:Free()
        if ok then changed = changed + (n or 0) end
    end
    local undo1 = History.Depth()
    local count = undo1 - undo0
    if count >= 2 then History.Merge(count, 'Apply skeleton') end
    Message = string.format('skeleton applied: %d samples changed, %d steps (one undo entry)', changed, count)
    pcall(function() import('/lua/editor/ui.lua').Say(Message) end)
    return count, changed
end
