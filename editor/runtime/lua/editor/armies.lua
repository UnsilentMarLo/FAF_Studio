-- Start positions: the markers named ARMY_<n> and the army list of the scenario that must follow them.
--
--   Names()           the start position names (ARMY_1, ARMY_2 ...), sorted by number
--   NextName()        the lowest ARMY_<n> not used yet
--   Place(x, z)       puts a start position marker down (the Army tool), selected, with undo
--   Sync(doc)         makes the scenario file's army list (ScenarioInfo.Configurations.standard.teams[1].armies) and the save file's Armies table match the
--                     start position markers; called by Map.SaveAs. Armies that are not named ARMY_<n> (mission maps) are left alone.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')

local function Number(name)
    local n = string.find(name, '^ARMY_%d+$') and tonumber(string.sub(name, 6))
    return n
end

function Names()
    local list = {}
    if Map.Doc then
        for name, _ in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
            local n = Number(name)
            if n then table.insert(list, { n = n, name = name }) end
        end
    end
    table.sort(list, function(a, b) return a.n < b.n end)
    local names = {}
    for _, e in list do table.insert(names, e.name) end
    return names
end

function NextName()
    local used = {}
    for _, name in Names() do used[name] = true end
    local n = 1
    while used['ARMY_' .. n] do n = n + 1 end
    return 'ARMY_' .. n
end

function Place(x, z)
    local Tools = import('/lua/editor/tools.lua')
    local History = import('/lua/editor/history.lua')
    -- with symmetry on, every image of the point becomes a start position (ARMY_<next>, ...); one undo step
    local first, count = nil, 0
    for _, p in import('/lua/editor/symmetry.lua').Points(x, z) do
        local placed = Tools.PlaceMarker(p.x, p.z, 'Blank Marker', NextName())
        if placed then
            count = count + 1
            first = first or placed
        end
    end
    if count > 1 then History.Merge(count, 'place ' .. count .. ' start positions') end
    return first
end

local function DefaultArmy(index)
    return {
        personality = '', plans = '', color = 0, faction = 0,
        Economy = { mass = 0, energy = 0 },
        Alliances = {},
        ArmyIndex = index,
        Units = { type = 'GROUP', orders = '', platoon = '',
                  Units = { INITIAL = { type = 'GROUP', orders = '', platoon = '', Units = {} } } },
        PlatoonBuilders = { next_platoon_builder_id = '0', Builders = {} },
    }
end

function Sync(doc)
    doc = doc or Map.Doc
    if not doc then return end
    local names = {}
    for name, _ in doc.save.MasterChain._MASTERCHAIN_.Markers do
        local n = Number(name)
        if n then table.insert(names, { n = n, name = name }) end
    end
    local hadNumbered = false
    for name, _ in doc.save.Armies or {} do
        if Number(name) then hadNumbered = true end
    end
    if table.getn(names) == 0 and not hadNumbered then return end       -- not a map with numbered start positions
    table.sort(names, function(a, b) return a.n < b.n end)

    doc.save.Armies = doc.save.Armies or {}
    local list = {}
    for i, e in names do
        table.insert(list, e.name)
        if not doc.save.Armies[e.name] then doc.save.Armies[e.name] = DefaultArmy(i) end
    end
    for name, _ in doc.save.Armies do
        if Number(name) and not doc.save.MasterChain._MASTERCHAIN_.Markers[name] then doc.save.Armies[name] = nil end
    end

    -- the counters and tables the game's own save files carry (the sim does not read them, the map tools of the game do)
    for _, army in doc.save.Armies do
        army.PlatoonBuilders = army.PlatoonBuilders or { next_platoon_builder_id = '0', Builders = {} }
    end
    doc.save.next_army_id = doc.save.next_army_id or tostring(table.getn(names) + 1)
    doc.save.next_group_id = doc.save.next_group_id or '1'
    doc.save.next_unit_id = doc.save.next_unit_id or '1'

    local info = doc.info
    info.Configurations = info.Configurations or {}
    info.Configurations.standard = info.Configurations.standard or {}
    local std = info.Configurations.standard
    std.teams = std.teams or {}
    if not std.teams[1] then std.teams[1] = { name = 'FFA', armies = {} } end
    -- the army list keeps its order (the army index is the position): armies of another name stay, numbered ones stay while their marker does,
    -- new start positions are appended in number order
    local keep, have = {}, {}
    for _, a in std.teams[1].armies or {} do
        if not Number(a) or doc.save.MasterChain._MASTERCHAIN_.Markers[a] then
            table.insert(keep, a)
            have[a] = true
        end
    end
    for _, a in list do
        if not have[a] then table.insert(keep, a) end
    end
    std.teams[1].armies = keep
    for i, a in keep do
        if doc.save.Armies[a] then doc.save.Armies[a].ArmyIndex = i end
    end
end
