-- Supreme Commander specific terrain tools (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T6): base pads and resource rings that follow the markers, symmetry of a whole map from one
-- part, the pathable slope limit and the ramp check, and water coupled masks. Native ops: moho/editor/EdFieldSc.cpp (pad_flatten, symmetrize, slope_limit, reach, regions). Every function
-- works standalone now; a graph node (T5) calls the same ops with the same parameters.
--
--   Pads      Settings (sizes of the pads, clustering, ring), Collect() -> the pads the markers ask for, Apply() / Remove() (one undo entry each, non-destructive: the previous result is taken
--             off first, so moving a marker and applying again replaces the pads), Stale() (the markers moved since the last Apply), Tick() (re-applies by itself when Auto is on)
--   Symmetry  Sym (state), SymParams(), Parts() (what part each master choice keeps), Symmetrize() (heights, texture layers, terrain types as ONE undo entry from the master part, using the
--             mode and centre of symmetry.lua: the same symmetry the marker tools use), MarkerCheck() (markers whose symmetric image is missing)
--   Slope     Slope (state), SlopeApply() (clamp the steepest neighbour difference: guaranteed pathable for every unit class), SlopeReport() (blocked share per unit class), SlopeThumb()
--   Ramp      RampProfile(points) / RampPath(id): the grade along a route, the stretches over the limit and where they are
--   Water     Water.Defs (beach / shore / underwater / shallows / deep masks written into texture layers), WaterApply(def), WaterTick() (re-evaluates after the map's water level changed)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Map = import('/lua/editor/map.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local World = import('/lua/editor/world.lua')

Message = ''
Revision = 0

local WORD = 128

local function Say(text)
    Message = text
    Revision = Revision + 1
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Clock()
    return rawget(_G, 'ed_field_clock') and ed_field_clock() or 0
end

local function MapSize()
    local w, h = ed_terrain_info()
    return w or 257, h or 257
end

local function Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function Markers()
    if not Map.Doc then return {} end
    return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
end

local function BumpMarkers()
    pcall(function()
        local Tools = import('/lua/editor/tools.lua')
        Tools.Changed = Tools.Changed + 1
    end)
end

--- Native handles of results that outlive their scope (freed by Reset).
local kept = {}

local function Keep(f)
    table.insert(kept, f)
    return f
end

-- ---- base pads and resource rings ---------------------------------------------------------------------------------------------------------------

Settings = {
    startPads = true, startHalf = 8, startSkirt = 10,
    massPads = true, massHalf = 2, massSkirt = 4,
    hydroPads = true, hydroHalf = 4, hydroSkirt = 5,
    ring = true, ringRadius = 30,          -- mass points and hydros within this distance of a start share the start pad's height (a resource ring on the base level)
    cluster = true, clusterDist = 16,      -- other resource markers closer than this share one height
    level = 0,                             -- the height of a pad: 0 mean of the core, 1 lowest, 2 highest
    strength = 1,
    auto = false,                          -- re-apply by itself when a marker moved
}

PadOverrides = {}           -- start name -> { half, skirt, y }: that start's pad is a plateau at the absolute height y (the skeleton generator sets these)
PadExtras = {}              -- extra pads that belong to no marker: list of { x, z, half, skirt, y } (absolute height), e.g. the hub plaza of the skeleton
PadResult = false           -- { rect, delta, sig, markers = { name = { oldY, newY } } } of the last Apply
local padCreated = {}

local function IsStart(name) return string.find(name, '^ARMY_%d+$') ~= nil end

--- The pads the markers ask for: list of { name, kind = 'start' | 'mass' | 'hydro', x, z, half, skirt, group }. group 0 = its own height, k >= 1 = the height shared by that group.
function Collect()
    local starts, res = {}, {}
    local markers = Markers()
    local names = {}
    for name, _ in markers do table.insert(names, name) end
    table.sort(names)
    for _, name in names do
        local m = markers[name]
        if m and m.position then
            local x, z = m.position[1], m.position[3]
            if IsStart(name) then
                local ov = PadOverrides[name]
                if ov then
                    table.insert(starts, { name = name, kind = 'start', x = x, z = z, half = ov.half, skirt = ov.skirt, group = -1, y = ov.y, plateau = true })
                elseif Settings.startPads then
                    table.insert(starts, { name = name, kind = 'start', x = x, z = z, half = Settings.startHalf, skirt = Settings.startSkirt, group = 0 })
                end
            elseif m.type == 'Mass' then
                if Settings.massPads then table.insert(res, { name = name, kind = 'mass', x = x, z = z, half = Settings.massHalf, skirt = Settings.massSkirt, group = 0 }) end
            elseif m.type == 'Hydrocarbon' then
                if Settings.hydroPads then table.insert(res, { name = name, kind = 'hydro', x = x, z = z, half = Settings.hydroHalf, skirt = Settings.hydroSkirt, group = 0 }) end
            end
        end
    end
    -- groups: a start and the resources around it (ring), then clusters of the other resources
    local nextGroup = 0
    local free = {}
    local ringOf = {}
    for _, r in res do
        local best, bestD = nil, Settings.ringRadius
        if Settings.ring then
            for _, s in starts do
                local d = math.sqrt((s.x - r.x) * (s.x - r.x) + (s.z - r.z) * (s.z - r.z))
                if d <= bestD and not s.plateau then best, bestD = s, d end
            end
        end
        if best then
            if best.group == 0 then
                nextGroup = nextGroup + 1
                best.group = nextGroup
            end
            r.group = best.group
        else
            table.insert(free, r)
        end
    end
    if Settings.cluster then
        local parent = {}
        for i = 1, table.getn(free) do parent[i] = i end
        local function Find(i)
            while parent[i] ~= i do
                parent[i] = parent[parent[i]]
                i = parent[i]
            end
            return i
        end
        for i = 1, table.getn(free) do
            for j = i + 1, table.getn(free) do
                local a, b = free[i], free[j]
                if a.kind == b.kind then
                    local d = math.sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z))
                    if d <= Settings.clusterDist then
                        local ra, rb = Find(i), Find(j)
                        if ra ~= rb then parent[math.max(ra, rb)] = math.min(ra, rb) end
                    end
                end
            end
        end
        local size, gid = {}, {}
        for i = 1, table.getn(free) do
            local root = Find(i)
            size[root] = (size[root] or 0) + 1
        end
        for i = 1, table.getn(free) do
            local root = Find(i)
            if size[root] >= 2 then
                if not gid[root] then
                    nextGroup = nextGroup + 1
                    gid[root] = nextGroup
                end
                free[i].group = gid[root]
            end
        end
    end
    local out = {}
    for _, e in PadExtras do table.insert(out, { name = 'extra', kind = 'extra', x = e.x, z = e.z, half = e.half, skirt = e.skirt, group = -1, y = e.y }) end
    for _, s in starts do table.insert(out, s) end
    for _, r in res do
        if r.kind == 'hydro' then table.insert(out, r) end
    end
    for _, r in res do
        if r.kind == 'mass' then table.insert(out, r) end
    end
    return out
end

--- The marker positions and sizes the pads are made from, as a string: changes when a marker moves (not when the ground under it changes).
function Signature()
    local parts = {}
    for _, p in Collect() do
        table.insert(parts, string.format('%s:%.2f:%.2f:%d:%.2f', p.name, p.x, p.z, p.group, p.y or 0))
    end
    local S = Settings
    return table.concat(parts, '|') .. string.format('#%d%d%d%d%d%d.%g.%g.%g.%g.%g.%g.%g.%g.%g.%d.%g', S.startPads and 1 or 0, S.massPads and 1 or 0, S.hydroPads and 1 or 0, S.ring and 1 or 0, S.cluster and 1 or 0, 0,
        S.startHalf, S.startSkirt, S.massHalf, S.massSkirt, S.hydroHalf, S.hydroSkirt, S.ringRadius, S.clusterDist, S.strength, S.level, 0)
end

--- Counts for the panel: starts, mass, hydro, groups.
function PadCounts()
    local list = Collect()
    local c = { start = 0, mass = 0, hydro = 0, extra = 0, groups = 0 }
    local seen = {}
    for _, p in list do
        c[p.kind] = c[p.kind] + 1
        if p.group > 0 and not seen[p.group] then
            seen[p.group] = true
            c.groups = c.groups + 1
        end
    end
    return c
end

local function PadArgs(list)
    local flat = {}
    local x0, z0, x1, z1 = 1e9, 1e9, -1e9, -1e9
    for _, p in list do
        table.insert(flat, p.x) table.insert(flat, p.z) table.insert(flat, p.half) table.insert(flat, p.skirt) table.insert(flat, p.y or 0) table.insert(flat, p.group)
        local r = p.half + p.skirt + 2
        x0, z0 = math.min(x0, p.x - r), math.min(z0, p.z - r)
        x1, z1 = math.max(x1, p.x + r), math.max(z1, p.z + r)
    end
    return flat, { x0, z0, x1, z1 }
end

local function UnionRect(a, b)
    if not a then return b end
    if not b then return a end
    return { math.min(a[1], b[1]), math.min(a[2], b[2]), math.max(a[3], b[3]), math.max(a[4], b[4]) }
end

local function ClampRect(rect)
    local mw, mh = MapSize()
    return Clamp(math.floor(rect[1]), 0, mw - 1), Clamp(math.floor(rect[2]), 0, mh - 1), Clamp(math.ceil(rect[3]), 0, mw - 1), Clamp(math.ceil(rect[4]), 0, mh - 1)
end

--- Wraps a history entry so that the module's own result record follows undo and redo.
local function Follow(entry, setBefore, setAfter)
    local undo0, redo0 = entry.undo, entry.redo
    entry.undo = function()
        undo0()
        setBefore()
        Revision = Revision + 1
    end
    entry.redo = function()
        redo0()
        setAfter()
        Revision = Revision + 1
    end
end

local function MoveMarkersY(table_, which)
    for name, ys in table_ do
        local m = Markers()[name]
        if m and m.position then Map.MoveMarker(name, m.position[1], ys[which], m.position[3]) end
    end
    BumpMarkers()
end

--- Applies the pads of the markers: the previous result is taken off first (so the call replaces it), the target heights come from the ground without pads, one undo entry.
--- Returns the number of samples changed, or false and a message.
function Apply()
    if not Fields.IsAvailable() then return false, 'no field engine' end
    if not Map.Doc then return false, 'no map' end
    local list = Collect()
    if table.getn(list) == 0 then return false, 'no start positions or resource markers (or all pad kinds are switched off)' end
    local flat, rect = PadArgs(list)
    local prev = PadResult
    local s = Fields.Scope()
    local ok, a, b = pcall(function()
        local x0, z0, x1, z1 = ClampRect(UnionRect(rect, prev and prev.rect))
        if x1 <= x0 or z1 <= z0 then error('the pads lie outside the map') end
        local H = s:Height(1, x0, z0, x1, z1)
        local base = H
        if prev and prev.delta then base = s:Op('path_paste', { a = H, b = prev.delta, mode = 'sub' }) end
        local raw = s:Op('pad_flatten', { a = base, pads = flat, strength = Settings.strength, level = Settings.level, grid = 1, snap = 1, word = WORD })
        local new = s:Op('quantize', { a = raw, step = 1 / WORD })
        local delta = s:Op('sub', { a = new, b = base })
        local changed, entry = Fields.Apply({ height = new, label = 'Base pads and resource rings' })
        local marks = {}
        for _, p in list do
            local m = p.kind ~= 'extra' and Markers()[p.name] or nil
            if m and m.position then marks[p.name] = { m.position[2], Fields.Sample(new, p.x, p.z) } end
        end
        local res = { rect = { x0, z0, x1, z1 }, delta = s:Keep(delta), sig = Signature(), markers = marks, count = table.getn(list) }
        table.insert(padCreated, res)
        return changed or 0, { entry = entry, res = res }
    end)
    s:Free()
    if not ok then
        Say('pads failed: ' .. tostring(a))
        return false, tostring(a)
    end
    local changed, info = a, b
    local entry = info.entry
    if not entry then
        entry = { label = 'Base pads and resource rings', undo = function() end, redo = function() end }
        History.Push(entry)
    end
    MoveMarkersY(info.res.markers, 2)
    PadResult = info.res
    Follow(entry, function() PadResult = prev MoveMarkersY(info.res.markers, 1) end, function() PadResult = info.res MoveMarkersY(info.res.markers, 2) end)
    Say(string.format('pads: %d pads, %d samples changed (one undo step)', info.res.count, changed))
    return changed
end

--- Takes the pads off again (one undo entry).
function Remove()
    local prev = PadResult
    if not prev then return false, 'there is no pad result to remove' end
    local s = Fields.Scope()
    local ok, a, b = pcall(function()
        local r = prev.rect
        local H = s:Height(1, r[1], r[2], r[3], r[4])
        local base = s:Op('path_paste', { a = H, b = prev.delta, mode = 'sub' })
        return Fields.Apply({ height = base, label = 'Remove base pads' })
    end)
    s:Free()
    if not ok then return false, tostring(a) end
    local entry = b
    if not entry then
        entry = { label = 'Remove base pads', undo = function() end, redo = function() end }
        History.Push(entry)
    end
    MoveMarkersY(prev.markers, 1)
    PadResult = false
    Follow(entry, function() PadResult = prev MoveMarkersY(prev.markers, 2) end, function() PadResult = false MoveMarkersY(prev.markers, 1) end)
    Say('pads removed')
    return a or 0
end

--- True when the markers (or the pad sizes) are not what the last Apply used.
function Stale()
    if not PadResult then return false end
    return Signature() ~= PadResult.sig
end

local padQuiet = 0
local padSig = ''

--- Per-frame tick of the panel: re-applies the pads about half a second after the markers stopped moving (when Auto is on).
function Tick()
    if not Settings.auto or not PadResult or not Map.Doc then return end
    local sig = Signature()
    if sig ~= padSig then
        padSig = sig
        padQuiet = Clock()
        return
    end
    if sig ~= PadResult.sig and Clock() - padQuiet > 0.5 then
        local _, redo = History.Depth()
        if redo == 0 then Apply() end
        padSig = Signature()
    end
end

-- ---- symmetry of a whole map ----------------------------------------------------------------------------------------------------------------------

Sym = { master = 1, combine = 'copy', seam = 0, height = true, layers = { true, true, true, true, true, true, true, true }, types = true }

-- what each master choice keeps, in the order of the native wedges (EdFieldSc.cpp)
local PARTS = {
    mirror_x = { 'left half', 'right half' },
    mirror_z = { 'upper half', 'lower half' },
    mirror_xz = { 'upper left quarter', 'upper right quarter', 'lower right quarter', 'lower left quarter' },
    rot2 = { 'upper half', 'lower half' },
    rot4 = { 'upper left quarter', 'upper right quarter', 'lower right quarter', 'lower left quarter' },
    diag = { 'part below the x = z diagonal', 'part above the x = z diagonal' },
    diag_both = { 'lower quarter', 'left quarter', 'upper quarter', 'right quarter' },
}

--- The parts one can keep with the current symmetry mode of symmetry.lua: a list of names (empty when the symmetry is off).
function Parts()
    return PARTS[Symmetry.Mode] or {}
end

--- The parameters of the native op for the current symmetry (mode and centre of symmetry.lua).
function SymParams()
    local mode = Symmetry.Mode
    if not PARTS[mode] then return nil end
    local cx, cz = Symmetry.Centre()
    local count = table.getn(PARTS[mode])
    return { mode = mode, cx = cx, cz = cz, sector = Clamp(Sym.master, 1, count) - 1, combine = Sym.combine, seam = Sym.seam }
end

local function CopyTable(t)
    local c = {}
    for k, v in t do c[k] = v end
    return c
end

--- Symmetrises heights, texture layers and terrain types from the master part (the symmetry of symmetry.lua), as ONE undo entry. Returns the number of samples changed (heights) and a table of counts.
function Symmetrize()
    if not Fields.IsAvailable() then return false, 'no field engine' end
    local params = SymParams()
    if not params then return false, 'switch a symmetry on first (Symmetry panel)' end
    local mw, mh = MapSize()
    if (params.mode == 'rot4' or params.mode == 'diag' or params.mode == 'diag_both') and mw ~= mh then return false, 'this symmetry needs a square map' end
    local label = 'Symmetrise from ' .. (PARTS[params.mode][params.sector + 1] or 'the master part')
    local s = Fields.Scope()
    local counts = { height = 0, layers = 0, types = 0 }
    local ok, err = pcall(function()
        local parts = {}
        local heightChanged = 0
        if Sym.height then
            local H = s:Height(1)
            local p = CopyTable(params)
            p.a = H
            local new = s:Op('quantize', { a = s:Op('symmetrize', p), step = 1 / WORD })
            local n = Fields.CommitHeight(new, { noHistory = true, label = label })
            heightChanged = n or 0
            counts.height = heightChanged
        end
        for layer = 1, 8 do
            if Sym.layers[layer] then
                local st = s:Stratum(layer)
                local p = CopyTable(params)
                p.a = st
                local sym = s:Op('symmetrize', p)
                local entry, n = Fields.CommitMask(sym, layer, { noPush = true, label = label })
                if entry then
                    table.insert(parts, entry)
                    counts.layers = counts.layers + (n or 0)
                end
            end
        end
        if Sym.types then
            local tt = Fields.TerrainTypes()
            s:Add(tt)
            local p = CopyTable(params)
            p.a = tt
            p.nearest = 1
            p.seam = 0
            p.combine = 'copy'
            local sym = s:Op('symmetrize', p)
            local entry, n = Fields.CommitTypes(sym, { noPush = true, label = label })
            if entry then
                table.insert(parts, entry)
                counts.types = n or 0
            end
        end
        local total = heightChanged + counts.layers + counts.types
        if total == 0 then return end
        local entry = {
            label = label,
            undo = function()
                for i = table.getn(parts), 1, -1 do parts[i].undo() end
                if heightChanged > 0 then import('/lua/editor/terrain.lua').Undo() end
            end,
            redo = function()
                if heightChanged > 0 then import('/lua/editor/terrain.lua').Redo() end
                for i = 1, table.getn(parts) do parts[i].redo() end
            end,
            release = function() for _, part in parts do part.release() end end,
        }
        History.Push(entry)
    end)
    s:Free()
    if not ok then
        Say('symmetrise failed: ' .. tostring(err))
        return false, tostring(err)
    end
    Say(string.format('symmetrised from the %s: %d height samples, %d mask samples, %d terrain types changed (one undo step)', PARTS[params.mode][params.sector + 1], counts.height, counts.layers, counts.types))
    return counts.height, counts
end

--- Markers whose symmetric image is missing: list of { name, type, x, z, ix, iz } (the position where the image should be). tol = distance in world units.
function MarkerCheck(tol)
    tol = tol or 1.5
    local out = {}
    if Symmetry.Mode == 'off' then return out end
    local markers = Markers()
    local items = {}
    for name, m in markers do
        if m and m.position and (m.type == 'Mass' or m.type == 'Hydrocarbon' or IsStart(name)) then
            table.insert(items, { name = name, type = IsStart(name) and 'start' or m.type, x = m.position[1], z = m.position[3] })
        end
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    for _, it in items do
        local pts = Symmetry.Points(it.x, it.z)
        for k = 2, table.getn(pts) do
            local q = pts[k]
            local found = false
            for _, o in items do
                if o.type == it.type then
                    local dx, dz = o.x - q.x, o.z - q.z
                    if dx * dx + dz * dz <= tol * tol then found = true break end
                end
            end
            if not found then
                table.insert(out, { name = it.name, type = it.type, x = it.x, z = it.z, ix = q.x, iz = q.z })
                break
            end
        end
    end
    return out
end

-- ---- the pathable slope limit and the ramp check ---------------------------------------------------------------------------------------------------

--- Unit classes by the footprint window of the engine's slope rule (the same table as the mask generator: maskgen.lua).
Classes = {
    { name = 'Land, small (1x1)', window = 1 },
    { name = 'Land, medium (2x2)', window = 2 },
    { name = 'Land, large (3x3)', window = 3 },
    { name = 'Experimental (5x5)', window = 5 },
}

Slope = { limit = 0.75, mode = 'both', balance = 0.5, margin = 0.03, strength = 1, layer = 0, soft = 2, class = 2, report = '' }
SlopeModes = { 'lower', 'raise', 'both' }

local function LayerMask(s, layer, like, soft)
    local st = s:Stratum(layer)
    local m = s:Op('resample', { a = st, like = like })
    if soft and soft > 0 then m = s:Op('blur', { a = m, radius = soft }) end
    return m
end

--- Blocked share (0..1) of the ground per unit class for the field H (limit = the blocking rating, 0.75 for land units).
local function BlockedShares(s, H, limit)
    local shares = {}
    for _, cls in Classes do
        local rating = s:Op('slope', { a = H, mode = 'rating', window = cls.window })
        local bad = s:Op('threshold', { a = rating, value = limit })
        local _, _, mean = Fields.Stats(bad)
        table.insert(shares, mean)
    end
    return shares
end

local function ShareText(before, after)
    local parts = {}
    for i, cls in Classes do
        if after then
            table.insert(parts, string.format('%s %.1f%% -> %.1f%%', cls.name, before[i] * 100, after[i] * 100))
        else
            table.insert(parts, string.format('%s %.1f%%', cls.name, before[i] * 100))
        end
    end
    return table.concat(parts, '   ')
end

--- Blocked share per unit class of the current terrain, as text (and the list of shares).
function SlopeReport()
    if not Fields.IsAvailable() then return '' end
    return Fields.Run(function(s)
        local H = s:Height(1)
        local shares = BlockedShares(s, H, Slope.limit)
        Slope.report = 'Ground a land unit cannot cross (rating > ' .. string.format('%.2f', Slope.limit) .. '):  ' .. ShareText(shares)
        return Slope.report, shares
    end)
end

--- A thumbnail (VFS path) of the ground that is too steep for the chosen unit class.
function SlopeThumb(size)
    if not Fields.IsAvailable() then return nil end
    return Fields.Run(function(s)
        local H = s:Height(1)
        local cls = Classes[Clamp(Slope.class, 1, table.getn(Classes))]
        local rating = s:Op('slope', { a = H, mode = 'rating', window = cls.window })
        local bad = s:Op('threshold', { a = rating, value = Slope.limit })
        return Fields.Preview(bad, size or 128, { ramp = 'heat', lo = 0, hi = 1 })
    end)
end

--- Clamps the steepest neighbour difference of the terrain to the limit (optionally only inside a texture layer's paint), one undo entry. Returns samples changed.
function SlopeApply()
    if not Fields.IsAvailable() then return false, 'no field engine' end
    local before, after
    local s = Fields.Scope()
    local ok, changed, err = pcall(function()
        local H = s:Height(1)
        before = BlockedShares(s, H, Slope.limit)
        local args = { a = H, limit = Slope.limit, mode = Slope.mode, balance = Slope.balance, margin = Slope.margin, strength = Slope.strength }
        if Slope.layer and Slope.layer >= 1 then args.mask = LayerMask(s, Slope.layer, H, Slope.soft) end
        local new = s:Op('quantize', { a = s:Op('slope_limit', args), step = 1 / WORD })
        after = BlockedShares(s, new, Slope.limit)
        return Fields.CommitHeight(new, { label = 'Slope limit' })
    end)
    s:Free()
    if not ok then
        Say('slope limit failed: ' .. tostring(changed))
        return false, tostring(changed)
    end
    Slope.report = 'Blocked ground:  ' .. ShareText(before, after)
    Say(string.format('slope limit: %d samples changed (one undo step)', changed or 0))
    return changed or 0
end

--- The grade along a polyline { {x, z}, ... } on the current terrain. opts: step (units between samples, default 1), run (grade = rise over this run, default 3), limit (default 0.75).
--- Returns { length, maxGrade, meanGrade, over (share of the length above the limit), minH, maxH, runs = { { s0, s1, x, z, grade }, ... }, samples = n }; runs are the stretches above the limit.
function RampProfile(points, opts)
    opts = opts or {}
    local step = math.max(0.25, opts.step or 1)
    local run = math.max(step, opts.run or 3)
    local limit = opts.limit or 0.75
    local report = { length = 0, maxGrade = 0, meanGrade = 0, over = 0, minH = 1e9, maxH = -1e9, runs = {}, samples = 0 }
    if not points or table.getn(points) < 2 then return report end
    local H = Fields.Height(1)
    local xs, zs, hs, ss = {}, {}, {}, {}
    local dist = 0
    local function Add(x, z, d)
        local h = Fields.Sample(H, x, z)
        table.insert(xs, x) table.insert(zs, z) table.insert(hs, h) table.insert(ss, d)
        report.minH, report.maxH = math.min(report.minH, h), math.max(report.maxH, h)
    end
    Add(points[1][1], points[1][2], 0)
    for i = 2, table.getn(points) do
        local ax, az, bx, bz = points[i - 1][1], points[i - 1][2], points[i][1], points[i][2]
        local len = math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))
        local n = math.max(1, math.ceil(len / step))
        for k = 1, n do
            local t = k / n
            Add(ax + (bx - ax) * t, az + (bz - az) * t, dist + len * t)
        end
        dist = dist + len
    end
    Fields.Free(H)
    local n = table.getn(xs)
    report.length = dist
    report.samples = n
    local sum, cnt, overLen = 0, 0, 0
    local cur
    for i = 1, n do
        -- grade over a window centred on the sample, clipped at the ends
        local j0, j1 = i, i
        while j0 > 1 and ss[i] - ss[j0] < run / 2 do j0 = j0 - 1 end
        while j1 < n and ss[j1] - ss[i] < run / 2 do j1 = j1 + 1 end
        local d = ss[j1] - ss[j0]
        local grade = d > 0 and math.abs(hs[j1] - hs[j0]) / d or 0
        report.maxGrade = math.max(report.maxGrade, grade)
        sum, cnt = sum + grade, cnt + 1
        local len = (i < n) and (ss[i + 1] - ss[i]) or 0
        if grade > limit then
            overLen = overLen + len
            if not cur then
                cur = { s0 = ss[i], s1 = ss[i], x = xs[i], z = zs[i], grade = grade }
                table.insert(report.runs, cur)
            end
            cur.s1 = ss[i]
            if grade > cur.grade then cur.grade, cur.x, cur.z = grade, xs[i], zs[i] end
        else
            cur = nil
        end
    end
    report.meanGrade = cnt > 0 and sum / cnt or 0
    report.over = dist > 0 and overLen / dist or 0
    return report
end

--- RampProfile along the curve of a path of the Paths tool (id).
function RampPath(id, opts)
    local Paths = import('/lua/editor/paths.lua')
    local path = Paths.ById(id)
    if not path or table.getn(path.points) < 2 then return nil end
    local S = Paths.Sample(path, 1)
    local pts = {}
    for i = 1, S.n do table.insert(pts, { S.x[i], S.z[i] }) end
    opts = opts or {}
    if not opts.limit then opts.limit = path.grade and path.grade > 0 and path.grade or 0.75 end
    return RampProfile(pts, opts)
end

-- ---- water coupled masks ----------------------------------------------------------------------------------------------------------------------------

Water = { Defs = {}, live = true, nextId = 1, dirty = false, quiet = 0, lastLevel = false }

Water.Kinds = {
    underwater = { label = 'Underwater', soft = 1 },
    shallows = { label = 'Shallows', soft = 1 },
    shore = { label = 'Shore line', soft = 1 },
    beach = { label = 'Beach', soft = 1 },
    deep = { label = 'Deep water', soft = 1 },
}
Water.Order = { 'beach', 'shore', 'shallows', 'underwater', 'deep' }

--- The map's water surface: elevation, or nil when the map has no water.
function WaterLevel()
    local on = World.Value('water_on')
    if on == 0 then return nil end
    return World.Value('water_elev')
end

function Water.Add(kind, layer)
    local k = Water.Kinds[kind] or Water.Kinds.beach
    local def = { id = 'w' .. Water.nextId, kind = kind, layer = layer or 1, width = 3, soft = k.soft, depth = 4, slope = 30, strength = 1, rec = false }
    Water.nextId = Water.nextId + 1
    table.insert(Water.Defs, def)
    return def
end

function Water.Remove(id)
    for i, d in Water.Defs do
        if d.id == id then
            table.remove(Water.Defs, i)
            return true
        end
    end
    return false
end

function Water.ById(id)
    for _, d in Water.Defs do
        if d.id == id then return d end
    end
end

--- The mask (0..1, on the grid of H) of a water definition at the given water level.
function Water.Mask(s, H, def, level)
    local k = def.kind
    if k == 'underwater' then
        return s:Op('water_below', { a = H, level = level, soft = def.soft })
    elseif k == 'deep' then
        return s:Op('water_below', { a = H, level = level - def.depth, soft = def.soft })
    elseif k == 'shallows' then
        return s:Op('height_band', { a = H, lo = level - def.depth, hi = level, soft = def.soft })
    elseif k == 'shore' then
        return s:Op('shore', { a = H, level = level, width = def.width, soft = def.soft })
    end
    -- beach: the land strip above the water, only where the ground is gentle
    local band = s:Op('height_band', { a = H, lo = level, hi = level + def.width, soft = def.soft })
    local deg = s:Op('slope', { a = H, mode = 'degrees', radius = 1 })
    local gentle = s:Op('smoothstep', { a = deg, edge0 = def.slope + 6, edge1 = def.slope - 6 })
    return s:Op('mul', { a = band, b = gentle })
end

--- Evaluates a definition at the current water level: returns the share of the map it covers (0..1) and a thumbnail path.
function Water.Preview(def, size)
    local level = WaterLevel()
    if not level or not Fields.IsAvailable() then return nil end
    return Fields.Run(function(s)
        local H = s:Height(1)
        local m = Water.Mask(s, H, def, level)
        local _, _, mean = Fields.Stats(m)
        local pic = Fields.Preview(m, size or 128, { ramp = 'heat', lo = 0, hi = 1 })
        return mean, pic
    end)
end

--- Writes the definition's mask into its texture layer (one undo entry). The layer keeps what was there before (`base`) and everything the user painted afterwards; the mask is added on
--- top (layer = layer + (1 - layer) x mask x strength) and replaces its own earlier result, so applying again after the water level changed moves the beach instead of piling up.
function Water.Apply(def)
    if not Fields.IsAvailable() then return false, 'no field engine' end
    local level = WaterLevel()
    if not level then return false, 'the map has no water (turn it on in the World panel)' end
    local layer = Clamp(def.layer, 1, 8)
    local prev = def.rec
    local s = Fields.Scope()
    local ok, a, b = pcall(function()
        local H = s:Height(1)
        local st = s:Stratum(layer)
        local m = Water.Mask(s, H, def, level)
        local mm = s:Op('resample', { a = m, like = st })
        if def.strength < 1 then mm = s:Op('affine', { a = mm, mul = def.strength, add = 0 }) end
        local base = st
        local user
        if prev then
            base = prev.base
            local diff = s:Op('abs', { a = s:Op('sub', { a = st, b = prev.last }) })
            user = s:Op('threshold', { a = diff, value = 0.0001 })
        else
            base = s:Op('affine', { a = st, mul = 1, add = 0 })
        end
        local inv = s:Op('affine', { a = base, mul = -1, add = 1 })
        local new = s:Op('add', { a = base, b = s:Op('mul', { a = inv, b = mm }) })
        local final = new
        if user then final = s:Op('add', { a = new, b = s:Op('mul', { a = s:Op('sub', { a = st, b = new }), b = user }) }) end
        local entry, changed = Fields.CommitMask(final, layer, { label = 'Water mask ' .. (Water.Kinds[def.kind] and Water.Kinds[def.kind].label or def.kind) })
        local rec = { base = prev and prev.base or Keep(s:Keep(base)), level = level, layer = layer }
        local readback = Fields.Stratum(layer)
        rec.last = Keep(readback)
        return changed or 0, { entry = entry, rec = rec }
    end)
    s:Free()
    if not ok then
        Say('water mask failed: ' .. tostring(a))
        return false, tostring(a)
    end
    local info = b
    def.rec = info.rec
    if info.entry then
        Follow(info.entry, function() def.rec = prev end, function() def.rec = info.rec end)
    end
    Water.lastLevel = level
    Say(string.format('water mask %s: %d samples changed at water level %.2f (one undo step)', def.kind, a, level))
    return a
end

--- Takes the result of a definition off the layer again (the paint the user added afterwards stays).
function Water.Unapply(def)
    local prev = def.rec
    if not prev then return false end
    local s = Fields.Scope()
    local ok, a = pcall(function()
        local st = s:Stratum(prev.layer)
        local diff = s:Op('abs', { a = s:Op('sub', { a = st, b = prev.last }) })
        local user = s:Op('threshold', { a = diff, value = 0.0001 })
        local final = s:Op('add', { a = prev.base, b = s:Op('mul', { a = s:Op('sub', { a = st, b = prev.base }), b = user }) })
        local entry, changed = Fields.CommitMask(final, prev.layer, { label = 'Remove water mask' })
        if entry then Follow(entry, function() def.rec = prev end, function() def.rec = false end) end
        return changed or 0
    end)
    s:Free()
    def.rec = false
    return ok and a or false
end

--- Per-frame tick: the water level changed and stayed put for 0.6 s -> every applied definition is evaluated again (not while undone steps wait for a redo).
function Water.Tick()
    if not Water.live or not Map.Doc then return end
    local level = WaterLevel()
    local any = false
    for _, d in Water.Defs do
        if d.rec then any = true end
    end
    if not any or not level then return end
    local want = false
    for _, d in Water.Defs do
        if d.rec and d.rec.level ~= level then want = true end
    end
    if not want then
        Water.quiet = 0
        return
    end
    if Water.lastSeen ~= level then
        Water.lastSeen = level
        Water.quiet = Clock()
        return
    end
    if Clock() - Water.quiet > 0.6 then
        local _, redo = History.Depth()
        if redo == 0 then
            for _, d in Water.Defs do
                if d.rec and d.rec.level ~= level then Water.Apply(d) end
            end
        end
        Water.quiet = Clock()
    end
end

--- Definitions that are applied at another water level than the map has now.
function Water.OutOfDate()
    local level = WaterLevel()
    local n = 0
    for _, d in Water.Defs do
        if d.rec and level and d.rec.level ~= level then n = n + 1 end
    end
    return n
end

-- ---- housekeeping -------------------------------------------------------------------------------------------------------------------------------------

--- Frees the native results (a new map, the editor closing) and forgets the pad result.
function Reset()
    for _, f in kept do pcall(Fields.Free, f) end
    kept = {}
    for _, r in padCreated do
        if r.delta then pcall(Fields.Free, r.delta) end
    end
    padCreated = {}
    PadResult = false
    PadOverrides = {}
    PadExtras = {}
    for _, d in Water.Defs do d.rec = false end
    Revision = Revision + 1
end
