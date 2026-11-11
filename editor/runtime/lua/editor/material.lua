-- The material editor's model (WP10 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md, docs/projects/editor/WP10_MATERIAL.md): a colour texture graph that makes the albedo, the normal map and a
-- paint mask of a terrain stratum. The logic is upstream's TextureGraph (noise, maths, blends, adjustments, normals, the map's height / mask / slope), bound as ed_tex_* (EdUpTexGraphLua.cpp);
-- this file is the document around it: undo, the picture files the panels show, graph files, and the bake that writes DDS files and sets them as a layer's textures.
--
--   Available() -> bool        this engine has the ed_tex_* natives
--   Types() / TypeOf(name)     the node palette (ed_tex_types) / one type
--   New(how)                   a new graph: 'start' (noise -> gradient map -> Albedo, its height -> Normal) or 'empty'; Doc = { id, name, sel, ... }
--   Snap()                     the graph as the natives describe it ({ nodes, links, output, ... }), refreshed when it changed
--   Node(id) / Link(id, pin) / InputLink(node, pin) / OutputNode()       lookups in the snapshot (pins are 0-based as in the natives)
--   AddNode(type, x, y) / RemoveNode(id) / SetParam(node, param, value, key) / Connect(fromNode, fromPin, toNode, toPin) / Disconnect(node, pin) / MoveNodes(list)     edits, each one undo step
--   Begin() / End(label, before, key)      group edits (a drag) into one undo step;  Undo() / Redo()
--   Refresh() -> bool          evaluates what changed (the preview size), polls the bake job; true when something moved
--   Picture(node, pin, size, channel) -> VFS path | nil       the node's output as a picture a Maui Bitmap shows (a new file per version)
--   OutputPicture(pin, size) / LitPicture(mode, size, yaw, light)     the Output's pin / the lit sphere or plane
--   Save(name) / Open(name) / Files()     graph files (materials/<name>.fafgraph.json)
--   Apply(opts)                bake at opts.size, write the DDS files, set them as the textures of layer opts.stratum (and paint its mask when opts.mask); one undo step. Result in Status.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Strata = import('/lua/editor/strata.lua')
local History = import('/lua/editor/history.lua')
local MapTextures = import('/lua/editor/maptextures.lua')

Doc = false
Status = ''
StatusKind = 'info'       -- 'info' | 'warn' | 'error'
PreviewSize = 256
Opts = { stratum = 1, size = 1024, tile = 0, mask = false, mode = 'albedo', yaw = 0.6, light = -0.7 }
Job = false               -- the running bake: { id, stratum, tile, size, mask, before, started, albedo, normal }

local types, byName = false, {}
local snap, snapChanges, snapKey = false, -1, ''
local tmpSerial = 0
local tmpMounted = false
local filesMounted = false

TMP = '../mattmp'
TMP_MOUNT = '/edmat'
FOLDER = 'materials'
FOLDER_MOUNT = '/usermaterials'
EXT = '.fafgraph.json'

local function Now()
    if rawget(_G, 'GetSystemTimeSeconds') then return GetSystemTimeSeconds() end
    return 0
end

local function Say(text, kind)
    Status = text
    StatusKind = kind or 'info'
end

function Available()
    return rawget(_G, 'ed_tex_new') ~= nil
end

-- ---- the palette ------------------------------------------------------------------------------------------------------------------------------

function Types()
    if not types then
        types, byName = {}, {}
        if Available() then
            types = ed_tex_types()
            for _, t in types do byName[t.name] = t end
        end
    end
    return types
end

function TypeOf(name)
    Types()
    return byName[name]
end

--- The palette by category: { { name = 'Noise', types = { ... } }, ... } in the order the natives list them (the Output node is not in it: a graph has exactly one).
function Categories()
    local out, index = {}, {}
    for _, t in Types() do
        if not t.output then
            local c = index[t.category]
            if not c then
                c = { name = t.category, types = {} }
                index[t.category] = c
                table.insert(out, c)
            end
            table.insert(c.types, t)
        end
    end
    return out
end

-- ---- the document -----------------------------------------------------------------------------------------------------------------------------

local function Free()
    if Job then
        ed_tex_bake_cancel(Job.id)
        ed_tex_bake_free(Job.id)
        Job = false
    end
    if Doc then ed_tex_free(Doc.id) end
    Doc = false
    snap, snapChanges, snapKey = false, -1, ''
end

--- A new graph. `how` 'start' (default) or 'empty'. Returns the document, or nil and why.
function New(how)
    if not Available() then return nil, 'this engine has no texture graph natives (ed_tex_*)' end
    Free()
    local id = ed_tex_new(how or 'start')
    Doc = { id = id, name = 'untitled', sel = false, undo = {}, redo = {}, pics = {}, serial = 0, evalChanges = -1, evalSize = 0, terrain = false, terrainStamp = '', saved = false,
            changed = 0, stamp = 0 }
    Doc.saved = ed_tex_save(id)
    Say('')
    return Doc
end

function Close()
    Free()
end

--- The snapshot of the graph; one native call per change.
function Snap()
    if not Doc then return false end
    local s = ed_tex_graph(Doc.id)
    if not s then return false end
    -- the natives' change counter and ours (a Load can bring the counter back to a value it had before: the graph file differs, the count may not)
    local key = s.changes .. ':' .. Doc.changed
    if key ~= snapKey or not snap then
        snap, snapKey, snapChanges = s, key, key
        Doc.stamp = Doc.stamp + 1
    else
        snap.size = s.size
    end
    return snap
end

function Node(id)
    local s = Snap()
    if not s then return nil end
    for _, n in s.nodes do
        if n.id == id then return n end
    end
    return nil
end

--- The link into input `pin` (0-based) of node `to`, or nil.
function InputLink(to, pin)
    local s = Snap()
    if not s then return nil end
    for _, l in s.links do
        if l.toNode == to and l.toPin == pin then return l end
    end
    return nil
end

function OutputNode()
    local s = Snap()
    return s and s.output or 0
end

-- ---- edits and undo ---------------------------------------------------------------------------------------------------------------------------

local LIMIT = 100

--- The graph as text now: what Begin hands to End.
function Begin()
    return ed_tex_save(Doc.id)
end

--- Records the edit that turned `before` into the graph as it is now. `key` merges the edits of one slider drag (within 1.5 s) into one entry. Returns true when something changed.
function End(label, before, key)
    local after = ed_tex_save(Doc.id)
    if after == before then return false end
    local now = Now()
    local top = Doc.undo[table.getn(Doc.undo)]
    Doc.redo = {}
    if key and top and top.key == key and now - top.time < 1.5 then
        top.after = after
        top.time = now
    else
        table.insert(Doc.undo, { label = label, before = before, after = after, key = key, time = now })
        if table.getn(Doc.undo) > LIMIT then table.remove(Doc.undo, 1) end
    end
    Doc.changed = Doc.changed + 1
    return true
end

local function Restore(text)
    local ok, why = ed_tex_load(Doc.id, text)
    if not ok then Say('undo: ' .. tostring(why), 'error') return false end
    if Doc.sel and not Node(Doc.sel) then Doc.sel = false end
    Doc.changed = Doc.changed + 1
    return true
end

function Undo()
    if not Doc then return false end
    local e = table.remove(Doc.undo)
    if not e then return false end
    table.insert(Doc.redo, e)
    return Restore(e.before)
end

function Redo()
    if not Doc then return false end
    local e = table.remove(Doc.redo)
    if not e then return false end
    table.insert(Doc.undo, e)
    return Restore(e.after)
end

local function Edit(label, fn, key)
    local before = Begin()
    local result = fn()
    End(label, before, key)
    return result
end

--- Adds a node; when a node is selected and the new one has an input it can take from the selected node's first output, the two are linked (a chain is built by clicking).
function AddNode(type, x, y)
    local def = TypeOf(type)
    if not def then return nil, 'unknown node type ' .. tostring(type) end
    local from = Doc.sel and Node(Doc.sel)
    local id, why = Edit('add ' .. def.title, function()
        local newId, err = ed_tex_add(Doc.id, type, x, y)
        if not newId then return nil, err end
        if from then
            local fromDef = TypeOf(from.type)
            if fromDef and fromDef.outputs[1] and def.inputs[1] and not fromDef.output then
                ed_tex_link(Doc.id, from.id, 0, newId, 0)
            end
        end
        return newId
    end)
    if not id then return nil, why end
    Doc.sel = id
    return id
end

function RemoveNode(id)
    local n = Node(id)
    if not n then return false end
    local def = TypeOf(n.type)
    if def and def.output then return false end
    local ok = Edit('delete ' .. (def and def.title or 'node'), function() return ed_tex_remove(Doc.id, id) end)
    if ok and Doc.sel == id then Doc.sel = false end
    return ok
end

--- Sets one parameter. `value`: a number or { v = {a, b, c, d}, text = s }; `key` merges a slider's drag.
function SetParam(node, param, value, key)
    local n = Node(node)
    local def = n and TypeOf(n.type)
    if not def then return false end
    local name = type(param) == 'number' and def.params[param + 1] and def.params[param + 1].name or param
    return Edit('set ' .. tostring(name), function() return ed_tex_set_param(Doc.id, node, param, value) end, key and (key .. ':' .. node .. ':' .. tostring(param)) or nil)
end

function Connect(fromNode, fromPin, toNode, toPin)
    local result
    Edit('link', function() result = ed_tex_link(Doc.id, fromNode, fromPin, toNode, toPin) end)
    return result == 'ok', result
end

function Disconnect(node, pin)
    return Edit('unlink', function() return ed_tex_unlink(Doc.id, node, pin) end)
end

--- Moves nodes: `list` = { { id, x, y }, ... }; `before` (from Begin) makes it one undo step, else each call is one.
function MoveNodes(list, before)
    for _, m in list do ed_tex_move(Doc.id, m[1], m[2], m[3]) end
    if before then End('move', before, 'move') end
end

--- Where a new node fits: right of the selected node, else below the lowest node.
function FreeSpot(type)
    local s = Snap()
    local from = Doc and Doc.sel and Node(Doc.sel)
    if from then return from.x + 190, from.y end
    local y = 0
    for _, n in s.nodes do
        if n.y + 140 > y then y = n.y + 140 end
    end
    return 0, y
end

-- ---- evaluation and pictures ------------------------------------------------------------------------------------------------------------------

local function TerrainStamp()
    local ok, stamp = pcall(function() return import('/lua/editor/terrainepoch.lua').Stamp() end)
    return ok and stamp or ''
end

--- Gives the Map nodes the open map's heights and stratum masks (again).
function CaptureTerrain()
    if not Doc then return false end
    local ok, why = ed_tex_terrain(Doc.id, true)
    Doc.terrain = ok and true or false
    Doc.terrainStamp = TerrainStamp()
    Doc.evalChanges = -1
    if not ok then Say('map data: ' .. tostring(why), 'warn') end
    return ok
end

--- The size the preview is evaluated at.
function SetPreviewSize(size)
    PreviewSize = size
    if Doc then
        ed_tex_size(Doc.id, size)
        Doc.evalChanges = -1
        Doc.pics = {}
    end
end

local function Delete(path)
    if rawget(_G, 'ed_file_delete') and path then pcall(ed_file_delete, path) end
end

local function EnsureTmp()
    if not tmpMounted then
        ed_write_file(TMP .. '/readme.txt', 'Pictures of the material editor; safe to delete.\n')
        ed_vfs_mount(TMP, TMP_MOUNT)
        tmpMounted = true
    end
end

--- A picture file under a fresh name (the engine keeps textures by path). `key` names what it shows; the file it replaces is deleted.
local function Fresh(key)
    EnsureTmp()
    tmpSerial = tmpSerial + 1
    local name = 'm' .. tmpSerial .. '.dds'
    local old = Doc.pics[key]
    if old then Delete(old.disk) end
    return TMP .. '/' .. name, TMP_MOUNT .. '/' .. name
end

--- The graph brought up to date at the preview size. Returns true when it computed something.
function Evaluate()
    if not Doc then return false end
    local s = Snap()
    if not s then return false end
    local uses = s.usesTerrain
    if uses and (not Doc.terrain or Doc.terrainStamp ~= TerrainStamp()) then CaptureTerrain() end
    if Doc.evalChanges == snapChanges and Doc.evalSize == PreviewSize then return false end
    ed_tex_size(Doc.id, PreviewSize)
    local n, ms = ed_tex_eval(Doc.id)
    Doc.evalChanges, Doc.evalSize = snapChanges, PreviewSize
    Doc.lastComputed, Doc.lastMillis = n, ms
    return true
end

--- A node's output as a picture; nil while it has none (an error, a loop). Cached per node revision and size.
function Picture(node, pin, size, channel)
    local n = Node(node)
    if not n then return nil end
    local key = 'n' .. node .. ':' .. pin .. ':' .. size .. ':' .. (channel or '')
    local have = Doc.pics[key]
    local rev = n.revision .. ':' .. Doc.evalSize
    if have and have.rev == rev then return have.vfs end
    local disk, vfs = Fresh(key)
    local ok, why = ed_tex_image(Doc.id, node, pin, disk, size, channel)
    if not ok then
        Doc.pics[key] = nil
        return nil, why
    end
    Doc.pics[key] = { rev = rev, vfs = vfs, disk = disk }
    return vfs
end

--- The Output node's pin ('Albedo', 'Normal', 'Mask') at the graph's size; nil when nothing is linked to it.
function OutputPicture(pin, size)
    if not Doc then return nil end
    Snap()
    local key = 'out:' .. pin .. ':' .. size
    local have = Doc.pics[key]
    local rev = snapChanges .. ':' .. Doc.evalSize
    if have and have.rev == rev then return have.vfs end
    local disk, vfs = Fresh(key)
    local ok, why = ed_tex_result(Doc.id, pin, disk, size)
    if not ok then
        Doc.pics[key] = nil
        return nil, why
    end
    Doc.pics[key] = { rev = rev, vfs = vfs, disk = disk }
    return vfs
end

--- A lit sphere (mode 0) or a 2 x 2 plane (mode 1) of the Albedo and Normal outputs.
function LitPicture(mode, size, yaw, light)
    if not Doc then return nil end
    Snap()
    local key = 'lit:' .. mode .. ':' .. size
    local have = Doc.pics[key]
    local rev = snapChanges .. ':' .. Doc.evalSize .. ':' .. yaw .. ':' .. light
    if have and have.rev == rev then return have.vfs end
    local disk, vfs = Fresh(key)
    local ok, why = ed_tex_lit(Doc.id, disk, size, mode, yaw, light)
    if not ok then
        Doc.pics[key] = nil
        return nil, why
    end
    Doc.pics[key] = { rev = rev, vfs = vfs, disk = disk }
    return vfs
end

--- What a node says about itself after the last evaluation: { warning, millis } or nil.
function NodeInfo(id)
    if not Doc then return nil end
    local info = ed_tex_info(Doc.id, id)
    return info
end

-- ---- files ------------------------------------------------------------------------------------------------------------------------------------

local function SafeName(name)
    name = string.gsub(tostring(name or ''), '[^%w_%- ]', '_')
    name = string.gsub(name, '^%s+', '')
    name = string.gsub(name, '%s+$', '')
    if name == '' then name = 'material' end
    return name
end
SafeNameOf = SafeName

function Save(name)
    if not Doc then return false, 'no graph' end
    name = SafeName(name or Doc.name)
    local ok = ed_write_file(FOLDER .. '/' .. name .. EXT, ed_tex_save(Doc.id))
    if not ok then return false, 'cannot write ' .. FOLDER .. '/' .. name .. EXT end
    Doc.name = name
    Doc.saved = ed_tex_save(Doc.id)
    return true
end

function Open(name)
    local text = ed_read_file(FOLDER .. '/' .. name .. EXT)
    if not text then return false, 'no file ' .. FOLDER .. '/' .. name .. EXT end
    local d = New('empty')
    if not d then return false, 'no texture graph natives' end
    local ok, why = ed_tex_load(d.id, text)
    if not ok then return false, why end
    d.name = name
    d.saved = ed_tex_save(d.id)
    d.evalChanges = -1
    return true
end

--- Names of the saved graphs (the folder is mounted to list it: the VFS cannot see the working directory otherwise).
function Files()
    local names = {}
    if rawget(_G, 'ed_vfs_mount') then
        if not filesMounted then
            ed_write_file(FOLDER .. '/readme.txt', 'Texture graphs of the material editor (*.fafgraph.json).\n')
            ed_vfs_mount(FOLDER, FOLDER_MOUNT)
            filesMounted = true
        end
    end
    for _, path in DiskFindFiles(FOLDER_MOUNT, '*' .. EXT) or {} do
        local base = string.gsub(path, '^.*[/\\]', '')
        base = string.gsub(base, '%.fafgraph%.json$', '')
        table.insert(names, base)
    end
    table.sort(names)
    return names
end

--- Does the graph differ from the file it was opened or saved as?
function Modified()
    return Doc and Doc.saved ~= ed_tex_save(Doc.id) or false
end

-- ---- the bake: DDS files that become a layer's textures ---------------------------------------------------------------------------------------

local function Basename(path)
    return (string.gsub(path or '', '^.*[/\\]', ''))
end

--- True when the output pin has a link in the snapshot.
function PinLinked(name)
    local s = Snap()
    if not s then return false end
    local out = Node(s.output)
    if not out then return false end
    local def = TypeOf(out.type)
    for i, p in def.inputs do
        if p.name == name then return InputLink(out.id, i - 1) ~= nil end
    end
    return false
end

local function StageName(kind)
    MapTextures.EnsureStage()
    local name = MapTextures.NextName(kind)
    return name, MapTextures.STAGE .. '/' .. name, MapTextures.MOUNT .. '/' .. name
end

--- Starts the bake. opts: stratum (0..8: 0 is the base layer, 1..8 the painted layers), size (the bake's size), tile (the layer's tile size in game units, 0 = keep the layer's own, else 10),
--- mask (paint the layer's mask from the Output's Mask). Returns true, or nil and why. The result is applied by Refresh when the job is done.
function Apply(opts)
    if not Doc then return nil, 'no graph' end
    if Job then return nil, 'a bake is running' end
    if not PinLinked('Albedo') then
        Say('Link something to the output\'s Albedo first.', 'warn')
        return nil, 'no albedo'
    end
    opts = opts or Opts
    local stratum = opts.stratum or Opts.stratum
    local mask = opts.mask and stratum >= 1 and stratum <= 8 and PinLinked('Mask')
    if opts.mask and not mask then
        Say(stratum < 1 and 'The base layer has no mask: the textures are applied without it.' or 'Link something to the output\'s Mask to paint the layer.', 'warn')
    end
    if Doc.terrain then CaptureTerrain() end             -- the bake sees the map as it is now
    local an, adisk, avfs = StageName('mata')
    local normalLinked = PinLinked('Normal')
    local nn, ndisk, nvfs
    if normalLinked then nn, ndisk, nvfs = StageName('matn') end
    local id = ed_tex_bake_start(Doc.id, { size = opts.size or Opts.size, albedo = adisk, normal = ndisk })
    local albedoPath, normalPath = avfs, nvfs
    -- the tile size: the layer's own when it has a texture of its own already, else 10 (upstream's default)
    local _, oldSize = ed_stratum_layer(stratum)
    local tile = opts.tile or Opts.tile
    if not tile or tile <= 0 then tile = (oldSize and oldSize > 1) and oldSize or 10 end
    Job = { id = id, stratum = stratum, tile = tile, mask = mask, before = Strata.Snapshot(stratum), started = Now(), albedoDisk = adisk, normalDisk = ndisk,
            albedoVfs = albedoPath, normalVfs = normalPath, size = opts.size or Opts.size }
    if not MapTextures.State.mounted then
        if ed_vfs_mount(MapTextures.STAGE, MapTextures.MOUNT) then MapTextures.State.mounted = true end
    end
    Say('Baking at ' .. Job.size .. ' ...')
    return true
end

--- Progress of the running bake (0..1) or nil.
function BakeProgress()
    if not Job then return nil end
    local p = ed_tex_bake_poll(Job.id)
    return p and p.progress or 0
end

--- A layer as a snapshot had it: Strata.Restore does nothing for a layer that had no texture, so that layer gets the transparent one back.
local function RestoreLayer(snap)
    if snap.albedo == '' then Strata.Clear(snap.index) else Strata.Restore(snap) end
end

--- Polls the bake; applies the result when it is done. Returns true when something happened.
local function PollBake()
    if not Job then return false end
    local r = ed_tex_bake_poll(Job.id)
    if not r then
        Job = false
        Say('The bake was lost.', 'error')
        return true
    end
    if not r.done then return false end
    local job = Job
    if not r.ok then
        ed_tex_bake_free(job.id)
        Job = false
        Say('Bake failed: ' .. tostring(r.error), 'error')
        return true
    end
    local stratum = job.stratum
    local before = job.before
    -- register the files with the staging folder's bookkeeping? No: maptextures.Prune only deletes files that module made itself (State.created); these are managed by name (maptex_*_N.dds), so
    -- the map save copies them into the map's folder (maptextures.PrepareSave) and cleans the unused ones.
    local normal = r.normalBytes > 0 and job.normalVfs or nil
    local ok = Strata.SetTexture(stratum, job.albedoVfs, normal, job.tile)
    if not ok then
        ed_tex_bake_free(job.id)
        Job = false
        Say('The engine could not load ' .. job.albedoVfs, 'error')
        return true
    end
    local after = Strata.Snapshot(stratum)
    local maskEntry = nil
    local text = 'Applied to ' .. Strata.LayerName(stratum) .. ': ' .. Basename(job.albedoVfs) .. ' (' .. string.format('%d', math.floor(r.albedoBytes / 1024)) .. ' KB, ' .. string.format('%.0f', r.millis) .. ' ms)'
    if job.mask then
        local w, h = ed_stratum_info()
        if w then
            maskEntry = Strata.EditMask(stratum, 'paint mask of', function(old, n, x0, z0, tw, th)
                local values = ed_tex_bake_mask(job.id, w, h, x0, z0, x0 + tw - 1, z0 + th - 1)
                return values
            end)
            text = text .. (maskEntry and '; its mask painted' or '; the mask was already that')
        end
    end
    ed_tex_bake_free(job.id)
    Job = false
    local entry = {
        label = 'material on ' .. Strata.LayerName(stratum),
        bytes = maskEntry and maskEntry.bytes or 0,
        undo = function()
            if maskEntry then maskEntry.undo() end
            RestoreLayer(before)
        end,
        redo = function()
            Strata.Restore(after)
            if maskEntry then maskEntry.redo() end
        end,
    }
    History.Push(entry)
    Doc.applied = { stratum = stratum, albedo = job.albedoVfs, normal = normal }
    Say(text)
    return true
end

--- Called about four times a second by the panels: evaluates what changed and finishes a bake. Returns true when something changed.
function Refresh()
    if not Doc then return false end
    local moved = false
    if Evaluate() then moved = true end
    if PollBake() then moved = true end
    return moved
end
