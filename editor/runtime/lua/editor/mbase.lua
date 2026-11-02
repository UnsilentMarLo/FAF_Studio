-- Mission bases: BaseManager tables edited in the Bases panel and compiled into the mission script region (docs/projects/MAP_EDITOR_DESIGN.md section 19.23,
-- docs/projects/editor_research/MISSION_SCRIPT_ANALYSIS.md sections 2.4 and 3.5 / 3.6).
--
--   Mission.Data.bases = { base, ... }
--   base = { name, army, marker, radius, diff, start, engineers = {e, n, h}, assist = {e, n, h}, maxBuild, alwaysAssist, supportAcus,
--            switchOn = { 'AirScouting', ... }, switchOff = { ... }, noBuild = { 'Defenses', ... },
--            groups = { { name, priority }, ... },                                  build groups (unit groups of the army); `diff`: stored as <name>_D1 .. _D3
--            opai = { { name, ptype, master, chains = {}, priority, children = {}, qty = {e, n, h}, lock, lockSecs, cond1, cond1n, cond1flag, cond1cat, cond2, ... } } }
--   AddBase / DefineFromArea / RemoveBase / SetField, AddGroup / RemoveGroup / SetGroupPriority, AddOpAI / RemoveOpAI / SetOpAI      edits with undo
--   Compile() -> lines of the script region (the BaseManager import, one `Base.Start_<name>()` function per base); Check(add) -> findings
--
-- A base is started by a *Start a base* node in a stage (or a trigger); the script then creates the BaseManager, initialises it with the army's groups, spawns the groups
-- with priority > 0 and arms the attack AIs (OpAI) of the base. Engineers and OpAI platoons are built by the campaign AI brain, so the map type must be `campaign`.
--
-- Lua 5.0 dialect.

local M = import('/lua/editor/mission.lua')
local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')

local Q = M.Quote
local N = M.Num

ACTIVE = { 'Shields', 'Fabrication', 'Intel', 'CounterIntel', 'TML', 'Nuke', 'Patrol', 'Reclaim', 'LandScouting', 'AirScouting' }
BUILD = { 'Engineers', 'AntiAir', 'GroundDefense', 'Torpedo', 'AirFactories', 'LandFactories', 'SeaFactories', 'Factories', 'MissileDefense', 'Shields', 'Artillery',
          'Experimentals', 'Walls', 'Defenses', 'Jammers', 'Radar', 'Sonar', 'Intel', 'Missiles', 'Fabrication', 'AirStaging', 'MassExtraction', 'EnergyProduction', 'Storage' }

--- Attack AI families (the OpAI save files of /lua/ai/opai) and the platoon kinds each one builds.
PTYPES = { 'BasicLandAttack', 'AirAttacks', 'NavalAttacks', 'EngineerAttack' }
CHILDREN = {
    BasicLandAttack = { 'LightBots', 'LightTanks', 'LightArtillery', 'MobileAntiAir', 'HeavyTanks', 'AmphibiousTanks', 'MobileShields', 'MobileStealth', 'MobileMissiles', 'MobileFlak', 'MobileBombs',
                        'RangeBots', 'SiegeBots', 'HeavyBots', 'MobileHeavyArtillery', 'HeavyMobileAntiAir', 'T1Transports', 'T2Transports', 'T3Transports' },
    AirAttacks = { 'Interceptors', 'Bombers', 'LightGunships', 'CombatFighters', 'TorpedoBombers', 'Gunships', 'GuidedMissiles', 'AirSuperiority', 'StratBombers', 'HeavyGunships', 'HeavyTorpedoBombers' },
    NavalAttacks = { 'Frigates', 'Submarines', 'Destroyers', 'Cruisers', 'Battleships', 'T2Submarines', 'T3Submarines', 'UtilityBoats', 'Carriers', 'NukeSubmarines', 'AABoats', 'BattleCruisers', 'MissileShips', 'TorpedoBoats' },
    EngineerAttack = { 'T1Engineers', 'T2Engineers', 'T3Engineers', 'CombatEngineers', 'MobileShields', 'T1Transports', 'T2Transports', 'T3Transports' },
}
MASTERS = { 'patrol chain picker', 'patrol one chain', 'random patrol', 'default' }
LOCKS = { 'None', 'DeathTimer', 'BuildTimer', 'DeathRatio' }
CONDS = { 'none', 'humans have units', 'flag is set', 'stage reached' }

local MASTER_CALL = {
    ['patrol chain picker'] = { 'PatrolChainPickerThread', 'PatrolChains' },
    ['patrol one chain'] = { 'PatrolThread', 'PatrolChain' },
    ['random patrol'] = { 'RandomPatrolThread', 'PatrolChain' },
}

--- The parameter lists the dialogs build forms from (same kinds as the node catalogue, plus diff3 = a number per difficulty and multi = a list of names).
BaseBasics = {
    { key = 'army', label = 'Army', kind = 'army' },
    { key = 'marker', label = 'Center marker', kind = 'marker' },
    { key = 'radius', label = 'Radius (structures within belong to the base)', kind = 'number', default = 40, min = 5, max = 300 },
    { key = 'diff', label = 'Groups per difficulty (<group>_D1 .. _D3)', kind = 'bool', default = false },
    { key = 'start', label = 'Start with', kind = 'choice', choices = { 'all groups built', 'empty (engineers build it)' }, default = 'all groups built' },
    { key = 'engineers', label = 'Engineers (easy / normal / hard)', kind = 'diff3', default = { 2, 4, 6 }, min = 0, max = 60 },
    { key = 'assist', label = 'Permanent assisters (easy / normal / hard)', kind = 'diff3', default = { 0, 0, 0 }, min = 0, max = 30 },
}
BaseDetails = {
    { key = 'maxBuild', label = 'Most engineers building at once (0 = default)', kind = 'number', default = 0, min = 0, max = 60 },
    { key = 'alwaysAssist', label = 'Idle engineers always assist', kind = 'bool', default = false },
    { key = 'supportAcus', label = 'Support commanders (SACU)', kind = 'number', default = 0, min = 0, max = 10 },
    { key = 'switchOn', label = 'Switch on', kind = 'multi', choices = ACTIVE },
    { key = 'switchOff', label = 'Switch off', kind = 'multi', choices = ACTIVE },
    { key = 'noBuild', label = 'Never build', kind = 'multi', choices = BUILD },
}
OpAIBasics = {
    { key = 'name', label = 'Name', kind = 'text', default = 'Attack1' },
    { key = 'ptype', label = 'Kind of attack', kind = 'choice', choices = PTYPES, default = 'BasicLandAttack' },
    { key = 'children', label = 'Platoon makes', kind = 'multi', choices = 'children' },
    { key = 'qty', label = 'Platoon size (easy / normal / hard)', kind = 'diff3', default = { 4, 6, 8 }, min = 1, max = 100 },
    { key = 'master', label = 'Attack orders', kind = 'choice', choices = MASTERS, default = 'patrol chain picker' },
    { key = 'chains', label = 'Patrol chains', kind = 'multi', choices = 'chains' },
    { key = 'priority', label = 'Priority', kind = 'number', default = 100, min = 1, max = 1000 },
    { key = 'lock', label = 'After a platoon was formed', kind = 'choice', choices = LOCKS, default = 'None' },
    { key = 'lockSecs', label = 'Lock time (seconds) / ratio x100 for DeathRatio', kind = 'number', default = 60, min = 1, max = 3600 },
}
OpAIConditions = {}
for slot = 1, 2 do
    local k = 'cond' .. slot
    table.insert(OpAIConditions, { key = k, label = 'Condition ' .. slot .. ' (the attack waits until it holds)', kind = 'choice', choices = CONDS, default = 'none' })
    table.insert(OpAIConditions, { key = k .. 'n', label = 'Humans have at least this many units (easy / normal / hard)', kind = 'diff3', default = { 10, 6, 4 }, min = 0, max = 500 })
    table.insert(OpAIConditions, { key = k .. 'stage', label = 'Stage number reached', kind = 'number', default = 1, min = 1, max = 50 })
    table.insert(OpAIConditions, { key = k .. 'flag', label = 'Flag name (set by a Set a flag node)', kind = 'text', default = '' })
end

-- ---- reading ---------------------------------------------------------------------------------------------------------------------------------------

function Bases() return M.Data.bases end

function Find(name)
    for i, b in M.Data.bases or {} do
        if b.name == name then return b, i end
    end
    return nil
end

local function Copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = Copy(v) end
    return c
end

local function Defaults(list)
    local t = {}
    for _, p in list do
        if p.default ~= nil then t[p.key] = Copy(p.default) end
    end
    return t
end

local function NewBase(name, army)
    local b = Defaults(BaseBasics)
    for k, v in Defaults(BaseDetails) do b[k] = v end
    b.name = name
    b.army = army
    b.marker = name .. '_Marker'
    b.switchOn, b.switchOff, b.noBuild = {}, {}, {}
    b.groups, b.opai = {}, {}
    return b
end

local function NewOpAI(existing)
    local o = Defaults(OpAIBasics)
    for k, v in Defaults(OpAIConditions) do o[k] = v end
    local used = {}
    for _, e in existing do used[e.name] = true end
    local n = 1
    while used['Attack' .. n] do n = n + 1 end
    o.name = 'Attack' .. n
    o.children, o.chains = {}, {}
    return o
end

--- The child kinds an attack of this family can build.
function ChildKinds(ptype) return CHILDREN[ptype or 'BasicLandAttack'] or {} end

-- ---- edits (all with undo, through the mission's model) -------------------------------------------------------------------------------------------

-- the plan list real campaign maps give their AI armies: the campaign brain loads its builders from the BaseManager, not from a skirmish plan
BLANK_PLANS = '/lua/ai/OpAI/DefaultBlankPlanlist.lua'

--- Gives an army without an AI plan list the blank one (a campaign brain with no plans runs the skirmish builders and fails). One undo entry when it changed something.
local function EnsurePlans(army)
    local a = Map.Doc and Map.Doc.save.Armies and Map.Doc.save.Armies[army]
    if not a or (a.plans and a.plans ~= '') then return 0 end
    a.plans = BLANK_PLANS
    History.Push({ label = 'army AI plans', undo = function() a.plans = '' end, redo = function() a.plans = BLANK_PLANS end })
    return 1
end

local function Base(i) return M.Data.bases and M.Data.bases[i] end

function AddBase(name, army)
    if not M.ValidName(name) then return nil, 'a base name takes letters, digits and _ and starts with a letter' end
    if Find(name) then return nil, 'there is already a base ' .. name end
    local steps = EnsurePlans(army)
    local ok = M.Edit('add base', function()
        M.Data.bases = M.Data.bases or {}
        table.insert(M.Data.bases, NewBase(name, army))
    end)
    if ok and steps > 0 then History.Merge(steps + 1, 'add base ' .. name) end
    return ok
end

function RemoveBase(i)
    if not Base(i) then return nil, 'no such base' end
    return M.Edit('remove base', function() table.remove(M.Data.bases, i) end)
end

function SetField(i, key, value, merge)
    if not Base(i) then return nil, 'no such base' end
    return M.Edit('base ' .. key, function() M.Data.bases[i][key] = value end, merge and ('base' .. i .. key) or nil)
end

function AddGroup(i, group, priority)
    local b = Base(i)
    if not b then return nil, 'no such base' end
    for _, g in b.groups do if g.name == group then return nil, 'the base has that group already' end end
    return M.Edit('add base group', function() table.insert(M.Data.bases[i].groups, { name = group, priority = priority or 100 }) end)
end

function RemoveGroup(i, gi)
    local b = Base(i)
    if not b or not b.groups[gi] then return nil, 'no such group' end
    return M.Edit('remove base group', function() table.remove(M.Data.bases[i].groups, gi) end)
end

function SetGroupPriority(i, gi, value, merge)
    local b = Base(i)
    if not b or not b.groups[gi] then return nil, 'no such group' end
    return M.Edit('base group priority', function() M.Data.bases[i].groups[gi].priority = value end, merge and ('basegp' .. i .. '.' .. gi) or nil)
end

function AddOpAI(i)
    local b = Base(i)
    if not b then return nil, 'no such base' end
    local at
    local ok = M.Edit('add attack', function()
        table.insert(M.Data.bases[i].opai, NewOpAI(M.Data.bases[i].opai))
        at = table.getn(M.Data.bases[i].opai)
    end)
    if not ok then return nil end
    return true, at
end

function RemoveOpAI(i, oi)
    local b = Base(i)
    if not b or not b.opai[oi] then return nil, 'no such attack' end
    return M.Edit('remove attack', function() table.remove(M.Data.bases[i].opai, oi) end)
end

function SetOpAI(i, oi, key, value, merge)
    local b = Base(i)
    if not b or not b.opai[oi] then return nil, 'no such attack' end
    return M.Edit('attack ' .. key, function()
        local o = M.Data.bases[i].opai[oi]
        o[key] = value
        if key == 'ptype' then o.children = {} end            -- the child kinds belong to the family
    end, merge and ('opai' .. i .. '.' .. oi .. key) or nil)
end

-- ---- defining a base from an area ------------------------------------------------------------------------------------------------------------------

--- The units of `army` standing inside the area, as Units.All() entries.
function UnitsInArea(army, area)
    local a = Map.Doc and Map.Doc.save.Areas and Map.Doc.save.Areas[area]
    local list = {}
    if not a then return list end
    local rect = a.rectangle or a.rect or a
    local x0, z0, x1, z1 = rect[1], rect[2], rect[3], rect[4]
    if not x0 then return list end
    for _, u in import('/lua/editor/units.lua').All() do
        if u.army == army and u.x >= math.min(x0, x1) and u.x <= math.max(x0, x1) and u.z >= math.min(z0, z1) and u.z <= math.max(z0, z1) then
            table.insert(list, u)
        end
    end
    return list, math.min(x0, x1), math.min(z0, z1), math.max(x0, x1), math.max(z0, z1)
end

--- "Define base": the area becomes a base. A marker is put at its center (name <Base>_Marker), the radius is half the diagonal, the army's units inside the area move into a
--- group named like the base (built by the BaseManager, spawned by the Start node), and the base joins the mission. One undo step. Returns true or nil and a reason.
function DefineFromArea(name, army, area)
    if not M.ValidName(name) then return nil, 'a base name takes letters, digits and _ and starts with a letter' end
    if Find(name) then return nil, 'there is already a base ' .. name end
    if not Map.Doc then return nil, 'no map' end
    local units, x0, z0, x1, z1 = UnitsInArea(army, area)
    if not x0 then return nil, 'there is no area ' .. tostring(area) end
    local Units = import('/lua/editor/units.lua')
    local Tools = import('/lua/editor/tools.lua')
    local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    local radius = math.ceil(math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0)) / 2)
    local steps = EnsurePlans(army)
    local marker = name .. '_Marker'
    if not Map.Doc.save.MasterChain._MASTERCHAIN_.Markers[marker] then
        if Tools.PlaceMarker(cx, cz, 'Blank Marker', marker) then steps = steps + 1 end
    end
    if table.getn(units) > 0 then
        Units.ClearSelection()
        for _, u in units do Units.Select(u, 'add') end
        if Units.SetGroup(name) then steps = steps + 1 end
        Units.ClearSelection()
    end
    local ok = M.Edit('add base', function()
        M.Data.bases = M.Data.bases or {}
        local b = NewBase(name, army)
        b.marker = marker
        b.radius = math.max(5, math.min(300, radius))
        if table.getn(units) > 0 then table.insert(b.groups, { name = name, priority = 100 }) end
        table.insert(M.Data.bases, b)
    end)
    if not ok then return nil, 'could not add the base' end
    steps = steps + 1
    if steps > 1 then History.Merge(steps, 'define base ' .. name) end
    return true, table.getn(units)
end

-- ---- compiling -------------------------------------------------------------------------------------------------------------------------------------

local function Diff3(v, default)
    local t = {}
    for i = 1, 3 do t[i] = N(type(v) == 'table' and v[i] or default or 0) end
    return '{ ' .. t[1] .. ', ' .. t[2] .. ', ' .. t[3] .. ' }'
end

local function StrList(list)
    local parts = {}
    for _, v in list or {} do table.insert(parts, Q(v)) end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
end

local function Condition(o, slot)
    local kind = o['cond' .. slot]
    local n = o['cond' .. slot .. 'n']
    if kind == 'humans have units' then
        return "op:AddBuildCondition('/lua/editor/otherarmyunitcountbuildconditions.lua', 'BrainsCompareNumCategory', { { 'HumanPlayers' }, " ..
               '(' .. Diff3(n, 6) .. ')[Difficulty], categories.ALLUNITS - categories.DEFENSE, \'>=\' })'
    elseif kind == 'flag is set' then
        return "op:AddBuildCondition('/lua/editor/miscbuildconditions.lua', 'CheckScenarioInfoVarTable', { " .. Q(o['cond' .. slot .. 'flag']) .. ' })'
    elseif kind == 'stage reached' then
        return "op:AddBuildCondition('/lua/editor/miscbuildconditions.lua', 'MissionNumberGreaterOrEqual', { " .. N(o['cond' .. slot .. 'stage'], 1) .. ' })'
    end
    return nil
end

local function CompileOpAI(b, o, out)
    local function Add(line) table.insert(out, '        ' .. line) end
    local master = MASTER_CALL[o.master or 'default']
    Add("op = bm:AddOpAI(" .. Q(o.ptype) .. ', ' .. Q(o.name) .. ', {')
    if master then
        Add("    MasterPlatoonFunction = { '/lua/scenarioplatoonai.lua', " .. Q(master[1]) .. ' },')
        if master[2] == 'PatrolChains' then
            Add('    PlatoonData = { PatrolChains = ' .. StrList(o.chains) .. ' },')
        else
            Add('    PlatoonData = { PatrolChain = ' .. Q(o.chains and o.chains[1] or '') .. ' },')
        end
    end
    Add('    Priority = ' .. N(o.priority, 100) .. ',')
    Add('})')
    if o.children and table.getn(o.children) > 0 then
        Add('op:SetChildQuantity(' .. StrList(o.children) .. ', (' .. Diff3(o.qty, 4) .. ')[Difficulty])')
    end
    if o.lock == 'DeathTimer' or o.lock == 'BuildTimer' then
        Add('op:SetLockingStyle(' .. Q(o.lock) .. ', { LockTimer = ' .. N(o.lockSecs, 60) .. ' })')
    elseif o.lock == 'DeathRatio' then
        Add('op:SetLockingStyle(' .. Q(o.lock) .. ', { Ratio = ' .. N((tonumber(o.lockSecs) or 50) / 100) .. ' })')
    else
        Add("op:SetLockingStyle('None')")
    end
    for slot = 1, 2 do
        local c = Condition(o, slot)
        if c then Add(c) end
    end
end

--- Lines of the region: BaseManager import and the start function of every base ({} without bases).
function Compile()
    local out = {}
    local bases = M.Data.bases or {}
    if table.getn(bases) == 0 then return out end
    table.insert(out, "local BaseManager = import('/lua/ai/opai/basemanager.lua')")
    table.insert(out, '')
    for _, b in bases do
      -- (a base that cannot be generated does not take the other bases and the stages with it: its start function only warns)
      local mark = table.getn(out)
      local ok, err = pcall(function()
        local name = b.name
        if not M.ValidName(name) then error('the base name ' .. tostring(name) .. ' is not usable (letters, digits and _)') end
        table.insert(out, '-- base ' .. name .. ' (army ' .. M.Comment(b.army) .. '): started by a Start a base node')
        table.insert(out, 'function Base.Start_' .. name .. '()')
        table.insert(out, '    if Base.Manager_' .. name .. ' then return end')
        table.insert(out, '    local brain = GetArmyBrain(' .. Q(b.army) .. ')')
        table.insert(out, '    if not brain.PBMAddBuildLocation then')
        table.insert(out, '        WARN(' .. Q('base ' .. name .. ': army ' .. tostring(b.army) .. ' has no campaign AI brain (set the map type to campaign)') .. ')')
        table.insert(out, '        return')
        table.insert(out, '    end')
        table.insert(out, '    local bm = BaseManager.CreateBaseManager()')
        table.insert(out, '    Base.Manager_' .. name .. ' = bm')
        local levels = {}
        for _, g in b.groups or {} do table.insert(levels, '[' .. Q(g.name) .. '] = ' .. N(g.priority, 100)) end
        local init = b.diff and 'InitializeDifficultyTables' or 'Initialize'
        table.insert(out, '    bm:' .. init .. '(brain, ' .. Q(name) .. ', ' .. Q(b.marker) .. ', ' .. N(b.radius, 40) .. ', { ' .. table.concat(levels, ', ') .. ' })')
        local eng = '{ ' .. Diff3(b.engineers, 2) .. ', ' .. Diff3(b.assist, 0) .. ' }'
        if b.start == 'empty (engineers build it)' then
            table.insert(out, '    bm:StartEmptyBase(' .. eng .. ')')
        else
            table.insert(out, '    bm:StartNonZeroBase(' .. eng .. ')')
        end
        if (tonumber(b.maxBuild) or 0) > 0 then table.insert(out, '    bm:SetMaximumConstructionEngineers(' .. N(b.maxBuild) .. ')') end
        if b.alwaysAssist then table.insert(out, '    bm:SetConstructionAlwaysAssist(true)') end
        if (tonumber(b.supportAcus) or 0) > 0 then table.insert(out, '    bm:SetSupportACUCount(' .. N(b.supportAcus) .. ')') end
        for _, a in b.switchOn or {} do table.insert(out, '    bm:SetActive(' .. Q(a) .. ', true)') end
        for _, a in b.switchOff or {} do table.insert(out, '    bm:SetActive(' .. Q(a) .. ', false)') end
        for _, a in b.noBuild or {} do table.insert(out, '    bm:SetBuild(' .. Q(a) .. ', false)') end
        if table.getn(b.opai or {}) > 0 then
            table.insert(out, '    local op')
            for _, o in b.opai do
                table.insert(out, '    do')
                CompileOpAI(b, o, out)
                table.insert(out, '    end')
            end
        end
        table.insert(out, 'end')
        table.insert(out, '')
      end)
      if not ok then
        while table.getn(out) > mark do table.remove(out) end
        M.Report('base ' .. tostring(b.name), err)
        if M.ValidName(b.name) then
            table.insert(out, 'function Base.Start_' .. b.name .. '() WARN(' .. Q('base ' .. b.name .. ' could not be generated: ' .. tostring(err)) .. ') end')
            table.insert(out, '')
        end
      end
    end
    return out
end

-- ---- checks ----------------------------------------------------------------------------------------------------------------------------------------

local function GroupExists(units, name)
    for k, v in (units and units.Units) or {} do
        if k == name then return true end
        if type(v) == 'table' and v.type == 'GROUP' and GroupExists(v, name) then return true end
    end
    return false
end

--- add(sev, text, stage, section, index) is the mission's finding collector.
function Check(add)
    local doc = Map.Doc
    local bases = M.Data.bases or {}
    local started = {}
    for si, _ in M.Data.stages do
        for _, row in M.Flatten(si) do
            if row.node.type == 'base_start' and row.node.base then started[row.node.base] = true end
        end
    end
    local names = {}
    local armies = {}
    for _, a in import('/lua/editor/armysetup.lua').Names() do armies[a] = true end
    for i, b in bases do
        local where = 'base ' .. tostring(b.name) .. ': '
        if not M.ValidName(b.name) then add('E', where .. 'not a valid name') end
        if names[b.name] then add('E', where .. 'name used twice') end
        names[b.name] = true
        if not b.army or not armies[b.army] then add('E', where .. 'army ' .. tostring(b.army) .. ' is not in the army list') end
        if not doc or not doc.save.MasterChain._MASTERCHAIN_.Markers[b.marker or ''] then add('E', where .. 'there is no marker ' .. tostring(b.marker)) end
        if table.getn(b.groups or {}) == 0 and b.start ~= 'empty (engineers build it)' then add('W', where .. 'no build group: nothing to spawn (choose "empty" or add a group)') end
        local army = b.army and doc and doc.save.Armies and doc.save.Armies[b.army]
        for _, g in b.groups or {} do
            if army then
                if b.diff then
                    for d = 1, 3 do
                        if not GroupExists(army.Units, g.name .. '_D' .. d) then add('E', where .. 'army ' .. b.army .. ' has no group ' .. g.name .. '_D' .. d) end
                    end
                elseif not GroupExists(army.Units, g.name) then
                    add('E', where .. 'army ' .. b.army .. ' has no group ' .. tostring(g.name))
                end
            end
        end
        if army and (not army.plans or army.plans == '') then add('E', where .. 'army ' .. b.army .. ' has no AI plan list (the blank campaign list is set when a base is added; ' .. BLANK_PLANS .. ')') end
        if army and army.Economy and (tonumber(army.Economy.mass) or 0) == 0 and (tonumber(army.Economy.energy) or 0) == 0 and b.start == 'empty (engineers build it)' then
            add('I', where .. 'army ' .. b.army .. ' starts with no mass or energy: engineers need income (extractors and generators in the base) or start resources (Armies panel)')
        end
        if not started[b.name] then add('W', where .. 'no stage starts it (add a "Start a base" node)') end
        local usedOp = {}
        for oi, o in b.opai or {} do
            local w2 = where .. 'attack ' .. tostring(o.name) .. ': '
            if not M.ValidName(o.name) then add('E', w2 .. 'not a valid name') end
            if usedOp[o.name] then add('E', w2 .. 'name used twice') end
            usedOp[o.name] = true
            if not CHILDREN[o.ptype or ''] then add('E', w2 .. 'unknown kind of attack ' .. tostring(o.ptype)) end
            if table.getn(o.children or {}) == 0 then add('W', w2 .. 'no platoon kind chosen (the family default is built)') end
            local m = o.master
            if m == 'patrol chain picker' or m == 'patrol one chain' or m == 'random patrol' then
                if table.getn(o.chains or {}) == 0 then add('E', w2 .. 'no patrol chain chosen') end
                for _, c in o.chains or {} do
                    if doc and doc.save.Chains and not doc.save.Chains[c] then add('E', w2 .. 'there is no chain ' .. tostring(c)) end
                end
            end
            for slot = 1, 2 do
                if o['cond' .. slot] == 'flag is set' and (not o['cond' .. slot .. 'flag'] or o['cond' .. slot .. 'flag'] == '') then add('E', w2 .. 'condition ' .. slot .. ' has no flag name') end
            end
        end
    end
    if table.getn(bases) > 0 and doc then
        local info = import('/lua/editor/maps.lua').Info()
        if info and info.type ~= 'campaign' then
            add('W', 'bases need the campaign AI brain: set the map type to campaign (map info), or their engineers and attacks will not run')
        end
    end
end
