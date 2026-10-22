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
--   Draw(ui) / Forget()                              the lines in the world (overlay.lua calls Draw every frame); a marker of a layer that is switched off in the View panel
--                                                    (markerfilter.lua) breaks the line; with OnlySelected only the chain of the selected marker (else the chain chosen in the panel) is drawn
--   SetOnlySelected(on)                              the View panel's "Only the selected chain"
--   DrawPress(wx, wz, event) / DrawTail() / Finish() the Draw chain tool: every click places a Blank Marker and appends it to the current chain (a new chain when there is none,
--                                                    Ctrl+click starts a new one); with symmetry on the images get chains of their own (<chain>_mx ...). One undo step per click.
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')
local Tools = import('/lua/editor/tools.lua')

Current = false        -- the chain the panel shows (highlighted in the world)
Show = true            -- draw the chains
OnlySelected = false   -- draw only the chain of the selected marker (else the current chain): the View panel's "Only the selected chain"
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

-- ---- drawing a chain with the Draw chain tool ---------------------------------------------------------------------------------------------------------

--- Sets the marker list of a chain by name (nil deletes it). An existing chain keeps its table (and a chain this tool made is put back as the same table `tbl`), so the entries
--- of the panel's own edits that captured the table stay valid through undo and redo.
local function SetChain(name, list, tbl)
    local chains = ChainTable()
    if not chains then return end
    if list then
        if chains[name] then
            chains[name].Markers = CopyList(list)
        else
            chains[name] = tbl or {}
            chains[name].Markers = CopyList(list)
        end
    else
        chains[name] = nil
        if Current == name then Current = false end
    end
end

--- The suffix of a symmetry image's chain: mx, mz, dg, da, rot90 ...
local function ImageSuffix(p)
    if p.kind == 'rot' then return 'rot' .. math.floor(math.abs(p.angle) * 57.29578 + 0.5) .. (p.angle < 0 and 'n' or '') end
    return p.kind
end

--- The end of the chain being drawn (x, z), for the rubber line of the tool's preview; nil when there is no current chain.
function DrawTail()
    if not Map.Doc or not Current then return nil end
    local chains = ChainTable()
    local c = chains and chains[Current]
    local last = c and c.Markers and c.Markers[table.getn(c.Markers)]
    local mk = last and MarkerTable()[last]
    if not mk then return nil end
    return mk.position[1], mk.position[3]
end

--- The next click of the Draw chain tool starts a new chain.
function Finish()
    if Current then
        Current = false
        Bump()
    end
end

--- The Draw chain tool's click: a Blank Marker at (wx, wz) joins the end of the current chain (a new chain "Chain_<n>" when none is chosen in the Chains panel; Ctrl+click
--- starts a new one). With symmetry on, the images get markers too and, in a chain of their own (<chain>_mx, <chain>_rot90 ...), their markers in the same order. The markers
--- are named <chain>_<n>. Everything of one click is one undo step. Always returns true (the click is taken).
function DrawPress(wx, wz, event)
    if not Map.Doc then Map.Load() end
    if not Map.Doc or Tools.ReadOnly then return true end
    local chains = ChainTable()
    local markers = MarkerTable()
    if not chains then return true end
    if event and event.Modifiers and event.Modifiers.Ctrl then Current = false end
    if Current and not chains[Current] then Current = false end
    local main = Current
    if not main then
        local n = 1
        repeat main = 'Chain_' .. n n = n + 1 until not chains[main]
    end

    local points = import('/lua/editor/symmetry.lua').Points(wx, wz)
    local changes, placed, first = {}, 0, nil
    for i, p in points do
        local cname = (i == 1) and main or (main .. '_' .. ImageSuffix(p))
        local existing = chains[cname]
        local list = existing and CopyList(existing.Markers) or {}
        local before = existing and CopyList(existing.Markers) or nil
        local tbl = existing or {}
        local base = string.gsub(cname, ' ', '_')
        local n = table.getn(list) + 1
        local name
        repeat name = base .. '_' .. n n = n + 1 until not markers[name]
        local made = Tools.PlaceMarker(p.x, p.z, 'Blank Marker', name)
        if made then
            placed = placed + 1
            first = first or made
            table.insert(list, made)
            table.insert(changes, { name = cname, before = before, after = list, tbl = tbl })
        end
    end
    if placed == 0 then return true end

    for _, ch in changes do SetChain(ch.name, ch.after, ch.tbl) end
    Current = main
    Tools.Select('marker', first)
    local label = 'draw ' .. main
    History.Push({
        label = label,
        undo = function()
            for i = table.getn(changes), 1, -1 do SetChain(changes[i].name, changes[i].before) end
            Bump()
        end,
        redo = function()
            for _, ch in changes do SetChain(ch.name, ch.after, ch.tbl) end
            Current = main
            Bump()
        end,
    })
    History.Merge(placed + 1, label)          -- the markers and their chains: one undo step per click
    Bump()
    local text = 'chain ' .. main .. ': ' .. table.getn(chains[main].Markers) .. ' markers (click for the next, Ctrl+click starts a new chain)'
    local ok, Filter = pcall(import, '/lua/editor/markerfilter.lua')
    if ok and Filter.IsHidden('Blank Marker') then text = text .. '. The Other markers layer is hidden in the View panel: its markers and chains are not drawn' end
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    return true
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

--- Switches the View panel's "Only the selected chain" (the overlay redraws at once).
function SetOnlySelected(on)
    OnlySelected = on and true or false
    Bump()
end

--- Hidden View layers as a string, part of the key the drawn lines are valid for.
local function HiddenKey(Filter)
    local key = ''
    for _, cat in Filter.CATEGORIES do
        if Filter.Hidden[cat] then key = key .. cat .. ',' end
    end
    return key
end

--- The names of the chains to draw when OnlySelected is on: the chains that contain a selected marker, else the chain chosen in the panel (nil = every chain).
local function FocusChains(chains)
    if not OnlySelected then return nil end
    local selected = {}
    for _, it in Tools.Items do
        if it.kind == 'marker' then selected[it.name] = true end
    end
    local focus, any = {}, false
    for cname, c in chains do
        for _, m in c.Markers or {} do
            if selected[m] then
                focus[cname] = true
                any = true
                break
            end
        end
    end
    if not any and Current and chains[Current] then focus[Current] = true end
    return focus
end

local followStamp = false

--- When the selection changes to markers that belong to chains, the chain the panel shows (and the world highlights) becomes the chain of the selected marker: kept when the
--- current chain already holds one of the selected markers, else the first chain (by name) that does. Only on a change of the selection: choosing a chain in the panel stays.
local function FollowSelection(chains)
    if followStamp == Tools.Changed then return end
    followStamp = Tools.Changed
    local selected, any = {}, false
    for _, it in Tools.Items do
        if it.kind == 'marker' then
            selected[it.name] = true
            any = true
        end
    end
    if not any then return end
    local cur = Current and chains[Current]
    if cur then
        for _, m in cur.Markers or {} do
            if selected[m] then return end
        end
    end
    for _, cname in Names() do
        for _, m in chains[cname].Markers or {} do
            if selected[m] then
                Current = cname
                Bump()
                return
            end
        end
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
    FollowSelection(chains)
    local Filter = import('/lua/editor/markerfilter.lua')
    local key = tostring(Revision) .. '|' .. tostring(Current) .. '|' .. tostring(Tools.Changed) .. '|' .. tostring(OnlySelected) .. '|' .. HiddenKey(Filter)
    if key == drawKey then return end
    drawKey = key
    local keep = {}
    local markers = MarkerTable()
    local focus = FocusChains(chains)
    for name, c in chains do
        if focus == nil or focus[name] then
            -- the line runs through the chain's markers in order; a marker of a hidden View layer breaks it (its segments are not drawn), so a hidden layer shows no chain of its markers
            local runs, pts = {}, {}
            local members = {}
            for _, m in c.Markers or {} do
                local mk = markers[m]
                if mk then
                    if Filter.IsHidden(mk.type) then
                        if table.getn(pts) >= 6 then table.insert(runs, pts) end
                        pts = {}
                    else
                        local x, z = mk.position[1], mk.position[3]
                        local y = (ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or mk.position[2]) + 0.6
                        table.insert(pts, x)
                        table.insert(pts, y)
                        table.insert(pts, z)
                        table.insert(members, { x, y, z })
                    end
                end
            end
            if table.getn(pts) >= 6 then table.insert(runs, pts) end
            local isCur = (name == Current)
            for r, run in runs do
                local id = (r == 1) and ('chain:' .. name) or ('chain:' .. name .. ':' .. r)
                ed_overlay_set(id, run, isCur and 'FFFFA020' or '90E08030', isCur and 0.3 or 0.18, 2, 4, false, true)
                keep[id] = true
                drawn[id] = true
            end
            -- only the selected chain: its members get a ring, so they can be told from the other markers
            if focus ~= nil and table.getn(runs) > 0 then
                for i, mm in members do
                    local ring = {}
                    for k = 0, 11 do
                        local a = k / 12 * 6.2831853
                        table.insert(ring, mm[1] + math.cos(a) * 1.8)
                        table.insert(ring, mm[2])
                        table.insert(ring, mm[3] + math.sin(a) * 1.8)
                    end
                    local id = 'chainm:' .. name .. ':' .. i
                    ed_overlay_set(id, ring, 'FFFFA020', 0.12, 2, 3, true, true)
                    keep[id] = true
                    drawn[id] = true
                end
            end
        end
    end
    Remove(keep)
end
