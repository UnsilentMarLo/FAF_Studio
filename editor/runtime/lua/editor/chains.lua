-- Chains: the save file's `Chains` table, { Name = { Markers = { 'marker name', ... } } }. Patrol and move orders of a mission (platoon patrol nodes, OpAI attack chains, base engineer / scout
-- chains) and the scenario scripts (`ScenarioUtils.ChainToPositions`) read them. Until now nothing in the editor could make one.
--
--   Names() / Markers(name)                          sorted chain names / a copy of the marker list
--   Create(name, markers) / Delete(name) / Rename(old, new)      with undo; Rename also follows the mission's references (platoon patrol / group patrol nodes, OpAI chains) in the same undo step
--   AddMarker(name, marker, at) / RemoveMarker(name, index) / MoveMarker(name, index, delta)       with undo
--   FromSelection(name)                              a chain from the selected markers in the order they were selected
--   SelectMarkers(name)                              selects the chain's markers in the world
--   Problems()                                       list of { names, x, z, text }: a chain with fewer than two markers, markers that no longer exist, a marker twice in a row
--   Length(name)                                     world length of the chain's line
--   Draw(ui) / Forget()                              the lines in the world (overlay.lua calls Draw every frame)
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')
local Tools = import('/lua/editor/tools.lua')

Current = false        -- the chain the panel shows (highlighted in the world)
Show = true            -- draw the chains
Revision = 0           -- bumped by every change (the panel and the overlay follow it)

local function ChainTable()
    return Map.Doc and Map.Doc.save.Chains
end

local function MarkerTable()
    return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
end

local function Bump()
    Revision = Revision + 1
end

local function CopyList(list)
    local c = {}
    for i, v in list or {} do c[i] = v end
    return c
end

function Names()
    local list = {}
    for name, _ in ChainTable() or {} do table.insert(list, name) end
    table.sort(list)
    return list
end

function Markers(name)
    local c = ChainTable() and ChainTable()[name]
    return c and CopyList(c.Markers) or nil
end

local function ValidName(name)
    return type(name) == 'string' and name ~= '' and not string.find(name, '[^%w_ %-]')
end

local function Push(label, undo, redo)
    History.Push({ label = label, undo = function() undo() Bump() end, redo = function() redo() Bump() end })
    Bump()
end

--- A new chain of the given markers (only names of existing markers are kept). Returns true or nil and a reason.
function Create(name, markers)
    local chains = ChainTable()
    if not chains then return nil, 'no map' end
    if Tools.ReadOnly then return nil, 'read only' end
    if not ValidName(name) then return nil, 'a chain name takes letters, digits, _ and spaces' end
    if chains[name] then return nil, 'there is already a chain ' .. name end
    local list = {}
    for _, m in markers or {} do
        if MarkerTable()[m] then table.insert(list, m) end
    end
    chains[name] = { Markers = list }
    Current = name
    Push('add chain ' .. name, function() chains[name] = nil if Current == name then Current = false end end, function() chains[name] = { Markers = CopyList(list) } Current = name end)
    return true
end

function Delete(name)
    local chains = ChainTable()
    if not chains or not chains[name] then return nil, 'no such chain' end
    if Tools.ReadOnly then return nil, 'read only' end
    local saved = CopyList(chains[name].Markers)
    chains[name] = nil
    if Current == name then Current = false end
    Push('delete chain ' .. name, function() chains[name] = { Markers = CopyList(saved) } end, function() chains[name] = nil if Current == name then Current = false end end)
    return true
end

--- Changes the chain name in the mission's nodes and attacks; returns how many references changed.
local function ReplaceRefs(old, new)
    local M = import('/lua/editor/mission.lua')
    local count = 0
    local function Visit(list)
        for _, node in list or {} do
            if node.chain == old then node.chain = new count = count + 1 end
            Visit(node.children)
        end
    end
    local ok = M.Edit('rename chain references', function()
        for _, stage in M.Data.stages do
            Visit(stage.enter)
            Visit(stage.ready)
        end
        for _, b in M.Data.bases or {} do
            for _, o in b.opai or {} do
                for i, c in o.chains or {} do
                    if c == old then o.chains[i] = new count = count + 1 end
                end
            end
        end
        if count == 0 then return false end
    end)
    return ok and count or 0
end

function Rename(old, new)
    local chains = ChainTable()
    if not chains or not chains[old] then return nil, 'no such chain' end
    if Tools.ReadOnly then return nil, 'read only' end
    if old == new then return true end
    if not ValidName(new) then return nil, 'a chain name takes letters, digits, _ and spaces' end
    if chains[new] then return nil, 'there is already a chain ' .. new end
    local c = chains[old]
    chains[old] = nil
    chains[new] = c
    if Current == old then Current = new end
    Push('rename chain ' .. old, function() chains[new] = nil chains[old] = c if Current == new then Current = old end end,
         function() chains[old] = nil chains[new] = c if Current == old then Current = new end end)
    local refs = ReplaceRefs(old, new)
    if refs > 0 then History.Merge(2, 'rename chain ' .. old .. ' to ' .. new) end
    return true, refs
end

--- Inserts a marker at position `at` (the end by default). Returns true or nil and a reason.
function AddMarker(name, marker, at)
    local chains = ChainTable()
    local c = chains and chains[name]
    if not c then return nil, 'no such chain' end
    if Tools.ReadOnly then return nil, 'read only' end
    if not MarkerTable()[marker] then return nil, 'no such marker' end
    local before = CopyList(c.Markers)
    local index = at or (table.getn(c.Markers) + 1)
    if index < 1 or index > table.getn(c.Markers) + 1 then index = table.getn(c.Markers) + 1 end
    table.insert(c.Markers, index, marker)
    local after = CopyList(c.Markers)
    Push('add ' .. marker .. ' to ' .. name, function() c.Markers = CopyList(before) end, function() c.Markers = CopyList(after) end)
    return true
end

function RemoveMarker(name, index)
    local chains = ChainTable()
    local c = chains and chains[name]
    if not c or not c.Markers[index] then return nil, 'no such marker in the chain' end
    if Tools.ReadOnly then return nil, 'read only' end
    local before = CopyList(c.Markers)
    table.remove(c.Markers, index)
    local after = CopyList(c.Markers)
    Push('remove ' .. tostring(before[index]) .. ' from ' .. name, function() c.Markers = CopyList(before) end, function() c.Markers = CopyList(after) end)
    return true
end

function MoveMarker(name, index, delta)
    local chains = ChainTable()
    local c = chains and chains[name]
    local to = index + delta
    if not c or not c.Markers[index] or to < 1 or to > table.getn(c.Markers) then return nil, 'out of range' end
    if Tools.ReadOnly then return nil, 'read only' end
    local before = CopyList(c.Markers)
    local m = table.remove(c.Markers, index)
    table.insert(c.Markers, to, m)
    local after = CopyList(c.Markers)
    Push('move ' .. m .. ' in ' .. name, function() c.Markers = CopyList(before) end, function() c.Markers = CopyList(after) end)
    return true
end

--- A chain of the selected markers, in selection order. Returns true or nil and a reason.
function FromSelection(name)
    local list = {}
    for _, it in Tools.Items do
        if it.kind == 'marker' then table.insert(list, it.name) end
    end
    if table.getn(list) == 0 then return nil, 'select markers first' end
    return Create(name, list)
end

function SelectMarkers(name)
    local list = Markers(name)
    if not list then return false end
    Tools.Select(false)
    for _, m in list do
        if MarkerTable()[m] then Tools.Select('marker', m, 'add') end
    end
    return true
end

function Length(name)
    local list = Markers(name)
    if not list then return 0 end
    local total, prev = 0, nil
    for _, m in list do
        local mk = MarkerTable()[m]
        if mk then
            if prev then
                local dx, dz = mk.position[1] - prev.position[1], mk.position[3] - prev.position[3]
                total = total + math.sqrt(dx * dx + dz * dz)
            end
            prev = mk
        end
    end
    return total
end

--- Problems of the chains: { names = markers involved, x, z, text }.
function Problems()
    local out = {}
    local markers = MarkerTable and Map.Doc and MarkerTable() or {}
    for _, name in Names() do
        local list = ChainTable()[name].Markers or {}
        local x, z = 0, 0
        local first = markers[list[1] or '']
        if first then x, z = first.position[1], first.position[3] end
        if table.getn(list) < 2 then
            table.insert(out, { names = {}, x = x, z = z, text = 'chain ' .. name .. ' has ' .. table.getn(list) .. ' marker(s): a patrol needs at least 2' })
        end
        local last
        for i, m in list do
            if not markers[m] then
                table.insert(out, { names = {}, x = x, z = z, text = 'chain ' .. name .. ' lists the marker ' .. tostring(m) .. ' that does not exist' })
            elseif m == last then
                table.insert(out, { names = { m }, x = markers[m].position[1], z = markers[m].position[3], text = 'chain ' .. name .. ' lists ' .. m .. ' twice in a row' })
            end
            last = m
        end
    end
    return out
end

-- ---- the lines in the world ---------------------------------------------------------------------------------------------------------------------------

local drawn = {}
local drawKey = ''

function Forget()
    drawn = {}
    drawKey = ''
end

local function Remove(keep)
    for id, _ in drawn do
        if not keep[id] then ed_overlay_remove(id) drawn[id] = nil end
    end
end

function Draw(ui)
    if rawget(_G, 'ed_overlay_set') == nil or not Map.Doc then return end
    local chains = ChainTable() or {}
    if not Show or next(chains) == nil then
        if next(drawn) ~= nil then Remove({}) drawKey = '' end
        return
    end
    local mode = ui and ui.State and ui.State.mode
    if mode == 'play' then
        if next(drawn) ~= nil then Remove({}) drawKey = '' end
        return
    end
    local key = tostring(Revision) .. '|' .. tostring(Current) .. '|' .. tostring(Tools.Changed)
    if key == drawKey then return end
    drawKey = key
    local keep = {}
    local markers = MarkerTable()
    for name, c in chains do
        local pts = {}
        for _, m in c.Markers or {} do
            local mk = markers[m]
            if mk then
                local x, z = mk.position[1], mk.position[3]
                table.insert(pts, x)
                table.insert(pts, (ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or mk.position[2]) + 0.6)
                table.insert(pts, z)
            end
        end
        if table.getn(pts) >= 6 then
            local id = 'chain:' .. name
            local isCur = (name == Current)
            ed_overlay_set(id, pts, isCur and 'FFFFA020' or '90E08030', isCur and 0.3 or 0.18, 2, 4, false, true)
            keep[id] = true
            drawn[id] = true
        end
    end
    Remove(keep)
end
