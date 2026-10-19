-- Effect and projectile preview (docs/projects/MOD_UNIT_EDITOR_DESIGN.md, stage S3): the effect templates of /lua/EffectTemplates.lua (a template is a list of emitter blueprints) are played at the lab spot with the
-- game's own emitter system, and a projectile blueprint can be fired from the unit standing there.
--
--   Templates()              list of { name, emitters } sorted by name (module tables whose entries are emitter paths)
--   Play(name, height)       plays every emitter of the template at the lab spot (X, Z of unitview.lua, or the middle of the map);  Last = what was played
--   Targets()                the emitter paths of the template played last, or the projectile fired last (what the Fields tab edits)
--   Projectiles()            list of projectile blueprint ids;  Fire(id, speed)     fires it from the unit of the unit viewer along +z
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local View = import('/lua/editor/unitview.lua')

Last = false          -- what was played / fired last (a template name or a projectile id)
LastKind = false      -- 'effect' | 'projectile'

local templates = false

--- The effect templates: every table of /lua/EffectTemplates.lua whose entries are emitter blueprint paths.
function Templates()
    if templates then return templates end
    local list = {}
    local ok, mod = pcall(import, '/lua/EffectTemplates.lua')
    if ok and mod then
        for name, t in mod do
            if type(name) == 'string' and type(t) == 'table' and t[1] ~= nil then
                local all = true
                for _, e in t do
                    if type(e) ~= 'string' or not string.find(e, '^/effects/') then all = false end
                end
                if all then table.insert(list, { name = name, emitters = t }) end
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    templates = list
    return list
end

local function Spot()
    if View.Id then return View.X, View.Z end
    local w = ed_terrain_info()
    local mid = ((w or 257) - 1) / 2
    return mid + 24, mid
end

function Play(name, height)
    for _, t in Templates() do
        if t.name == name then
            local x, z = Spot()
            local y = (ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0) + (height or 1)
            SimCallback({ Func = 'EdEffect', Args = { emitters = t.emitters, x = x, y = y, z = z, seconds = 6 } }, false)
            Last, LastKind = name, 'effect'
            return table.getn(t.emitters)
        end
    end
    return nil
end

--- The projectile blueprints the game knows (ids are paths below /projectiles/).
function Projectiles()
    local list = {}
    for id, bp in __blueprints or {} do
        if type(id) == 'string' and string.find(id, '^/projectiles/') then table.insert(list, id) end
    end
    table.sort(list)
    return list
end

--- Fires a projectile from the unit of the unit viewer.
function Fire(id, speed)
    if not View.Id then return nil, 'show a unit in the Unit viewer first' end
    SimCallback({ Func = 'EdFire', Args = { projectile = id, bp = View.Id, x = View.X, z = View.Z, speed = speed or 15 } }, false)
    return true
end

--- What the Fields tab can edit now: the emitter blueprint paths of the template that was played, or the projectile that was fired (blueprint ids / paths, see fxedit.lua).
function Targets()
    if LastKind == 'effect' then
        for _, t in Templates() do
            if t.name == Last then return t.emitters end
        end
    elseif LastKind == 'projectile' and Last then
        return { Last }
    end
    return {}
end
