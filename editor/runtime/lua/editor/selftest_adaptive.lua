-- Self test of the adaptive map support (adaptive.lua, gui/panels_adaptive.lua, the ed_adaptive_* / ed_wreck_value natives of moho/editor/EdUpAdaptiveLua.cpp). Run in the live editor:
--   return import('/lua/editor/selftest_adaptive.lua').Run()       the natives against the expectations of upstream's own tests (AdaptiveModelTests, AdaptiveTablesTests, UnitFateTests,
--                                                                  GroupOptionsTests), then the model on a made-up adaptive map: edits change only their lines, undo / redo, the files written
--   return import('/lua/editor/selftest_adaptive.lua').Retail()    on the open adaptive map (a retail one: open it first): the mex groups of one option edited, the files written and compared
--                                                                  with the files the map was loaded from (only the edited lines may differ), the fate of five units
--
-- Upstream's GoogleTests cover the library itself (faf_editor_brush_tests, with FAF_DUALGAP_DIR set); this covers the binding and the Lua on top of it.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')
local Adaptive = import('/lua/editor/adaptive.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
end

local function Has(text, part)
    return text ~= nil and string.find(text, part, 1, true) ~= nil
end

local function Reporter()
    local failures, lines = {}, {}
    local R = {}
    function R.check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    function R.eq(name, got, want)
        R.check(name, got == want, 'got ' .. tostring(got) .. ', want ' .. tostring(want))
    end
    function R.done()
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
        return 'PASS (' .. table.getn(lines) .. ' checks)\n' .. Join(lines, '\n')
    end
    return R
end

local function Lines(text)
    local list = {}
    for line in string.gfind((text or '') .. '\n', '([^\n]*)\n') do table.insert(list, line) end
    return list
end

--- The lines that differ between two texts: { index, ... } among the lines both have; the second result is the number of lines `b` has more (a table the file lacked is appended), nil when it
--- has fewer (a row was dropped).
local function ChangedLines(a, b)
    local la, lb = Lines(a), Lines(b)
    if table.getn(lb) < table.getn(la) then return nil, table.getn(lb) - table.getn(la) end
    local out = {}
    for i = 1, table.getn(la) do
        if la[i] ~= lb[i] then table.insert(out, i) end
    end
    return out, table.getn(lb) - table.getn(la)
end

-- ---- upstream's fixtures (tests/editor/*.cpp) ---------------------------------------------------------------------------------------------------------

-- AdaptiveModelTests
local MODEL_SCRIPT = [[
local Tables = import('/maps/x/x_tables.lua')
local optional_wreckage = ScenarioInfo.Options.optional_wreckage or 1
local optional_naval_wreckage = ScenarioInfo.Options.optional_naval_wreckage or 1
local jamming = ScenarioInfo.Options.jamming or 1
function OptionalUnits()
    for w = 2, optional_wreckage do
        ScenarioUtils.CreateArmyGroup('ARMY_17', 'Optional_Wreckage_' .. w, true)
    end
    for n = 2, optional_naval_wreckage do
        ScenarioUtils.CreateArmyGroup('ARMY_17', 'Optional_Wreckage_Naval_'..n, true)
    end
    if jamming == 2 then
        ScenarioUtils.CreateArmyGroup('ARMY_17', 'Jamming', false)
    end
end
]]

local MODEL_OPTIONS = [[
options = {
{ default = 1, label = "Middle mexes", help = "More mexes.", key = 'middle_mexes', values = {
    { text = "none", help = "", key = 1, }, { text = "some", help = "", key = 2, }, }, },
{ default = 2, label = "Wreckage", help = "Wrecks.", key = 'optional_wreckage', values = {
    { text = "disabled", help = "No wrecks.", key = 1, }, { text = "T3 wreckage", help = "Mid.", key = 2, }, }, },
{ default = 1, label = "Jamming", key = 'jamming', values = {
    { text = "off", key = 1, }, { text = "on", key = 2, }, }, },
{ default = 1, label = "Mode", key = 'mode', values = { 'fast', 'slow' }, },
}
]]

-- UnitFateTests
local FATE_SCRIPT = [[
    if optional_wreckage > 1 then
        for w = 2, optional_wreckage do
            ScenarioUtils.CreateArmyGroup('ARMY_17', 'Optional_Wreckage_' .. w, true)
        end
    end
    if(optional_civilian_base == 2) then
        ScenarioUtils.CreateArmyGroup('ARMY_17', 'Optional_Civilian_Base_2', true)
    elseif(optional_civilian_base == 3) then
        ScenarioUtils.CreateArmyGroup('ARMY_17', 'Optional_Civilian_Base_2', false)
    end
    ScenarioUtils.CreateArmyGroup('ARMY_17', 'Outpost', false)
    ScenarioUtils.CreateArmyGroupAsPlatoon('ARMY_17', 'Patrol', 'GrowthFormation')
]]

local DESTROYER = [[UnitBlueprint {
    Categories = { "SELECTABLE", "CYBRAN", "NAVAL", "TECH2", "DESTROYER", },
    Economy = { BuildCostEnergy = 15000, BuildCostMass = 2250, },
    Wreckage = { Blueprint = "/props/DefaultWreckage/DefaultWreckage_prop.bp", EnergyMult = 0, HealthMult = 0.9, MassMult = 0.9, ReclaimTimeMultiplier = 1, },
}
]]

-- AdaptiveTablesTests
local TABLES = "-- enter maximum possible player count (army slots) on the map\nmaxPlayerOnMap = 4\n\n-- line number is the army's\nspwnMexArmy = {     {1,2,3},\n" ..
    "                    {4,5,6},\n                    {},\n                    {}}\n\nspwnHydroArmy ={    {1},\n                    {2},\n                    {},\n" ..
    "                    {}}\n\n-- configure the amount of mexes at a certain map position\nmiddleMexes = {{7,8},{9},{'9b'}}\nextraHydros = {{}}\n" ..
    "myOwnTable = { 'keep', 'me' } -- the mapper's own\nforwardCrazyrushMexes = {10}\ncrazyrushOneMexes = {}\n"

local GENERATED = "--[[  Generated by FAF Map Editor                                              ]]--\n-- Table of which resources belong to which player\n\nmaxPlayerOnMap = 3\n\n" ..
    "-- Line number is 10 + armynumber for the mexes in the table\nspwnMexArmy = {\t\t{16,17},\n                    {89,90}, -- the second\n                    {00,01}}\n\nmiddleMexes = {{7,8},{9}}\n"

-- ---- the natives ------------------------------------------------------------------------------------------------------------------------------------

local function Natives(R)
    for _, name in { 'ed_adaptive_known_tables', 'ed_adaptive_tables_parse', 'ed_adaptive_tables_write', 'ed_adaptive_options_of', 'ed_adaptive_fate', 'ed_adaptive_rule',
                     'ed_adaptive_spawn_targets', 'ed_wreck_value', 'ed_wreck_value_of' } do
        R.check('native ' .. name, rawget(_G, name) ~= nil)
    end
    if not rawget(_G, 'ed_adaptive_tables_parse') then return false end

    -- AdaptiveTables.EntriesAsTheScriptReadsThem
    R.eq('entry Mass 07', ed_adaptive_entry('Mass 07', false), '7')
    R.eq('entry Mass 12', ed_adaptive_entry('Mass 12', false), '12')
    R.eq('entry Mass 7', ed_adaptive_entry('Mass 7', false), "'7'")
    R.eq('entry Mass 9b', ed_adaptive_entry('Mass 9b', false), "'9b'")
    R.eq('entry Hydrocarbon 03', ed_adaptive_entry('Hydrocarbon 03', true), '3')
    R.eq('entry Hydrocarbon as mass', ed_adaptive_entry('Hydrocarbon 03', false), '')
    R.eq('marker 7', ed_adaptive_marker('7', false), 'Mass 07')
    R.eq('marker \'7\'', ed_adaptive_marker("'7'", false), 'Mass 7')
    R.eq('marker hydro 2', ed_adaptive_marker('2', true), 'Hydrocarbon 02')
    R.eq('option key', ed_adaptive_option_key('middleMexes'), 'middle_mexes')

    -- AdaptiveTables.ReadsTheTablesTheScriptUses
    local t, why = ed_adaptive_tables_parse(TABLES)
    R.check('tables parse', t ~= nil, why)
    if t then
        R.eq('maxPlayers', t.maxPlayers, 4)
        R.eq('mexArmy rows', table.getn(t.mexArmy), 4)
        R.eq('army 1 mexes', Join(t.mexArmy[1], ','), 'Mass 01,Mass 02,Mass 03')
        R.eq('army 4 empty', table.getn(t.mexArmy[4]), 0)
        R.eq('army 2 hydro', Join(t.hydroArmy[2], ','), 'Hydrocarbon 02')
        R.eq('option tables', table.getn(t.options), 2)
        R.eq('middleMexes', t.options[1].name, 'middleMexes')
        R.eq('middleMexes groups', t.options[1].groups[1][1] .. '|' .. t.options[1].groups[2][1] .. '|' .. t.options[1].groups[3][1], 'Mass 07|Mass 09|Mass 9b')
        R.eq('forward crazyrush', Join(t.forwardCrazyrush, ','), 'Mass 10')
        -- AdaptiveTables.AnEditChangesOnlyItsTable
        t.mexArmy[3] = { 'Mass 11', 'Mass 5' }
        local out = ed_adaptive_tables_write(TABLES, t)
        R.check('edit: army 3 row written in place', Has(out, "{11,'5'}"))
        R.check('edit: comments kept', Has(out, '-- enter maximum possible player count'))
        R.check('edit: the mapper\'s own table kept', Has(out, "myOwnTable = { 'keep', 'me' } -- the mapper's own"))
        R.check('edit: other groups kept', Has(out, 'middleMexes = {{7,8},{9},{\'9b\'}}'))
        local changed = ChangedLines(TABLES, out)
        R.check('edit: one line differs', changed ~= nil and table.getn(changed) == 1, changed and Join(changed, ',') or 'line count')
    end
    -- AdaptiveTables.AnEditKeepsTheGeneratedLayout
    local g = ed_adaptive_tables_parse(GENERATED)
    if g then
        g.mexArmy[1] = { 'Mass 16', 'Mass 18' }
        local out = ed_adaptive_tables_write(GENERATED, g)
        R.check('generated: only the army row changes', Has(out, "spwnMexArmy = {\t\t{16,18},\n                    {89,90}, -- the second\n                    {00,01}}\n"))
        g.options[1].groups[2] = { 'Mass 09', 'Mass 10' }
        R.check('generated: one option group', Has(ed_adaptive_tables_write(GENERATED, g), 'middleMexes = {{7,8},{9,10}}'))
    else
        R.check('generated tables parse', false)
    end
    R.check('broken text is an error', ed_adaptive_tables_parse('spwnMexArmy = {') == nil)
    R.eq('script import path', ed_adaptive_tables_path(MODEL_SCRIPT), '/maps/x/x_tables.lua')
    R.eq('no import path', ed_adaptive_tables_path(FATE_SCRIPT), '')

    -- AdaptiveModel.OptionsByKindInTheLobbysOrder
    local tables = { maxPlayers = 4, mexArmy = {}, hydroArmy = {}, options = { { name = 'middleMexes', groups = { { 'Mass 07' } } }, { name = 'sideMexes', groups = { { 'Mass 09' }, {} } } },
                     forwardCrazyrush = {}, crazyrushOne = {} }
    local o = ed_adaptive_options_of(MODEL_SCRIPT, MODEL_OPTIONS, tables)
    R.eq('model: six options', table.getn(o), 6)
    if table.getn(o) == 6 then
        R.eq('model 1 key', o[1].key, 'middle_mexes')
        R.eq('model 1 kind', o[1].kind, 'mexes')
        R.eq('model 1 table', o[1].table, 'middleMexes')
        R.check('model 1 read by the script', o[1].scriptReads)
        R.eq('model 2 kind', o[2].kind, 'levels')
        R.eq('model 2 loop prefix', o[2].loop.prefix, 'Optional_Wreckage_')
        R.eq('model 2 loop army', o[2].loop.army, 'ARMY_17')
        R.eq('model 2 loop from', o[2].loop.from, 2)
        R.check('model 2 loop wreck', o[2].loop.wreck)
        R.eq('model 2 title', o[2].title, 'Wreckage')
        R.eq('model 3 kind', o[3].kind, 'other')
        R.check('model 4 read by nothing', not o[4].scriptReads)
        R.eq('model 5 key', o[5].key, 'side_mexes')
        R.eq('model 5 not in the lobby', o[5].lobby, 0)
        R.eq('model 5 title', o[5].title, 'Side mexes')
        R.eq('model 6 key', o[6].key, 'optional_naval_wreckage')
        R.eq('model 6 title', o[6].title, 'Optional naval wreckage')
    end

    -- AdaptiveModel.WhatAChoiceAdds
    local lobby = ed_adaptive_options_parse(MODEL_OPTIONS)
    R.eq('four lobby options', table.getn(lobby), 4)
    R.eq('table group of "none"', ed_adaptive_table_group(lobby[1].values[1]), 0)
    R.eq('table group of "some"', ed_adaptive_table_group(lobby[1].values[2]), 1)
    local loop = { prefix = 'Optional_Wreckage_', from = 2 }
    R.eq('level group of "disabled"', ed_adaptive_level_group(loop, lobby[2].values[1]), '')
    R.eq('level group of "T3 wreckage"', ed_adaptive_level_group(loop, lobby[2].values[2]), 'Optional_Wreckage_2')
    local on = ed_adaptive_groups_made(MODEL_SCRIPT, MODEL_OPTIONS, 'jamming', 2)
    R.check('jamming on makes Jamming as units', table.getn(on) == 1 and on[1].group == 'Jamming' and on[1].unit and not on[1].maybe)
    R.eq('jamming off makes nothing', table.getn(ed_adaptive_groups_made(MODEL_SCRIPT, MODEL_OPTIONS, 'jamming', 1)), 0)

    -- AdaptiveModel.AnOptionWrittenBackKeepsItsKeys
    local w = lobby[2]
    w.values[2].text = 'T3 wrecks'
    w.defaultIndex = 1
    table.insert(w.values, ed_adaptive_next_level(w, 'level 2'))
    local text = ed_adaptive_option_put(MODEL_OPTIONS, w)
    local back = ed_adaptive_options_parse(text)
    R.eq('written back: four options', table.getn(back), 4)
    R.eq('written back: label kept', back[2].label, 'Wreckage')
    R.eq('written back: help kept', back[2].help, 'Wrecks.')
    R.eq('written back: default', back[2].defaultIndex, 1)
    R.eq('written back: three values', table.getn(back[2].values), 3)
    R.eq('written back: renamed value', back[2].values[2].text, 'T3 wrecks')
    R.eq('written back: help of a value kept', back[2].values[2].help, 'Mid.')
    R.eq('written back: next key', back[2].values[3].numberKey, 3)
    R.check('written back: string keys stay strings', not ed_adaptive_options_parse(ed_adaptive_option_put(MODEL_OPTIONS, ed_adaptive_options_parse(MODEL_OPTIONS)[4]))[4].values[1].number)
    R.check('written back: other options untouched', Has(text, "key = 'middle_mexes'"))

    -- UnitFate.* : what becomes of a unit (the five sampled units of the port's check)
    local function Fate(path, civilian) return ed_adaptive_fate(path, civilian, FATE_SCRIPT) end
    R.eq('fate: INITIAL unit', Fate({ 'INITIAL' }, false).kind, 'unit')
    R.eq('fate: WRECKAGE', Fate({ 'WRECKAGE' }, true).kind, 'wreck')
    local f = Fate({ 'Optional_Wreckage_2', 'Middle' }, true)
    R.eq('fate: level group is made as wrecks', f.kind, 'scriptWreck')
    R.eq('fate: level group named', f.group, 'Optional_Wreckage_2')
    R.eq('fate: either', Fate({ 'Optional_Civilian_Base_2' }, true).kind, 'scriptEither')
    R.eq('fate: script unit', Fate({ 'Outpost' }, true).kind, 'scriptUnit')
    R.eq('fate: platoon is a unit', Fate({ 'Patrol' }, true).kind, 'scriptUnit')
    R.eq('fate: exact names only', Fate({ 'Optional_Civilian_Base_3' }, true).kind, 'never')
    R.eq('fate: nothing creates it', Fate({ 'Spare' }, true).kind, 'never')
    R.check('fate: civilian INITIAL says Civilians', Has(Fate({ 'INITIAL' }, true).text, 'Civilians'))

    -- UnitFate.WreckValueAsUnitLuaMakesIt
    local dry = ed_wreck_value_of(DESTROYER, 2250, 15000, false)
    R.check('wreck: exists', dry.exists)
    R.eq('wreck: mass 2250 * 0.9 * 0.8', math.floor(dry.mass * 1000 + 0.5), 1620000)
    R.eq('wreck: energy 0', dry.energy, 0)
    R.eq('wreck: under water 0.6', math.floor(ed_wreck_value_of(DESTROYER, 2250, 15000, true).mass * 1000 + 0.5), 972000)
    R.check('wreck: no Wreckage table, no wreck', not ed_wreck_value_of('UnitBlueprint { Economy = { BuildCostMass = 50 } }', 50, 0, false).exists)
    local frigate = ed_wreck_value_of('UnitBlueprint { Categories = { "UEF", "NAVAL", "TECH1", }, Economy = { BuildCostMass = 280 } }', 280, 2000, false)
    R.check('wreck: a naval unit gets the default Wreckage', frigate.exists and math.floor(frigate.mass * 1000 + 0.5) == 226800)
    -- the rules' blueprint: the Salem destroyer of the game
    local w2 = ed_wreck_value('urs0201', false)
    if w2 and w2.known then
        R.eq('wreck_value urs0201 (the rules)', math.floor(w2.mass + 0.5), 1620)
    else
        R.check('wreck_value urs0201 (the rules)', w2 ~= nil, 'no answer')
    end
    return true
end

-- ---- the model on a made-up adaptive map ----------------------------------------------------------------------------------------------------------------

local function WriteFixture(dir)
    local script = MODEL_SCRIPT .. FATE_SCRIPT
    script = string.gsub(script, "/maps/x/x_tables%.lua", '/maps/_adaptive_test/x_tables.lua')
    local files = {
        ['x_scenario.lua'] = 'version = 3\nScenarioInfo = {}\n',
        ['x_script.lua'] = script,
        ['x_tables.lua'] = TABLES,
        ['x_options.lua'] = MODEL_OPTIONS,
    }
    for name, text in files do
        if not ed_write_file(dir .. '/' .. name, text) then return false, name end
    end
    return files
end

local function Model(R)
    local dir = '../mapout/_adaptive_test'
    local files, why = WriteFixture(dir)
    R.check('fixture written', files ~= false, why)
    if not files then return end
    ed_vfs_mount(dir, '/maps/_adaptive_test')

    local units = import('/lua/editor/units.lua')
    local armies = {
        ARMY_17 = { Units = { type = 'GROUP', orders = '', platoon = '', Units = {
            INITIAL = { type = 'GROUP', Units = { UNIT_1 = { type = 'uel0101', Position = { 10, 0, 10 }, Orientation = { 0, 0, 0 } } } },
            WRECKAGE = { type = 'GROUP', Units = { UNIT_2 = { type = 'urs0201', Position = { 20, 0, 20 }, Orientation = { 0, 0, 0 } } } },
            Optional_Wreckage_2 = { type = 'GROUP', Units = { Middle = { type = 'GROUP', Units = { UNIT_3 = { type = 'urs0201', Position = { 30, 0, 30 }, Orientation = { 0, 0, 0 } } } } } },
            Outpost = { type = 'GROUP', Units = { UNIT_4 = { type = 'uel0101', Position = { 40, 0, 40 }, Orientation = { 0, 0, 0 } } } },
            Spare = { type = 'GROUP', Units = { UNIT_5 = { type = 'uel0101', Position = { 50, 0, 50 }, Orientation = { 0, 0, 0 } } } },
        } } },
    }
    local real = Map.Doc
    local fake = { info = { Configurations = { standard = { teams = { { name = 'FFA', armies = { 'ARMY_1' } } } } } },
                   save = { Armies = armies, MasterChain = { _MASTERCHAIN_ = { Markers = {} } } },
                   scenarioPath = '/maps/_adaptive_test/x_scenario.lua', scriptPath = '/maps/_adaptive_test/x_script.lua' }
    Map.Doc = fake
    Adaptive.Reset()
    local depth = History.Depth()
    local ok, err = pcall(function()
        local f = Adaptive.Files()
        R.check('files: adaptive', f.adaptive)
        R.eq('files: tables path', f.tablesPath, '/maps/_adaptive_test/x_tables.lua')
        R.check('files: the script reads them', f.scriptReads)
        R.check('files: options', f.hasOptions)
        R.eq('tables text is the file', Adaptive.TablesText(), TABLES)
        local t = Adaptive.Tables()
        R.check('tables read', t ~= nil and t.maxPlayers == 4)

        -- an army's mex list: one line changes
        local r1, why1 = Adaptive.AssignToArmy(3, { 'Mass 11', 'Mass 5' })
        R.check('assign to army 3', r1 == true, why1)
        local c1 = ChangedLines(TABLES, Adaptive.TablesText())
        R.check('assign: only the army 3 line differs', c1 ~= nil and table.getn(c1) == 1, c1 and Join(c1, ',') or 'line count changed')
        R.eq('assign: options text untouched', Adaptive.OptionsText(), MODEL_OPTIONS)
        R.check('assign: the row is written as the script reads it', Has(Adaptive.TablesText(), "{11,'5'}"))

        -- a group of an option table: the table line and the lobby option
        local r2, why2 = Adaptive.AddToGroup('middleMexes', 4, { 'Mass 20' })
        R.check('new group of middleMexes', r2 == true, why2)
        R.check('group written', Has(Adaptive.TablesText(), '{{7,8},{9},{\'9b\'},{20}}'), Adaptive.TablesText())
        local opt = ed_adaptive_option_find(Adaptive.OptionsText(), 'middle_mexes')
        R.check('lobby option written: one value per group + none', opt.found and opt.values == 5, tostring(opt.values))
        local rest = ed_adaptive_options_parse(Adaptive.OptionsText())
        R.check('other lobby options kept', table.getn(rest) >= 4 and rest[2].key == 'optional_wreckage')
        local setup = Adaptive.Options()
        R.eq('setup: middle mexes by kind', setup[1].kind, 'mexes')

        -- undo / redo
        local edited = { tables = Adaptive.TablesText(), options = Adaptive.OptionsText() }
        History.Undo()
        History.Undo()
        R.eq('undo x2: tables are the file again', Adaptive.TablesText(), TABLES)
        R.eq('undo x2: options are the file again', Adaptive.OptionsText(), MODEL_OPTIONS)
        History.Redo()
        History.Redo()
        R.eq('redo x2: tables', Adaptive.TablesText(), edited.tables)
        R.eq('redo x2: options', Adaptive.OptionsText(), edited.options)

        -- a group removed: the lobby option follows
        local r3 = Adaptive.RemoveGroup('middleMexes', 4)
        R.check('group removed', r3 == true and Has(Adaptive.TablesText(), "middleMexes = {{7,8},{9},{'9b'}}"))
        R.eq('lobby option back to groups + none', ed_adaptive_option_find(Adaptive.OptionsText(), 'middle_mexes').values, 4)

        -- crazyrush, players
        R.check('crazyrush add', Adaptive.CrazyrushAdd('forward', { 'Mass 12' }) == true and Has(Adaptive.TablesText(), 'forwardCrazyrushMexes = {10,12}'))
        R.check('max players', Adaptive.SetMaxPlayers(5) == true and Has(Adaptive.TablesText(), 'maxPlayerOnMap = 5'))
        R.check('tables that do not read are refused', Adaptive.SetTexts('spwnMexArmy = {', nil, 'bad') == false)

        -- the fate of five sampled units, by the groups they sit in
        local want = { UNIT_1 = 'unit', UNIT_2 = 'wreck', UNIT_3 = 'scriptWreck', UNIT_4 = 'scriptUnit', UNIT_5 = 'never' }
        for name, kind in want do
            local info = Adaptive.FateOf('ARMY_17', name)
            R.eq('fate of ' .. name, info and info.fate.kind or 'nil', kind)
        end
        local info = Adaptive.FateOf('ARMY_17', 'UNIT_3')
        R.eq('fate: group path', Join(info.group, '/'), 'Optional_Wreckage_2/Middle')
        R.check('fate: rule says which lobby option', info.rule ~= nil and Has(Join(info.rule.lines, '\n'), 'optional_wreckage'), info.rule and Join(info.rule.lines, ' | ') or 'no rule')
        if info.wreck then R.eq('fate: wreck value of a destroyer', math.floor(info.wreck.mass + 0.5), 1620) end
        local targets = Adaptive.SpawnTargets('ARMY_17')
        R.check('spawn targets: the script\'s groups are offered', table.getn(targets) > 2)

        -- units into a group (one undo step)
        local moved = units.MoveToGroup({ { army = 'ARMY_17', name = 'UNIT_5' } }, 'Outpost')
        R.eq('moved one unit', moved, 1)
        R.eq('now scriptUnit', Adaptive.FateOf('ARMY_17', 'UNIT_5').fate.kind, 'scriptUnit')
        History.Undo()
        R.eq('undo: never again', Adaptive.FateOf('ARMY_17', 'UNIT_5').fate.kind, 'never')

        -- saving: the files of the folder, the script reads the new tables
        local out = '../mapout/_adaptive_test_out'
        R.check('files written', Adaptive.WriteFiles(out, 'y') == true)
        R.eq('written tables', ed_read_file(out .. '/y_tables.lua'), Adaptive.TablesText())
        R.eq('written options', ed_read_file(out .. '/y_options.lua'), Adaptive.OptionsText())
        local patched = Adaptive.PatchScript(files['x_script.lua'], '/maps/_adaptive_test_out', 'y')
        R.eq('script imports the new tables', ed_adaptive_tables_path(patched), '/maps/_adaptive_test_out/y_tables.lua')
    end)
    if not ok then R.check('model run', false, err) end
    -- put the session back: the real document, the history as it was
    while History.Depth() > depth do History.Undo() end
    History.DropRedo()
    Map.Doc = real
    Adaptive.Reset()
    units.Rev = units.Rev + 1
end

function Run()
    local R = Reporter()
    local ok, err = pcall(function()
        if Natives(R) then Model(R) end
    end)
    if not ok then R.check('run', false, err) end
    return R.done()
end

-- ---- an open retail adaptive map ----------------------------------------------------------------------------------------------------------------------

--- On the open map: edits the groups of the first option table that has any (one marker of its last group moved to the first), writes the files and compares them with the map's own: only the
--- lines of that table and of its lobby option may differ.
function Retail()
    local R = Reporter()
    local s = SessionGetScenarioInfo()
    local head = '[' .. string.lower(s and s.file or '?') .. '] '
    Adaptive.Reset()
    local files = Adaptive.Files()
    if not files.adaptive then return head .. 'not adaptive' end
    local original = { tables = Adaptive.TablesText(), options = Adaptive.OptionsText() }
    local tables, readWhy = Adaptive.Tables()
    if not tables then return head .. 'SKIP the tables do not read (an older template?): ' .. tostring(readWhy) end
    R.check('tables read', true)
    local depth = History.Depth()
    local target
    local regionNote = ''
    for _, opt in tables.options do
        if table.getn(opt.groups) >= 2 and table.getn(opt.groups[table.getn(opt.groups)]) >= 1 then target = opt end
    end
    if not target then
        -- no option table with two groups: a mex moves from one army's list to another's (two rows change, the lobby options do not)
        local from, to
        for a = 1, table.getn(tables.mexArmy) do
            if not from and table.getn(tables.mexArmy[a]) > 0 then from = a end
        end
        to = (from == 1) and 2 or 1
        if not from or to > table.getn(tables.mexArmy) then return head .. 'SKIP no army with mexes: ' .. R.done() end
        local moved = tables.mexArmy[from][1]
        R.check('mex moved to another army', Adaptive.AssignToArmy(to, { moved }) == true)
        local c = ChangedLines(original.tables, Adaptive.TablesText())
        R.check('only the two army rows differ', c ~= nil and table.getn(c) == 2, c and Join(c, ',') or 'line count changed')
        local oc0 = ChangedLines(original.options, Adaptive.OptionsText())
        R.check('_options.lua unchanged', oc0 ~= nil and table.getn(oc0) == 0)
        while History.Depth() > depth do History.Undo() end
        History.DropRedo()
        R.eq('undo: tables are the file again', Adaptive.TablesText(), original.tables)
        return head .. R.done() .. '\n  no option table with two groups; moved ' .. moved .. ' from ARMY_' .. from .. ' to ARMY_' .. to .. ', changed lines ' .. (c and Join(c, ',') or '?')
    end
    local last = table.getn(target.groups)
    local name = target.groups[last][1]
    local r = Adaptive.AddToGroup(target.name, 1, { name })       -- the marker joins group 1 (and leaves its own)
    R.check('edit written', r == true)
    local tc = ChangedLines(original.tables, Adaptive.TablesText())
    R.check('only the edited table line differs in _tables.lua', tc ~= nil and table.getn(tc) <= 2, tc and Join(tc, ',') or 'line count changed')
    local oc = ChangedLines(original.options, Adaptive.OptionsText())
    R.check('_options.lua unchanged by a move between groups', oc ~= nil and table.getn(oc) == 0, oc and Join(oc, ',') or 'line count changed')
    -- a new group: the table line and one more value of the lobby option, nothing else
    local grown = target.groups[last]
    if table.getn(grown) >= 2 then
        local more = grown[table.getn(grown)]
        local r2 = Adaptive.AddToGroup(target.name, table.getn(target.groups) + 1, { more })
        R.check('new group written', r2 == true)
        local tc2, tadd = ChangedLines(original.tables, Adaptive.TablesText())
        R.check('new group: one table line differs', tc2 ~= nil and table.getn(tc2) <= 2 and tadd == 0, tc2 and (Join(tc2, ',') .. ' +' .. tostring(tadd)) or 'lines dropped')
        local a, b = Lines(original.options), Lines(Adaptive.OptionsText())
        local p = 0
        while p < table.getn(a) and p < table.getn(b) and a[p + 1] == b[p + 1] do p = p + 1 end
        local q = 0
        while q < table.getn(a) - p and q < table.getn(b) - p and a[table.getn(a) - q] == b[table.getn(b) - q] do q = q + 1 end
        local removed, added = table.getn(a) - p - q, table.getn(b) - p - q
        local before, after = ed_adaptive_option_find(original.options, ed_adaptive_option_key(target.name)), ed_adaptive_option_find(Adaptive.OptionsText(), ed_adaptive_option_key(target.name))
        R.check('new group: the lobby option has one more value', before.found and after.found and after.values == before.values + 1, tostring(before.values) .. ' -> ' .. tostring(after.values))
        R.check('new group: only the value lines of the option change (' .. removed .. ' lines become ' .. added .. ' at line ' .. (p + 1) .. ')', added == removed + 1 and removed <= before.values, tostring(before.values))
        regionNote = '\n  new group of ' .. target.name .. ': tables lines ' .. (tc2 and Join(tc2, ',') or '?') .. ', options region at line ' .. (p + 1) .. ' ' .. removed .. ' -> ' .. added .. ' lines'
    end
    local out = '../mapout/_adaptive_retail'
    R.check('files written', Adaptive.WriteFiles(out, 'z') == true)
    R.eq('written tables are the edited text', ed_read_file(out .. '/z_tables.lua'), Adaptive.TablesText())
    local line = tc and tc[1] and Lines(Adaptive.TablesText())[tc[1]] or ''
    local fates = {}
    local Units = import('/lua/editor/units.lua')
    local n = 0
    for _, u in Units.CachedAll() do
        if n < 5 and (u.group ~= 'INITIAL') then
            local info = Adaptive.FateOf(u.army, u.name)
            if info then
                n = n + 1
                table.insert(fates, u.army .. '/' .. u.name .. ' ' .. u.bp .. ' [' .. u.group .. '] ' .. info.fate.text .. (info.wreck and info.wreck.exists and string.format(' wreck=%d', info.wreck.mass + 0.5) or ''))
            end
        end
    end
    while History.Depth() > depth do History.Undo() end
    History.DropRedo()
    R.eq('undo: tables are the map\'s again', Adaptive.TablesText(), original.tables)
    return head .. R.done() .. regionNote .. '\n  edited: ' .. target.name .. ' marker ' .. name .. ' to group 1; changed lines of the tables file: ' .. (tc and Join(tc, ',') or '?') .. '\n  ' .. line ..
        '\n  fates:\n    ' .. Join(fates, '\n    ')
end
