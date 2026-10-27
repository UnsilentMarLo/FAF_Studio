-- Evaluation of the terrain graph (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5): runs the nodes of graph.lua on the native field engine, caches every node by a key made of its
-- parameters and the versions of its inputs (so a changed slider re-runs only the nodes downstream of it), makes the thumbnails, shows the result on the real terrain and builds it.
--
--   NewRun{ step, thumbs, seed, only }        an evaluation: step = 1 full resolution, 4 = every fourth sample (the preview); thumbs = make node pictures; seed = graph seed override;
--                                             only = set of node ids to evaluate (default all). run:Evaluate() -> report, run:Entry(id), run:Value(id, port), run:Free()
--   Main                                      the live run of the canvas (preview resolution, thumbnails); Refresh() re-evaluates when the graph or the map changed
--   PreviewStep()                             the step of the preview run for this map (grid at most PreviewCap = 513 samples a side; SetPreviewCap(257|513|1025))
--   FinalHeight(run, base)                    the field the height outputs make (nil when there is none)
--   ShowOnTerrain() / RevertTerrain() / TerrainShown()       the preview result on the real terrain, taken off again by Revert (a native undo step that is not in the history)
--   Build()                                   full resolution run; heights, layers, terrain types and props as ONE undo step -> summary table, or nil, message
--   ShowMask(id, port) / HideMask()           a node's field as red squares on the map (the Mask generator's overlay)
--   Gallery(first, count, size)               small pictures of the result for `count` seeds from `first`
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local TerrainEpoch = import('/lua/editor/terrainepoch.lua')
local World = import('/lua/editor/world.lua')
local GenSym = import('/lua/editor/gensym.lua')

-- ---- the map's ground before the graph (the "Map heights" node reads this) -----------------------------------------------------------------------------

-- A graph that reads the terrain and writes it back must not read its own result the second time: the heights are kept as they were when the graph first looked at them, and are taken
-- again only when the terrain is neither that nor the result of the graph (the user edited it).
Base = { field = false, sum = false, shownSum = false, builtSum = false, owner = false }

local function Clock()
    if rawget(_G, 'ed_field_clock') then return ed_field_clock() end
    return 0
end

local function Size()
    local w, h = ed_terrain_info()
    return w, h
end

--- The untouched heights at full resolution (a field owned here), checking whether the terrain was edited since. The check is always against a fresh read of the document's heights (Fields.Height
--- + Checksum), never against a revision or a history version, so whoever wrote the ground (brush, generator, tool, import, undo) is seen the next time this runs; when it runs is decided by
--- Refresh (terrainepoch.lua Stamp).
function EnsureBase()
    local f = Fields.Height(1)
    local sum = Fields.Checksum(f)
    -- the ground a graph made (its Build, its preview) counts as "ours" only for THAT graph: a second Build of the same graph starts from the same ground, but another graph (a new one,
    -- a preset loaded, the texture pass after the terrain graph) must see the ground as it is now, or its "Map heights" node kept showing the ground from before the first graph
    local ours = Base.owner == Graph.Current
    if Base.field and (sum == Base.sum or (ours and (sum == Base.shownSum or sum == Base.builtSum))) then
        Fields.Free(f)
        return Base.field
    end
    if Base.field then Fields.Free(Base.field) end
    Base.field, Base.sum, Base.shownSum, Base.builtSum, Base.owner = f, sum, false, false, Graph.Current
    return f
end

function ForgetBase()
    if Base.field then Fields.Free(Base.field) end
    Base.field, Base.sum, Base.shownSum, Base.builtSum, Base.owner = false, false, false, false, false
end

local function WaterLevel()
    local ok, v = pcall(function() return World.Get().water_elev end)
    return (ok and v) or 25
end

--- An error message as the user should read it: no "stack traceback:" (the engine appends one to a message raised under pcall) and no "file(line): " / "file:line: " prefixes.
local function Strip(msg)
    return Fields.CleanError(msg)
end

--- The preview grid is at most PreviewCap samples a side (the toolbar's Detail button cycles PreviewCaps). 257 was too coarse for texture masks; 513 is the default.
PreviewCaps = { 257, 513, 1025 }
PreviewCap = 513

--- The step of the preview: the smallest that keeps the grid within PreviewCap samples a side (1025 map: 2 at 513).
function PreviewStep()
    local w, h = Size()
    if not w then return 1 end
    local span = math.max(w, h) - 1
    local step = 1
    while math.floor(span / step) + 1 > PreviewCap do step = step + 1 end
    for s = step, step + 3 do
        if math.mod(w - 1, s) == 0 and math.mod(h - 1, s) == 0 then return s end
    end
    return step
end

--- The thumbnail size follows the detail: 128 px a side, 192 at the finest.
function ThumbSize()
    return PreviewCap > 513 and 192 or 128
end

-- ---- a run ------------------------------------------------------------------------------------------------------------------------------------------

local function ParamKey(value)
    local t = type(value)
    if t == 'number' then return string.format('%.7g', value) end
    if t == 'table' then
        local keys = {}
        for k, _ in value do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in keys do table.insert(parts, tostring(k) .. '=' .. ParamKey(value[k])) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return tostring(value)
end

local Run = {}
Run.__index = Run

function NewRun(opts)
    opts = opts or {}
    local r = setmetatable({}, Run)
    r.step = opts.step or PreviewStep()
    r.thumbs = opts.thumbs and true or false
    r.seed = opts.seed
    r.only = opts.only
    r.cache = {}
    r.refs = {}
    r.protected = {}
    r.ver = 0
    r.like = false
    r.likeKey = ''
    r.baseCoarse = false
    r.baseCoarseSum = false
    r.report = false
    return r
end

local function IsFieldType(t) return t == 'height' or t == 'mask' end
local GraphColor = import('/lua/editor/graphcolor.lua')      -- stage T7: the `color` port type is { r, g, b, a } fields
local BuildRun = false                                       -- the cache of Build (see below)
local buildWater = false
local DropBuild

--- Gives back a reference to a field; frees it with the last reference.
function Run:Release(h)
    if self.protected[h] then return end
    local n = (self.refs[h] or 1) - 1
    if n <= 0 then
        self.refs[h] = nil
        Fields.Free(h)
    else
        self.refs[h] = n
    end
end

local function OutType(nodeType, port)
    local p = Nodes.OutputPort(nodeType, port)
    return p and p.type
end

function Run:FreeEntry(entry)
    if not entry or not entry.outs then return end
    for port, val in entry.outs do
        local t = OutType(entry.nodeType, port)
        if IsFieldType(t) then
            self:Release(val)
        elseif t == 'color' then
            for _, k in GraphColor.CHANNELS do self:Release(val[k]) end
        end
    end
    entry.outs = nil
end

function Run:Free()
    for id, entry in self.cache do self:FreeEntry(entry) end
    self.cache = {}
    if self.like then
        self.protected[self.like] = nil
        Fields.Free(self.like)
        self.like = false
    end
    if self.baseCoarse then
        self.protected[self.baseCoarse] = nil
        Fields.Free(self.baseCoarse)
        self.baseCoarse = false
    end
end

--- The reference grid of this resolution (every generator takes its size and placement from it).
function Run:EnsureLike()
    local w, h = Size()
    if not w then error('no terrain') end
    local key = w .. 'x' .. h .. '@' .. self.step .. 'w' .. string.format('%.3f', WaterLevel())
    if self.like and key == self.likeKey then return end
    for id, entry in self.cache do self:FreeEntry(entry) end
    self.cache = {}
    if self.like then
        self.protected[self.like] = nil
        Fields.Free(self.like)
    end
    if self.baseCoarse then
        self.protected[self.baseCoarse] = nil
        Fields.Free(self.baseCoarse)
        self.baseCoarse = false
    end
    self.like = Fields.Height(self.step)
    self.likeKey = key
    self.protected[self.like] = true
end

function Run:BaseHere()
    local full = EnsureBase()
    if self.step == 1 then return full end
    if self.baseCoarse and self.baseCoarseSum == Base.sum then return self.baseCoarse end
    if self.baseCoarse then
        self.protected[self.baseCoarse] = nil
        Fields.Free(self.baseCoarse)
    end
    self.baseCoarse = Fields.Op('resample', { a = full, like = self.like })
    self.baseCoarseSum = Base.sum
    self.protected[self.baseCoarse] = true
    return self.baseCoarse
end

-- the environment a node's eval works in
local function NewEnv(run, node, wanted, graph)
    local E = { run = run, node = node, tmp = {}, like = run.like, step = run.step, wanted = wanted, graph = graph, Fields = Fields }
    local w, h, cell = Fields.Info(run.like)
    local mw, mh = Size()
    E.cell = cell
    E.W, E.H = mw - 1, mh - 1
    E.water = WaterLevel()
    function E:Add(f)
        self.tmp[f] = true
        return f
    end
    function E:Op(name, p)
        return self:Add(Fields.Op(name, p))
    end
    function E:Const(value)
        return self:Add(Fields.Op('const', { like = self.like, value = value }))
    end
    function E:Seed(n)
        local s = (run.seed or graph.seed) * 1009 + node.id * 101 + math.floor(n)
        return math.mod(s, 1000003)
    end
    function E:Units(units)
        return math.max(1, math.floor(units / self.cell + 0.5))
    end
    --- A field of the run's grid brought onto the grid this node works on (finer after an Oversample node: see Run:Conform).
    function E:Fit(f)
        local w = Fields.Info(f)
        local tw = Fields.Info(self.like)
        if w and tw and w ~= tw then return self:Op('upsample', { a = f, like = self.like }) end
        return f
    end
    function E:Base()
        return self:Fit(self:Add(Fields.Op('affine', { a = run:BaseHere(), mul = 1, add = 0 })))      -- a copy: the entry must not alias the shared base
    end
    function E:Stratum(layer)
        return self:Fit(self:Add(Fields.Stratum(layer)))
    end
    return E
end

local function WiredOutputs(graph)
    local wired = {}
    for _, n in graph.nodes do wired[n.id] = {} end
    for _, w in graph.wires do
        if wired[w[1]] then wired[w[1]][w[2]] = true end
    end
    return wired
end

local function Needs(graph, ids)
    local need = {}
    local stack = {}
    for id, _ in ids do table.insert(stack, id) end
    while table.getn(stack) > 0 do
        local id = table.remove(stack)
        if not need[id] then
            need[id] = true
            for _, w in graph.wires do
                if w[3] == id then table.insert(stack, w[1]) end
            end
        end
    end
    return need
end

--- The nodes upstream of the output nodes (what a build has to evaluate), as a set.
function OutputNeeds(graph)
    local outs = {}
    for _, n in graph.nodes do
        local d = Nodes.Defs[n.type]
        if d and d.output then outs[n.id] = true end
    end
    return Needs(graph, outs), outs
end

local function PickThumbField(entry, def)
    for _, o in def.outputs do
        local v = entry.outs[o.name]
        if v ~= nil and (IsFieldType(o.type) or o.type == 'color') then return v, o end
    end
    return nil
end

--- Evaluates the graph. Nodes whose key did not change keep their result. Returns a report { evaluated, cached, errors = { [id] = text }, ms }.
function Run:Evaluate()
    local graph = Graph.Current
    local t0 = Clock()
    self:EnsureLike()
    local report = { evaluated = 0, cached = 0, errors = {}, ms = 0, order = {} }
    local wired = WiredOutputs(graph)
    local order = Graph.Order()
    local live = tostring(History.Version)
    local needBase = false
    for _, n in graph.nodes do
        if n.type == 'terrain' then needBase = true end
    end
    local baseKey = ''
    if needBase then
        EnsureBase()
        baseKey = tostring(Base.sum)
    end
    local seen = {}
    for _, id in order do
        seen[id] = true
        if not self.only or self.only[id] then
            self:EvaluateNode(graph, Graph.NodeById(id), wired[id] or {}, report, live, baseKey)
        end
    end
    -- nodes that no longer exist (or were left out by a loop) give their memory back
    local present = {}
    for _, n in graph.nodes do present[n.id] = true end
    for id, entry in self.cache do
        if not present[id] or not seen[id] then
            self:FreeEntry(entry)
            self.cache[id] = nil
        end
    end
    report.ms = (Clock() - t0) * 1000
    self.report = report
    return report
end

--- A node works on one grid: the run's, or the finest one among its inputs (an Oversample node made it). The other inputs are brought onto it (smooth upsampling, a tent filter downwards), E.like / E.cell /
--- E.step follow it, so a node placed after an Oversample node simply runs at the higher resolution (an erosion node scales its settings by E.step). The nodes that write into the map's own grids (the
--- outputs of the heights, the paint and the terrain types) get their inputs on the run's grid again, averaged, which is what makes the oversampled masks crisp; only the map-wide textures (def.fineOk)
--- keep the fine grid. Changes `ins`; the converted fields belong to E.
function Run:Conform(node, def, ins, E)
    local baseW, _, baseCell = Fields.Info(self.like)
    local finest, finestW = nil, baseW
    local used = {}
    for _, p in Nodes.Inputs(node.type) do
        local val = ins[p.name]
        if val ~= nil then
            if (p.type == 'height' or p.type == 'mask') and type(val) == 'number' then
                local w = Fields.Info(val)
                if w and w > finestW then finest, finestW = val, w end
                table.insert(used, p)
            elseif p.type == 'color' and type(val) == 'table' then
                for _, k in GraphColor.CHANNELS do
                    local w = Fields.Info(val[k])
                    if w and w > finestW then finest, finestW = val[k], w end
                end
                table.insert(used, p)
            end
        end
    end
    if not finest then return end
    local target = finest
    if def.output and not def.fineOk then target = self.like end
    local tw, _, tcell = Fields.Info(target)
    local function Fit(val, linear)
        local w = Fields.Info(val)
        if w == tw then return val end
        if w < tw then return E:Op('upsample', { a = val, like = target, linear = linear and 1 or 0 }) end
        return E:Op('downsample', { a = val, like = target })
    end
    for _, p in used do
        local val = ins[p.name]
        if p.type == 'color' then
            local c = {}
            for _, k in GraphColor.CHANNELS do c[k] = Fit(val[k], true) end
            ins[p.name] = c
        else
            ins[p.name] = Fit(val, p.type == 'mask')
        end
    end
    if target ~= self.like then
        E.like = target
        E.cell = tcell
        E.step = self.step * (baseW - 1) / (tw - 1)
    end
end

function Run:EvaluateNode(graph, node, wanted, report, live, baseKey)
    local def = Nodes.Defs[node.type]
    local id = node.id
    local entry = self.cache[id]
    if not def then
        self:SetError(node, 'unknown node type ' .. tostring(node.type), report)
        return
    end
    -- inputs and parameters
    local ins, insKey = {}, {}
    local blocked, blockedUp = nil, false
    for _, p in Nodes.Inputs(node.type) do
        local wire = Graph.WireInto(id, p.name)
        if wire then
            local up = self.cache[wire[1]]
            if up and up.outs and up.outs[wire[2]] ~= nil then
                ins[p.name] = up.outs[wire[2]]
                table.insert(insKey, p.name .. '=' .. up.ver .. ':' .. wire[2])
            elseif not self.only or self.only[wire[1]] then
                blocked = 'input ' .. p.name .. ' has no value' .. ((up and up.err) and (' (' .. up.err .. ')') or '')
                blockedUp = true
            end
        elseif not p.opt then
            blocked = 'input ' .. p.name .. ' is not connected'
        end
    end
    if blocked then
        self:SetError(node, blocked, report, blockedUp)
        return
    end
    local v = {}
    for _, p in def.params do
        local val = node.params[p.key]
        if val == nil then val = p.default end
        if p.kind == 'number' and p.wire and type(ins[p.key]) == 'number' then val = ins[p.key] end
        v[p.key] = val
    end
    local seeded = false
    for _, p in def.params do
        if p.seed then seeded = true end
    end
    local key = node.type .. '|' .. (node.off and 'off' or 'on') .. '|' .. ParamKey(v) .. '|' .. table.concat(insKey, ';') .. '|' .. self.likeKey
    if seeded then key = key .. '|seed' .. (self.seed or graph.seed) end
    for k, _ in wanted do key = key .. '|w' .. k end
    if def.live == 'doc' then key = key .. '|doc' .. live end
    if def.liveKey then key = key .. '|lk' .. def.liveKey() end
    if node.type == 'terrain' then key = key .. '|base' .. baseKey end
    if node.type == 'path_drawn' then key = key .. '|paths' .. tostring(import('/lua/editor/paths.lua').DataRevision) end
    if entry and entry.key == key and entry.outs then
        report.cached = report.cached + 1
        table.insert(report.order, id)
        return
    end
    -- run it
    if entry then self:FreeEntry(entry) end
    local E = NewEnv(self, node, wanted, graph)
    local okConform, errConform = pcall(self.Conform, self, node, def, ins, E)
    if not okConform then
        for h, _ in E.tmp do Fields.Free(h) end
        self:SetError(node, Strip(errConform), report)
        return
    end
    local t0 = Clock()
    local ok, res
    if node.off then
        local first = def.outputs[1]
        local pass = ins.a
        if pass == nil and first and IsFieldType(first.type) then pass = E:Const(0) end
        ok, res = true, {}
        if first and pass ~= nil then res[first.name] = pass end
    else
        ok, res = pcall(def.eval, E, v, ins)
    end
    local ms = (Clock() - t0) * 1000
    if not ok then
        for h, _ in E.tmp do Fields.Free(h) end
        self:SetError(node, Strip(res), report)
        return
    end
    -- the outputs become owned by the entry; the other temporaries go
    local outs = {}
    for _, o in def.outputs do
        local val = res[o.name]
        if val ~= nil then
            outs[o.name] = val
            if IsFieldType(o.type) then
                if E.tmp[val] then
                    E.tmp[val] = nil
                    self.refs[val] = (self.refs[val] or 0) + 1
                else
                    self.refs[val] = (self.refs[val] or 1) + 1
                end
            elseif o.type == 'color' then
                for _, k in GraphColor.CHANNELS do
                    local h = val[k]
                    if E.tmp[h] then
                        E.tmp[h] = nil
                        self.refs[h] = (self.refs[h] or 0) + 1
                    else
                        self.refs[h] = (self.refs[h] or 1) + 1
                    end
                end
            end
        end
    end
    for h, _ in E.tmp do Fields.Free(h) end
    self.ver = self.ver + 1
    entry = { key = key, ver = self.ver, outs = outs, nodeType = node.type, ms = ms }
    self.cache[id] = entry
    report.evaluated = report.evaluated + 1
    table.insert(report.order, id)
    if self.thumbs then self:MakeThumb(entry, def) end
end

function Run:SetError(node, msg, report, upstream)
    local entry = self.cache[node.id]
    if entry then self:FreeEntry(entry) end
    self.cache[node.id] = { err = msg, upstream = upstream, nodeType = node.type, ver = -1 }
    if not upstream then report.errors[node.id] = msg end
end

local RAMP = { height = 'terrain', mask = 'grey' }

function Run:MakeThumb(entry, def)
    local f, o = PickThumbField(entry, def)
    if f == nil then return end
    if o.type == 'color' then
        entry.thumb = GraphColor.Thumb(f, ThumbSize())
        entry.lo, entry.hi = 0, 1
        entry.thumbPort = o.name
        return
    end
    local path, lo, hi = Fields.Preview(f, ThumbSize(), { ramp = RAMP[o.type] or 'grey' })
    entry.thumb = path
    entry.lo, entry.hi = lo, hi
    entry.thumbPort = o.name
end

function Run:Entry(id) return self.cache[id] end

function Run:Value(id, port)
    local e = self.cache[id]
    return e and e.outs and e.outs[port]
end

-- ---- the result fields of the outputs ----------------------------------------------------------------------------------------------------------------------

local function OutputNodes(graph, kind)
    local list = {}
    for _, id in Graph.Order() do
        local n = Graph.NodeById(id)
        local d = Nodes.Defs[n.type]
        if d and d.output == kind and not n.off then table.insert(list, n) end
    end
    return list
end

local function V(run, node, key)
    local def = Nodes.Defs[node.type]
    local val = node.params[key]
    if val == nil then
        for _, p in def.params do
            if p.key == key then val = p.default end
        end
    end
    local wire = Graph.WireInto(node.id, key)
    if wire then
        local up = run.cache[wire[1]]
        if up and up.outs and type(up.outs[wire[2]]) == 'number' then val = up.outs[wire[2]] end
    end
    return val
end

--- The height the height outputs make, built in `S` (a Fields scope): the base heights with every output node folded in, in node order. Returns the field and whether it differs from a
--- plain replace (then a coarse preview has to be applied as a difference, not as the new ground).
function FinalHeight(run, S, base)
    local graph = Graph.Current
    local cur = base
    local plain = true
    local any = false
    local spec = GenSym.Spec(graph.symmetry)          -- what the graph writes is symmetric (gensym.lua): the nodes after a Symmetrize node (erosion, noise) break it again
    for _, node in OutputNodes(graph, 'height') do
        local entry = run.cache[node.id]
        if entry and entry.outs and entry.outs.view then
            local field = GenSym.Field(S, entry.outs.view, spec, { seam = 12 })
            local mode = V(run, node, 'mode')
            local strength = V(run, node, 'strength')
            local maskWire = Graph.WireInto(node.id, 'mask')
            local mask = maskWire and run:Value(maskWire[1], maskWire[2]) or nil
            if mask then mask = GenSym.Field(S, mask, spec, { seam = 12 }) end
            any = true
            if mode == 'replace' and strength >= 0.9999 and not mask then
                cur = field
            else
                plain = false
                if mode == 'add' then
                    field = S:Op('affine', { a = field, mul = V(run, node, 'gain'), add = 0 })
                    cur = S:Op('blend', { a = cur, b = field, mode = 'add', opacity = strength, mask = mask })
                else
                    cur = S:Op('blend', { a = cur, b = field, mode = 'normal', opacity = strength, mask = mask })
                end
            end
        end
    end
    if not any then return nil end
    return cur, plain
end

-- ---- the live run -----------------------------------------------------------------------------------------------------------------------------------

Main = false
local mainRevision = -1
local mainDoc = -1
local mainExt = ''            -- interop.lua GraphSignature() when the live run last looked (the External nodes read files)
local mainHeights = ''        -- TerrainEpoch.Stamp() when the live run last looked at the map heights (or when this module itself last wrote them)
Report = false

--- True when a "Map heights" node is in the graph (the only node whose result follows the map heights).
local function ReadsTerrain()
    for _, n in Graph.Current.nodes do
        if n.type == 'terrain' then return true end
    end
    return false
end

--- True while a brush stroke is being dragged: every dab moves the document's revision, and the graph catches up when the stroke ends (that pushes a history entry).
local function Stroking()
    local ok, v = pcall(function() return import('/lua/editor/ui.lua').State.strokeDepth ~= nil end)
    return ok and v
end

function GetMain()
    if not Main then
        Main = NewRun{ step = PreviewStep(), thumbs = true }
        mainRevision = -1
    end
    return Main
end

--- Re-evaluates the live run when the graph (or the document) changed since. Returns the report when it ran.
function Refresh(force)
    if not Fields.IsAvailable() or not Size() then return nil end
    local run = GetMain()
    local doc = History.Version
    -- The map heights count as changed when the document's revision moved (terrainepoch.lua Stamp: every height write of any kind), not only when a history entry was pushed: a write that
    -- records no entry (a generator commit that merged into an open stroke or hit the stack limit, a tool, an import, undo of a preview) left the "Map heights" node on the old ground.
    -- A graph without that node does not care; a stroke being dragged waits for its end.
    local heights = TerrainEpoch.Stamp()
    -- the External terrain / External mask nodes read files: when the other tool wrote a new one (and stopped writing) or the import settings changed, evaluate again
    local okExt, ext = pcall(function() return import('/lua/editor/interop.lua').GraphSignature() end)
    if okExt and ext ~= mainExt then
        mainExt = ext
        mainRevision = -1
    end
    if not force and mainRevision == Graph.DataRevision and mainDoc == doc then
        if mainHeights == heights or not ReadsTerrain() or Stroking() then return nil end
    end
    mainRevision = Graph.DataRevision
    mainDoc = doc
    mainHeights = heights
    local ok, report = pcall(run.Evaluate, run)
    if not ok then
        Report = { evaluated = 0, cached = 0, errors = {}, ms = 0, fatal = Strip(report) }
        return Report
    end
    Report = report
    return report
end

function Invalidate()
    mainRevision = -1
end

--- Sets the preview detail (samples a side) and makes the live run start again at it. Returns the cap in use.
function SetPreviewCap(cap)
    cap = math.floor(cap)
    if cap == PreviewCap then return PreviewCap end
    PreviewCap = cap
    if Main then
        Main:Free()
        Main = false
    end
    mainRevision = -1
    return PreviewCap
end

function Release()
    RevertTerrain()
    HideMask()
    if BuildRun then DropBuild(BuildRun) end
    if Main then
        Main:Free()
        Main = false
    end
    ForgetBase()
    mainRevision = -1
end

-- ---- the preview on the real terrain ------------------------------------------------------------------------------------------------------------------

local shown = false      -- { depth }

function TerrainShown() return shown and true or false end

function RevertTerrain()
    if not shown then return false end
    local info = shown
    shown = false
    Base.shownSum = false        -- the preview is off the ground (or part of it now): a terrain that looks like it again is no longer "ours"
    if Terrain.UndoDepth() == info.depth then
        Terrain.Undo()
        mainHeights = TerrainEpoch.Stamp()       -- our own write: the live run does not read the ground again for it
        return true
    end
    return false
end

--- Writes the live result into the map as a native undo step that is not in the history. Returns the number of samples changed, or nil and a message.
function ShowOnTerrain()
    if not Fields.IsAvailable() or not Size() then return nil, 'no terrain' end
    RevertTerrain()
    Refresh(true)
    local run = GetMain()
    local base = EnsureBase()
    local mw, mh = Size()
    return Fields.Run(function(S)
        local baseHere = run:BaseHere()
        local cur, plain = FinalHeight(run, S, baseHere)
        if not cur then return nil, 'the graph has no height output' end
        local full
        if run.step == 1 then
            full = cur
        elseif plain then
            full = S:Op('resize', { a = cur, width = mw, height = mh })
        else
            local diff = S:Op('sub', { a = cur, b = baseHere })
            full = S:Op('add', { a = base, b = S:Op('resize', { a = diff, width = mw, height = mh }) })
        end
        if History.DropRedo then History.DropRedo() end
        local changed = Fields.CommitHeight(full, { label = 'Graph preview', noHistory = true })
        if changed and changed > 0 then
            shown = { depth = Terrain.UndoDepth() }
            local now = Fields.Height(1)
            Base.shownSum = Fields.Checksum(now)
            Base.owner = Graph.Current
            Fields.Free(now)
        end
        mainHeights = TerrainEpoch.Stamp()       -- our own write (the preview): not a reason to evaluate again, or the preview would be written again and again
        return changed or 0
    end)
end

-- a terrain edit on top of the preview turns it into an ordinary history entry placed before that edit; an undo / redo request with a preview showing only takes the preview off
History.AddBefore(function(entry)
    if shown and Terrain.UndoDepth() ~= shown.depth then
        shown = false
        History.PushQuiet({ kind = 'terrain', label = 'graph preview' })
    end
end)
History.AddPreUndo(function()
    if shown then
        RevertTerrain()
        return true
    end
    return false
end)

-- ---- mask overlay -----------------------------------------------------------------------------------------------------------------------------------

local masked = false

function MaskShown() return masked end

--- Shows a node output (a mask, or a height scaled to 0..1) as red squares on the ground around the camera.
function ShowMask(id, port)
    local run = GetMain()
    local e = run:Entry(id)
    local f = e and e.outs and run:Value(id, port or 'out')
    if not f then
        for _, o in (Nodes.Defs[Graph.NodeById(id).type].outputs) do
            if not f and e and e.outs and IsFieldType(o.type) then f = e.outs[o.name] end
        end
    end
    if not f then return false, 'this node has no field to show' end
    local MaskGen = import('/lua/editor/maskgen.lua')
    local copy
    local mn, mx = Fields.Stats(f)
    if mn >= -0.0001 and mx <= 1.0001 then
        copy = Fields.Op('affine', { a = f, mul = 1, add = 0 })
    else
        copy = Fields.Op('normalize', { a = f, lo = 0, hi = 1 })
    end
    MaskGen.SetPreview(copy)
    MaskGen.Preview.show = true
    masked = { id = id, port = port }
    return true
end

function HideMask()
    if masked then
        pcall(function() import('/lua/editor/maskgen.lua').ClearPreview() end)
        masked = false
    end
end

-- ---- build ------------------------------------------------------------------------------------------------------------------------------------------

local function Summary(run, label, ms)
    local list = {}
    for _, id in run.report.order do
        local e = run.cache[id]
        if e and e.ms then table.insert(list, { id = id, ms = e.ms }) end
    end
    table.sort(list, function(a, b) return a.ms > b.ms end)
    return list
end

-- ---- the full resolution cache of Build (stage T7) ---------------------------------------------------------------------------------------------------------
-- A Build keeps its private run (every node's full resolution result, keyed like the preview's) while it fits the memory budget, so the next Build after a change near the end of the graph
-- re-evaluates only that node and what is downstream. The key of a node holds its parameters and the versions of its inputs; the run is dropped when the water level or the map's own heights
-- changed (the `terrain` node's key sees those too), when the budget is exceeded, and by Release().

KeepBuildCache = true                   -- false: every Build starts from nothing
BuildCacheSamples = 160000000           -- budget: samples held by cached fields (4 bytes each: 640 MB)
local function RunSamples(run)
    local total = 0
    for h, _ in run.refs do
        local w, hh = Fields.Info(h)
        if w then total = total + w * hh end
    end
    return total
end

DropBuild = function(run)
    if run then run:Free() end
    if run == BuildRun then BuildRun = false end
end

local function TakeBuildRun(need)
    if BuildRun and (not KeepBuildCache or buildWater ~= WaterLevel()) then DropBuild(BuildRun) end
    local run = BuildRun
    if run then
        run.only = need
        return run
    end
    return NewRun{ step = 1, thumbs = false, only = need }
end

local function KeepBuildRun(run)
    if KeepBuildCache and RunSamples(run) <= BuildCacheSamples then
        BuildRun = run
        buildWater = WaterLevel()
    else
        DropBuild(run)
    end
end

--- What the Build cache holds: samples, megabytes and the number of nodes.
function BuildCacheInfo()
    if not BuildRun then return 0, 0, 0 end
    local samples, nodes = RunSamples(BuildRun), 0
    for _, _ in BuildRun.cache do nodes = nodes + 1 end
    return samples, samples * 4 / 1048576, nodes
end

function DropBuildCache() DropBuild(BuildRun) end

--- The painted layer an Output: ground kind node writes to: the layer that holds a texture of that kind in the map (recipes.lua Plan: found from the textures, not from layer numbers), else the layer the
--- map's shader gives that kind (texsets.lua Layout). Returns layer, nil, whether the layer still needs a texture; or nil and why not (the kind is the base layer, the shader has no layer for it).
function RoleLayer(role)
    local Recipes = import('/lua/editor/recipes.lua')
    local plan = Recipes.Plan()
    local cap = Recipes.Cap()
    local list = plan.byRole[role]
    if list then
        for _, l in list do
            if l >= 1 and l <= cap then return l, nil, false end
        end
        return nil, 'the base layer holds this kind of ground (it has no mask)'
    end
    local l = import('/lua/editor/texsets.lua').RoleLayer(role)
    if l and l <= cap then return l, nil, true end
    return nil, 'the shader ' .. tostring(rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or '?') .. ' has no layer for this kind of ground'
end

--- The layer an output node of the kind 'layer' writes to (a fixed layer, or the one of a kind of ground), nil and why when it has none. needsTexture: the layer is empty and gets the kind's texture.
function NodeLayer(run, node)
    local def = Nodes.Defs[node.type]
    if def.role then
        local l, why, needs = RoleLayer(V(run, node, 'role'))
        return l, why, needs
    end
    return math.floor(V(run, node, 'layer') + 0.5)
end

--- The map-wide textures that are MADE FROM THE PAINT (macrotexture, specular, roughness / height atlas) and the roughness mask of layer 8: written after the layers, so they see what this build painted.
local GENERATED = { { 'mapmacro', 'macro' }, { 'mapspecular', 'specular' }, { 'mapatlas', 'atlas' } }
function BuildPaintTextures(run, graph, result)
    local MT = import('/lua/editor/maptextures.lua')
    local notes = {}
    for _, g in GENERATED do
        for _, node in OutputNodes(graph, g[1]) do
            local kind = g[2]
            local un = MT.Unsupported(kind)
            if un then
                result.warnings = result.warnings or {}
                table.insert(result.warnings, { text = un.text, code = 'shader', kind = kind, node = node.id })
            else
                local o = {}
                for _, p in Nodes.Defs[node.type].params do o[p.key] = V(run, node, p.key) end
                if kind == 'atlas' then import('/lua/editor/alphagen.lua').ApplyStyle(o) end
                local entry, err = MT.Generate(kind, o)
                if not entry then return MT.Kinds[kind].label .. ': ' .. tostring(err) end
                result.maptextures = (result.maptextures or 0) + 1
                if kind == 'atlas' then
                    local note, why = import('/lua/editor/alphagen.lua').SetSplat(o.splatSoft, o.splatContrast)
                    if why then
                        result.warnings = result.warnings or {}
                        table.insert(result.warnings, { text = 'Splat settings not applied: ' .. why, code = 'shader', kind = kind, node = node.id })
                    end
                end
            end
        end
    end
    for _, node in OutputNodes(graph, 'texalpha') do
        local ag = import('/lua/editor/alphagen.lua')
        local profile = import('/lua/editor/strata.lua').Profile() or {}
        local o = { mode = V(run, node, 'mode'), detail = V(run, node, 'detail'), amount = V(run, node, 'amount') }
        local did = false
        if profile.baseAlpha == 'opacity' then
            local note = ag.FitBase(V(run, node, 'baseOpacity'))
            did = note ~= nil
        else
            local entry, msg, n = ag.ApplyLayerAlpha(o)
            if entry then did = true
            elseif o.mode ~= 'off' and msg and not string.find(msg, 'already', 1, true) then
                result.warnings = result.warnings or {}
                table.insert(result.warnings, { text = 'Texture alpha not applied: ' .. msg, code = 'shader', node = node.id })
            end
        end
        if did then result.maptextures = (result.maptextures or 0) + 1 end
    end
    for _, node in OutputNodes(graph, 'roughness') do
        local p = import('/lua/editor/strata.lua').Profile()
        if not p or p.l8 ~= 'rough' then
            result.warnings = result.warnings or {}
            table.insert(result.warnings, { text = 'Roughness mask not written: ' .. tostring(rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or '?') .. ' does not read a roughness mask in layer 8 (the Terrain1xx and Terrain2xx shaders do).', code = 'shader', node = node.id })
        else
            local amount = V(run, node, 'amount')
            local mask = run:Value(node.id, 'view')
            local field = nil
            if mask and Graph.WireInto(node.id, 'a') then
                field = Fields.Op('affine', { a = mask, mul = 200 * amount, add = 128 - 100 * amount })
            end
            local entry, err = MT.GenerateRoughness({ amount = amount, field = field })
            if field then Fields.Free(field) end
            if not entry and err and not string.find(err, 'already like that', 1, true) then return 'roughness mask: ' .. tostring(err) end
            if entry then result.maptextures = (result.maptextures or 0) + 1 end
        end
    end
    return nil
end

--- Writes the map-wide textures of the output nodes Output: map normal map and Output: map lighting (maptextures.lua; each is an undo entry that Build merges with the rest). Adds
--- result.maptextures (how many were made or written), result.mapNote (a sentence for the status line) and result.warnings ({ { text, code } }).
--- A texture the map's shader does not read is SKIPPED with a warning (code 'shader') while its node's Use it on the map is on: the other outputs are built normally. With Use it on the map off
--- only the file is written, which any shader allows. Returns nil, or the message of a real failure (the caller stops the build and reports it, no traceback). A module function, not a local:
--- Build is near the upvalue limit.
function BuildMapTextures(run, graph, result)
    local MT = import('/lua/editor/maptextures.lua')
    pcall(function() import('/lua/editor/alphagen.lua').FitBase() end)
    local notes = {}
    local function Make(kind, noun, node, pieces)
        local opts = { size = V(run, node, 'size'), assign = V(run, node, 'assign') }
        if opts.assign then
            local un = MT.Unsupported(kind)
            if un then
                result.warnings = result.warnings or {}
                table.insert(result.warnings, { text = un.text, code = 'shader', kind = kind, node = node.id })
                return nil
            end
        end
        local res, msg = MT.FromGraph(kind, pieces, opts)
        if not res then return noun .. ': ' .. tostring(msg) end
        result.maptextures = (result.maptextures or 0) + 1
        if msg then table.insert(notes, msg) end
        return nil
    end
    local fail = nil
    for _, node in OutputNodes(graph, 'mapnormal') do
        local col = run:Value(node.id, 'view')
        if col and not fail then fail = Make('normal', 'map normal map', node, { nx = col.r, nz = col.g }) end
    end
    for _, node in OutputNodes(graph, 'maplight') do
        local shadow = run:Value(node.id, 'view')
        if shadow and not fail then fail = Make('light', 'map lighting', node, { shadow = shadow, ao = run:Value(node.id, 'occlusion'), height = run:Value(node.id, 'terrain') }) end
    end
    if fail then return fail end
    if result.maptextures then
        result.mapNote = string.format(', %d map texture%s', result.maptextures, result.maptextures == 1 and '' or 's') .. (notes[1] and (' (' .. table.concat(notes, '; ') .. ')') or '')
    end
    return nil
end

--- Runs the graph at full resolution and writes the outputs: heights, texture layers, terrain types and scattered props as ONE undo step.
--- Returns { changed = samples, layers = n, types = n, props = n, ms, slow = { { id, ms } ... } } or nil and a message.
function Build()
    if not Fields.IsAvailable() or not Size() then return nil, 'no terrain' end
    local graph = Graph.Current
    local problems = Graph.Validate()
    for _, p in problems do
        if p.id then
            local d = Nodes.Defs[Graph.NodeById(p.id).type]
            if d and d.output then return nil, p.text end
        else
            return nil, p.text
        end
    end
    local need, outs = OutputNeeds(graph)
    if next(outs) == nil then return nil, 'the graph has no output node' end
    RevertTerrain()
    local t0 = Clock()
    local run = TakeBuildRun(need)
    local ok, report = pcall(run.Evaluate, run)
    if not ok then
        DropBuild(run)
        return nil, Strip(report), Fields.ErrorTrace(report)
    end
    for id, msg in report.errors do
        local n = Graph.NodeById(id)
        DropBuild(run)
        return nil, (Nodes.Defs[n.type] and Nodes.Defs[n.type].label or n.type) .. ': ' .. msg
    end
    for id, _ in outs do
        local e = run.cache[id]
        if not e or not e.outs then
            local msg = e and e.err or 'not evaluated'
            DropBuild(run)
            return nil, 'output node ' .. id .. ': ' .. tostring(msg)
        end
    end
    -- an output into a layer the map's shader does not paint (strata.lua WhyNotPaintable) refuses the whole build before anything is written
    for _, node in OutputNodes(graph, 'layer') do
        if not Nodes.Defs[node.type].role then
            local why = import('/lua/editor/strata.lua').WhyNotPaintable(math.floor(V(run, node, 'layer') + 0.5))
            if why then
                DropBuild(run)
                return nil, 'output node ' .. node.id .. ': ' .. why
            end
        end
    end
    local result = { changed = 0, layers = 0, types = 0, props = 0 }
    -- a graph that reads the drawing of the Layout workspace has nothing to build from while nothing is drawn: say so instead of building flat ground
    for _, n in graph.nodes do
        if n.type == 'layout_height' and not n.off then
            local okLayout, Layout = pcall(import, '/lua/editor/layout.lua')
            if okLayout and Layout and not Layout.Drawn() then
                result.warnings = result.warnings or {}
                table.insert(result.warnings, { text = 'Map layout: heights has nothing to read, the Layout workspace is empty (draw layers there, or start from one of its templates).', code = 'layout', node = n.id })
            end
        end
    end
    local depthBefore = History.Depth()
    local pushed = 0
    local failure = nil         -- a failure the build reports on purpose (a plain message, no traceback)
    -- Fields.Try, not Run: a failure comes back here without being raised once more (every raise puts another traceback into the message)
    local okBuild, err = Fields.Try(function(S)
        local base = EnsureBase()
        -- heights
        local final = FinalHeight(run, S, base)
        if final then
            local changed = Fields.Apply{ height = final, masks = {}, label = 'Terrain graph' }
            result.changed = changed or 0
        end
        -- texture layers
        local MaskGen = import('/lua/editor/maskgen.lua')
        local spec = GenSym.Spec(graph.symmetry)
        local c = MaskGen.NewContext(S, { step = 1, symmetry = spec })          -- the writers make the masks and the terrain types symmetric
        for _, node in OutputNodes(graph, 'layer') do
            local m = run:Value(node.id, 'view')
            local layer, whyNot, needsTexture = NodeLayer(run, node)
            if m and not layer then
                result.warnings = result.warnings or {}
                table.insert(result.warnings, { text = 'Output: ground kind not written: ' .. tostring(whyNot) .. '.', code = 'role', node = node.id })
            elseif m then
                local mode = ({ replace = 1, add = 2, subtract = 3 })[V(run, node, 'mode')] or 1
                local entry, n = MaskGen.WriteLayer(c, m, layer, { mode = mode, strength = V(run, node, 'strength'), takeAway = V(run, node, 'takeAway') }, false)
                if entry then result.layers = result.layers + 1 end
                -- the layer's texture by kind (grass, rock, sand ...) from the map's texture set, so the mask shows as something
                local role = Nodes.Defs[node.type].role and V(run, node, 'role') or V(run, node, 'texture')
                if Nodes.Defs[node.type].role then
                    -- a ground kind node gives an empty layer the texture of its kind and leaves a layer that has a texture alone
                    if needsTexture and V(run, node, 'texture') then pcall(function() import('/lua/editor/texsets.lua').ApplyRole(layer, role) end) end
                elseif role and role ~= 'keep' then
                    pcall(function() import('/lua/editor/texsets.lua').ApplyRole(layer, role) end)
                end
            end
        end
        -- all ground kinds at once (Output: ground kinds): the priority cascade, the layers of the shader, terrain types and roughness (recipes.lua WriteKinds)
        for _, node in OutputNodes(graph, 'kinds') do
            local sel, any = {}, false
            for _, id in import('/lua/editor/recipes.lua').Order do
                local m = run:Value(node.id, 'seen_' .. id)
                if m then sel[id] = m any = true end
            end
            -- the bands that split a kind between its layers (Ground kinds, erosion paint style)
            for _, vr in { { 'rock2', 'rock#1' }, { 'rock3', 'rock#2' }, { 'dirt2', 'dirt#1' }, { 'wet2', 'wet#1' }, { 'grass2', 'grass#1' } } do
                local m = run:Value(node.id, 'seen_' .. vr[1])
                if m then sel[vr[2]] = m end
            end
            if any then
                local Recipes = import('/lua/editor/recipes.lua')
                local summary, cellsOrWhy = Recipes.WriteKinds(S, c, sel, { label = 'terrain graph', types = V(run, node, 'types'), roughness = V(run, node, 'roughness'), amount = V(run, node, 'amount') })
                if summary then
                    result.layers = result.layers + 1
                    result.kinds = summary
                else
                    result.warnings = result.warnings or {}
                    table.insert(result.warnings, { text = 'Output: ground kinds not written: ' .. tostring(cellsOrWhy) .. '.', code = 'kinds', node = node.id })
                end
            end
        end
        -- terrain types
        if rawget(_G, 'ed_tt_info') and ed_tt_info() then
            for _, node in OutputNodes(graph, 'types') do
                local m = run:Value(node.id, 'view')
                if m then
                    local entry, n = MaskGen.WriteTypes(c, m, math.floor(V(run, node, 'code') + 0.5), V(run, node, 'threshold'), false)
                    if entry then result.types = result.types + 1 end
                end
            end
        end
        -- colour images (stage T7)
        for _, node in OutputNodes(graph, 'colormap') do
            local col = run:Value(node.id, 'view')
            if col then
                local ok, werr = GraphColor.Write(col, V(run, node, 'path'), V(run, node, 'size'))
                if ok then result.colormaps = (result.colormaps or 0) + 1 else failure = 'colour image: ' .. tostring(werr) return end
            end
        end
        -- map-wide shader textures: the normal map and the lighting texture (maptextures.lua)
        local mapFail = BuildMapTextures(run, graph, result)
        if mapFail then failure = mapFail return end
        mapFail = BuildPaintTextures(run, graph, result)
        if mapFail then failure = mapFail return end
        -- props
        local Scatter = import('/lua/editor/scatter.lua')
        for _, node in OutputNodes(graph, 'scatter') do
            local density = run:Value(node.id, 'view')
            if density then density = GenSym.Field(S, density, spec, { seam = 8 }) end
            local entries = node.params.entries or {}
            if table.getn(entries) > 0 then
                local kind = V(run, node, 'kind')
                local settings = {
                    mode = kind, decalSize = 10, withNormals = true, seed = run.seed or graph.seed,
                    count = V(run, node, 'count'), minDist = V(run, node, 'minDist'), fill = V(run, node, 'fill'), slopeMin = 0, slopeMax = V(run, node, 'slopeMax'),
                    heightMin = -100, heightMax = 600, scaleMin = V(run, node, 'scaleMin'), scaleMax = V(run, node, 'scaleMax'), randomHeading = true, avoidExisting = true,
                    margin = V(run, node, 'margin'), underWater = V(run, node, 'underWater'),
                }
                settings.seed = math.mod((run.seed or graph.seed) * 1009 + node.id * 101 + math.floor(V(run, node, 'seed')), 1000003)
                local plan, rep = Scatter.Plan{ settings = settings, entries = entries, density = density, symmetry = spec }
                if plan then
                    local n = Scatter.Place(plan, 'terrain graph props', kind)
                    result.props = result.props + (n or 0)
                end
            end
        end
    end)
    local depthAfter = History.Depth()
    pushed = depthAfter - depthBefore
    if pushed >= 2 then History.Merge(pushed, 'Terrain graph') end
    -- remember what the terrain looks like now: a second Build starts from the same ground
    if Base.field then
        local now = Fields.Height(1)
        Base.builtSum = Fields.Checksum(now)
        Base.owner = Graph.Current
        Fields.Free(now)
    end
    result.slow = Summary(run)
    result.ms = (Clock() - t0) * 1000
    KeepBuildRun(run)
    result.cached = run.report and run.report.cached or 0
    Invalidate()
    if not okBuild then return nil, Strip(err), Fields.ErrorTrace(err) end
    if failure then return nil, failure end
    return result
end

-- ---- variations -------------------------------------------------------------------------------------------------------------------------------------

--- Small pictures of the result for the seeds first .. first + count - 1: { { seed, path } }. Each seed is a private run at the preview resolution (the live cache stays).
function Gallery(first, count, size)
    local graph = Graph.Current
    local need = OutputNeeds(graph)
    local list = {}
    for i = 0, count - 1 do
        local seed = math.mod(first + i, 10000)
        local run = NewRun{ step = math.max(PreviewStep(), 2), thumbs = false, seed = seed, only = need }
        local ok, report = pcall(run.Evaluate, run)
        local path = nil
        if ok then
            local good = true
            for id, _ in report.errors do good = false end
            if good then
                Fields.Run(function(S)
                    local base = run:BaseHere()
                    local cur = FinalHeight(run, S, base)
                    if not cur then
                        -- no height output: the first output of the last node that has a field
                        for _, id in report.order do
                            local e = run.cache[id]
                            local f = e and e.outs and PickThumbField(e, Nodes.Defs[e.nodeType])
                            if f then cur = f end
                        end
                    end
                    if cur then path = Fields.Preview(cur, size, { ramp = 'terrain' }) end
                end)
            end
        end
        table.insert(list, { seed = seed, path = path })
        run:Free()
    end
    return list
end

--- A new map was opened: what belongs to the old one (a preview on its terrain, the cached fields, the remembered ground) is forgotten without touching the new document.
function Forget()
    shown = false
    masked = false
    pcall(function() import('/lua/editor/maskgen.lua').ClearPreview() end)
    if Main then
        Main:Free()
        Main = false
    end
    ForgetBase()
    mainRevision = -1
end
