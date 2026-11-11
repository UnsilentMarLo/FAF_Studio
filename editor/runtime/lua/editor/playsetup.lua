-- Play setup: how a test run (Play) is set up. Solo, or against AIs of any type (the game's own and the AI mods' CustomAIs_v2), per army slot: you / AI / empty, the team, the faction
-- (random or one); fog of war, the victory condition, unit cap, the cheating AIs' multiplier, pre-built bases and the sim mods the run plays with. The setup is remembered
-- (the last one used, one per map for the maps that keep their own) and saved as named profiles in the user folder (play_setups.lua).
--
-- What upstream's editor does (src/editor/EdPlay.cpp, a second session) is here a session of the same editor: the plain Solo setup runs in the editing session as before (ui.lua Play,
-- EdSetPlay); everything else needs armies with a brain, fog, mods or another faction, which only a session start can make, so Play saves the map, writes the launch file
-- (LaunchText below) and opens the saved copy in a new session that starts in play mode (schook/lua/SinglePlayerLaunch.lua reads the file, the armies are made as FAF's quick start
-- makes them: SetupCommandLineSkirmish). Stop opens the autosave again, as for every test run.
--
--   Setup tables:  { fog = bool, victory = 'sandbox', unitCap = 1000, cheat = 1.5, prebuilt = bool, mods = { uid, ... },
--                    slots = { { role = 'you' | 'ai' | 'empty', ai = '<AI key>', team = 0 (none) .. 8, faction = '' (random) | 'uef' | 'aeon' | 'cybran' | 'seraphim' }, ... } }
--
--   Lists (UI state):   AiTypes() { key, name, mod }, Factions() { key, name }, Mods() { uid, name, ai = { keys } }, SlotCount(), MapKey()
--   Setups:             Solo(n) / Builtin(name, n), Normalize(setup, n), NeedsReload(setup), Problems(setup), UsedMods(setup)
--   Remembered:         Current(), Remember(setup, keepForMap), KeepsOwn(), Profiles() / GetProfile / SaveProfile / DeleteProfile
--   Launch:             LaunchTable(setup, scenarioPath), WriteLaunch(setup, scenarioPath), ReadLaunch(scenarioPath) (the session start; the file is emptied when read)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

local UserData = import('/lua/editor/userdata.lua')
local LuaSer = import('/lua/editor/luaser.lua')

FILE = 'play_setups.lua'                    -- in the user folder
LAUNCH_FILE = 'editor_play_launch.txt'      -- next to the exe, like the other session files (control.lua)
MAX_SLOTS = 16
MAX_TEAM = 8
-- the editing session's own setup: what it can play without a new session (SinglePlayerLaunch.lua EditorStartSession: you in the first slot, UEF, no fog, sandbox, unit cap 1000)
EDIT_FACTION = 'uef'
EDIT_UNIT_CAP = 1000

--- The game's victory conditions (FAF lobbyOptions.lua, key Victory).
VICTORY = {
    { key = 'sandbox', name = 'Sandbox (never ends)' },
    { key = 'demoralization', name = 'Assassination (commander dies)' },
    { key = 'decapitation', name = 'Decapitation (all allied commanders)' },
    { key = 'domination', name = 'Supremacy (structures, commanders, engineers)' },
    { key = 'eradication', name = 'Annihilation (all units)' },
}

--- The unit caps the game's lobby offers.
UNIT_CAPS = { 125, 250, 375, 500, 625, 750, 875, 1000, 1250, 1500 }

BUILTIN = { 'Solo sandbox', 'You vs 1 AI', '2 v 2 with AI', 'Free for all with AI', 'Watch 4 AI' }

local lists = false       -- { ai, factions, mods } read once per session (the game's lists do not change while the editor runs)

local function Copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = Copy(v) end
    return c
end

local function Plain(text)
    -- "<LOC lobui_0347>AI: Easy" -> "AI: Easy"
    text = tostring(text or '')
    return (string.gsub(text, '^<LOC [^>]*>', ''))
end

-- ---- the game's lists -------------------------------------------------------------------------------------------------------------------------

--- The game's AI types (FAF aitypes.lua), then those of the AI mods (a mod's lua/AI/CustomAIs_v2 files: AI.AIList and AI.CheatAIList, as FAF's own GetAItypes reads them for the mods
--- of a lobby). Each { key, name, mod } where `mod` is the uid of the mod that brings the type ('' for the game's own).
local function ReadAiTypes(mods)
    local out, known = {}, {}
    local ok, base = pcall(function() return import('/lua/ui/lobby/aitypes.lua').GetAItypes() end)
    if ok and type(base) == 'table' then
        for _, t in base do
            if type(t) == 'table' and t.key and not known[t.key] then
                known[t.key] = true
                table.insert(out, { key = t.key, name = Plain(t.name or t.key), mod = '' })
            end
        end
    end
    for _, m in mods do
        for _, t in m.ai do
            if not known[t.key] then
                known[t.key] = true
                table.insert(out, { key = t.key, name = m.name .. ': ' .. Plain(t.name or t.key), mod = m.uid })
            end
        end
    end
    return out
end

--- The sim mods a run can play with (not the editor's own mods, not UI-only ones) and the AI types each brings.
local function ReadMods()
    local out = {}
    local ok, browsable = pcall(function() return import('/lua/editor/mods.lua').Browsable() end)
    if not ok then return out end
    for _, mod in browsable do
        local entry = { uid = mod.uid, name = Plain(mod.name or mod.uid), ai = {} }
        local folder = (mod.location or '') .. '/lua/AI/CustomAIs_v2'
        if mod.location and DiskGetFileInfo(folder) then
            local okFiles, files = pcall(DiskFindFiles, folder, '*.lua')
            if okFiles and files then
                for _, file in files do
                    local okImport, data = pcall(import, file)
                    if okImport and type(data) == 'table' and type(data.AI) == 'table' then
                        for _, list in { data.AI.AIList or {}, data.AI.CheatAIList or {} } do
                            for _, t in list do
                                if type(t) == 'table' and t.key then table.insert(entry.ai, { key = t.key, name = t.name }) end
                            end
                        end
                    end
                end
            end
        end
        table.insert(out, entry)
    end
    return out
end

local function Lists()
    if lists then return lists end
    local mods = ReadMods()
    local factions = {}
    local ok, all = pcall(function() return import('/lua/factions.lua').Factions end)
    if ok and type(all) == 'table' then
        for _, f in all do
            if f.Key then table.insert(factions, { key = f.Key, name = Plain(f.DisplayName or f.Key) }) end
        end
    end
    if table.getn(factions) == 0 then
        factions = { { key = 'uef', name = 'UEF' }, { key = 'aeon', name = 'Aeon' }, { key = 'cybran', name = 'Cybran' }, { key = 'seraphim', name = 'Seraphim' } }
    end
    lists = { ai = ReadAiTypes(mods), factions = factions, mods = mods }
    if table.getn(lists.ai) == 0 then lists.ai = { { key = 'rush', name = 'AI: Rush', mod = '' } } end
    return lists
end

--- Tests: the lists a fake game would have; nil reads the game's again.
function UseLists(fake)
    lists = fake or false
end

function AiTypes() return Lists().ai end
function Factions() return Lists().factions end
function Mods() return Lists().mods end

--- The AI type entry of a key (nil when the game has no such type any more).
function AiType(key)
    for _, t in Lists().ai do
        if t.key == key then return t end
    end
    return nil
end

--- The name an AI type is shown with; an unknown key shows as itself.
function AiName(key)
    local t = AiType(key)
    return t and t.name or tostring(key)
end

function FactionName(key)
    if not key or key == '' then return 'Random' end
    for _, f in Lists().factions do
        if f.key == key then return f.name end
    end
    return tostring(key)
end

--- FAF's quick start plays against "rush"; a game without it uses its first type.
function DefaultAi()
    if AiType('rush') then return 'rush' end
    return Lists().ai[1].key
end

-- ---- the map ----------------------------------------------------------------------------------------------------------------------------------

--- How many start positions (ARMY_n markers) the open map has; at least 1.
function SlotCount()
    local n = 0
    local ok, Map = pcall(import, '/lua/editor/map.lua')
    if ok and Map.Doc and Map.Doc.save then
        local markers = Map.Doc.save.MasterChain and Map.Doc.save.MasterChain._MASTERCHAIN_ and Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
        for name, _ in markers or {} do
            if string.find(name, '^ARMY_%d+$') then n = n + 1 end
        end
    end
    return math.max(1, math.min(n, MAX_SLOTS))
end

--- The key a map's own setup is kept under: its folder name in lower case without a .vNNNN version ('scmp_009').
function MapKey()
    local ok, Map = pcall(import, '/lua/editor/map.lua')
    local path = ok and Map.Doc and Map.Doc.scenarioPath
    if not path then return nil end
    path = string.gsub(tostring(path), '\\', '/')
    local folder = string.gsub(path, '/[^/]*$', '')
    folder = string.gsub(folder, '^.*/', '')
    folder = string.gsub(string.lower(folder), '%.v%d+$', '')
    if folder == '' then return nil end
    return folder
end

--- True when the open map is a campaign / coop mission: its armies are the mission's, a play setup does not apply (it plays with its own brains).
function IsCampaign()
    local ok, Map = pcall(import, '/lua/editor/map.lua')
    local t = ok and Map.Doc and Map.Doc.info and Map.Doc.info.type
    return t == 'campaign' or t == 'campaign_coop'
end

-- ---- setups -----------------------------------------------------------------------------------------------------------------------------------

local function EmptySlot()
    return { role = 'empty', ai = DefaultAi(), team = 0, faction = '' }
end

--- The editing session's own setup, for a map with `n` start positions: you in the first, nobody else.
function Solo(n)
    local s = { fog = false, victory = 'sandbox', unitCap = EDIT_UNIT_CAP, cheat = 1.5, prebuilt = false, mods = {}, slots = {} }
    for i = 1, math.max(1, n or 1) do
        s.slots[i] = EmptySlot()
    end
    s.slots[1].role = 'you'
    s.slots[1].faction = EDIT_FACTION
    return s
end

--- A built-in profile for a map with `n` start positions (the names of BUILTIN). nil for another name.
function Builtin(name, n)
    n = math.max(1, math.min(n or 2, MAX_SLOTS))
    local s = Solo(n)
    local ai = DefaultAi()
    if name == BUILTIN[1] then
        return s
    elseif name == BUILTIN[2] then
        if n >= 2 then s.slots[2].role = 'ai' s.slots[2].ai = ai end
        s.slots[1].faction = ''
        s.fog = true
        return s
    elseif name == BUILTIN[3] or name == BUILTIN[4] then
        local count = (name == BUILTIN[3]) and math.min(4, math.max(n, 2)) or math.max(n, 2)
        s.fog = true
        for i = 1, math.min(count, n) do
            local slot = s.slots[i]
            slot.role = (i == 1) and 'you' or 'ai'
            slot.ai = ai
            slot.faction = ''
            slot.team = (name == BUILTIN[3]) and (1 + math.mod(i - 1, 2)) or 0
        end
        return s
    elseif name == BUILTIN[5] then
        s.fog = false
        s.slots[1].role = 'empty'
        s.slots[1].faction = ''
        for i = 1, math.min(4, n) do
            s.slots[i].role = 'ai'
            s.slots[i].ai = ai
        end
        return s
    end
    return nil
end

--- A setup made safe: known fields in range, exactly `n` slots (new ones empty, extra ones dropped), at most one You, teams within range, mods a list of strings. Never raises, never
--- changes `setup`; a table that is no setup at all gives Solo(n).
function Normalize(setup, n)
    n = math.max(1, math.min(n or 1, MAX_SLOTS))
    if type(setup) ~= 'table' then return Solo(n) end
    local s = Solo(n)
    s.fog = setup.fog == true
    s.prebuilt = setup.prebuilt == true
    s.victory = 'sandbox'
    for _, v in VICTORY do
        if v.key == setup.victory then s.victory = v.key end
    end
    local cap = tonumber(setup.unitCap) or EDIT_UNIT_CAP
    s.unitCap = UNIT_CAPS[1]
    for _, c in UNIT_CAPS do
        if math.abs(c - cap) < math.abs(s.unitCap - cap) then s.unitCap = c end
    end
    local cheat = tonumber(setup.cheat) or 1.5
    s.cheat = math.floor(math.max(0.5, math.min(5.9, cheat)) * 10 + 0.5) / 10
    s.mods = {}
    local seen = {}
    if type(setup.mods) == 'table' then
        for _, uid in setup.mods do
            if type(uid) == 'string' and not seen[uid] then
                seen[uid] = true
                table.insert(s.mods, uid)
            end
        end
    end
    table.sort(s.mods)
    local haveYou = false
    local given = type(setup.slots) == 'table' and setup.slots or nil
    for i = 1, n do
        local from = given and given[i]
        local slot = EmptySlot()
        if type(from) == 'table' then
            if from.role == 'you' and not haveYou then
                slot.role = 'you'
                haveYou = true
            elseif from.role == 'ai' then
                slot.role = 'ai'
            end
            if type(from.ai) == 'string' and from.ai ~= '' then slot.ai = from.ai end
            slot.team = math.max(0, math.min(MAX_TEAM, math.floor(tonumber(from.team) or 0)))
            slot.faction = type(from.faction) == 'string' and from.faction or ''
        end
        s.slots[i] = slot
    end
    if not given then s.slots[1].role = 'you' s.slots[1].faction = EDIT_FACTION end
    return s
end

--- Does this setup need a new session (armies with a brain, fog, mods, another faction or unit cap ...)? False for what the editing session plays as it is: you in the first slot as UEF,
--- nobody else, no fog, sandbox, no pre-built bases, no mods, unit cap 1000.
function NeedsReload(setup)
    if type(setup) ~= 'table' or type(setup.slots) ~= 'table' then return false end
    if setup.fog or setup.prebuilt or setup.victory ~= 'sandbox' or (setup.unitCap or EDIT_UNIT_CAP) ~= EDIT_UNIT_CAP then return true end
    if setup.mods and table.getn(setup.mods) > 0 then return true end
    for i, slot in setup.slots do
        if i == 1 then
            if slot.role ~= 'you' or (slot.faction or '') ~= EDIT_FACTION then return true end
        elseif slot.role ~= 'empty' then
            return true
        end
    end
    return false
end

--- The mod uids a run plays with: the setup's own and those of the AI mods of its AI slots (a mod that is not on disk any more is dropped). Sorted.
function UsedMods(setup)
    local set = {}
    for _, uid in setup.mods or {} do set[uid] = true end
    for _, slot in setup.slots or {} do
        if slot.role == 'ai' then
            local t = AiType(slot.ai)
            if t and t.mod ~= '' then set[t.mod] = true end
        end
    end
    local out = {}
    for _, m in Lists().mods do
        if set[m.uid] then table.insert(out, m.uid) end
    end
    return out
end

--- What is wrong with the setup, as a list of texts (empty = fine): AI types the game does not have (a mod that is gone), an AI with nobody to fight, teams that put everybody on one side.
function Problems(setup)
    local list = {}
    local you, ais = 0, 0
    local teams = {}
    for i, slot in setup.slots do
        if slot.role == 'you' then you = you + 1 end
        if slot.role == 'ai' then
            ais = ais + 1
            if not AiType(slot.ai) then table.insert(list, 'slot ' .. i .. ': the AI "' .. tostring(slot.ai) .. '" is not in this game (is its mod gone?)') end
        end
        if slot.role ~= 'empty' then teams[slot.team] = true end
    end
    if you + ais == 0 then table.insert(list, 'no slot is You or an AI: nothing would play') end
    if you + ais == 1 and setup.victory ~= 'sandbox' then table.insert(list, 'the victory condition ends the run at once with one army (use Sandbox)') end
    local one = nil
    local allTeamed = you + ais >= 2
    for i, slot in setup.slots do
        if slot.role ~= 'empty' then
            if slot.team == 0 then allTeamed = false end
            if one == nil then one = slot.team elseif one ~= slot.team then allTeamed = false end
        end
    end
    if allTeamed then table.insert(list, 'every army is on the same team: nobody fights') end
    return list
end

--- A reason the run cannot start with this setup (nil when it can): nothing would play, or an AI the game does not have.
function Blocking(setup)
    local you, ais = 0, 0
    for i, slot in setup.slots do
        if slot.role == 'you' then you = you + 1 end
        if slot.role == 'ai' then
            ais = ais + 1
            if not AiType(slot.ai) then return 'slot ' .. i .. ' has the AI "' .. tostring(slot.ai) .. '", which this game does not have: open Play setup and choose another' end
        end
    end
    if you + ais == 0 then return 'no slot is You or an AI: open Play setup and choose one' end
    return nil
end

-- ---- remembered setups and profiles -----------------------------------------------------------------------------------------------------------

local store = false      -- { last = setup | nil, maps = { key = setup }, profiles = { name = setup } }

local function Store()
    if store then return store end
    local tbl = UserData.ReadTable(FILE)
    store = { last = nil, maps = {}, profiles = {} }
    if type(tbl) == 'table' then
        if type(tbl.last) == 'table' then store.last = tbl.last end
        if type(tbl.maps) == 'table' then store.maps = tbl.maps end
        if type(tbl.profiles) == 'table' then store.profiles = tbl.profiles end
    end
    return store
end

local function Flush()
    local s = Store()
    UserData.WriteTable(FILE, { last = s.last, maps = s.maps, profiles = s.profiles })
end

--- Tests: forget what was read (the next call reads the file again).
function Reload()
    store = false
end

--- The map keeps its own setup (else it plays with the last one used on any map).
function KeepsOwn(key)
    key = key or MapKey()
    return key ~= nil and Store().maps[key] ~= nil
end

--- The setup for the open map: its own when it keeps one, else the last one used, else Solo. Always normalised to the map's slot count.
function Current()
    local key = MapKey()
    local s = Store()
    local n = SlotCount()
    local setup = (key and s.maps[key]) or s.last
    return Normalize(setup, n)
end

--- Remembers a Play: the setup becomes the last one used, and the map's own when `keepForMap` (a map that no longer keeps one drops it).
function Remember(setup, keepForMap)
    local s = Store()
    s.last = Copy(setup)
    local key = MapKey()
    if key then
        s.maps[key] = keepForMap and Copy(setup) or nil
    end
    Flush()
end

--- The profile names: the built-in ones, then the saved ones by name.
function Profiles()
    local list = {}
    for _, name in BUILTIN do table.insert(list, name) end
    local saved = {}
    for name, _ in Store().profiles do table.insert(saved, name) end
    table.sort(saved, function(a, b) return string.lower(a) < string.lower(b) end)
    for _, name in saved do table.insert(list, name) end
    return list
end

function IsBuiltin(name)
    for _, b in BUILTIN do
        if b == name then return true end
    end
    return false
end

--- A profile's setup for a map with `n` start positions (nil: no such profile).
function GetProfile(name, n)
    local b = Builtin(name, n)
    if b then return b end
    local saved = Store().profiles[name]
    if type(saved) ~= 'table' then return nil end
    return Normalize(saved, n)
end

--- Saves the setup under a name. A built-in name is refused (false, why); an empty name too.
function SaveProfile(name, setup)
    name = string.gsub(tostring(name or ''), '^%s+', '')
    name = string.gsub(name, '%s+$', '')
    if name == '' then return false, 'type a name for the profile' end
    if IsBuiltin(name) then return false, '"' .. name .. '" is a built-in profile; pick another name' end
    Store().profiles[name] = Copy(setup)
    Flush()
    return true
end

--- Removes a saved profile (false, why for a built-in or unknown one).
function DeleteProfile(name)
    if IsBuiltin(name) then return false, 'built-in profiles stay' end
    if Store().profiles[name] == nil then return false, 'no such saved profile' end
    Store().profiles[name] = nil
    Flush()
    return true
end

-- ---- the launch file --------------------------------------------------------------------------------------------------------------------------

--- What the next session start needs of the setup: Lua data for schook/lua/SinglePlayerLaunch.lua. `map` is the scenario the session will open (the file is read only for that map).
function LaunchTable(setup, scenarioPath)
    local t = {
        map = tostring(scenarioPath or ''), fog = setup.fog and true or false, victory = setup.victory, unitCap = setup.unitCap, cheat = setup.cheat,
        prebuilt = setup.prebuilt and true or false, mods = UsedMods(setup), slots = {},
    }
    for i, slot in setup.slots do
        t.slots[i] = { role = slot.role, ai = slot.ai, team = slot.team, faction = slot.faction }
    end
    return t
end

function LaunchText(setup, scenarioPath)
    return 'return ' .. LuaSer.Dump(LaunchTable(setup, scenarioPath), 0) .. '\n'
end

--- Writes the launch file; true when it was written.
function WriteLaunch(setup, scenarioPath)
    return ed_write_file(LAUNCH_FILE, LaunchText(setup, scenarioPath)) ~= false
end

--- Reads the launch file for a session start and empties it (once read it applies to this start only). Returns the table, or nil when there is none, it is for another map or it is not
--- readable. `same(a, b)` says whether two scenario paths are the same map (default: equal ignoring case).
function ReadLaunch(scenarioPath, same)
    local text = ed_read_file(LAUNCH_FILE)
    if not text or string.find(text, '^%s*$') then return nil end
    ed_write_file(LAUNCH_FILE, '')
    local okLoad, chunk = pcall(loadstring, text, '=playlaunch')       -- (in this engine loadstring raises on a syntax error)
    if not okLoad or not chunk then return nil end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= 'table' or type(t.slots) ~= 'table' then return nil end
    local function Same(a, b)
        a = string.lower(string.gsub(tostring(a or ''), '\\', '/'))
        b = string.lower(string.gsub(tostring(b or ''), '\\', '/'))
        return a == b
    end
    if not (same or Same)(t.map, scenarioPath) then return nil end
    return t
end
