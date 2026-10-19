-- Emitter, beam, trail and projectile blueprints as editable fields (docs/projects/MOD_UNIT_EDITOR_DESIGN.md, stage S3, field editing). bpedit.lua keeps the edits (the same `Edits[id][key]` table as the
-- unit edits, with the blueprint path as the id), writes them as merge blueprints into the mod project, and asks this module for the field catalogue and the file layout.
--
--   Kind(id)                 'emitter' | 'beam' | 'trail' | 'projectile' | nil, by the path: /effects/emitters/*_emit.bp, *_beam.bp, *_trail.bp, /projectiles/*/*_proj.bp
--   Blueprint(id)            the game's table of that blueprint (emitters are read by running the .bp file in a sandbox: the engine keeps them out of __blueprints), nil when there is none
--   Fields(id)               { key, label, group, base, min, max, step, dec } for every number in it (curves: `SizeCurve.Keys.2.y`); projectiles only Physics / Display / Economy / Defense
--   Header(id)               the constructor the merge file uses ('EmitterBlueprint', ...)
--   Emitters(template)       the emitter paths of an effect template (effectview.lua)
--
-- An emitter or beam blueprint gets its id from the path of the file it was loaded from (Blueprints.lua SetBackwardsCompatId: lower(Source)), so a merge file names the game's path in `Source`; array
-- entries (curve keys) merge by index. Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local cache = {}

local HEADERS = { emitter = 'EmitterBlueprint', beam = 'BeamBlueprint', trail = 'TrailEmitterBlueprint', projectile = 'ProjectileBlueprint' }

function Kind(id)
    if type(id) ~= 'string' or string.sub(id, 1, 1) ~= '/' then return nil end
    local lower = string.lower(id)
    if string.find(lower, '^/projectiles/') then return 'projectile' end
    if string.find(lower, '^/effects/') then
        if string.find(lower, '_emit%.bp$') then return 'emitter' end
        if string.find(lower, '_beam%.bp$') then return 'beam' end
        if string.find(lower, '_trail%.bp$') then return 'trail' end
    end
    return nil
end

function Header(id)
    return HEADERS[Kind(id) or '']
end

local function Load(path)
    local captured
    local env = {}
    local function Capture(bp) captured = bp end
    env.EmitterBlueprint, env.BeamBlueprint, env.TrailEmitterBlueprint = Capture, Capture, Capture
    setmetatable(env, { __index = _G })
    local ok = pcall(doscript, path, env)
    if ok and type(captured) == 'table' then return captured end
    return nil
end

function Blueprint(id)
    local kind = Kind(id)
    if not kind then return nil end
    if kind == 'projectile' then
        return __blueprints and __blueprints[string.lower(id)]
    end
    if cache[id] == nil then cache[id] = Load(id) or false end
    return cache[id] or nil
end

local SKIP = { BlueprintId = true, Source = true, Merge = true, BlueprintOrdinal = true, CategoriesCount = true, SizeX = true, SizeY = true, SizeZ = true,
               StrategicIconSortPriority = true, Mod = true }
local PROJECTILE_GROUPS = { Physics = true, Display = true, Economy = true, Defense = true }

local function Collect(node, path, depth, out, rootKind)
    if depth > 5 then return end
    local keys = {}
    for k, _ in node do table.insert(keys, k) end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == 'number'
    end)
    for _, k in keys do
        local v = node[k]
        local name = tostring(k)
        if not (depth == 1 and (SKIP[k] or string.find(name, '^Selection') or string.find(name, '^Inertia') or string.find(name, '^Collision') or string.find(name, '^LifeBar'))) then
            local sub = path == '' and name or (path .. '.' .. name)
            if type(v) == 'number' then
                if not (rootKind == 'projectile' and depth == 1) then table.insert(out, { key = sub, value = v }) end
            elseif type(v) == 'table' and not (rootKind == 'projectile' and depth == 1 and not PROJECTILE_GROUPS[k]) then
                Collect(v, sub, depth + 1, out, rootKind)
            end
        end
    end
end

--- The editable numbers of a blueprint. `Base` is bpedit.Base (reads a key of the blueprint of an id).
function Fields(id, Base)
    local kind = Kind(id)
    local bp = Blueprint(id)
    local list = {}
    if not bp then return list end
    local leaves = {}
    Collect(bp, '', 1, leaves, kind)
    for _, leaf in leaves do
        local v = leaf.value
        local dec = (v == math.floor(v)) and 0 or 2
        local magnitude = math.max(10, math.abs(v) * 4)
        if dec == 0 then magnitude = math.ceil(magnitude / 10) * 10 end
        local negative = v < 0 or string.find(leaf.key, 'Curve') ~= nil
        local step = (dec == 0) and 1 or ((math.abs(v) >= 1) and 0.05 or 0.01)
        local group = string.gsub(leaf.key, '%..*$', '')
        table.insert(list, { key = leaf.key, label = leaf.key, group = group, base = v, min = negative and -magnitude or 0, max = magnitude, step = step, dec = dec })
    end
    return list
end

--- The emitter blueprint paths of an effect template (a list of path strings), the template's own table.
function Emitters(template)
    local list = {}
    for _, e in template or {} do
        if type(e) == 'string' then table.insert(list, e) end
    end
    return list
end
