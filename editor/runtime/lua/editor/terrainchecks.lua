-- Terrain checks (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T6): what a generated or edited map must satisfy for play, with the position of every problem.
--
--   * the marker validators of validate.lua (stacked, off the build grid, blocked according to the sim's own build check, map level findings)
--   * the ground of every start position: steep ground (engine slope rule over a unit class footprint) inside the base radius, and uneven ground under resource markers
--   * pathing connectivity: the passable ground of a unit layer (land / hover / amphibious, from the engine slope rule and the map's water) is cut into connected regions by the native
--     `regions` op; every start position must lie in one region, resource markers must be reachable, and the route length between the starts is measured with the native `reach` op
--   * the grade along the paths of the Paths tool (ramps, roads, levels) on the terrain as it is now
--   * the symmetry of the markers, pads and water masks that are out of date
--
--   Settings, Run(), Issues (list of { kind, sev = 'E' | 'W' | 'I', text, x, z }), Revision, Summary(), Tick() (auto run after edits and when the validators have an answer)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Map = import('/lua/editor/map.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local SC = import('/lua/editor/sctools.lua')

Settings = {
    land = true, hover = false, amph = false,
    limit = 0.75,           -- blocking slope rating (the engine's rule: 0.75 blocks land units)
    class = 2,              -- unit class footprint (index into SC.Classes)
    wade = 0.5,             -- land units cross water up to this deep
    startRadius = 10,       -- the base area checked around a start position
    blockedShare = 0.04,    -- share of blocked ground in the base area that is reported
    detour = 3,             -- a route longer than this many times the straight distance is reported
    validators = true, symmetry = true, paths = true, auto = false,
}

Issues = {}
Revision = 0
Message = ''
Info = { regions = 0, starts = 0, seconds = 0, lastRun = false }

local own = {}
local lastValRev = -1
local lastSig = ''
local quiet = 0
local dirty = false

local function Clock()
    return rawget(_G, 'ed_field_clock') and ed_field_clock() or 0
end

local function Issue(kind, sev, text, x, z)
    return { kind = kind, sev = sev, text = text, x = x or 0, z = z or 0 }
end

local function Markers()
    if not Map.Doc then return {} end
    return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
end

--- The start positions (ARMY_n) sorted by name: list of { name, x, z }.
function Starts()
    local list = {}
    for name, m in Markers() do
        if string.find(name, '^ARMY_%d+$') and m.position then table.insert(list, { name = name, x = m.position[1], z = m.position[3] }) end
    end
    table.sort(list, function(a, b)
        local na, nb = tonumber(string.sub(a.name, 6)) or 0, tonumber(string.sub(b.name, 6)) or 0
        return na < nb
    end)
    return list
end

local function Resources()
    local list = {}
    for name, m in Markers() do
        if m.position and (m.type == 'Mass' or m.type == 'Hydrocarbon') then table.insert(list, { name = name, type = m.type, x = m.position[1], z = m.position[3] }) end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- ---- field helpers ----------------------------------------------------------------------------------------------------------------------------------

local function Cell(v) return math.floor(v + 0.5) end

--- Values of f in the square of radius r around the world position (cell = 1 fields): list of { value, dist2 } sorted by distance.
local function Around(f, w, h, x, z, r)
    local cx, cz = Cell(x), Cell(z)
    local x0, z0, x1, z1 = math.max(0, cx - r), math.max(0, cz - r), math.min(w - 1, cx + r), math.min(h - 1, cz + r)
    if x1 < x0 or z1 < z0 then return {} end
    local vals = Fields.Read(f, x0, z0, x1, z1)
    local out = {}
    local ww = x1 - x0 + 1
    for i = 1, table.getn(vals) do
        local px = x0 + math.mod(i - 1, ww)
        local pz = z0 + math.floor((i - 1) / ww)
        table.insert(out, { v = vals[i], d = (px - x) * (px - x) + (pz - z) * (pz - z), x = px, z = pz })
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

--- The first value other than `skip` nearest to the position (within r cells), and where it is.
local function NearestValue(f, w, h, x, z, r, accept)
    for _, e in Around(f, w, h, x, z, r) do
        if accept(e.v) then return e.v, e.x, e.z end
    end
    return nil
end

--- The passable mask of a unit layer on the ground H: 1 where a unit of the class can stand.
local function Passable(s, H, layer)
    local cls = SC.Classes[math.max(1, math.min(table.getn(SC.Classes), Settings.class))]
    local rating = s:Op('slope', { a = H, mode = 'rating', window = cls.window })
    local bad = s:Op('threshold', { a = rating, value = Settings.limit })
    local ok = s:Op('affine', { a = bad, mul = -1, add = 1 })
    local level = SC.WaterLevel()
    if not level or layer == 'amph' then return ok end
    local wet = s:Op('threshold', { a = s:Op('water_depth', { a = H, level = level }), value = Settings.wade })
    local dry = s:Op('affine', { a = wet, mul = -1, add = 1 })
    local land = s:Op('mul', { a = ok, b = dry })
    if layer == 'land' then return land end
    return s:Op('max', { a = land, b = wet })       -- hover: land by the slope rule, any water
end

local LAYERS = { land = 'land', hover = 'hover', amph = 'amphibious' }

-- ---- the checks --------------------------------------------------------------------------------------------------------------------------------------

local function CheckGround(list, s, H, w, h)
    local starts, res = Starts(), Resources()
    local cls = SC.Classes[math.max(1, math.min(table.getn(SC.Classes), Settings.class))]
    local rating = s:Op('slope', { a = H, mode = 'rating', window = cls.window })
    local bad = s:Op('threshold', { a = rating, value = Settings.limit })
    local R = math.max(2, Settings.startRadius)
    for _, st in starts do
        local n, blocked = 0, 0
        for _, e in Around(bad, w, h, st.x, st.z, math.ceil(R)) do
            if e.d <= R * R then
                n = n + 1
                if e.v > 0.5 then blocked = blocked + 1 end
            end
        end
        if n > 0 and blocked / n > Settings.blockedShare then
            table.insert(list, Issue('ground', 'W', string.format('%s: %.0f%% of the base area (radius %d) is too steep for %s', st.name, blocked / n * 100, R, cls.name), st.x, st.z))
        end
    end
    local variation = s:Op('slope', { a = H, mode = 'variation', window = 2 })
    for _, r in res do
        local worst = 0
        for _, e in Around(variation, w, h, r.x - 0.5, r.z - 0.5, 1) do
            if e.d <= 2 then worst = math.max(worst, e.v) end
        end
        if worst > 1.1 then
            table.insert(list, Issue('ground', 'W', string.format('%s: the ground under the structure varies by %.2f (a structure needs 1.1 at most)', r.name, worst), r.x, r.z))
        end
    end
end

local function CheckConnectivity(list, s, H, w, h)
    local starts, res = Starts(), Resources()
    Info.starts = table.getn(starts)
    if table.getn(starts) < 2 then
        table.insert(list, Issue('path', 'I', 'connectivity: needs at least two start positions', 0, 0))
        return
    end
    for layer, name in LAYERS do
        if Settings[layer] then
            local mask = Passable(s, H, layer)
            local labels = s:Op('regions', { a = mask })
            local sizes = s:Op('regions', { a = mask, mode = 'size' })
            local _, mx = Fields.Stats(labels)
            Info.regions = mx or 0
            local lab = {}
            local groups = {}
            for _, st in starts do
                local l, lx, lz = NearestValue(labels, w, h, st.x, st.z, 6, function(v) return v > 0.5 end)
                lab[st.name] = l or 0
                if not l then
                    table.insert(list, Issue('path', 'E', string.format('%s stands on ground no %s unit can cross', st.name, name), st.x, st.z))
                else
                    groups[l] = groups[l] or {}
                    table.insert(groups[l], st)
                end
            end
            local base = lab[starts[1].name]
            for _, st in starts do
                if lab[st.name] > 0 and lab[st.name] ~= base and base > 0 then
                    local area = Fields.Get(sizes, Cell(st.x), Cell(st.z))
                    table.insert(list, Issue('path', 'E', string.format('%s cannot reach %s by %s units (separate ground)', st.name, starts[1].name, name), st.x, st.z))
                end
            end
            -- route lengths from the first start
            if base > 0 then
                local d = s:Op('reach', { a = mask, src = { starts[1].x, starts[1].z }, snap = 6 })
                for i = 2, table.getn(starts) do
                    local st = starts[i]
                    if lab[st.name] == base then
                        local v = NearestValue(d, w, h, st.x, st.z, 6, function(x) return x >= 0 end)
                        local straight = math.sqrt((st.x - starts[1].x) * (st.x - starts[1].x) + (st.z - starts[1].z) * (st.z - starts[1].z))
                        if v then
                            local ratio = straight > 1 and v / straight or 1
                            local text = string.format('%s -> %s (%s): route %.0f units, straight %.0f (x%.2f)', starts[1].name, st.name, name, v, straight, ratio)
                            if ratio > Settings.detour then
                                table.insert(list, Issue('path', 'W', text .. ' - a long detour', st.x, st.z))
                            else
                                table.insert(list, Issue('route', 'I', text, st.x, st.z))
                            end
                        end
                    end
                end
            end
            -- resources
            local isStartRegion = {}
            for _, st in starts do isStartRegion[lab[st.name]] = true end
            for _, r in res do
                local l = NearestValue(labels, w, h, r.x, r.z, 6, function(v) return v > 0.5 end)
                if not l then
                    table.insert(list, Issue('path', 'W', string.format('%s lies on ground no %s unit can reach', r.name, name), r.x, r.z))
                elseif not isStartRegion[l] then
                    local area = Fields.Get(sizes, Cell(r.x), Cell(r.z))
                    table.insert(list, Issue('path', 'W', string.format('%s is not connected to any start position (%s ground, region of %.0f square units)', r.name, name, area or 0), r.x, r.z))
                end
            end
        end
    end
end

local function CheckPaths(list)
    local Paths = import('/lua/editor/paths.lua')
    for _, path in Paths.List do
        local m = Paths.Modes[path.mode]
        if m and m.grade and table.getn(path.points) >= 2 then
            local rep = SC.RampPath(path.id, { limit = path.grade and path.grade > 0 and path.grade or Settings.limit })
            if rep and rep.over > 0.02 and table.getn(rep.runs) > 0 then
                local worst = rep.runs[1]
                for _, r in rep.runs do
                    if r.grade > worst.grade then worst = r end
                end
                table.insert(list, Issue('grade', 'W', string.format('path %s: %.0f%% of its length is steeper than %.2f (worst %.2f)', path.name or path.id, rep.over * 100, path.grade or Settings.limit, worst.grade), worst.x, worst.z))
            end
        end
    end
end

local function CheckOther(list)
    if Settings.symmetry and Symmetry.Mode ~= 'off' then
        for _, e in SC.MarkerCheck() do
            table.insert(list, Issue('symmetry', 'W', string.format('%s has no symmetric partner (expected near %.0f, %.0f)', e.name, e.ix, e.iz), e.x, e.z))
        end
    end
    if SC.Stale() then
        table.insert(list, Issue('pads', 'W', 'markers moved since the base pads were applied (Pads: Apply)', 0, 0))
    end
    local n = SC.Water.OutOfDate()
    if n > 0 then
        table.insert(list, Issue('water', 'W', n .. ' water mask(s) were made at another water level (Water: Update)', 0, 0))
    end
end

local function Compose()
    local out = {}
    for _, i in own do table.insert(out, i) end
    if Settings.validators then
        local Validate = import('/lua/editor/validate.lua')
        for _, v in Validate.Issues do
            local sev = (v.kind == 'blocked' or v.kind == 'map' or v.kind == 'start') and 'W' or 'W'
            if v.kind == 'blocked' or v.kind == 'water' then sev = 'E' end
            table.insert(out, { kind = v.kind, sev = sev, text = v.text, x = v.x or 0, z = v.z or 0 })
        end
    end
    local rank = { E = 1, W = 2, I = 3 }
    table.sort(out, function(a, b)
        if rank[a.sev] ~= rank[b.sev] then return rank[a.sev] < rank[b.sev] end
        return a.text < b.text
    end)
    Issues = out
    Revision = Revision + 1
end

--- Counts: errors, warnings, infos.
function Summary()
    local e, w, i = 0, 0, 0
    for _, v in Issues do
        if v.sev == 'E' then e = e + 1 elseif v.sev == 'W' then w = w + 1 else i = i + 1 end
    end
    return e, w, i
end

--- Runs all checks now (the sim's build check for the markers answers within a few frames and joins the list by itself).
function Run()
    if not Map.Doc then Message = 'no map' return false end
    local t0 = Clock()
    local list = {}
    if Fields.IsAvailable() then
        local ok, err = pcall(function()
            Fields.Run(function(s)
                local w, h = ed_terrain_info()
                local H = s:Height(1)
                CheckGround(list, s, H, w, h)
                CheckConnectivity(list, s, H, w, h)
            end)
        end)
        if not ok then table.insert(list, Issue('check', 'E', 'the field checks failed: ' .. tostring(err), 0, 0)) end
    end
    if Settings.paths then
        local ok, err = pcall(CheckPaths, list)
        if not ok then table.insert(list, Issue('check', 'E', 'the path checks failed: ' .. tostring(err), 0, 0)) end
    end
    pcall(CheckOther, list)
    own = list
    if Settings.validators then
        local Validate = import('/lua/editor/validate.lua')
        lastValRev = -1
        Validate.Run()
    end
    Info.seconds = Clock() - t0
    Info.lastRun = true
    dirty = false
    Compose()
    local e, w, i = Summary()
    Message = string.format('%d error(s), %d warning(s), %d note(s) in %.0f ms', e, w, i, Info.seconds * 1000)
    return e, w, i
end

--- Per-frame: takes the validators' late answer into the list, and (Auto) re-runs the checks about a second after the map was edited.
function Tick()
    if not Map.Doc or not Info.lastRun then return end
    if Settings.validators then
        local Validate = import('/lua/editor/validate.lua')
        if Validate.Revision ~= lastValRev then
            lastValRev = Validate.Revision
            Compose()
        end
    end
    if Settings.auto then
        local undo, redo = History.Depth()
        local sig = undo .. '/' .. redo .. '/' .. History.Version
        if sig ~= lastSig then
            lastSig = sig
            quiet = Clock()
            dirty = true
        elseif dirty and Clock() - quiet > 1.0 then
            Run()
        end
    end
end

function Clear()
    own = {}
    Issues = {}
    Info.lastRun = false
    Revision = Revision + 1
end
