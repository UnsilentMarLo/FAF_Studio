-- "Test in game" for a unit of the open mod project (docs/projects/MOD_UNIT_EDITOR_DESIGN.md, stage S4).
--
--   Begin(id [, opts])    writes the project, remembers the test in modproj/unittest.lua (the session ends when the mod list changes: the Lua state does not survive, a file does), enables the project
--                         and reloads the session; opts = { target = blueprint of the dummy target, targets = n }
--   Resume()              called once per session by the Unit wizard panel: when a test is pending and the unit is in the game, puts the unit under test and the dummy targets on the map and
--                         moves the camera over them; says what is wrong when the unit is not there
--   Command(cmd)          attack | move | patrol | stop | kill | heal | build | clear -> the unit's quick commands (editorsim/unittest.lua); `build` lets a factory or engineer of the game build the unit
--   Respawn()             a new unit and new targets with the same blueprint;  Restart(): writes the project again and reloads the session (the blueprint is read again from disk)
--   Status()              the last status of the sim: { alive, health, max, x, z, orders, targets = { {health, max} }, damage, built, error } or nil;  Stop(): ends the test, takes everything down
--   Active                the id under test or false;  Message: what the panel shows
--
-- Lua 5.0 dialect.

local Bp = import('/lua/editor/bpedit.lua')
local Wiz = import('/lua/editor/unitwiz.lua')
local Safe = import('/lua/editor/safe.lua')

ENEMY = 'UNIT_TEST_TARGETS'      -- the army of the dummy targets (an enemy of ARMY_1), added to the map for the test
Active = false
Message = ''
local statusPath = 'ed_unittest_status.txt'
local resumed = false
local TARGETS = { ground = 'uel0106', structure = 'ueb2101', air = 'uea0101', ship = 'ues0103' }

local function Say(text)
    Message = text
    Safe.Try('unittest:fn26', function() import('/lua/editor/ui.lua').Say(text) end)
end

local function PendingPath() return Bp.ROOT .. '/unittest.lua' end

--- The pending test: { project, unit, target, targets } or nil.
function Pending()
    local text = ed_read_file(PendingPath())
    if not text or text == '' then return nil end
    local fn = loadstring(text)
    if not fn then return nil end
    local env = {}
    setfenv(fn, env)
    Safe.Try('unittest:fn', fn)
    return env.Test
end

local function SavePending(t)
    if not t then
        ed_write_file(PendingPath(), '')
        return
    end
    ed_write_file(PendingPath(), string.format('Test = { project = %q, unit = %q, target = %q, targets = %d }\n', t.project, t.unit, t.target or 'uel0106', t.targets or 2))
end

--- Target blueprint for the kind of unit: air units need an air dummy for anti-air weapons, and so on.
function TargetFor(spec)
    local anti = {}
    for _, w in spec and spec.weapons or {} do anti[w.kind] = true end
    if anti.aa and not anti.direct and not anti.cannon then return TARGETS.air end
    if anti.torpedo then return TARGETS.ship end
    return TARGETS.ground
end

--- The map gets a second army, an enemy of ARMY_1, for the dummy targets (the session reload that applies the mod makes it a real army). Undoable.
local function EnsureEnemy()
    local ok, Armies = pcall(function() return import('/lua/editor/armysetup.lua') end)
    if not ok or not import('/lua/editor/map.lua').Doc then return end
    if not Armies.Get(ENEMY) then Armies.Add(ENEMY) end
    if Armies.Get(ENEMY) then Armies.SetAlliance('ARMY_1', ENEMY, 'Enemy', true) end
end

--- Takes the test army out of the map again.
local function RemoveEnemy()
    local ok, Armies = pcall(function() return import('/lua/editor/armysetup.lua') end)
    if ok and import('/lua/editor/map.lua').Doc and Armies.Get(ENEMY) then Armies.Remove(ENEMY) end
end

local function EnableProject()
    local Mods = import('/lua/editor/mods.lua')
    local UI = import('/lua/editor/ui.lua')
    local uid
    for u, mod in Mods.All() do
        if mod.name == Bp.Project then uid = u end
    end
    if not uid then return nil, 'the engine does not list the project as a mod yet (restart the editor once)' end
    local set = Mods.GetSelection()
    set[uid] = true
    UI.State.modsPending = set
    UI.ApplyMods()
    return true
end

--- Writes the project, remembers the test and reloads the session with the project enabled.
function Begin(id, opts)
    opts = opts or {}
    if not Bp.Project then return nil, 'open or create a mod project first' end
    if not (Bp.NewUnits[id] or Bp.Derived[id]) then return nil, id .. ' is not a unit of the project' end
    local n, why = Bp.Write()
    if not n then return nil, why end
    EnsureEnemy()
    SavePending({ project = Bp.Project, unit = id, target = opts.target or TargetFor(Bp.NewUnits[id]), targets = opts.targets or 2 })
    Active = id
    resumed = false
    local ok, err = EnableProject()
    if not ok then
        SavePending(nil)
        Active = false
        return nil, err
    end
    return true
end

function Restart()
    local p = Pending()
    if not p then return nil, 'no test is running' end
    return Begin(p.unit, { target = p.target, targets = p.targets })
end

--- The camera over the test.
local function Look(x, z)
    local cam = GetCamera('WorldCamera')
    if cam then cam:MoveToRegion(Rect(x - 40, z - 20, x + 40, z + 55), 0.4) end
end

local function Place()
    local View = import('/lua/editor/unitview.lua')
    local x, z = View.LabSpot()
    return x, z
end

--- Puts the unit and its targets on the map.
function Spawn()
    local p = Pending()
    if not p then return nil, 'no test is running' end
    local x, z = Place()
    ed_write_file(statusPath, '')
    local army
    local ok, Armies = pcall(function() return import('/lua/editor/armysetup.lua') end)
    if ok and Armies.Get(ENEMY) then army = ENEMY end
    SimCallback({ Func = 'EdTestSpawn', Args = { bp = p.unit, x = x, z = z, heading = 0, targetBp = p.target, targets = p.targets or 2, distance = 28, path = statusPath, targetArmy = army } }, false)
    Active = p.unit
    Look(x, z)
    return true
end

--- Called once per session: continues a test that reloaded the session.
function Resume()
    if resumed then return end
    resumed = true
    local p = Pending()
    if not p then return end
    if not (__blueprints and __blueprints[p.unit]) then
        -- a test left over from an earlier run of the editor (the project is not enabled now), or a blueprint that failed to load: say so once and forget it
        Say('test: the game does not know ' .. p.unit .. ' (the project is not enabled in this session, or its blueprint failed to load: see the log); the test is ended')
        SavePending(nil)
        RemoveEnemy()
        Active = false
        return
    end
    if p.project ~= Bp.Project then
        -- another project is open than the one under test (the session was reloaded: the Lua state starts empty)
        local ok = Bp.Open(p.project)
        if not ok then SavePending(nil) return end
    end
    Active = p.unit
    local ok, why = Spawn()
    Say(ok and ('testing ' .. p.unit .. ': attack, move, patrol or build it from a factory below') or ('test: ' .. tostring(why)))
end

--- The factory / engineer of the game that builds the unit: first of the matching builders that is a factory (mobile units) or an engineer (structures) of the unit's faction.
function BuilderFor(id)
    local bp = __blueprints and __blueprints[id]
    if not bp then return nil end
    local Check = import('/lua/editor/unitcheck.lua')
    local set = {}
    for _, c in bp.Categories or {} do set[string.upper(c)] = true end
    local structure = set.STRUCTURE
    local best
    for _, builderId in Check.Builders(set) do
        local b = __blueprints[builderId]
        if b and b.Categories then
            local cat = {}
            for _, c in b.Categories do cat[c] = true end
            local good
            if structure then good = cat.ENGINEER and cat.MOBILE and not cat.COMMAND and not cat.SUBCOMMAND else good = cat.FACTORY and cat.STRUCTURE end
            if good and not cat.SUPPORTFACTORY and string.sub(builderId, 1, 1) ~= 'z' then
                if not best then best = builderId end
                if string.sub(builderId, 4, 4) == '0' and string.sub(builderId, 5, 5) == '1' then best = builderId break end        -- the tech 1 factory / engineer
            end
        end
    end
    return best, structure
end

local statusRead = 0

--- Sends a quick command to the unit under test.
function Command(cmd, args)
    local p = Pending()
    if not p then return nil, 'no test is running' end
    local x, z = Place()
    local a = { cmd = cmd, path = statusPath, x = x, z = z + 14, x2 = x + 22, z2 = z + 14 }
    if cmd == 'move' then a.x, a.z = x + (args and args.dx or 18), z + (args and args.dz or -18) end
    if cmd == 'patrol' then a.x, a.z, a.x2, a.z2 = x - 24, z - 10, x + 24, z - 10 end
    if cmd == 'build' then
        local builder, structure = BuilderFor(p.unit)
        if not builder then return nil, 'no factory or engineer of the game can build ' .. p.unit .. ' (see the Validation panel: build menu)' end
        a.builder, a.structure, a.bp = builder, structure, p.unit
        Say('build: ' .. builder .. ' builds ' .. p.unit)
    end
    SimCallback({ Func = 'EdTestCommand', Args = a }, false)
    return true
end

function Respawn()
    local ok, why = Spawn()
    return ok, why
end

function Refresh()
    SimCallback({ Func = 'EdTestStatus', Args = { path = statusPath } }, false)
end

--- The last status the sim wrote, or nil.
function Status()
    local text = ed_read_file(statusPath)
    if not text or text == '' or string.sub(text, 1, 4) == 'none' then return nil end
    local s = { targets = {}, orders = 0, damage = 0, built = 0 }
    for line in string.gfind(text, '[^\n]+') do
        local s1, e1, k, rest = string.find(line, '^(%a+)%s*(.*)$')
        if k == 'unit' then
            local _, _, alive, health, max = string.find(rest, '^(%d)%s+([%-%d%.]+)%s+([%-%d%.]+)')
            s.alive, s.health, s.max = alive == '1', tonumber(health), tonumber(max)
        elseif k == 'pos' then
            local _, _, px, pz = string.find(rest, '^([%-%d%.]+)%s+([%-%d%.]+)')
            s.x, s.z = tonumber(px), tonumber(pz)
        elseif k == 'orders' then s.orders = tonumber(rest) or 0
        elseif k == 'target' then
            local _, _, i, h, m = string.find(rest, '^(%d+)%s+([%-%d%.]+)%s+([%-%d%.]+)')
            if i then s.targets[tonumber(i)] = { health = tonumber(h), max = tonumber(m) } end
        elseif k == 'damage' then s.damage = tonumber(rest) or 0
        elseif k == 'built' then s.built = tonumber(rest) or 0
        elseif k == 'error' then s.error = rest
        end
    end
    return s
end

--- Ends the test: takes the units down and forgets the pending test (the project stays enabled for this session).
function Stop()
    SimCallback({ Func = 'EdTestCommand', Args = { cmd = 'clear', path = statusPath } }, false)
    SavePending(nil)
    RemoveEnemy()
    Active = false
end
