-- A mission script EXECUTED without the game: the compiled script of every sim-test case is run in the editor's own Lua VM against a fake game, with real coroutines as sim
-- threads and a virtual clock. The fake modules know exactly the functions of the game's own Lua (data/faf_mission_api.lua, made by scripts/editor_mission_api.py from lua.nx2):
-- a call of a function the game does not have, or with more arguments than it takes, is a failure; a thread that raises is a failure. The nodes the script reaches are compared with
-- what the case expects (the same expectation as the real sim test, selftest_missionsim.lua, which also checks the real functions' effects).
--
--   Run()                          the selftest: every case, test flavor and saved-map flavor
--   Execute(text, opts)            runs one script text -> result { problems = {}, trace = {}, calls = {}, ended, flags, ... }
--
-- What this does NOT show (only the sim test does): that the real ScenarioFramework / Objectives functions do what the node means with real units, real armies, real objectives.
-- Lua 5.0 dialect.

local M = import('/lua/editor/mission.lua')
local Sim = import('/lua/editor/selftest_missionsim.lua')
local API = import('/lua/editor/data/faf_mission_api.lua')

local out, failed = {}, 0
local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local ARMIES = { ARMY_1 = 1, Enemy = 2, Player1 = 3 }
local NAMES = { 'ARMY_1', 'Enemy', 'Player1' }

--- A script text run against the fake game. opts = { ticks = virtual ticks to run (default 6000), editor = ScenarioInfo.Options.EditorMode }.
function Execute(text, opts)
    opts = opts or {}
    local R = { problems = {}, trace = {}, calls = {}, ended = nil, flags = {}, objectives = {}, threads = 0 }
    local now = 0
    local threads = {}
    local current = nil
    local function Problem(text) if table.getn(R.problems) < 40 then table.insert(R.problems, text) end end

    -- ---- fake units, platoons, brains -----------------------------------------------------------------------------------------------------------
    local deathWatch = {}
    local function NewUnit(army)
        local u = { Dead = false, army = army }
        u.Kill = function(self) self.Dead = true for _, cb in deathWatch[self] or {} do cb(self) end end
        u.GetArmy = function(self) return self.army end
        u.GetPosition = function(self) return { 1, 0, 1 } end
        u.SetCustomName = function() end
        u.GiveNukeSiloAmmo = function() end
        return u
    end
    local function NewGroup(army, n)
        local g = {}
        for i = 1, n do table.insert(g, NewUnit(army)) end
        return g
    end
    local anyMethod = { __index = function(t, name)
        return function(self, a, b, c) R.calls['method:' .. name] = (R.calls['method:' .. name] or 0) + 1 return self end
    end }
    local function Loose() return setmetatable({}, anyMethod) end

    local brains = {}
    local function Brain(name)
        if brains[name] then return brains[name] end
        local b = { Name = name, Nickname = name }
        b.GetArmyIndex = function() return ARMIES[name] or 0 end
        b.GetFactionIndex = function() return 1 end
        b.GiveResource = function(self, kind, amount) R.calls['GiveResource'] = (R.calls['GiveResource'] or 0) + 1 end
        b.GetListOfUnits = function(self) return { NewUnit(ARMIES[name]) } end
        b.PBMRemoveBuilder = function() end
        b.PBMAddBuildLocation = function() end
        brains[name] = b
        return b
    end
    local ArmyBrains = {}
    for i, name in NAMES do ArmyBrains[i] = Brain(name) end

    -- ---- fake game modules, built from the game's own function list ----------------------------------------------------------------------------------
    local function Recorder(mod, name, params, impl)
        return function(a1, a2, a3, a4, a5, a6, a7, a8, a9)
            local list = { a1, a2, a3, a4, a5, a6, a7, a8, a9 }
            local n = 0
            for i = 1, 9 do if list[i] ~= nil then n = i end end
            if params >= 0 and n > params then Problem(mod .. '.' .. name .. ' is called with ' .. n .. ' arguments, the game\'s function takes ' .. params) end
            local key = mod .. '.' .. name
            R.calls[key] = (R.calls[key] or 0) + 1
            if impl then return impl(a1, a2, a3, a4, a5, a6, a7, a8) end
            return nil
        end
    end
    local function Module(mod, impls)
        local m = {}
        for name, params in API[mod] do m[name] = Recorder(mod, name, params, impls and impls[name]) end
        setmetatable(m, { __index = function(t, name)
            Problem(mod .. '.' .. name .. ' does not exist in the game\'s Lua')
            return function() end
        end })
        return m
    end

    local objectives = {}
    local Objectives
    local function NewObjective(kind, Target, title)
        local o = { Active = true, Title = title, kind = kind, Target = Target or {}, born = now, ResultCallbacks = {} }
        o.AddResultCallback = function(self, cb) table.insert(self.ResultCallbacks, cb) end
        o.Finish = function(self, result)
            if not self.Active then return end
            self.Active = false
            for _, cb in self.ResultCallbacks do cb(result) end
        end
        o.ManualResult = function(self, result) self:Finish(result) end
        table.insert(objectives, o)
        table.insert(R.objectives, o)
        return o
    end
    local function Objective(kind)
        return function(Type, Complete, Title, Description, Target) return NewObjective(kind, Target, Title) end
    end
    Objectives = Module('Objectives', {
        Kill = Objective('kill'), Protect = Objective('protect'), Timer = Objective('timer'),
        CategoriesInArea = function(Type, Complete, Title, Description, Action, Target) return NewObjective('area', Target, Title) end,
        CreateGroup = function(name, callback)
            local g = { objs = {} }
            g.AddObjective = function(self, o)
                table.insert(self.objs, o)
                o:AddResultCallback(function(result)
                    for _, x in self.objs do if x.Active then return end end
                    if callback then callback() end
                end)
            end
            return g
        end,
    })

    local ScenarioUtils = Module('ScenarioUtils', {
        CreateArmyGroup = function(army, group) return NewGroup(ARMIES[army] or 2, 2) end,
        CreateArmyGroupAsPlatoon = function(army, group) return Loose() end,
        CreateArmyUnit = function(army, name) return NewUnit(ARMIES[army] or 2) end,
        MarkerToPosition = function(name) return { 10, 0, 10 } end,
        GetMarker = function(name) return { position = { 10, 0, 10 } } end,
        AreaToRect = function(area) return { x0 = 0, y0 = 0, x1 = 100, y1 = 100 } end,
        FindUnitGroup = function() return {} end,
    })
    local SF = Module('ScenarioFramework', {
        EndOperation = function(success) R.ended = { success = success and true or false } end,
        CreateUnitDeathTrigger = function(cb, unit)
            deathWatch[unit] = deathWatch[unit] or {}
            table.insert(deathWatch[unit], cb)
        end,
        CreateGroupDeathTrigger = function(cb, group)
            for _, u in group do
                deathWatch[u] = deathWatch[u] or {}
                table.insert(deathWatch[u], function()
                    for _, x in group do if not x.Dead then return end end
                    cb()
                end)
            end
        end,
        CreateSubGroupDeathTrigger = function(cb, group, num)
            local dead = 0
            for _, u in group do
                deathWatch[u] = deathWatch[u] or {}
                table.insert(deathWatch[u], function() dead = dead + 1 if dead == num then cb() end end)
            end
        end,
        Dialogue = function() end,
        SpawnCommander = function(brain, unit) return NewUnit(ARMIES[brain] or 3) end,
    })
    rawset(SF, 'Objectives', Objectives)
    local Cinematics = Module('Cinematics')

    -- the coop support mod: defined when the script's coop shim is installed (rawget in the generated code)
    local coop = { 'SetSharedUnitCap', 'AddRestrictionForAllHumans', 'RemoveRestrictionForAllHumans', 'SimAnnouncement', 'PlayerDeath' }
    local function InstallCoop()
        for _, name in coop do
            if API.Coop[name] then rawset(SF, name, Recorder('ScenarioFramework', name, API.Coop[name])) end
        end
    end

    local modules = {
        ['/lua/sim/scenarioutilities.lua'] = ScenarioUtils,
        ['/lua/scenarioframework.lua'] = SF,
        ['/lua/cinematics.lua'] = Cinematics,
        ['/lua/ai/opai/basemanager.lua'] = { CreateBaseManager = function() return Loose() end },
        ['/lua/editor/coopshim.lua'] = { Install = InstallCoop },
        ['/lua/editorsim/mission.lua'] = { Attach = function() end },
    }

    -- ---- the scheduler: coroutines as sim threads, a virtual clock in ticks ---------------------------------------------------------------------------
    local function Resume(t)
        local previous = current
        current = t
        local ok, err = coroutine.resume(t.co)
        current = previous
        if not ok then Problem('a thread raised: ' .. tostring(err)) t.dead = true
        elseif coroutine.status(t.co) == 'dead' then t.dead = true end
    end
    local function Fork(fn, a1, a2, a3)
        local t = { wake = now, dead = false }
        t.co = coroutine.create(function() fn(a1, a2, a3) end)
        R.threads = R.threads + 1
        table.insert(threads, t)
        Resume(t)       -- (a forked thread runs at once until its first wait)
        return t
    end
    local function WaitTicks(n)
        if not current then Problem('a wait outside of a thread') return end
        current.wake = now + math.max(1, math.ceil(n or 1))
        coroutine.yield()
    end

    local categoryMeta = {}
    categoryMeta.__add = function(a, b) return a end
    categoryMeta.__sub = function(a, b) return a end
    categoryMeta.__mul = function(a, b) return a end
    local categories = setmetatable({}, { __index = function(t, k) return setmetatable({ name = k }, categoryMeta) end })

    local ScenarioInfo = { Options = { Difficulty = 2, EditorMode = opts.editor and true or false }, VarTable = {}, UnitNames = {}, HumanPlayers = {}, EditorPlaying = true }
    for index, name in NAMES do ScenarioInfo.UnitNames[index] = {} end
    ScenarioInfo.UnitNames[2].SIM_U9 = NewUnit(2)
    ScenarioInfo.UnitNames[1].UNIT_A1 = NewUnit(1)          -- an INITIAL unit of ARMY_1 (the game's army setup registers it)

    local env = {
        ScenarioInfo = ScenarioInfo, ArmyBrains = ArmyBrains, categories = categories,
        import = function(path)
            local m = modules[string.lower(path)]
            if not m then Problem('import of an unknown module ' .. tostring(path)) return {} end
            return m
        end,
        ForkThread = Fork,
        WaitSeconds = function(s) WaitTicks((tonumber(s) or 0) * 10) end,
        WaitTicks = WaitTicks,
        GetGameTick = function() return now end,
        GetGameTimeSeconds = function() return now / 10 end,
        Random = function() return 0.5 end,
        LOG = function() end,
        WARN = function(...) R.warned = (R.warned or 0) + 1 end,
        GetArmyBrain = function(name)
            if not ARMIES[name] and type(name) == 'string' then Problem('GetArmyBrain of an army that does not exist: ' .. name) end
            return Brain(name)
        end,
        SetAlliance = function(a, b, state) R.calls['SetAlliance'] = (R.calls['SetAlliance'] or 0) + 1 end,
        IssueNuke = function() R.calls['IssueNuke'] = (R.calls['IssueNuke'] or 0) + 1 end,
        GetUnitsInRect = function(rect) return { NewUnit(1), NewUnit(1) } end,
        EntityCategoryContains = function() return true end,
        ParseEntityCategory = function(s) return setmetatable({ name = s }, categoryMeta) end,
        Scenario = { Armies = { ARMY_1 = { Units = {} }, Enemy = { Units = {} }, Player1 = { Units = {} } } },
        tostring = tostring, tonumber = tonumber, type = type, pairs = pairs, ipairs = ipairs, next = next, rawget = rawget, rawset = rawset, unpack = unpack,
        math = math, string = string, error = error, pcall = pcall, loadstring = loadstring, setmetatable = setmetatable,
    }
    env.table = {}
    for k, v in table do env.table[k] = v end
    env.table.getsize = function(t) local n = 0 for _ in t do n = n + 1 end return n end
    env.ScenarioInfo.Options.Difficulty = 2

    local f, err = loadstring(text)
    if not f then Problem('the script does not load: ' .. tostring(err)) return R end
    setfenv(f, env)
    local okc, errc = pcall(f)
    if not okc then Problem('the script raised when it was loaded: ' .. tostring(errc)) return R end
    if env.OnPopulate then local ok, e = pcall(env.OnPopulate) if not ok then Problem('OnPopulate raised: ' .. tostring(e)) end end
    if env.OnStart then local ok, e = pcall(env.OnStart, {}) if not ok then Problem('OnStart raised: ' .. tostring(e)) end end

    -- the trace of a test script goes through EdTrace -> ScenarioInfo.EditorMission.Trace
    local limit = opts.ticks or 6000
    while now < limit do
        -- objectives the fake game decides on its own: a kill objective when its units are dead, a timer when it runs out, an area one soon, a protect one by hand
        for oi = 1, table.getn(objectives) do
            local o = objectives[oi]
            if o.Active then
                if o.kind == 'kill' then
                    local all = true
                    for _, u in o.Target.Units or {} do if not u.Dead then all = false end end
                    if all then o:Finish(true) end
                elseif o.kind == 'timer' then
                    if now - o.born >= (tonumber(o.Target.Timer) or 1) * 10 then o:Finish(o.Target.ExpireResult ~= 'failed') end
                elseif o.kind == 'area' then
                    if now - o.born >= 20 then o:Finish(true) end
                end
            end
        end
        for ti = 1, table.getn(threads) do
            local t = threads[ti]
            if not t.dead and t.wake <= now then Resume(t) end
        end
        local alive = false
        for _, t in threads do if not t.dead then alive = true end end
        local m = ScenarioInfo.EditorMission
        if not alive and not objectives[1] then break end
        now = now + 1
    end
    local m = ScenarioInfo.EditorMission
    if m then
        for i = 1, m.TraceCount or 0 do R.trace[m.Trace[i]] = true end
    end
    R.flags = ScenarioInfo.VarTable
    R.ticks = now
    R.env = env
    return R
end

--- The sim-test cases through the fake game.
function Run()
    out, failed = {}, 0
    local saved = M.Data
    for _, case in Sim.Cases do
        local ok, expect = pcall(Sim.Build, case)
        if not ok then
            Check(false, 'case ' .. case .. ' builds: ' .. tostring(expect))
        else
            local text = M.Compile(true, { test = true })
            local R = Execute(text, { editor = true })
            Check(table.getn(R.problems) == 0, 'case ' .. case .. ' (test run script) runs without a problem (' .. table.concat(R.problems, ' | ') .. ')')
            local missing = {}
            for _, n in expect.nodes do if not R.trace[n.addr] then table.insert(missing, n.addr .. ' ' .. n.type) end end
            for _, b in expect.bodies do if not R.trace[b] then table.insert(missing, b) end end
            Check(table.getn(missing) == 0, 'case ' .. case .. ': every expected node is reached (missing: ' .. table.concat(missing, ', ') .. ')')
            if expect.ended then Check(R.ended ~= nil and R.ended.success == expect.success, 'case ' .. case .. ': the operation ends ' .. (expect.success and 'with a win' or 'with a loss')) end
            for name, want in expect.flags do Check(R.flags[name] == want, 'case ' .. case .. ': flag ' .. name .. ' = ' .. tostring(want) .. ' (got ' .. tostring(R.flags[name]) .. ')') end
            for name, _ in expect.noflags do Check(R.flags[name] == nil, 'case ' .. case .. ': flag ' .. name .. ' stays unset') end
            for _, d in expect.dropped do Check(R.trace[d], 'case ' .. case .. ': ' .. d .. ' (a trigger of a stage that was left is dropped, visibly)') end
            -- the same mission as a saved map: no hooks, real waits; it must run to the same end
            local plain = Execute(M.Compile(true), { editor = false, ticks = 6000 })
            Check(table.getn(plain.problems) == 0, 'case ' .. case .. ' (saved map script) runs without a problem (' .. table.concat(plain.problems, ' | ') .. ')')
            if expect.ended then Check(plain.ended ~= nil and plain.ended.success == expect.success, 'case ' .. case .. ' (saved map script) ends the same way') end
        end
    end
    M.Data = saved
    Sim.Clear()
    table.insert(out, failed == 0 and 'ALL PASS' or (failed .. ' FAILED'))
    return table.concat(out, '\n')
end
