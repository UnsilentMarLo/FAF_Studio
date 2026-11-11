-- The particle editor's model (WP8 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md, docs/projects/editor/WP8_PARTICLES.md): one open emitter, beam or trail FILE with its curves, edited, shown live
-- in the preview (ed_fxv_*) and written whole into a mod project or the map's folder (`effects/emitters/<name>`), in the text of retail's own emitter editor (the logic is upstream's EdEmitter,
-- bound as ed_fx_*, EdUpFxLua.cpp). fxedit.lua keeps the other route: numeric deltas of the game's existing blueprints as merge blueprints (see the split in the doc).
--
--   Info()                         ed_fx_info(): the 21 curves (name, group, caption, view range, start value), the flags, blend modes, the browser's factions and kinds
--   Kind                           'emitter' | 'beam' | 'trail';  Emitter / Flat the open table (ed_fx_emitter_new / ed_fx_flat_parse shape);  Name ('x_emit.bp');  Source (game path it came from or '')
--   New(kind) / Open(path) / OpenText(text, name)       -> true | nil, message;  Close()
--   Text()                         the file's text: the file as it was opened with the edited keys replaced (Patched = true), or the editor's own layout (a new file, or a text that could not be patched)
--   SetNumber(key, v) SetFlag(name, v) SetText(key, v) SetBool(key, v)      the emitter's settings (lifetime, repeatTime, ... texture, rampTexture; lowFidelity ...)
--   Curve(i)                       curve i (1..21, the file's order)           SetRange(i, xRange)     SetKeys(i, keys)     SetKey(i, k, x, y, z)     AddKey(i, x, y, z) -> k     RemoveKey(i, k)
--   FlatField(key) / SetFlat(key, kind, value)   a beam's or trail's value;  FlatFields()  the catalogue of the kind
--   Undo() / Redo() / CanUndo() / CanRedo()        own history of the open file (the map's history is not touched: an effect file is not a part of the map)
--   Dirty, Revision                changed since open / save, and a counter every edit raises
--   Destinations()                 list of { id, label, dir }: the open mod project and the open map's folder;  Save(destId) -> path | nil, message
--   Apply()                        sends the open file to the preview (every edit does)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

Kind = 'emitter'
Emitter = false
Flat = false
Name = ''
Source = ''
Original = ''               -- the text of the file as it was opened: writing edits THIS text (only the changed keys are replaced), see ed_fx_emitter_write
Patched = false             -- the last Text() kept the file's own text (true) or wrote the editor's layout (false)
Dirty = false
Revision = 0
Error = false

local info = false
local undo, redo = {}, {}
local LIMIT = 100
local lastLabel, lastTime = false, 0

function Info()
    if not info then
        info = ed_fx_info and ed_fx_info() or { curves = {}, flags = {}, blendModes = {}, factions = {}, kinds = {} }
    end
    return info
end

--- The index of a curve by its file key (nil when there is none).
function CurveIndex(name)
    for i, c in Info().curves do
        if c.name == name then return i end
    end
    return nil
end

-- ---- copies ------------------------------------------------------------------------------------------------------------------------------------------

local function CopyCurve(c)
    local out = { name = c.name, xRange = c.xRange, keys = {} }
    for i, k in c.keys do out.keys[i] = { x = k.x, y = k.y, z = k.z } end
    return out
end

local function CopyEmitter(e)
    local out = {}
    for k, v in e do
        if type(v) ~= 'table' then out[k] = v end
    end
    out.flags = {}
    for k, v in e.flags do out.flags[k] = v end
    out.curves = {}
    for i = 1, table.getn(Info().curves) do
        local c = CopyCurve(e.curves[i])
        out.curves[i] = c
        out.curves[c.name] = c
    end
    out.extra = {}
    for i, x in e.extra or {} do out.extra[i] = { key = x.key, text = x.text } end
    return out
end

local function CopyFlat(f)
    local out = { kind = f.kind, fields = {} }
    for i, v in f.fields do
        out.fields[i] = { key = v.key, kind = v.kind, number = v.number, flag = v.flag, text = v.text, color = { v.color[1], v.color[2], v.color[3], v.color[4] } }
    end
    return out
end

local function Snapshot()
    if Kind == 'emitter' then return { kind = Kind, name = Name, emitter = CopyEmitter(Emitter) } end
    return { kind = Kind, name = Name, flat = CopyFlat(Flat) }
end

local function Restore(s)
    Kind, Name = s.kind, s.name
    if s.emitter then Emitter, Flat = CopyEmitter(s.emitter), false else Emitter, Flat = false, CopyFlat(s.flat) end
end

-- ---- applying ----------------------------------------------------------------------------------------------------------------------------------------

--- Sends the open file to the preview.
function Apply(restart)
    if not ed_fxv_emitter then return end
    if Kind == 'emitter' and Emitter then ed_fxv_emitter(Emitter, restart)
    elseif Flat then ed_fxv_flat(Flat, restart) end
end

local function Changed(label, merge)
    -- the undo entry is taken BEFORE the change: the caller passes the snapshot
    Revision = Revision + 1
    Dirty = true
    Apply(false)
end

--- Pushes an undo entry for the change about to be made. The same label within 0.7 s (a drag) is one entry.
local function Before(label)
    local now = GetSystemTimeSeconds and GetSystemTimeSeconds() or 0
    if label and label == lastLabel and now - lastTime < 0.7 and table.getn(undo) > 0 then
        lastTime = now
        return
    end
    table.insert(undo, Snapshot())
    if table.getn(undo) > LIMIT then table.remove(undo, 1) end
    redo = {}
    lastLabel, lastTime = label, now
end

function CanUndo() return table.getn(undo) > 0 end
function CanRedo() return table.getn(redo) > 0 end

function Undo()
    if table.getn(undo) == 0 then return false end
    table.insert(redo, Snapshot())
    Restore(table.remove(undo))
    lastLabel = false
    Revision = Revision + 1
    Dirty = true
    Apply(false)
    return true
end

function Redo()
    if table.getn(redo) == 0 then return false end
    table.insert(undo, Snapshot())
    Restore(table.remove(redo))
    lastLabel = false
    Revision = Revision + 1
    Dirty = true
    Apply(false)
    return true
end

-- ---- open / new --------------------------------------------------------------------------------------------------------------------------------------

local function Reset()
    undo, redo = {}, {}
    lastLabel = false
    Dirty = false
    Error = false
    Revision = Revision + 1
end

local function StemOf(path)
    return (string.gsub(path or '', '^.*/', ''))
end

--- The kind of a file's text by its constructor.
function KindOfText(text)
    local head = string.gsub(text, '%-%-[^\n]*', '')
    if string.find(head, '^%s*TrailEmitterBlueprint') then return 'trail' end
    if string.find(head, '^%s*BeamBlueprint') then return 'beam' end
    if string.find(head, '^%s*EmitterBlueprint') then return 'emitter' end
    return nil
end

--- The default file name of a kind: `new_emit.bp` ...
local function DefaultName(kind)
    return 'new_' .. (kind == 'emitter' and 'emit' or kind) .. '.bp'
end

function New(kind)
    kind = kind or 'emitter'
    if not ed_fx_emitter_new then return nil, 'this engine build has no particle natives' end
    Reset()
    Kind = kind
    Source = ''
    Original = ''
    Name = DefaultName(kind)
    if kind == 'emitter' then
        Emitter, Flat = ed_fx_emitter_new(), false
    else
        Emitter, Flat = false, { kind = kind == 'beam' and 'BeamBlueprint' or 'TrailEmitterBlueprint', fields = {} }
    end
    Apply(true)
    return true
end

--- Opens a file from its text (`name` shows in the title).
function OpenText(text, name, source)
    if not ed_fx_emitter_parse then return nil, 'this engine build has no particle natives' end
    local kind = KindOfText(text)
    if not kind then return nil, 'not an emitter, beam or trail blueprint' end
    local e, f, why
    if kind == 'emitter' then
        e, why = ed_fx_emitter_parse(text)
        if not e then return nil, why end
    else
        f, why = ed_fx_flat_parse(text)
        if not f then return nil, why end
    end
    Reset()
    Kind, Emitter, Flat = kind, e or false, f or false
    Name = name or DefaultName(kind)
    Source = source or ''
    Original = text
    Apply(true)
    return true
end

--- Opens a game file by its virtual path (/effects/emitters/x_emit.bp).
function Open(path)
    local text = ed_game_file_read and ed_game_file_read(path)
    if not text then return nil, 'cannot read ' .. tostring(path) end
    return OpenText(text, StemOf(path), path)
end

function Close()
    Emitter, Flat = false, false
    Name, Source, Original = '', '', ''
    Reset()
end

function SetName(text)
    if text and text ~= '' then Name = text end
end

function IsOpen()
    return Emitter ~= false or Flat ~= false
end

--- The text of the open file as the editor writes it (nil without a file).
function Text()
    local original = Original ~= '' and Original or nil
    if Kind == 'emitter' and Emitter then
        local text, patched = ed_fx_emitter_write(Emitter, original)
        Patched = patched and true or false
        return text
    end
    if Flat then
        local text, patched = ed_fx_flat_write(Flat, original)
        Patched = patched and true or false
        return text
    end
    return nil
end

-- ---- the emitter's settings ---------------------------------------------------------------------------------------------------------------------------

function SetNumber(key, v)
    if not Emitter or Emitter[key] == v then return end
    Before('number ' .. key)
    Emitter[key] = v
    Changed()
end

function SetBool(key, v)
    if not Emitter or Emitter[key] == v then return end
    Before('bool ' .. key)
    Emitter[key] = v
    Changed()
end

function SetFlag(name, v)
    if not Emitter or Emitter.flags[name] == v then return end
    Before('flag ' .. name)
    Emitter.flags[name] = v
    Changed()
end

function SetText(key, v)
    if not Emitter or Emitter[key] == v then return end
    Before('text ' .. key)
    Emitter[key] = v
    Changed()
end

-- ---- curves ------------------------------------------------------------------------------------------------------------------------------------------

function Curve(i)
    return Emitter and Emitter.curves[i] or nil
end

local function SortKeys(keys)
    table.sort(keys, function(a, b) return a.x < b.x end)
end

function SetRange(i, xRange)
    local c = Curve(i)
    if not c or xRange <= 0 or c.xRange == xRange then return end
    Before('range ' .. i)
    c.xRange = xRange
    Changed()
end

--- Replaces the keys of curve i (a list of { x, y, z }).
function SetKeys(i, keys)
    local c = Curve(i)
    if not c then return end
    Before('keys ' .. i)
    c.keys = {}
    for n, k in keys do c.keys[n] = { x = k.x, y = k.y, z = k.z or 0 } end
    SortKeys(c.keys)
    Changed()
end

--- Moves key k of curve i (x, y, z: nil keeps it). The keys stay in x order; returns the key's new index.
function SetKey(i, k, x, y, z)
    local c = Curve(i)
    local key = c and c.keys[k]
    if not key then return k end
    Before('key ' .. i)
    if x ~= nil then key.x = math.max(0, math.min(c.xRange, x)) end
    if y ~= nil then key.y = y end
    if z ~= nil then key.z = math.max(0, z) end
    SortKeys(c.keys)
    for n, other in c.keys do
        if other == key then k = n end
    end
    Changed()
    return k
end

--- Adds a key (the curve's value at x unless y is given); returns its index.
function AddKey(i, x, y, z)
    local c = Curve(i)
    if not c then return nil end
    Before('addkey ' .. i)
    x = math.max(0, math.min(c.xRange, x))
    if y == nil then
        local s = ed_fx_curve_samples(c.keys, c.xRange, 2)
        y = s and s.mid[1] or 0
        -- the value at x: from the samples of a fine run
        local fine = ed_fx_curve_samples(c.keys, c.xRange, 257)
        if fine and c.xRange > 0 then
            local at = math.floor(x / c.xRange * 256 + 0.5) + 1
            y = fine.mid[math.max(1, math.min(257, at))]
        end
    end
    local key = { x = x, y = y, z = z or 0 }
    table.insert(c.keys, key)
    SortKeys(c.keys)
    local index = 1
    for n, other in c.keys do
        if other == key then index = n end
    end
    Changed()
    return index
end

function RemoveKey(i, k)
    local c = Curve(i)
    if not c or not c.keys[k] or table.getn(c.keys) <= 1 then return false end
    Before('rmkey ' .. i)
    table.remove(c.keys, k)
    Changed()
    return true
end

-- ---- beams and trails --------------------------------------------------------------------------------------------------------------------------------

local flatFields = {}

--- The catalogue of the open beam / trail (ed_fx_flat_info): { key, kind, initial, color, help, texture }.
function FlatFields()
    if not Flat then return {} end
    if not flatFields[Flat.kind] then flatFields[Flat.kind] = ed_fx_flat_info(Flat.kind) or {} end
    return flatFields[Flat.kind]
end

--- The value the open beam / trail has for a key (nil = the file has none: the engine's default applies).
function FlatField(key)
    if not Flat then return nil end
    for _, v in Flat.fields do
        if v.key == key then return v end
    end
    return nil
end

--- Sets a key (adds it at the end when the file did not have it). `value` is a number, a bool, a string, or { r, g, b, a } by `kind`.
function SetFlat(key, kind, value)
    if not Flat then return end
    Before('flat ' .. key)
    local v = FlatField(key)
    if not v then
        v = { key = key, kind = kind, number = 0, flag = false, text = '', color = { 0, 0, 0, 0 } }
        table.insert(Flat.fields, v)
    end
    v.kind = kind
    if kind == 'number' then v.number = value
    elseif kind == 'bool' then v.flag = value
    elseif kind == 'text' then v.text = value
    elseif kind == 'color' then v.color = { value[1], value[2], value[3], value[4] } end
    Changed()
end

-- ---- writing ------------------------------------------------------------------------------------------------------------------------------------------

local function DirOf(vfs)
    return ed_vfs_to_disk and ed_vfs_to_disk(vfs) or nil
end

--- Where a file can be written: the open mod project (its effects/emitters folder) and the folder of the open map. Each { id, label, dir } (dir = the folder that holds `effects/`).
function Destinations()
    local list = {}
    local ok, Bp = pcall(import, '/lua/editor/bpedit.lua')
    if ok and Bp and Bp.Project then
        table.insert(list, { id = 'project', label = 'Mod project ' .. tostring(Bp.Project), dir = Bp.ROOT .. '/' .. Bp.Project })
    end
    local okm, session = pcall(SessionGetScenarioInfo)
    local file = okm and session and session.file
    if file then
        local disk = DirOf(file)
        if disk then
            disk = (string.gsub(disk, '\\', '/'))
            disk = (string.gsub(disk, '/[^/]*$', ''))
            table.insert(list, { id = 'map', label = 'Map folder ' .. (string.gsub(disk, '^.*/', '')), dir = disk })
        end
    end
    return list
end

--- The virtual folders besides the game's /effects that hold effect files of the work in hand: the open mod project's and the open map's `effects` folder (the browser lists them too).
function Roots()
    local roots = {}
    local ok, Bp = pcall(import, '/lua/editor/bpedit.lua')
    if ok and Bp and Bp.Project then table.insert(roots, '/mods/' .. Bp.Project .. '/effects') end
    local okm, session = pcall(SessionGetScenarioInfo)
    if okm and session and session.file then
        table.insert(roots, (string.gsub(session.file, '/[^/]*$', '')) .. '/effects')
    end
    return roots
end

--- The file name with the suffix of its kind (a name without one gets it).
function FileName()
    local n = string.gsub(string.lower(Name), '%.bp$', '')
    local suffix = Kind == 'emitter' and '_emit' or ('_' .. Kind)
    if not string.find(n, suffix .. '$') then n = n .. suffix end
    return n .. '.bp'
end

--- Writes the open file into `effects/emitters/` of the destination (id of Destinations() or a disk folder). Returns the path, or nil and why.
function Save(dest)
    if not IsOpen() then return nil, 'no file open' end
    local dir
    if type(dest) == 'string' and (string.find(dest, ':') or string.find(dest, '^[/\\.]')) then
        dir = dest
    else
        for _, d in Destinations() do
            if d.id == dest then dir = d.dir end
        end
    end
    if not dir then return nil, 'no mod project or map folder to write into (open a mod project in the Unit lab, or save the map first)' end
    local text = Text()
    if not text then return nil, 'nothing to write' end
    local path = dir .. '/effects/emitters/' .. FileName()
    if not ed_write_file(path, text) then return nil, 'cannot write ' .. path end
    Original = text         -- what is on disk now is the base of the next write
    Dirty = false
    return path
end
