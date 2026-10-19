-- Mirror the whole half of the map through the symmetry definition (Edit > Mirror the whole half...): everything in one source region (a half, a quarter or a triangle, depending on the
-- symmetry mode) gets its images in the other regions: markers, areas, props, decals and units, headings mapped through the same transform. The images are added, or the other regions
-- are emptied first ("replace"). One undo step. mirror.lua (the selection) uses the army mapping of this file too.
--
--   ArmyMode            'keep' (the images belong to the same army) | 'map' (to the army whose start position is the image of the army's start position)
--   Sectors()           the source regions of the symmetry mode: list of { id, label, planes }; a point is inside when a * dx + b * dz < 0 for every plane (dx, dz from the centre)
--   InSector(s, x, z) / Polygon(s) / ShowSector(s) / ClearSector()
--   ArmyImage(army, image)      the army for an image point of Symmetry.Points ('keep' returns `army`)
--   Plan(opts)          what a run would do: { source = { markers, areas, props, decals, units }, images = n, others = { ... } }
--   Run(opts)           -> copies made, objects removed, or 0, 0 and a reason. opts = { sector = index, cats = { markers = true, ... }, mode = 'add' | 'replace', armies = 'keep' | 'map' }
--
-- Start position markers (ARMY_n) are never mirrored (the start positions are placed by hand); the playable area (AREA_1) stays. Chains do not follow (a copy is not in the chain of its
-- original); a mirrored decal or prop keeps its picture, only its heading is mapped (a picture cannot be flipped).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local History = import('/lua/editor/history.lua')
local Symmetry = import('/lua/editor/symmetry.lua')

ArmyMode = 'keep'
CATEGORIES = { 'markers', 'areas', 'props', 'decals', 'units' }
local MARGIN = 0.5

local function Markers() return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local c = {}
    for k, x in v do c[k] = Copy(x) end
    return c
end

-- ---- the regions ------------------------------------------------------------------------------------------------------------------------------------

local function S(id, label, ...)
    local planes = {}
    for i = 1, arg.n do planes[i] = arg[i] end
    return { id = id, label = label, planes = planes }
end

--- The source regions of the current symmetry mode (none for 'off').
function Sectors()
    local m = Symmetry.Mode
    if m == 'mirror_x' or m == 'rot2' then
        return { S('west', 'West half', { 1, 0 }), S('east', 'East half', { -1, 0 }) }
    elseif m == 'mirror_z' then
        return { S('north', 'North half', { 0, 1 }), S('south', 'South half', { 0, -1 }) }
    elseif m == 'mirror_xz' or m == 'rot4' then
        return { S('nw', 'North-west quarter', { 1, 0 }, { 0, 1 }), S('ne', 'North-east quarter', { -1, 0 }, { 0, 1 }),
                 S('sw', 'South-west quarter', { 1, 0 }, { 0, -1 }), S('se', 'South-east quarter', { -1, 0 }, { 0, -1 }) }
    elseif m == 'diag' then
        return { S('lower', 'South-west of the diagonal', { 1, -1 }), S('upper', 'North-east of the diagonal', { -1, 1 }) }
    elseif m == 'diag_both' then
        return { S('n', 'North triangle', { 1, 1 }, { -1, 1 }), S('e', 'East triangle', { -1, 1 }, { -1, -1 }),
                 S('s', 'South triangle', { 1, -1 }, { -1, -1 }), S('w', 'West triangle', { 1, 1 }, { 1, -1 }) }
    end
    return {}
end

--- True when (x, z) is inside the region (a margin of half a unit keeps points on an axis out of every region).
function InSector(sector, x, z)
    local cx, cz = Symmetry.Centre()
    local dx, dz = x - cx, z - cz
    for _, p in sector.planes do
        if p[1] * dx + p[2] * dz >= -MARGIN then return false end
    end
    return true
end

--- True when the point is on an axis (in no region at all).
local function OnAxis(x, z)
    for _, sec in Sectors() do
        if InSector(sec, x, z) then return false end
    end
    return true
end

--- The region as a polygon (flat x, y, z list for the overlay), the map square clipped by its half planes.
function Polygon(sector)
    local cx, cz = Symmetry.Centre()
    local size = (ed_terrain_info and ed_terrain_info()) or 257
    local max = (size or 257) - 1
    local pts = { { 0, 0 }, { max, 0 }, { max, max }, { 0, max } }
    for _, p in sector.planes do
        local out = {}
        local n = table.getn(pts)
        for i = 1, n do
            local a, b = pts[i], pts[math.mod(i, n) + 1]
            local fa = p[1] * (a[1] - cx) + p[2] * (a[2] - cz)
            local fb = p[1] * (b[1] - cx) + p[2] * (b[2] - cz)
            if fa <= 0 then table.insert(out, a) end
            if (fa < 0 and fb > 0) or (fa > 0 and fb < 0) then
                local t = fa / (fa - fb)
                table.insert(out, { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t })
            end
        end
        pts = out
    end
    local flat = {}
    for _, q in pts do
        table.insert(flat, q[1]) table.insert(flat, 40) table.insert(flat, q[2])
    end
    return flat
end

local OVERLAY = 'mirrorhalf:source'

function ShowSector(sector)
    if rawget(_G, 'ed_overlay_set') == nil then return end
    if not sector then ClearSector() return end
    local flat = Polygon(sector)
    if table.getn(flat) >= 9 then ed_overlay_set(OVERLAY, flat, 'FF40FF60', 0.8, 2, 6, true, false) end
end

function ClearSector()
    if rawget(_G, 'ed_overlay_remove') ~= nil then ed_overlay_remove(OVERLAY) end
end

-- ---- armies ---------------------------------------------------------------------------------------------------------------------------------------------

local function StartOf(army)
    local m = Markers()[army]
    if m and m.position and string.find(army, '^ARMY_%d+$') then return m.position[1], m.position[3] end
    return nil
end

--- The army an object of `army` belongs to at the image `image` ({ x, z, kind, angle } of Symmetry.Points): the army whose start marker is the same image of the army's own start
--- marker. Armies without a start marker, and images without a matching army, keep `army`.
function ArmyImage(army, image, mode)
    if (mode or ArmyMode) ~= 'map' or not image then return army end
    local sx, sz = StartOf(army)
    if not sx then return army end
    local best, bestD = nil, 9
    for _, q in Symmetry.Points(sx, sz) do
        if q.kind == image.kind and math.abs((q.angle or 0) - (image.angle or 0)) < 0.01 then
            for name, _ in (Map.Doc.save.Armies or {}) do
                local ox, oz = StartOf(name)
                if ox then
                    local d = math.sqrt((ox - q.x) * (ox - q.x) + (oz - q.z) * (oz - q.z))
                    if d < bestD then best, bestD = name, d end
                end
            end
        end
    end
    return best or army
end

-- ---- collecting -------------------------------------------------------------------------------------------------------------------------------------------

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

local function AreaCentre(a)
    local r = a.rectangle
    return (r[1] + r[3]) / 2, (r[2] + r[4]) / 2
end

--- The objects of the chosen categories for which `pick(x, z)` is true: { markers = { names }, areas = { names }, props = { data }, decals = { data }, units = { data } }.
local function Gather(cats, pick)
    local out = { markers = {}, areas = {}, props = {}, decals = {}, units = {} }
    if cats.markers then
        for name, m in Markers() do
            if m.position and m.position[1] and not string.find(name, '^ARMY_%d+$') and pick(m.position[1], m.position[3]) then table.insert(out.markers, name) end
        end
        table.sort(out.markers)
    end
    if cats.areas then
        for name, a in Map.Doc.save.Areas or {} do
            if name ~= 'AREA_1' and a.rectangle then
                local x, z = AreaCentre(a)
                if pick(x, z) then table.insert(out.areas, name) end
            end
        end
        table.sort(out.areas)
    end
    if cats.props then
        for i = 1, ed_prop_count() do
            local bp, x, y, z, qw, qx, qy, qz, sx, sy, sz = ed_prop_get(i)
            if bp and pick(x, z) then
                table.insert(out.props, { bp = bp, x = x, y = y, z = z, heading = 2 * math.atan2(qy, qw), sx = sx, sy = sy, sz = sz })
            end
        end
    end
    if cats.decals then
        for i = 1, ed_decal_count() do
            local t0, t1, kind, x, y, z, sx, sy, sz, ox, oy, oz, cutoff = ed_decal_get(i)
            if t0 and pick(x, z) then
                table.insert(out.decals, { tex = t0, kind = kind, x = x, y = y, z = z, sx = sx, sy = sy, sz = sz, ox = ox, oy = oy, oz = oz, cutoff = cutoff })
            end
        end
    end
    if cats.units then
        for _, u in import('/lua/editor/units.lua').All() do
            if pick(u.x, u.z) then table.insert(out.units, u) end
        end
    end
    return out
end

local function Count(t)
    return table.getn(t.markers) + table.getn(t.areas) + table.getn(t.props) + table.getn(t.decals) + table.getn(t.units)
end

--- What a run with these options would do (nothing is changed).
function Plan(opts)
    if not Map.Doc then return { error = 'no map' } end
    if Symmetry.Mode == 'off' then return { error = 'set a symmetry mode first (Symmetry panel)' } end
    local sectors = Sectors()
    local sector = sectors[opts.sector or 1]
    if not sector then return { error = 'no such region' } end
    local cats = opts.cats or {}
    local source = Gather(cats, function(x, z) return InSector(sector, x, z) end)
    local others
    if opts.mode == 'replace' then
        others = Gather(cats, function(x, z) return not InSector(sector, x, z) and not OnAxis(x, z) end)
    end
    local images = 0
    local function N(list, pos)
        for _, o in list do
            local x, z = pos(o)
            images = images + table.getn(Symmetry.Points(x, z)) - 1
        end
    end
    N(source.markers, function(n) local p = Markers()[n].position return p[1], p[3] end)
    N(source.areas, function(n) return AreaCentre(Map.Doc.save.Areas[n]) end)
    for _, k in { 'props', 'decals', 'units' } do N(source[k], function(o) return o.x, o.z end) end
    return { sector = sector, source = source, others = others, images = images, nSource = Count(source), nOthers = others and Count(others) or 0 }
end

-- ---- doing it ----------------------------------------------------------------------------------------------------------------------------------------------

local function Key(a, x, z)
    return tostring(a) .. '|' .. math.floor(x * 100 + 0.5) .. '|' .. math.floor(z * 100 + 0.5)
end

--- Removes the props / decals of `list` (data with bp / tex, x, z) in one pass; returns how many went.
local function RemoveListed(kind, list)
    if table.getn(list) == 0 then return 0 end
    local want = {}
    for _, d in list do
        local k = Key(kind == 'props' and d.bp or d.tex, d.x, d.z)
        want[k] = (want[k] or 0) + 1
    end
    local found = {}
    if kind == 'props' then
        for i = 1, ed_prop_count() do
            local bp, x, y, z = ed_prop_get(i)
            local k = bp and Key(bp, x, z)
            if k and want[k] and want[k] > 0 then want[k] = want[k] - 1 table.insert(found, i) end
        end
    else
        for i = 1, ed_decal_count() do
            local t0, t1, kind2, x, y, z = ed_decal_get(i)
            local k = t0 and Key(t0, x, z)
            if k and want[k] and want[k] > 0 then want[k] = want[k] - 1 table.insert(found, i) end
        end
    end
    if kind == 'props' then
        return import('/lua/editor/propbulk.lua').Remove(found)
    end
    for j = table.getn(found), 1, -1 do Map.RemoveDecal(found[j]) end
    return table.getn(found)
end

local function AddProps(list)
    for _, d in list do Map.AddProp(d.bp, d.x, d.y, d.z, d.heading, { d.sx, d.sy, d.sz }) end
end

local function AddDecals(list)
    for _, d in list do ed_decal_add(d.tex, d.kind, d.x, d.y, d.z, d.ox, d.oy, d.oz, d.sx, d.sy, d.sz, d.cutoff) end
end

local function NewMarkerName(type)
    local n = 1
    local name
    repeat
        name = string.format('%s %02d', type or 'Blank Marker', n)
        n = n + 1
    until Markers()[name] == nil
    return name
end

local function NewAreaName(base)
    local n = 1
    while Map.Doc.save.Areas[base .. '_' .. n] do n = n + 1 end
    return base .. '_' .. n
end

--- Mirrors. Returns the number of copies made and of objects removed, or 0, 0 and a reason.
function Run(opts)
    if not Map.Doc or Tools.ReadOnly then return 0, 0, 'read only' end
    local plan = Plan(opts)
    if plan.error then return 0, 0, plan.error end
    local Units = import('/lua/editor/units.lua')
    local Grid = import('/lua/editor/grid.lua')
    local armyMode = opts.armies or ArmyMode
    local src, oth = plan.source, plan.others
    local rec = { markers = { added = {}, removed = {} }, areas = { added = {}, removed = {} }, props = { added = {}, removed = {} }, decals = { added = {}, removed = {} },
                  units = { added = {}, removed = {} } }

    -- 1. the other regions are emptied (replace)
    if oth then
        for _, name in oth.markers do table.insert(rec.markers.removed, { name = name, obj = Markers()[name] }) Markers()[name] = nil end
        for _, name in oth.areas do table.insert(rec.areas.removed, { name = name, obj = Map.Doc.save.Areas[name] }) Map.Doc.save.Areas[name] = nil end
        rec.props.removed = oth.props
        rec.decals.removed = oth.decals
        RemoveListed('props', oth.props)
        RemoveListed('decals', oth.decals)
        for _, u in oth.units do table.insert(rec.units.removed, u) Units.RemoveRaw(u) end
    end

    -- 2. the images
    local made = 0
    for _, name in src.markers do
        local m = Markers()[name]
        local yaw = (m.orientation and m.orientation[2]) or 0
        local pts = Symmetry.Points(m.position[1], m.position[3])
        for i = 2, table.getn(pts) do
            local p = pts[i]
            local c = Copy(m)
            c.adjacentTo = nil
            local x, z = p.x, p.z
            if m.type == 'Mass' or m.type == 'Hydrocarbon' then
                local ok, sx, sz = pcall(function() return Grid.SnapMarker(m.type, x, z) end)
                if ok and sx then x, z = sx, sz end
            end
            c.position = { x, Ground(x, z), z, type = 'VECTOR3' }
            local o = Copy(m.orientation) or { 0, 0, 0, type = 'VECTOR3' }
            o[2] = Symmetry.Heading(yaw, p)
            c.orientation = o
            local newName = NewMarkerName(m.type)
            Markers()[newName] = c
            table.insert(rec.markers.added, { name = newName, obj = c })
            made = made + 1
        end
    end
    for _, name in src.areas do
        local r = Map.Doc.save.Areas[name].rectangle
        local images = Symmetry.Rect(r[1], r[2], r[3], r[4])
        for i = 2, table.getn(images) do
            local img = images[i]
            local newName = NewAreaName(name)
            Map.AddArea(newName, img[1], img[2], img[3], img[4])
            table.insert(rec.areas.added, { name = newName, obj = Map.Doc.save.Areas[newName] })
            made = made + 1
        end
    end
    for _, d in src.props do
        local pts = Symmetry.Points(d.x, d.z)
        for i = 2, table.getn(pts) do
            local n = Copy(d)
            n.x, n.z = pts[i].x, pts[i].z
            n.y = Ground(n.x, n.z)
            n.heading = Symmetry.Heading(d.heading or 0, pts[i])
            table.insert(rec.props.added, n)
            made = made + 1
        end
    end
    for _, d in src.decals do
        local pts = Symmetry.Points(d.x, d.z)
        for i = 2, table.getn(pts) do
            local n = Copy(d)
            n.x, n.z = pts[i].x, pts[i].z
            n.y = Ground(n.x, n.z)
            n.oy = Symmetry.Heading(d.oy or 0, pts[i])
            table.insert(rec.decals.added, n)
            made = made + 1
        end
    end
    AddProps(rec.props.added)
    AddDecals(rec.decals.added)
    local names = Units.NameCounter()
    for _, u in src.units do
        local pts = Symmetry.Points(u.x, u.z)
        for i = 2, table.getn(pts) do
            local n = Copy(u)
            n.x, n.z = pts[i].x, pts[i].z
            n.y = Ground(n.x, n.z)
            n.heading = Symmetry.Heading(u.heading or 0, pts[i])
            local army = ArmyImage(u.army, pts[i], armyMode)
            if Map.Doc.save.Armies and Map.Doc.save.Armies[army] then n.army = army end
            n.name = names()
            if Units.AddRaw(n) then
                table.insert(rec.units.added, n)
                made = made + 1
            end
        end
    end

    local removed = Count({ markers = rec.markers.removed, areas = rec.areas.removed, props = rec.props.removed, decals = rec.decals.removed, units = rec.units.removed })
    if made == 0 and removed == 0 then return 0, 0, 'nothing in that region' end
    Tools.Prune()
    Tools.Changed = (Tools.Changed or 0) + 1
    local function Undo()
        for _, e in rec.markers.added do Markers()[e.name] = nil end
        for _, e in rec.areas.added do Map.Doc.save.Areas[e.name] = nil end
        RemoveListed('props', rec.props.added)
        RemoveListed('decals', rec.decals.added)
        for _, u in rec.units.added do Units.RemoveRaw(u) end
        for _, e in rec.markers.removed do Markers()[e.name] = e.obj end
        for _, e in rec.areas.removed do Map.Doc.save.Areas[e.name] = e.obj end
        AddProps(rec.props.removed)
        AddDecals(rec.decals.removed)
        for _, u in rec.units.removed do Units.AddRaw(u) end
        Tools.Prune()
        Tools.Changed = (Tools.Changed or 0) + 1
    end
    local function Redo()
        for _, e in rec.markers.removed do Markers()[e.name] = nil end
        for _, e in rec.areas.removed do Map.Doc.save.Areas[e.name] = nil end
        RemoveListed('props', rec.props.removed)
        RemoveListed('decals', rec.decals.removed)
        for _, u in rec.units.removed do Units.RemoveRaw(u) end
        for _, e in rec.markers.added do Markers()[e.name] = e.obj end
        for _, e in rec.areas.added do Map.Doc.save.Areas[e.name] = e.obj end
        AddProps(rec.props.added)
        AddDecals(rec.decals.added)
        for _, u in rec.units.added do Units.AddRaw(u) end
        Tools.Prune()
        Tools.Changed = (Tools.Changed or 0) + 1
    end
    History.Push({ label = 'mirror the ' .. string.lower(plan.sector.label) .. (oth and ' (replace)' or ''), undo = Undo, redo = Redo })
    return made, removed
end
