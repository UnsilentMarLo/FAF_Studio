-- Missions that are RUN: the cases of the sim test (scripts/editor_mission_sim.py). Each case builds a small mission that uses a family of the catalogue's node types over a fixed
-- test world, and says what a test run of it must show: which nodes the script reached (the test copy traces every node, mission.lua Compile {test=true}), which trigger bodies
-- ran, the flags, the units of the armies, how the operation ended. The driver plays a case, polls the sim (missionrun.lua) and calls Verify until it says done / fail.
--
--   Prepare(case)     builds the world and the mission of the case, requests a play test (the session reloads with the test copy)
--   Verify(case)      after the reload: polls the sim and compares -> 'done' | 'wait <what is missing>' | 'fail <what is wrong>'
--   Run()             the selftest (no sim): every case builds, has no findings, both flavors compile and load, every node type of the catalogue is used by some case,
--                     the dry run (selftest_missiondry.lua) executes the compiled scripts
--
-- Lua 5.0 dialect.

local M = import('/lua/editor/mission.lua')
local Map = import('/lua/editor/map.lua')
local A = import('/lua/editor/armysetup.lua')
local Tools = import('/lua/editor/tools.lua')

Cases = { 'actions', 'flow', 'triggers', 'objectives', 'platoons', 'cutscene', 'coop', 'bases' }

--- The cases whose failure is a failure of the nightly (the others are reported only): all of them, but a case can be moved here when it cannot run in an editor session.
Soft = {}

local out, failed = {}, 0
local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

-- ---- the test world -------------------------------------------------------------------------------------------------------------------------------

local function Group(units)
    return { type = 'GROUP', orders = '', platoon = '', Units = units or {} }
end

local function Unit(bp, x, z)
    return { type = bp, orders = '', platoon = '', Position = { x, 0, z }, Orientation = { 0, 0, 0 } }
end

local function Units(bp, n, x, z)
    local list = {}
    for i = 1, n do list['UNIT_' .. i] = Unit(bp, x + i * 3, z) end
    return list
end

--- The armies, groups, markers, chains and areas the cases use. Safe to call again (it only adds what is missing).
function World()
    if not Map.Doc then Map.Load() end
    for _, name in { 'Enemy', 'Player1' } do
        if not A.Get(name) then A.Add(name) end
    end
    local save = Map.Doc.save
    local enemy = save.Armies.Enemy.Units.Units
    enemy.INITIAL.Units = { UNIT_9 = Unit('uel0106', 200, 200) }       -- (exactly these: leftovers of other tests in the open map would change the unit counts)
    enemy.WAVE1 = Group(Units('uel0106', 3, 150, 150))
    for d = 1, 3 do enemy['WAVE1_D' .. d] = Group(Units('uel0106', 1, 150, 150)) end
    enemy.WAVE2 = Group(Units('uel0106', 2, 160, 140))
    enemy.NUKE = Group({ UNIT_1 = Unit('uab2305', 215, 215) })
    enemy.TDROP = Group({ UNIT_1 = Unit('uea0107', 190, 190), UNIT_2 = Unit('uel0106', 192, 190), UNIT_3 = Unit('uel0106', 194, 190) })
    enemy.DEF1 = Group({ UNIT_1 = Unit('ueb1101', 205, 150) })
    save.Armies.ARMY_1.Units.Units.INITIAL.Units = { UNIT_A1 = Unit('uel0106', 80, 80) }
    save.Armies.Player1.Units.Units.INITIAL.Units = { Commander = Unit('uel0001', 30, 30) }

    local markers = save.MasterChain._MASTERCHAIN_.Markers
    local function Marker(name, kind, x, z)
        if not markers[name] then Tools.PlaceMarker(x, z, kind, name) end
    end
    Marker('PATROL_1', 'Blank Marker', 150, 150)
    Marker('PATROL_2', 'Blank Marker', 175, 175)
    Marker('LAND_1', 'Blank Marker', 120, 200)
    Marker('NUKE_TGT', 'Blank Marker', 235, 235)
    Marker('VIEW_1', 'Blank Marker', 100, 220)
    Marker('CAM_1', 'Camera Info', 100, 100)
    Marker('BASE_1', 'Blank Marker', 205, 150)
    save.Chains = save.Chains or {}
    save.Chains.PATROL = { Markers = { 'PATROL_1', 'PATROL_2' } }
    save.Chains.LANDING = { Markers = { 'LAND_1' } }
    save.Areas = save.Areas or {}
    save.Areas.TRG_AREA = { rectangle = { 60, 60, 110, 110, type = 'RECTANGLE' } }
    save.Areas.PLAY_AREA = { rectangle = { 10, 10, 245, 245, type = 'RECTANGLE' } }
    save.Areas.CAM_AREA = { rectangle = { 90, 90, 130, 130, type = 'RECTANGLE' } }

    local PL = import('/lua/editor/platoons.lua')
    if not save.Platoons or not save.Platoons.TPL1 then
        PL.NewPlatoon('TPL1', '')
        PL.AddRow('TPL1', { 'uel0106', 0, 2 })
    end
    if not save.Orders or not save.Orders.ORD1 then
        PL.NewOrders('ORD1')
        PL.AddOrder('ORD1', { type = 'Patrol', chain = 'PATROL' })
    end
    if not PL.Builders('Enemy') or not PL.Builders('Enemy').BLD1 then PL.NewBuilder('Enemy', 'BLD1', 'TPL1') end
end

-- ---- building a case -------------------------------------------------------------------------------------------------------------------------------

local B       -- the case being built: { nodes = { { addr, type } }, callbacks, ... }

local function Fresh(mode)
    World()
    M.Data = { mode = mode or 'campaign', stages = {}, bases = {}, dialogues = {} }
    M.AddDialogue('INTRO')
    M.AddLine(1, 'Commander, the test run is on.')
    B = { nodes = {}, bodies = {}, dropped = {}, flags = {}, noflags = {}, units = {}, vars = {}, types = {} }
    return B
end

local function Stage(name, failsafe)
    local ok, why = M.AddStage(name)
    if not ok then error('AddStage failed: ' .. tostring(why)) end
    local i = table.getn(M.Data.stages)
    if failsafe then M.SetStage(i, 'failsafe', failsafe) end
    return i
end

--- Adds a node (an error, not a silent nil, when the catalogue refuses it) and remembers its address; returns the path and the address.
local function Node(stage, section, id, params, parent)
    local ok, path = M.AddNode(stage, section, id, nil, parent)
    if not ok then error('AddNode ' .. tostring(id) .. ' failed: ' .. tostring(path)) end
    for k, v in params or {} do
        local r, why = M.SetParam(stage, section, path, k, v)
        if not r then error('SetParam ' .. tostring(id) .. '.' .. tostring(k) .. ' failed: ' .. tostring(why)) end
    end
    local parts = {}
    for _, i in path do table.insert(parts, tostring(i)) end
    local addr = stage .. '.' .. section .. '.' .. table.concat(parts, '.')
    table.insert(B.nodes, { addr = addr, type = id })
    B.types[id] = true
    return path, addr
end

local function Body(addr) table.insert(B.bodies, addr .. '!') end

-- ---- the cases ---------------------------------------------------------------------------------------------------------------------------------------

local function Actions()
    Fresh('campaign')
    local s = Stage('Actions')
    Node(s, 'ready', 'set_alliance', { army = 'Enemy', other = 'ARMY_1', state = 'Ally' })
    Node(s, 'ready', 'set_alliance', { army = 'ARMY_1', other = 'Enemy', state = 'Ally' })
    Node(s, 'ready', 'spawn', { army = 'Enemy', group = 'WAVE1', var = 'w1' })
    Node(s, 'ready', 'spawn', { army = 'Enemy', group = 'WAVE1', bydiff = true, var = 'w2' })
    Node(s, 'ready', 'spawn', { army = 'Enemy', group = 'NUKE', var = 'nk' })
    Node(s, 'ready', 'platoon_patrol', { army = 'Enemy', group = 'WAVE2', chain = 'PATROL', var = 'p1' })
    Node(s, 'ready', 'group_patrol', { var = 'w1', chain = 'PATROL' })
    Node(s, 'ready', 'dialogue', { text = 'Mission text node', seconds = 1 })
    Node(s, 'ready', 'dialogue_table', { name = 'INTRO' })
    Node(s, 'ready', 'restrict', { mode = 'restrict', army = 'ARMY_1', categories = 'categories.TECH3' })
    Node(s, 'ready', 'restrict', { mode = 'allow', army = 'ARMY_1', categories = 'categories.TECH3' })
    Node(s, 'ready', 'resources', { army = 'ARMY_1', mass = 500, energy = 800 })
    Node(s, 'ready', 'playable', { area = 'PLAY_AREA' })
    Node(s, 'ready', 'vision', { marker = 'VIEW_1', radius = 20, seconds = 3, army = 'ARMY_1' })
    Node(s, 'ready', 'set_flag', { flag = 'GOFLAG', value = true })
    Node(s, 'ready', 'set_flag', { flag = 'OFFFLAG', value = false })
    Node(s, 'ready', 'taunt', { head = 1, taunt = 1 })
    Node(s, 'ready', 'nuke_barrage', { var = 'nk', marker = 'NUKE_TGT', count = 1, spread = 5, fill = true })
    Node(s, 'ready', 'kill_group', { var = 'w2' })
    Node(s, 'ready', 'give_group', { var = 'w1', army = 'ARMY_1' })
    Node(s, 'ready', 'raw', { code = 'V.rawran = true' })
    Node(s, 'ready', 'end', { result = 'win' })
    B.flags.GOFLAG = true
    B.flags.OFFFLAG = false
    B.vars.rawran = 'boolean'
    B.ended = true B.success = true
    B.rel = { ['2>1'] = 'ally', ['1>2'] = 'ally' }
    B.eco = { ARMY_1 = { mass = 300, energy = 500 } }
    B.units = { ARMY_1 = { min = 4 }, Enemy = { min = 3 } }       -- UNIT_A1 + the group given away; UNIT_9, the launcher, the platoon (the killed group is gone)
    B.playable = true
    B.stage = 1
    return B
end

local function Flow()
    Fresh('campaign')
    local s1 = Stage('Flow one')
    Node(s1, 'ready', 'spawn', { army = 'Enemy', group = 'WAVE1', var = 'w1' })
    Node(s1, 'ready', 'wait', { seconds = 1 })
    local t, taddr = Node(s1, 'ready', 'trg_timer', { seconds = 2 })
    Body(taddr)
    Node(s1, 'ready', 'kill_group', { var = 'w1' }, t)
    Node(s1, 'ready', 'wait_dead', { var = 'w1', remaining = 0 })
    local d = Node(s1, 'ready', 'if_difficulty', { compare = '>=', level = 1 })
    Node(s1, 'ready', 'dialogue', { text = 'difficulty branch', seconds = 0 }, d)
    local p = Node(s1, 'ready', 'if_players', { compare = '>=', count = 1 })
    Node(s1, 'ready', 'set_flag', { flag = 'IFPLAYERS', value = true }, p)
    Node(s1, 'ready', 'if_difficulty', { compare = '>', level = 3 })       -- never true: its body must NOT run
    Node(s1, 'ready', 'wait_area', { area = 'TRG_AREA', army = 'ARMY_1', category = 'categories.ALLUNITS', compare = '>=', value = 1 })
    Node(s1, 'ready', 'next_stage', {})
    local s2 = Stage('Flow two', 2)
    Node(s2, 'ready', 'dialogue', { text = 'stage two', seconds = 0 })
    Node(s2, 'ready', 'wait', { seconds = 30 })
    local s3 = Stage('Flow three')
    Node(s3, 'ready', 'end', { result = 'lose' })
    B.flags.IFPLAYERS = true
    B.ended = true B.success = false
    B.stage = 3
    B.units = { Enemy = { max = 1 } }
    -- the empty branch of the impossible difficulty is reached but has no children to trace
    return B
end

local function Triggers()
    Fresh('campaign')
    local s1 = Stage('Triggers one', 7)
    Node(s1, 'ready', 'spawn', { army = 'Enemy', group = 'WAVE1', var = 'w1' })
    local t1, a1 = Node(s1, 'ready', 'trg_timer', { seconds = 2 })
    Body(a1)
    Node(s1, 'ready', 'dialogue', { text = 'timer fired', seconds = 0 }, t1)
    Node(s1, 'ready', 'set_flag', { flag = 'T1', value = true }, t1)
    local g, ga = Node(s1, 'ready', 'trg_group_dead', { var = 'w1', count = 0 })
    Body(ga)
    Node(s1, 'ready', 'set_flag', { flag = 'GD', value = true }, g)
    local g2, ga2 = Node(s1, 'ready', 'trg_group_dead', { var = 'w1', count = 2 })
    Body(ga2)
    Node(s1, 'ready', 'set_flag', { flag = 'GD2', value = true }, g2)
    local u, ua = Node(s1, 'ready', 'trg_unit_killed', { army = 'Enemy', unit = 'UNIT_9' })
    Body(ua)
    Node(s1, 'ready', 'set_flag', { flag = 'UK', value = true }, u)
    local ar, aa = Node(s1, 'ready', 'trg_area', { area = 'TRG_AREA', army = 'ARMY_1', category = 'categories.ALLUNITS', compare = '>=', value = 1, once = true })
    Body(aa)
    Node(s1, 'ready', 'set_flag', { flag = 'TA', value = true }, ar)
    local ar2, aa2 = Node(s1, 'ready', 'trg_area', { area = 'TRG_AREA', army = 'ARMY_1', category = 'categories.ALLUNITS', compare = '>=', value = 1, once = false })
    Body(aa2)
    Node(s1, 'ready', 'set_flag', { flag = 'TA2', value = true }, ar2)
    local k1, ka = Node(s1, 'ready', 'trg_timer', { seconds = 3 })
    Body(ka)
    Node(s1, 'ready', 'raw', { code = "ScenarioInfo.UnitNames[GetArmyBrain('Enemy'):GetArmyIndex()]['UNIT_9']:Kill()" }, k1)
    local k2, kb = Node(s1, 'ready', 'trg_timer', { seconds = 4 })
    Body(kb)
    Node(s1, 'ready', 'kill_group', { var = 'w1' }, k2)
    -- stage only (default): the stage is left after 7 s, the timer of 9 s is dropped (traced '~'); stageOnly = false keeps it
    local late, la = Node(s1, 'ready', 'trg_timer', { seconds = 9 })
    table.insert(B.dropped, la .. '~')
    Node(s1, 'ready', 'set_flag', { flag = 'LATE', value = true }, late)
    table.remove(B.nodes)       -- (the body of the dropped timer must never run: not an expected node)
    local late2, la2 = Node(s1, 'ready', 'trg_timer', { seconds = 9, stageOnly = false })
    Body(la2)
    Node(s1, 'ready', 'set_flag', { flag = 'LATE2', value = true }, late2)
    local s2 = Stage('Triggers two')
    Node(s2, 'ready', 'wait', { seconds = 4 })
    Node(s2, 'ready', 'end', { result = 'win' })
    B.flags.T1 = true B.flags.GD = true B.flags.GD2 = true B.flags.UK = true B.flags.TA = true B.flags.TA2 = true B.flags.LATE2 = true
    B.noflags.LATE = true
    B.ended = true B.success = true
    B.stage = 2
    B.units = { Enemy = { max = 1 } }
    return B
end

local function Objectives()
    Fresh('campaign')
    local s1 = Stage('Objectives one')
    Node(s1, 'ready', 'spawn', { army = 'Enemy', group = 'WAVE1', var = 'w1' })
    Node(s1, 'ready', 'obj_kill', { var = 'w1', name = 'k1', title = 'Kill the wave', description = 'Destroy it.' })
    local r, ra = Node(s1, 'ready', 'trg_objective', { objective = 'k1', result = 'complete' })
    Body(ra)
    Node(s1, 'ready', 'set_flag', { flag = 'K1DONE', value = true }, r)
    local k, ka = Node(s1, 'ready', 'trg_timer', { seconds = 2 })
    Body(ka)
    Node(s1, 'ready', 'kill_group', { var = 'w1' }, k)
    local s2 = Stage('Objectives two')
    Node(s2, 'ready', 'spawn', { army = 'Enemy', group = 'WAVE2', var = 'w2' })
    Node(s2, 'ready', 'obj_protect', { var = 'w2', name = 'p1', title = 'Protect the pair', description = 'Keep them alive.' })
    Node(s2, 'ready', 'obj_timer', { seconds = 3, expire = 'complete', name = 't1', title = 'Hold out', description = 'Survive.' })
    Node(s2, 'ready', 'obj_area', { area = 'TRG_AREA', army = 'ARMY_1', icon = 'move', compare = '>=', value = 1, name = 'a1', title = 'Reach the area', description = 'Be there.' })
    local pt, pa = Node(s2, 'ready', 'trg_timer', { seconds = 4 })
    Body(pa)
    Node(s2, 'ready', 'raw', { code = 'if V.p1 and V.p1.Active then V.p1:ManualResult(true) end' }, pt)
    local s3 = Stage('Objectives three')
    Node(s3, 'ready', 'end', { result = 'win' })
    B.flags.K1DONE = true
    B.ended = true B.success = true
    B.stage = 3
    B.objectives = { 'Kill the wave', 'Protect the pair', 'Hold out', 'Reach the area' }
    return B
end

local function Platoons()
    Fresh('campaign')
    local s = Stage('Platoons')
    Node(s, 'ready', 'set_alliance', { army = 'Enemy', other = 'ARMY_1', state = 'Ally' })
    Node(s, 'ready', 'platoon_group', { army = 'Enemy', group = 'WAVE1', platoon = 'TPL1', formation = 'GrowthFormation', orders = 'ORD1', var = 'pl' })
    Node(s, 'ready', 'orders_apply', { var = 'pl', orders = 'ORD1', clear = true })
    Node(s, 'ready', 'transport_drop', { army = 'Enemy', group = 'TDROP', landing = 'LANDING', attack = 'PATROL', instant = true, formation = 'GrowthFormation' })
    Node(s, 'ready', 'pbm_remove', { army = 'Enemy', builder = 'BLD1' })
    Node(s, 'ready', 'end', { result = 'win' })
    B.ended = true B.success = true
    B.stage = 1
    B.units = { Enemy = { min = 3 } }
    return B
end

local function Cutscene()
    Fresh('campaign')
    local s = Stage('Cutscene')
    local c = Node(s, 'ready', 'cutscene', {})
    Node(s, 'ready', 'cam_area', { area = 'CAM_AREA', seconds = 1 }, c)
    Node(s, 'ready', 'cam_marker', { marker = 'CAM_1', seconds = 1 }, c)
    Node(s, 'ready', 'cam_reset', {}, c)
    Node(s, 'ready', 'end', { result = 'win' })
    B.ended = true B.success = true
    B.stage = 1
    return B
end

local function Coop()
    Fresh('both')
    local s = Stage('Coop')
    Node(s, 'ready', 'coop_commanders', { unit = 'Commander', byFaction = false, effect = 'none', death = false })
    Node(s, 'ready', 'coop_unitcap', { cap = 800 })
    Node(s, 'ready', 'coop_restrict', { mode = 'restrict', categories = 'categories.TECH3' })
    Node(s, 'ready', 'coop_restrict', { mode = 'allow', categories = 'categories.TECH3', unlock = false })
    Node(s, 'ready', 'coop_announce', { text = 'Coop test', second = 'second line' })
    Node(s, 'ready', 'coop_player_death', {})
    Node(s, 'ready', 'end', { result = 'win' })
    B.ended = true B.success = true
    B.stage = 1
    return B
end

local function Bases()
    Fresh('campaign')
    local MB = import('/lua/editor/mbase.lua')
    if not Map.Doc.save.MasterChain._MASTERCHAIN_.Markers.Alpha_Marker then Tools.PlaceMarker(205, 150, 'Blank Marker', 'Alpha_Marker') end
    MB.AddBase('Alpha', 'Enemy')
    MB.AddGroup(1, 'DEF1', 100)
    local s = Stage('Bases')
    Node(s, 'ready', 'base_start', { base = 'Alpha' })
    Node(s, 'ready', 'base_active', { base = 'Alpha', on = false })
    Node(s, 'ready', 'end', { result = 'win' })
    B.ended = true B.success = true
    B.stage = 1
    B.allowWarn = { 'has no campaign AI brain' }       -- an editor session of a skirmish type map has no campaign brains: the base start only warns
    return B
end

local BUILD = { actions = Actions, flow = Flow, triggers = Triggers, objectives = Objectives, platoons = Platoons, cutscene = Cutscene, coop = Coop, bases = Bases }

--- Builds the mission of a case (the world and the model); returns the expectation table.
function Build(case)
    local f = BUILD[case]
    if not f then error('no such case ' .. tostring(case)) end
    return f()
end

-- ---- running a case --------------------------------------------------------------------------------------------------------------------------------

function Prepare(case)
    Build(case)
    local findings = {}
    for _, p in M.Check() do
        if p.sev == 'E' then table.insert(findings, p.text) end
    end
    if table.getn(findings) > 0 then return 'fail the mission has findings: ' .. table.concat(findings, ' | ') end
    M.Revision = M.Revision + 1
    local R = import('/lua/editor/missionrun.lua')
    R.MarkLog()
    import('/lua/editor/ui.lua').Play()
    return 'play requested (' .. table.getn(B.nodes) .. ' nodes)'
end

local function Set(list)
    local s = {}
    for _, v in list do s[v] = true end
    return s
end

--- Polls the sim and compares with what the case expects. Returns 'done' | 'wait ...' | 'fail ...' (a text; 'done' only when everything holds).
function Verify(case)
    local expect = Build(case)       -- (rebuilt after the reload: the same model, the same addresses)
    local R = import('/lua/editor/missionrun.lua')
    R.Poll()
    local st = R.Poll()
    if not st.playing then return 'wait the test run has not started (playing = ' .. tostring(st.playing) .. ')' end
    local seen = Set(st.trace)
    local missing = {}
    for _, n in expect.nodes do
        if not seen[n.addr] then table.insert(missing, n.addr .. ' (' .. n.type .. ')') end
    end
    for _, b in expect.bodies do
        if not seen[b] then table.insert(missing, b .. ' (trigger body)') end
    end
    local problems = {}
    for _, d in expect.dropped do
        if not seen[d] then table.insert(missing, d .. ' (dropped trigger)') end
    end
    -- the facts that must hold (checked once the trace is complete, so a slow run is not a failure)
    local late = {}
    if expect.ended and not st.ended then table.insert(missing, 'the operation end') end
    if table.getn(missing) > 0 then return 'wait ' .. table.concat(missing, ', ') end
    if expect.ended and st.success ~= expect.success then table.insert(problems, 'the operation ended with success = ' .. tostring(st.success) .. ', expected ' .. tostring(expect.success)) end
    for name, want in expect.flags do
        if st.flags[name] ~= want then table.insert(problems, 'flag ' .. name .. ' is ' .. tostring(st.flags[name]) .. ', expected ' .. tostring(want)) end
    end
    for name, _ in expect.noflags do
        if st.flags[name] ~= nil then table.insert(problems, 'flag ' .. name .. ' is set (' .. tostring(st.flags[name]) .. '), it must not be (a dropped trigger ran)') end
    end
    for name, kind in expect.vars do
        if st.vars[name] ~= kind then table.insert(problems, 'variable ' .. name .. ' is ' .. tostring(st.vars[name]) .. ', expected ' .. tostring(kind)) end
    end
    for army, range in expect.units do
        local n = st.units[army]
        if n == nil then table.insert(problems, 'no unit count of army ' .. army)
        else
            if range.min and n < range.min then table.insert(problems, army .. ' has ' .. n .. ' units, at least ' .. range.min .. ' expected') end
            if range.max and n > range.max then table.insert(problems, army .. ' has ' .. n .. ' units, at most ' .. range.max .. ' expected') end
        end
    end
    for key, kind in expect.rel or {} do
        if st.rel[key] ~= kind then table.insert(problems, 'army relation ' .. key .. ' is ' .. tostring(st.rel[key]) .. ', expected ' .. kind) end
    end
    for army, want in expect.eco or {} do
        local e = st.eco[army]
        if not e or e.mass < want.mass or e.energy < want.energy then
            table.insert(problems, army .. ' has ' .. (e and (e.mass .. ' mass / ' .. e.energy .. ' energy') or 'no economy') .. ', at least ' .. want.mass .. ' / ' .. want.energy .. ' expected')
        end
    end
    if expect.playable and not st.playable then table.insert(problems, 'the playable area was not set') end
    if expect.stage and st.stage < expect.stage then table.insert(problems, 'the mission is in stage ' .. st.stage .. ', stage ' .. expect.stage .. ' expected') end
    if expect.objectives then
        local titles = {}
        for _, o in st.objectives do titles[o.title] = true end
        for _, t in expect.objectives do
            if not titles[t] then table.insert(problems, 'objective "' .. t .. '" was never created') end
        end
        for _, o in st.objectives do
            if o.active then table.insert(problems, 'objective "' .. o.title .. '" is still active at the end') end
        end
    end
    -- warnings the script raised
    local allow = expect.allowWarn or {}
    for _, w in R.Warnings() do
        local fine = false
        for _, a in allow do if string.find(w, a, 1, true) then fine = true end end
        if not fine and string.find(w, '^    ') == nil then table.insert(problems, 'log: ' .. w) end
    end
    if table.getn(problems) > 0 then return 'fail ' .. table.concat(problems, ' | ') end
    return 'done (' .. table.getn(st.trace) .. ' trace entries, stage ' .. st.stage .. ', tick ' .. st.tick .. ')'
end

--- The selftest (no sim): the cases build and are clean, both flavors load, every catalogue node type is used.
function Run()
    out, failed = {}, 0
    local saved = M.Data
    local used = {}
    for _, case in Cases do
        local ok, expect = pcall(Build, case)
        Check(ok, 'case ' .. case .. ' builds' .. (ok and '' or (': ' .. tostring(expect))))
        if ok then
            local errs = {}
            for _, p in M.Check() do if p.sev == 'E' then table.insert(errs, p.text) end end
            Check(table.getn(errs) == 0, 'case ' .. case .. ' has no error findings (' .. table.concat(errs, ' | ') .. ')')
            for _, flavor in { false, true } do
                local text = M.Compile(true, { test = flavor })
                Check(loadstring(text) ~= nil, 'case ' .. case .. ' compiles to loadable Lua (' .. (flavor and 'test run' or 'saved map') .. ')')
            end
            Check(table.getn(M.Problems) == 0, 'case ' .. case .. ' leaves no node out of the script')
            for id, _ in expect.types do used[id] = true end
        end
    end
    local unused = {}
    for _, t in M.Catalogue do
        if not used[t.id] then table.insert(unused, t.id) end
    end
    Check(table.getn(unused) == 0, 'every node type of the catalogue is used by a case of the sim test (not used: ' .. table.concat(unused, ', ') .. ')')
    M.Data = saved
    table.insert(out, failed == 0 and 'ALL PASS' or (failed .. ' FAILED'))
    return table.concat(out, '\n')
end
