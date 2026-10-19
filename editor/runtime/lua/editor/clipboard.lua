-- Copy, cut, paste and duplicate of the selected objects: markers, areas and props (the select tools' selections together). The copies keep their offsets from each
-- other; paste puts the group's centre at the pointer (or a few units off the original when the pointer is not over the world). Pasted start positions get the next
-- ARMY_<n>. Everything pasted is one undo step and is selected afterwards.
--
--   Copy() -> number of objects copied      Cut()      Paste([x, z])      Duplicate()      Count()
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local Props = import('/lua/editor/props.lua')
local History = import('/lua/editor/history.lua')

local clip = false          -- { markers = {...}, areas = {...}, props = {...}, decals = {...}, units = {...}, cx, cz }

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

function Count()
    if not clip then return 0 end
    return table.getn(clip.markers) + table.getn(clip.areas) + table.getn(clip.props) + table.getn(clip.decals) + table.getn(clip.units)
end

local function CopyTable(t)
    local c = {}
    for k, v in t do
        if type(v) == 'table' then
            local inner = {}
            for k2, v2 in v do inner[k2] = v2 end
            c[k] = inner
        else
            c[k] = v
        end
    end
    return c
end

function Copy()
    if not Map.Doc then return 0 end
    local markers, areas, props = {}, {}, {}
    local sx, sz, n = 0, 0, 0
    for _, it in Tools.Items do
        if it.kind == 'marker' then
            local m = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers[it.name]
            if m then
                table.insert(markers, { name = it.name, data = CopyTable(m), x = m.position[1], z = m.position[3] })
                sx, sz, n = sx + m.position[1], sz + m.position[3], n + 1
            end
        elseif it.kind == 'area' then
            local a = Map.Doc.save.Areas[it.name]
            if a and a.rectangle then
                local r = a.rectangle
                table.insert(areas, { rect = { r[1], r[2], r[3], r[4] }, x = (r[1] + r[3]) / 2, z = (r[2] + r[4]) / 2 })
                sx, sz, n = sx + (r[1] + r[3]) / 2, sz + (r[2] + r[4]) / 2, n + 1
            end
        end
    end
    for _, d in Props.SelectedData() do
        table.insert(props, d)
        sx, sz, n = sx + d.x, sz + d.z, n + 1
    end
    local decals = {}
    for _, d in import('/lua/editor/decals.lua').SelectedData() do
        table.insert(decals, d)
        sx, sz, n = sx + d.x, sz + d.z, n + 1
    end
    local units = {}
    for _, u in import('/lua/editor/units.lua').SelectedData() do
        table.insert(units, u)
        sx, sz, n = sx + u.x, sz + u.z, n + 1
    end
    if n == 0 then
        Say('nothing selected to copy')
        return 0
    end
    clip = { markers = markers, areas = areas, props = props, decals = decals, units = units, cx = sx / n, cz = sz / n }
    Say('copied ' .. n .. ' objects')
    return n
end

function Cut()
    local n = Copy()
    if n > 0 then
        if table.getn(Props.Selection) > 0 then Props.DeleteSelected() end
        local Decals = import('/lua/editor/decals.lua')
        if table.getn(Decals.Selection) > 0 then Decals.DeleteSelected() end
        local Units = import('/lua/editor/units.lua')
        if table.getn(Units.Selection) > 0 then Units.DeleteSelected() end
        if Tools.SelectionCount() > 0 then Tools.DeleteSelection() end
    end
    return n
end

--- Pastes with the group's centre at (x, z).
function Paste(x, z)
    if not clip or Count() == 0 then
        Say('the clipboard is empty')
        return 0
    end
    if not x then
        local p = GetMouseWorldPos and GetMouseWorldPos()
        if p and import('/lua/ui/game/worldview.lua').viewLeft.CursorOverWorld then
            x, z = p[1], p[3]
        else
            x, z = clip.cx + 6, clip.cz + 6
        end
    end
    local dx, dz = x - clip.cx, z - clip.cz
    local depth = History.Depth()
    local newItems = {}
    local Armies = import('/lua/editor/armies.lua')
    for _, m in clip.markers do
        local name
        if string.find(m.name, '^ARMY_%d+$') then name = Armies.NextName() end
        local placed = Tools.PasteMarker(m.data, m.x + dx, m.z + dz, name)
        if placed then table.insert(newItems, { kind = 'marker', name = placed }) end
    end
    for _, a in clip.areas do
        local placed = Tools.PasteArea(a.rect, dx, dz)
        if placed then table.insert(newItems, { kind = 'area', name = placed }) end
    end
    local propCount = 0
    if table.getn(clip.props) > 0 then
        propCount = Props.Paste(clip.props, dx, dz)
    end
    if table.getn(clip.decals) > 0 then
        propCount = propCount + import('/lua/editor/decals.lua').Paste(clip.decals, dx, dz)
    end
    if table.getn(clip.units) > 0 then
        propCount = propCount + import('/lua/editor/units.lua').Paste(clip.units, dx, dz)
    end
    local after = History.Depth()
    local entries = (after - depth)
    if entries > 1 then History.Merge(entries, 'paste ' .. Count() .. ' objects') end
    if table.getn(newItems) > 0 then Tools.SelectMany(newItems, false) end
    Say('pasted ' .. (table.getn(newItems) + propCount) .. ' objects')
    return table.getn(newItems) + propCount
end

function Duplicate()
    if Copy() == 0 then return 0 end
    return Paste(clip.cx + 5, clip.cz + 5)
end
