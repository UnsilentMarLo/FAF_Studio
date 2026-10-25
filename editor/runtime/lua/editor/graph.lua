-- Terrain graph model (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5): nodes with typed ports, wires, parameters and a seed, as plain data. Evaluation is graphrun.lua, the node
-- catalogue is graphnodes.lua, the canvas is gui/panels_graph.lua. Nothing here touches the terrain or a field.
--
--   data        graph = { name, seed, nodes = { { id, type, x, y, params = { key = value }, label, off }, ... }, wires = { { fromId, 'out', toId, 'a' }, ... }, nextId, view = { x, y, zoom } }
--               a wire runs from an output port of one node to an input port of another; one wire per input port. Port types: height, mask (both are fields and connect freely), points, number.
--   Current     the graph being edited; Sel = { [id] = true }; SelWire = wire index or false
--   Revision / DataRevision     bumped by every change (canvas redraw) / by changes that need a new evaluation (parameters, wires, nodes; not moves and selection)
--
--   New(name) Load(table) Snapshot() NodeById(id) Add(type, x, y, params) Remove(ids) Connect(from, outPort, to, inPort) Disconnect(to, inPort) SetParam(id, key, value) SetSeed(n)
--   Move(ids, dx, dy) Copy(ids) Paste(x, y) Duplicate(ids) Undo() Redo() Order() Validate() Text(graph) FromText(text) Save(name) LoadFile(name) Files() Presets()
--   SidecarText() LoadSidecar(file)     the graph travels with the map (_editor.lua: Graph = { ... })
--
-- Edits are undoable in the graph's own stack (Undo / Redo); slider drags of one parameter merge into one entry. Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Nodes = import('/lua/editor/graphnodes.lua')
local Ser = import('/lua/editor/luaser.lua')

Current = false
Sel = {}
SelWire = false
Revision = 0
DataRevision = 0
Clipboard = false
Message = ''
FileName = ''

local undoStack = {}
local redoStack = {}
local LIMIT = 100

-- ---- small helpers ----------------------------------------------------------------------------------------------------------------------------------

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local c = {}
    for k, x in v do c[k] = Copy(x) end
    return c
end
CopyValue = Copy

local function Changed(data)
    Revision = Revision + 1
    if data then DataRevision = DataRevision + 1 end
end

local function Now()
    if rawget(_G, 'GetSystemTimeSeconds') then return GetSystemTimeSeconds() end
    return 0
end

function Fresh(name)
    return { name = name or 'untitled', seed = 1, nodes = {}, wires = {}, nextId = 1, view = { x = 0, y = 0, zoom = 1 } }
end

function New(name)
    Current = Fresh(name)
    Sel = {}
    SelWire = false
    undoStack, redoStack = {}, {}
    FileName = ''
    Changed(true)
    return Current
end

function NodeById(id)
    if not Current then return nil end
    for _, n in Current.nodes do
        if n.id == id then return n end
    end
    return nil
end

local function Index(id)
    for i, n in Current.nodes do
        if n.id == id then return i end
    end
    return nil
end

-- ---- undo -------------------------------------------------------------------------------------------------------------------------------------------

local function Data()
    return { seed = Current.seed, symmetry = Copy(Current.symmetry), nodes = Copy(Current.nodes), wires = Copy(Current.wires), nextId = Current.nextId }
end

function Snapshot()
    return Data()
end

local function Restore(snap)
    Current.seed = snap.seed
    Current.symmetry = Copy(snap.symmetry)
    Current.nodes = Copy(snap.nodes)
    Current.wires = Copy(snap.wires)
    Current.nextId = snap.nextId
    local keep = {}
    for id, _ in Sel do
        if NodeById(id) then keep[id] = true end
    end
    Sel = keep
    SelWire = false
    Changed(true)
end

--- Records the edit that turned `before` into the current state. `key` merges the edits of one slider drag (within 1.5 s) into one entry.
local function Record(label, before, key)
    local now = Now()
    local top = undoStack[table.getn(undoStack)]
    redoStack = {}
    if key and top and top.key == key and now - top.time < 1.5 then
        top.after = Data()
        top.time = now
        return
    end
    table.insert(undoStack, { label = label, before = before, after = Data(), key = key, time = now })
    if table.getn(undoStack) > LIMIT then table.remove(undoStack, 1) end
end

function Edit(label, fn, key, data)
    local before = Data()
    local r = fn()
    Record(label, before, key)
    Changed(data ~= false)
    return r
end

--- For drags: Begin() at the press, End(label, before) at the release (one undo entry for the whole drag).
function Begin() return Data() end

function End(label, before, key, data)
    Record(label, before, key)
    Changed(data ~= false)
end

--- Replaces the nodes, wires and seed by those of `plain` (a preset or a file) as one undoable edit.
function Replace(plain, label)
    local g = Normalize(plain)
    Edit(label or 'load graph', function()
        Current.seed = g.seed
        Current.symmetry = g.symmetry
        Current.nodes = g.nodes
        Current.wires = g.wires
        Current.nextId = g.nextId
        Current.name = g.name
        Current.view = g.view
        Sel = {}
        SelWire = false
    end)
end

function Undo()
    local entry = table.remove(undoStack)
    if not entry then return false end
    table.insert(redoStack, entry)
    Restore(entry.before)
    return entry.label
end

function Redo()
    local entry = table.remove(redoStack)
    if not entry then return false end
    table.insert(undoStack, entry)
    Restore(entry.after)
    return entry.label
end

function UndoDepth()
    return table.getn(undoStack), table.getn(redoStack)
end

-- ---- nodes ------------------------------------------------------------------------------------------------------------------------------------------

--- A node of `type` at canvas position (x, y) with the default parameters (and `params` over them).
function Add(type, x, y, params)
    local def = Nodes.Defs[type]
    if not def then return nil, 'unknown node type ' .. tostring(type) end
    return Edit('add ' .. def.label, function()
        local node = { id = Current.nextId, type = type, x = x or 0, y = y or 0, params = Nodes.DefaultParams(type) }
        Current.nextId = Current.nextId + 1
        if params then for k, v in params do node.params[k] = Copy(v) end end
        table.insert(Current.nodes, node)
        return node
    end)
end

--- Removes nodes (a set { [id] = true } or a list of ids) and the wires that touch them.
function Remove(ids)
    local set = {}
    for k, v in ids do
        if type(k) == 'number' and v == true then set[k] = true else set[v] = true end
    end
    Edit('delete nodes', function()
        for i = table.getn(Current.nodes), 1, -1 do
            if set[Current.nodes[i].id] then table.remove(Current.nodes, i) end
        end
        for i = table.getn(Current.wires), 1, -1 do
            local w = Current.wires[i]
            if set[w[1]] or set[w[3]] then table.remove(Current.wires, i) end
        end
        for id, _ in set do Sel[id] = nil end
        SelWire = false
    end)
end

function SetLabel(id, text)
    local n = NodeById(id)
    if not n then return end
    Edit('rename node', function() n.label = (text ~= '' and text) or nil end, 'label' .. id, false)
end

function SetOff(id, off)
    local n = NodeById(id)
    if not n then return end
    Edit(off and 'bypass node' or 'enable node', function() n.off = off and true or nil end)
end

--- Sets a parameter. `key` merges a slider drag. Wires into a number port of the same name stay (the wire wins during evaluation).
function SetParam(id, key, value, merge)
    local n = NodeById(id)
    if not n then return end
    Edit('set ' .. key, function() n.params[key] = Copy(value) end, merge and ('param' .. id .. key) or nil)
end

--- Sets several parameters as one edit (a preset of a node).
function SetParams(id, values, label)
    local n = NodeById(id)
    if not n then return end
    Edit(label or 'set parameters', function()
        for k, v in values do n.params[k] = Copy(v) end
    end)
end

--- The symmetry of what the graph writes (gensym.lua): nil / 'map' follows the editor's symmetry, 'off', a symmetrize mode, or { mode = 'rotn', n }.
function SetSymmetry(setting)
    Edit('symmetry', function() Current.symmetry = Copy(setting) end)
end

function SetSeed(seed)
    Edit('seed', function() Current.seed = math.mod(math.floor(seed), 10000) end, 'seed')
end

function Move(ids, dx, dy, merge)
    Edit('move', function()
        for id, _ in ids do
            local n = NodeById(id)
            if n then n.x, n.y = n.x + dx, n.y + dy end
        end
    end, merge and 'move' or nil, false)
end

--- Sets absolute positions { [id] = {x, y} } as one edit (the end of a drag).
function Place(positions)
    Edit('move', function()
        for id, p in positions do
            local n = NodeById(id)
            if n then n.x, n.y = p[1], p[2] end
        end
    end, nil, false)
end

-- ---- wires ------------------------------------------------------------------------------------------------------------------------------------------

local function Compatible(tf, tt)
    if tf == tt then return true end
    return (tf == 'height' or tf == 'mask') and (tt == 'height' or tt == 'mask')
end

--- Is `target` reachable from `start` along the wires (used to refuse cycles)?
local function Reaches(start, target)
    local seen = {}
    local stack = { start }
    while table.getn(stack) > 0 do
        local id = table.remove(stack)
        if id == target then return true end
        if not seen[id] then
            seen[id] = true
            for _, w in Current.wires do
                if w[1] == id then table.insert(stack, w[3]) end
            end
        end
    end
    return false
end

--- Can the output port of `from` feed the input port of `to`? Returns true, or false and the reason.
function CanConnect(fromId, outPort, toId, inPort)
    local a, b = NodeById(fromId), NodeById(toId)
    if not a or not b then return false, 'no such node' end
    if fromId == toId then return false, 'a node cannot feed itself' end
    local po = Nodes.OutputPort(a.type, outPort)
    local pi = Nodes.InputPort(b.type, inPort)
    if not po then return false, 'no output ' .. tostring(outPort) end
    if not pi then return false, 'no input ' .. tostring(inPort) end
    if not Compatible(po.type, pi.type) then return false, po.type .. ' does not fit a ' .. pi.type .. ' input' end
    if Reaches(toId, fromId) then return false, 'that wire would make a loop' end
    return true
end

--- Wires an output to an input; an input takes one wire, a new one replaces the old.
function Connect(fromId, outPort, toId, inPort)
    local ok, msg = CanConnect(fromId, outPort, toId, inPort)
    if not ok then
        Message = msg
        return false, msg
    end
    Edit('connect', function()
        for i = table.getn(Current.wires), 1, -1 do
            local w = Current.wires[i]
            if w[3] == toId and w[4] == inPort then table.remove(Current.wires, i) end
        end
        table.insert(Current.wires, { fromId, outPort, toId, inPort })
        SelWire = false
    end)
    Message = ''
    return true
end

function Disconnect(toId, inPort)
    local found = false
    for _, w in Current.wires do
        if w[3] == toId and w[4] == inPort then found = true end
    end
    if not found then return false end
    Edit('disconnect', function()
        for i = table.getn(Current.wires), 1, -1 do
            local w = Current.wires[i]
            if w[3] == toId and w[4] == inPort then table.remove(Current.wires, i) end
        end
        SelWire = false
    end)
    return true
end

function RemoveWire(index)
    local w = Current.wires[index]
    if not w then return end
    Disconnect(w[3], w[4])
end

--- The wire into an input port, with its index.
function WireInto(toId, inPort)
    for i, w in Current.wires do
        if w[3] == toId and w[4] == inPort then return w, i end
    end
    return nil
end

-- ---- selection, clipboard ---------------------------------------------------------------------------------------------------------------------------

function Select(ids, add)
    if not add then Sel = {} end
    for _, id in ids do Sel[id] = true end
    SelWire = false
    Changed(false)
end

function SelectOne(id, add)
    if not add then Sel = {} end
    if id then
        if add and Sel[id] then Sel[id] = nil else Sel[id] = true end
    end
    SelWire = false
    Changed(false)
end

function ClearSelection()
    Sel = {}
    SelWire = false
    Changed(false)
end

function SelectedList()
    local list = {}
    for _, n in Current.nodes do
        if Sel[n.id] then table.insert(list, n.id) end
    end
    return list
end

--- Copies the nodes of `ids` (a list or a set) and the wires between them.
function CopyNodes(ids)
    local set = {}
    for k, v in ids do
        if v == true then set[k] = true else set[v] = true end
    end
    local nodes, wires = {}, {}
    for _, n in Current.nodes do
        if set[n.id] then table.insert(nodes, Copy(n)) end
    end
    for _, w in Current.wires do
        if set[w[1]] and set[w[3]] then table.insert(wires, Copy(w)) end
    end
    if table.getn(nodes) == 0 then return false end
    Clipboard = { nodes = nodes, wires = wires }
    return true
end

--- Pastes the clipboard with its first node's top left corner at (x, y). Returns the new ids.
function Paste(x, y)
    if not Clipboard then return {} end
    local x0, y0 = 1e9, 1e9
    for _, n in Clipboard.nodes do
        if n.x < x0 then x0 = n.x end
        if n.y < y0 then y0 = n.y end
    end
    local map = {}
    local made = {}
    Edit('paste nodes', function()
        Sel = {}
        for _, n in Clipboard.nodes do
            local c = Copy(n)
            c.id = Current.nextId
            Current.nextId = Current.nextId + 1
            c.x, c.y = x + (n.x - x0), y + (n.y - y0)
            map[n.id] = c.id
            table.insert(Current.nodes, c)
            table.insert(made, c.id)
            Sel[c.id] = true
        end
        for _, w in Clipboard.wires do
            table.insert(Current.wires, { map[w[1]], w[2], map[w[3]], w[4] })
        end
        SelWire = false
    end)
    return made
end

function Duplicate(ids)
    if not CopyNodes(ids) then return {} end
    local x0, y0 = 1e9, 1e9
    for _, n in Clipboard.nodes do
        if n.x < x0 then x0 = n.x end
        if n.y < y0 then y0 = n.y end
    end
    return Paste(x0 + 40, y0 + 40)
end

-- ---- order and checks -------------------------------------------------------------------------------------------------------------------------------

--- Node ids in evaluation order (inputs before the nodes that use them; ties by node order). A cycle leaves its nodes out.
function Order()
    local indeg, down = {}, {}
    for _, n in Current.nodes do
        indeg[n.id] = 0
        down[n.id] = {}
    end
    for _, w in Current.wires do
        if indeg[w[3]] and indeg[w[1]] then
            indeg[w[3]] = indeg[w[3]] + 1
            table.insert(down[w[1]], w[3])
        end
    end
    local out = {}
    local ready = {}
    for _, n in Current.nodes do
        if indeg[n.id] == 0 then table.insert(ready, n.id) end
    end
    local at = 1
    while at <= table.getn(ready) do
        local id = ready[at]
        at = at + 1
        table.insert(out, id)
        for _, to in down[id] do
            indeg[to] = indeg[to] - 1
            if indeg[to] == 0 then table.insert(ready, to) end
        end
    end
    return out
end

--- Problems of the graph as a list of { id, text }: required inputs without a wire, wires into ports that do not exist (a file from another version), loops.
function Validate()
    local list = {}
    for _, n in Current.nodes do
        local def = Nodes.Defs[n.type]
        if not def then
            table.insert(list, { id = n.id, text = 'unknown node type ' .. tostring(n.type) })
        else
            for _, p in Nodes.Inputs(n.type) do
                if not p.opt and not WireInto(n.id, p.name) then
                    table.insert(list, { id = n.id, text = def.label .. ': input ' .. p.name .. ' is not connected' })
                end
            end
        end
    end
    if table.getn(Order()) < table.getn(Current.nodes) then
        table.insert(list, { id = false, text = 'the graph has a loop' })
    end
    return list
end

--- Nodes whose results nothing uses and that are no outputs (greyed in the canvas).
function Downstream(id)
    local seen, stack, out = {}, { id }, {}
    while table.getn(stack) > 0 do
        local cur = table.remove(stack)
        for _, w in Current.wires do
            if w[1] == cur and not seen[w[3]] then
                seen[w[3]] = true
                table.insert(out, w[3])
                table.insert(stack, w[3])
            end
        end
    end
    return out
end

-- ---- files ------------------------------------------------------------------------------------------------------------------------------------------

--- The graph as plain data for a file (view included).
function Plain(graph)
    graph = graph or Current
    local nodes = {}
    for _, n in graph.nodes do
        local c = { id = n.id, type = n.type, x = math.floor(n.x + 0.5), y = math.floor(n.y + 0.5), params = Copy(n.params) }
        if n.label then c.label = n.label end
        if n.off then c.off = true end
        table.insert(nodes, c)
    end
    local wires = {}
    for _, w in graph.wires do table.insert(wires, { w[1], w[2], w[3], w[4] }) end
    local view = graph.view or { x = 0, y = 0, zoom = 1 }
    return { version = 1, name = graph.name, seed = graph.seed, symmetry = Copy(graph.symmetry), nodes = nodes, wires = wires, nextId = graph.nextId, view = { x = view.x, y = view.y, zoom = view.zoom } }
end

function Text(graph)
    return 'return ' .. Ser.Dump(Plain(graph), 0) .. '\n'
end

--- A graph from plain data (a file, a preset): missing parameters take their defaults, unknown parameters stay, wires to missing nodes are dropped.
function Normalize(data)
    local g = Fresh(data.name)
    g.seed = data.seed or 1
    g.symmetry = Copy(data.symmetry)
    local maxId = 0
    for _, n in (data.nodes or {}) do
        local c = { id = n.id, type = n.type, x = n.x or 0, y = n.y or 0, params = Copy(n.params or {}), label = n.label, off = n.off }
        if Nodes.Defs[c.type] then
            for k, v in Nodes.DefaultParams(c.type) do
                if c.params[k] == nil then c.params[k] = v end
            end
        end
        if c.id > maxId then maxId = c.id end
        table.insert(g.nodes, c)
    end
    local have = {}
    for _, n in g.nodes do have[n.id] = true end
    for _, w in (data.wires or {}) do
        if have[w[1]] and have[w[3]] then table.insert(g.wires, { w[1], w[2], w[3], w[4] }) end
    end
    g.nextId = math.max(data.nextId or 1, maxId + 1)
    local v = data.view or {}
    g.view = { x = v.x or 0, y = v.y or 0, zoom = v.zoom or 1 }
    return g
end

--- Makes `data` the current graph (clears the undo stack).
function Load(data)
    Current = Normalize(data)
    Sel = {}
    SelWire = false
    undoStack, redoStack = {}, {}
    Changed(true)
    return Current
end

function FromText(text)
    local chunk, err = loadstring(text, '=graph')
    if not chunk then return nil, tostring(err) end
    local env = {}
    setfenv(chunk, env)
    local ok, data = pcall(chunk)
    if not ok then return nil, tostring(data) end
    if type(data) ~= 'table' then return nil, 'not a graph file' end
    return data
end

local function SafeName(name)
    name = string.gsub(name or '', '[^%w_%- ]', '')
    if name == '' then name = 'graph' end
    return name
end

--- Saves the current graph as graphs/<name>.lua next to the engine's working directory.
function Save(name)
    name = SafeName(name or Current.name)
    Current.name = name
    FileName = name
    local ok = ed_write_file('graphs/' .. name .. '.lua', Text())
    return ok and true or false
end

function LoadFile(name)
    local text = ed_read_file('graphs/' .. name .. '.lua')
    if not text then return false, 'no file graphs/' .. name .. '.lua' end
    local data, err = FromText(text)
    if not data then return false, err end
    Replace(data, 'open ' .. name)
    FileName = name
    return true
end

local mounted = false

--- Names of the saved graphs (the folder graphs/ is mounted as /usergraphs to list it: the VFS cannot see the working directory otherwise).
function Files()
    local names = {}
    if not mounted and rawget(_G, 'ed_vfs_mount') then
        pcall(ed_vfs_mount, 'graphs', '/usergraphs')
        mounted = true
    end
    local files = DiskFindFiles('/usergraphs', '*.lua') or {}
    for _, path in files do
        local base = string.gsub(path, '^.*[/\]', '')
        base = string.gsub(base, '%.lua$', '')
        table.insert(names, base)
    end
    table.sort(names)
    return names
end

--- The sample graphs shipped with the editor: { { id, name } } (files in lua/editor/graphpresets/).
function Presets()
    local list = {}
    local ok, index = pcall(import, '/lua/editor/graphpresets/index.lua')
    if ok and index then
        for _, p in index.List do table.insert(list, { id = p.id, name = p.name, note = p.note, library = p.library }) end
    end
    return list
end

-- The shipped graphs name their texture layers by number (layer 2 = rock, 3 = sand ... of the standard layout of texsets.lua). A preset is loaded with those outputs turned into Output: ground kind
-- nodes, so it textures the right kinds of ground whatever the map's shader and layer order are (TTerrain's four layers, the seven layer shaders, the biplanar ones).
local STANDARD_KINDS = { 'grass', 'rock', 'sand', 'dirt', 'wet', 'highrock', 'darkrock', 'snow' }

local function KindsForLayers(g)
    for _, n in g.nodes or {} do
        if n.type == 'out_layer' then
            local p = n.params or {}
            local role = (p.texture and p.texture ~= 'keep') and p.texture or STANDARD_KINDS[math.floor((p.layer or 2) + 0.5)]
            if role then
                n.type = 'out_role'
                p.role, p.layer, p.texture = role, nil, nil
                n.params = p
            end
        end
    end
end

function LoadPreset(id)
    local env = {}
    local ok, err = pcall(doscript, '/lua/editor/graphpresets/' .. id .. '.lua', env)
    if not ok then return false, tostring(err) end
    if type(env.Graph) ~= 'table' then return false, 'preset ' .. id .. ' has no Graph' end
    KindsForLayers(env.Graph)
    Replace(env.Graph, 'load ' .. id)
    Current.name = env.Graph.name or id
    FileName = ''
    return true
end

-- ---- the map's sidecar ------------------------------------------------------------------------------------------------------------------------------

function SidecarText()
    if not Current or table.getn(Current.nodes) == 0 then return '' end
    return Ser.Chunk({ { 'Graph', Plain() } })
end

function LoadSidecar(scenarioFile)
    pcall(function() import('/lua/editor/graphrun.lua').Forget() end)
    New('untitled')
    local path = scenarioFile and import('/lua/editor/mods.lua').SidecarPath(scenarioFile)
    if path and DiskGetFileInfo(path) then
        local env = {}
        doscript(path, env)
        if type(env.Graph) == 'table' then
            Load(env.Graph)
        end
    end
    Changed(true)
end

function Reset()
    pcall(function() import('/lua/editor/graphrun.lua').Forget() end)
    New('untitled')
end

New('untitled')
