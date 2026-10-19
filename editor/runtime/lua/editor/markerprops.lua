-- Marker properties of every marker type. A marker type (/lua/MarkerTemplates.lua) carries fields of its own: a Camera Info marker a zoom and camera flags, a path node its graph and
-- adjacency, a weather definition its cloud types, an effect marker its template, scale and offset. The Properties panel shows one field per key of the marker's template; this
-- module knows which keys those are, how to read and change them with undo, how to change a marker's type and how a camera marker looks through / is set from the view.
--
--   Fields(markerType, marker)     -> list of { key, kind = 'number' | 'string' | 'bool' | 'vector', default } (template keys, plus keys the marker already has)
--   Get(name, key) / Set(name, key, value)           value of a field (the template default when the marker has none), change with undo
--   VectorText(v) / ParseVector(text)                 'x, y, z' <-> { x, y, z }
--   ChangeType(name, newType)                         the marker becomes another type: template fields of the new type added, those of the old one dropped, one undo step
--   IsCamera(marker) / LookThrough(name) / SetFromCamera(name)       Camera Info markers: orientation = { heading, pitch, 0 }, zoom
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local History = import('/lua/editor/history.lua')

-- keys the Properties panel shows in its own rows or that are not data a person edits
local STRUCTURAL = { type = true, position = true, orientation = true, prop = true, color = true, hint = true, resource = true, editorIcon = true, amount = true, size = true }

local function MarkerTable()
    return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local c = {}
    for k, x in v do c[k] = Copy(x) end
    return c
end

local function KindOf(v)
    local t = type(v)
    if t == 'number' then return 'number' end
    if t == 'boolean' then return 'bool' end
    if t == 'table' and type(v[1]) == 'number' and type(v[3]) == 'number' then return 'vector' end
    return 'string'
end

--- The editable fields of a marker of type `markerType`: the template's keys (default = the template's value) and the keys the marker itself has beyond them.
function Fields(markerType, marker)
    local list, seen = {}, {}
    local tpl = Tools.Templates()[markerType] or {}
    for k, v in tpl do
        if not STRUCTURAL[k] and type(v) ~= 'function' then
            table.insert(list, { key = k, kind = KindOf(v), default = v })
            seen[k] = true
        end
    end
    for k, v in marker or {} do
        if not STRUCTURAL[k] and not seen[k] and type(v) ~= 'function' then
            table.insert(list, { key = k, kind = KindOf(v), default = v })
        end
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

function Get(name, key)
    local m = MarkerTable()[name]
    if not m then return nil end
    if m[key] ~= nil then return m[key] end
    local tpl = Tools.Templates()[m.type] or {}
    return tpl[key]
end

--- Changes one field with undo. Returns true.
function Set(name, key, value)
    local m = MarkerTable()[name]
    if not m then return false end
    Tools.SetField(m, { key }, value, key .. ' of ' .. name)
    return true
end

function VectorText(v)
    if type(v) ~= 'table' then return '' end
    return string.format('%g, %g, %g', v[1] or 0, v[2] or 0, v[3] or 0)
end

--- 'x, y, z' (commas or spaces) -> { x, y, z }; nil when it does not hold three numbers.
function ParseVector(text)
    local nums = {}
    for token in string.gfind(text or '', '[^,%s]+') do
        local n = tonumber(token)
        if not n then return nil end
        table.insert(nums, n)
    end
    if table.getn(nums) ~= 3 then return nil end
    return nums
end

--- The marker becomes a marker of `newType`: prop, colour and the fields of the new template (defaults where the marker has no value of that name), fields only the old template had
--- are dropped, position and rotation stay. One undo step. Returns true or nil and a reason.
function ChangeType(name, newType)
    local m = MarkerTable()[name]
    local tpl = Tools.Templates()[newType]
    if not m then return nil, 'no such marker' end
    if not tpl then return nil, 'unknown marker type ' .. tostring(newType) end
    if m.type == newType then return nil, 'already that type' end
    if Tools.ReadOnly then return nil, 'read only' end
    local before = Copy(m)
    local old = Tools.Templates()[m.type] or {}
    for k, _ in old do
        if k ~= 'prop' and k ~= 'color' then m[k] = nil end
    end
    m.resource, m.amount, m.size, m.editorIcon = nil, nil, nil, nil
    m.type = newType
    for k, v in tpl do
        if type(v) ~= 'function' then m[k] = Copy(v) end
    end
    local after = Copy(m)
    local function Restore(state)
        for k, _ in m do m[k] = nil end
        for k, v in state do m[k] = Copy(v) end
        Tools.Changed = Tools.Changed + 1
    end
    Tools.Changed = Tools.Changed + 1
    History.Push({ label = 'type of ' .. name .. ': ' .. newType, undo = function() Restore(before) end, redo = function() Restore(after) end })
    return true
end

function IsCamera(marker)
    return marker ~= nil and marker.type == 'Camera Info'
end

--- The editor camera moves to the view a Camera Info marker stores: its position, orientation { heading, pitch, 0 } and zoom.
function LookThrough(name)
    local m = MarkerTable()[name]
    if not m then return false end
    local cam = GetCamera('WorldCamera')
    if not cam then return false end
    local s = cam:SaveSettings()
    local o = m.orientation or { 0, 0, 0 }
    local zoom = tonumber(m.zoom)
    if not zoom or zoom <= 0 then zoom = s.Zoom end
    cam:MoveTo(Vector(m.position[1], m.position[2], m.position[3]), { o[1] or s.Heading, o[2] or s.Pitch, 0 }, zoom, 0.4)
    return true
end

--- The marker takes the editor camera's view: focus point, heading, pitch and zoom. One undo step. Returns true.
function SetFromCamera(name)
    local m = MarkerTable()[name]
    local cam = GetCamera('WorldCamera')
    if not m or not cam or Tools.ReadOnly then return false end
    local s = cam:SaveSettings()
    local f = s.Focus
    if not f then return false end
    local before = { Copy(m.position), Copy(m.orientation), m.zoom }
    local after = { { f[1], f[2], f[3] }, { s.Heading, s.Pitch, 0 }, s.Zoom }
    local function Apply(state)
        m.position, m.orientation, m.zoom = Copy(state[1]), Copy(state[2]), state[3]
        Tools.Changed = Tools.Changed + 1
    end
    Apply(after)
    History.Push({ label = 'camera of ' .. name, undo = function() Apply(before) end, redo = function() Apply(after) end })
    return true
end
