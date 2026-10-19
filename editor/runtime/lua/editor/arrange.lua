-- Align, distribute and snap the selection. The selection that counts is the one of the active tool: markers and areas (select tool), units (Select units), props (Select props),
-- decals (Select decals). One undo step per command (the moves are merged).
--
--   Count()                              number of selected objects of the active tool's kind
--   Align(mode)                          'left' | 'right' | 'top' | 'bottom' | 'centerx' | 'centerz': every object takes the extreme / middle of the selection's bounds (x to the west
--                                        or east, z to the north or south side; areas move as a whole by their centre)
--   Distribute(axis)                     'x' | 'z': the objects keep their order along the axis and are spaced evenly between the first and the last
--   Circle()                             the objects are put on a circle around their centre (radius = their mean distance), in the order of their angle
--   Snap(step)                           every object's position rounded to a multiple of `step` world units
--   Kind()                               'markers' | 'units' | 'props' | 'decals' (what the commands act on)
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local History = import('/lua/editor/history.lua')
local UI = import('/lua/editor/ui.lua')

function Kind()
    local tool = UI.State.tool
    if tool == 'unit_select' then return 'units' end
    if tool == 'prop_select' then return 'props' end
    if tool == 'decal_select' then return 'decals' end
    return 'markers'
end

-- Each kind: Items() -> list of { x, z, ref }, Move(item, x, z) (the object goes to (x, z)), Restore(items) (selection after the moves).
local function MarkerItems()
    local list = {}
    local markers = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
    for _, it in Tools.Items do
        if it.kind == 'marker' and markers[it.name] then
            local p = markers[it.name].position
            table.insert(list, { x = p[1], z = p[3], ref = it.name, kind = 'marker' })
        elseif it.kind == 'area' and Map.Doc.save.Areas[it.name] then
            local r = Map.Doc.save.Areas[it.name].rectangle
            table.insert(list, { x = (r[1] + r[3]) / 2, z = (r[2] + r[4]) / 2, ref = it.name, kind = 'area', w = r[3] - r[1], h = r[4] - r[2] })
        end
    end
    return list
end

local function MoveMarkerItem(item, x, z)
    if item.kind == 'marker' then
        Tools.SetMarkerPosition(item.ref, x, z)
    else
        Tools.SetAreaRect(item.ref, x - item.w / 2, z - item.h / 2, x + item.w / 2, z + item.h / 2)
    end
end

local function UnitItems()
    local Units = import('/lua/editor/units.lua')
    local list = {}
    for _, sel in Units.Selection do
        for _, u in Units.All() do
            if u.army == sel.army and u.name == sel.name then
                table.insert(list, { x = u.x, z = u.z, ref = { army = u.army, name = u.name } })
            end
        end
    end
    return list
end

local function MoveUnitItem(item, x, z)
    local Units = import('/lua/editor/units.lua')
    Units.Selection = { { army = item.ref.army, name = item.ref.name } }
    Units.MoveTo(x, z)
end

local function PropItems()
    local Props = import('/lua/editor/props.lua')
    local list = {}
    for _, p in Props.Selection do table.insert(list, { x = p.x, z = p.z, ref = { bp = p.bp, x = p.x, z = p.z } }) end
    return list
end

local function MovePropItem(item, x, z)
    local Props = import('/lua/editor/props.lua')
    Props.Selection = { { bp = item.ref.bp, x = item.ref.x, z = item.ref.z } }
    Props.MoveTo(x, z)
    local s = Props.Selection[1]
    if s then item.ref = { bp = s.bp, x = s.x, z = s.z } end
end

local function DecalItems()
    local Decals = import('/lua/editor/decals.lua')
    local list = {}
    for _, d in Decals.Selection do table.insert(list, { x = d.x, z = d.z, ref = { tex = d.tex, x = d.x, z = d.z } }) end
    return list
end

local function MoveDecalItem(item, x, z)
    local Decals = import('/lua/editor/decals.lua')
    Decals.Selection = { { tex = item.ref.tex, x = item.ref.x, z = item.ref.z } }
    Decals.MoveTo(x, z)
    local s = Decals.Selection[1]
    if s then item.ref = { tex = s.tex, x = s.x, z = s.z } end
end

local function Adapter()
    local kind = Kind()
    if kind == 'units' then return UnitItems, MoveUnitItem, kind end
    if kind == 'props' then return PropItems, MovePropItem, kind end
    if kind == 'decals' then return DecalItems, MoveDecalItem, kind end
    return MarkerItems, MoveMarkerItem, kind
end

function Count()
    if not Map.Doc then return 0 end
    local items = Adapter()
    return table.getn(items())
end

--- Runs `compute(items)` -> list of { x, z } targets (same order), moves every object, merges the undo entries, restores the selection. Returns the number moved.
local function Apply(label, compute, minCount)
    if not Map.Doc or Tools.ReadOnly then return 0 end
    local items, move, kind = Adapter()
    local list = items()
    if table.getn(list) < (minCount or 2) then return 0 end
    local targets = compute(list)
    local before = History.Depth()
    local moved = 0
    for i, item in list do
        local t = targets[i]
        if t and (math.abs(t.x - item.x) > 0.001 or math.abs(t.z - item.z) > 0.001) then
            move(item, t.x, t.z)
            moved = moved + 1
        end
    end
    local pushed = History.Depth() - before
    if pushed > 1 then History.Merge(pushed, label) end
    -- selection back on everything that was selected
    if kind == 'units' then
        local Units = import('/lua/editor/units.lua')
        Units.Selection = {}
        for _, item in list do table.insert(Units.Selection, { army = item.ref.army, name = item.ref.name }) end
        Units.SelRevision = Units.SelRevision + 1
    elseif kind == 'props' then
        local Props = import('/lua/editor/props.lua')
        Props.Selection = {}
        for _, item in list do table.insert(Props.Selection, { bp = item.ref.bp, x = item.ref.x, z = item.ref.z }) end
        Props.SelRevision = Props.SelRevision + 1
    elseif kind == 'decals' then
        local Decals = import('/lua/editor/decals.lua')
        Decals.Selection = {}
        for _, item in list do table.insert(Decals.Selection, { tex = item.ref.tex, x = item.ref.x, z = item.ref.z }) end
        Decals.SelRevision = Decals.SelRevision + 1
    end
    return moved
end

local function Bounds(list)
    local x0, z0, x1, z1
    for _, it in list do
        if not x0 or it.x < x0 then x0 = it.x end
        if not x1 or it.x > x1 then x1 = it.x end
        if not z0 or it.z < z0 then z0 = it.z end
        if not z1 or it.z > z1 then z1 = it.z end
    end
    return x0, z0, x1, z1
end

function Align(mode)
    return Apply('align ' .. mode, function(list)
        local x0, z0, x1, z1 = Bounds(list)
        local out = {}
        for i, it in list do
            local x, z = it.x, it.z
            if mode == 'left' then x = x0
            elseif mode == 'right' then x = x1
            elseif mode == 'centerx' then x = (x0 + x1) / 2
            elseif mode == 'top' then z = z0
            elseif mode == 'bottom' then z = z1
            elseif mode == 'centerz' then z = (z0 + z1) / 2 end
            out[i] = { x = x, z = z }
        end
        return out
    end)
end

function Distribute(axis)
    return Apply('distribute along ' .. axis, function(list)
        local order = {}
        for i, it in list do table.insert(order, { i = i, v = (axis == 'x') and it.x or it.z }) end
        table.sort(order, function(a, b) return a.v < b.v end)
        local n = table.getn(order)
        local lo, hi = order[1].v, order[n].v
        local out = {}
        for rank, o in order do
            local v = lo + (hi - lo) * (rank - 1) / math.max(1, n - 1)
            local it = list[o.i]
            out[o.i] = (axis == 'x') and { x = v, z = it.z } or { x = it.x, z = v }
        end
        return out
    end)
end

function Circle()
    return Apply('arrange in a circle', function(list)
        local cx, cz = 0, 0
        for _, it in list do cx, cz = cx + it.x, cz + it.z end
        cx, cz = cx / table.getn(list), cz / table.getn(list)
        local radius = 0
        for _, it in list do radius = radius + math.sqrt((it.x - cx) * (it.x - cx) + (it.z - cz) * (it.z - cz)) end
        radius = math.max(2, radius / table.getn(list))
        local order = {}
        for i, it in list do table.insert(order, { i = i, a = math.atan2(it.z - cz, it.x - cx) }) end
        table.sort(order, function(a, b) return a.a < b.a end)
        local n = table.getn(order)
        local start = order[1].a
        local out = {}
        for rank, o in order do
            local a = start + 2 * math.pi * (rank - 1) / n
            out[o.i] = { x = cx + radius * math.cos(a), z = cz + radius * math.sin(a) }
        end
        return out
    end)
end

--- Rounds every position to a multiple of `step` (units). Works for one object as well.
function Snap(step)
    step = step or 1
    return Apply('snap to grid ' .. step, function(list)
        local out = {}
        for i, it in list do
            out[i] = { x = math.floor(it.x / step + 0.5) * step, z = math.floor(it.z / step + 0.5) * step }
        end
        return out
    end, 1)
end
