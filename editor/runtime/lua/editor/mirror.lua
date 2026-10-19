-- Mirror the selection through the symmetry definition (Symmetry panel): copies of the selected markers, areas, props, units and decals are put at the images of their positions,
-- with the heading mapped through the same transform. One undo step. (Placing with a tool already follows the symmetry; this is for what is already there.) A unit's army is kept,
-- or mapped to the army whose start position is the image of its own (mirrorhalf.ArmyMode, the Symmetry panel's switch). The whole half at once: mirrorhalf.lua.
--
--   Available()      true when a symmetry mode other than "off" is set
--   Mirror()         -> number of copies made, or 0 and a reason
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local History = import('/lua/editor/history.lua')
local Symmetry = import('/lua/editor/symmetry.lua')

function Available()
    return Symmetry.Mode ~= 'off'
end

local function CopyTable(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = CopyTable(v) end
    return c
end

local function NewAreaName(base)
    local n = 1
    while Map.Doc.save.Areas[base .. '_' .. n] do n = n + 1 end
    return base .. '_' .. n
end

function Mirror()
    if not Map.Doc or Tools.ReadOnly then return 0, 'read only' end
    if not Available() then return 0, 'set a symmetry mode first (Symmetry panel)' end
    local before = History.Depth()
    local made = 0
    local markers = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
    local items = {}
    for _, it in Tools.Items do table.insert(items, { kind = it.kind, name = it.name }) end
    for _, it in items do
        if it.kind == 'marker' and markers[it.name] then
            local src = markers[it.name]
            local yaw = (src.orientation and src.orientation[2]) or 0
            local pts = Symmetry.Points(src.position[1], src.position[3])
            for i = 2, table.getn(pts) do
                local p = pts[i]
                local name = Tools.PasteMarker(src, p.x, p.z)
                if name and markers[name] then
                    local o = CopyTable(src.orientation) or { 0, 0, 0 }
                    o[2] = Symmetry.Heading(yaw, p)
                    markers[name].orientation = o
                    made = made + 1
                end
            end
        elseif it.kind == 'area' and Map.Doc.save.Areas[it.name] then
            local r = Map.Doc.save.Areas[it.name].rectangle
            local images = Symmetry.Rect(r[1], r[2], r[3], r[4])
            for i = 2, table.getn(images) do
                local img = images[i]
                local name = NewAreaName(it.name)
                Map.AddArea(name, img[1], img[2], img[3], img[4])
                local area = Map.Doc.save.Areas[name]
                History.Push({
                    label = 'mirror ' .. it.name,
                    undo = function() Map.Doc.save.Areas[name] = nil Tools.Prune() Tools.Changed = Tools.Changed + 1 end,
                    redo = function() Map.Doc.save.Areas[name] = area Tools.Changed = Tools.Changed + 1 end,
                })
                Tools.Changed = Tools.Changed + 1
                made = made + 1
            end
        end
    end
    -- the selected props
    local Props = import('/lua/editor/props.lua')
    if table.getn(Props.Selection) > 0 then
        local list = {}
        for _, d in Props.SelectedData() do
            local pts = Symmetry.Points(d.x, d.z)
            for i = 2, table.getn(pts) do
                local n = {}
                for k, v in d do n[k] = v end
                n.x, n.z = pts[i].x, pts[i].z
                n.heading = Symmetry.Heading(d.heading or 0, pts[i])
                table.insert(list, n)
            end
        end
        if table.getn(list) > 0 then
            made = made + Props.PasteExact(list, 'mirror props')
        end
    end
    -- the selected units
    local Units = import('/lua/editor/units.lua')
    if table.getn(Units.Selection) > 0 then
        local H = import('/lua/editor/mirrorhalf.lua')
        local list = {}
        for _, d in Units.SelectedData() do
            local pts = Symmetry.Points(d.x, d.z)
            for i = 2, table.getn(pts) do
                local n = CopyTable(d)
                n.x, n.z = pts[i].x, pts[i].z
                n.heading = Symmetry.Heading(d.heading or 0, pts[i])
                local army = H.ArmyImage(d.army, pts[i])
                if Map.Doc.save.Armies and Map.Doc.save.Armies[army] then n.army = army end
                table.insert(list, n)
            end
        end
        if table.getn(list) > 0 then made = made + Units.PasteExact(list, 'mirror units') end
    end
    -- the selected decals
    local Decals = import('/lua/editor/decals.lua')
    if table.getn(Decals.Selection) > 0 then
        local list = {}
        for _, d in Decals.SelectedData() do
            local pts = Symmetry.Points(d.x, d.z)
            for i = 2, table.getn(pts) do
                local n = CopyTable(d)
                n.x, n.z = pts[i].x, pts[i].z
                n.heading = Symmetry.Heading(d.heading or 0, pts[i])
                table.insert(list, n)
            end
        end
        if table.getn(list) > 0 then made = made + Decals.PasteExact(list, 'mirror decals') end
    end
    local pushed = History.Depth() - before
    if pushed > 1 then History.Merge(pushed, 'mirror selection') end
    if made == 0 then return 0, 'nothing selected that can be mirrored' end
    return made
end
