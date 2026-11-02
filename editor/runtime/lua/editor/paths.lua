-- Paths: spline objects that shape the terrain (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T4). A path is a Catmull-Rom or Bezier curve through control points; every point has a
-- width, a falloff, a height and a bank angle. A cross-section profile curve says how the terrain follows the curve; the native path ops (EdFieldPath.cpp) turn curve + profile into a
-- height change, and the result is previewed on the real terrain, applied (replacing the path's previous result, one undo step) or baked (frozen).
--
--   data (the sidecar `_editor.lua` keeps it as `Paths = { ... }`):
--     path   { id, name, kind = 'catmull' | 'bezier', mode, closed, sym, strength, tension, grade, limitGrade, interp, erosion (thermal passes over the banks),
--              blend (units: the change spreads into the surrounding ground by a Gaussian of this width),
--              points = { { x, z, w, f, h, abs, bank, ho = {dx, dz}, hi = {dx, dz} }, ... },
--              profile = { points = { {x, v}, ... }, smooth, symmetric, preset },
--              strata = { { layer, kind = 'core' | 'bank' | 'reach', strength }, ... },
--              scatter = { on, bp, spacing, side, lateral, jitter, scaleMin, scaleMax, seed },
--              decals = { on, tex, spacing, side, lateral, size, jitter, seed } }
--     modes  carve / raise (a height offset `h` across the profile), level / ramp / road (blend towards a target height: `h` is added to the ground under the point, or is the
--            absolute height when `abs`; unpinned points between two pinned ones are interpolated along the path), river (carve to the water level minus the depth `h`, never uphill)
--
--   List, Current, Sel, Mode, Snap      state (paths, selected path id, selected point indices, 'edit' | 'draw', snap step)
--   Add / Delete / Duplicate / Copy / Paste / AddPoint / InsertPoint / DeletePoints / MovePoints / RotatePoints / SetPoint / SetField / SetProfile ...   edits, all with undo
--   Sample(path, step)                  -> dense polyline { n, x, z, w, f, bank, h, seg, t, s }
--   Report(path)                        -> { max, ys, flagged } the planned grade along the path (for the live display)
--   Preview(id) / RevertPreview()       the result on the real terrain, without an undo entry
--   Apply(id) / Bake(id) / Unapply(id)  one undo step each
--   SidecarText() / LoadSidecar(file)   the model travels with the map
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Ser = import('/lua/editor/luaser.lua')
local Map = import('/lua/editor/map.lua')

List = {}
Current = false
Sel = {}
Mode = 'edit'
Snap = 0
Revision = 0           -- bumped by every change, selection included (the overlay redraws)
DataRevision = 0       -- bumped by edits of the model only (live preview re-runs)
Results = {}           -- path id -> the applied result (native handles; not part of the undo snapshots)
Released = {}          -- release functions of the history entries that hold raw mask copies (freed with the results)
Created = {}           -- every result record ever made: undone and replaced ones live on in the history, so they are freed together (FreeResults)
Clipboard = false
Message = ''
PreviewState = false   -- { id, depth }

local nextId = 1
local STEP = 1.0
local WORD = 128

-- ---- presets and modes -------------------------------------------------------------------------------------------------------------------------

--- Cross-section profiles: x = |distance| / half width (0 = the middle line), v = how much of the effect is there.
Presets = {
    { id = 'ramp',    label = 'Ramp',            smooth = true,  points = { { 0, 1 }, { 1, 1 } } },
    { id = 'road',    label = 'Road + shoulders', smooth = true, points = { { 0, 1 }, { 0.6, 1 }, { 0.8, 0.55 }, { 1, 0.2 } } },
    { id = 'v',       label = 'V valley',        smooth = false, points = { { 0, 1 }, { 1, 0 } } },
    { id = 'u',       label = 'U canyon',        smooth = true,  points = { { 0, 1 }, { 0.55, 1 }, { 0.8, 0.85 }, { 0.93, 0.35 }, { 1, 0 } } },
    { id = 'ridge',   label = 'Ridge',           smooth = true,  points = { { 0, 1 }, { 0.4, 0.45 }, { 1, 0 } } },
    { id = 'wall',    label = 'Wall',            smooth = true,  points = { { 0, 1 }, { 0.85, 1 }, { 1, 0 } } },
    { id = 'terrace', label = 'Terrace steps',   smooth = true,  points = { { 0, 1 }, { 0.2, 1 }, { 0.28, 0.75 }, { 0.46, 0.75 }, { 0.54, 0.5 }, { 0.72, 0.5 }, { 0.8, 0.25 }, { 0.95, 0.25 }, { 1, 0 } } },
}

--- native: the op mode ('offset' | 'target'); clip: keep only lowering ('min') or raising ('max'); interp: interpolate unpinned heights; grade: has a grade limit.
Modes = {
    carve = { label = 'Carve',  native = 'offset', clip = 'none', preset = 'u',     h = -6, hLabel = 'Depth (negative cuts)' },
    raise = { label = 'Raise',  native = 'offset', clip = 'none', preset = 'ridge', h = 6,  hLabel = 'Height (positive raises)' },
    level = { label = 'Level',  native = 'target', clip = 'none', preset = 'ramp',  h = 0,  hLabel = 'Height above the ground', interp = true, grade = true },
    ramp  = { label = 'Ramp',   native = 'target', clip = 'none', preset = 'ramp',  h = 0,  hLabel = 'Height above the ground', interp = true, grade = true },
    road  = { label = 'Road',   native = 'target', clip = 'none', preset = 'road',  h = 0,  hLabel = 'Height above the ground', interp = true, grade = true },
    river = { label = 'River',  native = 'target', clip = 'min',  preset = 'u',     h = 3,  hLabel = 'Depth below the water', river = true },
}
ModeOrder = { 'carve', 'raise', 'level', 'ramp', 'road', 'river' }

local function Preset(id)
    for _, p in Presets do
        if p.id == id then return p end
    end
    return Presets[1]
end

--- The profile curve at x (0..1): a monotone cubic (Fritsch-Carlson) through the points, or the polyline (smooth = false); constant outside the first and last point.
--- The same curve the native path ops use (EdFieldPath.cpp).
function EvalProfile(points, smooth, x)
    local n = table.getn(points)
    if n == 0 then return 1 end
    if n == 1 or x <= points[1][1] then return points[1][2] end
    if x >= points[n][1] then return points[n][2] end
    local k = 1
    while k + 2 <= n and x >= points[k + 1][1] do k = k + 1 end
    local x0, y0, x1, y1 = points[k][1], points[k][2], points[k + 1][1], points[k + 1][2]
    local h = x1 - x0
    local t = (x - x0) / h
    if not smooth then return y0 + (y1 - y0) * t end
    local function Delta(i) return (points[i + 1][2] - points[i][2]) / (points[i + 1][1] - points[i][1]) end
    local function Slope(i)
        if i == 1 then return Delta(1) end
        if i == n then return Delta(n - 1) end
        local d0, d1 = Delta(i - 1), Delta(i)
        if d0 * d1 <= 0 then return 0 end
        local h0 = points[i][1] - points[i - 1][1]
        local h1 = points[i + 1][1] - points[i][1]
        local w1, w2 = 2 * h1 + h0, h1 + 2 * h0
        return (w1 + w2) / (w1 / d0 + w2 / d1)
    end
    local m0, m1 = Slope(k), Slope(k + 1)
    local t2 = t * t
    local t3 = t2 * t
    return (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * h * m0 + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * h * m1
end

-- ---- small helpers ------------------------------------------------------------------------------------------------------------------------------

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local c = {}
    for k, x in v do c[k] = Copy(x) end
    return c
end

DeepCopy = Copy

local function Changed()
    Revision = Revision + 1
end

--- The model changed without an undo entry (drags): redraw.
function Touch()
    Revision = Revision + 1
    DataRevision = DataRevision + 1
end

function ById(id)
    for _, p in List do
        if p.id == id then return p end
    end
    return nil
end

function CurrentPath()
    return Current and ById(Current) or nil
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

local function WaterLevel()
    local ok, v = pcall(function() return import('/lua/editor/world.lua').Value('water_elev') end)
    return (ok and v) or 25
end

local function Say(text)
    Message = text
    pcall(function() import('/lua/editor/ui.lua').State.message = text end)       -- best effort: a status line message
end

local function Lerp(a, b, t) return a + (b - a) * t end

local function Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function MapSize()
    local w, h = ed_terrain_info()
    return w or 257, h or 257
end

-- ---- undo: whole-state snapshots ------------------------------------------------------------------------------------------------------------------

local function Snapshot()
    return { list = Copy(List), current = Current, sel = Copy(Sel), nextId = nextId }
end

local function Restore(snap)
    List = Copy(snap.list)
    Current = snap.current
    Sel = Copy(snap.sel)
    if Current and not ById(Current) then Current = false Sel = {} end
    DataRevision = DataRevision + 1
    Changed()
end

--- Records a finished edit. `key` merges edits of one slider drag (within 1.5 s) into one undo entry.
local function Record(label, before, key)
    local after = Snapshot()
    local now = GetSystemTimeSeconds()
    local top = History.Top()
    DataRevision = DataRevision + 1
    if key and top and top.pathKey == key and top.pathTime and now - top.pathTime < 1.5 then
        top.after = after
        top.pathTime = now
        Changed()
        return
    end
    local entry = { label = label, pathKey = key, pathTime = now, before = before, after = after }
    entry.undo = function() Restore(entry.before) end
    entry.redo = function() Restore(entry.after) end
    History.Push(entry)
    Changed()
end

--- Runs fn() as one undoable edit.
function Edit(label, fn, key)
    local before = Snapshot()
    local r = fn()
    Record(label, before, key)
    return r
end

--- For drags: the state before (take it at the press), and the record at the release.
function Begin() return Snapshot() end
function End(label, before, key) Record(label, before, key) end

-- ---- construction -----------------------------------------------------------------------------------------------------------------------------

--- Level / ramp / road need heights to aim at. A new path pins its first point at the ground under it; every point added after that becomes the pinned end (ramp, road: the ground
--- under it; level: the height of the first point, a flat way) and the one before it is released (it lies on the line between the pins).
local function Pin(path)
    local m = Modes[path.mode]
    local pts = path.points
    local n = table.getn(pts)
    if not m or not m.interp or n == 0 then return end
    local function Release(p) if p.autoPin then p.autoPin = nil p.abs = false p.h = 0 end end
    local first = pts[1]
    if n == 1 then
        first.abs, first.autoPin, first.h = true, true, math.floor(Ground(first.x, first.z) * 4 + 0.5) / 4
        return
    end
    for i = 2, n - 1 do Release(pts[i]) end
    local last = pts[n]
    if not last.abs or last.autoPin then
        last.abs, last.autoPin = true, true
        last.h = (path.mode == 'level') and first.h or (math.floor(Ground(last.x, last.z) * 4 + 0.5) / 4)
    end
end

local function NewPoint(x, z, path)
    local m = Modes[path.mode] or Modes.carve
    local last = path.points[table.getn(path.points)]
    return { x = x, z = z, w = last and last.w or 6, f = last and last.f or 4, h = last and last.h or m.h, abs = false, bank = 0 }
end

local function SetPreset(path, id)
    local pr = Preset(id)
    path.profile = { points = Copy(pr.points), smooth = pr.smooth, symmetric = true, preset = pr.id }
end

function NewPath(mode, kind)
    mode = Modes[mode] and mode or 'carve'
    local id = 'p' .. nextId
    nextId = nextId + 1
    local path = {
        id = id, name = Modes[mode].label .. ' ' .. (nextId - 1), kind = kind or 'catmull', mode = mode, closed = false, sym = false, strength = 1,
        tension = 1, grade = 0.75, limitGrade = false, interp = true, erosion = 0, blend = 0, points = {}, strata = {},
        scatter = { on = false, bp = '', spacing = 6, side = 'both', lateral = 1, jitter = 0.5, scaleMin = 0.8, scaleMax = 1.2, seed = 1 },
        decals = { on = false, tex = '', spacing = 12, side = 'center', lateral = 0, size = 6, jitter = 0.2, seed = 1 },
    }
    SetPreset(path, Modes[mode].preset)
    return path
end

--- Adds a new path (selected) with an optional first point.
function Add(mode, kind, x, z)
    local before = Snapshot()
    local path = NewPath(mode, kind)
    if x then
        table.insert(path.points, NewPoint(x, z, path))
        Pin(path)
    end
    table.insert(List, path)
    Current = path.id
    Sel = x and { [1] = true } or {}
    Record('add path', before)
    return path
end

function Select(id, index, additive)
    Current = id
    if not additive then Sel = {} end
    if index then
        if additive and Sel[index] then Sel[index] = nil else Sel[index] = true end
    end
    Changed()
end

function SelectedIndices()
    local list = {}
    local path = CurrentPath()
    if not path then return list end
    for i = 1, table.getn(path.points) do
        if Sel[i] then table.insert(list, i) end
    end
    return list
end

local function SnapValue(v)
    if Snap and Snap > 0 then return math.floor(v / Snap + 0.5) * Snap end
    return v
end

function SnapPoint(x, z)
    return SnapValue(x), SnapValue(z)
end

--- Appends a point to the current path (a new one when there is none).
function AddPoint(x, z, mode, kind)
    x, z = SnapPoint(x, z)
    local before = Snapshot()
    local path = CurrentPath()
    if not path then
        path = NewPath(mode or 'carve', kind)
        table.insert(List, path)
        Current = path.id
    end
    table.insert(path.points, NewPoint(x, z, path))
    Pin(path)
    Sel = { [table.getn(path.points)] = true }
    Record('add path point', before)
    return table.getn(path.points)
end

--- Inserts a point after control point `after` (a click on a segment).
function InsertPoint(after, x, z)
    local path = CurrentPath()
    if not path then return nil end
    x, z = SnapPoint(x, z)
    local before = Snapshot()
    local a = path.points[after]
    local b = path.points[after + 1] or path.points[1]
    local p = NewPoint(x, z, path)
    if a and b then
        local d1 = math.sqrt((x - a.x) * (x - a.x) + (z - a.z) * (z - a.z))
        local d2 = math.sqrt((x - b.x) * (x - b.x) + (z - b.z) * (z - b.z))
        local t = (d1 + d2) > 0 and d1 / (d1 + d2) or 0.5
        p.w, p.f, p.h, p.bank = Lerp(a.w, b.w, t), Lerp(a.f, b.f, t), Lerp(a.h, b.h, t), Lerp(a.bank, b.bank, t)
    end
    table.insert(path.points, after + 1, p)
    Sel = { [after + 1] = true }
    Record('insert path point', before)
    return after + 1
end

function DeletePoints()
    local path = CurrentPath()
    if not path then return false end
    local idx = SelectedIndices()
    if table.getn(idx) == 0 then return false end
    local before = Snapshot()
    for k = table.getn(idx), 1, -1 do table.remove(path.points, idx[k]) end
    Sel = {}
    if table.getn(path.points) == 0 then
        for i, p in List do
            if p.id == path.id then table.remove(List, i) break end
        end
        Current = false
    end
    Record('delete path points', before)
    return true
end

function Delete(id)
    local before = Snapshot()
    for i, p in List do
        if p.id == id then table.remove(List, i) break end
    end
    if Current == id then Current = false Sel = {} end
    Record('delete path', before)
end

--- Moves the selected points (and their handles stay relative). No undo entry: drags record once with Begin / End.
function MoveBy(dx, dz, raw)
    local path = CurrentPath()
    if not path then return end
    for _, i in SelectedIndices() do
        local p = path.points[i]
        p.x = p.x + dx
        p.z = p.z + dz
    end
    Touch()
end

--- Sets the selected points to snapped positions after a drag: every point moves by the same snapped delta (anchor = the first selected).
function SnapSelection()
    if not Snap or Snap <= 0 then return end
    local path = CurrentPath()
    if not path then return end
    for _, i in SelectedIndices() do
        local p = path.points[i]
        p.x, p.z = SnapPoint(p.x, p.z)
    end
    Changed()
end

function MoveSelected(dx, dz)
    local path = CurrentPath()
    if not path or table.getn(SelectedIndices()) == 0 then
        if path and dx then
            -- no point selected: the gizmo moves the whole path
            local before = Snapshot()
            for _, p in path.points do p.x, p.z = p.x + dx, p.z + dz end
            Record('move path', before)
        end
        return
    end
    local before = Snapshot()
    MoveBy(dx, dz)
    SnapSelection()
    Record('move path points', before)
end

-- The transform gizmo drags live: the model follows the pointer while the button is down; at the release the live move is taken back and the gizmo's own move / rotate records the
-- final one as a single undo entry.
local liveMove = { 0, 0 }
local liveTurn = 0

function GizmoOffset(o)
    local path = CurrentPath()
    if not path then return end
    local function Each(fn)
        local idx = SelectedIndices()
        if table.getn(idx) == 0 then
            for i = 1, table.getn(path.points) do table.insert(idx, i) end
        end
        for _, i in idx do fn(path.points[i]) end
    end
    local nx, nz = 0, 0
    if o then nx, nz = o[1], o[2] end
    local dx, dz = nx - liveMove[1], nz - liveMove[2]
    liveMove = { nx, nz }
    if dx ~= 0 or dz ~= 0 then
        Each(function(p) p.x, p.z = p.x + dx, p.z + dz end)
        Touch()
    end
end

function GizmoTurn(deg)
    local path = CurrentPath()
    if not path then return end
    local d = (deg or 0) - liveTurn
    liveTurn = deg or 0
    if d == 0 then return end
    local cx, cz = SelectionCenter()
    if not cx then return end
    local a = math.rad(d)
    local c, s = math.cos(a), math.sin(a)
    local idx = SelectedIndices()
    if table.getn(idx) == 0 then
        for i = 1, table.getn(path.points) do table.insert(idx, i) end
    end
    for _, i in idx do
        local p = path.points[i]
        local dx, dz = p.x - cx, p.z - cz
        p.x, p.z = cx + dx * c - dz * s, cz + dx * s + dz * c
        for _, key in { 'ho', 'hi' } do
            local h = p[key]
            if h then p[key] = { h[1] * c - h[2] * s, h[1] * s + h[2] * c } end
        end
    end
    Touch()
end

--- Selects the points of the current path (else the path with the most points) inside the world box { x0, z0, x1, z1 }: how = 'set' | 'add' | 'toggle'.
function SelectInRect(box, how)
    local x0, x1 = math.min(box[1], box[3]), math.max(box[1], box[3])
    local z0, z1 = math.min(box[2], box[4]), math.max(box[2], box[4])
    local best, bestN, found = nil, 0, {}
    local function Inside(path)
        local list = {}
        for i, p in path.points do
            if p.x >= x0 and p.x <= x1 and p.z >= z0 and p.z <= z1 then table.insert(list, i) end
        end
        return list
    end
    local cur = CurrentPath()
    if cur then
        local l = Inside(cur)
        if table.getn(l) > 0 then best, found = cur, l end
    end
    if not best then
        for _, path in List do
            local l = Inside(path)
            if table.getn(l) > bestN then best, bestN, found = path, table.getn(l), l end
        end
    end
    if not best then
        if how == 'set' then Sel = {} Changed() end
        return 0
    end
    if Current ~= best.id then Current = best.id Sel = {} end
    if how == 'set' then Sel = {} end
    for _, i in found do
        if how == 'toggle' and Sel[i] then Sel[i] = nil else Sel[i] = true end
    end
    Changed()
    return table.getn(found)
end

--- Only a redraw (a marquee, a hover).
function Redraw()
    Changed()
end

--- The centre of the selected points (or of the whole path when none is selected).
function SelectionCenter()
    local path = CurrentPath()
    if not path then return nil end
    local sx, sz, n = 0, 0, 0
    local idx = SelectedIndices()
    if table.getn(idx) == 0 then
        for _, p in path.points do sx, sz, n = sx + p.x, sz + p.z, n + 1 end
    else
        for _, i in idx do sx, sz, n = sx + path.points[i].x, sz + path.points[i].z, n + 1 end
    end
    if n == 0 then return nil end
    return sx / n, sz / n
end

function RotateSelected(deg)
    local path = CurrentPath()
    if not path then return end
    local cx, cz = SelectionCenter()
    if not cx then return end
    local before = Snapshot()
    local a = math.rad(deg)
    local c, s = math.cos(a), math.sin(a)
    local idx = SelectedIndices()
    local list = {}
    if table.getn(idx) == 0 then
        for i = 1, table.getn(path.points) do table.insert(list, i) end
    else
        list = idx
    end
    for _, i in list do
        local p = path.points[i]
        local dx, dz = p.x - cx, p.z - cz
        p.x, p.z = cx + dx * c - dz * s, cz + dx * s + dz * c
        for _, key in { 'ho', 'hi' } do
            local h = p[key]
            if h then p[key] = { h[1] * c - h[2] * s, h[1] * s + h[2] * c } end
        end
    end
    Record('rotate path points', before)
end

--- Sets a field of the selected points (or of the given indices): width, falloff, height, bank, abs.
function SetPoint(key, value, key2)
    local path = CurrentPath()
    if not path then return end
    local idx = SelectedIndices()
    if table.getn(idx) == 0 then
        for i = 1, table.getn(path.points) do table.insert(idx, i) end
    end
    local before = Snapshot()
    for _, i in idx do path.points[i][key] = value end
    Record('path point ' .. key, before, key2 or ('pt:' .. key .. ':' .. path.id))
end

--- Pins (or releases) the selected points (all when none is selected): a pinned point aims at its own height `h`, starting at the ground height under it.
function SetAbsolute(on)
    local path = CurrentPath()
    if not path then return end
    local idx = SelectedIndices()
    if table.getn(idx) == 0 then
        for i = 1, table.getn(path.points) do table.insert(idx, i) end
    end
    local before = Snapshot()
    for _, i in idx do
        local p = path.points[i]
        if on and not p.abs then p.h = math.floor(Ground(p.x, p.z) * 4 + 0.5) / 4 elseif not on and p.abs then p.h = 0 end
        p.abs = on and true or false
        p.autoPin = nil
    end
    Record('path point pinned', before)
end

--- Sets a field of the current path (name, mode, kind, closed, sym, strength, tension, grade, limitGrade, interp, erosion, blend).
function SetField(key, value)
    local path = CurrentPath()
    if not path then return end
    local before = Snapshot()
    path[key] = value
    if key == 'kind' and value == 'catmull' then
        for _, p in path.points do p.ho, p.hi = nil, nil end
    end
    Record('path ' .. key, before, 'pf:' .. key .. ':' .. path.id)
end

function SetMode(mode)
    local path = CurrentPath()
    if not path or not Modes[mode] then return end
    local before = Snapshot()
    local old = Modes[path.mode]
    path.mode = mode
    local m = Modes[mode]
    SetPreset(path, m.preset)
    if old.native ~= m.native or old.river ~= m.river then
        for _, p in path.points do p.h = m.h p.abs = false end
    elseif m.native == 'offset' then
        -- carve <-> raise: the amount keeps its size, the sign follows the mode
        for _, p in path.points do p.h = (mode == 'raise') and math.abs(p.h or 0) or -math.abs(p.h or 0) end
    end
    Pin(path)
    Record('path mode', before)
end

function SetProfile(points, smooth, symmetric, preset)
    local path = CurrentPath()
    if not path then return end
    local before = Snapshot()
    path.profile = { points = Copy(points), smooth = smooth, symmetric = symmetric, preset = preset }
    Record('path profile', before, 'profile:' .. path.id)
end

function UsePreset(id)
    local path = CurrentPath()
    if not path then return end
    local pr = Preset(id)
    SetProfile(pr.points, pr.smooth, true, pr.id)
end

--- A strata entry of the current path: index 1 or 2.
function SetStrata(index, layer, kind, strength)
    local path = CurrentPath()
    if not path then return end
    local before = Snapshot()
    path.strata = path.strata or {}
    local e = path.strata[index]
    if not e then
        e = { layer = 0, kind = index == 1 and 'core' or 'bank', strength = 1 }
        path.strata[index] = e
    end
    if layer ~= nil then e.layer = layer end
    if kind ~= nil then e.kind = kind end
    if strength ~= nil then e.strength = strength end
    Record('path strata', before, 'strata:' .. index .. ':' .. path.id)
end

function SetScatter(group, key, value)
    local path = CurrentPath()
    if not path then return end
    local before = Snapshot()
    path[group] = path[group] or {}
    path[group][key] = value
    Record('path ' .. group, before, group .. ':' .. key .. ':' .. path.id)
end

function Duplicate(id)
    local src = ById(id)
    if not src then return nil end
    local before = Snapshot()
    local c = Copy(src)
    c.id = 'p' .. nextId
    nextId = nextId + 1
    c.name = src.name .. ' copy'
    for _, p in c.points do p.x, p.z = p.x + 8, p.z + 8 end
    table.insert(List, c)
    Current = c.id
    Sel = {}
    Record('duplicate path', before)
    return c
end

function CopyCurrent()
    local path = CurrentPath()
    if not path then return false end
    Clipboard = Copy(path)
    return true
end

--- Pastes the copied path with its centre at (x, z) (8 units aside when no position is given).
function Paste(x, z)
    if not Clipboard then return nil end
    local before = Snapshot()
    local c = Copy(Clipboard)
    local sx, sz, n = 0, 0, 0
    for _, p in c.points do sx, sz, n = sx + p.x, sz + p.z, n + 1 end
    local dx, dz = 8, 8
    if x and n > 0 then dx, dz = x - sx / n, z - sz / n end
    for _, p in c.points do p.x, p.z = p.x + dx, p.z + dz end
    c.id = 'p' .. nextId
    nextId = nextId + 1
    c.name = Clipboard.name .. ' copy'
    table.insert(List, c)
    Current = c.id
    Sel = {}
    Record('paste path', before)
    return c
end

-- ---- symmetry images ----------------------------------------------------------------------------------------------------------------------------

--- The images of the symmetry mode: a list of { f(x, z) -> x, z, mirror = true when the image is a reflection }.
function ImageMaps()
    local mode = Symmetry.Mode
    local cx, cz = Symmetry.Centre()
    local maps = {}
    local function Add(f, mirror) table.insert(maps, { f = f, mirror = mirror }) end
    local function Rot180(x, z) return 2 * cx - x, 2 * cz - z end
    if mode == 'mirror_x' then
        Add(function(x, z) return 2 * cx - x, z end, true)
    elseif mode == 'mirror_z' then
        Add(function(x, z) return x, 2 * cz - z end, true)
    elseif mode == 'mirror_xz' then
        Add(function(x, z) return 2 * cx - x, z end, true)
        Add(function(x, z) return x, 2 * cz - z end, true)
        Add(Rot180, false)
    elseif mode == 'rot2' then
        Add(Rot180, false)
    elseif mode == 'rot4' then
        Add(function(x, z) return cx - (z - cz), cz + (x - cx) end, false)
        Add(Rot180, false)
        Add(function(x, z) return cx + (z - cz), cz - (x - cx) end, false)
    elseif mode == 'diag' then
        Add(function(x, z) return cx + (z - cz), cz + (x - cx) end, true)
    elseif mode == 'diag_both' then
        Add(function(x, z) return cx + (z - cz), cz + (x - cx) end, true)
        Add(function(x, z) return cx - (z - cz), cz - (x - cx) end, true)
        Add(Rot180, false)
    end
    return maps
end

--- A copy of the path moved through an image map (positions and handle vectors; a reflection flips the bank and an asymmetric profile).
local function ImagePath(path, map)
    local c = Copy(path)
    for _, p in c.points do
        local x, z = p.x, p.z
        p.x, p.z = map.f(x, z)
        for _, key in { 'ho', 'hi' } do
            local h = p[key]
            if h then
                local ax, az = map.f(x, z)
                local bx, bz = map.f(x + h[1], z + h[2])
                p[key] = { bx - ax, bz - az }
            end
        end
        if map.mirror then p.bank = -(p.bank or 0) end
    end
    if map.mirror and c.profile and not c.profile.symmetric then
        local flipped = {}
        for i = table.getn(c.profile.points), 1, -1 do
            local q = c.profile.points[i]
            table.insert(flipped, { 1 - q[1], q[2] })
        end
        c.profile.points = flipped
    end
    return c
end

-- ---- curve sampling -----------------------------------------------------------------------------------------------------------------------------

local function WrapIndex(i, n) return math.mod(i - 1 + n, n) + 1 end

--- Out and in handle vectors (offsets from the point) of every control point.
local function HandleVectors(path)
    local pts = path.points
    local n = table.getn(pts)
    local out, inn = {}, {}
    for i = 1, n do
        local p = pts[i]
        local prev = (i > 1 and pts[i - 1]) or (path.closed and n > 2 and pts[n]) or nil
        local nxt = (i < n and pts[i + 1]) or (path.closed and n > 2 and pts[1]) or nil
        local ho, hi
        if path.kind == 'bezier' and (p.ho or p.hi) then
            ho = p.ho and { p.ho[1], p.ho[2] } or nil
            hi = p.hi and { p.hi[1], p.hi[2] } or nil
            if not hi then hi = { -ho[1], -ho[2] } end
            if not ho then ho = { -hi[1], -hi[2] } end
        elseif path.kind == 'bezier' then
            local px, pz = prev and prev.x or p.x, prev and prev.z or p.z
            local qx, qz = nxt and nxt.x or p.x, nxt and nxt.z or p.z
            local dx, dz = qx - px, qz - pz
            local dl = math.sqrt(dx * dx + dz * dz)
            if dl > 0.0001 then dx, dz = dx / dl, dz / dl else dx, dz = 0, 0 end
            local lo = nxt and math.sqrt((nxt.x - p.x) * (nxt.x - p.x) + (nxt.z - p.z) * (nxt.z - p.z)) / 3 or 0
            local li = prev and math.sqrt((p.x - prev.x) * (p.x - prev.x) + (p.z - prev.z) * (p.z - prev.z)) / 3 or 0
            local t = path.tension or 1
            ho = { dx * lo * t, dz * lo * t }
            hi = { -dx * li * t, -dz * li * t }
        else
            local px, pz = prev and prev.x or p.x, prev and prev.z or p.z
            local qx, qz = nxt and nxt.x or p.x, nxt and nxt.z or p.z
            local t = (path.tension or 1) / 6
            ho = { (qx - px) * t, (qz - pz) * t }
            hi = { -(qx - px) * t, -(qz - pz) * t }
        end
        out[i], inn[i] = ho, hi
    end
    return out, inn
end

HandleVectorsOf = HandleVectors

--- Dense polyline of the curve: arrays x, z, w, f, bank, h, seg (control point the segment starts at), t (0..1 inside the segment), s (arc length), and ctrlS (arc length at every control point).
function Sample(path, step)
    step = step or STEP
    local pts = path.points
    local n = table.getn(pts)
    local S = { n = 0, x = {}, z = {}, w = {}, f = {}, bank = {}, h = {}, seg = {}, t = {}, s = {}, ctrlS = {} }
    if n == 0 then return S end
    local out, inn = HandleVectors(path)
    local nseg = path.closed and n > 2 and n or (n - 1)
    local k = 0
    local len = 0
    local function Push(x, z, a, b, t, seg)
        k = k + 1
        if k > 1 then
            local dx, dz = x - S.x[k - 1], z - S.z[k - 1]
            len = len + math.sqrt(dx * dx + dz * dz)
        end
        S.x[k], S.z[k] = x, z
        S.w[k], S.f[k] = Lerp(a.w, b.w, t), Lerp(a.f, b.f, t)
        S.bank[k], S.h[k] = Lerp(a.bank or 0, b.bank or 0, t), Lerp(a.h or 0, b.h or 0, t)
        S.seg[k], S.t[k], S.s[k] = seg, t, len
    end
    if nseg < 1 then
        local p = pts[1]
        Push(p.x, p.z, p, p, 0, 1)
        S.n = 1
        S.ctrlS[1] = 0
        return S
    end
    for i = 1, nseg do
        local j = WrapIndex(i + 1, n)
        local a, b = pts[i], pts[j]
        local p0x, p0z = a.x, a.z
        local p1x, p1z = a.x + out[i][1], a.z + out[i][2]
        local p2x, p2z = b.x + inn[j][1], b.z + inn[j][2]
        local p3x, p3z = b.x, b.z
        local poly = math.sqrt((p1x - p0x) * (p1x - p0x) + (p1z - p0z) * (p1z - p0z)) + math.sqrt((p2x - p1x) * (p2x - p1x) + (p2z - p1z) * (p2z - p1z))
                   + math.sqrt((p3x - p2x) * (p3x - p2x) + (p3z - p2z) * (p3z - p2z))
        local count = Clamp(math.ceil(poly / step), 2, 400)
        local last = (i == nseg) and count or (count - 1)
        -- positions first: the attributes run along the arc length of the segment (not the curve parameter, which is fast in the middle)
        local qx, qz, cum = {}, {}, {}
        local total = 0
        for q = 0, count do
            local t = q / count
            local u = 1 - t
            local c0, c1, c2, c3 = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
            qx[q], qz[q] = c0 * p0x + c1 * p1x + c2 * p2x + c3 * p3x, c0 * p0z + c1 * p1z + c2 * p2z + c3 * p3z
            if q > 0 then total = total + math.sqrt((qx[q] - qx[q - 1]) * (qx[q] - qx[q - 1]) + (qz[q] - qz[q - 1]) * (qz[q] - qz[q - 1])) end
            cum[q] = total
        end
        for q = 0, last do
            local frac = total > 0.00001 and cum[q] / total or (q / count)
            if q == count then frac = 1 end
            Push(qx[q], qz[q], a, b, frac, i)
            if q == 0 then S.ctrlS[i] = len end
        end
    end
    S.ctrlS[nseg + 1] = len
    S.n = k
    return S
end

--- Total length of the path.
function Length(path)
    local S = Sample(path, 2)
    return S.s[S.n] or 0
end

-- ---- heights and grade ---------------------------------------------------------------------------------------------------------------------------

local function LimitGrade(y, s, g, pin)
    local n = table.getn(y)
    for pass = 1, 3 do
        for k = 2, n do
            if not pin[k] then
                local ds = s[k] - s[k - 1]
                y[k] = Clamp(y[k], y[k - 1] - g * ds, y[k - 1] + g * ds)
            end
        end
        for k = n - 1, 1, -1 do
            if not pin[k] then
                local ds = s[k + 1] - s[k]
                y[k] = Clamp(y[k], y[k + 1] - g * ds, y[k + 1] + g * ds)
            end
        end
    end
end

--- Target heights along the dense samples (target modes) or the offsets (offset modes): ys, offs. `ground(x, z)` gives the terrain the path starts from.
function Heights(path, S, ground)
    local m = Modes[path.mode] or Modes.carve
    local n = S.n
    local pts = path.points
    local pc = table.getn(pts)
    local ys, offs = {}, {}
    if m.native == 'offset' then
        for k = 1, n do offs[k] = S.h[k] ys[k] = 0 end
        return ys, offs
    end
    -- heights at the control points
    local yc, pinned = {}, {}
    local water = WaterLevel()
    for i = 1, pc do
        local p = pts[i]
        if p.abs then
            yc[i], pinned[i] = p.h, true
        elseif m.river then
            yc[i] = water - (p.h or 0)
        else
            yc[i] = ground(p.x, p.z) + (p.h or 0)
        end
    end
    if m.interp and path.interp ~= false then
        -- unpinned points between two pinned ones lie on the straight line (in arc length) between them
        local lastPin = nil
        for i = 1, pc do
            if pinned[i] then
                if lastPin and i - lastPin > 1 then
                    local s0, s1 = S.ctrlS[lastPin] or 0, S.ctrlS[i] or 0
                    for j = lastPin + 1, i - 1 do
                        local sj = S.ctrlS[j] or 0
                        local t = (s1 > s0) and (sj - s0) / (s1 - s0) or 0
                        yc[j] = Lerp(yc[lastPin], yc[i], t) + (pts[j].h or 0)
                    end
                end
                lastPin = i
            end
        end
    end
    local pin = {}
    for k = 1, n do
        local a = S.seg[k]
        local b = WrapIndex(a + 1, pc)
        ys[k] = Lerp(yc[a], yc[b], S.t[k])
        local t = S.t[k]
        pin[k] = (t == 0 and pinned[a]) or (t == 1 and pinned[b]) or false
        offs[k] = 0
    end
    if path.limitGrade and m.grade then
        LimitGrade(ys, S.s, path.grade or 0.75, pin)
    end
    if m.river then
        for k = 2, n do
            if ys[k] > ys[k - 1] then ys[k] = ys[k - 1] end
        end
    end
    return ys, offs
end

--- The planned grade (rise per run, over windows of about 3 units) along the path: { max, over = fraction above the limit, flagged = { {k0, k1}, ... }, S }.
function Report(path)
    local S = Sample(path, STEP)
    local m = Modes[path.mode] or Modes.carve
    local rep = { max = 0, over = 0, flagged = {}, S = S, ys = nil }
    if S.n < 2 then return rep end
    local ys = Heights(path, S, Ground)
    if m.native == 'offset' then
        -- the surface after the offset follows the ground plus the offset
        for k = 1, S.n do ys[k] = Ground(S.x[k], S.z[k]) + S.h[k] end
    end
    rep.ys = ys
    local limit = path.grade or 0.75
    local flagged = {}
    local k = 1
    local total, bad = 0, 0
    while k < S.n do
        local j = k + 1
        while j < S.n and S.s[j] - S.s[k] < 3 do j = j + 1 end
        local ds = S.s[j] - S.s[k]
        local g = ds > 0.01 and math.abs(ys[j] - ys[k]) / ds or 0
        if g > rep.max then rep.max = g end
        total = total + ds
        if g > limit + 0.0001 then
            bad = bad + ds
            local last = flagged[table.getn(flagged)]
            if last and last[2] >= k then last[2] = j else table.insert(flagged, { k, j }) end
        end
        k = j
    end
    rep.flagged = flagged
    rep.over = total > 0 and bad / total or 0
    return rep
end

-- ---- the native build ---------------------------------------------------------------------------------------------------------------------------

local function Bounds(sets, extra)
    local x0, z0, x1, z1 = 1e9, 1e9, -1e9, -1e9
    for _, set in sets do
        local S = set.S
        for k = 1, S.n do
            local r = S.w[k] + S.f[k] + 2 + (extra or 0)
            if S.x[k] - r < x0 then x0 = S.x[k] - r end
            if S.z[k] - r < z0 then z0 = S.z[k] - r end
            if S.x[k] + r > x1 then x1 = S.x[k] + r end
            if S.z[k] + r > z1 then z1 = S.z[k] + r end
        end
    end
    return x0, z0, x1, z1
end

--- The path and its symmetry images: list of { path, S }.
local function ImageSets(path)
    local sets = { { path = path, S = Sample(path, STEP) } }
    if path.sym then
        for _, map in ImageMaps() do
            local ip = ImagePath(path, map)
            table.insert(sets, { path = ip, S = Sample(ip, STEP) })
        end
    end
    return sets
end

local function FlatPts(S, ys, offs)
    local flat = {}
    for k = 1, S.n do
        table.insert(flat, S.x[k]) table.insert(flat, S.z[k]) table.insert(flat, ys[k])
        table.insert(flat, S.w[k]) table.insert(flat, S.f[k]) table.insert(flat, S.bank[k]) table.insert(flat, offs[k]) table.insert(flat, S.s[k])
    end
    return flat
end

local function ProfileParams(path)
    local flat = {}
    for _, q in path.profile.points do
        table.insert(flat, q[1]) table.insert(flat, q[2])
    end
    return { profile = flat, smooth = path.profile.smooth and 1 or 0, symmetric = path.profile.symmetric and 1 or 0 }
end

--- Pts for a native call of a path (identity) and the parameters of its profile.
function NativeArgs(path, S, ground)
    local ys, offs = Heights(path, S, ground or Ground)
    local params = ProfileParams(path)
    params.pts = FlatPts(S, ys, offs)
    return params
end

local function Union(a, b)
    if not a then return b end
    if not b then return a end
    return { math.min(a[1], b[1]), math.min(a[2], b[2]), math.max(a[3], b[3]), math.max(a[4], b[4]) }
end

--- Builds the new heights (quantised to the map's words) and the strata layers of a path. `s` is a Fields scope owning all temporaries; the result keeps its handles in `s`.
--- Returns { rect, base, new, delta, masks = { {layer, base, new, delta, cover} }, sets }.
local function Build(path, s, wantMasks, chain)
    local mw, mh = MapSize()
    local sets = ImageSets(path)
    local blend = Clamp(path.blend or 0, 0, 80)
    local bx0, bz0, bx1, bz1 = Bounds(sets, blend * 3)
    local rect = { bx0, bz0, bx1, bz1 }
    local old = Results[path.id]
    if old and old.rect then rect = Union(rect, old.rect) end
    local x0 = Clamp(math.floor(rect[1]), 0, mw - 1)
    local z0 = Clamp(math.floor(rect[2]), 0, mh - 1)
    local x1 = Clamp(math.ceil(rect[3]), 0, mw - 1)
    local z1 = Clamp(math.ceil(rect[4]), 0, mh - 1)
    if x1 <= x0 or z1 <= z0 then error('the path lies outside the map') end
    local H = s:Height(1, x0, z0, x1, z1)
    -- paths previewed together: the ground this path starts from already holds the result of the paths before it
    for _, prev in (chain or {}) do
        H = s:Op('path_paste', { a = H, b = prev.new, mode = 'set' })
    end
    local base = H
    if old and old.delta then base = s:Op('path_paste', { a = H, b = old.delta, mode = 'sub' }) end
    local ground = function(x, z) return Fields.Sample(base, x, z) end
    local m = Modes[path.mode] or Modes.carve
    local cur = base
    for _, set in sets do
        local args = NativeArgs(set.path, set.S, ground)
        args.a = cur
        args.mode = m.native
        args.clip = m.clip
        args.strength = path.strength or 1
        cur = s:Op('path_shape', args)
    end
    if blend > 0 then
        -- blend: the change spreads into the surrounding ground. The blurred change is added where it is stronger than the shaped one (the core keeps its depth, the edge gets a soft skirt)
        local d = s:Op('sub', { a = cur, b = base })
        local soft = s:Op('blur', { a = d, radius = blend })
        local up = s:Op('max', { a = s:Op('clamp', { a = d, lo = 0, hi = 100000 }), b = s:Op('clamp', { a = soft, lo = 0, hi = 100000 }) })
        local down = s:Op('min', { a = s:Op('clamp', { a = d, lo = -100000, hi = 0 }), b = s:Op('clamp', { a = soft, lo = -100000, hi = 0 }) })
        cur = s:Op('add', { a = base, b = s:Op('add', { a = up, b = down }) })
    end
    if (path.erosion or 0) > 0 then
        -- bank erosion: thermal passes over the whole reach of the path (the cut walls slump to a natural talus)
        local reach
        for _, set in sets do
            local args = ProfileParams(set.path)
            local zeros = {}
            for k = 1, set.S.n do zeros[k] = 0 end
            args.pts = FlatPts(set.S, zeros, zeros)
            args.like = base
            args.kind = 'reach'
            args.soft = 3
            local mk = s:Op('path_mask', args)
            reach = reach and s:Op('max', { a = reach, b = mk }) or mk
        end
        cur = s:Op('thermal', { a = cur, mask = reach, iterations = path.erosion, talus = 0.5, rate = 0.5 })
    end
    local new = s:Op('quantize', { a = cur, step = 1 / WORD })
    local plan = { rect = { x0, z0, x1, z1 }, base = base, new = new, delta = s:Op('sub', { a = new, b = base }), masks = {}, sets = sets }
    if wantMasks then
        local layers = {}
        for _, e in (path.strata or {}) do
            if e.layer and e.layer >= 1 and e.layer <= 8 then
                local rec = layers[e.layer]
                if not rec then
                    local st = s:Stratum(e.layer)
                    local oldM = old and old.masks and old.masks[e.layer]
                    local b = st
                    if oldM then b = s:Op('sub', { a = st, b = oldM }) end
                    rec = { layer = e.layer, base = b, cur = b, cover = false, like = st }
                    layers[e.layer] = rec
                    table.insert(plan.masks, rec)
                end
                local mask
                for _, set in sets do
                    local args = ProfileParams(set.path)
                    local zeros = {}
                    for k = 1, set.S.n do zeros[k] = 0 end
                    args.pts = FlatPts(set.S, zeros, zeros)
                    args.like = rec.like
                    args.kind = e.kind or 'core'
                    local mk = s:Op('path_mask', args)
                    mask = mask and s:Op('max', { a = mask, b = mk }) or mk
                end
                local strength = e.strength or 1
                if strength < 1 then mask = s:Op('affine', { a = mask, mul = strength, add = 0 }) end
                local inv = s:Op('affine', { a = rec.cur, mul = -1, add = 1 })
                local prod = s:Op('mul', { a = inv, b = mask })
                rec.cur = s:Op('add', { a = rec.cur, b = prod })
                rec.cover = rec.cover and s:Op('max', { a = rec.cover, b = mask }) or mask
            end
        end
        for _, rec in plan.masks do
            -- the commit touches exactly the samples the paint covers now or covered before (whole new values there, the rest of the layer stays byte for byte)
            rec.cover = s:Op('threshold', { a = rec.cover, value = 0 })
            local oldM = old and old.masks and old.masks[rec.layer]
            if oldM then
                local was = s:Op('threshold', { a = s:Op('abs', { a = oldM }), value = 0.000001 })
                rec.cover = s:Op('max', { a = rec.cover, b = was })
            end
            rec.delta = s:Op('sub', { a = rec.cur, b = rec.base })
        end
    end
    return plan
end

-- ---- scatter along the path ------------------------------------------------------------------------------------------------------------------------

local function Lcg(seed)
    local state = math.mod(seed * 7919 + 12345, 2147483647)
    return function()
        state = math.mod(state * 16807, 2147483647)
        return state / 2147483647
    end
end

--- Item positions along the path: list of { x, z, heading, scale }.
function ScatterPlan(path, cfg)
    local S = Sample(path, STEP)
    local items = {}
    if S.n < 2 or not cfg or not cfg.on then return items end
    local rnd = Lcg(cfg.seed or 1)
    local spacing = math.max(0.5, cfg.spacing or 6)
    local total = S.s[S.n]
    local d = spacing / 2
    local flip = 1
    local k = 1
    while d < total and table.getn(items) < 4000 do
        while k < S.n and S.s[k + 1] < d do k = k + 1 end
        local j = math.min(S.n, k + 1)
        local ds = S.s[j] - S.s[k]
        local t = ds > 0.0001 and (d - S.s[k]) / ds or 0
        local x, z = Lerp(S.x[k], S.x[j], t), Lerp(S.z[k], S.z[j], t)
        local dx, dz = S.x[j] - S.x[k], S.z[j] - S.z[k]
        local dl = math.sqrt(dx * dx + dz * dz)
        local nx, nz = 0, 0
        if dl > 0.0001 then nx, nz = -dz / dl, dx / dl end
        local w = Lerp(S.w[k], S.w[j], t)
        local sides = { 0 }
        local side = cfg.side or 'both'
        if side == 'both' then sides = { -1, 1 } elseif side == 'left' then sides = { -1 } elseif side == 'right' then sides = { 1 } end
        for _, sd in sides do
            local lat = (sd == 0) and 0 or sd * (w + (cfg.lateral or 0))
            local jx = (rnd() - 0.5) * 2 * (cfg.jitter or 0)
            local jz = (rnd() - 0.5) * 2 * (cfg.jitter or 0)
            local lo, hi = cfg.scaleMin or 1, cfg.scaleMax or 1
            table.insert(items, { x = x + nx * lat + jx, z = z + nz * lat + jz, heading = rnd() * 6.2831853, scale = lo + (hi - lo) * rnd() })
        end
        d = d + spacing
        flip = -flip
    end
    return items
end

local function FindProp(bp, x, z)
    for i = 1, ed_prop_count() do
        local b, px, py, pz = ed_prop_get(i)
        if b == bp then
            local dx, dz = px - x, pz - z
            if dx * dx + dz * dz < 0.0004 then return i end
        end
    end
    return nil
end

local function FindDecal(tex, x, z)
    for i = ed_decal_count(), 1, -1 do
        local t0, t1, kind, px, py, pz = ed_decal_get(i)
        if t0 == tex then
            local dx, dz = px - x, pz - z
            if dx * dx + dz * dz < 0.0004 then return i end
        end
    end
    return nil
end

--- Adds / removes the items of a scatter result record { props = {...}, decals = {...} }.
local function ScatterAdd(res)
    if not res then return end
    for _, it in (res.props or {}) do
        if not FindProp(it.bp, it.x, it.z) then Map.AddProp(it.bp, it.x, it.y, it.z, it.heading, it.scale) end
    end
    for _, it in (res.decals or {}) do
        if not FindDecal(it.tex, it.x, it.z) then Map.AddDecal(it.tex, 'albedo', it.x, it.y, it.z, it.heading, it.size, it.cutoff) end
    end
end

local function ScatterRemove(res)
    if not res then return end
    for _, it in (res.props or {}) do
        local idx = FindProp(it.bp, it.x, it.z)
        if idx then Map.RemoveProp(idx) end
    end
    for _, it in (res.decals or {}) do
        local idx = FindDecal(it.tex, it.x, it.z)
        if idx then Map.RemoveDecal(idx) end
    end
end

--- The scatter result record of a path for the terrain after it was shaped (heights read from the document).
local function ScatterBuild(path)
    local res = { props = {}, decals = {} }
    local cfg = path.scatter
    if cfg and cfg.on and cfg.bp and cfg.bp ~= '' then
        for _, it in ScatterPlan(path, cfg) do
            table.insert(res.props, { bp = cfg.bp, x = it.x, y = Ground(it.x, it.z), z = it.z, heading = it.heading, scale = it.scale })
        end
    end
    local dc = path.decals
    if dc and dc.on and dc.tex and dc.tex ~= '' then
        for _, it in ScatterPlan(path, dc) do
            table.insert(res.decals, { tex = dc.tex, x = it.x, y = Ground(it.x, it.z), z = it.z, heading = it.heading, size = (dc.size or 6) * it.scale, cutoff = 1000 })
        end
    end
    return res
end

-- ---- what the last preview / apply did ---------------------------------------------------------------------------------------------------------

LastStats = false      -- { kind = 'preview' | 'apply', id, n = samples changed, lo, hi = lowest and highest height change }

local HINTS = {
    carve = 'the depth is 0: raise the Height slider (negative cuts)',
    raise = 'the height is 0: raise the Height slider (positive raises)',
    level = 'every point lies on the ground already: pin points (Absolute height) and give them heights',
    ramp = 'the ends lie on the ground already: pin the first and last point (Absolute height) and give them different heights',
    road = 'the ends lie on the ground already: pin the first and last point (Absolute height) and give them different heights',
    river = 'the terrain along the path is already below the water level minus the depth',
}

local function NoteStats(kind, path, plan, n)
    local lo, hi = Fields.Stats(plan.delta)
    LastStats = { kind = kind, id = path.id, n = n or 0, lo = lo or 0, hi = hi or 0, mode = path.mode }
end

--- One line about the last preview / apply, e.g. 'applied: 1427 samples, height change -6.0 .. +0.0 units'.
function StatsText()
    local st = LastStats
    if not st then return '' end
    local what = st.kind == 'preview' and 'preview' or 'applied'
    if math.abs(st.lo) < 0.01 and math.abs(st.hi) < 0.01 then
        return what .. ': the path changes nothing - ' .. (HINTS[st.mode] or 'check its heights')
    end
    return string.format('%s: %d samples, height change %+.1f .. %+.1f', what, st.n, st.lo, st.hi)
end

-- ---- preview, apply, bake ------------------------------------------------------------------------------------------------------------------------

--- Takes the live preview off the terrain (when nothing else was edited since).
function RevertPreview()
    local st = PreviewState
    if not st then return end
    PreviewState = false
    local depth = Terrain.UndoDepth()
    if depth == st.depth then
        Terrain.Undo()
    end
    Changed()
end

function HasPreview()
    return PreviewState and true or false
end

-- The preview is a native terrain step without a history entry. When a terrain edit lands on top of it (a brush stroke), the preview becomes an ordinary entry placed before that edit's
-- entry, so history and native stack stay in step; an undo or redo request with a preview showing only takes the preview off.
History.Before = function(entry)
    local st = PreviewState
    if st and Terrain.UndoDepth() ~= st.depth then
        PreviewState = false
        History.PushQuiet({ kind = 'terrain', label = 'path preview' })
    end
end
History.PreUndo = function()
    if PreviewState then
        RevertPreview()
        return true
    end
    return false
end

--- Shows the result of one path (`id`) or of several (`id` a list of path ids, previewed together in that order: a later path starts from the ground the earlier ones made) on the real
--- terrain (heights only), as one native step; the next Preview, Apply or tool change takes it away first.
function Preview(id)
    if not Fields.IsAvailable() then return false, 'no field engine' end
    local ids = type(id) == 'table' and id or { id }
    local paths = {}
    for _, i in ids do
        local path = ById(i)
        if path and table.getn(path.points) >= 1 then table.insert(paths, path) end
    end
    if table.getn(paths) == 0 then return false, 'no path' end
    RevertPreview()
    local s = Fields.Scope()
    local plans = {}
    local ok, err = pcall(function()
        for _, path in paths do
            table.insert(plans, Build(path, s, false, plans))
        end
    end)
    if not ok then
        s:Free()
        return false, tostring(err)
    end
    -- one field holds the final heights of every plan: the ground, then each plan's rectangle pasted over it in order
    local result = plans[1].new
    local rect = plans[1].rect
    if table.getn(plans) > 1 then
        for _, plan in plans do rect = Union(rect, plan.rect) end
        local H = s:Height(1, rect[1], rect[2], rect[3], rect[4])
        for _, plan in plans do H = s:Op('path_paste', { a = H, b = plan.new, mode = 'set' }) end
        result = H
    end
    -- the document's redo list is cleared by a new edit: do the same in the history so the two stay in step
    if History.DropRedo then History.DropRedo() end
    local n, cerr = Fields.CommitHeight(result, { noHistory = true, label = 'Path preview' })
    if n then NoteStats('preview', paths[1], plans[1], n) end
    s:Free()
    if not n then return false, tostring(cerr) end
    if n > 0 then PreviewState = { id = paths[1].id, ids = ids, depth = Terrain.UndoDepth() } end
    Changed()
    return true, n
end

local function KeepResult(plan, s, path)
    local res = { rect = plan.rect, delta = s:Keep(plan.delta), masks = {} }
    for _, rec in plan.masks do
        res.masks[rec.layer] = s:Keep(rec.delta)
    end
    table.insert(Created, res)
    return res
end

local function WrapEntry(entry, id, prev, res)
    local undo0, redo0 = entry.undo, entry.redo
    entry.undo = function()
        undo0()
        ScatterRemove(res)
        ScatterAdd(prev)
        Results[id] = prev
        Changed()
    end
    entry.redo = function()
        redo0()
        ScatterRemove(prev)
        ScatterAdd(res)
        Results[id] = res
        Changed()
    end
end

--- Applies the path to the terrain: replaces the path's previous result, one undo entry. Returns the number of height samples that changed.
function Apply(id)
    if not Fields.IsAvailable() then return false, 'no field engine' end
    local path = ById(id)
    if not path or table.getn(path.points) < 1 then return false, 'no path' end
    RevertPreview()
    local s = Fields.Scope()
    local ok, plan = pcall(Build, path, s, true)
    if not ok then
        s:Free()
        return false, tostring(plan)
    end
    local prev = Results[id]
    local masks = {}
    for _, rec in plan.masks do
        table.insert(masks, { layer = rec.layer, field = rec.cur, opts = { mask = rec.cover } })
    end
    local label = 'Apply path ' .. (path.name or id)
    local changed, entry = Fields.Apply({ height = plan.new, masks = masks, label = label })
    if entry and entry.release then table.insert(Released, entry.release) end
    local res = KeepResult(plan, s, path)
    res.props = nil
    NoteStats('apply', path, plan, changed or 0)
    s:Free()
    -- scatter: remove the previous items, add the new ones
    local sc = ScatterBuild(path)
    if table.getn(sc.props) > 0 then res.props = sc.props end
    if table.getn(sc.decals) > 0 then res.decals = sc.decals end
    ScatterRemove(prev)
    ScatterAdd(res)
    Results[id] = res
    if not entry then
        entry = { label = label, undo = function() end, redo = function() end }
        History.Push(entry)
    end
    WrapEntry(entry, id, prev, res)
    Changed()
    return changed or 0
end

--- Freezes the result: the next Apply adds to the terrain instead of replacing the result.
function Bake(id)
    local res = Results[id]
    if not res then return false end
    Results[id] = nil
    History.Push({
        label = 'Bake path',
        undo = function() Results[id] = res Changed() end,
        redo = function() Results[id] = nil Changed() end,
    })
    Changed()
    return true
end

--- Takes the path's result off the terrain again (one undo step).
function Unapply(id)
    local res = Results[id]
    if not res then return false, 'this path has no result to remove' end
    RevertPreview()
    local s = Fields.Scope()
    local mw, mh = MapSize()
    local r = res.rect
    local H = s:Height(1, r[1], r[2], r[3], r[4])
    local base = s:Op('path_paste', { a = H, b = res.delta, mode = 'sub' })
    local masks = {}
    for layer, d in res.masks do
        local st = s:Stratum(layer)
        local b = s:Op('sub', { a = st, b = d })
        local cover = s:Op('threshold', { a = s:Op('abs', { a = d }), value = 0.000001 })
        table.insert(masks, { layer = layer, field = b, opts = { mask = cover } })
    end
    local changed, entry = Fields.Apply({ height = base, masks = masks, label = 'Remove path result' })
    if entry and entry.release then table.insert(Released, entry.release) end
    s:Free()
    ScatterRemove(res)
    Results[id] = nil
    if not entry then
        entry = { label = 'Remove path result', undo = function() end, redo = function() end }
        History.Push(entry)
    end
    WrapEntry(entry, id, res, nil)
    Changed()
    return changed or 0
end

-- ---- analysis: is the corridor pathable? -----------------------------------------------------------------------------------------------------------

--- Fraction of the path's core corridor on the CURRENT terrain that a land unit cannot cross (engine slope rule 0.75), and the number of corridor samples.
function Pathable(id, limit)
    local path = ById(id)
    if not path or table.getn(path.points) < 2 then return nil end
    local sets = ImageSets(path)
    local x0, z0, x1, z1 = Bounds(sets)
    local mw, mh = MapSize()
    x0, z0 = Clamp(math.floor(x0), 0, mw - 1), Clamp(math.floor(z0), 0, mh - 1)
    x1, z1 = Clamp(math.ceil(x1), 0, mw - 1), Clamp(math.ceil(z1), 0, mh - 1)
    if x1 <= x0 or z1 <= z0 then return nil end
    return Fields.Run(function(s)
        local H = s:Height(1, x0, z0, x1, z1)
        local rating = s:Op('slope', { a = H, mode = 'rating', window = 1 })
        local bad = s:Op('threshold', { a = rating, value = limit or 0.75 })
        local total, blocked = 0, 0
        for _, set in sets do
            -- the corridor: the middle 60% of the half width, without the end caps (where the path meets the terrain at any height)
            local S = set.S
            local narrow = { n = S.n, x = S.x, z = S.z, bank = S.bank, s = S.s, w = {}, f = {} }
            local ys, offs = {}, {}
            for k = 1, S.n do narrow.w[k] = S.w[k] * 0.6 narrow.f[k] = 0 ys[k] = 0 offs[k] = 0 end
            local args = ProfileParams(set.path)
            args.pts = FlatPts(narrow, ys, offs)
            args.like = H
            args.kind = 'core'
            local core = s:Op('path_mask', args)
            local along = s:Op('path_along', { like = H, pts = args.pts, normalize = 1, outside = -1 })
            local inner = s:Op('mul', { a = s:Op('threshold', { a = along, value = 0.02 }), b = s:Op('invert', { a = s:Op('threshold', { a = along, value = 0.98 }), lo = 0, hi = 1 }) })
            local inCore = s:Op('mul', { a = s:Op('threshold', { a = core, value = 0.999 }), b = inner })
            local hit = s:Op('mul', { a = inCore, b = bad })
            local _, _, meanIn = Fields.Stats(inCore)
            local _, _, meanHit = Fields.Stats(hit)
            local w, h = Fields.Info(H)
            total = total + meanIn * w * h
            blocked = blocked + meanHit * w * h
        end
        return total > 0 and blocked / total or 0, total
    end)
end

-- ---- the model travels with the map ---------------------------------------------------------------------------------------------------------------

local function Clean(path)
    local c = Copy(path)
    c.applied = (Results[path.id] or path.wasApplied) and true or nil
    c.wasApplied = nil
    return c
end

--- The paths as the sidecar keeps them (copies): a list of path tables.
function ExportData()
    local data = {}
    for _, p in List do table.insert(data, Clean(p)) end
    return data
end

function SidecarText()
    if table.getn(List) == 0 then return '' end
    return Ser.Chunk({ { 'Paths', ExportData() } })
end

local function Normalize(p)
    p.kind = (p.kind == 'bezier') and 'bezier' or 'catmull'
    p.mode = Modes[p.mode] and p.mode or 'carve'
    p.points = p.points or {}
    p.strength = p.strength or 1
    p.tension = p.tension or 1
    p.grade = p.grade or 0.75
    p.erosion = p.erosion or 0
    p.blend = p.blend or 0
    p.strata = p.strata or {}
    if not p.profile or not p.profile.points then SetPreset(p, Modes[p.mode].preset) end
    p.scatter = p.scatter or { on = false, bp = '', spacing = 6, side = 'both', lateral = 1, jitter = 0.5, scaleMin = 0.8, scaleMax = 1.2, seed = 1 }
    p.decals = p.decals or { on = false, tex = '', spacing = 12, side = 'center', lateral = 0, size = 6, jitter = 0.2, seed = 1 }
    for _, q in p.points do
        q.w, q.f, q.h, q.bank = q.w or 6, q.f or 4, q.h or 0, q.bank or 0
    end
    p.wasApplied = p.applied or p.wasApplied
    p.applied = nil
    return p
end

function FreeResults()
    for _, res in Created do
        if res.delta then Fields.Free(res.delta) end
        for _, m in (res.masks or {}) do Fields.Free(m) end
    end
    Created = {}
    Results = {}
    for _, release in Released do import('/lua/editor/safe.lua').Try('paths.release', release) end
    Released = {}
end

function LoadSidecar(scenarioFile)
    List = {}
    Current = false
    Sel = {}
    PreviewState = false
    FreeResults()
    nextId = 1
    local env = import('/lua/editor/mods.lua').SidecarEnv(scenarioFile)           -- protected, shared read (mods.lua)
    if env then
        for _, p in (env.Paths or {}) do
            if type(p) == 'table' then
                local ok, norm = pcall(Normalize, p)
                if ok then
                    table.insert(List, norm)
                    local n = tonumber(string.sub(tostring(p.id or ''), 2))
                    if n and n >= nextId then nextId = n + 1 end
                else
                    WARN('EDITOR paths: a saved path could not be read (' .. tostring(norm) .. '): skipped')
                end
            end
        end
    end
    Changed()
end

--- Back to an empty model (a new map).
function Reset()
    List = {}
    Current = false
    Sel = {}
    PreviewState = false
    FreeResults()
    Changed()
end
