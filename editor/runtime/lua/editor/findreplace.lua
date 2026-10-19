-- Find and replace objects across the whole map: marker type, prop blueprint, unit blueprint, decal texture.
--
--   KINDS                          { 'marker type', 'prop blueprint', 'unit blueprint', 'decal texture' }
--   Present(kind)                  -> list of { value, count } of what the map contains (sorted by value), for the "find" picker
--   Candidates(kind)               -> list of values a replacement may take (marker types, prop blueprint paths, unit ids, decal texture paths)
--   Count(kind, value)             how many objects match
--   Select(kind, value)            selects the matches (in the select tool of that kind's workspace); returns how many
--   Replace(kind, from, to)        every match becomes `to`, one undo step; returns how many
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local History = import('/lua/editor/history.lua')

KINDS = { 'marker type', 'prop blueprint', 'unit blueprint', 'decal texture' }

local function Tally(counts)
    local list = {}
    for value, n in counts do table.insert(list, { value = value, count = n }) end
    table.sort(list, function(a, b) return a.value < b.value end)
    return list
end

function Present(kind)
    local counts = {}
    if not Map.Doc then return {} end
    if kind == 'marker type' then
        for _, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
            local t = tostring(m.type)
            counts[t] = (counts[t] or 0) + 1
        end
    elseif kind == 'prop blueprint' then
        for i = 1, ed_prop_count() do
            local bp = ed_prop_get(i)
            if bp then counts[bp] = (counts[bp] or 0) + 1 end
        end
    elseif kind == 'unit blueprint' then
        for _, u in import('/lua/editor/units.lua').All() do counts[u.bp] = (counts[u.bp] or 0) + 1 end
    elseif kind == 'decal texture' then
        for i = 1, ed_decal_count() do
            local tex = ed_decal_get(i)
            if tex then counts[tex] = (counts[tex] or 0) + 1 end
        end
    end
    return Tally(counts)
end

function Candidates(kind)
    local list = {}
    if kind == 'marker type' then
        for _, t in Tools.MarkerTypes() do table.insert(list, t.name) end
    elseif kind == 'prop blueprint' then
        for _, e in import('/lua/editor/props.lua').Catalog() do table.insert(list, e.path) end
    elseif kind == 'unit blueprint' then
        for _, e in import('/lua/editor/units.lua').Catalog() do table.insert(list, e.id) end
    elseif kind == 'decal texture' then
        for _, e in import('/lua/editor/decals.lua').Catalog() do table.insert(list, e.path) end
    end
    return list
end

function Count(kind, value)
    for _, e in Present(kind) do
        if e.value == value then return e.count end
    end
    return 0
end

--- Selects the matches; returns how many.
function Select(kind, value)
    local n = 0
    if not Map.Doc then return 0 end
    if kind == 'marker type' then
        Tools.Select(false)
        for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
            if m.type == value then Tools.Select('marker', name, 'add') n = n + 1 end
        end
    elseif kind == 'prop blueprint' then
        local Props = import('/lua/editor/props.lua')
        Props.Selection = {}
        for i = 1, ed_prop_count() do
            local bp, x, y, z = ed_prop_get(i)
            if bp == value then table.insert(Props.Selection, { bp = bp, x = x, z = z }) n = n + 1 end
        end
        Props.SelRevision = Props.SelRevision + 1
    elseif kind == 'unit blueprint' then
        local Units = import('/lua/editor/units.lua')
        Units.Selection = {}
        for _, u in Units.All() do
            if u.bp == value then table.insert(Units.Selection, { army = u.army, name = u.name }) n = n + 1 end
        end
        Units.SelRevision = Units.SelRevision + 1
    elseif kind == 'decal texture' then
        local Decals = import('/lua/editor/decals.lua')
        Decals.Selection = {}
        for i = 1, ed_decal_count() do
            local tex, t1, k, x, y, z = ed_decal_get(i)
            if tex == value then table.insert(Decals.Selection, { tex = tex, x = x, z = z }) n = n + 1 end
        end
        Decals.SelRevision = Decals.SelRevision + 1
    end
    return n
end

--- Every match becomes `to`. Returns the number replaced (0 and a reason when nothing happened).
function Replace(kind, from, to)
    if Tools.ReadOnly then return 0, 'read only' end
    if not Map.Doc then return 0, 'no map' end
    if from == to then return 0, 'nothing to change' end
    if kind == 'marker type' then
        local MP = import('/lua/editor/markerprops.lua')
        local before = History.Depth()
        local n = 0
        for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
            if m.type == from and MP.ChangeType(name, to) then n = n + 1 end
        end
        local pushed = History.Depth() - before
        if pushed > 1 then History.Merge(pushed, 'replace marker type ' .. from .. ' with ' .. to) end
        return n
    elseif kind == 'prop blueprint' then
        return import('/lua/editor/props.lua').ReplaceBlueprint(from, to)
    elseif kind == 'unit blueprint' then
        return import('/lua/editor/units.lua').ReplaceBlueprint(from, to)
    elseif kind == 'decal texture' then
        return import('/lua/editor/decals.lua').ReplaceTexture(from, to)
    end
    return 0, 'unknown kind'
end
