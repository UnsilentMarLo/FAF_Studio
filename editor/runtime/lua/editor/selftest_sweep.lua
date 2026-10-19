-- Self test of the sweep batch (docs/projects/editor/PARITY_FINAL.md). Through /edcmd:
--   return import('/lua/editor/selftest_sweep.lua').Run()
-- Select the same / same group / all of a kind; idempotent (it removes what it made).

local Same = import('/lua/editor/selectsame.lua')
local Tools = import('/lua/editor/tools.lua')
local Map = import('/lua/editor/map.lua')
local Units = import('/lua/editor/units.lua')
local History = import('/lua/editor/history.lua')

local out, failed = {}, 0
local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

function Run()
    out, failed = {}, 0
    if not Map.Doc then Map.Load() end
    local depth = History.Depth()
    Tools.Select(false)
    Units.ClearSelection()
    Ok(Same.Describe() == nil, 'nothing selected: nothing to describe')
    Ok(Same.Same() == 0, 'and nothing is selected by "the same"')

    -- markers: three Mass, one Hydrocarbon
    local a = Tools.PlaceMarker(40, 40, 'Mass')
    local b = Tools.PlaceMarker(60, 40, 'Mass')
    local c = Tools.PlaceMarker(80, 40, 'Mass')
    local h = Tools.PlaceMarker(100, 40, 'Hydrocarbon')
    Tools.Select('marker', a)
    local kind, value, text = Same.Describe()
    Ok(kind == 'marker type' and value == 'Mass', 'a selected marker describes its type: ' .. tostring(text))
    local n = Same.Same()
    local hit = 0
    for _, it in Tools.Items do if it.name == a or it.name == b or it.name == c then hit = hit + 1 end end
    Ok(n >= 3 and hit == 3, 'select the same selects all Mass markers (' .. n .. ')')
    Ok(not Tools.IsSelected('marker', h), 'and not the Hydrocarbon one')
    Ok(Same.Everything('marker') >= 4 and Tools.IsSelected('marker', h), 'select all markers takes the Hydrocarbon one too')

    -- units: two groups of one army
    Tools.Select(false)
    local army = 'ARMY_1'
    Units.Active = 'uel0106'
    Units.ArmyName = army
    Units.Group = 'INITIAL'
    Units.Place(50, 90)
    Units.Place(56, 90)
    local list = Units.All()
    local first
    for _, u in list do if u.x > 49 and u.x < 51 and u.z > 89 and u.z < 91 then first = u end end
    Ok(first ~= nil, 'units placed')
    if first then
        Units.Selection = {}
        Units.Select(first, 'set')
        local k, v = Same.Describe()
        Ok(k == 'unit blueprint' and v == 'uel0106', 'a selected unit describes its blueprint')
        local g = Same.UnitGroup()
        local inGroup = 0
        for _, e in Units.All() do if e.army == first.army and e.group == first.group then inGroup = inGroup + 1 end end
        Ok(g == inGroup and g >= 2, 'select units of the same group selects the whole group (' .. g .. ')')
        Ok(Same.Same() >= 2, 'select the same selects the units of that blueprint')
        Ok(Same.Everything('unit') == table.getn(Units.All()), 'select all units')
    end
    -- undo what was placed
    Units.ClearSelection()
    Tools.Select(false)
    while History.Depth() > depth do History.Undo() end
    Ok(Tools.Items and table.getn(Tools.Items) == 0, 'clean again')
    -- mission: reinforcement drop, taunt, voice-over lines, start at a stage
    do
        local M = import('/lua/editor/mission.lua')
        local saved = M.Data
        local function Loads(text) local ok, f = pcall(loadstring, text) return ok and f ~= nil end
        M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
        M.AddStage('One') M.AddStage('Two')
        local okn, path = M.AddNode(1, 'ready', 'transport_drop')
        Ok(okn, 'the transport drop node exists')
        M.SetParam(1, 'ready', path, 'army', 'ARMY_1')
        M.SetParam(1, 'ready', path, 'group', 'INITIAL')
        M.SetParam(1, 'ready', path, 'landing', 'CH_LAND')
        M.SetParam(1, 'ready', path, 'attack', 'CH_ATTACK')
        local text = M.Compile(true)
        Ok(Loads(text) and string.find(text, 'PlatoonAttackWithTransports(ScenarioUtils.CreateArmyGroupAsPlatoon(', 1, true) ~= nil and string.find(text, "'CH_LAND', 'CH_ATTACK', true", 1, true) ~= nil, 'it compiles to PlatoonAttackWithTransports with both chains')
        local found = false
        for _, p in M.Check() do if string.find(p.text, 'there is no chain', 1, true) then found = true end end
        Ok(found, 'a chain that does not exist is reported')
        M.RemoveNode(1, 'ready', path)
        local okt, tpath = M.AddNode(1, 'ready', 'taunt')
        M.SetParam(1, 'ready', tpath, 'head', 3) M.SetParam(1, 'ready', tpath, 'taunt', 12)
        text = M.Compile(true)
        Ok(Loads(text) and string.find(text, 'ScenarioFramework.PlayTaunt(3, 12)', 1, true) ~= nil, 'the taunt node compiles to PlayTaunt(head, taunt)')
        M.RemoveNode(1, 'ready', tpath)
        local okb, bpath = M.AddNode(1, 'ready', 'nuke_barrage')
        M.SetParam(1, 'ready', bpath, 'var', 'silos') M.SetParam(1, 'ready', bpath, 'marker', 'M1') M.SetParam(1, 'ready', bpath, 'count', 3) M.SetParam(1, 'ready', bpath, 'spread', 12)
        text = M.Compile(true)
        Ok(okb and Loads(text) and string.find(text, 'GiveNukeSiloAmmo(3)', 1, true) ~= nil and string.find(text, 'IssueNuke({ u }, {', 1, true) ~= nil, 'the nuke barrage node compiles to silo ammo and IssueNuke per missile')
        M.RemoveNode(1, 'ready', bpath)
        okt, tpath = M.AddNode(1, 'ready', 'taunt')
        M.AddDialogue('Voiced')
        M.AddLine(1, 'Commander')
        M.SetLine(1, 1, 'bank', 'XGG') M.SetLine(1, 1, 'cue', 'Computer_Computer_UnitRevalation_01370') M.SetLine(1, 1, 'vid', 'UEF_Commander.sfd')
        text = M.Compile(true)
        Ok(Loads(text) and string.find(text, "bank = 'XGG', cue = 'Computer_Computer_UnitRevalation_01370', vid = 'UEF_Commander.sfd'", 1, true) ~= nil, 'a dialogue line carries its voice-over and video')
        M.AddLine(1, 'Plain')
        text = M.Compile(true)
        Ok(string.find(text, "{ text = 'Plain', delay = 5 },", 1, true) ~= nil, 'a line without voice stays plain')
        Ok(string.find(text, 'Stage[ScenarioInfo.EditorStartStage or 1]()', 1, true) ~= nil, 'the mission starts at the stage a play test asks for')
        M.Data = saved
    end

    -- lobby slots: factions per start position
    do
        local Slots = import('/lua/editor/lobbyslots.lua')
        local std = Map.Doc.info.Configurations and Map.Doc.info.Configurations.standard
        local savedFactions = std and std.factions
        if std then std.factions = nil end
        local d0 = History.Depth()
        Ok(table.getn(Slots.Get(1)) == 4 and not Slots.IsRestricted(1), 'a slot offers all four factions by default')
        Ok(Slots.Set(1, { 'aeon', 'cybran', 'bogus' }), 'a slot can be restricted')
        local g = Slots.Get(1)
        Ok(table.getn(g) == 2 and g[1] == 'aeon' and g[2] == 'cybran' and Slots.IsRestricted(1), 'it offers only the listed known factions, in the standard order')
        Ok(Map.Doc.info.Configurations.standard.factions ~= nil and Map.Doc.info.Configurations.standard.factions[1] ~= nil, 'the lobby table exists')
        Slots.Set(1, { 'uef', 'aeon', 'cybran', 'seraphim' })
        Ok(Map.Doc.info.Configurations.standard.factions == nil and not Slots.IsRestricted(1), 'all four again removes the restriction and the table')
        History.Undo()
        Ok(Slots.IsRestricted(1), 'undo brings the restriction back')
        History.Undo()
        Ok(not Slots.IsRestricted(1) and Map.Doc.info.Configurations.standard.factions == nil, 'and undo again removes it')
        while History.Depth() > d0 do History.Undo() end
        Map.Doc.info.Configurations.standard.factions = savedFactions
    end

    if failed == 0 then return 'PASS sweep (' .. table.getn(out) .. ' checks)' end
    return 'FAIL ' .. failed .. '\n' .. table.concat(out, '\n')
end
