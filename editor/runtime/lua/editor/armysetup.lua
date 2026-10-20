-- Army setup of a mission map: the armies of the save file (`Scenario.Armies`) and the order in the scenario's army list (the army index is the position
-- in `ScenarioInfo.Configurations.standard.teams[1].armies`). Faction, colour, economy and the alliances every army holds towards the others are what
-- ScenarioUtils.InitializeScenarioArmies applies (faf_repo/fa/lua/sim/ScenarioUtilities.lua:813): SetArmyEconomy, SetArmyFactionIndex, SetArmyColorIndex,
-- SetAllianceOneWay(army, other, state) per entry, so an alliance is one direction per army (the editor sets both unless told otherwise).
--
--   Names()                      the armies in index order
--   Get(name)                    the army table or nil
--   Set(name, field, value, label)       field: 'faction' | 'color' | 'mass' | 'energy' | 'personality'; with undo
--   SetAlliance(a, b, state, both)       state 'Ally' | 'Enemy' | 'Neutral' (nil removes the entry: the army keeps the default); with undo
--   AllianceOf(a, b)             the state a holds towards b, or nil
--   Add(name)                    a new army at the end of the list (nil + reason when the name is invalid or taken)
--   Remove(name)                 numbered start position armies (ARMY_<n>) follow their markers and cannot be removed here
--   Move(name, delta)            changes the index
--   Check()                      problems: list of { sev, text }
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')

Factions = { 'UEF', 'Aeon', 'Cybran', 'Seraphim' }
States = { 'Enemy', 'Ally', 'Neutral' }

local function Numbered(name)
    return string.find(name, '^ARMY_%d+$') ~= nil
end

local function Team()
    local info = Map.Doc and Map.Doc.info
    if not info then return nil end
    info.Configurations = info.Configurations or {}
    info.Configurations.standard = info.Configurations.standard or {}
    local std = info.Configurations.standard
    std.teams = std.teams or {}
    if not std.teams[1] then std.teams[1] = { name = 'FFA', armies = {} } end
    std.teams[1].armies = std.teams[1].armies or {}
    return std.teams[1]
end

--- Armies in index order: the team's list, then armies of the save file that the list lacks (by name).
function Names()
    local list, seen = {}, {}
    local team = Team()
    if not team then return list end
    for _, a in team.armies do
        if not seen[a] then seen[a] = true table.insert(list, a) end
    end
    local rest = {}
    for name, _ in Map.Doc.save.Armies or {} do
        if not seen[name] then table.insert(rest, name) end
    end
    table.sort(rest)
    for _, a in rest do table.insert(list, a) end
    return list
end

function Get(name)
    return Map.Doc and Map.Doc.save.Armies and Map.Doc.save.Armies[name]
end

local function Copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = Copy(v) end
    return c
end

--- The settings of every army (not its unit tree), the army list and the army tables themselves, for undo.
local function Snapshot()
    local snap = { order = Copy(Team().armies), armies = {}, tables = {} }
    for name, a in Map.Doc.save.Armies or {} do
        snap.tables[name] = a
        snap.armies[name] = { faction = a.faction, color = a.color, personality = a.personality, plans = a.plans, Economy = Copy(a.Economy), Alliances = Copy(a.Alliances), ArmyIndex = a.ArmyIndex }
    end
    return snap
end

local function Restore(snap)
    local doc = Map.Doc
    doc.save.Armies = doc.save.Armies or {}
    for name, _ in doc.save.Armies do
        if not snap.tables[name] then doc.save.Armies[name] = nil end
    end
    for name, t in snap.tables do
        doc.save.Armies[name] = t
        local s = snap.armies[name]
        t.faction, t.color, t.personality, t.plans, t.ArmyIndex = s.faction, s.color, s.personality, s.plans, s.ArmyIndex
        t.Economy = Copy(s.Economy)
        t.Alliances = Copy(s.Alliances)
    end
    Team().armies = Copy(snap.order)
    Revision = Revision + 1
end

--- Bumped by every change and undo: panels compare it.
Revision = 0

local function Do(label, fn)
    local before = Snapshot()
    local ok, why = fn()
    if ok == false then return nil, why end
    local after = Snapshot()
    Revision = Revision + 1
    History.Push({ label = label, undo = function() Restore(before) end, redo = function() Restore(after) end })
    return true
end

local function Reindex()
    local team = Team()
    for i, name in team.armies do
        local a = Get(name)
        if a then a.ArmyIndex = i end
    end
end

function Set(name, field, value, label)
    local a = Get(name)
    if not a then return nil, 'no such army' end
    return Do(label or ('army ' .. name .. ' ' .. field), function()
        if field == 'mass' or field == 'energy' then
            a.Economy = a.Economy or { mass = 0, energy = 0 }
            a.Economy[field] = value
        else
            a[field] = value
        end
    end)
end

function AllianceOf(a, b)
    local x = Get(a)
    return x and x.Alliances and x.Alliances[b]
end

function SetAlliance(a, b, state, both)
    local x, y = Get(a), Get(b)
    if not x or not y or a == b then return nil, 'no such army pair' end
    return Do('alliance ' .. a .. ' / ' .. b, function()
        x.Alliances = x.Alliances or {}
        x.Alliances[b] = state
        if both then
            y.Alliances = y.Alliances or {}
            y.Alliances[a] = state
        end
    end)
end

function Add(name)
    if not name or name == '' then return nil, 'the army needs a name' end
    if string.find(name, '[^%w_]') then return nil, 'army names take letters, digits and _ only' end
    if Get(name) then return nil, 'there is an army with that name already' end
    return Do('add army ' .. name, function()
        Map.Doc.save.Armies = Map.Doc.save.Armies or {}
        local army = {
            personality = '', plans = '', color = 0, faction = 0,
            Economy = { mass = 0, energy = 0 }, Alliances = {},
            Units = { type = 'GROUP', orders = '', platoon = '',
                      Units = { INITIAL = { type = 'GROUP', orders = '', platoon = '', Units = {} } } },
            PlatoonBuilders = { next_platoon_builder_id = '0', Builders = {} },
        }
        Map.Doc.save.Armies[name] = army
        table.insert(Team().armies, name)
        Reindex()
    end)
end

function Remove(name)
    if Numbered(name) then return nil, 'start position armies follow their markers: delete the marker' end
    if not Get(name) then return nil, 'no such army' end
    return Do('remove army ' .. name, function()
        Map.Doc.save.Armies[name] = nil
        local keep = {}
        for _, a in Team().armies do
            if a ~= name then table.insert(keep, a) end
        end
        Team().armies = keep
        for _, other in Map.Doc.save.Armies do
            if other.Alliances then other.Alliances[name] = nil end
        end
        Reindex()
    end)
end

function Move(name, delta)
    local names = Names()
    local at
    for i, a in names do if a == name then at = i end end
    if not at then return nil, 'no such army' end
    local to = at + delta
    if to < 1 or to > table.getn(names) then return nil, 'already at the end' end
    return Do('move army ' .. name, function()
        local order = {}
        for _, a in names do table.insert(order, a) end
        table.remove(order, at)
        table.insert(order, to, name)
        Team().armies = order
        Reindex()
    end)
end

--- Problems of the army setup (shown by the panel and the validation panel).
function Check()
    local list = {}
    local names = Names()
    if table.getn(names) == 0 then table.insert(list, { sev = 'W', text = 'the map has no armies' }) end
    local seen = {}
    for i, name in names do
        local a = Get(name)
        if not a then
            table.insert(list, { sev = 'E', text = 'army ' .. name .. ' is in the army list but has no entry in the save file' })
        else
            if a.ArmyIndex and a.ArmyIndex ~= i then table.insert(list, { sev = 'W', text = name .. ' has ArmyIndex ' .. a.ArmyIndex .. ' but stands at position ' .. i .. ' of the list' }) end
            if (a.faction or 0) < 0 or (a.faction or 0) > 3 then table.insert(list, { sev = 'W', text = name .. ': faction ' .. tostring(a.faction) .. ' is not one of the four (0-3)' }) end
            for other, state in a.Alliances or {} do
                if not Get(other) then table.insert(list, { sev = 'W', text = name .. ' has an alliance with ' .. other .. ', which is not an army of the map' }) end
                if state ~= 'Ally' and state ~= 'Enemy' and state ~= 'Neutral' then table.insert(list, { sev = 'E', text = name .. ' / ' .. other .. ': alliance state ' .. tostring(state) .. ' is not Ally, Enemy or Neutral' }) end
            end
            -- one-sided alliances: allowed, but the usual setup is mutual
            for other, state in a.Alliances or {} do
                local b = Get(other)
                if b and other > name and state ~= (b.Alliances and b.Alliances[name]) then
                    table.insert(list, { sev = 'I', text = name .. ' sees ' .. other .. ' as ' .. state .. ', ' .. other .. ' sees ' .. name .. ' as ' .. tostring(b.Alliances and b.Alliances[name] or 'default') })
                end
            end
        end
        seen[name] = true
    end
    return list
end
