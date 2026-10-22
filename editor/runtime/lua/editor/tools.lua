-- Object tools: marker types, selection (single, shift-toggle and box), picking, moving / resizing, property edits and deleting for
-- markers and areas. Everything goes through the map document (map.lua) and records an undo entry in history.lua. ui.lua owns the tool
-- list and the world click hook and calls OnSelectPress / PlaceMarker / NewArea; the GUI panels (gui/panels_objects.lua) read and
-- change the state here.

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')
local Dragger = import('/lua/maui/dragger.lua').Dragger
local Grid = import('/lua/editor/grid.lua')

--- The primary selected object (the one the properties panel edits): kind 'marker' | 'area' (false = nothing), and its name.
Selection = { kind = false, name = false }
--- Everything selected, in selection order: list of { kind, name }. The primary is the last element.
Items = {}
--- What the pointer is over with the select tool (highlight only).
Hover = { kind = false, name = false }
--- Marker template the Marker tool places.
MarkerType = 'Blank Marker'
--- Rectangle being dragged out with the select tool, { x0, z0, x1, z1 } in world units, or false.
Marquee = false
--- Bumped by every change of the objects (overlays and marker visuals re-sync on it).
Changed = 0
--- Bumped when the hovered object changes. A hover is no change of the objects: it moved `Changed` before, and so rebuilt the outliner, the properties and the chain
--- lines of the whole map each time the pointer crossed a marker. Only overlay.lua (the highlight) looks at this one.
HoverRev = 0

local function Bump()
    Changed = Changed + 1
end

local function GroundHeight(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

local function Markers()
    return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
end

local function Areas()
    return Map.Doc.save.Areas
end

local function Table(kind)
    if kind == 'marker' then return Markers() end
    return Areas()
end

-- ---- keeping areas on the map ---------------------------------------------------------------------------------------------------
-- 'Limit to map bounds' (Properties panel, area tools): while it is on an area is kept inside the map (0 .. size) while it is drawn, moved, resized and typed; 'Limit to
-- playable area' narrows that to the playable area (AREA_1 itself is only limited by the map). Both are remembered in the user settings.
--
--   LimitAreas / LimitPlayable        the two switches (module fields; SetLimitAreas / SetLimitPlayable change and save them)
--   AreaBounds(name) -> x0, z0, x1, z1 | nil     the rectangle areas stay in (nil: no limit); `name` is the area being edited
--   ClampAreaPoint(x, z, name) -> x, z           a point brought inside
--   ClampAreaShift(r, dx, dz, name) -> dx, dz    a wanted shift of rectangle r, cut so r does not go further out than it is (an area already outside may still come back)

LimitAreas = true
LimitPlayable = false

pcall(function()
    local UD = import('/lua/editor/userdata.lua')
    LimitAreas = UD.Get('areaLimitMap', true) ~= false
    LimitPlayable = UD.Get('areaLimitPlayable', false) == true
end)

function SetLimitAreas(on)
    LimitAreas = on and true or false
    pcall(function() import('/lua/editor/userdata.lua').Set('areaLimitMap', LimitAreas) end)
    Bump()
end

function SetLimitPlayable(on)
    LimitPlayable = on and true or false
    pcall(function() import('/lua/editor/userdata.lua').Set('areaLimitPlayable', LimitPlayable) end)
    Bump()
end

function AreaBounds(name)
    if not LimitAreas then return nil end
    if LimitPlayable then
        local P = import('/lua/editor/playable.lua')
        if name ~= P.NAME then
            local x0, z0, x1, z1 = P.Get()
            return x0, z0, x1, z1
        end
    end
    local w, h = ed_terrain_info()
    return 0, 0, (w or 257) - 1, (h or 257) - 1
end

function ClampAreaPoint(x, z, name)
    local x0, z0, x1, z1 = AreaBounds(name)
    if not x0 then return x, z end
    return math.max(x0, math.min(x1, x)), math.max(z0, math.min(z1, z))
end

function ClampAreaShift(r, dx, dz, name)
    local x0, z0, x1, z1 = AreaBounds(name)
    if not x0 then return dx, dz end
    dx = math.max(math.min(0, x0 - r[1]), math.min(math.max(0, x1 - r[3]), dx))
    dz = math.max(math.min(0, z0 - r[2]), math.min(math.max(0, z1 - r[4]), dz))
    return dx, dz
end

-- ---- marker types --------------------------------------------------------------------------------------------------------------

local CATEGORY_ORDER = { 'Resources', 'Areas and points', 'Paths', 'Other' }

local FALLBACK_TYPES = {
    ['Blank Marker'] = { prop = '/env/common/props/markers/M_Blank_prop.bp', color = 'ff800080' },
    ['Mass'] = { resource = true, amount = 100, size = 1, prop = '/env/common/props/markers/M_Mass_prop.bp', color = 'ff808080' },
    ['Hydrocarbon'] = { resource = true, amount = 100, size = 3, prop = '/env/common/props/markers/M_Hydrocarbon_prop.bp', color = 'ff008000' },
}

local templates = false

--- The marker templates of the game (/lua/MarkerTemplates.lua), so mods that add marker types show up too.
--- True while a read-only workspace (Review) is showing: selecting and looking stay possible, every change is refused.
ReadOnly = false

function Templates()
    if templates then
        return templates
    end
    -- the file calls VECTOR3(), which only the sim and the map loader define
    if rawget(_G, 'VECTOR3') == nil then
        rawset(_G, 'VECTOR3', function(x, y, z) return { x, y, z } end)
    end
    local ok, mod = pcall(import, '/lua/MarkerTemplates.lua')
    templates = (ok and mod.MarkerTemplates) or FALLBACK_TYPES
    return templates
end

local function CategoryOf(name, t)
    if t.resource then return 1 end
    if string.find(name, 'Path Node', 1, true) then return 3 end
    if t.hint or string.find(name, 'Area', 1, true) or string.find(name, 'Point', 1, true) or string.find(name, 'Zone', 1, true) then return 2 end
    return 4
end

--- All marker types as { name, category, color, resource }, grouped by category and sorted by name.
function MarkerTypes()
    local list = {}
    for name, t in Templates() do
        table.insert(list, { name = name, category = CATEGORY_ORDER[CategoryOf(name, t)], rank = CategoryOf(name, t),
                             color = t.color or 'ff808080', resource = t.resource and true or false })
    end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)
    return list
end

function SetMarkerType(name)
    if Templates()[name] then
        MarkerType = name
        return true
    end
    return false
end

--- 'RRGGBB' of a template colour string ('ffRRGGBB').
function ColorHex(argb)
    local s = argb or 'ff808080'
    if string.len(s) >= 8 then return string.sub(s, 3) end
    return s
end

-- ---- selection ---------------------------------------------------------------------------------------------------------------

local function Exists(kind, name)
    return Map.Doc ~= nil and Table(kind)[name] ~= nil
end

--- True when the object is part of the selection.
function IsSelected(kind, name)
    for _, it in Items do
        if it.kind == kind and it.name == name then return true end
    end
    return false
end

local function SyncPrimary()
    local last = Items[table.getn(Items)]
    if last then
        Selection.kind, Selection.name = last.kind, last.name
    else
        Selection.kind, Selection.name = false, false
    end
    Bump()
end

--- Selects an object. mode: nil / 'set' replaces the selection, 'add' adds, 'toggle' flips its membership.
--- Select(false) clears everything.
function Select(kind, name, mode)
    if not kind or not name then
        Items = {}
        SyncPrimary()
        return
    end
    if mode == 'toggle' and IsSelected(kind, name) then
        local rest = {}
        for _, it in Items do
            if not (it.kind == kind and it.name == name) then table.insert(rest, it) end
        end
        Items = rest
    else
        if mode ~= 'add' and mode ~= 'toggle' then Items = {} end
        if not IsSelected(kind, name) then
            table.insert(Items, { kind = kind, name = name })
        else
            -- re-picking a selected object makes it the primary one
            local rest = {}
            for _, it in Items do
                if not (it.kind == kind and it.name == name) then table.insert(rest, it) end
            end
            table.insert(rest, { kind = kind, name = name })
            Items = rest
        end
    end
    SyncPrimary()
end

--- Replaces (or, with `additive`, extends) the selection with a list of { kind, name }.
function SelectMany(list, additive)
    if not additive then Items = {} end
    -- a set of what is selected: IsSelected scans the whole selection, which made a box over thousands of markers quadratic
    local have = {}
    for _, it in Items do have[it.kind .. '\1' .. it.name] = true end
    for _, it in list do
        local key = it.kind .. '\1' .. it.name
        if not have[key] then
            have[key] = true
            table.insert(Items, { kind = it.kind, name = it.name })
        end
    end
    SyncPrimary()
end

--- Drops selected objects that no longer exist (after delete / undo).
function Prune()
    if not Map.Doc then
        Items = {}
        SyncPrimary()
        return
    end
    local keep = {}
    for _, it in Items do
        if Exists(it.kind, it.name) then table.insert(keep, it) end
    end
    if table.getn(keep) ~= table.getn(Items) then
        Items = keep
        SyncPrimary()
    end
end

function SelectionCount()
    return table.getn(Items)
end

--- The primary selected object's data table, or nil.
function SelectedObject()
    if not Map.Doc or not Selection.kind then
        return nil
    end
    return Table(Selection.kind)[Selection.name]
end

-- ---- naming ------------------------------------------------------------------------------------------------------------------------

local function UniqueName(kind, base)
    local n = 1
    local name
    repeat
        name = string.format('%s %02d', base, n)
        n = n + 1
    until not Exists(kind, name)
    return name
end

-- ---- creating / deleting -------------------------------------------------------------------------------------------------------------

local function CopyFields(t)
    local fields = {}
    for k, v in t do
        if type(v) == 'table' then
            local c = {}
            for k2, v2 in v do c[k2] = v2 end
            fields[k] = c
        else
            fields[k] = v
        end
    end
    return fields
end

--- Places a marker of the selected type at a world position, selects it, records undo. Returns its name.
function PlaceMarker(x, z, kind, fixedName)
    if not Map.Doc or ReadOnly then return nil end
    kind = kind or MarkerType
    x, z = Grid.SnapMarker(kind, x, z)       -- Mass / Hydrocarbon markers sit on the build grid like the structure they stand for
    local template = Templates()[kind] or {}
    local name = fixedName or UniqueName('marker', kind)
    local m = Map.AddMarker(name, kind, x, GroundHeight(x, z), z, CopyFields(template))
    History.Push({
        label = 'place ' .. name,
        undo = function() Markers()[name] = nil Prune() Bump() end,
        redo = function() Markers()[name] = m Select('marker', name) end,
    })
    Select('marker', name)
    return name
end

--- Puts a copy of marker table `src` at (x, z) (clipboard paste): same type and fields, a new name (`name` or <type> NN), one undo entry, not selected.
function PasteMarker(src, x, z, name)
    if not Map.Doc or ReadOnly then return nil end
    local fields = CopyFields(src)
    fields.position = nil
    name = name or UniqueName('marker', src.type or 'marker')
    local m = Map.AddMarker(name, src.type, x, GroundHeight(x, z), z, fields)
    History.Push({
        label = 'paste ' .. name,
        undo = function() Markers()[name] = nil Prune() Bump() end,
        redo = function() Markers()[name] = m Select('marker', name) end,
    })
    Bump()
    return name
end

--- A copy of the rectangle `r` ({ x0, z0, x1, z1 }) moved by (dx, dz) (clipboard paste), one undo entry, not selected.
function PasteArea(r, dx, dz)
    if not Map.Doc or ReadOnly then return nil end
    local name = UniqueName('area', 'AREA')
    dx, dz = ClampAreaShift(r, dx, dz)          -- a pasted copy stays on the map too (when the limit is on)
    Map.AddArea(name, r[1] + dx, r[2] + dz, r[3] + dx, r[4] + dz)
    local a = Areas()[name]
    History.Push({
        label = 'paste ' .. name,
        undo = function() Areas()[name] = nil Prune() Bump() end,
        redo = function() Areas()[name] = a Select('area', name) end,
    })
    Bump()
    return name
end

--- Creates a rectangle area, selects it, records undo. Returns its name.
function NewArea(x0, z0, x1, z1)
    if not Map.Doc or ReadOnly then return nil end
    local name = UniqueName('area', 'AREA')
    x0, z0 = ClampAreaPoint(x0, z0)
    x1, z1 = ClampAreaPoint(x1, z1)
    Map.AddArea(name, math.min(x0, x1), math.min(z0, z1), math.max(x0, x1), math.max(z0, z1))
    local a = Areas()[name]
    History.Push({
        label = 'add ' .. name,
        undo = function() Areas()[name] = nil Prune() Bump() end,
        redo = function() Areas()[name] = a Select('area', name) end,
    })
    Select('area', name)
    return name
end

--- Deletes everything selected (one undo step).
function DeleteSelection()
    if not Map.Doc or ReadOnly or table.getn(Items) == 0 then return false end
    local removed = {}
    for _, it in Items do
        local obj = Table(it.kind)[it.name]
        if obj then table.insert(removed, { kind = it.kind, name = it.name, obj = obj }) end
    end
    if table.getn(removed) == 0 then return false end
    local function Remove()
        for _, r in removed do Table(r.kind)[r.name] = nil end
        Prune()
        Bump()
    end
    local function Restore()
        for _, r in removed do Table(r.kind)[r.name] = r.obj end
        Items = {}
        for _, r in removed do table.insert(Items, { kind = r.kind, name = r.name }) end
        SyncPrimary()
    end
    Remove()
    History.Push({
        label = (table.getn(removed) == 1) and ('delete ' .. removed[1].name) or ('delete ' .. table.getn(removed) .. ' objects'),
        undo = Restore,
        redo = Remove,
    })
    return true
end

-- ---- property edits (the properties panel) -------------------------------------------------------------------------------------

--- Sets a marker field (position.x / .z, orientation, amount ...) to a value with undo. `path` is a list of keys.
function SetField(obj, path, value, label)
    if ReadOnly then return end
    local holder = obj
    for i = 1, table.getn(path) - 1 do
        holder = holder[path[i]]
    end
    local key = path[table.getn(path)]
    local old = holder[key]
    if old == value then return end
    holder[key] = value
    Bump()
    History.Push({
        label = label or 'edit',
        undo = function() holder[key] = old Bump() end,
        redo = function() holder[key] = value Bump() end,
    })
end

--- Middle of the selected markers and areas: x, z (nil without a selection).
function SelectionCenter()
    if not Map.Doc then return nil end
    local sx, sz, n = 0, 0, 0
    for _, it in Items do
        local obj = Table(it.kind)[it.name]
        if obj then
            if it.kind == 'marker' then
                sx, sz, n = sx + obj.position[1], sz + obj.position[3], n + 1
            else
                local r = obj.rectangle
                sx, sz, n = sx + (r[1] + r[3]) / 2, sz + (r[2] + r[4]) / 2, n + 1
            end
        end
    end
    if n == 0 then return nil end
    return sx / n, sz / n
end

--- The markers that stand at the mirror images of the selected markers (same type, with symmetry on): groups, see symmetry.lua Plan.
local function MirrorPlan()
    local Sym = import('/lua/editor/symmetry.lua')
    if Sym.Mode == 'off' or not Map.Doc then return nil end
    local items, selected = {}, {}
    for _, it in Items do
        if it.kind == 'marker' then
            local m = Markers()[it.name]
            if m then
                table.insert(items, { name = it.name, type = m.type, x = m.position[1], z = m.position[3] })
                selected[it.name] = true
            end
        end
    end
    if table.getn(items) == 0 then return nil end
    local cands = {}
    for name, m in Markers() do
        if not selected[name] then table.insert(cands, { name = name, type = m.type, x = m.position[1], z = m.position[3] }) end
    end
    return Sym.Plan(items, function(o) return o.x, o.z end, cands, function(a, b) return a.type == b.type end, function(c) return selected[c.name] end)
end

--- Moves every selected marker and area by (dx, dz) as one undo step (markers snap to the build grid like a drag does). With symmetry on the marker at the mirror image of
--- a selected one moves by the mirrored move.
function MoveSelectionBy(dx, dz)
    if not Map.Doc or ReadOnly or table.getn(Items) == 0 then return false end
    local before, after = {}, {}
    for _, it in Items do
        local obj = Table(it.kind)[it.name]
        if obj then
            if it.kind == 'marker' then
                local nx, nz = Grid.SnapMarker(obj.type, obj.position[1] + dx, obj.position[3] + dz)
                table.insert(before, { kind = 'marker', name = it.name, x = obj.position[1], y = obj.position[2], z = obj.position[3] })
                table.insert(after, { kind = 'marker', name = it.name, x = nx, y = GroundHeight(nx, nz), z = nz })
            else
                local r = obj.rectangle
                local adx, adz = ClampAreaShift(r, dx, dz, it.name)
                table.insert(before, { kind = 'area', name = it.name, r1 = r[1], r2 = r[2], r3 = r[3], r4 = r[4] })
                table.insert(after, { kind = 'area', name = it.name, r1 = r[1] + adx, r2 = r[2] + adz, r3 = r[3] + adx, r4 = r[4] + adz })
            end
        end
    end
    local plan = MirrorPlan()
    if plan then
        local Sym = import('/lua/editor/symmetry.lua')
        for _, g in plan do
            local mdx, mdz = Sym.ImageDelta(g.key, g.refX, g.refZ, dx, dz)
            for _, t in g.targets do
                local obj = Markers()[t.name]
                if obj then
                    local nx, nz = Grid.SnapMarker(obj.type, obj.position[1] + mdx, obj.position[3] + mdz)
                    table.insert(before, { kind = 'marker', name = t.name, x = obj.position[1], y = obj.position[2], z = obj.position[3] })
                    table.insert(after, { kind = 'marker', name = t.name, x = nx, y = GroundHeight(nx, nz), z = nz })
                end
            end
        end
    end
    local function Set(list)
        for _, b in list do
            if b.kind == 'marker' then
                if Markers()[b.name] then Map.MoveMarker(b.name, b.x, b.y, b.z) end
            else
                local a = Areas()[b.name]
                if a then a.rectangle[1], a.rectangle[2], a.rectangle[3], a.rectangle[4] = b.r1, b.r2, b.r3, b.r4 end
            end
        end
        Bump()
    end
    Set(after)
    History.Push({
        label = (table.getn(before) == 1) and ('move ' .. before[1].name) or ('move ' .. table.getn(before) .. ' objects'),
        undo = function() Set(before) end,
        redo = function() Set(after) end,
    })
    return true
end

--- Turns the selected markers (their heading, the second orientation lane) by `deg` degrees as one undo step; areas stay as they are.
function RotateSelectionBy(deg)
    if not Map.Doc or ReadOnly then return false end
    local changes = {}
    for _, it in Items do
        if it.kind == 'marker' then
            local m = Markers()[it.name]
            if m then
                m.orientation = m.orientation or Map.MakeVec3(0, 0, 0)
                table.insert(changes, { m = m, old = m.orientation[2] or 0, new = (m.orientation[2] or 0) + math.rad(deg) })
            end
        end
    end
    local plan = MirrorPlan()
    if plan and table.getn(changes) > 0 then
        local Sym = import('/lua/editor/symmetry.lua')
        for _, g in plan do
            for _, t in g.targets do
                local m = Markers()[t.name]
                if m then
                    m.orientation = m.orientation or Map.MakeVec3(0, 0, 0)
                    table.insert(changes, { m = m, old = m.orientation[2] or 0, new = (m.orientation[2] or 0) + math.rad(Sym.ImageTurn(g.kind, deg)) })
                end
            end
        end
    end
    if table.getn(changes) == 0 then return false end
    for _, c in changes do c.m.orientation[2] = c.new end
    Bump()
    History.Push({
        label = 'rotate ' .. table.getn(changes) .. ' markers',
        undo = function() for _, c in changes do c.m.orientation[2] = c.old end Bump() end,
        redo = function() for _, c in changes do c.m.orientation[2] = c.new end Bump() end,
    })
    return true
end

--- Moves a marker to x, z (y follows the terrain) with undo; used by the position fields.
function SetMarkerPosition(name, x, z)
    if ReadOnly then return false end
    local m = Markers()[name]
    if not m then return false end
    local ox, oy, oz = m.position[1], m.position[2], m.position[3]
    local ny = GroundHeight(x, z)
    Map.MoveMarker(name, x, ny, z)
    Bump()
    History.Push({
        label = 'move ' .. name,
        undo = function() Map.MoveMarker(name, ox, oy, oz) Bump() end,
        redo = function() Map.MoveMarker(name, x, ny, z) Bump() end,
    })
    return true
end

local function Rename(kind, old, new)
    if new == '' or new == old or Exists(kind, new) then return false end
    local tbl = Table(kind)
    local obj = tbl[old]
    if not obj then return false end
    local function Swap(from, to)
        tbl[to] = obj
        tbl[from] = nil
        for _, it in Items do
            if it.kind == kind and it.name == from then it.name = to end
        end
        SyncPrimary()
    end
    Swap(old, new)
    History.Push({
        label = 'rename ' .. old,
        undo = function() Swap(new, old) end,
        redo = function() Swap(old, new) end,
    })
    return true
end

function RenameSelection(new)
    if not Map.Doc or not Selection.kind then return false end
    return Rename(Selection.kind, Selection.name, new)
end

function SetAreaRect(name, x0, z0, x1, z1)
    if ReadOnly then return false end
    local a = Areas()[name]
    if not a then return false end
    local r = a.rectangle
    local ox0, oz0, ox1, oz1 = r[1], r[2], r[3], r[4]
    local nx0, nz0, nx1, nz1 = math.min(x0, x1), math.min(z0, z1), math.max(x0, x1), math.max(z0, z1)
    -- typed coordinates stay on the map: an edge that was not changed (the fields show one decimal) is left as it is
    local bx0, bz0, bx1, bz1 = AreaBounds(name)
    if bx0 then
        if math.abs(nx0 - ox0) > 0.06 then nx0 = math.max(bx0, math.min(bx1, nx0)) end
        if math.abs(nz0 - oz0) > 0.06 then nz0 = math.max(bz0, math.min(bz1, nz0)) end
        if math.abs(nx1 - ox1) > 0.06 then nx1 = math.max(bx0, math.min(bx1, nx1)) end
        if math.abs(nz1 - oz1) > 0.06 then nz1 = math.max(bz0, math.min(bz1, nz1)) end
    end
    if nx0 == ox0 and nz0 == oz0 and nx1 == ox1 and nz1 == oz1 then return true end
    r[1], r[2], r[3], r[4] = nx0, nz0, nx1, nz1
    Bump()
    History.Push({
        label = 'resize ' .. name,
        undo = function() r[1], r[2], r[3], r[4] = ox0, oz0, ox1, oz1 Bump() end,
        redo = function() r[1], r[2], r[3], r[4] = nx0, nz0, nx1, nz1 Bump() end,
    })
    return true
end

--- Moves the given resource markers onto the build grid (one undo step). Returns how many moved.
function SnapMarkersToGrid(names)
    if ReadOnly then return 0 end
    if not Map.Doc then return 0 end
    local before, after = {}, {}
    for _, name in names do
        local m = Markers()[name]
        if m and not Grid.IsAligned(m.type, m.position[1], m.position[3]) then
            local nx, nz = Grid.SnapMarker(m.type, m.position[1], m.position[3])
            table.insert(before, { name = name, x = m.position[1], y = m.position[2], z = m.position[3] })
            table.insert(after, { name = name, x = nx, y = GroundHeight(nx, nz), z = nz })
        end
    end
    if table.getn(before) == 0 then return 0 end
    local function Set(list)
        for _, b in list do
            if Markers()[b.name] then Map.MoveMarker(b.name, b.x, b.y, b.z) end
        end
        Bump()
    end
    Set(after)
    History.Push({
        label = 'snap ' .. table.getn(before) .. ' marker(s) to the build grid',
        undo = function() Set(before) end,
        redo = function() Set(after) end,
    })
    return table.getn(before)
end

--- Moves the named markers that stand outside the map onto the nearest point of the map (height from the terrain there), one undo step. -> how many moved.
function ClampMarkersToMap(names)
    if ReadOnly or not Map.Doc then return 0 end
    local w, h = ed_terrain_info()
    local sx, sz = (w or 257) - 1, (h or 257) - 1
    local before, after = {}, {}
    for _, name in names do
        local m = Markers()[name]
        local p = m and m.position
        if p and p[1] and p[3] and p[1] == p[1] and p[3] == p[3] and (p[1] < 0 or p[3] < 0 or p[1] > sx or p[3] > sz) then
            local nx, nz = math.max(0, math.min(sx, p[1])), math.max(0, math.min(sz, p[3]))
            table.insert(before, { name = name, x = p[1], y = p[2], z = p[3] })
            table.insert(after, { name = name, x = nx, y = GroundHeight(nx, nz), z = nz })
        end
    end
    if table.getn(before) == 0 then return 0 end
    local function Set(list)
        for _, b in list do
            if Markers()[b.name] then Map.MoveMarker(b.name, b.x, b.y, b.z) end
        end
        Bump()
    end
    Set(after)
    History.Push({
        label = 'pull ' .. table.getn(before) .. ' marker(s) onto the map',
        undo = function() Set(before) end,
        redo = function() Set(after) end,
    })
    return table.getn(before)
end

-- ---- picking ------------------------------------------------------------------------------------------------------------------

local function View()
    return import('/lua/ui/game/worldview.lua').viewLeft
end

--- World units per screen pixel at a window position (for pick tolerances that stay the same size on screen).
local function PixelSize(mx, my)
    return import('/lua/editor/viewscale.lua').PixelSize()
end

local HANDLE_PX = 10
local MARKER_PX = 14

-- Resize handles of a rectangle: corners and edge midpoints. id = which edges move.
local function Handles(r)
    local mx, mz = (r[1] + r[3]) / 2, (r[2] + r[4]) / 2
    return {
        { id = 'nw', x = r[1], z = r[2] }, { id = 'ne', x = r[3], z = r[2] },
        { id = 'sw', x = r[1], z = r[4] }, { id = 'se', x = r[3], z = r[4] },
        { id = 'n', x = mx, z = r[2] }, { id = 's', x = mx, z = r[4] },
        { id = 'w', x = r[1], z = mz }, { id = 'e', x = r[3], z = mz },
    }
end
HandlesOf = Handles

--- The area whose handles are shown: only when exactly one area (and nothing else) is selected.
function HandleArea()
    if table.getn(Items) == 1 and Items[1].kind == 'area' and Map.Doc and Areas()[Items[1].name] then
        return Items[1].name
    end
    return nil
end

--- What is under a world position: { kind, name, handle } or nil. Window position for the pixel tolerance.
--- `only` limits it to one kind of object ('marker' | 'area'; nil = both): the Select marker tool never picks an area (areas are big rectangles that
--- covered the markers' neighbourhood), the Select area tool never picks a marker. A marker of a layer that is switched off in the View panel is not pickable
--- either (it is not drawn), unless it is selected.
function Pick(wx, wz, mx, my, only)
    if not Map.Doc then return nil end
    local px = PixelSize(mx, my)

    -- the handles of a lone selected area win over everything under them
    local handleArea = (only ~= 'marker') and HandleArea() or nil
    if handleArea then
        for _, h in Handles(Areas()[handleArea].rectangle) do
            if math.abs(h.x - wx) <= HANDLE_PX * px and math.abs(h.z - wz) <= HANDLE_PX * px then
                return { kind = 'area', name = handleArea, handle = h.id }
            end
        end
    end

    local best, bestD = nil, (MARKER_PX * px) * (MARKER_PX * px)
    if only ~= 'area' then
        local Filter = import('/lua/editor/markerfilter.lua')
        for name, m in Markers() do
            local dx, dz = m.position[1] - wx, m.position[3] - wz
            local d = dx * dx + dz * dz
            if d <= bestD and (not Filter.IsHidden(m.type) or IsSelected('marker', name)) then
                best, bestD = name, d
            end
        end
    end
    if best then
        return { kind = 'marker', name = best }
    end

    -- smallest area containing the point
    local areaName, areaSize = nil, nil
    for name, a in Areas() do
        local r = a.rectangle
        if only ~= 'marker' and r and wx >= r[1] and wx <= r[3] and wz >= r[2] and wz <= r[4] then
            local size = (r[3] - r[1]) * (r[4] - r[2])
            if not areaSize or size < areaSize then
                areaName, areaSize = name, size
            end
        end
    end
    if areaName then
        return { kind = 'area', name = areaName }
    end
    return nil
end

--- Updates the hover highlight (call each frame with the world position under the pointer, or nil).
local lastHoverQuery = { wx = false }

function UpdateHover(wx, wz, mx, my, only)
    -- called every frame: with the pointer at rest, over the same objects, the answer is the one of the frame before (Pick walks every marker and area)
    local q = lastHoverQuery
    local hit
    if wx and q.wx == wx and q.wz == wz and q.mx == mx and q.my == my and q.only == only and q.changed == Changed and q.doc == Map.Doc then
        hit = q.hit
    else
        hit = wx and Pick(wx, wz, mx, my, only) or nil
        q.wx, q.wz, q.mx, q.my, q.only, q.changed, q.doc, q.hit = wx, wz, mx, my, only, Changed, Map.Doc, hit
    end
    local kind, name = false, false
    if hit and not hit.handle then kind, name = hit.kind, hit.name end
    if Hover.kind ~= kind or Hover.name ~= name then
        Hover.kind, Hover.name = kind, name
        HoverRev = HoverRev + 1
    end
    return hit
end

-- ---- select tool: press, then drag ------------------------------------------------------------------------------------------------

local function WorldAt(x, y)
    local view = View()
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

--- Everything whose reference point lies inside the world rectangle: markers by position, areas by centre. `only` = 'marker' | 'area' limits it to one kind
--- (see Pick); markers of a hidden View layer are left out.
local function InBox(x0, z0, x1, z1, only)
    local minx, maxx, minz, maxz = math.min(x0, x1), math.max(x0, x1), math.min(z0, z1), math.max(z0, z1)
    local list = {}
    local Filter = import('/lua/editor/markerfilter.lua')
    for name, m in Markers() do
        local p = m.position
        if only ~= 'area' and p[1] >= minx and p[1] <= maxx and p[3] >= minz and p[3] <= maxz and (not Filter.IsHidden(m.type) or IsSelected('marker', name)) then
            table.insert(list, { kind = 'marker', name = name })
        end
    end
    for name, a in Areas() do
        local r = a.rectangle
        if r and only ~= 'marker' then
            local cx, cz = (r[1] + r[3]) / 2, (r[2] + r[4]) / 2
            if cx >= minx and cx <= maxx and cz >= minz and cz <= maxz then
                table.insert(list, { kind = 'area', name = name })
            end
        end
    end
    return list
end

--- Starts a drag that moves everything selected together; `wx, wz` is where the grab happened.
--- A live move / turn of the selected markers and areas: Move(dx, dz) and Turn(deg) change the objects at once (relative to where they were when this
--- started), Commit() pushes ONE undo entry for everything done since (nothing when nothing changed), Cancel() puts everything back. The group drag of the
--- select tool and the transform gizmo both use it, so the objects follow the pointer while it is dragged.
function NewLiveMove()
    local before = {}
    for _, it in Items do
        local obj = Table(it.kind)[it.name]
        if obj then
            if it.kind == 'marker' then
                table.insert(before, { kind = 'marker', name = it.name, x = obj.position[1], y = obj.position[2], z = obj.position[3], turn = (obj.orientation and obj.orientation[2]) or 0 })
            else
                local r = obj.rectangle
                table.insert(before, { kind = 'area', name = it.name, r1 = r[1], r2 = r[2], r3 = r[3], r4 = r[4] })
            end
        end
    end
    -- with symmetry on the markers at the mirror images of the selected ones follow, mirrored
    local plan = MirrorPlan()
    if plan then
        for _, g in plan do
            for _, t in g.targets do
                local obj = Markers()[t.name]
                if obj then
                    table.insert(before, { kind = 'marker', name = t.name, x = obj.position[1], y = obj.position[2], z = obj.position[3], turn = (obj.orientation and obj.orientation[2]) or 0,
                                           mk = g.key, mkind = g.kind, refX = g.refX, refZ = g.refZ })
                end
            end
        end
    end
    local L = { moved = false, dx = 0, dz = 0, deg = 0 }

    local function Snapshot()
        local after = {}
        for _, b in before do
            if b.kind == 'marker' then
                local m = Markers()[b.name]
                if m then table.insert(after, { kind = 'marker', name = b.name, x = m.position[1], y = m.position[2], z = m.position[3], turn = (m.orientation and m.orientation[2]) or 0 }) end
            else
                local a = Areas()[b.name]
                if a then
                    local r = a.rectangle
                    table.insert(after, { kind = 'area', name = b.name, r1 = r[1], r2 = r[2], r3 = r[3], r4 = r[4] })
                end
            end
        end
        return after
    end
    local function Set(list)
        for _, b in list do
            if b.kind == 'marker' then
                local m = Markers()[b.name]
                if m then
                    Map.MoveMarker(b.name, b.x, b.y, b.z)
                    if b.turn and (b.turn ~= 0 or m.orientation) then
                        m.orientation = m.orientation or Map.MakeVec3(0, 0, 0)
                        m.orientation[2] = b.turn
                    end
                end
            else
                local a = Areas()[b.name]
                if a then a.rectangle[1], a.rectangle[2], a.rectangle[3], a.rectangle[4] = b.r1, b.r2, b.r3, b.r4 end
            end
        end
        Bump()
    end

    local function Apply()
        for _, b in before do
            if b.kind == 'marker' then
                local m = Markers()[b.name]
                if m then
                    local ddx, ddz, ddeg = L.dx, L.dz, L.deg
                    if b.mk then
                        local Sym = import('/lua/editor/symmetry.lua')
                        ddx, ddz = Sym.ImageDelta(b.mk, b.refX, b.refZ, L.dx, L.dz)
                        ddeg = Sym.ImageTurn(b.mkind, L.deg)
                    end
                    local nx, nz = Grid.SnapMarker(m.type, b.x + ddx, b.z + ddz)
                    Map.MoveMarker(b.name, nx, GroundHeight(nx, nz), nz)
                    if ddeg ~= 0 then
                        m.orientation = m.orientation or Map.MakeVec3(0, 0, 0)
                        m.orientation[2] = b.turn + math.rad(ddeg)
                    end
                end
            else
                local a = Areas()[b.name]
                if a then
                    local r = a.rectangle
                    local adx, adz = ClampAreaShift({ b.r1, b.r2, b.r3, b.r4 }, L.dx, L.dz, b.name)
                    r[1], r[2], r[3], r[4] = b.r1 + adx, b.r2 + adz, b.r3 + adx, b.r4 + adz
                end
            end
        end
        Bump()
        L.moved = true
    end
    function L.Move(dx, dz) L.dx, L.dz = dx, dz Apply() end
    function L.Turn(deg) L.deg = deg Apply() end
    function L.Cancel()
        if L.moved then Set(before) L.moved = false end
    end
    function L.Commit()
        if not L.moved then return false end
        local after = Snapshot()
        History.Push({
            label = (table.getn(before) == 1) and ((L.deg ~= 0 and 'turn ' or 'move ') .. before[1].name) or ((L.deg ~= 0 and 'turn ' or 'move ') .. table.getn(before) .. ' objects'),
            undo = function() Set(before) end,
            redo = function() Set(after) end,
        })
        return true
    end
    return L
end

local function BeginGroupMove(wx, wz, event)
    local live = NewLiveMove()
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local cx, cz = WorldAt(x, y)
        if cx then live.Move(cx - wx, cz - wz) end
    end
    dragger.OnRelease = function(self, x, y)
        self:Destroy()
        live.Commit()
    end
    dragger.OnCancel = function(self)
        self:Destroy()
        live.Cancel()
    end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
end

--- Drag a handle of the lone selected area.
local function BeginResize(name, handle, event)
    local r = Areas()[name].rectangle
    local o0, o1, o2, o3 = r[1], r[2], r[3], r[4]
    local dragger = Dragger()
    local changed = false
    dragger.OnMove = function(self, x, y)
        local cx, cz = WorldAt(x, y)
        if not cx or not Areas()[name] then return end
        cx, cz = ClampAreaPoint(cx, cz, name)
        local x0, z0, x1, z1 = o0, o1, o2, o3
        if string.find(handle, 'w', 1, true) then x0 = cx end
        if string.find(handle, 'e', 1, true) then x1 = cx end
        if string.find(handle, 'n', 1, true) then z0 = cz end
        if string.find(handle, 's', 1, true) then z1 = cz end
        r[1], r[2], r[3], r[4] = math.min(x0, x1), math.min(z0, z1), math.max(x0, x1), math.max(z0, z1)
        changed = true
        Bump()
    end
    dragger.OnRelease = function(self, x, y)
        self:Destroy()
        if changed then
            local n0, n1, n2, n3 = r[1], r[2], r[3], r[4]
            History.Push({
                label = 'resize ' .. name,
                undo = function() r[1], r[2], r[3], r[4] = o0, o1, o2, o3 Bump() end,
                redo = function() r[1], r[2], r[3], r[4] = n0, n1, n2, n3 Bump() end,
            })
        end
    end
    dragger.OnCancel = function(self) self:Destroy() end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
end

--- Drag out a selection box from empty ground (also used by the unit, prop and decal select tools). `onDone(box, additive)` runs on release:
--- box = { x0, z0, x1, z1 } in world units after a drag, nil after a plain click.
function BeginBoxSelect(wx, wz, event, additive, onDone)
    local sx, sy = event.MouseX, event.MouseY
    local dragger = Dragger()
    local moved = false
    dragger.OnMove = function(self, x, y)
        local cx, cz = WorldAt(x, y)
        if not cx then return end
        if not moved and (math.abs(x - sx) + math.abs(y - sy)) < 5 then return end   -- a click, not a drag, until the pointer leaves
        moved = true
        Marquee = { wx, wz, cx, cz }
        Bump()
    end
    dragger.OnRelease = function(self, x, y)
        self:Destroy()
        local box = Marquee
        Marquee = false
        onDone(box, additive)
        Bump()
    end
    dragger.OnCancel = function(self)
        self:Destroy()
        Marquee = false
        Bump()
    end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
end

local function BeginMarquee(wx, wz, event, additive, only)
    BeginBoxSelect(wx, wz, event, additive, function(box, add)
        if box then
            SelectMany(InBox(box[1], box[2], box[3], box[4], only), add)
        elseif not add then
            Select(false)
        end
    end)
end

--- Left press with the select tool. Shift toggles an object in the selection; a press on a selected object drags the whole
--- selection; a press on empty ground drags a selection box. Returns true (the click is always taken). `only` = 'marker' (the Select marker tool) or 'area'
--- (the Select area tool) limits what is picked, hovered and boxed to that kind of object; nil = both.
function OnSelectPress(wx, wz, event, only)
    if not Map.Doc then Map.Load() end        -- the document loads on first use, like the other tools
    if not Map.Doc then return true end
    local shift = event.Modifiers and event.Modifiers.Shift
    local hit = Pick(wx, wz, event.MouseX, event.MouseY, only)

    if not hit then
        BeginMarquee(wx, wz, event, shift and true or false, only)
        return true
    end

    if hit.handle and not ReadOnly then
        BeginResize(hit.name, hit.handle, event)
        return true
    end

    if shift then
        Select(hit.kind, hit.name, 'toggle')
        return true
    end

    if not IsSelected(hit.kind, hit.name) then
        Select(hit.kind, hit.name)
    else
        Select(hit.kind, hit.name, 'add')    -- already part of it: keep the group, make this the primary
    end
    if not ReadOnly then
        BeginGroupMove(wx, wz, event)
    end
    return true
end

--- Short info text for the status line: what is selected.
function SelectionText()
    local n = table.getn(Items)
    if n == 0 or not Map.Doc then return '' end
    if n == 1 then return Selection.kind .. ' ' .. tostring(Selection.name) end
    return n .. ' selected'
end
