-- Favourites of the asset browsers: a star per entry, starred entries come first in the list, "Starred only" hides the rest; and the entries used last (the asset browser's Recent view).
-- Kept in `editor_favourites.lua` next to the exe (per editor installation, not per map), loaded on first use.
--
--   Is(kind, key) / Toggle(kind, key) / List(kind)       kind: 'props' | 'decals' | 'units' | 'markers' | 'textures' | 'effects' | 'mods'; key: blueprint path / texture path / unit id / name
--   Touch(kind, key) / Recent(kind) / RecentRank(kind, key)   the last MAX_RECENT used entries (all kinds in one list, newest first); Recent(kind) lists the keys of one kind
--   Arrange(kind, list, keyOf, onlyStarred)              -> a new list: starred entries first (order kept inside both parts), only those when `onlyStarred`
--
-- Lua 5.0 dialect.

local FILE = 'editor_favourites.lua'
local KINDS = { 'props', 'decals', 'units', 'markers', 'textures', 'effects', 'mods' }
MAX_RECENT = 60

local data = false
local recent = {}        -- { { kind, key }, ... } newest first

local function Load()
    if data then return end
    data = {}
    for _, kind in KINDS do data[kind] = {} end
    recent = {}
    local text = ed_read_file(FILE)
    if text and text ~= '' then
        local env = {}
        local fn = loadstring(text)
        if fn then
            setfenv(fn, env)
            pcall(fn)
            for _, kind in KINDS do
                for _, key in env[kind] or {} do data[kind][key] = true end
            end
            for _, r in env.recent or {} do
                if type(r) == 'table' and r[1] and r[2] and data[r[1]] then table.insert(recent, { r[1], r[2] }) end
            end
        end
    end
end

local function Save()
    local lines = {}
    for _, kind in KINDS do
        local keys = {}
        for key, on in data[kind] do if on then table.insert(keys, key) end end
        table.sort(keys)
        table.insert(lines, kind .. ' = {')
        for _, key in keys do table.insert(lines, string.format('    %q,', key)) end
        table.insert(lines, '}')
    end
    table.insert(lines, 'recent = {')
    for _, r in recent do table.insert(lines, string.format('    { %q, %q },', r[1], r[2])) end
    table.insert(lines, '}')
    ed_write_file(FILE, table.concat(lines, '\n') .. '\n')
end

function Is(kind, key)
    Load()
    return data[kind] and data[kind][key] and true or false
end

function Toggle(kind, key)
    Load()
    if not data[kind] or not key then return false end
    if data[kind][key] then data[kind][key] = nil else data[kind][key] = true end
    Save()
    return data[kind][key] and true or false
end

function List(kind)
    Load()
    local keys = {}
    for key, on in data[kind] or {} do if on then table.insert(keys, key) end end
    table.sort(keys)
    return keys
end

--- A new list with the starred entries first (their order kept), or only the starred ones.
function Arrange(kind, list, keyOf, onlyStarred)
    Load()
    local starred, rest = {}, {}
    for _, e in list do
        if data[kind] and data[kind][keyOf(e)] then table.insert(starred, e) else table.insert(rest, e) end
    end
    if not onlyStarred then
        for _, e in rest do table.insert(starred, e) end
    end
    return starred
end

--- Marks an entry as used just now (the asset browser calls it when something is placed or picked).
function Touch(kind, key)
    Load()
    if not data[kind] or not key then return end
    for i, r in recent do
        if r[1] == kind and r[2] == key then table.remove(recent, i) break end
    end
    table.insert(recent, 1, { kind, key })
    while table.getn(recent) > MAX_RECENT do table.remove(recent) end
    Save()
end

--- The keys of one kind, newest used first.
function Recent(kind)
    Load()
    local keys = {}
    for _, r in recent do
        if r[1] == kind then table.insert(keys, r[2]) end
    end
    return keys
end

--- Forgets the recent list (the stars stay).
function ClearRecent()
    Load()
    recent = {}
    Save()
end

--- 1 = used last; nil = not in the recent list.
function RecentRank(kind, key)
    Load()
    for i, r in recent do
        if r[1] == kind and r[2] == key then return i end
    end
    return nil
end

--- Test helper: forget everything in memory (the file is rewritten at the next change).
function Reset()
    data = {}
    for _, kind in KINDS do data[kind] = {} end
    recent = {}
end
