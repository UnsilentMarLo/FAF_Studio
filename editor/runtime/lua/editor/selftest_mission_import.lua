-- Mission import self test: a hand-written mission script is shown in the mission editor as read-only imported stages and never rewritten. Through /edcmd, in an /editor session:
--   return import('/lua/editor/selftest_mission_import.lua').Run()
-- Runs the parser on small inline scripts (comments and strings, nested blocks, objectives, triggers, AI helpers, the strings file), walks the model through the rules (imported stages
-- are never compiled, never written to the script, never saved to the sidecar, editor stages can follow them), and reads the Operation Citadel script when its file is on disk.
--
-- Lua 5.0 dialect.

local I = import('/lua/editor/missionimport.lua')
local M = import('/lua/editor/mission.lua')

local out, failed, total = {}, 0, 0

--   CitadelDir     where the files of the Operation Citadel map are (path prefix up to `Operation_Citadel_`); the test is skipped when the script is not there. Set it before Run().
CitadelDir = '/tmp/claude-0/-home-user/0950802f-64ee-5af0-964b-74a587770188/scratchpad/citadel/Operation_Citadel.v0001/Operation_Citadel_'

local function Check(ok, text)
    total = total + 1
    if not ok then
        failed = failed + 1
        table.insert(out, '  FAIL ' .. text)
    end
end

local SCRIPT = table.concat({
    'local Objectives = import(\'/lua/ScenarioFramework.lua\').Objectives',
    'local M1AI = import(\'/maps/demo/demo_m1ai.lua\')',
    'local OpStrings = import(\'/maps/demo/demo_strings.lua\')',
    '-- ScenarioInfo.MissionNumber = 9',
    '--[[ ScenarioInfo.MissionNumber = 8',
    'function Ghost() end ]]',
    'local text = "ScenarioInfo.MissionNumber = 7 function Fake() end"',
    'local Difficulty = ScenarioInfo.Options.Difficulty',
    '',
    'function OnPopulate()',
    '    ScenarioUtils.InitializeScenarioArmies()',
    '    M1AI.BaseAI()',
    'end',
    '',
    'function IntroMission1()',
    '    ScenarioInfo.MissionNumber = 1',
    '    StartMission1()',
    'end',
    '',
    'function StartMission1()',
    '    for i = 1, 3 do',
    '        local p = ScenarioUtils.CreateArmyGroupAsPlatoon(\'Enemy\', \'G\' .. i, \'GrowthFormation\')',
    '        ScenarioFramework.PlatoonPatrolChain(p, \'Chain\')',
    '    end',
    '    ScenarioInfo.M1P1 = Objectives.Kill(',
    '        \'primary\',                 -- type',
    '        \'incomplete\',',
    '        \'Kill it\',                 -- title',
    '        "Destroy \'it\' now",        -- description',
    '        { Units = { ScenarioInfo.Boss } }',
    '    )',
    '    ScenarioInfo.M1P1:AddResultCallback(function(result)',
    '        if result then IntroMission2() end',
    '    end)',
    '    ScenarioFramework.CreateTimerTrigger(Remind, 4 * 60)',
    '    ScenarioFramework.Dialogue(OpStrings.M1_START, nil, true)',
    '    if Difficulty == 3 then',
    '        repeat WaitSeconds(1) until ScenarioInfo.Done',
    '    end',
    'end',
    '',
    'function Remind()',
    '    if ScenarioInfo.M1P1.Active then end',
    'end',
    '',
    'function IntroMission2()',
    '    if ScenarioInfo.MissionNumber == 2 or ScenarioInfo.MissionNumber == 3 then return end',
    '    ScenarioInfo.MissionNumber = 2',
    'end',
}, '\n') .. '\n'

local STRINGS = table.concat({
    'OPERATION_NAME = --[[LOC OPNAME]]\'Operation: Demo\'',
    'BriefingData = {',
    '  {phase = 0, character = --[[LOC Date]]\'Date\', text = --[[LOC B1]]\'06-June-3858\'},',
    '  {phase = 1, character = \'Hall\', text = \'We\\\'re ready, it\\\'s "go".\'},',
    '}',
    'DEMO_M01_010 = {',
    '  {text = --[[LOC X]]\'[{i HQ}]: All commanders are on-planet.\', vid = \'a.sfd\', bank = \'VO\', cue = \'cue1\', faction = \'NONE\'},',
    '  {text = \'second line\', delay = 7},',
    '}',
    '-- DEMO_M01_020 = { {text = \'commented out\'} }',
    'DEMO_OBJ = { Count = 3 }',
}, '\n') .. '\n'

local function Names(list, field)
    local t = {}
    for _, v in list do table.insert(t, tostring(v[field])) end
    return table.concat(t, ',')
end

--- The parser on the inline script.
local function RunParser()
    local o = I.Parse(SCRIPT)
    Check(table.getn(o.stages) == 2 and o.stages[1].number == 1 and o.stages[2].number == 2, 'two stages (1, 2): the commented, quoted and block-commented MissionNumber lines are not stages (' .. Names(o.stages, 'number') .. ')')
    Check(o.stages[1].entry == 'IntroMission1', 'stage 1 is entered by IntroMission1')
    local f = {}
    for _, fn in o.functions do f[fn.name] = fn end
    Check(f.Ghost == nil and f.Fake == nil, 'functions inside comments and strings are not found')
    Check(f.IntroMission1 and f.IntroMission1.line == 15 and f.IntroMission1.endLine == 18, 'IntroMission1 spans lines 15-18 (' .. tostring(f.IntroMission1 and f.IntroMission1.line) .. '-' .. tostring(f.IntroMission1 and f.IntroMission1.endLine) .. ')')
    Check(f.StartMission1 and f.StartMission1.line == 20 and f.StartMission1.endLine == 40, 'StartMission1 spans its nested blocks to line 40 (' .. tostring(f.StartMission1 and f.StartMission1.endLine) .. ')')
    Check(f.OnPopulate and f.OnPopulate.stage == nil, 'OnPopulate belongs to no stage')
    Check(f.Remind and f.Remind.stage == 1 and f.Remind.how == 'called', 'Remind is only called from stage 1')
    Check(f.IntroMission2 and f.IntroMission2.stage == 2 and f.IntroMission2.how == 'sets', 'IntroMission2 sets MissionNumber 2')
    Check(o.referenced[3] ~= nil and string.find(table.concat(o.notes, ' '), 'MissionNumber 3', 1, true) ~= nil, 'MissionNumber 3 is checked but never set: a note')
    Check(table.getn(o.objectives) == 1, 'one objective (' .. table.getn(o.objectives) .. ')')
    local ob = o.objectives[1]
    if ob then
        Check(ob.title == 'Kill it' and ob.description == "Destroy 'it' now" and ob.otype == 'primary', 'objective type, title and description are the literals without the comments')
        Check(ob.var == 'ScenarioInfo.M1P1' and ob.stage == 1 and ob.line == 25, 'objective variable, stage and line (' .. tostring(ob.var) .. ' ' .. tostring(ob.stage) .. ' ' .. tostring(ob.line) .. ')')
    end
    local kinds = {}
    for _, t in o.triggers do kinds[t.kind] = t.callback end
    Check(kinds.CreateTimerTrigger == 'Remind' and kinds.AddResultCallback == '(inline function)', 'trigger callbacks: a named function and an inline one')
    local helpers = {}
    for _, h in o.helpers do helpers[h.name] = h.kind end
    Check(helpers['M1AI.BaseAI'] == 'ai module' and helpers['ScenarioUtils.CreateArmyGroupAsPlatoon'] == 'platoon' and helpers['ScenarioFramework.PlatoonPatrolChain'] == 'platoon',
        'AI module call and platoon helpers are listed by name')
    Check(o.dialogueRefs[1] and o.dialogueRefs[1].name == 'OpStrings.M1_START', 'the dialogue table a Dialogue call plays')
    Check(o.difficulty.uses >= 2 and o.difficulty.branches == 1, 'difficulty: uses and one comparison (' .. o.difficulty.uses .. ' / ' .. o.difficulty.branches .. ')')
    Check(table.getn(o.imports) == 3 and o.imports[2].ai == true and o.imports[3].ai == false, 'imports, the AI module marked')
    local stages = I.Stages(o)
    Check(table.getn(stages) == 3 and stages[1].info.number == 0 and stages[2].info.number == 1 and stages[3].info.number == 2, 'model stages: script setup, 1, 2')
    Check(stages[2].imported == true and table.getn(stages[2].enter) == 0 and table.getn(stages[2].ready) == 0, 'imported stages carry no nodes')
    Check(table.getn(I.Rows(stages[2].info)) > 6, 'the outline has rows')

    -- blocks that must not confuse the function ends
    local o2 = I.Parse("function A()\n  local t = { f = function() return 1 end }\n  while x do\n    if y then z() elseif w then q() else r() end\n  end\nend\nfunction B() end\n")
    local g = {}
    for _, fn in o2.functions do g[fn.name] = fn end
    Check(g.A and g.A.line == 1 and g.A.endLine == 6 and g.B and g.B.line == 7, 'nested function, while and if..elseif..else close in the right place')
    local o3 = I.Parse("ScenarioInfo.MissionNumber = 4\nx = 'unclosed\nfunction Late() end\n")
    Check(o3.stages[1] and o3.stages[1].number == 4, 'a stage number set at file level is a stage')
    Check(table.getn(I.Parse('').stages) == 0 and table.getn(I.Parse('function OnStart(self) end').stages) == 0, 'empty and stage-less scripts have no stages')
end

--- The strings file.
local function RunStrings()
    local list = I.ParseStrings(STRINGS)
    local by = {}
    for _, d in list do by[d.name] = d end
    Check(by.BriefingData and table.getn(by.BriefingData.lines) == 2, 'BriefingData has its two lines')
    Check(by.BriefingData and by.BriefingData.lines[1].speaker == 'Date' and by.BriefingData.lines[1].text == '06-June-3858', 'a comment between the key and the string is skipped')
    Check(by.BriefingData and by.BriefingData.lines[2].text == 'We\'re ready, it\'s "go".', 'escaped quotes are unescaped')
    local d = by.DEMO_M01_010
    Check(d and table.getn(d.lines) == 2 and d.lines[1].speaker == 'HQ' and d.lines[1].text == 'All commanders are on-planet.', 'the [{i Speaker}]: prefix becomes the speaker')
    Check(d and d.lines[1].vid == 'a.sfd' and d.lines[1].bank == 'VO' and d.lines[1].cue == 'cue1' and d.lines[1].faction == 'NONE' and d.lines[2].seconds == 7, 'vid, bank, cue, faction and the delay are kept')
    Check(by.DEMO_M01_020 == nil and by.DEMO_OBJ == nil, 'a commented table and a table without text lines are not dialogues')
    Check(by['Text strings'] and by['Text strings'].lines[1].speaker == 'OPERATION_NAME' and by['Text strings'].lines[1].text == 'Operation: Demo', 'plain string entries are listed in one dialogue')
    Check(by.BriefingData and by.BriefingData.imported == true, 'imported dialogues are marked')
end

--- The model: imported stages are read-only, not compiled, not written, not saved.
local function RunModel()
    local saved = M.Data
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    local ok = M.ImportText(SCRIPT, STRINGS, { type = 'campaign_coop', script = '/maps/demo/demo_script.lua' })
    Check(ok and M.IsImported() and M.EditorStageCount() == 0 and M.ImportedStageCount() == 3, 'ImportText imports 3 stages and no editor stage')
    Check(M.Data.mode == 'both', 'a campaign_coop map imports as mode both')
    Check(table.getn(M.Data.dialogues) >= 3 and M.Data.dialogues[1].imported == true, 'the strings are in Data.dialogues')

    Check(M.PatchScript(SCRIPT) == SCRIPT, 'PatchScript leaves the script untouched')
    local patched, state = M.PatchScript(SCRIPT)
    Check(state == 'none' and patched == SCRIPT, 'and says there is no mission to write (' .. tostring(state) .. ')')
    Check(M.SidecarText() == '', 'an imported-only mission writes no sidecar text')
    Check(table.getn(M.Check()) == 0, 'an imported-only mission has no findings')
    Check(M.ScenarioType('campaign_coop') == 'campaign_coop' and M.ScenarioType('campaign') == 'campaign', 'the scenario type is left as it is')

    Check(not M.RemoveStage(1) and not M.SetStage(2, 'name', 'x') and not M.MoveStage(2, 1) and not M.AddNode(2, 'ready', 'wait'), 'imported stages refuse removal, rename, move and nodes')
    Check(not M.RemoveDialogue(1) and not M.AddLine(1, 'x') and not M.SetLine(1, 1, 'text', 'x') and not M.RemoveLine(1, 1), 'imported dialogues refuse edits')
    Check(M.FindDialogue('BriefingData') == nil and table.getn(M.DialogueNames()) == 0, 'imported dialogues are not offered to nodes')
    Check(M.StageByNumber(2) and M.StageByNumber(2).info.number == 2 and M.StageByNumber(5) == nil, 'StageByNumber finds an imported stage by its script number')

    -- an editor stage behind the imported ones
    M.AddStage('Mine')
    M.AddNode(4, 'ready', 'end')
    Check(M.EditorStageCount() == 1 and table.getn(M.Data.stages) == 4 and not M.Data.stages[4].imported, 'an editor stage is added behind the imported ones')
    Check(not M.MoveStage(4, -1), 'it cannot be moved in front of an imported stage')
    local text = M.Compile(true)
    Check(loadstring(text) ~= nil, 'the compiled region loads')
    Check(string.find(text, 'Stage[4] = function', 1, true) ~= nil and string.find(text, 'Stage[1] = function', 1, true) == nil, 'only the editor stage is compiled, under its own number')
    Check(string.find(text, 'EditorStartStage or 4', 1, true) ~= nil, 'the editor run starts at the first editor stage')
    Check(string.find(text, 'IntroMission1', 1, true) == nil and string.find(text, 'Kill it', 1, true) == nil and string.find(text, 'BriefingData', 1, true) == nil, 'nothing of the script or its strings is in the generated text')
    local written, state2 = M.PatchScript(SCRIPT)
    Check(state2 == 'written' and string.sub(written, 1, string.len(SCRIPT)) == SCRIPT, 'the region is appended behind the unchanged script')
    local again, state3 = M.PatchScript(written)
    Check(state3 == 'written' and again == written, 'and patching again changes nothing')
    Check(table.getn(M.Check()) == 0, 'no findings for the mixed mission')

    local side = M.SidecarText()
    local env = {}
    local f = loadstring(side)
    Check(f ~= nil and side ~= '', 'the sidecar text loads')
    if f then
        setfenv(f, env)
        f()
        local m = env.Mission
        Check(m and table.getn(m.stages) == 1 and m.stages[1].name == 'Mine' and m.keepImport == true, 'the sidecar keeps the editor stage and keepImport')
        Check(m and table.getn(m.dialogues) == 0 and not m.imported, 'but not the imported dialogues')
        Check(string.find(side, 'IntroMission1', 1, true) == nil and string.find(side, 'Kill it', 1, true) == nil and string.find(side, 'We\'re ready', 1, true) == nil, 'and no text of the script or the strings')
    end
    -- loading it back imports again behind nothing, the editor stage keeps its place
    local mine = M.Data.stages[4]
    M.Data = { mode = 'campaign', stages = { mine }, bases = {}, dialogues = {}, keepImport = true }
    Check(M.ImportText(SCRIPT, STRINGS, { type = 'campaign_coop' }) and table.getn(M.Data.stages) == 4 and M.Data.stages[4] == mine and M.Data.mode == 'campaign', 'a reload imports again in front of the editor stage (mode of the sidecar kept)')

    -- a script that is already the editor's own region only is no import
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    Check(not M.ImportText(written, nil, {}) or M.ImportedStageCount() == 3, 'the region the editor wrote is not imported (the script outside it is)')
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    local onlyRegion = string.sub(written, string.len(SCRIPT) + 1)
    Check(not M.ImportText(onlyRegion, nil, {}) and M.ImportedStageCount() == 0, 'a script that only holds the generated region has nothing to import')
    M.Data = saved
end

--- The real Operation Citadel script, when its file is there (the map of the bug report).
local function RunCitadel()
    local base = CitadelDir
    if not rawget(_G, 'ed_read_file') then return 'skipped (no ed_read_file)' end
    local ok, script = pcall(ed_read_file, base .. 'script.lua')
    if not ok or not script then return 'skipped (file not found)' end
    local o = I.Parse(script)
    Check(table.getn(o.stages) == 2 and o.stages[1].entry == 'IntroMission1' and o.stages[2].entry == 'IntroMission2', 'Citadel: two stages entered by IntroMission1 / IntroMission2')
    Check(table.getn(o.objectives) == 2 and o.objectives[1].title == 'Destroy the Seraphim support Bases' and o.objectives[2].title == 'Defeat the Seraphim Commanders', 'Citadel: both objectives with their titles')
    local ai = 0
    for _, h in o.helpers do
        if h.kind == 'ai module' then ai = ai + 1 end
    end
    Check(ai >= 4, 'Citadel: the Seraphim AI module calls are found (' .. ai .. ')')
    local ok2, strings = pcall(ed_read_file, base .. 'strings.lua')
    if ok2 and strings then
        local list = I.ParseStrings(strings)
        Check(table.getn(list) > 10 and list[1].name == 'BriefingData' and table.getn(list[1].lines) == 6, 'Citadel: BriefingData and the dialogue tables of the strings file')
    end
    return 'ran'
end

function Run()
    out, failed, total = {}, 0, 0
    RunParser()
    RunStrings()
    RunModel()
    local citadel = RunCitadel()
    table.insert(out, 'Citadel script: ' .. citadel)
    table.insert(out, failed == 0 and ('ALL PASSED (' .. total .. ' checks)') or (failed .. ' FAILED of ' .. total))
    return table.concat(out, '\n')
end
