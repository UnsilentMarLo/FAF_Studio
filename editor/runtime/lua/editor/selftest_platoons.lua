-- Platoons / orders / builders self test. Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_platoons.lua').Run()
-- and the round trip over a real map (scripts/editor_platoons_flow.py drives it; the session is reloaded in between):
--   return import('/lua/editor/selftest_platoons.lua').RoundTripStart('<scenario path of a map with platoon builders>')    opens the map
--   return import('/lua/editor/selftest_platoons.lua').RoundTripEdit()       edits the platoons / orders / builders, saves a copy, writes what it expects, reopens the copy
--   return import('/lua/editor/selftest_platoons.lua').RoundTripVerify()     after the reload: what the saved copy holds is what was expected
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local PL = import('/lua/editor/platoons.lua')
local H = import('/lua/editor/history.lua')
local Ser = import('/lua/editor/luaser.lua')
local M = import('/lua/editor/mission.lua')

local out, failed, total = {}, 0, 0
Verbose = false

local function Check(ok, text)
    total = total + 1
    if not ok or Verbose then table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text) end
    if not ok then failed = failed + 1 end
end

local function Finish()
    table.insert(out, failed == 0 and ('ALL PASSED (' .. total .. ' checks)') or (failed .. ' FAILED of ' .. total))
    return table.concat(out, '\n')
end

local function Dump(v) return Ser.Dump(v, 0) end

local function HasProblem(list, pattern)
    for _, p in list do
        if string.find(p.text, pattern, 1, true) then return true end
    end
    return false
end

local function Errors(list)
    local n = 0
    for _, p in list do if p.sev == 'E' then n = n + 1 end end
    return n
end

local function UndoAll(depth)
    while H.Depth() > depth do H.Undo() end
end

--- The tables a real OpAI file holds (Scenario.Platoons and the builders of ARMY_1), read as the game reads them.
local function RealData()
    local env = {}
    doscript('/lua/dataInit.lua', env)
    local ok = pcall(doscript, '/lua/AI/OpAI/BasicLandAttack_save.lua', env)
    if not ok or not env.Scenario then return nil end
    return env.Scenario
end

function Run()
    out, failed, total = {}, 0, 0
    if not Map.Doc then Map.Load() end
    local doc = Map.Doc
    local depth0 = H.Depth()
    local savedMission = M.Data
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    local Units = import('/lua/editor/units.lua')
    local Tools = import('/lua/editor/tools.lua')
    pcall(function() import('/lua/editor/armies.lua').Sync(doc) end)
    local army = 'ARMY_1'
    Check(doc.save.Armies and doc.save.Armies[army] ~= nil, 'the test map has an army')
    local savedGroup, savedActive, savedArmy = Units.Group, Units.Active, Units.ArmyName
    Units.Group, Units.ArmyName = 'PTG1', army
    Units.Active = 'uel0106'
    Units.Place(60, 60) Units.Place(64, 60) Units.Place(68, 60)
    Units.Active = 'uel0105'
    Units.Place(72, 60)
    Check(table.getn(PL.GroupCounts(army, 'PTG1')) == 2, 'the group has two unit types')
    Check(table.getn(PL.GroupNames(army)) >= 1, 'GroupNames lists the group')
    local markersTable = doc.save.MasterChain._MASTERCHAIN_.Markers
    Tools.PlaceMarker(100, 100, 'Blank Marker', 'PT_M1')
    Tools.PlaceMarker(150, 100, 'Blank Marker', 'PT_M2')
    doc.save.Chains.PT_CH = { Markers = { 'PT_M1', 'PT_M2' } }

    -- templates
    local before = H.Depth()
    local name = PL.FromGroup(army, 'PTG1')
    Check(name == 'PLATOON_PTG1', 'FromGroup names the template after the group (' .. tostring(name) .. ')')
    local rows = PL.Rows(name)
    Check(table.getn(rows) == 2 and rows[1].bp == 'uel0105' and rows[1].max == 1 and rows[1].squad == 'support', 'rows: one per unit type, engineers are support')
    Check(rows[2].bp == 'uel0106' and rows[2].max == 3 and rows[2].min == 0 and rows[2].squad == 'attack', 'rows: counts become the maximum')
    Check(H.Depth() == before + 1, 'FromGroup is one undo step')
    H.Undo()
    Check(doc.save.Platoons[name] == nil, 'undo removes it')
    H.Redo()
    Check(doc.save.Platoons[name] ~= nil, 'redo brings it back')
    Check(PL.NewPlatoon('PT_B', 'AttackForceAI') == 'PT_B' and PL.Plan('PT_B') == 'AttackForceAI', 'NewPlatoon keeps the plan')
    Check(PL.NewPlatoon('PT_B') == nil, 'a name is not used twice')
    Check(PL.NewPlatoon('bad name!') == nil, 'a bad name is refused')
    local row = PL.AddRow('PT_B', { 'uel0106' })
    Check(row == 1 and PL.Rows('PT_B')[1].squad == 'attack', 'AddRow fills in the squad')
    PL.SetRow('PT_B', 1, 'max', 5)
    PL.SetRow('PT_B', 1, 'min', 7)
    local r = PL.Rows('PT_B')[1]
    Check(r.min == 7 and r.max == 7, 'raising the minimum raises the maximum with it')
    PL.SetRow('PT_B', 1, 'max', 2)
    r = PL.Rows('PT_B')[1]
    Check(r.min == 2 and r.max == 2, 'lowering the maximum lowers the minimum with it')
    PL.AddRow('PT_B', { 'uel0105', 0, 2, 'support', 'GrowthFormation' })
    PL.MoveRow('PT_B', 2, -1)
    Check(PL.Rows('PT_B')[1].bp == 'uel0105' and PL.Rows('PT_B')[1].formation == 'GrowthFormation', 'MoveRow swaps rows')
    PL.RemoveRow('PT_B', 1)
    Check(table.getn(PL.Rows('PT_B')) == 1, 'RemoveRow')
    -- slider drags fold into one step
    local d1 = H.Depth()
    PL.SetRow('PT_B', 1, 'max', 3, true) PL.SetRow('PT_B', 1, 'max', 4, true) PL.SetRow('PT_B', 1, 'max', 6, true)
    Check(H.Depth() == d1 + 1 and PL.Rows('PT_B')[1].max == 6, 'a slider drag is one undo step')
    H.Undo()
    Check(PL.Rows('PT_B')[1].max == 2, 'and undoing it restores the first value')
    H.Redo()

    -- orders
    Check(PL.NewOrders('PT_O') == 'PT_O', 'NewOrders')
    PL.AddOrder('PT_O', { type = 'Move', target = 'PT_M1' })
    PL.AddOrder('PT_O', { type = 'Patrol', chain = 'PT_CH' })
    PL.AddOrder('PT_O', { type = 'Attack', target = 'NO_SUCH_MARKER' })
    PL.AddOrder('PT_O', { type = 'Patrol', chain = 'NO_SUCH_CHAIN' })
    PL.AddOrder('PT_O', { type = 'Move' })
    local q = PL.Queue('PT_O')
    Check(table.getn(q) == 5 and q[2].chain == 'PT_CH', 'five orders in the queue')
    local problems = PL.Problems()
    Check(HasProblem(problems, 'no marker NO_SUCH_MARKER') or HasProblem(problems, 'there is no marker NO_SUCH_MARKER'), 'a missing marker is reported')
    Check(HasProblem(problems, 'there is no chain NO_SUCH_CHAIN'), 'a missing chain is reported')
    Check(HasProblem(problems, 'has no marker or chain'), 'an order without a target is reported')
    PL.SetOrder('PT_O', 3, 'target', 'PT_M2')
    PL.SetOrder('PT_O', 4, 'chain', 'PT_CH')
    PL.SetOrder('PT_O', 5, 'target', 'PT_M1')
    Check(not HasProblem(PL.Problems(), 'order queue PT_O'), 'the queue is clean once its targets exist')
    PL.SetOrder('PT_O', 5, 'chain', 'PT_CH')
    q = PL.Queue('PT_O')
    Check(q[5].target == '' and q[5].chain == 'PT_CH', 'a target is a marker or a chain, not both')
    PL.MoveOrder('PT_O', 5, -1)
    PL.RemoveOrder('PT_O', 1)
    Check(table.getn(PL.Queue('PT_O')) == 4, 'RemoveOrder')

    -- assigning and renaming
    Check(PL.AssignPlatoon(army, 'PTG1', name), 'AssignPlatoon puts the template on a group')
    local p1, o1 = PL.Assigned(army, 'PTG1')
    Check(p1 == name, 'Assigned reads it back')
    Check(PL.AssignOrders(army, 'PTG1', 'PT_O'), 'AssignOrders puts the queue on a group')
    Check(PL.AssignPlatoon(army, 'PTG1', 'NO_SUCH') == nil, 'a missing template is refused')
    Check(PL.NewBuilder(army, 'PT_BLD', name) == 'PT_BLD', 'NewBuilder')
    local rn, refs = PL.RenamePlatoon(name, 'PT_WEST')
    Check(rn and refs == 2, 'RenamePlatoon follows the group and the builder (' .. tostring(refs) .. ')')
    Check(PL.Builders(army).PT_BLD.PlatoonTemplate == 'PT_WEST', 'the builder uses the new name')
    Check((PL.Assigned(army, 'PTG1')) == 'PT_WEST', 'the group uses the new name')
    H.Undo()
    Check((PL.Assigned(army, 'PTG1')) == name and PL.Builders(army).PT_BLD.PlatoonTemplate == name and doc.save.Platoons[name] ~= nil, 'undo of the rename restores every reference')
    H.Redo()
    Check(table.getn(PL.UsedBy('platoon', 'PT_WEST')) == 2, 'UsedBy lists the group and the builder')
    Check(table.getn(PL.UsedBy('orders', 'PT_O')) == 1, 'UsedBy lists the group of the queue')

    -- builders
    PL.SetBuilder(army, 'PT_BLD', 'Priority', 300)
    PL.SetBuilder(army, 'PT_BLD', 'PlatoonType', 'Air')
    PL.SetBuilder(army, 'PT_BLD', 'AIFile', '/lua/ScenarioPlatoonAI.lua')
    PL.SetBuilder(army, 'PT_BLD', 'AIFunction', 'TransportPool')
    local b = PL.Builders(army).PT_BLD
    Check(b.Priority == 300 and b.PlatoonType == 'Air' and b.PlatoonAIFunction[2] == 'TransportPool', 'builder fields')
    Check(PL.AddCondition(army, 'PT_BLD', '/lua/editor/miscbuildconditions.lua', 'FactionIndex', '1, 2') == 1, 'AddCondition')
    b = PL.Builders(army).PT_BLD
    Check(b.BuildConditions[1][2] == 'FactionIndex' and table.getn(b.BuildConditions[1][3]) == 2 and b.BuildConditions[1][3][2] == '2', 'arguments are a list')
    PL.SetCondition(army, 'PT_BLD', 1, 'args', 'MAIN')
    Check(PL.Builders(army).PT_BLD.BuildConditions[1][3][1] == 'MAIN', 'SetCondition')
    Check(not HasProblem(PL.Problems(), 'builder PT_BLD'), 'a good builder has no problems')
    PL.SetBuilder(army, 'PT_BLD', 'PlatoonTemplate', 'GONE')
    Check(HasProblem(PL.Problems(), 'uses the missing platoon GONE'), 'a builder of a missing template is reported')
    PL.SetBuilder(army, 'PT_BLD', 'PlatoonTemplate', 'PT_WEST')
    Check(PL.DuplicateBuilder(army, 'PT_BLD') == 'PT_BLD_copy', 'DuplicateBuilder')
    Check(PL.RenameBuilder(army, 'PT_BLD_copy', 'PT_BLD2') and PL.Builders(army).PT_BLD2 and not PL.Builders(army).PT_BLD_copy, 'RenameBuilder')
    Check(PL.DeleteBuilder(army, 'PT_BLD2') and not PL.Builders(army).PT_BLD2, 'DeleteBuilder')

    -- the mission suite
    M.AddStage('Platoons')
    M.AddNode(1, 'enter', 'platoon_group')
    local node = M.Data.stages[1].enter[1]
    Check(node ~= nil and node.type == 'platoon_group', 'the platoon node is in the catalogue')
    M.SetParam(1, 'enter', 1, 'army', army) M.SetParam(1, 'enter', 1, 'group', 'PTG1')
    M.SetParam(1, 'enter', 1, 'platoon', 'PT_WEST') M.SetParam(1, 'enter', 1, 'orders', 'PT_O') M.SetParam(1, 'enter', 1, 'var', 'wave')
    M.AddNode(1, 'enter', 'orders_apply')
    M.SetParam(1, 'enter', 2, 'var', 'wave') M.SetParam(1, 'enter', 2, 'orders', 'PT_O')
    M.AddNode(1, 'enter', 'pbm_remove')
    M.SetParam(1, 'enter', 3, 'army', army) M.SetParam(1, 'enter', 3, 'builder', 'PT_BLD')
    local script = M.Compile(true)
    Check(string.find(script, "ScenarioUtils.FindUnitGroup('PTG1'", 1, true) and string.find(script, "node.platoon = 'PT_WEST'", 1, true), 'the template is set on the group before the spawn')
    Check(string.find(script, "V.wave = ScenarioUtils.CreateArmyGroupAsPlatoon('ARMY_1', 'PTG1'", 1, true), 'the platoon is kept in a variable')
    Check(string.find(script, "ScenarioUtils.MarkerToPosition('PT_M2')", 1, true) and string.find(script, "PlatoonPatrolChain(V.wave, 'PT_CH')", 1, true), 'orders compile to marker and chain calls')
    Check(string.find(script, ':AggressiveMoveToLocation(', 1, true) ~= nil and string.find(script, "V.wave:Stop()", 1, true) ~= nil, 'attack orders and the stop before a new queue')
    Check(string.find(script, "PBMRemoveBuilder('PT_BLD')", 1, true), 'the builder node compiles')
    local okLoad, chunk = pcall(loadstring, script)
    Check(okLoad and chunk ~= nil, 'the generated script compiles')
    local mp = M.Check()
    Check(Errors(mp) == 0, 'the mission check is clean (' .. Errors(mp) .. ' errors)')
    -- a rename follows the nodes
    PL.RenamePlatoon('PT_WEST', 'PT_EAST')
    Check(M.Data.stages[1].enter[1].platoon == 'PT_EAST', 'a platoon rename follows the mission node')
    PL.RenameOrders('PT_O', 'PT_Q')
    Check(M.Data.stages[1].enter[1].orders == 'PT_Q' and M.Data.stages[1].enter[2].orders == 'PT_Q', 'an order queue rename follows the mission nodes')
    PL.DeleteOrders('PT_Q')
    local mp2 = M.Check()
    local foundMissing = false
    for _, p in mp2 do if string.find(p.text, 'there is no order queue PT_Q', 1, true) then foundMissing = true end end
    Check(foundMissing, 'a deleted order queue is an error in the mission check')
    Check((PL.Assigned(army, 'PTG1')) == 'PT_EAST', 'the group still has its template')
    local _, oAfter = PL.Assigned(army, 'PTG1')
    Check(oAfter == '', 'the group lost the deleted queue')

    -- serialization: the tables survive the save file writer
    local text = Ser.Chunk({ { 'Scenario', doc.save } })
    local env = {}
    doscript('/lua/dataInit.lua', env)
    local okRead, chunk2 = pcall(loadstring, text)
    Check(okRead and chunk2 ~= nil, 'the save text compiles')
    if okRead and chunk2 then
        setfenv(chunk2, env)
        pcall(chunk2)
        local S = env.Scenario
        Check(S and Dump(S.Platoons) == Dump(doc.save.Platoons) and Dump(S.Orders) == Dump(doc.save.Orders), 'platoons and orders survive the writer')
        Check(S and Dump(S.Armies[army].PlatoonBuilders) == Dump(doc.save.Armies[army].PlatoonBuilders), 'builders survive the writer')
    end

    -- real OpAI data: a file the game itself reads
    local real = RealData()
    Check(real and real.Platoons and real.Armies and real.Armies.ARMY_1 and real.Armies.ARMY_1.PlatoonBuilders, 'the OpAI file was read')
    if real then
        local savePlat, saveBld = doc.save.Platoons, doc.save.Armies[army].PlatoonBuilders
        doc.save.Platoons = real.Platoons
        doc.save.Armies[army].PlatoonBuilders = real.Armies.ARMY_1.PlatoonBuilders
        local names = PL.PlatoonNames()
        Check(table.getn(names) > 5 and table.getn(PL.BuilderNames(army)) > 5, 'the game\'s own templates and builders are listed (' .. table.getn(names) .. ' / ' .. table.getn(PL.BuilderNames(army)) .. ')')
        local rp = PL.Problems()
        local badTemplates = 0
        for _, p in rp do if p.sev == 'E' and (string.find(p.text, '^platoon ') or string.find(p.text, '^builder ')) then badTemplates = badTemplates + 1 end end
        Check(badTemplates == 0, 'no errors on the game\'s own data (' .. badTemplates .. ')')
        local t2 = Ser.Chunk({ { 'Scenario', { Platoons = doc.save.Platoons, Armies = { [army] = { PlatoonBuilders = doc.save.Armies[army].PlatoonBuilders } } } } })
        local env2 = {}
        doscript('/lua/dataInit.lua', env2)
        local ok2, c3 = pcall(loadstring, t2)
        if ok2 and c3 then
            setfenv(c3, env2)
            pcall(c3)
            Check(Dump(env2.Scenario.Platoons) == Dump(real.Platoons) and Dump(env2.Scenario.Armies[army].PlatoonBuilders) == Dump(real.Armies.ARMY_1.PlatoonBuilders), 'the game\'s data survives the save writer unchanged')
        else
            Check(false, 'the OpAI save text compiles')
        end
        doc.save.Platoons, doc.save.Armies[army].PlatoonBuilders = savePlat, saveBld
    end

    -- clean up: every edit undone, the units and markers removed
    M.Data = savedMission
    UndoAll(depth0)
    Check(next(doc.save.Platoons or {}) == nil, 'undoing everything leaves no platoon behind')
    Check(next(doc.save.Orders or {}) == nil, 'and no order queue')
    markersTable.PT_M1 = nil markersTable.PT_M2 = nil
    doc.save.Chains.PT_CH = nil
    Units.Group, Units.Active, Units.ArmyName = savedGroup, savedActive, savedArmy
    return Finish()
end

-- ---- the round trip over a real map ---------------------------------------------------------------------------------------------------------------

local EXPECT = 'editor_platoons_expect.txt'
local COPY_DIR = '../mapout/platoon_roundtrip.v0001'
local COPY_STEM = 'platoon_roundtrip'

function RoundTripStart(scenario)
    import('/lua/editor/maps.lua').Open(scenario)
    return 'opening'
end

local function Snapshot(doc)
    local army = PL.Armies()[1]
    local t = { Platoons = doc.save.Platoons or {}, Orders = doc.save.Orders or {}, Builders = {} }
    for _, a in PL.Armies() do t.Builders[a] = PL.Builders(a) or {} end
    return Dump(t)
end

--- Describes the loaded map for the driver (what it has) and edits it: renames a platoon and its references, changes a builder, adds a platoon from a group, an order queue and a builder.
function RoundTripEdit()
    out, failed, total = {}, 0, 0
    if not Map.Doc then Map.Load() end
    local doc = Map.Doc
    local before = Snapshot(doc)
    local armies = PL.Armies()
    local army, builders
    for _, a in armies do
        if PL.Builders(a) and next(PL.Builders(a)) then army = a builders = PL.BuilderNames(a) break end
    end
    if not army then return 'FAIL the map has no platoon builders' end
    local first = builders[1]
    local nBefore = table.getn(builders)
    table.insert(out, 'map: ' .. tostring(doc.info.name) .. ', army ' .. army .. ', ' .. nBefore .. ' builders, ' .. table.getn(PL.PlatoonNames()) .. ' platoons, ' .. table.getn(PL.OrderNames()) .. ' order queues')
    PL.SetBuilder(army, first, 'Priority', (tonumber(PL.Builders(army)[first].Priority) or 0) + 7)
    local plat = PL.Builders(army)[first].PlatoonTemplate
    if plat and doc.save.Platoons[plat] then
        PL.RenamePlatoon(plat, plat .. '_X')
    end
    local groups = PL.GroupNames(army)
    local newPlat
    for _, g in groups do
        if table.getn(PL.GroupCounts(army, g)) > 0 then newPlat = PL.FromGroup(army, g, 'RT_FROM_GROUP') break end
    end
    PL.NewOrders('RT_QUEUE')
    local markers = M.MarkerNames()
    if markers[1] then PL.AddOrder('RT_QUEUE', { type = 'Move', target = markers[1] }) end
    PL.AddOrder('RT_QUEUE', { type = 'Stop' })
    PL.NewBuilder(army, 'RT_BUILDER', newPlat or plat)
    PL.AddCondition(army, 'RT_BUILDER', '/lua/editor/miscbuildconditions.lua', 'FactionIndex', '1')
    local after = Snapshot(doc)
    Check(after ~= before, 'the edits changed the data')
    ed_write_file(EXPECT, after)
    local Maps = import('/lua/editor/maps.lua')
    local scenario, why = Maps.SaveTo(COPY_DIR, COPY_STEM)
    if not scenario then return 'FAIL save: ' .. tostring(why) end
    table.insert(out, 'saved ' .. scenario)
    Maps.Open(scenario)
    table.insert(out, Finish())
    return table.concat(out, '\n')
end

function RoundTripVerify()
    out, failed, total = {}, 0, 0
    if not Map.Doc then Map.Load() end
    local expect = ed_read_file(EXPECT)
    Check(expect ~= nil and expect ~= '', 'the expected data was written before the reload')
    local got = Snapshot(Map.Doc)
    Check(got == expect, 'the reloaded copy holds exactly the edited platoons, orders and builders (' .. string.len(got) .. ' / ' .. string.len(expect or '') .. ' characters)')
    if got ~= expect and expect then
        -- the first difference, for the report
        local n = math.min(string.len(got), string.len(expect))
        for i = 1, n do
            if string.sub(got, i, i) ~= string.sub(expect, i, i) then
                table.insert(out, 'first difference at ' .. i .. ': ...' .. string.sub(got, math.max(1, i - 40), i + 40) .. ' | expected ...' .. string.sub(expect, math.max(1, i - 40), i + 40))
                break
            end
        end
    end
    Check(table.getn(PL.PlatoonNames()) > 0, 'platoons are there')
    Check(Errors(PL.Problems()) == 0, 'the copy has no platoon errors (' .. Errors(PL.Problems()) .. ')')
    return Finish()
end
