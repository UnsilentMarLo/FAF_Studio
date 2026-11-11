-- Adaptive maps: the model behind the Adaptive map panel and the Lobby options window (gui/panels_adaptive.lua). FAF's adaptive maps ("Ultimate maps" script by CookieNoob and KeyBlue) have
-- three files beside the scenario: `<base>_tables.lua` (which mass / hydrocarbon markers spawn with which army, which belong to the lobby options' groups, the crazyrush lists),
-- `<base>_script.lua` (reads the tables when the game starts; copied from an adaptive map, never made here) and `<base>_options.lua` (the lobby's options). This module holds the texts of
-- the two data files as they are and edits them through upstream's text model (moho/editor/EdUpAdaptiveLua.cpp, the `ed_adaptive_*` natives): only what changes is rewritten, the rest of
-- a file (comments, the mapper's own tables, unrelated options) stays as it was. Every change is one undo step; the files are written with the map (map.lua SaveAsCore calls WriteFiles).
--
--   Files()                         { adaptive, tablesPath, optionsPath, scriptPath, scriptReads, hasOptions } of the open map (vfs paths)
--   TablesText() / OptionsText() / Script()          the texts (edited ones, not what is on disk)
--   Tables()                        the parsed tables ({ maxPlayers, mexArmy, hydroArmy, options = { { name, groups } }, forwardCrazyrush, crazyrushOne }) | nil, message
--   LobbyOptions()                  the parsed `_options.lua` ({ { key, label, help, defaultIndex, values } })
--   Options()                       the setup by what the player picks: { { kind = 'mexes' | 'hydros' | 'levels' | 'other', key, lobby, table, title, scriptReads, loop } }
--   MakeAdaptive()                  the map gets fresh tables (one list per start slot) and AdaptiveMap = true
--   SetTables(tables, label) / SetTexts(tablesText, optionsText, label)       one undo step; false + reason when the tables do not read
--   Marker lists (names of the selected markers: SelectedMarkers()):
--     SetMaxPlayers(n), AssignToArmy(index, names), SpawnAlways(names), CrazyrushAdd(which, names), CrazyrushRemove(which, names)
--     AddToGroup(tableName, group, names) (group = number of the group, or #groups + 1 for a new one), RemoveGroup(tableName, group), RemoveFromTables(names), RemoveTable(tableName)
--   Lobby options: PutOption(option), RemoveOption(key), AddChoice(option, text), RemoveChoice(option, valueIndex), SyncTableOption(tableName)
--   Units: FateOf(army, unitName) -> { fate, rule, wreck, targets }, SelectedUnits(), MoveSelectedToGroup(army, path)
--   WriteFiles(diskDir, stem) / PatchScript(script, mount, stem)      what map.lua's save does with the files
--
-- Index conventions are those of the natives: 1-based, 0 = none / not offered.
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')

--- Bumped by every change (the panels compare it).
Revision = 0

local state = false

local function Native(name)
    return rawget(_G, name)
end

local function ReadText(vfs)
    if type(vfs) ~= 'string' or vfs == '' then return nil end
    if Native('ed_game_file_read') then
        local ok, text = pcall(ed_game_file_read, vfs)
        if ok and type(text) == 'string' then return text end
    end
    local disk = ed_vfs_to_disk(vfs)
    if disk and ed_file_exists(disk) then return ed_read_file(disk) end
    return nil
end

local function BaseOf(scenarioPath)
    return type(scenarioPath) == 'string' and string.gsub(scenarioPath, '_scenario%.lua$', '') or nil
end

--- Loads the texts of the open map once per document (a new document, or Reset, loads them again).
local function Ensure()
    local doc = Map.Doc
    if not doc then
        state = false
        return nil
    end
    if state and state.doc == doc then return state end
    local s = { doc = doc, parsed = false, parsedText = false, optionsParsed = false, optionsParsedText = false, setup = false, setupKey = false }
    s.script = ReadText(doc.scriptPath) or ''
    local base = BaseOf(doc.scenarioPath)
    local imported = s.script ~= '' and ed_adaptive_tables_path(s.script) or ''
    if imported ~= '' and ReadText(imported) then
        s.tablesPath = imported
    elseif base and ReadText(base .. '_tables.lua') then
        s.tablesPath = base .. '_tables.lua'
    end
    s.tables = s.tablesPath and ReadText(s.tablesPath) or ''
    if base and ReadText(base .. '_options.lua') then s.optionsPath = base .. '_options.lua' end
    s.options = s.optionsPath and ReadText(s.optionsPath) or ''
    s.base = base
    state = s
    return s
end

--- Forgets the loaded texts (the next call reads them again).
function Reset()
    state = false
    Revision = Revision + 1
end

function Script()
    local s = Ensure()
    return s and s.script or ''
end

function TablesText()
    local s = Ensure()
    return s and s.tables or ''
end

function OptionsText()
    local s = Ensure()
    return s and s.options or ''
end

function Files()
    local s = Ensure()
    if not s then return { adaptive = false } end
    local path = ed_adaptive_tables_path(s.script)
    return {
        adaptive = s.tablesPath ~= nil,
        tablesPath = s.tablesPath or (s.base and (s.base .. '_tables.lua')),
        optionsPath = s.optionsPath or (s.base and (s.base .. '_options.lua')),
        scriptPath = s.doc.scriptPath,
        scriptReads = path ~= '',
        scriptImports = path,
        hasOptions = s.options ~= '',
    }
end

function IsAdaptive()
    local s = Ensure()
    return s ~= nil and s ~= false and s.tablesPath ~= nil
end

--- The parsed tables, cached per text.
function Tables()
    local s = Ensure()
    if not s then return nil, 'no map' end
    if s.tablesPath == nil then return nil, 'the map is not adaptive' end
    if s.parsedText ~= s.tables then
        s.parsed, s.parseError = ed_adaptive_tables_parse(s.tables)
        s.parsedText = s.tables
    end
    if not s.parsed then return nil, s.parseError end
    return s.parsed
end

local function Copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = Copy(v) end
    return c
end

--- The parsed tables as a copy that may be changed (Tables() hands out the cached one).
function TablesCopy()
    local t, why = Tables()
    if not t then return nil, why end
    return Copy(t)
end

function LobbyOptions()
    local s = Ensure()
    if not s then return {} end
    if s.optionsParsedText ~= s.options then
        s.optionsParsed = ed_adaptive_options_parse(s.options)
        s.optionsParsedText = s.options
    end
    return s.optionsParsed
end

--- The setup by what the player picks (see the natives' header), cached per text.
function Options()
    local s = Ensure()
    if not s then return {} end
    local key = s.tables .. '\0' .. s.options .. '\0' .. s.script
    if s.setupKey ~= key then
        local tables = Tables() or s.tables
        s.setup = ed_adaptive_options_of(s.script, s.options, tables)
        s.setupKey = key
    end
    return s.setup
end

-- ---- changing the texts ---------------------------------------------------------------------------------------------------------------------------

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Snapshot(s)
    return { tables = s.tables, options = s.options, tablesPath = s.tablesPath, optionsPath = s.optionsPath, flag = s.doc.info.AdaptiveMap }
end

local function Restore(s, snap)
    s.tables, s.options, s.tablesPath, s.optionsPath = snap.tables, snap.options, snap.tablesPath, snap.optionsPath
    s.doc.info.AdaptiveMap = snap.flag
    Revision = Revision + 1
end

--- Sets the texts of the two files as one undo step. Nothing is done (false, reason) when the new tables do not read. A map without tables becomes adaptive (AdaptiveMap = true in its scenario,
--- the file `<base>_tables.lua` beside it); one without `_options.lua` gets the file beside the scenario.
function SetTexts(tablesText, optionsText, label)
    local s = Ensure()
    if not s then return false, 'no map' end
    tablesText = tablesText or s.tables
    optionsText = optionsText or s.options
    if tablesText == s.tables and optionsText == s.options then return true end
    if tablesText ~= s.tables and tablesText ~= s.tables then
        local ok, why = ed_adaptive_tables_parse(tablesText)
        if not ok then return false, 'the tables do not read: ' .. tostring(why) end
    end
    local before = Snapshot(s)
    if tablesText ~= s.tables then
        if not s.tablesPath then
            if not s.base then return false, 'the map has no scenario file name' end
            s.tablesPath = s.base .. '_tables.lua'
            s.doc.info.AdaptiveMap = true
        end
        s.tables = tablesText
    end
    if optionsText ~= s.options then
        if not s.optionsPath and s.base then s.optionsPath = s.base .. '_options.lua' end
        s.options = optionsText
    end
    local after = Snapshot(s)
    Revision = Revision + 1
    History.Push({
        label = label or 'adaptive map',
        undo = function() Restore(s, before) end,
        redo = function() Restore(s, after) end,
    })
    return true
end

function SetTables(tables, label)
    local s = Ensure()
    if not s then return false, 'no map' end
    return SetTexts(ed_adaptive_tables_write(s.tables, tables), nil, label)
end

function MakeAdaptive()
    local s = Ensure()
    if not s then return false, 'no map' end
    if s.tablesPath then return true end
    local slots = 0
    pcall(function() slots = table.getn(import('/lua/editor/armies.lua').Names()) end)
    local fresh = { maxPlayers = math.max(slots, 1), mexArmy = {}, hydroArmy = {}, options = {}, forwardCrazyrush = {}, crazyrushOne = {} }
    for i = 1, fresh.maxPlayers do
        fresh.mexArmy[i] = {}
        fresh.hydroArmy[i] = {}
    end
    return SetTexts(ed_adaptive_tables_write('', fresh), nil, 'make the map adaptive')
end

-- ---- marker lists -----------------------------------------------------------------------------------------------------------------------------------

--- The selected mass and hydrocarbon markers the script can read: { mass = { names }, hydro = { names } } (a marker of another type, or one whose name has no number, is left out).
function SelectedMarkers()
    local mass, hydro = {}, {}
    local Tools = import('/lua/editor/tools.lua')
    local markers = Map.Doc and Map.Doc.save.MasterChain and Map.Doc.save.MasterChain._MASTERCHAIN_.Markers or {}
    for _, it in Tools.Items do
        if it.kind == 'marker' then
            local m = markers[it.name]
            local kind = m and m.type
            if kind == 'Mass' and ed_adaptive_entry(it.name, false) ~= '' then
                table.insert(mass, it.name)
            elseif kind == 'Hydrocarbon' and ed_adaptive_entry(it.name, true) ~= '' then
                table.insert(hydro, it.name)
            end
        end
    end
    return { mass = mass, hydro = hydro }
end

local function Has(list, name)
    for _, n in list do
        if n == name then return true end
    end
    return false
end

local function Without(list, names)
    local out = {}
    for _, n in list do
        if not Has(names, n) then table.insert(out, n) end
    end
    return out
end

local function Hydro(name)
    return ed_adaptive_entry(name, true) ~= '' and ed_adaptive_entry(name, false) == ''
end

--- A copy of the parsed tables with every marker of `names` taken out of every list (the armies', the groups', the crazyrush lists).
local function TakeOut(tables, names)
    for i = 1, table.getn(tables.mexArmy) do tables.mexArmy[i] = Without(tables.mexArmy[i], names) end
    for i = 1, table.getn(tables.hydroArmy) do tables.hydroArmy[i] = Without(tables.hydroArmy[i], names) end
    for _, opt in tables.options do
        for g = 1, table.getn(opt.groups) do opt.groups[g] = Without(opt.groups[g], names) end
    end
    tables.forwardCrazyrush = Without(tables.forwardCrazyrush, names)
    tables.crazyrushOne = Without(tables.crazyrushOne, names)
end

local function Edit(label, fn)
    local tables, why = TablesCopy()
    if not tables then return false, why end
    local ok, reason = fn(tables)
    if ok == false then return false, reason end
    -- the script reads armies up to maxPlayerOnMap: never fewer than the lobby's slots
    return SetTables(tables, label)
end

function SetMaxPlayers(n)
    return Edit('max players', function(t) t.maxPlayers = math.max(1, math.min(16, math.floor(n))) end)
end

--- The markers of `names` spawn only with army number `index` (1 = ARMY_1): taken out of every list first.
function AssignToArmy(index, names)
    return Edit('resources to ARMY_' .. index, function(t)
        TakeOut(t, names)
        while table.getn(t.mexArmy) < index do table.insert(t.mexArmy, {}) end
        while table.getn(t.hydroArmy) < index do table.insert(t.hydroArmy, {}) end
        for _, n in names do
            local into = Hydro(n) and t.hydroArmy[index] or t.mexArmy[index]
            table.insert(into, n)
        end
    end)
end

function SpawnAlways(names)
    return Edit('resources spawn always', function(t) TakeOut(t, names) end)
end

--- which: 'forward' (forwardCrazyrushMexes) | 'one' (crazyrushOneMexes).
function CrazyrushAdd(which, names)
    return Edit('crazyrush list', function(t)
        local list = which == 'one' and t.crazyrushOne or t.forwardCrazyrush
        for _, n in names do
            if not Has(list, n) then table.insert(list, n) end
        end
    end)
end

function CrazyrushRemove(which, names)
    return Edit('crazyrush list', function(t)
        if which == 'one' then t.crazyrushOne = Without(t.crazyrushOne, names) else t.forwardCrazyrush = Without(t.forwardCrazyrush, names) end
    end)
end

-- ---- option tables (groups of resources a lobby option adds) -------------------------------------------------------------------------------------

local function TableInfo(name)
    for _, t in ed_adaptive_known_tables() do
        if t.name == name then return t end
    end
    return nil
end

local function FindTable(tables, name)
    for _, opt in tables.options do
        if opt.name == name then return opt end
    end
    return nil
end

--- The lobby option that goes with a table, one value per group (key 1 = none, key k = groups 1 .. k-1). An option the file has already keeps its label, help and the wording of its values:
--- only the values are added or dropped at the end when the group count changed (a mapper's "Spawn 1 additional mexes" stays); an option it lacks is written whole (disabled, then one value per
--- group with its resource count); a table without groups loses its option. Returns the new `_options.lua` text.
local function OptionWithTable(optionsText, info, groups)
    local n = table.getn(groups)
    if n == 0 then return ed_adaptive_option_remove(optionsText, info.optionKey) end
    local found = ed_adaptive_option_find(optionsText, info.optionKey)
    if found.found and found.values == n + 1 then return optionsText end
    if found.found then
        for _, o in ed_adaptive_options_parse(optionsText) do
            if o.key == info.optionKey then
                local copy = { key = o.key, label = o.label, help = o.help, defaultIndex = o.defaultIndex, values = {} }
                for i = 1, n + 1 do
                    local v = o.values[i]
                    if not v then
                        v = ed_adaptive_next_level(copy, 'group ' .. (i - 1))
                        v.help = 'Groups 1 to ' .. (i - 1) .. ' spawn.'
                    end
                    copy.values[i] = v
                end
                if copy.defaultIndex > n + 1 then copy.defaultIndex = n + 1 end
                return ed_adaptive_option_put(optionsText, copy)
            end
        end
    end
    local sizes = {}
    for g = 1, n do sizes[g] = table.getn(groups[g]) end
    return ed_adaptive_option_for(optionsText, info.optionKey, info.label, info.hydro, sizes)
end

--- Rewrites the lobby option of a table to match its groups.
function SyncTableOption(tableName)
    local tables = Tables()
    local info = TableInfo(tableName)
    if not tables or not info then return false, 'unknown table' end
    local opt = FindTable(tables, tableName)
    return SetTexts(nil, OptionWithTable(OptionsText(), info, opt and opt.groups or {}), 'lobby option ' .. info.optionKey)
end

--- Puts markers into group `group` of an option table (the groups are 1-based; #groups + 1 makes a new group; the table is added when it is not there yet); the markers are taken out of
--- every other list. The table's lobby option is written with it (one value per group). One undo step.
function AddToGroup(tableName, group, names)
    local info = TableInfo(tableName)
    if not info then return false, 'unknown option table ' .. tostring(tableName) end
    local tables, why = TablesCopy()
    if not tables then return false, why end
    TakeOut(tables, names)
    local opt = FindTable(tables, tableName)
    if not opt then
        opt = { name = tableName, groups = {} }
        table.insert(tables.options, opt)
    end
    group = math.max(1, math.min(group, table.getn(opt.groups) + 1))
    if not opt.groups[group] then opt.groups[group] = {} end
    for _, n in names do
        if not Has(opt.groups[group], n) then table.insert(opt.groups[group], n) end
    end
    local tablesText = ed_adaptive_tables_write(TablesText(), tables)
    return SetTexts(tablesText, OptionWithTable(OptionsText(), info, opt.groups), 'resources to ' .. tableName .. ' group ' .. group)
end

function RemoveGroup(tableName, group)
    local info = TableInfo(tableName)
    local tables, why = TablesCopy()
    if not info or not tables then return false, why or 'unknown option table' end
    local opt = FindTable(tables, tableName)
    if not opt or not opt.groups[group] then return false, 'no such group' end
    table.remove(opt.groups, group)
    local tablesText = ed_adaptive_tables_write(TablesText(), tables)
    return SetTexts(tablesText, OptionWithTable(OptionsText(), info, opt.groups), 'remove ' .. tableName .. ' group ' .. group)
end

--- The resources of a table spawn in every game again (the table and its lobby option go).
function RemoveTable(tableName)
    local info = TableInfo(tableName)
    local tables, why = TablesCopy()
    if not info or not tables then return false, why or 'unknown option table' end
    local keep = {}
    for _, opt in tables.options do
        if opt.name ~= tableName then table.insert(keep, opt) end
    end
    tables.options = keep
    return SetTexts(ed_adaptive_tables_write(TablesText(), tables), ed_adaptive_option_remove(OptionsText(), info.optionKey), 'remove ' .. tableName)
end

--- The markers belong to no list any more (they spawn in every game).
function RemoveFromTables(names)
    local tables, why = TablesCopy()
    if not tables then return false, why end
    TakeOut(tables, names)
    local text = ed_adaptive_tables_write(TablesText(), tables)
    local optionsText = OptionsText()
    for _, info in ed_adaptive_known_tables() do
        local opt = FindTable(tables, info.name)
        if opt then optionsText = OptionWithTable(optionsText, info, opt.groups) end
    end
    return SetTexts(text, optionsText, 'resources spawn always')
end

-- ---- lobby options ----------------------------------------------------------------------------------------------------------------------------------

--- Writes an option back as `option` has it ({ key, label, help, defaultIndex, values }); an option the file lacks is added.
function PutOption(option, label)
    local text = ed_adaptive_option_put(OptionsText(), option)
    return SetTexts(nil, text, label or ('lobby option ' .. tostring(option.key)))
end

function RemoveOption(key)
    return SetTexts(nil, ed_adaptive_option_remove(OptionsText(), key), 'remove lobby option ' .. tostring(key))
end

--- A level / choice after the last one of the option ({ key, label, ... } as parsed): the next counted key, `text` its text.
function AddChoice(option, text)
    local copy = { key = option.key, label = option.label, help = option.help, defaultIndex = option.defaultIndex, values = {} }
    for i, v in option.values do copy.values[i] = v end
    table.insert(copy.values, ed_adaptive_next_level(option, text))
    return PutOption(copy, 'add a choice to ' .. option.key)
end

function RemoveChoice(option, valueIndex)
    if not option.values[valueIndex] then return false, 'no such choice' end
    local copy = { key = option.key, label = option.label, help = option.help, defaultIndex = option.defaultIndex, values = {} }
    for i, v in option.values do
        if i ~= valueIndex then table.insert(copy.values, v) end
    end
    if copy.defaultIndex > table.getn(copy.values) then copy.defaultIndex = table.getn(copy.values) end
    return PutOption(copy, 'remove a choice of ' .. option.key)
end

-- ---- units ------------------------------------------------------------------------------------------------------------------------------------------

--- The selected units as { { army, name }, ... }.
function SelectedUnits()
    local list = {}
    for _, sel in import('/lua/editor/units.lua').Selection do table.insert(list, { army = sel.army, name = sel.name }) end
    return list
end

--- Is the army not one of the lobby's player slots (the scenario's team list)? Such an army is "civilian": its INITIAL group is created unless the lobby's Civilians option removes it.
function IsCivilian(army)
    local info = Map.Doc and Map.Doc.info
    local teams = info and info.Configurations and info.Configurations.standard and info.Configurations.standard.teams
    for _, team in teams or {} do
        for _, a in team.armies or {} do
            if a == army then return false end
        end
    end
    return true
end

local function Underwater(x, z)
    local ok, level = pcall(function() return import('/lua/editor/fieldgen.lua').WaterLevel() end)
    if not ok or not level then return false end
    return (ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0) < level
end

--- What becomes of a unit: { fate = { kind, group, text }, rule = { lines, when, never, cases... } | nil (for a group the script creates), wreck = { exists, mass, energy } | nil, group = path }.
function FateOf(army, name)
    local Units = import('/lua/editor/units.lua')
    local u = Units.Lookup(army, name)
    if not u then return nil, 'no such unit' end
    local s = Ensure()
    local path = Units.SplitGroup(u.group)
    local fate = ed_adaptive_fate(path, IsCivilian(army), s and s.script or '')
    local out = { fate = fate, group = path, unit = u }
    if fate.kind == 'scriptUnit' or fate.kind == 'scriptWreck' or fate.kind == 'scriptEither' then
        out.rule = ed_adaptive_rule(s.script, s.options, fate.group)
    end
    if fate.kind == 'wreck' or fate.kind == 'scriptWreck' or fate.kind == 'scriptEither' then
        if Native('ed_wreck_value') then
            local w = ed_wreck_value(u.bp, Underwater(u.x, u.z))
            if w and w.known then out.wreck = w end
        end
    end
    return out
end

--- The places a unit of `army` can be put so that the script brings it into games: { { path, exists, rule, when, wreck, unit, optionsWith, optionsChange }, ... }.
function SpawnTargets(army)
    local s = Ensure()
    if not s then return {} end
    return ed_adaptive_spawn_targets(s.script, s.options, army, import('/lua/editor/units.lua').GroupPaths(army))
end

--- Moves the units into the group `target.path` (a SpawnTargets entry); when the target says the lobby needs another option text (`optionsWith`), that is written first (a second undo step).
function MoveToTarget(army, names, target)
    local Units = import('/lua/editor/units.lua')
    local list = {}
    for _, n in names do table.insert(list, { army = army, name = n }) end
    if target.optionsWith and target.optionsWith ~= '' then SetTexts(nil, target.optionsWith, 'lobby option: ' .. tostring(target.optionsChange)) end
    return Units.MoveToGroup(list, table.concat(target.path, '/'))
end

-- ---- saving -----------------------------------------------------------------------------------------------------------------------------------------

--- The script with the tables' import path of the map's old folder / name replaced by the new one (a save into a new folder or under a new name keeps reading its own tables).
function PatchScript(script, mount, stem)
    local s = Ensure()
    if not s or not s.tablesPath or type(script) ~= 'string' then return script end
    local old = ed_adaptive_tables_path(script)
    if old == '' then return script end
    local new = mount .. '/' .. stem .. '_tables.lua'
    if old == new then return script end
    local at = string.find(script, old, 1, true)
    if not at then return script end
    return string.sub(script, 1, at - 1) .. new .. string.sub(script, at + string.len(old))
end

--- Writes `<stem>_tables.lua` and `<stem>_options.lua` into the map folder when the map has them. Returns true, or false + the file that failed.
function WriteFiles(diskDir, stem)
    local s = Ensure()
    if not s then return true end
    if s.tablesPath and not ed_write_file(diskDir .. '/' .. stem .. '_tables.lua', s.tables) then return false, stem .. '_tables.lua' end
    if (s.optionsPath or s.options ~= '') and not ed_write_file(diskDir .. '/' .. stem .. '_options.lua', s.options) then return false, stem .. '_options.lua' end
    return true
end
