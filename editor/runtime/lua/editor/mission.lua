-- Missions: stages with action / objective / trigger nodes, compiled to the map script (docs/projects/MAP_EDITOR_DESIGN.md section 11: a structured list instead of a
-- node canvas; the model is the same).
--
--   Mission.Data = { mode = 'campaign' | 'coop' | 'both', stages = { { name, failsafe, enter = { node, ... }, ready = { node, ... } } }, bases = { base, ... },
--                    dialogues = { { name, lines = { { text, speaker, seconds }, ... } }, ... } }
--     a node = { type = '<catalogue id>', <param> = value, ..., children = { node, ... } (container nodes only) }
--     a base = see mbase.lua (BaseManager tables edited in the Bases panel)
--   Catalogue                 node types: { id, family = 'action' | 'objective' | 'flow' | 'trigger', title, container, callback, params = { { key, label, kind, default, choices } },
--                             emit = function(node, C) -> lines }. `container` nodes hold a child list (`children`); `callback` containers compile the children into a function that
--                             runs later (timer, area, death, objective result): their stage guard keeps them quiet after the stage has moved on.
--   A node is addressed by (stage, section, path): path is the index in the section's list, or a table { i, j, ... } through the children of container nodes.
--   AddStage / RemoveStage / MoveStage / SetStage, AddNode / RemoveNode / MoveNode / IndentNode / OutdentNode / SetParam     edits with undo (History)
--   Compile()                 -> script text of the region (the generated part of `_script.lua`)
--   PatchScript(text)         -> text with the region written (or replaced); the second result says what happened: 'none' (no mission), 'written', 'detached' (the region was edited by hand: left alone)
--   Check()                   -> list of { sev = 'E' | 'W' | 'I', text, stage, section, index }
--   SidecarText() / LoadSidecar(scenarioFile)    the model travels with the map in the `_editor.lua` file
--   ImportScript(doc)         a hand-written mission (`_script.lua` with ScenarioInfo.MissionNumber stages, `_strings.lua` dialogues) is shown as IMPORTED stages / dialogues (missionimport.lua):
--                             `imported = true`, read-only, an outline with line numbers in `stage.info`. They are never compiled (Compile / PatchScript skip them, a mission that is only imported
--                             writes nothing into the script), never saved to the sidecar (the sidecar only keeps `keepImport = true`: the next load imports again from the script), and editor
--                             stages can be added behind them (their numbers are their positions in the list, so keep the script's own numbers below them).
--   EditorStageCount() / ImportedStageCount() / IsImported()      how many stages the editor made / were imported
--
-- A stage is one forked function: it enters (MissionNumber guard against a second entry), runs its *enter* nodes, then its *ready* nodes. The objective nodes of a stage go into one
-- objective group; when the group is complete the next stage starts (the last stage ends the operation with a win unless it has an End node). A stage without objectives
-- starts the next one at once unless it has a failsafe timer, an End node or a Next stage node (usually inside a trigger). A failsafe timer starts the next stage
-- after that many seconds even when the objectives are not done. Every node is one catalogue entry; the Raw Lua node is the escape hatch.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match; numbers are 32-bit floats.

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')
local Ser = import('/lua/editor/luaser.lua')

Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
Revision = 0
LoadedRevision = 0     -- Revision when this session loaded its map: the running sim has the mission script of that moment (ui.lua Play reloads when it differs)

local BEGIN = '-- >>> EDITOR MISSION v1'
local FINISH = '-- <<< EDITOR MISSION'

local MAX_DEPTH = 6

-- ---- imported stages (a hand-written script): read-only, never compiled ---------------------------------------------------------------------------

--- Stages the editor made (compiled into the script).
function EditorStageCount()
    local n = 0
    for _, s in Data.stages do
        if not s.imported then n = n + 1 end
    end
    return n
end

--- Stages imported from the map's own script (never compiled).
function ImportedStageCount()
    return table.getn(Data.stages) - EditorStageCount()
end

function IsImported()
    return ImportedStageCount() > 0
end

--- The stage that the running script reports as ScenarioInfo.MissionNumber = n: an imported stage with that script number, else the editor stage at position n (or nil).
function StageByNumber(n)
    for _, s in Data.stages do
        if s.imported and s.info and n and n > 0 and s.info.number == n then return s end
    end
    local s = Data.stages[n or 0]
    if s and not s.imported then return s end
    return nil
end

--- Index of the next stage the editor made after stage `i`, or nil.
local function NextActive(i)
    for j = i + 1, table.getn(Data.stages) do
        if not Data.stages[j].imported then return j end
    end
    return nil
end

--- The stages Compile writes: { { i = index, stage = stage } } in order.
local function ActiveStages()
    local list = {}
    for i, s in Data.stages do
        if not s.imported then table.insert(list, { i = i, stage = s }) end
    end
    return list
end

local IMPORTED = 'imported from the script: read-only'

-- ---- helpers for the emitters ---------------------------------------------------------------------------------------------------------------------

local function Q(s)
    s = tostring(s or '')
    s = string.gsub(s, '\\', '\\\\')
    s = string.gsub(s, "'", "\\'")
    s = string.gsub(s, '\n', '\\n')
    s = string.gsub(s, '\r', '')
    return "'" .. s .. "'"
end

local function N(v, default)
    v = tonumber(v)
    if not v then v = default or 0 end
    if v == math.floor(v) and v > -1000000 and v < 1000000 then return string.format('%d', v) end
    return string.format('%.3f', v)
end

local function IsName(s)
    return type(s) == 'string' and string.find(s, '^[%a_][%w_]*$') ~= nil
end

--- The field of the variable table for a name the user typed. A name that is not an identifier (empty = not chosen yet) becomes V.UNSET, a field nothing sets: the script
--- still compiles, the node does nothing, and Check reports the missing variable (an empty name used to give 'V.' and a script that did not load at all).
local function Var(name)
    if not IsName(name) then return 'V.UNSET' end
    return 'V.' .. name
end

--- A Lua expression the user typed (a category such as categories.TECH3): the text itself when it compiles, else `default` (Check reports the broken expression).
local function Expr(text, default)
    if text == nil or text == '' then return default end
    local ok, f = pcall(loadstring, 'return ' .. tostring(text))
    if ok and f then return text end
    return default
end
ExprOk = function(text) return text == nil or text == '' or Expr(text, false) ~= false end

local function Lines(text)
    local list = {}
    for line in string.gfind(text .. '\n', '([^\n]*)\n') do table.insert(list, line) end
    return list
end

-- shared with mbase.lua
Quote = Q
Num = N
ValidName = IsName

-- ---- the catalogue ---------------------------------------------------------------------------------------------------------------------------------

local OBJ_TYPES = { 'primary', 'secondary', 'bonus' }
local FORMATIONS = { 'GrowthFormation', 'AttackFormation', 'NoFormation' }
local COMPARE = { '>=', '<=', '==', '>', '<' }
local ICONS = { 'kill', 'protect', 'move', 'build', 'capture', 'reclaim', 'repair' }

-- the parameters every objective has: type, title, description, an optional name other nodes (the objective result trigger) can refer to
local function ObjHead(title, desc)
    return {
        { key = 'otype', label = 'Type', kind = 'choice', choices = OBJ_TYPES, default = 'primary' },
        { key = 'title', label = 'Title', kind = 'text', default = title },
        { key = 'description', label = 'Description', kind = 'text', default = desc },
        { key = 'name', label = 'Name for triggers (optional)', kind = 'var', defines = true, vtype = 'objective' },
        { key = 'reminder', label = 'Reminder dialogue (optional)', kind = 'dialogue', optional = true },
        { key = 'reminderSecs', label = 'Reminder every (seconds)', kind = 'number', default = 120, min = 10, max = 1800 },
    }
end

local function Concat(a, b)
    local list = {}
    for _, v in a do table.insert(list, v) end
    for _, v in b do table.insert(list, v) end
    return list
end

-- the lines after the objective was created: remember it under its name, add it to the stage's group (stage level only; an objective made by a trigger stands alone)
local function ObjTail(n, C)
    local out = {}
    if n.name and n.name ~= '' then table.insert(out, Var(n.name) .. ' = obj') end
    if not (C and C.inCallback) then table.insert(out, 'Group:AddObjective(obj)') end
    table.insert(out, 'table.insert(AssignedObjectives, obj)')
    if n.reminder and n.reminder ~= '' then
        -- the objective's reminder: the dialogue repeats while the objective is open (and, at stage level, the stage runs)
        table.insert(out, 'do')
        table.insert(out, '    local o = obj')
        table.insert(out, '    ForkThread(function()')
        table.insert(out, '        while true do')
        table.insert(out, '            Wait(' .. N(n.reminderSecs, 120) .. ')')
        table.insert(out, '            if not o.Active' .. ((C and C.inCallback) and '' or (' or ScenarioInfo.MissionNumber ~= ' .. tostring(C and C.stage or 0))) .. ' then return end')
        table.insert(out, '            ScenarioFramework.Dialogue(Strings[' .. Q(n.reminder) .. '])')
        table.insert(out, '        end')
        table.insert(out, '    end)')
        table.insert(out, 'end')
    end
    return out
end

local function Objective(call, n, target, C)
    local lines = { ((C and C.inCallback) and 'local obj = ' or 'obj = ') .. 'Objectives.' .. call .. '(' .. Q(n.otype or 'primary') .. ", 'incomplete', " .. Q(n.title) .. ', ' .. Q(n.description) .. target .. ')' }
    for _, l in ObjTail(n, C) do table.insert(lines, l) end
    return lines
end

-- the body of a callback: stage guard, then the children (indented by `pad`); `fork` wraps it into its own thread (callbacks of units and objectives do not run in one)
local function CallbackBody(n, C, fork)
    local lines = {}
    local pad = fork and '        ' or '    '
    if fork then table.insert(lines, '    ForkThread(function()') end
    if n.stageOnly ~= false then table.insert(lines, pad .. 'if ScenarioInfo.MissionNumber ~= ' .. C.stage .. ' then return end') end
    local body = C.Body(n, pad, true)
    for _, l in body do table.insert(lines, l) end
    if table.getn(body) == 0 then table.insert(lines, pad .. '-- (nothing to do)') end
    if fork then table.insert(lines, '    end)') end
    return lines
end

local function Join(head, body, tail)
    local out = { head }
    for _, l in body do table.insert(out, l) end
    table.insert(out, tail)
    return out
end

local STAGE_ONLY = { key = 'stageOnly', label = 'Only while this stage runs', kind = 'bool', default = true }
local COUNT_CAT = 'categories.ALLUNITS'

Catalogue = {
    { id = 'spawn', family = 'action', title = 'Spawn group',
      params = { { key = 'army', label = 'Army', kind = 'army' }, { key = 'group', label = 'Group', kind = 'group' },
                 { key = 'bydiff', label = 'Group per difficulty (<group>_D1 .. _D3)', kind = 'bool', default = false },
                 { key = 'var', label = 'Keep as variable (optional)', kind = 'var', defines = true }, { key = 'wreck', label = 'As wreckage', kind = 'bool', default = false } },
      emit = function(n)
          local group = Q(n.group) .. (n.bydiff and " .. '_D' .. Difficulty" or '')
          local call = 'ScenarioUtils.CreateArmyGroup(' .. Q(n.army) .. ', ' .. group .. (n.wreck and ', true' or '') .. ')'
          if n.var and n.var ~= '' then return { Var(n.var) .. ' = ' .. call } end
          return { call }
      end },
    { id = 'platoon_patrol', family = 'action', title = 'Spawn platoon on a patrol chain',
      params = { { key = 'army', label = 'Army', kind = 'army' }, { key = 'group', label = 'Group', kind = 'group' }, { key = 'chain', label = 'Chain', kind = 'chain' },
                 { key = 'formation', label = 'Formation', kind = 'choice', choices = FORMATIONS, default = 'GrowthFormation' },
                 { key = 'var', label = 'Keep as variable (optional)', kind = 'var', defines = true } },
      emit = function(n)
          local target = (n.var and n.var ~= '') and Var(n.var) or 'platoon'
          return { (target == 'platoon' and 'local ' or '') .. target .. ' = ScenarioUtils.CreateArmyGroupAsPlatoon(' .. Q(n.army) .. ', ' .. Q(n.group) .. ', ' .. Q(n.formation or 'GrowthFormation') .. ')',
                   'ScenarioFramework.PlatoonPatrolChain(' .. target .. ', ' .. Q(n.chain) .. ')' }
      end },
    { id = 'group_patrol', family = 'action', title = 'Send a spawned group on a patrol chain',
      params = { { key = 'var', label = 'Group variable', kind = 'var' }, { key = 'chain', label = 'Chain', kind = 'chain' } },
      emit = function(n) return { 'ScenarioFramework.GroupPatrolChain(' .. Var(n.var or '') .. ', ' .. Q(n.chain) .. ')' } end },
    { id = 'dialogue', family = 'action', title = 'Mission text',
      params = { { key = 'text', label = 'Text', kind = 'text' }, { key = 'seconds', label = 'Shown for (seconds)', kind = 'number', default = 5, min = 0, max = 60 } },
      emit = function(n) return { 'ScenarioFramework.Dialogue({ { text = ' .. Q(n.text) .. ', delay = ' .. N(n.seconds, 5) .. ' } }, nil, true)' } end },
    { id = 'wait', family = 'flow', title = 'Wait',
      params = { { key = 'seconds', label = 'Seconds', kind = 'number', default = 10, min = 0, max = 3600 } },
      emit = function(n) return { 'Wait(' .. N(n.seconds, 10) .. ')' } end },
    { id = 'restrict', family = 'action', title = 'Restrict / allow units',
      params = { { key = 'mode', label = 'Mode', kind = 'choice', choices = { 'restrict', 'allow' }, default = 'restrict' }, { key = 'army', label = 'Army', kind = 'army' },
                 { key = 'categories', label = 'Categories (e.g. categories.TECH3)', kind = 'text', default = 'categories.TECH3' } },
      emit = function(n)
          local fn = (n.mode == 'allow') and 'RemoveRestriction' or 'AddRestriction'
          return { 'ScenarioFramework.' .. fn .. '(' .. Q(n.army) .. ', ' .. Expr(n.categories, 'categories.ALLUNITS') .. ')' }
      end },
    { id = 'resources', family = 'action', title = 'Give resources',
      params = { { key = 'army', label = 'Army', kind = 'army' }, { key = 'mass', label = 'Mass', kind = 'number', default = 0, min = 0, max = 100000 },
                 { key = 'energy', label = 'Energy', kind = 'number', default = 0, min = 0, max = 500000 } },
      emit = function(n)
          local out = {}
          if (tonumber(n.mass) or 0) ~= 0 then table.insert(out, 'GetArmyBrain(' .. Q(n.army) .. "):GiveResource('MASS', " .. N(n.mass) .. ')') end
          if (tonumber(n.energy) or 0) ~= 0 then table.insert(out, 'GetArmyBrain(' .. Q(n.army) .. "):GiveResource('ENERGY', " .. N(n.energy) .. ')') end
          if table.getn(out) == 0 then table.insert(out, '-- (no resources given)') end
          return out
      end },
    { id = 'playable', family = 'action', title = 'Set playable area',
      params = { { key = 'area', label = 'Area', kind = 'area' } },
      emit = function(n) return { 'ScenarioFramework.SetPlayableArea(' .. Q(n.area) .. ', true)' } end },
    { id = 'vision', family = 'action', title = 'Reveal a place',
      params = { { key = 'marker', label = 'Marker', kind = 'marker' }, { key = 'radius', label = 'Radius', kind = 'number', default = 40, min = 1, max = 500 },
                 { key = 'seconds', label = 'Seconds (0 = forever)', kind = 'number', default = 30, min = 0, max = 3600 }, { key = 'army', label = 'Army', kind = 'army' } },
      emit = function(n)
          return { 'ScenarioFramework.CreateVisibleAreaLocation(' .. N(n.radius, 40) .. ', ScenarioUtils.MarkerToPosition(' .. Q(n.marker) .. '), ' .. N(n.seconds, 30) .. ', GetArmyBrain(' .. Q(n.army) .. '))' }
      end },
    { id = 'wait_dead', family = 'flow', title = 'Wait until a group is destroyed',
      params = { { key = 'var', label = 'Group variable', kind = 'var' }, { key = 'remaining', label = 'Until at most this many are left', kind = 'number', default = 0, min = 0, max = 500 } },
      emit = function(n) return { 'while Alive(' .. Var(n.var or '') .. ') > ' .. N(n.remaining, 0) .. ' do Wait(1) end' } end },
    { id = 'wait_area', family = 'flow', title = 'Wait until units are in an area',
      params = { { key = 'area', label = 'Area', kind = 'area' }, { key = 'army', label = 'Army whose units count', kind = 'army' },
                 { key = 'category', label = 'Category', kind = 'text', default = COUNT_CAT },
                 { key = 'compare', label = 'Compare', kind = 'choice', choices = COMPARE, default = '>=' }, { key = 'value', label = 'Count', kind = 'number', default = 1, min = 0, max = 500 } },
      emit = function(n)
          local cat = Expr(n.category, COUNT_CAT)
          return { 'while not (CountInArea(' .. Q(n.area) .. ', ' .. Q(n.army) .. ', ' .. cat .. ') ' .. (n.compare or '>=') .. ' ' .. N(n.value, 1) .. ') do Wait(1) end' }
      end },
    { id = 'set_alliance', family = 'action', title = 'Set alliance',
      params = { { key = 'army', label = 'Army', kind = 'army' }, { key = 'other', label = 'Towards army', kind = 'army' },
                 { key = 'state', label = 'State', kind = 'choice', choices = { 'Ally', 'Enemy', 'Neutral' }, default = 'Ally' } },
      emit = function(n) return { 'SetAlliance(' .. Q(n.army) .. ', ' .. Q(n.other) .. ', ' .. Q(n.state or 'Ally') .. ')' } end },
    { id = 'kill_group', family = 'action', title = 'Destroy a group',
      params = { { key = 'var', label = 'Group variable', kind = 'var' } },
      emit = function(n) return { 'for _, u in ' .. Var(n.var or '') .. ' or {} do if u and not u.Dead then u:Kill() end end' } end },
    { id = 'give_group', family = 'action', title = 'Give a group to an army',
      params = { { key = 'var', label = 'Group variable', kind = 'var' }, { key = 'army', label = 'To army', kind = 'army' } },
      emit = function(n)
          return { 'for _, u in ' .. Var(n.var or '') .. ' or {} do if u and not u.Dead then ScenarioFramework.GiveUnitToArmy(u, GetArmyBrain(' .. Q(n.army) .. '):GetArmyIndex()) end end' }
      end },
    { id = 'set_flag', family = 'action', title = 'Set a flag (read by OpAI build conditions)',
      params = { { key = 'flag', label = 'Flag name', kind = 'text', default = 'ATTACK_NOW' }, { key = 'value', label = 'Value', kind = 'bool', default = true } },
      emit = function(n) return { 'ScenarioInfo.VarTable[' .. Q(n.flag) .. '] = ' .. (n.value == false and 'false' or 'true') } end },
    { id = 'transport_drop', family = 'action', title = 'Drop reinforcements by transport',
      params = { { key = 'army', label = 'Army', kind = 'army' }, { key = 'group', label = 'Group (transports and cargo)', kind = 'group' },
                 { key = 'landing', label = 'Landing chain (one of its markers)', kind = 'chain' }, { key = 'attack', label = 'Patrol chain after the drop', kind = 'chain' },
                 { key = 'instant', label = 'Cargo is attached at once (no loading trip)', kind = 'bool', default = true },
                 { key = 'formation', label = 'Formation', kind = 'choice', choices = FORMATIONS, default = 'GrowthFormation' } },
      emit = function(n)
          return { 'ScenarioFramework.PlatoonAttackWithTransports(ScenarioUtils.CreateArmyGroupAsPlatoon(' .. Q(n.army) .. ', ' .. Q(n.group) .. ', ' .. Q(n.formation or 'GrowthFormation') .. '), ' ..
                   Q(n.landing) .. ', ' .. Q(n.attack) .. ', ' .. (n.instant and 'true' or 'false') .. ')' }
      end },
    { id = 'taunt', family = 'action', title = 'Play a multiplayer taunt',
      params = { { key = 'head', label = 'Head (1-8)', kind = 'number', default = 1, min = 1, max = 8 }, { key = 'taunt', label = 'Taunt number (1-48)', kind = 'number', default = 1, min = 1, max = 48 } },
      emit = function(n) return { 'ScenarioFramework.PlayTaunt(' .. N(n.head, 1) .. ', ' .. N(n.taunt, 1) .. ')' } end },
    { id = 'nuke_barrage', family = 'action', title = 'Nuke barrage: launchers of a group fire at a place',
      params = { { key = 'var', label = 'Launcher group variable', kind = 'var' }, { key = 'marker', label = 'Target marker', kind = 'marker' },
                 { key = 'count', label = 'Missiles per launcher', kind = 'number', default = 1, min = 1, max = 10 },
                 { key = 'spread', label = 'Scatter radius', kind = 'number', default = 0, min = 0, max = 200 },
                 { key = 'fill', label = 'Load the silos first (no build time)', kind = 'bool', default = true } },
      emit = function(n)
          local count = math.floor(tonumber(n.count) or 1)
          local spread = N(n.spread, 0)
          return { 'do',
                   '    local target = ScenarioUtils.MarkerToPosition(' .. Q(n.marker) .. ')',
                   '    for _, u in ' .. Var(n.var or '') .. ' or {} do',
                   '        if u and not u.Dead then',
                   (n.fill == false) and '' or ('            u:GiveNukeSiloAmmo(' .. count .. ')'),
                   '            for i = 1, ' .. count .. ' do',
                   '                IssueNuke({ u }, { target[1] + (Random() - 0.5) * 2 * ' .. spread .. ', target[2], target[3] + (Random() - 0.5) * 2 * ' .. spread .. ' })',
                   '            end',
                   '        end',
                   '    end',
                   'end' }
      end },
    { id = 'dialogue_table', family = 'action', title = 'Play a dialogue (from the Strings panel)',
      params = { { key = 'name', label = 'Dialogue', kind = 'dialogue' } },
      emit = function(n) return { 'ScenarioFramework.Dialogue(Strings[' .. Q(n.name) .. '], nil, true)' } end },
    { id = 'coop_commanders', family = 'coop', title = 'Coop: spawn player commanders',
      params = { { key = 'unit', label = 'Unit name in the army (Commander)', kind = 'text', default = 'Commander' },
                 { key = 'byFaction', label = 'Use UEFPlayer / AeonPlayer / CybranPlayer by faction', kind = 'bool', default = true },
                 { key = 'effect', label = 'Arrival effect', kind = 'choice', choices = { 'Warp', 'Gate', 'none' }, default = 'Warp' },
                 { key = 'death', label = 'Lose the mission when all commanders are dead', kind = 'bool', default = true } },
      emit = function(n)
          local effect = (n.effect == 'none') and 'false' or Q(n.effect or 'Warp')
          local unit = Q(n.unit or 'Commander')
          if n.byFaction then unit = "({ 'UEFPlayer', 'AeonPlayer', 'CybranPlayer' })[GetArmyBrain(name):GetFactionIndex()] or " .. unit end
          local trigger = n.death and 'function(cdr) ScenarioFramework.PlayerDeath(cdr, nil, AssignedObjectives) end' or 'nil'
          return { 'ScenarioInfo.CoopCDR = ScenarioInfo.CoopCDR or {}',
                   'for name, _ in ScenarioInfo.HumanPlayers or {} do',
                   '    ScenarioInfo.CoopCDR[name] = ScenarioFramework.SpawnCommander(name, ' .. unit .. ', ' .. effect .. ', true, true, ' .. trigger .. ')',
                   'end' }
      end },
    { id = 'coop_unitcap', family = 'coop', title = 'Coop: shared unit cap',
      params = { { key = 'cap', label = 'Cap shared by the living players', kind = 'number', default = 1000, min = 100, max = 4000 } },
      emit = function(n) return { "if rawget(ScenarioFramework, 'SetSharedUnitCap') then ScenarioFramework.SetSharedUnitCap(" .. N(n.cap, 1000) .. ') end' } end },
    { id = 'coop_restrict', family = 'coop', title = 'Coop: restrict / allow units for all humans',
      params = { { key = 'mode', label = 'Mode', kind = 'choice', choices = { 'restrict', 'allow' }, default = 'restrict' },
                 { key = 'categories', label = 'Categories', kind = 'text', default = 'categories.TECH3' },
                 { key = 'unlock', label = 'Play the unlock voice when allowing', kind = 'bool', default = false } },
      emit = function(n)
          local cats = Expr(n.categories, 'categories.ALLUNITS')
          if n.mode == 'allow' then
              return { "if rawget(ScenarioFramework, 'RemoveRestrictionForAllHumans') then ScenarioFramework.RemoveRestrictionForAllHumans(" .. cats .. ', ' .. (n.unlock and 'true' or 'false') .. ') end' }
          end
          return { "if rawget(ScenarioFramework, 'AddRestrictionForAllHumans') then ScenarioFramework.AddRestrictionForAllHumans(" .. cats .. ') end' }
      end },
    { id = 'coop_announce', family = 'coop', title = 'Coop: announcement on screen',
      params = { { key = 'text', label = 'Headline', kind = 'text' }, { key = 'second', label = 'Second line (optional)', kind = 'text' } },
      emit = function(n) return { "if rawget(ScenarioFramework, 'SimAnnouncement') then ScenarioFramework.SimAnnouncement(" .. Q(n.text) .. ', ' .. Q(n.second) .. ') end' } end },
    { id = 'coop_player_death', family = 'coop', title = 'Coop: lose when all player commanders are dead',
      params = { { key = 'dialogue', label = 'Failure dialogue (optional)', kind = 'dialogue', optional = true } },
      emit = function(n)
          local fail = (n.dialogue and n.dialogue ~= '') and ('Strings[' .. Q(n.dialogue) .. ']') or 'nil'
          return { 'for _, index in ScenarioInfo.HumanPlayers or {} do',
                   '    for _, cdr in ArmyBrains[index]:GetListOfUnits(categories.COMMAND, false) do',
                   '        ScenarioFramework.CreateUnitDeathTrigger(function(unit) ScenarioFramework.PlayerDeath(unit, ' .. fail .. ', AssignedObjectives) end, cdr)',
                   '    end',
                   'end' }
      end },
    { id = 'if_players', family = 'flow', container = true, title = 'If the number of human players is ...',
      params = { { key = 'compare', label = 'Compare', kind = 'choice', choices = COMPARE, default = '>=' },
                 { key = 'count', label = 'Players (1 in single player)', kind = 'number', default = 2, min = 1, max = 8 } },
      emit = function(n, C)
          local body = C.Body(n, '    ', false)
          if table.getn(body) == 0 then table.insert(body, '    -- (nothing to do)') end
          return Join('if math.max(1, table.getsize(ScenarioInfo.HumanPlayers or {})) ' .. (n.compare or '>=') .. ' ' .. N(n.count, 2) .. ' then', body, 'end')
      end },
    { id = 'base_start', family = 'action', title = 'Start a base (BaseManager)',
      params = { { key = 'base', label = 'Base', kind = 'base' } },
      emit = function(n) return { 'Base.Start_' .. tostring(n.base or '') .. '()' } end },
    { id = 'base_active', family = 'action', title = 'Switch a base on / off',
      params = { { key = 'base', label = 'Base', kind = 'base' }, { key = 'on', label = 'Active', kind = 'bool', default = true } },
      emit = function(n)
          local b = 'Base.Manager_' .. tostring(n.base or '')
          return { 'if ' .. b .. ' then ' .. b .. ':BaseActive(' .. (n.on == false and 'false' or 'true') .. ') end' }
      end },
    { id = 'raw', family = 'action', title = 'Raw Lua',
      params = { { key = 'code', label = 'Lua', kind = 'text' } },
      emit = function(n) return Lines(n.code or '') end },
    { id = 'end', family = 'flow', title = 'End the mission',
      params = { { key = 'result', label = 'Result', kind = 'choice', choices = { 'win', 'lose' }, default = 'win' } },
      emit = function(n)
          if n.result == 'lose' then return { 'ScenarioFramework.EndOperation(false, false, false)' } end
          return { 'ScenarioFramework.EndOperation(true, true, true)' }
      end },
    { id = 'next_stage', family = 'flow', title = 'Start next stage',
      params = {},
      emit = function(n, C) return { C.nextCall or '-- (no next stage)' } end },

    -- ---- triggers: containers whose children run when the event happens ----------------------------------------------------------------
    { id = 'trg_timer', family = 'trigger', container = true, callback = true, title = 'When a timer runs out',
      params = { { key = 'seconds', label = 'Seconds', kind = 'number', default = 30, min = 1, max = 7200 }, STAGE_ONLY },
      emit = function(n, C) return Join('Timer(function()', CallbackBody(n, C, false), 'end, ' .. N(n.seconds, 30) .. ')') end },
    { id = 'trg_group_dead', family = 'trigger', container = true, callback = true, title = 'When a group is destroyed',
      params = { { key = 'var', label = 'Group variable', kind = 'var' }, { key = 'count', label = 'Number of dead units (0 = all)', kind = 'number', default = 0, min = 0, max = 500 }, STAGE_ONLY },
      emit = function(n, C)
          local units = '(' .. Var(n.var or '') .. ' or {})'
          local count = tonumber(n.count) or 0
          local call = (count > 0) and ('ScenarioFramework.CreateSubGroupDeathTrigger(function()') or 'ScenarioFramework.CreateGroupDeathTrigger(function()'
          local tail = (count > 0) and ('end, ' .. units .. ', ' .. N(count) .. ')') or ('end, ' .. units .. ')')
          return Join(call, CallbackBody(n, C, false), tail)
      end },
    { id = 'trg_unit_killed', family = 'trigger', container = true, callback = true, title = 'When a unit is killed',
      params = { { key = 'army', label = 'Army', kind = 'army' }, { key = 'unit', label = 'Unit', kind = 'unit' }, STAGE_ONLY },
      emit = function(n, C)
          local out = { 'do', '    local u = ScenarioInfo.UnitNames[GetArmyBrain(' .. Q(n.army) .. '):GetArmyIndex()][' .. Q(n.unit) .. ']',
                        '    if u then', '        ScenarioFramework.CreateUnitDeathTrigger(function()' }
          for _, l in CallbackBody(n, C, true) do table.insert(out, '            ' .. l) end
          table.insert(out, '        end, u)')
          table.insert(out, '    end')
          table.insert(out, 'end')
          return out
      end },
    { id = 'trg_area', family = 'trigger', container = true, callback = true, title = 'When units are in an area',
      params = { { key = 'area', label = 'Area', kind = 'area' }, { key = 'army', label = 'Army whose units count', kind = 'army' },
                 { key = 'category', label = 'Category', kind = 'text', default = COUNT_CAT },
                 { key = 'compare', label = 'Compare', kind = 'choice', choices = COMPARE, default = '>=' }, { key = 'value', label = 'Count', kind = 'number', default = 1, min = 0, max = 500 },
                 { key = 'once', label = 'Only the first time', kind = 'bool', default = true }, STAGE_ONLY },
      emit = function(n, C)
          local cat = Expr(n.category, COUNT_CAT)
          local test = 'CountInArea(' .. Q(n.area) .. ', ' .. Q(n.army) .. ', ' .. cat .. ') ' .. (n.compare or '>=') .. ' ' .. N(n.value, 1)
          local out = { 'ForkThread(function()', '    while true do' }
          if n.stageOnly ~= false then table.insert(out, '        if ScenarioInfo.MissionNumber ~= ' .. C.stage .. ' then return end') end
          table.insert(out, '        if ' .. test .. ' then')
          local body = C.Body(n, '            ', true)
          for _, l in body do table.insert(out, l) end
          if n.once ~= false then
              table.insert(out, '            return')
          else
              table.insert(out, '            while ' .. test .. ' do Wait(1) end')
          end
          table.insert(out, '        end')
          table.insert(out, '        Wait(1)')
          table.insert(out, '    end')
          table.insert(out, 'end)')
          return out
      end },
    { id = 'trg_objective', family = 'trigger', container = true, callback = true, title = 'When an objective is decided',
      params = { { key = 'objective', label = 'Objective', kind = 'var', vtype = 'objective' }, { key = 'result', label = 'Result', kind = 'choice', choices = { 'complete', 'failed' }, default = 'complete' }, STAGE_ONLY },
      emit = function(n, C)
          local want = (n.result == 'failed') and 'false' or 'true'
          local out = { 'if ' .. Var(n.objective or '') .. ' then', '    ' .. Var(n.objective or '') .. ':AddResultCallback(function(result)', '        if result ~= ' .. want .. ' then return end' }
          for _, l in CallbackBody(n, C, true) do table.insert(out, '        ' .. l) end
          table.insert(out, '    end)')
          table.insert(out, 'end')
          return out
      end },

    -- ---- flow containers ------------------------------------------------------------------------------------------------------------------
    { id = 'if_difficulty', family = 'flow', container = true, title = 'If the difficulty is ...',
      params = { { key = 'compare', label = 'Compare', kind = 'choice', choices = COMPARE, default = '>=' },
                 { key = 'level', label = 'Difficulty (1 easy, 2 normal, 3 hard)', kind = 'number', default = 2, min = 1, max = 3 } },
      emit = function(n, C)
          local body = C.Body(n, '    ', false)
          if table.getn(body) == 0 then table.insert(body, '    -- (nothing to do)') end
          return Join('if Difficulty ' .. (n.compare or '>=') .. ' ' .. N(n.level, 2) .. ' then', body, 'end')
      end },
    { id = 'cutscene', family = 'flow', container = true, title = 'Cutscene (camera moves, input locked)',
      params = {},
      emit = function(n, C)
          local body = C.Body(n, '', false)
          local out = { 'Cinematics.EnterNISMode()' }
          for _, l in body do table.insert(out, l) end
          table.insert(out, 'Cinematics.ExitNISMode()')
          return out
      end },
    { id = 'cam_area', family = 'action', title = 'Cutscene camera: move to an area',
      params = { { key = 'area', label = 'Area', kind = 'area' }, { key = 'seconds', label = 'Seconds', kind = 'number', default = 4, min = 0, max = 120 } },
      emit = function(n) return { 'Cinematics.CameraMoveToArea(' .. Q(n.area) .. ', ' .. N(n.seconds, 4) .. ')' } end },
    { id = 'cam_marker', family = 'action', title = 'Cutscene camera: move to a camera marker',
      params = { { key = 'marker', label = 'Camera Info marker', kind = 'marker', mtype = 'Camera Info' }, { key = 'seconds', label = 'Seconds', kind = 'number', default = 4, min = 0, max = 120 } },
      emit = function(n) return { 'Cinematics.CameraMoveToMarker(ScenarioUtils.GetMarker(' .. Q(n.marker) .. '), ' .. N(n.seconds, 4) .. ')' } end },
    { id = 'cam_reset', family = 'action', title = 'Cutscene camera: return to player',
      params = {},
      emit = function() return { 'Cinematics.CameraReset()' } end },

    -- ---- objectives -----------------------------------------------------------------------------------------------------------------------
    { id = 'obj_kill', family = 'objective', title = 'Objective: destroy a group',
      params = Concat(ObjHead('Destroy the enemy', 'Destroy all enemy units.'), { { key = 'var', label = 'Group variable', kind = 'var' } }),
      emit = function(n, C) return Objective('Kill', n, ', { Units = ' .. Var(n.var or '') .. ', MarkUnits = true }', C) end },
    { id = 'obj_protect', family = 'objective', title = 'Objective: protect a group',
      params = Concat(ObjHead('Protect the convoy', 'Keep these units alive.'), { { key = 'var', label = 'Group variable', kind = 'var' } }),
      emit = function(n, C) return Objective('Protect', n, ', { Units = ' .. Var(n.var or '') .. ', MarkUnits = true }', C) end },
    { id = 'obj_timer', family = 'objective', title = 'Objective: survive a time',
      params = Concat(ObjHead('Hold out', 'Survive until the time is up.'),
                      { { key = 'seconds', label = 'Seconds', kind = 'number', default = 600, min = 10, max = 7200 }, { key = 'expire', label = 'When it runs out', kind = 'choice', choices = { 'complete', 'failed' }, default = 'complete' } }),
      emit = function(n, C) return Objective('Timer', n, ', { Timer = ' .. N(n.seconds, 600) .. ', ExpireResult = ' .. Q(n.expire or 'complete') .. ' }', C) end },
    { id = 'obj_area', family = 'objective', title = 'Objective: units in an area',
      params = Concat(ObjHead('Reach the area', 'Move units into the marked area.'),
                      { { key = 'icon', label = 'Icon', kind = 'choice', choices = ICONS, default = 'move' },
                        { key = 'area', label = 'Area', kind = 'area' }, { key = 'category', label = 'Category', kind = 'text', default = COUNT_CAT },
                        { key = 'compare', label = 'Compare', kind = 'choice', choices = COMPARE, default = '>=' }, { key = 'value', label = 'Count', kind = 'number', default = 1, min = 0, max = 500 },
                        { key = 'army', label = 'Army whose units count', kind = 'army' } }),
      emit = function(n, C)
          local req = '{ Area = ' .. Q(n.area) .. ', Category = ' .. Expr(n.category, COUNT_CAT) .. ', CompareOp = ' .. Q(n.compare or '>=') ..
                      ', Value = ' .. N(n.value, 1) .. ', ArmyIndex = GetArmyBrain(' .. Q(n.army) .. '):GetArmyIndex() }'
          local lines = { ((C and C.inCallback) and 'local obj = ' or 'obj = ') .. 'Objectives.CategoriesInArea(' .. Q(n.otype or 'primary') .. ", 'incomplete', " .. Q(n.title) .. ', ' .. Q(n.description) .. ', ' .. Q(n.icon or 'move') ..
                  ', { MarkArea = true, ShowProgress = true, Requirements = { ' .. req .. ' } })' }
          for _, l in ObjTail(n, C) do table.insert(lines, l) end
          return lines
      end },
}

local byId = {}
for _, t in Catalogue do byId[t.id] = t end

--- Adds a node type to the catalogue (another module's nodes: missionplat.lua). A type id that exists is replaced.
function Register(entry)
    if byId[entry.id] then
        for i, t in Catalogue do if t.id == entry.id then Catalogue[i] = entry end end
    else
        table.insert(Catalogue, entry)
    end
    byId[entry.id] = entry
end

--- Checks of parameter kinds other modules add: KindChecks[kind] = function(value, node, param, doc) -> problem text or nil (an error in Check).
KindChecks = {}

function NodeType(id) return byId[id] end

-- ---- the model and its edits (all with undo) ---------------------------------------------------------------------------------------------------

local function Copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = Copy(v) end
    return c
end

--- Runs an edit of the model with undo. `mergeKey`: edits with the same key one after the other (typing in a field) share one undo step.
--- (Also used by mbase.lua for the base tables.)
local function Do(label, fn, mergeKey)
    local before = Copy(Data)
    local ok, why = fn()
    if ok == false then Data = before return nil, why end
    Revision = Revision + 1
    local top = mergeKey and History.Top and History.Top()
    if top and top.mergeKey == mergeKey and top.snapshot then
        top.snapshot.after = Copy(Data)
        return true
    end
    local snap = { before = before, after = Copy(Data) }
    History.Push({ label = label, mergeKey = mergeKey, snapshot = snap,
                   undo = function() Data = Copy(snap.before) Revision = Revision + 1 end,
                   redo = function() Data = Copy(snap.after) Revision = Revision + 1 end })
    return true
end
Edit = Do

function AddStage(name)
    return Do('add stage', function()
        local n = table.getn(Data.stages) + 1
        table.insert(Data.stages, { name = name or ('Stage ' .. n), failsafe = 0, enter = {}, ready = {} })
    end)
end

function RemoveStage(i)
    if not Data.stages[i] then return nil, 'no such stage' end
    if Data.stages[i].imported then return nil, IMPORTED end
    return Do('remove stage', function() table.remove(Data.stages, i) end)
end

function MoveStage(i, delta)
    local to = i + delta
    if not Data.stages[i] or to < 1 or to > table.getn(Data.stages) then return nil, 'out of range' end
    if Data.stages[i].imported or Data.stages[to].imported then return nil, IMPORTED end
    return Do('move stage', function()
        local s = table.remove(Data.stages, i)
        table.insert(Data.stages, to, s)
    end)
end

function SetStage(i, field, value, merge)
    if not Data.stages[i] then return nil, 'no such stage' end
    if Data.stages[i].imported then return nil, IMPORTED end
    return Do('stage ' .. field, function() Data.stages[i][field] = value end, merge and ('stage' .. i .. field) or nil)
end

MODES = { 'campaign', 'coop', 'both' }

local BLANK_PLANS = '/lua/ai/OpAI/DefaultBlankPlanlist.lua'

--- Campaign maps give their armies the blank plan list (every non-human army of a campaign session gets the campaign brain, civilians included, and a campaign brain without plans
--- runs the skirmish plan loader and raises errors): every army of the save except the first (the human). Called when the map is saved.
function PrepareArmies()
    if EditorStageCount() == 0 and table.getn(Data.bases or {}) == 0 then return end       -- (an imported mission keeps the armies of its script as they are)
    local info = Map.Doc and Map.Doc.info
    local t = info and ScenarioType(info.type)
    if t ~= 'campaign' and t ~= 'campaign_coop' then return end
    local names = import('/lua/editor/armysetup.lua').Names()
    for i, name in names do
        local a = Map.Doc.save.Armies[name]
        if i > 1 and a and (not a.plans or a.plans == '') then a.plans = BLANK_PLANS end
    end
end

function SetMode(mode)
    return Do('mission mode', function() Data.mode = mode end)
end

--- The scenario `type` the mission needs: coop and both-mode missions are `campaign_coop` (the coop support mod is loaded for them), others keep the map's type.
function ScenarioType(current)
    if EditorStageCount() > 0 or table.getn(Data.bases or {}) > 0 then
        if Data.mode == 'coop' or Data.mode == 'both' then return 'campaign_coop' end
        if current == 'campaign_coop' then return 'campaign' end
    end
    return current
end

-- ---- dialogue tables (the Strings panel) ------------------------------------------------------------------------------------------------------------

function DialogueNames()
    local list = {}
    for _, d in Data.dialogues or {} do
        if not d.imported then table.insert(list, d.name) end       -- (imported ones are not compiled: a node cannot play them)
    end
    table.sort(list)
    return list
end

function FindDialogue(name)
    for i, d in Data.dialogues or {} do
        if d.name == name and not d.imported then return d, i end
    end
    return nil
end

function AddDialogue(name)
    if not IsName(name) then return nil, 'a dialogue name takes letters, digits and _ and starts with a letter' end
    if FindDialogue(name) then return nil, 'there is already a dialogue ' .. name end
    return Do('add dialogue', function()
        Data.dialogues = Data.dialogues or {}
        table.insert(Data.dialogues, { name = name, lines = {} })
    end)
end

function RemoveDialogue(i)
    if not (Data.dialogues and Data.dialogues[i]) then return nil, 'no such dialogue' end
    if Data.dialogues[i].imported then return nil, IMPORTED end
    return Do('remove dialogue', function() table.remove(Data.dialogues, i) end)
end

function AddLine(i, text)
    if not (Data.dialogues and Data.dialogues[i]) then return nil, 'no such dialogue' end
    if Data.dialogues[i].imported then return nil, IMPORTED end
    local at
    local ok = Do('add dialogue line', function()
        table.insert(Data.dialogues[i].lines, { text = text or 'Text', speaker = '', seconds = 5 })
        at = table.getn(Data.dialogues[i].lines)
    end)
    if not ok then return nil end
    return true, at
end

function RemoveLine(i, li)
    local d = Data.dialogues and Data.dialogues[i]
    if not d or not d.lines[li] then return nil, 'no such line' end
    if d.imported then return nil, IMPORTED end
    return Do('remove dialogue line', function() table.remove(Data.dialogues[i].lines, li) end)
end

function MoveLine(i, li, delta)
    local d = Data.dialogues and Data.dialogues[i]
    local to = li + delta
    if not d or not d.lines[li] or to < 1 or to > table.getn(d.lines) then return nil, 'out of range' end
    if d.imported then return nil, IMPORTED end
    return Do('move dialogue line', function()
        local l = table.remove(Data.dialogues[i].lines, li)
        table.insert(Data.dialogues[i].lines, to, l)
    end)
end

function SetLine(i, li, key, value, merge)
    local d = Data.dialogues and Data.dialogues[i]
    if not d or not d.lines[li] then return nil, 'no such line' end
    if d.imported then return nil, IMPORTED end
    return Do('edit dialogue line', function() Data.dialogues[i].lines[li][key] = value end, merge and ('dline' .. i .. '.' .. li .. key) or nil)
end

--- Lines of the Strings table: Strings['NAME'] = { { text = '<speaker>: <text>', delay = <seconds> }, ... } (a ScenarioFramework dialogue table).
local function StringsLines()
    local out = { 'local Strings = {' }
    for _, d in Data.dialogues or {} do
      if not d.imported then       -- (imported dialogues belong to the script's own strings file: never written)
        table.insert(out, '    [' .. Q(d.name) .. '] = {')
        for _, l in d.lines or {} do
            local text = tostring(l.text or '')
            if l.speaker and l.speaker ~= '' then text = l.speaker .. ': ' .. text end
            -- optional voice-over / video of the line (ScenarioFramework.Dialogue: bank + cue play a sound, vid a movie of /movies, faction picks the portrait)
            local extra = ''
            for _, key in { 'bank', 'cue', 'vid', 'faction' } do
                if l[key] and l[key] ~= '' then extra = extra .. ', ' .. key .. ' = ' .. Q(l[key]) end
            end
            table.insert(out, '        { text = ' .. Q(text) .. ', delay = ' .. N(l.seconds, 5) .. extra .. ' },')
        end
        table.insert(out, '    },')
      end
    end
    table.insert(out, '}')
    return out
end

--- Flag names a mission knows: set by Set a flag nodes, or read by an attack's flag condition.
function FlagNames()
    local seen, list = {}, {}
    local function Add(name)
        if name and name ~= '' and not seen[name] then seen[name] = true table.insert(list, name) end
    end
    for si, _ in Data.stages do
        for _, row in Flatten(si) do
            if row.node.type == 'set_flag' then Add(row.node.flag) end
        end
    end
    for _, b in Data.bases or {} do
        for _, o in b.opai or {} do
            for slot = 1, 2 do
                if o['cond' .. slot] == 'flag is set' then Add(o['cond' .. slot .. 'flag']) end
            end
        end
    end
    table.sort(list)
    return list
end


--- A node of catalogue type `id` with the parameters' defaults (container nodes with an empty child list).
function NewNode(id)
    local t = byId[id]
    if not t then return nil end
    local node = { type = id }
    for _, p in t.params do
        if p.default ~= nil then node[p.key] = p.default end
    end
    if t.container then node.children = {} end
    return node
end

-- ---- node addresses ----------------------------------------------------------------------------------------------------------------------------

--- A path as a table: a number is the index in the section's list, a table walks through the children of container nodes.
local function AsPath(path)
    if type(path) == 'table' then return path end
    return { path }
end

--- The list that holds the node at `path`, its index in that list and the node itself; nil when there is no such node.
local function Locate(stage, section, path)
    local s = Data.stages[stage]
    local list = s and s[section]
    path = AsPath(path)
    local count = table.getn(path)
    if not list or count == 0 then return nil end
    local node
    for d = 1, count do
        node = list[path[d]]
        if not node then return nil end
        if d < count then
            list = node.children
            if not list then return nil end
        end
    end
    return list, path[count], node
end
LocateNode = Locate

function PathKey(path)
    local key = ''
    for _, i in AsPath(path) do key = key .. tostring(i) .. '.' end
    return key
end

local function Child(path, i)
    local p = {}
    for _, v in AsPath(path) do table.insert(p, v) end
    table.insert(p, i)
    return p
end

--- All nodes of a stage in display order: { section, path, node, depth }.
function Flatten(stage)
    local rows = {}
    local s = Data.stages[stage]
    local function Walk(list, section, prefix, depth)
        for i, node in list or {} do
            local path = prefix and Child(prefix, i) or { i }
            table.insert(rows, { section = section, path = path, node = node, depth = depth })
            if node.children then Walk(node.children, section, path, depth + 1) end
        end
    end
    if s then
        for _, section in { 'enter', 'ready' } do Walk(s[section], section, nil, 0) end
    end
    return rows
end

--- Adds a node of type `id` to `section` of the stage: at the end of the list (or before index `at`); `parent` (path of a container node) puts it into that node's children.
--- Returns true and the new node's path.
function AddNode(stage, section, id, at, parent)
    local s = Data.stages[stage]
    local t = byId[id]
    if not s or not t or (section ~= 'enter' and section ~= 'ready') then return nil, 'no such stage or node type' end
    if s.imported then return nil, IMPORTED end
    if t.family == 'objective' and section ~= 'ready' then return nil, 'objectives belong to the ready part of a stage' end
    local newPath
    local ok, why = Do('add node', function()
        local list = s[section]
        if parent then
            local _, _, holder = Locate(stage, section, parent)
            local tt = holder and byId[holder.type]
            if not holder or not tt or not tt.container then return false, 'the chosen node holds no children' end
            if table.getn(AsPath(parent)) >= MAX_DEPTH then return false, 'nested too deep' end
            holder.children = holder.children or {}
            list = holder.children
        end
        local node = NewNode(id)
        local index
        if at and at >= 1 and at <= table.getn(list) + 1 then index = at else index = table.getn(list) + 1 end
        table.insert(list, index, node)
        newPath = parent and Child(parent, index) or { index }
    end)
    if not ok then return nil, why end
    return true, newPath
end

function RemoveNode(stage, section, path)
    local list, index = Locate(stage, section, path)
    if not list then return nil, 'no such node' end
    return Do('remove node', function() local l, i = Locate(stage, section, path) table.remove(l, i) end)
end

function MoveNode(stage, section, path, delta)
    local list, index = Locate(stage, section, path)
    if not list then return nil, 'no such node' end
    local to = index + delta
    if to < 1 or to > table.getn(list) then return nil, 'out of range' end
    return Do('move node', function()
        local l, i = Locate(stage, section, path)
        local node = table.remove(l, i)
        table.insert(l, to, node)
    end)
end

--- Puts the node into the container node just above it (its new last child). Returns true and the new path.
function IndentNode(stage, section, path)
    local list, index = Locate(stage, section, path)
    if not list or index < 2 then return nil, 'nothing above to put it into' end
    local above = list[index - 1]
    local t = byId[above.type]
    if not t or not t.container then return nil, 'the node above holds no children' end
    local node = list[index]
    local nt = byId[node.type]
    if table.getn(AsPath(path)) >= MAX_DEPTH then return nil, 'nested too deep' end
    local newPath
    local ok = Do('indent node', function()
        local l, i = Locate(stage, section, path)
        local n = table.remove(l, i)
        local holder = l[i - 1]
        holder.children = holder.children or {}
        table.insert(holder.children, n)
        local prefix = {}
        local p = AsPath(path)
        for d = 1, table.getn(p) - 1 do table.insert(prefix, p[d]) end
        table.insert(prefix, i - 1)
        table.insert(prefix, table.getn(holder.children))
        newPath = prefix
    end)
    if not ok then return nil end
    return true, newPath
end

--- Takes the node out of its container node and puts it behind it. Returns true and the new path.
function OutdentNode(stage, section, path)
    local p = AsPath(path)
    local depth = table.getn(p)
    if depth < 2 then return nil, 'the node is not inside a container' end
    local newPath
    local ok = Do('outdent node', function()
        local l, i = Locate(stage, section, path)
        local n = table.remove(l, i)
        local parentPath = {}
        for d = 1, depth - 1 do table.insert(parentPath, p[d]) end
        local pl, pi = Locate(stage, section, parentPath)
        table.insert(pl, pi + 1, n)
        local np = {}
        for d = 1, depth - 2 do table.insert(np, p[d]) end
        table.insert(np, pi + 1)
        newPath = np
    end)
    if not ok then return nil end
    return true, newPath
end

function SetParam(stage, section, path, key, value, merge)
    local _, _, node = Locate(stage, section, path)
    if not node then return nil, 'no such node' end
    return Do('edit node', function()
        local _, _, n = Locate(stage, section, path)
        n[key] = value
    end, merge and ('node' .. stage .. section .. PathKey(path) .. key) or nil)
end

-- ---- what the pickers offer -------------------------------------------------------------------------------------------------------------------------

local function CollectGroups(tree, list, prefix)
    if type(tree) ~= 'table' or type(tree.Units) ~= 'table' then return end
    for name, v in tree.Units do
        if type(v) == 'table' and v.type == 'GROUP' then
            table.insert(list, name)
            CollectGroups(v, list)
        end
    end
end

--- Names of the unit groups of an army (INITIAL spawns by itself, the others are for Spawn nodes).
function GroupNames(army)
    local list = {}
    local a = Map.Doc and Map.Doc.save.Armies and Map.Doc.save.Armies[army]
    if a then CollectGroups(a.Units, list) end
    table.sort(list)
    return list
end

--- Names of the single units of an army (any group).
function UnitNames(army)
    local list = {}
    local a = Map.Doc and Map.Doc.save.Armies and Map.Doc.save.Armies[army]
    local function Collect(tree)
        for name, v in (tree and tree.Units) or {} do
            if type(v) == 'table' then
                if v.type == 'GROUP' then Collect(v) else table.insert(list, name) end
            end
        end
    end
    if a then Collect(a.Units) end
    table.sort(list)
    return list
end

local function SortedKeys(t)
    local list = {}
    for k, _ in t or {} do table.insert(list, k) end
    table.sort(list)
    return list
end

function ChainNames() return SortedKeys(Map.Doc and Map.Doc.save.Chains) end
function AreaNames() return SortedKeys(Map.Doc and Map.Doc.save.Areas) end
function MarkerNames(markerType)
    local all = Map.Doc and Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
    if not markerType then return SortedKeys(all) end
    local list = {}
    for name, m in all or {} do
        if m.type == markerType then table.insert(list, name) end
    end
    table.sort(list)
    return list
end

function BaseNames()
    local list = {}
    for _, b in Data.bases or {} do table.insert(list, b.name) end
    table.sort(list)
    return list
end

--- Walks every node in the order the script runs them: visit(node, stage, section, path, scope) is called before the node's own definitions apply;
--- scope = { name = vtype } of the variables set by nodes before it (a trigger's children see the variables before the trigger, and what they set stays inside).
local function WalkAll(visit)
    local root = {}
    local function List(list, stage, section, prefix, scope)
        for i, node in list or {} do
            local path = prefix and Child(prefix, i) or { i }
            visit(node, stage, section, path, scope)
            local t = byId[node.type]
            if t then
                for _, p in t.params do
                    if p.kind == 'var' and p.defines and node[p.key] and node[p.key] ~= '' then scope[node[p.key]] = p.vtype or 'group' end
                end
                if t.container and node.children then
                    local inner = {}
                    for k, v in scope do inner[k] = v end
                    List(node.children, stage, section, path, inner)
                end
            end
        end
    end
    for si, s in Data.stages do
        List(s.enter, si, 'enter', nil, root)
        List(s.ready, si, 'ready', nil, root)
    end
end

--- Variables of type `vtype` ('group' default, 'objective') set by nodes before the node at (stage, section, path).
function DefinedVars(stage, section, path, vtype)
    vtype = vtype or 'group'
    local key = PathKey(path)
    local found
    WalkAll(function(node, si, sec, p, scope)
        if not found and si == stage and sec == section and PathKey(p) == key then
            found = {}
            for k, v in scope do found[k] = v end
        end
    end)
    local list = {}
    for k, v in found or {} do
        if v == vtype then table.insert(list, k) end
    end
    table.sort(list)
    return list
end

-- ---- compiling -------------------------------------------------------------------------------------------------------------------------------------

local function Hash(text)
    local a, b = 1, 0
    for i = 1, string.len(text) do
        a = math.mod(a + string.byte(text, i), 65521)
        b = math.mod(b + a, 65521)
    end
    return string.format('%05d%05d', a, b)
end

--- Does any node of the list (or a container of the kinds `into` accepts) satisfy `pred`?
local function Any(list, pred, into)
    for _, n in list or {} do
        if pred(n) then return true end
        local t = byId[n.type]
        if t and t.container and into(t) and Any(n.children, pred, into) then return true end
    end
    return false
end

local function AllContainers() return true end
local function PlainContainers(t) return not t.callback end

-- objectives of the stage itself (also inside if / cutscene containers, but not inside triggers: those objectives stand alone)
local function HasObjectives(stage)
    return Any(stage.ready, function(n) local t = byId[n.type] return t and t.family == 'objective' end, PlainContainers)
end

-- does the stage end the mission or start the next stage by itself (End or Next stage node, anywhere)?
local function HasExit(stage)
    local function Exit(n) return n.type == 'end' or n.type == 'next_stage' end
    return Any(stage.enter, Exit, AllContainers) or Any(stage.ready, Exit, AllContainers)
end

local function HasEnd(stage)
    local function Exit(n) return n.type == 'end' end
    return Any(stage.enter, Exit, AllContainers) or Any(stage.ready, Exit, AllContainers)
end

local function UsesType(id)
    for _, s in Data.stages do
        local function Is(n) return n.type == id end
        if Any(s.enter, Is, AllContainers) or Any(s.ready, Is, AllContainers) then return true end
    end
    return false
end

local Context
local function EmitList(list, C, prefix)
    local out = {}
    for _, node in list or {} do
        local t = byId[node.type]
        if t then
            for _, line in t.emit(node, C) do table.insert(out, prefix .. line) end
        else
            table.insert(out, prefix .. '-- unknown node type ' .. tostring(node.type))
        end
    end
    return out
end

--- What the emitters of one stage may ask: the stage number, the call that starts the next stage and the lines of a container's children.
Context = function(stage, nextCall, inCallback)
    local C = { stage = stage, nextCall = nextCall, inCallback = inCallback }
    C.Body = function(node, prefix, callback)
        return EmitList(node.children, Context(stage, nextCall, inCallback or callback), prefix or '    ')
    end
    return C
end

--- Lua text of the region body: header, base functions, one function per stage, OnPopulate / OnStart when `withEntry`.
function Compile(withEntry)
    local out = {}
    local function Add(line) table.insert(out, line) end
    local active = ActiveStages()       -- (stages imported from a hand-written script are never compiled; a stage keeps its position in the list as its number)
    local MB = import('/lua/editor/mbase.lua')
    Add("local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')")
    Add("local ScenarioFramework = import('/lua/ScenarioFramework.lua')")
    Add('local Objectives = ScenarioFramework.Objectives')
    if UsesType('cutscene') then Add("local Cinematics = import('/lua/cinematics.lua')") end
    Add('')
    Add('-- variables the nodes keep (spawned groups, objectives); stage progress')
    Add('local V = {}')
    Add('local Stage = {}')
    Add('local Base = {}')
    Add('local AssignedObjectives = {}')
    Add('local Difficulty = ScenarioInfo.Options.Difficulty or 2')
    for _, line in StringsLines() do Add(line) end
    Add('')
    Add("-- waits and timers: the editor's run panel can skip and speed them up (EditorSkip / EditorTimeScale are never set in a real game)")
    Add('local function Wait(seconds)')
    Add('    local skip = ScenarioInfo.EditorSkip or 0')
    Add('    local left = seconds * 10')
    Add('    while left > 0 do')
    Add('        if (ScenarioInfo.EditorSkip or 0) ~= skip then return end')
    Add('        WaitTicks(1)')
    Add('        left = left - (ScenarioInfo.EditorTimeScale or 1)')
    Add('    end')
    Add('end')
    Add('')
    Add('local function Timer(callback, seconds)')
    Add('    return ForkThread(function() Wait(seconds) callback() end)')
    Add('end')
    Add('')
    Add("-- what the editor's run panel looks at")
    Add('ScenarioInfo.EditorMission = { Stage = Stage, V = V, Objectives = AssignedObjectives }')
    Add('')
    Add('-- helpers of the wait and trigger nodes')
    Add('local function Alive(units)')
    Add('    local n = 0')
    Add('    for _, u in units or {} do')
    Add('        if u and not u.Dead then n = n + 1 end')
    Add('    end')
    Add('    return n')
    Add('end')
    Add('')
    Add('local function CountInArea(area, army, category)')
    Add('    local index = GetArmyBrain(army):GetArmyIndex()')
    Add('    local n = 0')
    Add('    for _, u in GetUnitsInRect(ScenarioUtils.AreaToRect(area)) or {} do')
    Add('        if not u.Dead and u:GetArmy() == index and EntityCategoryContains(category, u) then n = n + 1 end')
    Add('    end')
    Add('    return n')
    Add('end')
    Add('')
    for _, line in MB.Compile() do Add(line) end
    Add('ScenarioInfo.MissionNumber = 0')
    Add('')
    if active[1] then
        Add('-- the first stage; in the editor (edit mode) it waits for the Play button')
        Add('function EditorMissionStart()')
        Add('    if ScenarioInfo.Options.EditorMode then')
        Add('        while not ScenarioInfo.EditorPlaying do WaitSeconds(0.2) end')
        Add('    end')
        if Data.mode == 'coop' or Data.mode == 'both' then
            Add('    -- coop: a play test in the editor installs the coop support functions (lua/editor/coopshim.lua); in a real game the lobby loads the coop mod')
            Add("    if ScenarioInfo.Options.EditorMode then import('/lua/editor/coopshim.lua').Install() end")
        end
        Add('    Stage[ScenarioInfo.EditorStartStage or ' .. active[1].i .. ']()           -- a play test can start at any stage (Stages panel: Play from here)')
        Add('end')
        Add('')
    end
    for _, item in active do
        local i, stage = item.i, item.stage
        Add('-- stage ' .. i .. ': ' .. string.gsub(tostring(stage.name or ''), '[\r\n]', ' '))
        Add('Stage[' .. i .. '] = function()')
        Add('    if ScenarioInfo.MissionNumber >= ' .. i .. ' then return end')
        Add('    ScenarioInfo.MissionNumber = ' .. i)
        local objectives = HasObjectives(stage)
        local nextCall
        local following = NextActive(i)
        if following then nextCall = 'ForkThread(Stage[' .. following .. '])' end
        if objectives then
            local callback
            if nextCall then
                callback = 'function() ' .. nextCall .. ' end'
            elseif HasEnd(stage) then
                callback = 'function() end'
            else
                callback = 'function() ScenarioFramework.EndOperation(true, true, true) end'
            end
            Add('    local obj')
            Add('    local Group = Objectives.CreateGroup(' .. Q('Stage' .. i) .. ', ' .. callback .. ')')
        end
        if (tonumber(stage.failsafe) or 0) > 0 and nextCall then
            Add('    Timer(function() ' .. nextCall .. ' end, ' .. N(stage.failsafe) .. ')')
        end
        local C = Context(i, nextCall, false)
        for _, section in { 'enter', 'ready' } do
            for _, line in EmitList(stage[section], C, '    ') do Add(line) end
        end
        if not objectives and nextCall and not HasExit(stage) and not ((tonumber(stage.failsafe) or 0) > 0) then
            Add('    ' .. nextCall)
        end
        Add('end')
        Add('')
    end
    if withEntry then
        Add('function OnPopulate()')
        Add('    ScenarioUtils.InitializeScenarioArmies()')
        if Map.Doc and Map.Doc.save.Areas and Map.Doc.save.Areas['AREA_1'] then
            Add("    ScenarioFramework.SetPlayableArea('AREA_1', false)")
        end
        Add('end')
        Add('')
        Add('function OnStart(self)')
        if active[1] then Add('    ForkThread(EditorMissionStart)') end
        Add('end')
    end
    return table.concat(out, '\n') .. '\n'
end

local function RegionBounds(text)
    local s = string.find(text, BEGIN, 1, true)
    if not s then return nil end
    local e1, e2 = string.find(text, FINISH, s, true)
    if not e1 then return nil end
    return s, e2
end

--- Is the text only the editor's empty default script (OnPopulate / OnStart with nothing of their own)?
local function IsStub(text)
    local count = 0
    for _ in string.gfind(text, 'function') do count = count + 1 end
    return count <= 2 and string.find(text, 'function OnPopulate', 1, true) ~= nil and string.find(text, 'function OnStart', 1, true) ~= nil
        and not string.find(text, 'ForkThread', 1, true) and string.len(text) < 600
end

--- Compile(withEntry), but never a script that does not load: a mission with errors (a Raw Lua node with a syntax error ...) would make the whole map fail to start. Such a
--- mission is written as a stub that starts the army setup and warns in the log; Check() lists the reason in the Stages panel.
local function SafeCompile(withEntry)
    local body = Compile(withEntry)
    local ok, f = pcall(loadstring, body)
    if ok and f then return body end
    LOG('EDITOR mission: the generated script does not compile (' .. tostring(f) .. '): a stub is written instead')
    local lines = { "local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')", '',
        "local MISSION_ERROR = 'The mission script of this map has errors and was not generated: open the map in the editor, fix the findings of the Stages panel and save again.'" }
    if withEntry then
        table.insert(lines, 'function OnPopulate() ScenarioUtils.InitializeScenarioArmies() end')
        table.insert(lines, 'function OnStart(self) WARN(MISSION_ERROR) end')
    else
        table.insert(lines, 'function EditorMissionStart() WARN(MISSION_ERROR) end')
    end
    return table.concat(lines, '\n') .. '\n'
end

function PatchScript(text)
    if EditorStageCount() == 0 then return text, 'none' end       -- (nothing imported is ever written: the script of an imported mission stays byte for byte as it is)
    local s, e = RegionBounds(text)
    if s then
        local region = string.sub(text, s, e)
        local _, _, stored = string.find(region, 'hash=(%d+)')
        local _, bodyAt = string.find(region, '\n', 1, true)
        local bodyEnd = string.find(region, FINISH, 1, true)
        local body = bodyAt and string.sub(region, bodyAt + 1, bodyEnd - 1) or ''
        if stored and stored ~= Hash(body) then
            LOG('EDITOR mission: the generated part of the map script was edited by hand: left alone (delete the region to generate it again)')
            return text, 'detached'
        end
        local outside = string.sub(text, 1, s - 1) .. string.sub(text, e + 1)
        local withEntry = not (string.find(outside, 'function OnPopulate', 1, true) or string.find(outside, 'function OnStart', 1, true))
        local newBody = SafeCompile(withEntry)
        local newRegion = BEGIN .. ' (generated: edit the mission in the editor, not between these lines) hash=' .. Hash(newBody) .. '\n' .. newBody .. FINISH
        return string.sub(text, 1, s - 1) .. newRegion .. string.sub(text, e + 1), 'written'
    end
    local stub = IsStub(text)
    local withEntry = stub or not (string.find(text, 'function OnPopulate', 1, true) or string.find(text, 'function OnStart', 1, true))
    local body = SafeCompile(withEntry)
    local region = BEGIN .. ' (generated: edit the mission in the editor, not between these lines) hash=' .. Hash(body) .. '\n' .. body .. FINISH .. '\n'
    if stub then return region, 'written' end
    if not withEntry then LOG('EDITOR mission: the map script has its own OnPopulate / OnStart: add ForkThread(EditorMissionStart) to OnStart') end
    return text .. '\n' .. region, 'written'
end

-- ---- checks ------------------------------------------------------------------------------------------------------------------------------------------

local function GroupExists(tree, name)
    if type(tree) ~= 'table' then return false end
    if tree.Units and type(tree.Units) == 'table' then
        for k, v in tree.Units do
            if k == name then return true end
            if GroupExists(v, name) then return true end
        end
    end
    return false
end

function Check()
    local list = {}
    local function Add(sev, text, stage, section, index) table.insert(list, { sev = sev, text = text, stage = stage, section = section, index = index }) end
    local doc = Map.Doc
    local armies = {}
    for _, a in import('/lua/editor/armysetup.lua').Names() do armies[a] = true end
    local bases = {}
    for _, b in Data.bases or {} do bases[b.name] = true end
    if EditorStageCount() == 0 and table.getn(Data.bases or {}) == 0 then return list end       -- (an imported mission is the script's business: nothing to check)
    for _, d in Data.dialogues or {} do
        if not d.imported and table.getn(d.lines or {}) == 0 then Add('W', 'dialogue ' .. tostring(d.name) .. ' has no lines') end
    end
    -- editor stages behind imported ones are numbered by their position: the script must not use that number for one of its own stages
    local scriptNumbers = {}
    for _, s in Data.stages do
        if s.imported and s.info and s.info.number and s.info.number > 0 then scriptNumbers[s.info.number] = true end
    end
    for _, item in ActiveStages() do
        local si, stage = item.i, item.stage
        local following = NextActive(si)
        if scriptNumbers[si] then Add('W', 'stage ' .. si .. ' (' .. tostring(stage.name) .. ') gets MissionNumber ' .. si .. ', which the imported script also sets', si) end
        local nodes = table.getn(stage.enter or {}) + table.getn(stage.ready or {})
        if nodes == 0 then Add('W', 'stage ' .. si .. ' (' .. tostring(stage.name) .. ') has no nodes', si) end
        if (tonumber(stage.failsafe) or 0) > 0 and not following then Add('W', 'stage ' .. si .. ' has a failsafe timer but no next stage', si) end
        if HasObjectives(stage) == false and not following and not HasEnd(stage) then
            Add('W', 'the last stage has no objective and no End node: the mission never ends', si)
        end
        if not following then
            local sec = Any(stage.enter, function(n) return n.type == 'next_stage' end, AllContainers) and 'enter' or (Any(stage.ready, function(n) return n.type == 'next_stage' end, AllContainers) and 'ready')
            if sec then Add('E', 'stage ' .. si .. ' has a Next stage node but there is no next stage', si, sec) end
        end
    end
    -- every node, in script order, with the variables set before it
    WalkAll(function(n, si, section, path, scope)
        local ni = path
        local depth = table.getn(path)
        local t = byId[n.type]
        if not t then
            Add('E', 'unknown node type ' .. tostring(n.type), si, section, ni)
            return
        end
        if t.family == 'objective' and depth > 1 then
            -- reached through a container: standalone when a trigger sits above
            local holder = Data.stages[si][section]
            local inTrigger = false
            for d = 1, depth - 1 do
                local h = holder[path[d]]
                local ht = h and byId[h.type]
                if ht and ht.callback then inTrigger = true end
                holder = h and h.children
                if not holder then break end
            end
            if inTrigger and (n.otype or 'primary') == 'primary' then
                Add('I', t.title .. ': an objective made by a trigger does not hold up the stage (it stands alone)', si, section, ni)
            end
        end
        if t.family == 'coop' and Data.mode == 'campaign' then
            Add('E', t.title .. ': the mission mode is campaign, coop nodes need coop or both (Stages panel, Mode)', si, section, ni)
        end
        for _, p in t.params do
            local v = n[p.key]
            if p.kind == 'dialogue' then
                if v and v ~= '' then
                    if not FindDialogue(v) then Add('E', t.title .. ': there is no dialogue ' .. tostring(v) .. ' (Strings panel)', si, section, ni) end
                elseif not p.optional then
                    Add('E', t.title .. ': no dialogue chosen', si, section, ni)
                end
            elseif p.kind == 'army' then
                if not v or v == '' then Add('E', t.title .. ': no army chosen', si, section, ni)
                elseif not armies[v] then Add('E', t.title .. ': army ' .. tostring(v) .. ' is not in the army list', si, section, ni) end
            elseif p.kind == 'group' then
                if not v or v == '' then Add('E', t.title .. ': no group chosen', si, section, ni)
                elseif n.army and doc and doc.save.Armies and doc.save.Armies[n.army] then
                    local units = doc.save.Armies[n.army].Units
                    if n.bydiff then
                        for d = 1, 3 do
                            if not GroupExists(units, v .. '_D' .. d) then Add('E', t.title .. ': army ' .. tostring(n.army) .. ' has no group ' .. v .. '_D' .. d, si, section, ni) end
                        end
                    elseif not GroupExists(units, v) then
                        Add('E', t.title .. ': army ' .. tostring(n.army) .. ' has no group ' .. tostring(v), si, section, ni)
                    end
                end
            elseif p.kind == 'unit' then
                local found = false
                if v and v ~= '' and n.army then
                    for _, name in UnitNames(n.army) do if name == v then found = true end end
                end
                if not v or v == '' then Add('E', t.title .. ': no unit chosen', si, section, ni)
                elseif not found then Add('E', t.title .. ': army ' .. tostring(n.army) .. ' has no unit ' .. tostring(v), si, section, ni) end
            elseif p.kind == 'chain' then
                if not v or v == '' then Add('E', t.title .. ': no chain chosen', si, section, ni)
                elseif doc and doc.save.Chains and not doc.save.Chains[v] then Add('E', t.title .. ': there is no chain ' .. tostring(v), si, section, ni) end
            elseif p.kind == 'area' then
                if not v or v == '' then Add('E', t.title .. ': no area chosen', si, section, ni)
                elseif doc and doc.save.Areas and not doc.save.Areas[v] then Add('E', t.title .. ': there is no area ' .. tostring(v), si, section, ni) end
            elseif p.kind == 'marker' then
                if not v or v == '' then Add('E', t.title .. ': no marker chosen', si, section, ni)
                elseif doc and not doc.save.MasterChain._MASTERCHAIN_.Markers[v] then Add('E', t.title .. ': there is no marker ' .. tostring(v), si, section, ni)
                elseif p.mtype and doc.save.MasterChain._MASTERCHAIN_.Markers[v].type ~= p.mtype then Add('E', t.title .. ': marker ' .. tostring(v) .. ' is not a ' .. p.mtype .. ' marker', si, section, ni) end
            elseif KindChecks[p.kind] then
                local problem = KindChecks[p.kind](v, n, p, doc)
                if problem then Add('E', t.title .. ': ' .. problem, si, section, ni) end
            elseif p.kind == 'base' then
                if not v or v == '' then Add('E', t.title .. ': no base chosen', si, section, ni)
                elseif not bases[v] then Add('E', t.title .. ': there is no base ' .. tostring(v), si, section, ni) end
            elseif p.kind == 'text' and (p.key == 'category' or p.key == 'categories') then
                if not ExprOk(v) then Add('E', t.title .. ': ' .. p.label .. ' is not a Lua expression (' .. tostring(v) .. '), categories.ALLUNITS is used', si, section, ni) end
            elseif p.kind == 'var' then
                if p.defines then
                    if v and v ~= '' and not IsName(v) then Add('E', t.title .. ': ' .. tostring(v) .. ' is not a valid variable name', si, section, ni) end
                else
                    local want = p.vtype or 'group'
                    if not v or v == '' then Add('E', t.title .. ': no ' .. want .. ' variable chosen', si, section, ni)
                    elseif scope[v] ~= want then Add('E', t.title .. ': ' .. want .. ' variable ' .. tostring(v) .. ' is not set by an earlier node', si, section, ni) end
                end
            end
        end
    end)
    import('/lua/editor/mbase.lua').Check(Add)
    -- the generated script must compile (a Raw Lua node with a syntax error would empty the whole script)
    local ok, f, err = pcall(loadstring, Compile(true))       -- (a bad chunk may raise instead of returning nil, message)
    if not ok then err = f f = nil end
    if not f then Add('E', 'the generated script does not compile: ' .. tostring(err)) end
    return list
end

-- ---- the model travels with the map -----------------------------------------------------------------------------------------------------------------

function SidecarText()
    -- imported stages and dialogues are not written: the next load imports them again from the script (the sidecar keeps only `keepImport`, so that editor stages
    -- added behind them find their place again)
    local saved = {}
    for k, v in Data do
        if k ~= 'stages' and k ~= 'dialogues' and k ~= 'imported' and k ~= 'keepImport' then saved[k] = v end
    end
    saved.stages, saved.dialogues = {}, {}
    local hadImport = false
    for _, s in Data.stages do
        if s.imported then hadImport = true else table.insert(saved.stages, s) end
    end
    for _, d in Data.dialogues or {} do
        if d.imported then hadImport = true else table.insert(saved.dialogues, d) end
    end
    if table.getn(saved.stages) == 0 and table.getn(saved.bases or {}) == 0 and not (hadImport and table.getn(saved.dialogues) > 0) then return '' end
    if hadImport then saved.keepImport = true end
    return Ser.Chunk({ { 'Mission', saved } })
end

function LoadSidecar(scenarioFile)
    Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    local path = scenarioFile and import('/lua/editor/mods.lua').SidecarPath(scenarioFile)
    if not path or not DiskGetFileInfo(path) then return end
    local env = {}
    doscript(path, env)
    if env.Mission and env.Mission.stages then
        Data = env.Mission
        Data.mode = Data.mode or 'campaign'
        Data.bases = Data.bases or {}
        Data.dialogues = Data.dialogues or {}
        for _, s in Data.stages do
            s.enter = s.enter or {}
            s.ready = s.ready or {}
        end
    end
    Revision = Revision + 1
    LoadedRevision = Revision
end

-- ---- import of a hand-written mission (missionimport.lua) ---------------------------------------------------------------------------------------------

--- The script text without the generated region (blanked, so line numbers stay): the region is the editor's own, never part of what is imported.
local function WithoutRegion(text)
    local s, e = RegionBounds(text)
    if not s then return text end
    local blank = string.gsub(string.sub(text, s, e), '[^\n]', ' ')
    return string.sub(text, 1, s - 1) .. blank .. string.sub(text, e + 1)
end

--- `<stem>_strings.lua` next to the script (or the scenario file), or nil.
local function StringsPath(doc)
    for _, p in { doc.scriptPath, doc.scenarioPath } do
        if type(p) == 'string' then
            local q, n = string.gsub(p, '_%a+%.lua$', '_strings.lua')
            if n > 0 then return q end
        end
    end
    return nil
end

local function ReadVfs(vfs)
    if not vfs or not rawget(_G, 'ed_vfs_to_disk') or not rawget(_G, 'ed_read_file') then return nil end
    local disk = ed_vfs_to_disk(vfs)
    return disk and ed_read_file(disk) or nil
end

--- Puts the stages and dialogues of a hand-written mission into the model as IMPORTED entries (read-only, never compiled or saved): `scriptText` is the map script, `stringsText` its
--- strings file or nil, `info` = { type = scenario type, script = path, strings = path }. Editor stages already in the model stay behind the imported ones. Returns true when
--- the script has mission stages (ScenarioInfo.MissionNumber = N), else false and nothing changes.
function ImportText(scriptText, stringsText, info)
    info = info or {}
    local I = import('/lua/editor/missionimport.lua')
    local outline = I.Parse(WithoutRegion(scriptText or ''))
    if table.getn(outline.stages) == 0 then return false end
    local stages = I.Stages(outline)
    local dialogues = {}
    if stringsText and stringsText ~= '' then
        local ok, list = pcall(I.ParseStrings, stringsText)
        if ok and list then dialogues = list else LOG('EDITOR mission import: the strings file could not be read: ' .. tostring(list)) end
    end
    local editorMade = EditorStageCount() > 0 or table.getn(Data.bases or {}) > 0
    for _, s in Data.stages do
        if not s.imported then table.insert(stages, s) end
    end
    for _, d in Data.dialogues or {} do
        if not d.imported then table.insert(dialogues, d) end
    end
    Data.stages = stages
    Data.dialogues = dialogues
    Data.bases = Data.bases or {}
    if not editorMade then Data.mode = (info.type == 'campaign_coop') and 'both' or 'campaign' end
    Data.imported = { script = info.script, strings = stringsText and info.strings or nil, lineCount = outline.lineCount, stages = table.getn(outline.stages) }
    Revision = Revision + 1
    LoadedRevision = Revision
    return true
end

--- Map.Load: a map whose script has mission stages and whose sidecar holds no editor mission (or only stages made behind imported ones: `keepImport`) is imported.
--- The script file is only read. Returns true when something was imported.
function ImportScript(doc)
    doc = doc or Map.Doc
    if not doc or not doc.scriptPath then return false end
    if (EditorStageCount() > 0 or table.getn(Data.bases or {}) > 0) and not Data.keepImport then return false end
    local text = ReadVfs(doc.scriptPath)
    if not text or text == '' then return false end
    local strings = StringsPath(doc)
    return ImportText(text, ReadVfs(strings), { type = doc.info and doc.info.type, script = doc.scriptPath, strings = strings })
end

-- the platoon and order nodes live in their own file and register themselves here
pcall(function() import('/lua/editor/missionplat.lua') end)
