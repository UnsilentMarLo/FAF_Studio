-- Mission model, compiler and script region. Through /edcmd, in an /editor session:
--   return import('/lua/editor/selftest_mission.lua').Run()
-- Builds a two stage mission, compiles it (the text must load), checks the checks, and walks the script region through its cases: empty stub, rewrite, hand edit, own script.

local M = import('/lua/editor/mission.lua')
local H = import('/lua/editor/history.lua')
local A = import('/lua/editor/armysetup.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

function Run()
    out, failed = {}, 0
    local saved = M.Data
    M.Data = { mode = 'campaign', stages = {} }
    if not A.Get('Enemy') then A.Add('Enemy') end
    local map = import('/lua/editor/map.lua')
    map.Doc.save.Armies.Enemy.Units.Units.WAVE1 = { type = 'GROUP', orders = '', platoon = '', Units = {} }

    M.AddStage('One') M.AddStage('Two')
    M.AddNode(1, 'ready', 'spawn')
    M.SetParam(1, 'ready', 1, 'army', 'Enemy') M.SetParam(1, 'ready', 1, 'group', 'WAVE1') M.SetParam(1, 'ready', 1, 'var', 'w')
    M.AddNode(1, 'ready', 'obj_kill')
    M.SetParam(1, 'ready', 2, 'var', 'w')
    M.AddNode(2, 'ready', 'end')
    Check(table.getn(M.Check()) == 0, 'a valid mission has no findings')
    local text = M.Compile(true)
    Check(loadstring(text) ~= nil, 'compiled script loads')
    Check(string.find(text, 'Stage[2]', 1, true) ~= nil and string.find(text, 'Objectives.Kill', 1, true) ~= nil, 'script has both stages and the objective')
    Check(not M.AddNode(1, 'enter', 'obj_kill'), 'objective nodes are refused in the enter part')

    -- checks find the mistakes
    M.SetParam(1, 'ready', 2, 'var', 'nothing')
    local found = {}
    for _, p in M.Check() do table.insert(found, p.text) end
    Check(table.getn(found) == 1 and string.find(found[1], 'not set by an earlier node', 1, true) ~= nil, 'undefined variable is reported (' .. table.concat(found, ' | ') .. ')')
    M.SetParam(1, 'ready', 2, 'var', 'w')
    M.SetParam(1, 'ready', 1, 'group', 'NOPE')
    found = {}
    for _, p in M.Check() do table.insert(found, p.text) end
    Check(table.getn(found) == 1 and string.find(found[1], 'has no group', 1, true) ~= nil, 'missing group is reported')
    M.SetParam(1, 'ready', 1, 'group', 'WAVE1')
    M.AddNode(2, 'ready', 'raw')
    M.SetParam(2, 'ready', 2, 'code', 'this is not lua')
    found = {}
    for _, p in M.Check() do table.insert(found, p.text) end
    Check(table.getn(found) == 1 and string.find(found[1], 'does not compile', 1, true) ~= nil, 'a Raw Lua syntax error is reported')
    M.RemoveNode(2, 'ready', 2)

    -- undo / redo
    local n = table.getn(M.Data.stages[2].ready)
    M.AddNode(2, 'ready', 'wait')
    Check(table.getn(M.Data.stages[2].ready) == n + 1, 'node added')
    H.Undo()
    Check(table.getn(M.Data.stages[2].ready) == n, 'undo removes it')
    H.Redo()
    Check(table.getn(M.Data.stages[2].ready) == n + 1, 'redo brings it back')
    M.RemoveNode(2, 'ready', n + 1)

    -- the script region
    local stub = "local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')\n\nfunction OnPopulate()\n    ScenarioUtils.InitializeArmies()\nend\n\nfunction OnStart(self)\nend\n"
    local a, state = M.PatchScript(stub)
    Check(state == 'written' and string.find(a, 'function OnPopulate', 1, true) and not string.find(a, 'ScenarioUtils.InitializeArmies()', 1, true), 'the default stub is replaced by the region')
    Check(loadstring(a) ~= nil, 'the patched script loads')
    local b, state2 = M.PatchScript(a)
    Check(state2 == 'written' and b == a, 'patching again changes nothing')
    local edited = string.gsub(a, 'MissionNumber = 0', 'MissionNumber = 7')
    local c, state3 = M.PatchScript(edited)
    Check(state3 == 'detached' and c == edited, 'a hand edit inside the region is left alone')
    local own = "function OnPopulate()\nend\nfunction OnStart(self)\n    LOG('mine')\nend\nfunction Helper() return 1 end\n"
    local d, state4 = M.PatchScript(own)
    Check(state4 == 'written' and string.find(d, 'LOG(\'mine\')', 1, true) and not string.find(d, 'function OnStart(self)\n    ForkThread', 1, true), 'a script with its own entry points keeps them and gets the region appended')
    local e = M.PatchScript(d)
    Check(e == d, 'and patching that again changes nothing')

    -- the sidecar text loads back
    local side = M.SidecarText()
    local env = {}
    local f = loadstring(side)
    Check(f ~= nil, 'sidecar text loads')
    if f then
        setfenv(f, env)
        f()
        Check(env.Mission and table.getn(env.Mission.stages) == 2 and env.Mission.stages[1].ready[1].var == 'w', 'sidecar carries the stages and node parameters')
    end

    M.Data = saved
    RunTriggers()
    RunBases()
    RunStrings()
    RunCoop()
    RunRunParsers()
    table.insert(out, failed == 0 and 'ALL PASS' or (failed .. ' FAILED'))
    return table.concat(out, '\n')
end

local function Findings()
    local found = {}
    for _, p in M.Check() do
        if p.sev ~= 'I' then table.insert(found, p.text) end
    end
    return found
end

--- Trigger nodes: nested children, addresses by path, indent / outdent, variable scope, compiled callbacks.
function RunTriggers()
    local saved = M.Data
    M.Data = { mode = 'campaign', stages = {}, bases = {} }
    local map = import('/lua/editor/map.lua')
    if not A.Get('Enemy') then A.Add('Enemy') end
    map.Doc.save.Armies.Enemy.Units.Units.WAVE1 = { type = 'GROUP', orders = '', platoon = '', Units = {} }
    map.Doc.save.Armies.Enemy.Units.Units.WAVE2_D1 = { type = 'GROUP', orders = '', platoon = '', Units = {} }
    map.Doc.save.Armies.Enemy.Units.Units.WAVE2_D2 = { type = 'GROUP', orders = '', platoon = '', Units = {} }
    map.Doc.save.Armies.Enemy.Units.Units.WAVE2_D3 = { type = 'GROUP', orders = '', platoon = '', Units = {} }
    map.Doc.save.Armies.Enemy.Units.Units.INITIAL.Units.UNIT_9 = { type = 'uel0106', orders = '', platoon = '', Position = { 10, 0, 10 }, Orientation = { 0, 0, 0 } }
    map.Doc.save.Areas.TRG_AREA = { rectangle = { 10, 10, 60, 60, type = 'RECTANGLE' } }

    M.AddStage('One') M.AddStage('Two')
    M.AddNode(2, 'ready', 'end')
    M.AddNode(1, 'ready', 'spawn')
    M.SetParam(1, 'ready', 1, 'army', 'Enemy') M.SetParam(1, 'ready', 1, 'group', 'WAVE1') M.SetParam(1, 'ready', 1, 'var', 'w')
    M.AddNode(1, 'ready', 'obj_kill')
    M.SetParam(1, 'ready', 2, 'var', 'w') M.SetParam(1, 'ready', 2, 'name', 'killAll')

    -- a timer with children; an area trigger inside it
    local ok, timerPath = M.AddNode(1, 'ready', 'trg_timer')
    Check(ok and timerPath[1] == 3, 'a trigger node is added and its path returned')
    M.SetParam(1, 'ready', timerPath, 'seconds', 20)
    local ok2, textPath = M.AddNode(1, 'ready', 'dialogue', nil, timerPath)
    Check(ok2 and table.getn(textPath) == 2 and textPath[2] == 1, 'a node is added into the trigger (path { 3, 1 })')
    local ok3, areaPath = M.AddNode(1, 'ready', 'trg_area', nil, timerPath)
    M.SetParam(1, 'ready', areaPath, 'area', 'TRG_AREA') M.SetParam(1, 'ready', areaPath, 'army', 'Enemy')
    local ok4, flagPath = M.AddNode(1, 'ready', 'set_flag', nil, areaPath)
    Check(ok4 and table.getn(flagPath) == 3, 'triggers nest')
    Check(not M.AddNode(1, 'enter', 'obj_kill', nil, nil), 'objectives are still refused in the enter part')
    local refused = M.AddNode(1, 'ready', 'dialogue', nil, { 1 })
    Check(not refused, 'a node that holds no children refuses children')
    local rows = M.Flatten(1)
    Check(table.getn(rows) == 6 and rows[5].depth == 1 and rows[6].depth == 2, 'Flatten lists nested nodes with their depth')
    Check(table.getn(Findings()) == 0, 'a valid nested mission has no findings (' .. table.concat(Findings(), ' | ') .. ')')
    local text = M.Compile(true)
    Check(loadstring(text) ~= nil, 'the nested mission compiles to loadable Lua')
    Check(string.find(text, 'Timer(function()', 1, true) and string.find(text, 'MissionNumber ~= 1 then return end', 1, true) and string.find(text, 'ScenarioInfo.VarTable', 1, true), 'timer callback, stage guard and flag are in the script')
    Check(string.find(text, 'CountInArea(\'TRG_AREA\', \'Enemy\'', 1, true) ~= nil, 'area trigger polls CountInArea')

    -- variable scope: a group made inside the timer is not visible outside it
    local ok5, inner = M.AddNode(1, 'ready', 'spawn', nil, timerPath)
    M.SetParam(1, 'ready', inner, 'army', 'Enemy') M.SetParam(1, 'ready', inner, 'group', 'WAVE1') M.SetParam(1, 'ready', inner, 'var', 'late')
    local ok6, after = M.AddNode(1, 'ready', 'group_patrol')
    M.SetParam(1, 'ready', after, 'var', 'late')
    local f = Findings()
    local scoped = false
    for _, t in f do if string.find(t, 'late is not set by an earlier node', 1, true) then scoped = true end end
    Check(scoped, 'a variable set inside a trigger is not visible outside it (' .. table.concat(f, ' | ') .. ')')
    M.RemoveNode(1, 'ready', after)

    -- an objective result trigger needs a named objective
    local ok7, resPath = M.AddNode(1, 'ready', 'trg_objective')
    M.SetParam(1, 'ready', resPath, 'objective', 'killAll')
    Check(table.getn(Findings()) == 0, 'objective result trigger finds the named objective (' .. table.concat(Findings(), ' | ') .. ')')
    local ok8, nextPath = M.AddNode(1, 'ready', 'next_stage', nil, resPath)
    local t2 = M.Compile(true)
    Check(string.find(t2, 'AddResultCallback', 1, true) and string.find(t2, 'ForkThread(Stage[2])', 1, true) and loadstring(t2) ~= nil, 'result callback and the next stage call compile')
    M.SetParam(1, 'ready', resPath, 'objective', 'nope')
    local bad = false
    for _, t in Findings() do if string.find(t, 'nope', 1, true) then bad = true end end
    Check(bad, 'an unknown objective is reported')
    M.SetParam(1, 'ready', resPath, 'objective', 'killAll')

    -- indent / outdent
    Check(not M.IndentNode(1, 'ready', { 2 }), 'indent: the spawn node above holds no children')
    local okA, newPath = M.AddNode(1, 'ready', 'wait')
    local okB, inPath = M.IndentNode(1, 'ready', newPath)
    Check(okB and inPath[1] == newPath[1] - 1 and table.getn(inPath) == 2, 'indent puts the node into the container above')
    local okC, outPath = M.OutdentNode(1, 'ready', inPath)
    Check(okC and outPath[1] == newPath[1] and table.getn(outPath) == 1, 'outdent puts it back behind the container')
    M.RemoveNode(1, 'ready', outPath)

    -- undo / redo of a nested edit
    local n1 = table.getn(M.Flatten(1))
    M.AddNode(1, 'ready', 'wait', nil, timerPath)
    Check(table.getn(M.Flatten(1)) == n1 + 1, 'nested node added')
    H.Undo()
    Check(table.getn(M.Flatten(1)) == n1, 'undo removes the nested node')
    H.Redo()
    Check(table.getn(M.Flatten(1)) == n1 + 1, 'redo brings it back')

    -- difficulty branch, spawn per difficulty, cutscene
    M.AddStage('Three')
    local okD, diffPath = M.AddNode(3, 'ready', 'if_difficulty')
    M.SetParam(3, 'ready', diffPath, 'level', 3)
    local okS, spPath = M.AddNode(3, 'ready', 'spawn', nil, diffPath)
    M.SetParam(3, 'ready', spPath, 'army', 'Enemy') M.SetParam(3, 'ready', spPath, 'group', 'WAVE2') M.SetParam(3, 'ready', spPath, 'bydiff', true)
    local okC, cutPath = M.AddNode(3, 'ready', 'cutscene')
    local okM, camPath = M.AddNode(3, 'ready', 'cam_area', nil, cutPath)
    M.SetParam(3, 'ready', camPath, 'area', 'TRG_AREA')
    M.AddNode(3, 'ready', 'end')
    local t3 = M.Compile(true)
    Check(string.find(t3, 'if Difficulty >= 3 then', 1, true) and string.find(t3, "'WAVE2' .. '_D' .. Difficulty", 1, true), 'difficulty branch and per-difficulty group')
    Check(string.find(t3, 'Cinematics.EnterNISMode()', 1, true) and string.find(t3, 'Cinematics.CameraMoveToArea', 1, true) and string.find(t3, "local Cinematics = import('/lua/cinematics.lua')", 1, true), 'cutscene and camera nodes')
    Check(loadstring(t3) ~= nil, 'script with branch and cutscene loads')
    M.SetParam(3, 'ready', spPath, 'group', 'WAVE1')
    local diffMissing = false
    for _, t in Findings() do if string.find(t, 'WAVE1_D1', 1, true) then diffMissing = true end end
    Check(diffMissing, 'per-difficulty spawn checks the three groups')
    M.SetParam(3, 'ready', spPath, 'group', 'WAVE2')

    -- single unit death trigger
    local okU, uPath = M.AddNode(3, 'ready', 'trg_unit_killed')
    M.SetParam(3, 'ready', uPath, 'army', 'Enemy') M.SetParam(3, 'ready', uPath, 'unit', 'UNIT_9')
    M.AddNode(3, 'ready', 'dialogue', nil, uPath)
    Check(table.getn(Findings()) == 0, 'unit death trigger with an existing unit has no findings (' .. table.concat(Findings(), ' | ') .. ')')
    Check(string.find(M.Compile(true), 'CreateUnitDeathTrigger', 1, true) ~= nil, 'unit death trigger compiled')
    M.SetParam(3, 'ready', uPath, 'unit', 'UNIT_NOPE')
    local unitBad = false
    for _, t in Findings() do if string.find(t, 'no unit UNIT_NOPE', 1, true) then unitBad = true end end
    Check(unitBad, 'unknown unit reported')

    -- sidecar keeps the nested children
    local side = M.SidecarText()
    local env = {}
    local fn = loadstring(side)
    if fn then
        setfenv(fn, env)
        fn()
        local first = env.Mission and env.Mission.stages[1].ready[3]
        Check(first and first.type == 'trg_timer' and first.children and table.getn(first.children) >= 2 and first.children[2].children, 'sidecar carries nested children')
    else
        Check(false, 'sidecar text loads')
    end

    -- the generated mission is what a map script would hold
    local patched, state = M.PatchScript("function OnPopulate()\nend\nfunction OnStart(self)\nend\n")
    Check(state == 'written' and loadstring(patched) ~= nil, 'a script with the nested mission patches and loads')

    M.Data = saved
end

--- Bases: model, edits, define from area, compile, checks.
function RunBases()
    local saved = M.Data
    M.Data = { mode = 'campaign', stages = {}, bases = {} }
    local B = import('/lua/editor/mbase.lua')
    local map = import('/lua/editor/map.lua')
    local Units = import('/lua/editor/units.lua')
    if not A.Get('Enemy') then A.Add('Enemy') end
    local doc = map.Doc
    -- leftovers of an earlier run of this test in the same session
    doc.save.Armies.Enemy.Units.Units.North = nil
    doc.save.MasterChain._MASTERCHAIN_.Markers.North_Marker = nil
    doc.save.Chains.ATK_CHAIN = { Markers = { 'ATK_M1' } }
    doc.save.Areas.BASE_AREA = { rectangle = { 100, 100, 140, 120, type = 'RECTANGLE' } }
    -- two structures of the enemy inside the area, one outside
    local initial = doc.save.Armies.Enemy.Units.Units.INITIAL.Units
    initial.UNIT_B1 = { type = 'ueb0101', orders = '', platoon = '', Position = { 110, 0, 105 }, Orientation = { 0, 0, 0 } }
    initial.UNIT_B2 = { type = 'ueb1101', orders = '', platoon = '', Position = { 120, 0, 110 }, Orientation = { 0, 0, 0 } }
    initial.UNIT_B3 = { type = 'ueb1101', orders = '', platoon = '', Position = { 300, 0, 300 }, Orientation = { 0, 0, 0 } }

    local inArea = B.UnitsInArea('Enemy', 'BASE_AREA')
    Check(table.getn(inArea) == 2, 'two units of the army stand inside the area (' .. table.getn(inArea) .. ')')
    local okDef, count = B.DefineFromArea('North', 'Enemy', 'BASE_AREA')
    Check(okDef and count == 2, 'Define base from area works')
    local b = B.Find('North')
    Check(b and b.marker == 'North_Marker' and doc.save.MasterChain._MASTERCHAIN_.Markers.North_Marker, 'the base has its marker')
    Check(b and b.groups[1] and b.groups[1].name == 'North' and doc.save.Armies.Enemy.Units.Units.North and doc.save.Armies.Enemy.Units.Units.North.Units.UNIT_B1, 'the units moved into the base group')
    Check(not doc.save.Armies.Enemy.Units.Units.INITIAL.Units.UNIT_B1 and doc.save.Armies.Enemy.Units.Units.INITIAL.Units.UNIT_B3, 'the unit outside stays')
    Check(b and b.radius == 23, 'radius is half the diagonal (' .. tostring(b and b.radius) .. ')')
    H.Undo()
    Check(not B.Find('North') and not doc.save.MasterChain._MASTERCHAIN_.Markers.North_Marker and doc.save.Armies.Enemy.Units.Units.INITIAL.Units.UNIT_B1, 'one undo reverts marker, units and base')
    H.Redo()
    Check(B.Find('North') and doc.save.MasterChain._MASTERCHAIN_.Markers.North_Marker and doc.save.Armies.Enemy.Units.Units.North.Units.UNIT_B1, 'redo brings the definition back')

    local _, bi = B.Find('North')
    B.SetField(bi, 'engineers', { 3, 5, 7 })
    B.SetField(bi, 'noBuild', { 'Defenses' })
    B.SetField(bi, 'switchOn', { 'AirScouting' })
    B.AddGroup(bi, 'WAVE_X', 50)
    Check(not B.AddGroup(bi, 'WAVE_X', 50), 'a group is added once')
    local okO, oi = B.AddOpAI(bi)
    Check(okO and oi == 1, 'an attack is added')
    B.SetOpAI(bi, oi, 'ptype', 'BasicLandAttack')
    B.SetOpAI(bi, oi, 'children', { 'LightTanks', 'LightArtillery' })
    B.SetOpAI(bi, oi, 'chains', { 'ATK_CHAIN' })
    B.SetOpAI(bi, oi, 'cond1', 'humans have units')
    B.SetOpAI(bi, oi, 'cond2', 'flag is set')
    B.SetOpAI(bi, oi, 'cond2flag', 'GO')
    B.SetOpAI(bi, oi, 'lock', 'DeathTimer')

    local lines = B.Compile()
    local text = table.concat(lines, '\n')
    Check(string.find(text, "bm:Initialize(brain, 'North', 'North_Marker', 23", 1, true) and string.find(text, "['North'] = 100", 1, true), 'Initialize with the level table')
    Check(string.find(text, 'bm:StartNonZeroBase({ { 3, 5, 7 }, { 0, 0, 0 } })', 1, true), 'engineers per difficulty')
    Check(string.find(text, "bm:SetBuild('Defenses', false)", 1, true) and string.find(text, "bm:SetActive('AirScouting', true)", 1, true), 'build and activity switches')
    Check(string.find(text, "AddOpAI('BasicLandAttack', 'Attack1'", 1, true) and string.find(text, "PatrolChains = { 'ATK_CHAIN' }", 1, true) and string.find(text, "SetChildQuantity({ 'LightTanks', 'LightArtillery' }", 1, true), 'OpAI with master function, chains and children')
    Check(string.find(text, 'BrainsCompareNumCategory', 1, true) and string.find(text, 'CheckScenarioInfoVarTable', 1, true) and string.find(text, "SetLockingStyle('DeathTimer', { LockTimer = 60 })", 1, true), 'build conditions and locking style')

    -- a stage starts the base; the whole script loads
    M.AddStage('Bases')
    M.AddNode(1, 'ready', 'base_start')
    M.SetParam(1, 'ready', 1, 'base', 'North')
    M.AddNode(1, 'ready', 'base_active')
    M.SetParam(1, 'ready', 2, 'base', 'North')
    M.AddNode(1, 'ready', 'end')
    local script = M.Compile(true)
    Check(loadstring(script) ~= nil, 'the script with a base compiles to loadable Lua')
    Check(string.find(script, 'Base.Start_North()', 1, true) and string.find(script, "local BaseManager = import('/lua/ai/opai/basemanager.lua')", 1, true), 'the stage calls the base start')
    local f = Findings()
    local typeWarn = false
    for _, t in f do if string.find(t, 'campaign AI brain', 1, true) then typeWarn = true end end
    local info = import('/lua/editor/maps.lua').Info()
    Check(typeWarn == (info.type ~= 'campaign'), 'the checks warn about a non-campaign map type only (' .. table.concat(f, ' | ') .. ')')
    -- problems are found
    B.SetOpAI(bi, oi, 'chains', {})
    B.SetField(bi, 'army', 'Nobody')
    local msgs = table.concat(Findings(), ' | ')
    Check(string.find(msgs, 'no patrol chain chosen', 1, true) and string.find(msgs, 'army Nobody is not in the army list', 1, true), 'base problems are reported')
    B.SetField(bi, 'army', 'Enemy')
    B.SetOpAI(bi, oi, 'chains', { 'ATK_CHAIN' })

    -- sidecar and undo
    local fn = loadstring(M.SidecarText())
    local env = {}
    if fn then
        setfenv(fn, env)
        fn()
        Check(env.Mission and env.Mission.bases and env.Mission.bases[1].opai[1].children[2] == 'LightArtillery', 'sidecar carries bases and attacks')
    else
        Check(false, 'sidecar loads')
    end
    local nb = table.getn(M.Data.bases)
    B.RemoveBase(bi)
    Check(table.getn(M.Data.bases) == nb - 1, 'base removed')
    H.Undo()
    Check(table.getn(M.Data.bases) == nb, 'undo brings it back')

    M.Data = saved
end

--- Dialogue tables, objective reminders, the Wait / Timer helpers of the script.
function RunStrings()
    local saved = M.Data
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    local map = import('/lua/editor/map.lua')
    if not A.Get('Enemy') then A.Add('Enemy') end
    map.Doc.save.Armies.Enemy.Units.Units.WAVE1 = { type = 'GROUP', orders = '', platoon = '', Units = {} }

    Check(M.AddDialogue('INTRO') and not M.AddDialogue('INTRO') and not M.AddDialogue('bad name'), 'dialogues have unique valid names')
    local ok, li = M.AddLine(1, 'Welcome, Commander')
    Check(ok and li == 1, 'a line is added')
    M.SetLine(1, 1, 'speaker', 'HQ') M.SetLine(1, 1, 'seconds', 7)
    M.AddLine(1, 'Second line')
    M.MoveLine(1, 2, -1)
    Check(M.Data.dialogues[1].lines[1].text == 'Second line', 'lines move')
    M.MoveLine(1, 1, 1)

    M.AddStage('One')
    M.AddNode(1, 'ready', 'spawn')
    M.SetParam(1, 'ready', 1, 'army', 'Enemy') M.SetParam(1, 'ready', 1, 'group', 'WAVE1') M.SetParam(1, 'ready', 1, 'var', 'w')
    M.AddNode(1, 'ready', 'dialogue_table')
    M.AddNode(1, 'ready', 'obj_kill')
    M.SetParam(1, 'ready', 3, 'var', 'w') M.SetParam(1, 'ready', 3, 'name', 'k1')
    M.AddNode(1, 'ready', 'next_stage')
    Check(table.getn(Findings()) > 0, 'a dialogue node without a chosen dialogue is reported')
    M.SetParam(1, 'ready', 2, 'name', 'INTRO')
    M.AddStage('Two')
    M.AddNode(2, 'ready', 'end')
    M.RemoveNode(1, 'ready', 4)
    Check(table.getn(Findings()) == 0, 'a valid dialogue node has no findings (' .. table.concat(Findings(), ' | ') .. ')')
    M.SetParam(1, 'ready', 3, 'reminder', 'NOPE')
    local nope = false
    for _, t in Findings() do if string.find(t, 'no dialogue NOPE', 1, true) then nope = true end end
    Check(nope, 'an unknown reminder dialogue is reported')
    M.SetParam(1, 'ready', 3, 'reminder', 'INTRO') M.SetParam(1, 'ready', 3, 'reminderSecs', 30)
    local text = M.Compile(true)
    Check(loadstring(text) ~= nil, 'the script with strings and a reminder loads')
    Check(string.find(text, "['INTRO'] = {", 1, true) and string.find(text, "text = 'HQ: Welcome, Commander', delay = 7", 1, true), 'the Strings table carries speaker and duration')
    Check(string.find(text, "ScenarioFramework.Dialogue(Strings['INTRO'], nil, true)", 1, true), 'the dialogue node plays the table')
    Check(string.find(text, 'local o = obj', 1, true) and string.find(text, 'Wait(30)', 1, true) and string.find(text, "Strings['INTRO'])", 1, true), 'the reminder loop is compiled')
    local testText = M.Compile(true, { test = true })
    Check(string.find(testText, 'local function Wait(seconds)', 1, true) and string.find(testText, 'ScenarioInfo.EditorMission = ', 1, true) and string.find(testText, 'EdTrace(', 1, true), 'a test run script has the Wait shim, the editor state and the node trace')
    Check(loadstring(testText) ~= nil, 'and loads')
    -- the script of a saved or released map has none of the editor's test hooks
    Check(string.find(text, 'local function Wait(seconds)', 1, true) and string.find(text, 'WaitSeconds(seconds)', 1, true) and not string.find(text, 'left = left', 1, true), 'a saved map waits with WaitSeconds (no polling shim)')
    for _, hook in { 'EditorSkip', 'EditorTimeScale', 'EditorMission =', 'EdTrace', 'EditorStartStage', 'coopshim', 'editorsim' } do
        Check(not string.find(text, hook, 1, true), 'a saved map script has no ' .. hook)
    end

    -- sidecar and undo
    local fn = loadstring(M.SidecarText())
    local env = {}
    if fn then
        setfenv(fn, env)
        fn()
        Check(env.Mission and env.Mission.dialogues and env.Mission.dialogues[1].lines[1].speaker == 'HQ', 'sidecar carries the dialogues')
    else
        Check(false, 'sidecar loads')
    end
    local n = table.getn(M.Data.dialogues[1].lines)
    M.AddLine(1, 'x')
    H.Undo()
    Check(table.getn(M.Data.dialogues[1].lines) == n, 'undo removes a line')
    H.Redo()
    M.RemoveLine(1, n + 1)
    M.Data = saved
end

--- Coop mode: nodes, mode check, scenario type, player-count branch.
function RunCoop()
    local saved = M.Data
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    M.AddStage('One')
    local _, p = M.AddNode(1, 'ready', 'coop_commanders')
    M.AddNode(1, 'ready', 'coop_unitcap')
    M.AddNode(1, 'ready', 'coop_restrict')
    M.AddNode(1, 'ready', 'coop_announce')
    M.SetParam(1, 'ready', 4, 'text', 'Mission start')
    M.AddNode(1, 'ready', 'coop_player_death')
    local _, ip = M.AddNode(1, 'ready', 'if_players')
    M.AddNode(1, 'ready', 'wait', nil, ip)
    M.AddNode(1, 'ready', 'end')
    local campaignErr = false
    for _, t in Findings() do if string.find(t, 'mission mode is campaign', 1, true) then campaignErr = true end end
    Check(campaignErr, 'coop nodes are errors in campaign mode')
    Check(M.ScenarioType('campaign') == 'campaign' and M.ScenarioType('skirmish') == 'skirmish', 'campaign mode keeps the map type')
    M.SetMode('coop')
    Check(table.getn(Findings()) == 0, 'coop nodes are fine in coop mode (' .. table.concat(Findings(), ' | ') .. ')')
    Check(M.ScenarioType('campaign') == 'campaign_coop' and M.ScenarioType('skirmish') == 'campaign_coop', 'coop and both modes make the scenario campaign_coop')
    M.SetMode('both')
    Check(M.ScenarioType('campaign') == 'campaign_coop', 'both mode too')
    Check(string.find(M.Compile(true, { test = true }), "import('/lua/editor/coopshim.lua').Install()", 1, true) ~= nil, 'coop and both-mode scripts install the coop support in an editor play test')
    Check(string.find(M.Compile(true), 'coopshim', 1, true) == nil, 'and a saved map does not mention the editor shim')
    H.Undo()
    Check(M.Data.mode == 'coop', 'mode change has undo')
    H.Redo()
    local map = import('/lua/editor/map.lua')
    local Maps = import('/lua/editor/maps.lua')
    if not A.Get('Enemy') then A.Add('Enemy') end
    if not A.Get('Player1') then A.Add('Player1') end
    local oldType = Maps.Info().type
    Maps.SetInfo({ type = 'campaign' })
    map.Doc.save.Armies.Enemy.plans = '' map.Doc.save.Armies.Player1.plans = ''
    M.PrepareArmies()
    Check(map.Doc.save.Armies.Enemy.plans ~= '' and map.Doc.save.Armies.Player1.plans ~= '', 'campaign maps give every non-human army the blank plan list')
    Maps.SetInfo({ type = oldType })
    local text = M.Compile(true)
    Check(loadstring(text) ~= nil, 'the coop script loads')
    Check(string.find(text, 'ScenarioFramework.SpawnCommander(name,', 1, true) and string.find(text, 'GetFactionIndex()', 1, true), 'commanders are spawned per human slot by faction')
    Check(string.find(text, 'SetSharedUnitCap(1000)', 1, true) and string.find(text, 'AddRestrictionForAllHumans', 1, true) and string.find(text, 'SimAnnouncement(', 1, true), 'unit cap, restrictions and announcement')
    Check(string.find(text, 'ScenarioFramework.PlayerDeath(unit,', 1, true) and string.find(text, 'table.getsize(ScenarioInfo.HumanPlayers or {})', 1, true), 'player death handling and the player-count branch')
    local fn = loadstring(M.SidecarText())
    local env = {}
    if fn then setfenv(fn, env) fn() end
    Check(env.Mission and env.Mission.mode == 'both', 'the mode travels with the map')
    M.Data = saved
end

--- The run panel's parsers (the sim side is checked in the play test).
function RunRunParsers()
    local R = import('/lua/editor/missionrun.lua')
    local s = R.ParseState('tick 120\nstage 2\nplaying 1\nscale 4\nflag GO 1\nflag NO 0\nobj Destroy the base|1\nobj Hold|0\nvar t 3\nvar late table\n')
    Check(s.tick == 120 and s.stage == 2 and s.playing and s.scale == 4, 'the dump header is parsed')
    Check(s.flags.GO == true and s.flags.NO == false and s.flagOrder[1] == 'GO', 'flags are parsed')
    Check(table.getn(s.objectives) == 2 and s.objectives[1].title == 'Destroy the base' and s.objectives[1].active and not s.objectives[2].active, 'objectives are parsed')
    Check(s.vars.t == '3', 'group variables are parsed')
    local log = 'info: fine\nwarning: [SIMGATE] tick=3\nwarning: Error running lua script: x.lua(5): attempt to call a nil value\n         stack traceback:\n         \tx.lua:5: in function f\ninfo: next\nwarning: GetResource: Invalid name ""\nwarning: *AI ERROR: boom\n'
    local list = R.ParseLog(log)
    Check(table.getn(list) == 4 and string.find(list[1], 'Error running lua script', 1, true) and string.find(list[4], 'AI ERROR', 1, true), 'script warnings are kept, engine noise is dropped (' .. table.getn(list) .. ')')
end
