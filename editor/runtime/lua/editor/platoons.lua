-- Platoons and orders: the save file's `Platoons` and `Orders` tables and the platoon builders of every army (docs/projects/editor/MAP_EDITOR_DESIGN.md 19.28).
--
--   Platoons[name] = { name, plan, { blueprintId, min, max, squad, formation }, ... }     a platoon template (what ScenarioUtils.CreateArmyGroupAsPlatoon and the platoon
--                                                      build manager read: row 1 the name, row 2 the AI plan, from row 3 one entry per unit type)
--   Orders[name]   = { { type = 'Move' | 'Patrol' | 'Attack' | 'Stop', target = <marker>, chain = <chain> }, ... }     an order queue, in order
--   Armies[army].PlatoonBuilders = { Builders = { name = { PlatoonTemplate, Priority, InstanceCount, LocationType, BuildTimeOut, PlatoonType, RequiresConstruction,
--                                                          PlatoonAIFunction = { file, function, { data }, { data } }, BuildConditions = { { file, function, { args }, { args } }, ... },
--                                                          PlatoonData = {} } } }     (campaign AI: loaded by ScenarioUtils.LoadArmyPBMBuilders)
--   a unit or group of an army's unit tree names its platoon template (`platoon`) and its order queue (`orders`)
--
--   Kinds                                       'platoon' | 'orders' | 'builder'
--   PlatoonNames() / OrderNames() / BuilderNames(army)         sorted names
--   NewPlatoon(name, plan) / FromGroup(army, group, name) / DuplicatePlatoon / RenamePlatoon / DeletePlatoon
--   SetPlan(name, plan) / AddRow(name, row) / SetRow(name, i, key, value) / RemoveRow(name, i) / MoveRow(name, i, delta)
--   NewOrders / RenameOrders / DeleteOrders / DuplicateOrders / AddOrder(name, order) / SetOrder(name, i, key, value) / RemoveOrder / MoveOrder
--   AssignPlatoon(army, group, name) / AssignOrders(army, group, name)       group or unit of the army's tree (name '' clears it)
--   NewBuilder(army, name, template) / SetBuilder(army, name, key, value) / DeleteBuilder / RenameBuilder / DuplicateBuilder / AddCondition / SetCondition / RemoveCondition
--   Problems()                                  list of { sev = 'E' | 'W' | 'I', text, kind, name, army } for the map's validation
--   UsedBy(kind, name)                          what refers to a platoon / order queue: units, groups, builders, mission nodes
--
-- Every edit is one undo step (History). Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')

Revision = 0

SQUADS = { 'attack', 'artillery', 'guard', 'scout', 'support' }
FORMATIONS = { 'None', 'NoFormation', 'AttackFormation', 'GrowthFormation', 'GuardFormation', 'BlockFormation', 'CircleFormation', 'ColumnFormation', 'ChevronFormation', 'LBlockFormation' }
ORDER_TYPES = { 'Move', 'Patrol', 'Attack', 'Stop' }
PLATOON_TYPES = { 'Any', 'Land', 'Air', 'Sea', 'Gate' }

local function Save() return Map.Doc and Map.Doc.save end

local function Bump() Revision = Revision + 1 end

local function ValidName(name)
    return type(name) == 'string' and name ~= '' and not string.find(name, '[^%w_%-]')
end
NameOk = ValidName

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local c = {}
    for k, x in v do c[k] = Copy(x) end
    return c
end
CopyData = Copy

local function Platoons()
    local s = Save()
    if not s then return nil end
    s.Platoons = s.Platoons or {}
    return s.Platoons
end

local function Orders()
    local s = Save()
    if not s then return nil end
    s.Orders = s.Orders or {}
    return s.Orders
end

local function SortedNames(t)
    local list = {}
    for k, _ in t or {} do table.insert(list, k) end
    table.sort(list)
    return list
end

function PlatoonNames() return SortedNames(Platoons()) end
function OrderNames() return SortedNames(Orders()) end

function Armies()
    return SortedNames(Save() and Save().Armies)
end

function Builders(army)
    local a = Save() and Save().Armies and Save().Armies[army]
    return a and a.PlatoonBuilders and a.PlatoonBuilders.Builders
end
function BuilderNames(army) return SortedNames(Builders(army)) end

-- ---- undo: every edit is a list of field changes ----------------------------------------------------------------------------------------------------

local lastMerge = false          -- { key, entry, log } of the latest entry made with a merge key

--- Runs fn(Set) where Set(tbl, key, value) changes a field and remembers the old value; the changes become one undo step. fn may return false to cancel (nothing recorded).
--- With `mergeKey` a second edit with the same key right after the first (a slider being dragged) is folded into the first one's undo step.
local function Edit(label, fn, mergeKey)
    local log = {}
    local function Set(tbl, key, value)
        table.insert(log, { tbl = tbl, key = key, old = tbl[key], new = value })
        tbl[key] = value
    end
    local result = fn(Set)
    if result == false or table.getn(log) == 0 then
        for i = table.getn(log), 1, -1 do log[i].tbl[log[i].key] = log[i].old end
        return false
    end
    if mergeKey and lastMerge and lastMerge.key == mergeKey and History.Top() == lastMerge.entry then
        for _, change in log do table.insert(lastMerge.log, change) end
        History.Version = History.Version + 1
        Bump()
        return true
    end
    local entry = {
        label = label,
        undo = function() for i = table.getn(log), 1, -1 do log[i].tbl[log[i].key] = log[i].old end Bump() end,
        redo = function() for i = 1, table.getn(log) do log[i].tbl[log[i].key] = log[i].new end Bump() end,
    }
    History.Push(entry)
    lastMerge = mergeKey and { key = mergeKey, entry = entry, log = log } or false
    Bump()
    return true
end

-- ---- the unit trees ---------------------------------------------------------------------------------------------------------------------------------

--- Calls fn(node, army, name, isGroup, parent) for every group and unit of every army's unit tree.
local function EachNode(fn)
    local function Walk(tbl, army, parent)
        for name, n in tbl or {} do
            if type(n) == 'table' and n.type then
                local isGroup = n.type == 'GROUP'
                fn(n, army, name, isGroup, parent)
                if isGroup and n.Units then Walk(n.Units, army, n) end
            end
        end
    end
    local s = Save()
    for army, a in (s and s.Armies) or {} do
        if type(a) == 'table' and a.Units and a.Units.Units then Walk(a.Units.Units, army, a.Units) end
    end
end

--- The node (group or unit) `name` of an army's tree.
local function FindNode(army, name)
    local found
    EachNode(function(n, a, nm)
        if not found and a == army and nm == name then found = n end
    end)
    return found
end
FindGroupOrUnit = FindNode

--- Counts the unit types of a group (nested groups included): list of { bp, count } sorted by blueprint id.
function GroupCounts(army, group)
    local node = FindNode(army, group)
    local counts = {}
    local function Walk(tbl)
        for _, n in tbl or {} do
            if type(n) == 'table' and n.type then
                if n.type == 'GROUP' then Walk(n.Units) else counts[n.type] = (counts[n.type] or 0) + 1 end
            end
        end
    end
    if node and node.Units then Walk(node.Units) end
    local list = {}
    for bp, n in counts do table.insert(list, { bp = bp, count = n }) end
    table.sort(list, function(a, b) return a.bp < b.bp end)
    return list
end

--- The groups of the army: top level and nested, sorted.
function GroupNames(army)
    local list = {}
    EachNode(function(n, a, name, isGroup)
        if a == army and isGroup then table.insert(list, name) end
    end)
    table.sort(list)
    return list
end

local function SquadOf(bp)
    local b = __blueprints and __blueprints[bp]
    local cats = {}
    for _, c in (b and b.Categories) or {} do cats[c] = true end
    if cats.ENGINEER or cats.TRANSPORTATION then return 'support' end
    if cats.SCOUT or cats.INTELLIGENCE and cats.AIR and not cats.BOMBER then return 'scout' end
    if cats.ARTILLERY or cats.INDIRECTFIRE and not cats.DIRECTFIRE then return 'artillery' end
    return 'attack'
end

-- ---- platoon templates ------------------------------------------------------------------------------------------------------------------------------

local function Unique(tbl, base)
    local name = base
    local n = 1
    while tbl[name] ~= nil do
        n = n + 1
        name = base .. '_' .. n
    end
    return name
end

--- A new empty platoon template. Returns the name or nil, reason.
function NewPlatoon(name, plan)
    local t = Platoons()
    if not t then return nil, 'no map' end
    if not ValidName(name) then return nil, 'a name takes letters, digits, _ and -' end
    if t[name] then return nil, 'there is already a platoon ' .. name end
    Edit('add platoon ' .. name, function(Set) Set(t, name, { name, plan or '' }) end)
    return name
end

--- A platoon template from the units of a group: one row per unit type (min 0, max = how many the group has). Returns the name or nil, reason.
function FromGroup(army, group, name)
    local t = Platoons()
    if not t then return nil, 'no map' end
    local counts = GroupCounts(army, group)
    if table.getn(counts) == 0 then return nil, 'the group has no units' end
    name = name or Unique(t, 'PLATOON_' .. group)
    if not ValidName(name) then return nil, 'a name takes letters, digits, _ and -' end
    if t[name] then return nil, 'there is already a platoon ' .. name end
    local entry = { name, '' }
    for _, c in counts do table.insert(entry, { c.bp, 0, c.count, SquadOf(c.bp), 'None' }) end
    Edit('platoon from group ' .. group, function(Set) Set(t, name, entry) end)
    return name
end

function DuplicatePlatoon(name)
    local t = Platoons()
    if not t or not t[name] then return nil, 'no such platoon' end
    local new = Unique(t, name .. '_copy')
    local entry = Copy(t[name])
    entry[1] = new
    Edit('duplicate platoon ' .. name, function(Set) Set(t, new, entry) end)
    return new
end

--- Walks mission nodes and bases (kind 'platoon', 'orders' fields); `change(node)` returns true when it changed the node. Returns how many.
local function MissionRefs(field, old, new)
    local M = import('/lua/editor/mission.lua')
    local count = 0
    local function Visit(list)
        for _, node in list or {} do
            if node[field] == old then node[field] = new count = count + 1 end
            Visit(node.children)
        end
    end
    local ok = M.Edit('rename ' .. field .. ' references', function()
        for _, stage in M.Data.stages do
            Visit(stage.enter)
            Visit(stage.ready)
        end
        if count == 0 then return false end
    end)
    return ok and count or 0
end

local function Rename(kind, old, new)
    local t = (kind == 'platoon') and Platoons() or Orders()
    if not t or not t[old] then return nil, 'no such ' .. kind end
    if old == new then return true end
    if not ValidName(new) then return nil, 'a name takes letters, digits, _ and -' end
    if t[new] then return nil, 'there is already a ' .. kind .. ' ' .. new end
    local field = (kind == 'platoon') and 'platoon' or 'orders'
    local refs = 0
    Edit('rename ' .. kind .. ' ' .. old, function(Set)
        local entry = t[old]
        if kind == 'platoon' then entry = Copy(entry) entry[1] = new end
        Set(t, old, nil)
        Set(t, new, entry)
        EachNode(function(n)
            if n[field] == old then Set(n, field, new) refs = refs + 1 end
        end)
        if kind == 'platoon' then
            for _, army in Armies() do
                for _, b in Builders(army) or {} do
                    if b.PlatoonTemplate == old then Set(b, 'PlatoonTemplate', new) refs = refs + 1 end
                end
            end
        end
    end)
    local m = MissionRefs(field, old, new)
    if m > 0 then History.Merge(2, 'rename ' .. kind .. ' ' .. old .. ' to ' .. new) end
    return true, refs + m
end

function RenamePlatoon(old, new) return Rename('platoon', old, new) end
function RenameOrders(old, new) return Rename('orders', old, new) end

--- What refers to a template or queue: list of { kind = 'unit' | 'group' | 'builder' | 'mission', text }.
function UsedBy(kind, name)
    local list = {}
    local field = (kind == 'platoon') and 'platoon' or 'orders'
    EachNode(function(n, army, nm, isGroup)
        if n[field] == name then table.insert(list, { kind = isGroup and 'group' or 'unit', army = army, name = nm, text = (isGroup and 'group ' or 'unit ') .. nm .. ' of ' .. army }) end
    end)
    if kind == 'platoon' then
        for _, army in Armies() do
            for bn, b in Builders(army) or {} do
                if b.PlatoonTemplate == name then table.insert(list, { kind = 'builder', army = army, name = bn, text = 'builder ' .. bn .. ' of ' .. army }) end
            end
        end
    end
    local M = import('/lua/editor/mission.lua')
    local function Visit(l, si)
        for _, node in l or {} do
            if node[field] == name then table.insert(list, { kind = 'mission', text = 'mission stage ' .. si .. ': ' .. tostring(node.type) }) end
            Visit(node.children, si)
        end
    end
    for si, stage in M.Data.stages do
        Visit(stage.enter, si)
        Visit(stage.ready, si)
    end
    return list
end

--- Deletes a template or queue. Units and groups that named it lose the name; builders and mission nodes that use it are left (they show up as problems).
function DeletePlatoon(name) return Delete('platoon', name) end
function DeleteOrders(name) return Delete('orders', name) end

function Delete(kind, name)
    local t = (kind == 'platoon') and Platoons() or Orders()
    if not t or not t[name] then return nil, 'no such ' .. kind end
    local field = (kind == 'platoon') and 'platoon' or 'orders'
    Edit('delete ' .. kind .. ' ' .. name, function(Set)
        Set(t, name, nil)
        EachNode(function(n)
            if n[field] == name then Set(n, field, '') end
        end)
    end)
    return true
end

function SetPlan(name, plan)
    local t = Platoons()
    if not t or not t[name] then return nil, 'no such platoon' end
    if t[name][2] == plan then return true end
    local entry = Copy(t[name])
    entry[2] = plan or ''
    Edit('platoon plan', function(Set) Set(t, name, entry) end)
    return true
end

local function RowDefault(bp)
    return { bp or '', 0, 1, SquadOf(bp), 'None' }
end

--- Adds a row (unit type) to the platoon; `row` = { bp, min, max, squad, formation } (defaults filled in). Returns the row number.
function AddRow(name, row)
    local t = Platoons()
    if not t or not t[name] then return nil, 'no such platoon' end
    local entry = Copy(t[name])
    local d = RowDefault(row and row[1])
    for i = 1, 5 do if row and row[i] ~= nil then d[i] = row[i] end end
    table.insert(entry, d)
    Edit('add unit to platoon ' .. name, function(Set) Set(t, name, entry) end)
    return table.getn(entry) - 2
end

--- Sets one field of row `i` (1 = the first unit type): key 'bp' | 'min' | 'max' | 'squad' | 'formation'.
local KEYS = { bp = 1, min = 2, max = 3, squad = 4, formation = 5 }
function SetRow(name, i, key, value, merge)
    local t = Platoons()
    if not t or not t[name] or not t[name][i + 2] or not KEYS[key] then return nil, 'no such row' end
    local entry = Copy(t[name])
    local row = entry[i + 2]
    if key == 'min' or key == 'max' then value = math.max(0, math.floor((tonumber(value) or 0) + 0.5)) end
    row[KEYS[key]] = value
    if key == 'min' and row[3] < row[2] then row[3] = row[2] end
    if key == 'max' and row[2] > row[3] then row[2] = row[3] end
    Edit('platoon ' .. name .. ' ' .. key, function(Set) Set(t, name, entry) end, merge and ('row:' .. name .. ':' .. i .. ':' .. key) or nil)
    return true
end

function RemoveRow(name, i)
    local t = Platoons()
    if not t or not t[name] or not t[name][i + 2] then return nil, 'no such row' end
    local entry = Copy(t[name])
    table.remove(entry, i + 2)
    Edit('remove unit from platoon ' .. name, function(Set) Set(t, name, entry) end)
    return true
end

function MoveRow(name, i, delta)
    local t = Platoons()
    local j = i + delta
    if not t or not t[name] or not t[name][i + 2] or not t[name][j + 2] or j < 1 then return nil, 'cannot move' end
    local entry = Copy(t[name])
    entry[i + 2], entry[j + 2] = entry[j + 2], entry[i + 2]
    Edit('move unit in platoon ' .. name, function(Set) Set(t, name, entry) end)
    return true
end

--- The rows of a platoon as a list of { bp, min, max, squad, formation }.
function Rows(name)
    local t = Platoons()
    local list = {}
    if not t or not t[name] then return list end
    for i = 3, table.getn(t[name]) do
        local r = t[name][i]
        table.insert(list, { bp = r[1], min = r[2], max = r[3], squad = r[4], formation = r[5] })
    end
    return list
end

function Plan(name)
    local t = Platoons()
    return t and t[name] and t[name][2] or ''
end

-- ---- order queues -----------------------------------------------------------------------------------------------------------------------------------

function NewOrders(name)
    local t = Orders()
    if not t then return nil, 'no map' end
    if not ValidName(name) then return nil, 'a name takes letters, digits, _ and -' end
    if t[name] then return nil, 'there is already an order queue ' .. name end
    Edit('add order queue ' .. name, function(Set) Set(t, name, {}) end)
    return name
end

function DuplicateOrders(name)
    local t = Orders()
    if not t or not t[name] then return nil, 'no such order queue' end
    local new = Unique(t, name .. '_copy')
    Edit('duplicate order queue ' .. name, function(Set) Set(t, new, Copy(t[name])) end)
    return new
end

--- Adds an order to the end of a queue: order = { type = 'Move' | 'Patrol' | 'Attack' | 'Stop', target = marker, chain = chain }. Returns its number.
function AddOrder(name, order)
    local t = Orders()
    if not t or not t[name] then return nil, 'no such order queue' end
    local list = Copy(t[name])
    local o = { type = 'Move', target = '', chain = '' }
    for k, v in order or {} do o[k] = v end
    table.insert(list, o)
    Edit('add order to ' .. name, function(Set) Set(t, name, list) end)
    return table.getn(list)
end

function SetOrder(name, i, key, value)
    local t = Orders()
    if not t or not t[name] or not t[name][i] then return nil, 'no such order' end
    local list = Copy(t[name])
    list[i][key] = value
    if key == 'chain' and value ~= '' then list[i].target = '' end         -- a target is a marker or a chain, not both
    if key == 'target' and value ~= '' then list[i].chain = '' end
    Edit('order ' .. name .. ' ' .. key, function(Set) Set(t, name, list) end)
    return true
end

function RemoveOrder(name, i)
    local t = Orders()
    if not t or not t[name] or not t[name][i] then return nil, 'no such order' end
    local list = Copy(t[name])
    table.remove(list, i)
    Edit('remove order from ' .. name, function(Set) Set(t, name, list) end)
    return true
end

function MoveOrder(name, i, delta)
    local t = Orders()
    local j = i + delta
    if not t or not t[name] or not t[name][i] or not t[name][j] then return nil, 'cannot move' end
    local list = Copy(t[name])
    list[i], list[j] = list[j], list[i]
    Edit('move order in ' .. name, function(Set) Set(t, name, list) end)
    return true
end

--- The queue as a list of orders (copies).
function Queue(name)
    local t = Orders()
    return (t and t[name]) and Copy(t[name]) or {}
end

-- ---- assigning to the unit tree --------------------------------------------------------------------------------------------------------------------

local function Assign(field, army, node, name)
    local n = FindNode(army, node)
    if not n then return nil, 'no group or unit ' .. tostring(node) .. ' in ' .. tostring(army) end
    if name ~= '' then
        local t = (field == 'platoon') and Platoons() or Orders()
        if not t[name] then return nil, 'no such ' .. ((field == 'platoon') and 'platoon' or 'order queue') .. ' ' .. name end
    end
    Edit('set ' .. field .. ' of ' .. node, function(Set) Set(n, field, name) end)
    return true
end

function AssignPlatoon(army, node, name) return Assign('platoon', army, node, name or '') end
function AssignOrders(army, node, name) return Assign('orders', army, node, name or '') end

--- What a group or unit has assigned: platoon, orders.
function Assigned(army, node)
    local n = FindNode(army, node)
    if not n then return '', '' end
    return n.platoon or '', n.orders or ''
end

-- ---- platoon builders -------------------------------------------------------------------------------------------------------------------------------

local function BuilderTable(army, Set)
    local a = Save() and Save().Armies and Save().Armies[army]
    if not a then return nil end
    if not a.PlatoonBuilders then Set(a, 'PlatoonBuilders', { next_platoon_builder_id = 1, Builders = {} }) end
    if not a.PlatoonBuilders.Builders then Set(a.PlatoonBuilders, 'Builders', {}) end
    return a.PlatoonBuilders.Builders
end

local function DefaultBuilder(template)
    return {
        PlatoonTemplate = template or '',
        Priority = 100,
        InstanceCount = 1,
        LocationType = 'MAIN',
        BuildTimeOut = -1,
        PlatoonType = 'Land',
        RequiresConstruction = true,
        PlatoonAIFunction = { '/lua/ScenarioPlatoonAI.lua', 'PatrolChainPickerThread', {}, {} },
        BuildConditions = {},
        PlatoonData = {},
    }
end
DefaultBuilderData = DefaultBuilder

function NewBuilder(army, name, template)
    if not Save() or not Save().Armies or not Save().Armies[army] then return nil, 'no such army' end
    if not ValidName(name) then return nil, 'a name takes letters, digits, _ and -' end
    if Builders(army) and Builders(army)[name] then return nil, 'there is already a builder ' .. name end
    Edit('add platoon builder ' .. name, function(Set)
        local b = BuilderTable(army, Set)
        Set(b, name, DefaultBuilder(template))
    end)
    return name
end

function DeleteBuilder(army, name)
    local b = Builders(army)
    if not b or not b[name] then return nil, 'no such builder' end
    Edit('delete platoon builder ' .. name, function(Set) Set(b, name, nil) end)
    return true
end

function RenameBuilder(army, old, new)
    local b = Builders(army)
    if not b or not b[old] then return nil, 'no such builder' end
    if old == new then return true end
    if not ValidName(new) then return nil, 'a name takes letters, digits, _ and -' end
    if b[new] then return nil, 'there is already a builder ' .. new end
    Edit('rename platoon builder ' .. old, function(Set)
        local entry = b[old]
        Set(b, old, nil)
        Set(b, new, entry)
    end)
    return true
end

function DuplicateBuilder(army, name)
    local b = Builders(army)
    if not b or not b[name] then return nil, 'no such builder' end
    local new = Unique(b, name .. '_copy')
    Edit('duplicate platoon builder ' .. name, function(Set) Set(b, new, Copy(b[name])) end)
    return new
end

--- Sets a field of a builder (a copy of the entry is replaced, so the change is one undo step): PlatoonTemplate, Priority, InstanceCount, LocationType, BuildTimeOut,
--- PlatoonType, RequiresConstruction; 'AIFile' / 'AIFunction' set the two parts of PlatoonAIFunction.
function SetBuilder(army, name, key, value, merge)
    local b = Builders(army)
    if not b or not b[name] then return nil, 'no such builder' end
    local entry = Copy(b[name])
    if key == 'AIFile' or key == 'AIFunction' then
        entry.PlatoonAIFunction = entry.PlatoonAIFunction or { '', '', {}, {} }
        entry.PlatoonAIFunction[(key == 'AIFile') and 1 or 2] = value
    elseif key == 'Priority' or key == 'InstanceCount' or key == 'BuildTimeOut' then
        entry[key] = math.floor((tonumber(value) or 0) + 0.5)
    else
        entry[key] = value
    end
    Edit('builder ' .. name .. ' ' .. key, function(Set) Set(b, name, entry) end, merge and ('builder:' .. army .. ':' .. name .. ':' .. key) or nil)
    return true
end

--- Build conditions: { file, function, { args }, { args } }; `args` as text ('MAIN, 4') is stored as a list of strings.
local function ArgList(text)
    local list = {}
    for token in string.gfind(text or '', '[^,]+') do
        local t = string.gsub(string.gsub(token, '^%s+', ''), '%s+$', '')
        if t ~= '' then table.insert(list, t) end
    end
    return list
end
ArgsFromText = ArgList

function ArgsToText(list)
    local parts = {}
    for _, a in list or {} do table.insert(parts, tostring(a)) end
    return table.concat(parts, ', ')
end

function AddCondition(army, name, file, fn, args)
    local b = Builders(army)
    if not b or not b[name] then return nil, 'no such builder' end
    local entry = Copy(b[name])
    entry.BuildConditions = entry.BuildConditions or {}
    local list = ArgList(args)
    table.insert(entry.BuildConditions, { file or '/lua/editor/miscbuildconditions.lua', fn or '', Copy(list), Copy(list) })
    Edit('add build condition to ' .. name, function(Set) Set(b, name, entry) end)
    return table.getn(entry.BuildConditions)
end

function SetCondition(army, name, i, key, value)
    local b = Builders(army)
    if not b or not b[name] or not b[name].BuildConditions or not b[name].BuildConditions[i] then return nil, 'no such condition' end
    local entry = Copy(b[name])
    local c = entry.BuildConditions[i]
    if key == 'file' then c[1] = value
    elseif key == 'fn' then c[2] = value
    elseif key == 'args' then
        local list = ArgList(value)
        c[3] = list
        c[4] = Copy(list)
    end
    Edit('build condition of ' .. name, function(Set) Set(b, name, entry) end)
    return true
end

function RemoveCondition(army, name, i)
    local b = Builders(army)
    if not b or not b[name] or not b[name].BuildConditions or not b[name].BuildConditions[i] then return nil, 'no such condition' end
    local entry = Copy(b[name])
    table.remove(entry.BuildConditions, i)
    Edit('remove build condition of ' .. name, function(Set) Set(b, name, entry) end)
    return true
end

-- ---- checks -----------------------------------------------------------------------------------------------------------------------------------------

local function InList(list, v)
    for _, x in list do if x == v then return true end end
    return false
end

local function BlueprintKnown(bp)
    return __blueprints == nil or __blueprints[bp] ~= nil or __blueprints[string.lower(bp or '')] ~= nil
end

--- Problems of the platoon templates, order queues and builders: list of { sev, text, kind, name, army }.
function Problems()
    local list = {}
    local s = Save()
    if not s then return list end
    local function Add(sev, text, kind, name, army) table.insert(list, { sev = sev, text = text, kind = kind, name = name, army = army }) end
    local markers = s.MasterChain and s.MasterChain._MASTERCHAIN_ and s.MasterChain._MASTERCHAIN_.Markers or {}
    for name, p in Platoons() or {} do
        if table.getn(p) < 3 then Add('W', 'platoon ' .. name .. ' has no units', 'platoon', name) end
        for i = 3, table.getn(p) do
            local r = p[i]
            local label = 'platoon ' .. name .. ' row ' .. (i - 2)
            if type(r) ~= 'table' or not r[1] or r[1] == '' then
                Add('E', label .. ' has no unit type', 'platoon', name)
            else
                if not BlueprintKnown(r[1]) then Add('W', label .. ': unknown unit ' .. tostring(r[1]), 'platoon', name) end
                if (tonumber(r[2]) or 0) > (tonumber(r[3]) or 0) then Add('E', label .. ': minimum ' .. tostring(r[2]) .. ' is above the maximum ' .. tostring(r[3]), 'platoon', name) end
                if (tonumber(r[3]) or 0) < 1 then Add('W', label .. ': the maximum is 0, no unit will ever join', 'platoon', name) end
                if not InList(SQUADS, r[4]) then Add('W', label .. ': squad ' .. tostring(r[4]) .. ' is not one of ' .. table.concat(SQUADS, ', '), 'platoon', name) end
                if not InList(FORMATIONS, r[5]) then Add('I', label .. ': formation ' .. tostring(r[5]) .. ' is not a known formation', 'platoon', name) end
            end
        end
    end
    for name, q in Orders() or {} do
        if table.getn(q) == 0 then Add('W', 'order queue ' .. name .. ' has no orders', 'orders', name) end
        for i, o in q do
            local label = 'order queue ' .. name .. ' order ' .. i
            if not InList(ORDER_TYPES, o.type) then Add('E', label .. ': unknown type ' .. tostring(o.type), 'orders', name) end
            if o.type ~= 'Stop' then
                if (o.target or '') == '' and (o.chain or '') == '' then
                    Add('E', label .. ' (' .. tostring(o.type) .. ') has no marker or chain', 'orders', name)
                end
                if (o.target or '') ~= '' and not markers[o.target] then Add('E', label .. ': there is no marker ' .. tostring(o.target), 'orders', name) end
                if (o.chain or '') ~= '' and not (s.Chains and s.Chains[o.chain]) then Add('E', label .. ': there is no chain ' .. tostring(o.chain), 'orders', name) end
            end
        end
    end
    EachNode(function(n, army, nm, isGroup)
        local kind = isGroup and 'group ' or 'unit '
        if (n.platoon or '') ~= '' and not (s.Platoons and s.Platoons[n.platoon]) then Add('E', kind .. nm .. ' of ' .. army .. ' names the missing platoon ' .. n.platoon, 'platoon', n.platoon, army) end
        if (n.orders or '') ~= '' and not (s.Orders and s.Orders[n.orders]) then Add('E', kind .. nm .. ' of ' .. army .. ' names the missing order queue ' .. n.orders, 'orders', n.orders, army) end
    end)
    -- a platoon on a group needs units of the types it lists
    EachNode(function(n, army, nm, isGroup)
        if isGroup and (n.platoon or '') ~= '' and s.Platoons and s.Platoons[n.platoon] then
            local have = {}
            for _, c in GroupCounts(army, nm) do have[c.bp] = c.count end
            local p = s.Platoons[n.platoon]
            for i = 3, table.getn(p) do
                local r = p[i]
                if type(r) == 'table' and r[1] and not have[r[1]] and (tonumber(r[2]) or 0) > 0 then
                    Add('W', 'group ' .. nm .. ' of ' .. army .. ' has no ' .. tostring(r[1]) .. ' (platoon ' .. n.platoon .. ' wants at least ' .. tostring(r[2]) .. ')', 'platoon', n.platoon, army)
                end
            end
        end
    end)
    for _, army in Armies() do
        for name, b in Builders(army) or {} do
            local label = 'builder ' .. name .. ' of ' .. army
            if (b.PlatoonTemplate or '') == '' then Add('E', label .. ' has no platoon template', 'builder', name, army)
            elseif not (s.Platoons and s.Platoons[b.PlatoonTemplate]) and string.sub(name, 1, 4) ~= 'OSB_' then
                Add('E', label .. ' uses the missing platoon ' .. tostring(b.PlatoonTemplate), 'builder', name, army)
            end
            if (tonumber(b.Priority) or 0) < 0 then Add('W', label .. ' has a negative priority', 'builder', name, army) end
            if (tonumber(b.InstanceCount) or 0) < 1 then Add('W', label .. ': instance count below 1, it never forms', 'builder', name, army) end
            if b.PlatoonType and not InList(PLATOON_TYPES, b.PlatoonType) then Add('W', label .. ': platoon type ' .. tostring(b.PlatoonType) .. ' is unknown', 'builder', name, army) end
            local ai = b.PlatoonAIFunction
            if ai and ai[1] and ai[1] ~= '' then
                local ok, info = pcall(DiskGetFileInfo, ai[1])
                if ok and not info then Add('W', label .. ': the AI file ' .. tostring(ai[1]) .. ' does not exist', 'builder', name, army) end
            end
            for i, c in b.BuildConditions or {} do
                if type(c) ~= 'table' or not c[1] or not c[2] or c[2] == '' then Add('E', label .. ': build condition ' .. i .. ' has no function', 'builder', name, army)
                else
                    local ok, info = pcall(DiskGetFileInfo, c[1])
                    if ok and not info then Add('W', label .. ': the file ' .. tostring(c[1]) .. ' of build condition ' .. i .. ' does not exist', 'builder', name, army) end
                end
            end
        end
    end
    return list
end
