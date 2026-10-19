-- Lobby slots of a map: which factions a start slot offers in the game lobby (`ScenarioInfo.Configurations.standard.factions[slot]`, a list of faction keys;
-- faf_repo/fa/lua/ui/lobby/lobby.lua UpdateAvailableSlots). Without the table every slot offers all four factions. The lobby reads nothing else of the
-- configuration: `teams` is one FFA entry whose army count is the slot count, so there is no team layout to edit (docs/projects/editor/PARITY_FINAL.md).
--
--   Keys                         { 'uef', 'aeon', 'cybran', 'seraphim' }
--   Get(slot)                    the factions the slot offers (all four when unrestricted)
--   IsRestricted(slot)
--   Set(slot, list)              restricts the slot to the listed keys (an empty list or all four removes the restriction); with undo
--   Check()                      problems: list of { sev, text }
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')

Keys = { 'uef', 'aeon', 'cybran', 'seraphim' }

local function Std()
    local info = Map.Doc and Map.Doc.info
    if not info then return nil end
    info.Configurations = info.Configurations or {}
    info.Configurations.standard = info.Configurations.standard or {}
    return info.Configurations.standard
end

local function Copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in t do c[k] = Copy(v) end
    return c
end

function Get(slot)
    local std = Std()
    local list = std and std.factions and std.factions[slot]
    if not list or table.getn(list) == 0 then return Copy(Keys) end
    return Copy(list)
end

function IsRestricted(slot)
    local std = Std()
    local list = std and std.factions and std.factions[slot]
    return list ~= nil and table.getn(list) > 0 and table.getn(list) < table.getn(Keys)
end

local function SlotCount()
    local n = 0
    for name, _ in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers or {} do
        if string.find(name, '^ARMY_%d+$') then n = n + 1 end
    end
    return n
end

--- The lobby loops 1..slots over the table: when any slot is restricted every slot needs an entry (the full list for the free ones); when none is, the table goes.
local function Normalize()
    local std = Std()
    if not std.factions then return end
    local n = math.max(SlotCount(), 1)
    local restricted = false
    for i, list in std.factions do
        if type(list) == 'table' and table.getn(list) > 0 and table.getn(list) < table.getn(Keys) then restricted = true end
    end
    if not restricted then std.factions = nil return end
    for i = 1, n do
        if not std.factions[i] or table.getn(std.factions[i]) == 0 then std.factions[i] = Copy(Keys) end
    end
end

--- Ordered by `Keys`, only known keys; an empty list or all four means unrestricted.
function Set(slot, list)
    if not Std() or slot < 1 then return false end
    local want = {}
    for _, k in Keys do
        for _, k2 in list or {} do
            if k == k2 then table.insert(want, k) break end
        end
    end
    local before = Std().factions and Copy(Std().factions) or nil
    if table.getn(want) == 0 or table.getn(want) == table.getn(Keys) then
        if Std().factions then Std().factions[slot] = Copy(Keys) end
    else
        Std().factions = Std().factions or {}
        Std().factions[slot] = want
    end
    Normalize()
    local after = Std().factions and Copy(Std().factions) or nil
    History.Push{
        label = 'lobby slot ' .. slot .. ' factions',
        undo = function() Std().factions = before and Copy(before) or nil end,
        redo = function() Std().factions = after and Copy(after) or nil end,
    }
    return true
end

function Check()
    local out = {}
    local std = Std()
    if not std or not std.factions then return out end
    local slots = SlotCount()
    for i, list in std.factions do
        if i > slots then
            table.insert(out, { sev = 'warn', text = 'lobby slot ' .. i .. ' has a faction list but the map has only ' .. slots .. ' start positions' })
        end
        if type(list) ~= 'table' or table.getn(list) == 0 then
            table.insert(out, { sev = 'error', text = 'lobby slot ' .. i .. ' offers no faction (the lobby would show an empty list)' })
        end
    end
    for i = 1, slots do
        if not std.factions[i] then
            table.insert(out, { sev = 'error', text = 'lobby slot ' .. i .. ' has no faction entry while other slots do (the lobby loops over nil)' })
        end
    end
    return out
end
